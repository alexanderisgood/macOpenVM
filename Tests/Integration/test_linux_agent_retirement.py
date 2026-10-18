# SPDX-License-Identifier: Apache-2.0
"""Private retirement namespace/lock fixtures; no native or power-loss claim."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import unittest

from linux_agent_transaction_fixture import GenerationFixture

RETIREMENT_ID = "11111111-2222-4333-8444-555555555555"
OTHER_RETIREMENT_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
OTHER_VM_ID = "11234567-89ab-cdef-0123-456789abcdef"


def payload_manifest(directory):
    data = "".join(hashlib.sha256((directory / name).read_bytes()).hexdigest()
                   + "  " + name + "\n" for name in ("agent", "initd", "setup.sh")).encode()
    (directory / "SHA256SUMS").write_bytes(data)
    return hashlib.sha256(data).hexdigest()


class RetirementFixture(GenerationFixture):
    def __init__(self):
        super().__init__()
        self.payload_c = self.base / "payload-c"
        self.payload_c.mkdir(mode=0o700)
        for name in ("initd", "setup.sh"):
            shutil.copyfile(self.payload_a / name, self.payload_c / name)
        (self.payload_c / "agent").write_bytes(b"fixture-generation-C-not-an-agent\n")
        self.pin_c = payload_manifest(self.payload_c)
        self.retirement = self.owned_state.with_name("macopenvm-agent.retirement")
        self.retirement_next = Path(str(self.retirement) + ".next")
        self.program_retired = self.program.with_name("macopenvm-agent.retired")
        self.state_retired = self.owned_state.with_name("macopenvm-agent.retired")
        self.fixture.observe = self.observe

    def observe(self, *arguments, success=True, extra_env=None, test_mode=True):
        # Large bounded archive catalogs are slow through isolated Python shims.
        # This per-fixture limit changes no manager behavior or shared helper.
        environment = os.environ.copy()
        environment.update(MVO_FAKE_ROOT=str(self.sysroot), MVO_FAKE_STATE=str(self.state_file))
        if test_mode:
            environment["MACOPENVM_AGENT_TEST_MODE"] = "1"
        else:
            environment.pop("MACOPENVM_AGENT_TEST_MODE", None)
        environment.update(extra_env or {})
        result = subprocess.run(["/bin/sh", str(self.manager_script), "--test-sysroot", str(self.sysroot),
                                 "--test-command-dir", str(self.commands), *arguments],
                                env=environment, capture_output=True, timeout=240, check=False)
        self.fixture.assertEqual(result.returncode == 0, success, result.stderr.decode())
        self.fixture.assertNotIn(b"fixture-private-key", result.stdout + result.stderr)
        self.fixture.assertLessEqual(len(result.stdout + result.stderr), 128)
        return result

    def install(self, **kwargs):
        return self.fixture.install(**kwargs)

    def archives(self, retirement_id=RETIREMENT_ID):
        return {"program": self.program_retired / retirement_id / "program",
                "state": self.state_retired / retirement_id / "state",
                "journals": self.state_retired / retirement_id / "journals",
                "retirement": self.state_retired / retirement_id / "retirement"}

    def rolled_back(self, *, failed_upgrade_start=False):
        self.install()
        if failed_upgrade_start:
            self.upgrade(extra_env={"MVO_FAIL_START": "1"}, success=False)
        else:
            self.upgrade()
        self.rollback()

    def retire(self, *, resume=False, vm_id=None, current=None, failed=None,
               retirement_id=RETIREMENT_ID, **kwargs):
        arguments = ["retire-failed", "--vm-id", self.vm_id if vm_id is None else vm_id,
                     "--expect-generation", self.pin_a if current is None else current,
                     "--generation-sha256", self.pin_b if failed is None else failed,
                     "--retirement-id", retirement_id]
        if resume:
            arguments.append("--resume")
        return self.observe(*arguments, **kwargs)

    def upgrade_to_c(self, **kwargs):
        return self.observe("upgrade", "--vm-id", self.vm_id,
                            "--expect-generation", self.pin_a,
                            "--payload", str(self.payload_c),
                            "--manifest-sha256", self.pin_c, **kwargs)

    def replace_fixture_manager(self, data):
        # These are new private copies only; both existing source and historically
        # signed payloads remain untouched. All candidates use one exact manager.
        self.manager_script.write_bytes(data)
        for payload in (self.payload_a, self.payload_b, self.payload_c):
            (payload / "setup.sh").write_bytes(data)
        self.pin_a = payload_manifest(self.payload_a)
        self.fixture.pin = self.pin_a
        self.pin_b = payload_manifest(self.payload_b)
        self.pin_c = payload_manifest(self.payload_c)


class RetirementCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.baseline = RetirementFixture()
        cls.addClassCleanup(cls.baseline.close)
        cls.baseline.rolled_back()

    def fixture(self, *, rolled_back=True, failed_upgrade_start=False):
        fixture = RetirementFixture()
        self.addCleanup(fixture.close)
        if rolled_back:
            if failed_upgrade_start:
                fixture.rolled_back(failed_upgrade_start=True)
            else:
                # Seed only pre-retirement data produced by the actual immutable
                # manager. All destination inodes are new; retirement records and
                # authority are never copied. Each operation re-admits the files.
                self.assertEqual(fixture.manager_script.read_bytes(), self.baseline.manager_script.read_bytes())
                self.assertEqual((fixture.pin_a, fixture.pin_b), (self.baseline.pin_a, self.baseline.pin_b))
                shutil.rmtree(fixture.sysroot)
                shutil.copytree(self.baseline.sysroot, fixture.sysroot, symlinks=True)
                for path in fixture.sysroot.rglob("*"):
                    if path.is_symlink():
                        self.assertEqual(path.relative_to(fixture.sysroot).as_posix(),
                                         "etc/runlevels/default/macopenvm-agent")
                        target = Path(os.readlink(path)).relative_to(self.baseline.sysroot)
                        path.unlink()
                        path.symlink_to(fixture.sysroot / target)
                fixture.state_file.write_bytes(self.baseline.state_file.read_bytes())
                self.assertNotEqual(fixture.kernel_lock.stat().st_ino, self.baseline.kernel_lock.stat().st_ino)
        return fixture

    def tree_identity(self, fixture, directory):
        return {".": fixture.path_identity(directory),
                **{path.relative_to(directory).as_posix(): fixture.path_identity(path)
                   for path in directory.rglob("*")}}

    def current_identity(self, fixture):
        return {"program": self.tree_identity(fixture, fixture.program),
                "state": self.tree_identity(fixture, fixture.owned_state),
                "protected": fixture.protected(),
                "kernel": fixture.path_identity(fixture.kernel_lock)}

    def assert_admission_refusal_unchanged(self, fixture, **kwargs):
        before = fixture.full_tree()
        calls = fixture.service_mutations()
        fixture.retire(success=False, **kwargs)
        self.assertEqual(fixture.full_tree(), before)
        self.assertEqual(fixture.service_mutations(), calls)

    def evidence(self, fixture):
        return {"program": self.tree_identity(fixture, fixture.slot(fixture.program, "failed")),
                "state": self.tree_identity(fixture, fixture.slot(fixture.owned_state, "failed")),
                "journals": self.tree_identity(fixture, fixture.journal.parent)}

    def assert_evidence_preserved(self, fixture, evidence, retirement_id=RETIREMENT_ID):
        source = {"program": fixture.slot(fixture.program, "failed"),
                  "state": fixture.slot(fixture.owned_state, "failed"),
                  "journals": fixture.journal.parent}
        archive = fixture.archives(retirement_id)
        for name in source:
            locations = [path for path in (source[name], archive[name]) if path.exists()]
            self.assertEqual(len(locations), 1, (name, locations))
            self.assertEqual(self.tree_identity(fixture, locations[0]), evidence[name])

    def record(self, directory):
        data = (directory / "record").read_bytes()
        lines = data.splitlines()
        keys = ("vm-id", "retirement-id", "current", "failed", "manager", "initd", "uid", "gid",
                "reservation", "current-state", "failed-state", "cohort", "current-program-inode",
                "current-state-inode", "failed-program-inode", "failed-state-inode", "cohort-inode", "phase")
        self.assertEqual(lines[0], b"macopenvm-agent-retirement-v1")
        self.assertEqual(len(lines), 19)
        self.assertTrue(data.endswith(b"\n"))
        fields = {}
        for name, line in zip(keys, lines[1:]):
            key, value = line.decode().split("=", 1)
            self.assertEqual(key, name)
            fields[key] = value
        return data, fields

    def assert_complete(self, fixture, evidence, current, retirement_id=RETIREMENT_ID):
        self.assertEqual(self.current_identity(fixture), current)
        self.assert_evidence_preserved(fixture, evidence, retirement_id)
        archive = fixture.archives(retirement_id)
        for path in (fixture.retirement, fixture.retirement_next,
                     fixture.slot(fixture.program, "failed"), fixture.slot(fixture.owned_state, "failed"),
                     fixture.journal.parent):
            self.assertFalse(path.exists(), str(path))
        for name in evidence:
            self.assertEqual(self.tree_identity(fixture, archive[name]), evidence[name])
        data, fields = self.record(archive["retirement"])
        self.assertEqual((archive["retirement"] / "confirmation").read_bytes(), data)
        for name in ("record.next", "confirmation.next", "confirmation-unconfirmed"):
            self.assertFalse((archive["retirement"] / name).exists())
        self.assertEqual((fields["vm-id"], fields["retirement-id"], fields["current"], fields["failed"]),
                         (fixture.vm_id.lower(), retirement_id, fixture.pin_a, fixture.pin_b))
        self.assertEqual(fields["phase"], "complete")
        for name, identity in (("current-program-inode", current["program"]["."]),
                               ("current-state-inode", current["state"]["."]),
                               ("failed-program-inode", evidence["program"]["."]),
                               ("failed-state-inode", evidence["state"]["."]),
                               ("cohort-inode", evidence["journals"]["."])):
            self.assertEqual(fields[name], f"{identity[0]}:{identity[1]}")
        self.assertEqual(fields["manager"], hashlib.sha256(fixture.manager_script.read_bytes()).hexdigest())
        self.assertEqual(fields["initd"], hashlib.sha256(fixture.service.read_bytes()).hexdigest())
        self.assertEqual(fields["reservation"], hashlib.sha256((fixture.reservation / "record").read_bytes()).hexdigest())

    def retirement_trace(self):
        fixture = self.fixture()
        offset = len(fixture.state()["calls"])
        fixture.retire()
        return fixture, [call for call in fixture.state()["calls"][offset:]
                         if call[0] in ("mv", "sync")]

    def finish_interrupted(self, fixture, evidence, current):
        self.assertEqual(self.current_identity(fixture), current)
        self.assert_evidence_preserved(fixture, evidence)
        fixture.retire(resume=True)
        self.assert_complete(fixture, evidence, current)
        before = fixture.full_tree(); moves = fixture.state()["moves"]
        fixture.retire(resume=True)
        self.assertEqual(fixture.full_tree(), before)
        self.assertEqual(fixture.state()["moves"], moves)
        self.assertFalse(fixture.state()["running"])



class LinuxAgentRetirementTests(RetirementCase):
    def test_exact_retirement_preserves_current_identity_and_allows_c_then_rollback(self):
        fixture = self.fixture()
        current = self.current_identity(fixture)
        evidence = self.evidence(fixture)
        offset = len(fixture.state()["calls"])
        fixture.retire()
        self.assert_complete(fixture, evidence, current)
        self.assertFalse(fixture.state()["running"])
        self.assertFalse(any(call[:3] == ["rc-service", "macopenvm-agent", "start"]
                             for call in fixture.state()["calls"][offset:]))
        archived = {name: self.tree_identity(fixture, path) for name, path in fixture.archives().items()}
        before = fixture.full_tree(); calls = fixture.service_mutations()
        fixture.retire(resume=True)
        self.assertEqual(fixture.full_tree(), before)
        self.assertEqual(fixture.service_mutations(), calls)
        fixture.upgrade_to_c()
        self.assertEqual(fixture.current_pin(), fixture.pin_c)
        fixture.observe("rollback", "--vm-id", fixture.vm_id, "--expect-generation", fixture.pin_c,
                        "--generation-sha256", fixture.pin_a)
        self.assertEqual(fixture.current_pin(), fixture.pin_a)
        self.assertEqual(fixture.protected(), current["protected"])
        self.assertEqual(fixture.path_identity(fixture.kernel_lock), current["kernel"])
        self.assertEqual({name: self.tree_identity(fixture, path) for name, path in fixture.archives().items()}, archived)

    def test_published_b_with_failed_service_start_is_retireable_after_completed_rollback(self):
        fixture = self.fixture(failed_upgrade_start=True)
        self.assertEqual((fixture.journal.parent / "previous-transaction").read_text().splitlines()[-1], "phase=start")
        current = self.current_identity(fixture); evidence = self.evidence(fixture)
        fixture.retire()
        self.assert_complete(fixture, evidence, current)

    def test_historical_archive_survives_same_manager_uninstall_reinstall_and_c_upgrade(self):
        fixture = self.fixture()
        fixture.retire()
        archive = {name: self.tree_identity(fixture, path) for name, path in fixture.archives().items()}
        credentials = {path.name: fixture.path_identity(path) for path in fixture.credentials.iterdir()}
        account = {name: fixture.path_identity(fixture.sysroot / "etc" / name)
                   for name in ("passwd", "shadow", "group")}
        kernel = fixture.path_identity(fixture.kernel_lock)
        fixture.observe("uninstall")
        fixture.fixture.reinstall(reuse=True)
        fixture.upgrade_to_c()
        self.assertEqual(fixture.current_pin(), fixture.pin_c)
        self.assertEqual({path.name: fixture.path_identity(path) for path in fixture.credentials.iterdir()}, credentials)
        self.assertEqual({name: fixture.path_identity(fixture.sysroot / "etc" / name) for name in account}, account)
        self.assertEqual(fixture.path_identity(fixture.kernel_lock), kernel)
        self.assertEqual({name: self.tree_identity(fixture, path) for name, path in fixture.archives().items()}, archive)

    def test_wrong_vm_pins_and_malformed_retirement_ids_refuse_without_mutation(self):
        cases = ({"vm_id": OTHER_VM_ID}, {"current": "0" * 64},
                 {"failed": "0" * 64}, {"failed": None, "current": "not-a-pin"},
                 {"retirement_id": "../unrelated"}, {"retirement_id": "not-a-uuid"},
                 {"retirement_id": RETIREMENT_ID + "x"})
        for arguments in cases:
            with self.subTest(arguments=arguments):
                fixture = self.fixture()
                self.assert_admission_refusal_unchanged(fixture, **arguments)

    def test_actual_kernel_lock_contention_blocks_every_mutator(self):
        fixture = self.fixture()
        actions = {
            "install": lambda: fixture.fixture.install(success=False),
            "reinstall": lambda: fixture.fixture.reinstall(success=False),
            "uninstall": lambda: fixture.observe("uninstall", success=False),
            "remove-credentials": lambda: fixture.observe("uninstall", "--remove-credentials", success=False),
            "upgrade": lambda: fixture.upgrade_to_c(success=False),
            "rollback": lambda: fixture.rollback(success=False),
            "generation-recover": lambda: fixture.recover(success=False),
            "retire-failed": lambda: fixture.retire(success=False),
            "retire-resume": lambda: fixture.retire(resume=True, success=False),
        }
        with fixture.held_kernel_lock():
            before = fixture.full_tree()
            calls = fixture.service_mutations()
            for name, action in actions.items():
                with self.subTest(action=name):
                    result = action()
                    self.assertIn(b"kernel", result.stderr)
                    self.assertEqual(fixture.full_tree(), before)
                    self.assertEqual(fixture.service_mutations(), calls)

    def test_manager_only_size_bound_does_not_expand_credentials(self):
        fixture = self.fixture(rolled_back=False)
        manager = fixture.manager_script.read_bytes()
        self.assertLessEqual(len(manager), 131072)
        padding = 131072 - len(manager)
        self.assertGreaterEqual(padding, 3)
        fixture.replace_fixture_manager(manager + b"\n#" + b"x" * (padding - 3) + b"\n")
        self.assertEqual(fixture.manager_script.stat().st_size, 131072)
        fixture.install()
        self.assertEqual((fixture.program / "setup.sh").read_bytes(), fixture.manager_script.read_bytes())
        oversized = self.fixture(rolled_back=False)
        raw = oversized.manager_script.read_bytes()
        padding = 131073 - len(raw)
        oversized.replace_fixture_manager(raw + b"\n#" + b"x" * (padding - 3) + b"\n")
        before = oversized.full_tree()
        oversized.install(success=False)
        self.assertEqual(oversized.full_tree(), before)
        self.assertFalse(oversized.kernel_lock.exists())
        credentials = self.fixture(rolled_back=False)
        # A valid permanent exclusion inode may predate fresh enrollment. Its
        # identity must survive rejection; no account or credential is provisioned.
        credentials.kernel_lock.write_bytes(b"")
        credentials.kernel_lock.chmod(0o600)
        (credentials.enrollment / "cert.pem").write_bytes(b"x" * 65537)
        before = credentials.full_tree()
        credentials.install(success=False)
        self.assertEqual(credentials.full_tree(), before)
        self.assertFalse(credentials.state()["user"])


if __name__ == "__main__":
    unittest.main()
