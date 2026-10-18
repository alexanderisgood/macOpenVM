# SPDX-License-Identifier: Apache-2.0
"""Recoverable filesystem transaction tests; no guest, root ownership or power-loss claim."""
import hashlib
import fcntl
import os
import subprocess
import unittest
import shutil
import time

from linux_agent_transaction_fixture import GenerationFixture, LEGACY, LEGACY_SHA


class LinuxAgentGenerationTests(unittest.TestCase):
    def setUp(self):
        self.f = GenerationFixture()
        self.addCleanup(self.f.close)

    def test_distinct_A_B_A_uses_exact_slots_and_preserves_identity(self):
        f = self.f
        f.install()
        protected = f.protected()
        kernel = f.path_identity(f.kernel_lock)
        self.assertNotEqual(f.pin_a, f.pin_b)
        f.upgrade()
        self.assertEqual(f.current_pin(), f.pin_b)
        self.assertEqual((f.program / "macopenvm-agent").read_bytes(), (f.payload_b / "agent").read_bytes())
        self.assertEqual((f.slot(f.program, "previous") / "macopenvm-agent").read_bytes(), (f.payload_a / "agent").read_bytes())
        self.assertEqual(f.state()["running_generation"], hashlib.sha256((f.payload_b / "agent").read_bytes()).hexdigest())
        self.assertEqual(f.protected(), protected)
        f.rollback()
        self.assertEqual(f.current_pin(), f.pin_a)
        self.assertEqual((f.program / "macopenvm-agent").read_bytes(), (f.payload_a / "agent").read_bytes())
        self.assertEqual((f.slot(f.program, "failed") / "macopenvm-agent").read_bytes(), (f.payload_b / "agent").read_bytes())
        self.assertEqual(f.state()["running_generation"], hashlib.sha256((f.payload_a / "agent").read_bytes()).hexdigest())
        self.assertEqual(f.protected(), protected)
        self.assertEqual(f.path_identity(f.kernel_lock), kernel)
        self.assertTrue(f.state()["running"])
        self.assertTrue(all(not inherited for inherited in f.state()["service_lock_inherited"]))

    def test_stop_error_and_false_ack_preserve_A_before_namespace_change(self):
        for flag in ("MVO_FAIL_STOP", "MVO_FALSE_STOP_ACK"):
            with self.subTest(flag=flag):
                f = GenerationFixture()
                try:
                    f.install()
                    protected = f.protected()
                    program = f.path_identity(f.program)
                    state = f.path_identity(f.owned_state)
                    result = f.upgrade(extra_env={flag: "1"}, success=False)
                    message = b"Normal service stop failed" if flag == "MVO_FAIL_STOP" else b"not demonstrably stopped"
                    self.assertIn(message, result.stderr)
                    self.assertEqual(f.path_identity(f.program), program)
                    self.assertEqual(f.path_identity(f.owned_state), state)
                    self.assertEqual(f.current_pin(), f.pin_a)
                    self.assertEqual(f.protected(), protected)
                    self.assertTrue(f.state()["running"])
                    f.assert_generations_present(self)
                finally: f.close()

    def test_old_v1_manager_refuses_v2_state_before_stop_or_remove(self):
        f = self.f
        f.install()
        self.assertEqual(hashlib.sha256(LEGACY.read_bytes()).hexdigest(), LEGACY_SHA)
        before = f.full_tree()
        calls = f.service_mutations()
        env = os.environ.copy()
        env.update(MACOPENVM_AGENT_TEST_MODE="1", MVO_FAKE_ROOT=str(f.sysroot), MVO_FAKE_STATE=str(f.state_file))
        result = subprocess.run(["/bin/sh", str(LEGACY), "--test-sysroot", str(f.sysroot),
                                 "--test-command-dir", str(f.commands), "uninstall", "--remove-credentials"],
                                env=env, capture_output=True, timeout=20, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(f.full_tree(), before)
        self.assertEqual(f.service_mutations(), calls)

    def test_all_current_mutators_refuse_actual_kernel_lock_and_release_admits_upgrade(self):
        f = self.f
        f.install()
        before = f.full_tree(); calls = f.service_mutations()
        with f.held_kernel_lock() as child:
            actions = [
                lambda: f.fixture.install(success=False),
                lambda: f.fixture.reinstall(success=False),
                lambda: f.observe("uninstall", "--remove-credentials", success=False),
                lambda: f.upgrade(success=False), lambda: f.rollback(success=False), lambda: f.recover(success=False),
            ]
            for action in actions:
                result = action()
                self.assertIn(b"holds kernel exclusion", result.stderr)
                self.assertEqual(f.full_tree(), before)
                self.assertEqual(f.service_mutations(), calls)
                self.assertIsNone(child.poll())
        f.upgrade()
        self.assertEqual(f.current_pin(), f.pin_b)
        self.assertEqual(f.path_identity(f.kernel_lock), before["var/lib/macopenvm-agent.kernel-lock"])

    def test_admitted_upgrade_retains_kernel_exclusion_across_normal_service_child(self):
        f = self.f; f.install()
        protected = f.protected(); kernel = f.path_identity(f.kernel_lock)
        initial_reader, writer = os.pipe()
        reader = fcntl.fcntl(initial_reader, fcntl.F_DUPFD_CLOEXEC, 20)
        os.close(initial_reader)
        ready = f.base / "service-child-waiting"
        env = os.environ.copy()
        env.update(MACOPENVM_AGENT_TEST_MODE="1", MVO_FAKE_ROOT=str(f.sysroot),
                   MVO_FAKE_STATE=str(f.state_file), MVO_SERVICE_GATE_FD=str(reader),
                   MVO_SERVICE_GATE_READY=str(ready))
        arguments = ["/bin/sh", str(f.manager_script), "--test-sysroot", str(f.sysroot),
                     "--test-command-dir", str(f.commands), "upgrade", "--vm-id", f.vm_id,
                     "--expect-generation", f.pin_a, "--payload", str(f.payload_b), "--manifest-sha256", f.pin_b]
        child = subprocess.Popen(arguments, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(reader,))
        os.close(reader)
        try:
            deadline = time.monotonic() + 60
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "manager never reached the controlled normal-stop boundary")
            self.assertIsNone(child.poll())
            before = f.full_tree(); calls = f.service_mutations()
            result = f.observe("uninstall", "--remove-credentials", success=False)
            self.assertIn(b"holds kernel exclusion", result.stderr)
            self.assertEqual(f.full_tree(), before)
            self.assertEqual(f.service_mutations(), calls)
            self.assertFalse(f.state()["service_lock_inherited"][-1])
        finally:
            try: os.write(writer, b"R")
            except BrokenPipeError: pass
            os.close(writer)
            output, error = child.communicate()
        self.assertEqual(child.returncode, 0, error.decode())
        self.assertNotIn(b"fixture-private-key", output + error)
        self.assertEqual(f.current_pin(), f.pin_b)
        self.assertEqual(f.path_identity(f.kernel_lock), kernel)
        self.assertEqual(f.protected(), protected)

    def test_actual_v1_reinstall_cannot_adopt_either_v2_uninstall_reservation_while_locked(self):
        for remove in (False, True):
            with self.subTest(remove=remove):
                f = GenerationFixture()
                try:
                    f.install()
                    f.observe("uninstall", *(["--remove-credentials"] if remove else []))
                    before = f.full_tree(); calls = f.service_mutations()
                    arguments = ["reinstall", "--vm-id", f.vm_id, "--payload", str(f.payload_a),
                                 "--manifest-sha256", f.pin_a]
                    arguments += ["--enrollment", str(f.enrollment)] if remove else ["--reuse-credentials"]
                    with f.held_kernel_lock():
                        result = f.legacy(*arguments)
                        self.assertIn(b"reservation", result.stderr)
                        self.assertEqual(f.full_tree(), before)
                        self.assertEqual(f.service_mutations(), calls)
                finally: f.close()

    def test_before_after_each_actual_namespace_rename_is_preserved_and_resumable(self):
        baseline = GenerationFixture()
        try:
            baseline.install()
            offsets, _ = baseline.namespace_offsets()
            self.assertEqual(len(offsets), 4)
        finally: baseline.close()
        for offset in offsets:
            for after in (False, True):
                with self.subTest(offset=offset, after=after):
                    f = GenerationFixture()
                    try:
                        f.install(); protected = f.protected()
                        variable = "MVO_FAIL_AFTER_MOVE" if after else "MVO_FAIL_MOVE"
                        f.upgrade(extra_env={variable: str(f.state()["moves"] + offset)}, success=False)
                        self.assertEqual(f.protected(), protected)
                        f.assert_generations_present(self)
                        self.assertTrue(f.journal.is_file())
                        self.assertFalse(f.state()["running"])
                        f.recover()
                        self.assertEqual(f.current_pin(), f.pin_b)
                        self.assertEqual(f.protected(), protected)
                        f.assert_generations_present(self)
                    finally: f.close()

    def test_start_failure_and_start_success_then_failure_preserve_B_and_A_until_explicit_recovery(self):
        for variable in ("MVO_FAIL_START", "MVO_FAIL_START_AFTER_SUCCESS"):
            with self.subTest(variable=variable):
                f = GenerationFixture()
                try:
                    f.install(); protected = f.protected()
                    f.upgrade(extra_env={variable: "1"}, success=False)
                    self.assertEqual(f.current_pin(), f.pin_b)
                    self.assertEqual(f.protected(), protected)
                    f.assert_generations_present(self)
                    self.assertEqual(f.journal.read_text().splitlines()[-1], "phase=start")
                    self.assertEqual(f.state()["running"], variable == "MVO_FAIL_START_AFTER_SUCCESS")
                    f.recover()
                    self.assertEqual(f.current_pin(), f.pin_b)
                    self.assertTrue(f.state()["running"])
                    self.assertEqual(f.protected(), protected)
                finally: f.close()

    def test_wrong_pins_on_valid_transaction_next_refuse_without_archival_or_mutation(self):
        f = self.f
        f.install(); protected = f.protected()
        # The first upgrade move publishes prepared transaction.next; fail before it.
        f.upgrade(extra_env={"MVO_FAIL_MOVE": str(f.state()["moves"] + 1)}, success=False)
        self.assertTrue((f.journal.parent / "transaction.next").is_file())
        before = f.full_tree(); calls = f.service_mutations()
        for source, target in (("0" * 64, f.pin_b), (f.pin_a, "0" * 64)):
            result = f.recover(source=source, target=target, success=False)
            self.assertIn(b"pins", result.stderr)
            self.assertEqual(f.full_tree(), before)
            self.assertEqual(f.service_mutations(), calls)
        f.recover()
        self.assertEqual(f.current_pin(), f.pin_b)
        self.assertEqual(f.protected(), protected)

    def test_mounted_source_device_simulation_refuses_before_namespace_mv(self):
        f = self.f
        f.install(); protected = f.protected()
        calls = len(f.state()["calls"])
        result = f.upgrade(extra_env={"MVO_OTHER_DEVICE_PATH": str(f.program)}, success=False)
        self.assertIn(b"filesystem", result.stderr)
        self.assertEqual(f.current_pin(), f.pin_a)
        self.assertEqual(f.protected(), protected)
        self.assertFalse(any(call[0] == "mv" and call[1] in (str(f.program), str(f.owned_state))
                             for call in f.state()["calls"][calls:]))

    def test_new_manager_refuses_removed_v1_reservation_without_creating_kernel_inode(self):
        f = self.f
        old = f.base / "legacy-payload"
        shutil.copytree(f.payload_a, old)
        (old / "setup.sh").write_bytes(LEGACY.read_bytes())
        manifest = "".join(hashlib.sha256((old / name).read_bytes()).hexdigest() + "  " + name + "\n"
                           for name in ("agent", "initd", "setup.sh"))
        (old / "SHA256SUMS").write_text(manifest)
        pin = hashlib.sha256(manifest.encode()).hexdigest()
        f.legacy("install", "--payload", str(old), "--manifest-sha256", pin,
                 "--enrollment", str(f.enrollment), success=True)
        f.legacy("uninstall", "--remove-credentials", success=True)
        self.assertFalse(f.kernel_lock.exists())
        before = f.full_tree(); calls = f.service_mutations()
        result = f.fixture.reinstall(reuse=False, success=False)
        self.assertIn(b"reservation", result.stderr)
        self.assertEqual(f.full_tree(), before)
        self.assertEqual(f.service_mutations(), calls)
        self.assertFalse(f.kernel_lock.exists())

    def test_mixed_manager_or_service_target_refuses_before_stop_and_staging(self):
        for name in ("setup.sh", "initd"):
            with self.subTest(name=name):
                f = GenerationFixture()
                try:
                    f.install()
                    target = f.payload_b / name
                    target.write_bytes(target.read_bytes() + b"\n# unrelated manager or service\n")
                    manifest = "".join(hashlib.sha256((f.payload_b / item).read_bytes()).hexdigest()
                                       + "  " + item + "\n" for item in ("agent", "initd", "setup.sh"))
                    (f.payload_b / "SHA256SUMS").write_text(manifest)
                    f.pin_b = hashlib.sha256(manifest.encode()).hexdigest()
                    before = f.full_tree(); calls = f.service_mutations()
                    result = f.upgrade(success=False)
                    self.assertIn(b"Mixed manager or service", result.stderr)
                    self.assertEqual(f.full_tree(), before)
                    self.assertEqual(f.service_mutations(), calls)
                finally: f.close()

    def test_occupied_previous_or_failed_evidence_is_never_implicitly_pruned(self):
        for mode in ("previous", "failed"):
            with self.subTest(mode=mode):
                f = GenerationFixture()
                try:
                    f.install(); f.upgrade()
                    if mode == "failed": f.rollback()
                    before = f.full_tree(); calls = f.service_mutations()
                    result = f.upgrade(success=False)
                    self.assertIn(b"conflicts", result.stderr)
                    self.assertEqual(f.full_tree(), before)
                    self.assertEqual(f.service_mutations(), calls)
                finally: f.close()

    def test_missing_flock_refuses_before_state_or_lockfile_creation(self):
        f = self.f
        (f.commands / "flock").unlink()
        before = f.full_tree()
        result = f.fixture.install(success=False)
        self.assertIn(b"tool is unavailable", result.stderr)
        self.assertEqual(f.full_tree(), before)
        self.assertFalse(f.kernel_lock.exists())

    def test_fresh_stage_device_mismatch_refuses_before_account_or_publication(self):
        for leaf in ("program", "credentials", "state", "initd"):
            with self.subTest(leaf=leaf):
                f = GenerationFixture()
                try:
                    rows = {name: f.path_identity(f.sysroot / "etc" / name) for name in ("passwd", "shadow", "group")}
                    pattern = str(f.sysroot / "var/lib/.macopenvm-agent-stage.*" / leaf)
                    result = f.fixture.install(extra_env={"MVO_OTHER_DEVICE_PATTERN": pattern}, success=False)
                    self.assertIn(b"filesystem", result.stderr)
                    self.assertEqual({name: f.path_identity(f.sysroot / "etc" / name) for name in rows}, rows)
                    self.assertFalse(f.state()["user"])
                    self.assertFalse(f.state()["group"])
                    self.assertFalse(f.service_mutations())
                    self.assertFalse(f.program.exists())
                    self.assertFalse(f.credentials.exists())
                    self.assertFalse(f.owned_state.exists())
                    self.assertFalse(f.reservation.exists())
                    self.assertFalse(any(call[0] == "mv" for call in f.state()["calls"]))
                    self.assertTrue(list((f.sysroot / "var/lib").glob(".macopenvm-agent-stage.*")))
                finally: f.close()


if __name__ == "__main__":
    unittest.main()
