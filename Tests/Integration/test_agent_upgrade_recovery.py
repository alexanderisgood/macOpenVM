# SPDX-License-Identifier: Apache-2.0
"""Actual private files plus synthetic retained serial; no guest, process or socket."""
import json
from pathlib import Path
import shutil
import tempfile
from contextlib import redirect_stdout
import io
import os
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

import agent_upgrade_native as proof


class OwnedSerialFixture:
    def __init__(self, executable):
        self.executable = executable
        self.identity = proof.executable_identity(executable)
        self.stdout = b"public copied fixture\nmacopenvm-lab login: "
        self.active = True
        self.first_error = None
        self.truncated = False
        self.writes = []
        self.respond_login = True
        self.respond_root = True
        self.after_write = None

    def snapshot(self, *, deadline):
        return SimpleNamespace(started=True, is_active=self.active, returncode=None,
                               first_error=self.first_error, transcript_truncated=self.truncated,
                               stdout=self.stdout, stdout_bytes=len(self.stdout))

    def write(self, data, *, deadline):
        self.writes.append(data)
        if data == b"\n" and self.respond_login:
            self.stdout += b"\nmacopenvm-lab login: "
        elif data == b"root\n" and self.respond_root:
            self.stdout += b"root\nmacopenvm-lab:~# "
        if self.after_write:
            self.after_write(data)


class AgentUpgradeRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mvo-recovery-test-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / ".lab").mkdir(mode=0o700)
        self.evidence = self.root / ".lab" / ("agent-upgrade-" + uuid.uuid4().hex)
        self.evidence.mkdir(mode=0o700)
        private = Path("/private/tmp") / ("agent-guest-" + uuid.uuid4().hex)
        private.mkdir(mode=0o700)
        self.addCleanup(shutil.rmtree, private)
        self.vm = private / "Agent.macopenvm"
        self.vm.mkdir(mode=0o700)
        self.vm_id, self.session = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        self.executable = self.root / "public-executable-fixture"
        self.executable.write_bytes(b"public fixture bytes only\n"); self.executable.chmod(0o500)
        self.owner = OwnedSerialFixture(self.executable)
        self.history = {"schemaVersion": 1, "sessionID": self.session,
                        "snapshot": {"state": "running", "backendActive": True, "outcome": "pending"}}
        self.write(self.vm / "configuration.json", {"id": self.vm_id})
        self.write(self.vm / "runtime.json", self.history)
        self.write(self.vm / "runtime-intent.json", {"schemaVersion": 1, "vmID": self.vm_id,
                                                    "sessionID": self.session, "state": "unsettled"})
        self.patch = mock.patch.object(proof, "ROOT", self.root)
        self.patch.start(); self.addCleanup(self.patch.stop)

    def write(self, path, value):
        path.write_text(json.dumps(value)); path.chmod(0o600)

    def rejected(self, code, operation, *args):
        with self.assertRaises(proof.base.InstallationProofError) as error:
            operation(*args)
        self.assertEqual(str(error.exception), code)

    def context(self):
        return proof.FixtureRecovery(self.owner, self.vm, self.vm_id, self.evidence, "installed-boot-1")

    def request(self, context, value=None):
        self.write(context.request_file, context.challenge if value is None else value)

    def short_prompts(self, context):
        real = context.prompt
        return mock.patch.object(context, "prompt", side_effect=lambda owner, prompt, offset:
                                 real(owner, prompt, offset, seconds=.01))

    def test_registered_actual_object_and_new_private_request_issue_only_fixed_input(self):
        context = self.context()
        self.assertFalse(context.consume(self.owner))
        self.assertFalse(context.attempted)
        challenge = self.evidence / "recovery-challenge.json"
        self.assertEqual(challenge.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(challenge.read_bytes()), context.challenge)
        self.assertEqual(context.request_file.parent, self.evidence)
        self.assertEqual(context.request_file.name, "normal-poweroff.request.json")
        self.assertEqual(str(uuid.UUID(context.nonce)), context.nonce)
        self.request(context)
        self.assertTrue(context.consume(self.owner))
        self.assertEqual(self.owner.writes, [b"\n", b"root\n", b"poweroff\n"])
        self.assertTrue(self.owner.active)  # Delivery never manufactures a stop receipt.
        self.assertFalse(context.consume(self.owner))
        self.assertEqual(len(self.owner.writes), 3)
        self.assertEqual(json.loads((self.vm / "runtime-intent.json").read_bytes())["state"], "unsettled")

    def test_normal_stopping_is_admitted_but_failed_force_or_inactive_is_not(self):
        self.history["snapshot"].update(state="stopping", operation="stop")
        self.write(self.vm / "runtime.json", self.history)
        context = self.context()
        self.request(context)
        self.assertTrue(context.consume(self.owner))
        for change in ({"state": "failed"}, {"operation": "forceStop"}, {"backendActive": False},
                       {"backendActive": 1}, {"outcome": "failed"}, {"state": "paused"}):
            with self.subTest(change=change):
                self.write(self.vm / "runtime.json", {**self.history,
                                                      "snapshot": {**self.history["snapshot"], **change}})
                self.rejected("recovery-owner-state-invalid", proof.recovery_session,
                              self.owner, self.vm, self.vm_id)

    def test_request_dto_rejects_wrong_identity_nonce_phase_action_extra_boolean_and_duplicates(self):
        context = self.context()
        changes = ({"vmID": str(uuid.uuid4())}, {"sessionID": str(uuid.uuid4())}, {"nonce": str(uuid.uuid4())},
                   {"phase": "installed-boot-2"}, {"action": "arbitrary-command"}, {"extra": True},
                   {"schemaVersion": True}, {"scope": "other-fixture"})
        for change in changes:
            with self.subTest(change=change):
                context.attempted = False  # Independent request admission case, not a production retry.
                self.request(context, {**context.challenge, **change})
                before = context.request_file.read_bytes()
                self.rejected("recovery-request-mismatch", context.consume, self.owner)
                self.assertEqual(context.request_file.read_bytes(), before)
                self.assertEqual(self.owner.writes, [])
        context.attempted = False
        context.request_file.write_text(json.dumps(context.challenge)[:-1] + ',"action":"login-root-and-poweroff"}')
        self.rejected("metadata-duplicate-field", context.consume, self.owner)
        self.assertEqual(self.owner.writes, [])

    def test_request_aliased_nonprivate_hardlinked_and_oversize_files_never_write(self):
        context = self.context()
        target = self.root / "public-request"
        self.write(target, context.challenge)
        context.request_file.symlink_to(target)
        self.rejected("input-ancestor-invalid", context.consume, self.owner)
        self.assertTrue(context.request_file.is_symlink())
        context.request_file.unlink(); context.attempted = False
        context.request_file.hardlink_to(target)
        self.rejected("input-file-invalid", context.consume, self.owner)
        context.request_file.unlink(); context.attempted = False
        self.request(context); context.request_file.chmod(0o644)
        self.rejected("input-mode-invalid", context.consume, self.owner)
        context.attempted = False; context.request_file.chmod(0o600)
        context.request_file.write_bytes(b"p" * 1025)
        self.rejected("input-file-invalid", context.consume, self.owner)
        self.assertEqual(context.request_file.stat().st_size, 1025)
        self.assertEqual(self.owner.writes, [])

    def test_phase_namespace_and_foreign_owner_reject_without_input_or_overwriting(self):
        self.rejected("recovery-phase-invalid", proof.FixtureRecovery, self.owner, self.vm,
                      self.vm_id, self.evidence, "ordinary-live-preparation")
        occupied = self.evidence / "normal-poweroff.request.json"
        occupied.write_bytes(b"preserved public request\n")
        self.rejected("recovery-namespace-occupied", self.context)
        self.assertEqual(occupied.read_bytes(), b"preserved public request\n")
        occupied.unlink()
        context = self.context(); self.request(context)
        foreign = OwnedSerialFixture(self.executable)
        self.rejected("recovery-foreign-owner", context.consume, foreign)
        self.assertEqual(foreign.writes, []); self.assertEqual(self.owner.writes, [])

    def test_cached_login_or_root_prompt_cannot_satisfy_required_new_prompts(self):
        context = self.context(); self.request(context)
        self.owner.respond_login = False
        with self.short_prompts(context):
            self.rejected("recovery-fresh-prompt-missing", context.consume, self.owner)
        self.assertEqual(self.owner.writes, [b"\n"])
        context.attempted = False; self.owner.writes.clear(); self.owner.respond_login = True
        self.owner.stdout = b"old\nmacopenvm-lab:~# \nmacopenvm-lab login: "
        self.owner.respond_root = False
        with self.short_prompts(context):
            self.rejected("recovery-fresh-prompt-missing", context.consume, self.owner)
        self.assertEqual(self.owner.writes, [b"\n", b"root\n"])

    def test_changed_session_or_executable_and_guest_error_never_release_or_poweroff(self):
        context = self.context(); self.request(context)
        def changed(data):
            if data == b"root\n":
                self.write(self.vm / "runtime.json", {**self.history, "sessionID": str(uuid.uuid4()).upper()})
        self.owner.after_write = changed
        with self.assertRaises(proof.base.InstallationProofError):
            context.consume(self.owner)
        self.assertEqual(self.owner.writes, [b"\n", b"root\n"])
        self.assertTrue(self.owner.active)
        self.write(self.vm / "runtime.json", self.history)
        for attribute, value in (("first_error", "fixtureFailure"), ("truncated", True), ("active", False)):
            with self.subTest(attribute=attribute):
                previous = getattr(self.owner, attribute)
                setattr(self.owner, attribute, value)
                self.rejected("recovery-owner-not-active", proof.recovery_session, self.owner, self.vm, self.vm_id)
                setattr(self.owner, attribute, previous)
                self.assertEqual(self.owner.writes, [b"\n", b"root\n"])
        self.executable.chmod(0o700)
        self.executable.write_bytes(b"changed public executable\n")
        self.rejected("live-owner-executable-changed", proof.recovery_session, self.owner, self.vm, self.vm_id)
        self.assertTrue(self.owner.active)

    def test_registration_rejects_wrong_private_paths_and_directory_aliases(self):
        wrong = self.root / "other-evidence"
        wrong.mkdir(mode=0o700)
        self.rejected("recovery-evidence-path-invalid", proof.FixtureRecovery, self.owner, self.vm,
                      self.vm_id, wrong, "installed-boot-1")
        alias = self.root / ".lab" / ("agent-upgrade-" + uuid.uuid4().hex)
        alias.symlink_to(wrong, target_is_directory=True)
        self.rejected("input-ancestor-invalid", proof.FixtureRecovery, self.owner, self.vm,
                      self.vm_id, alias, "installed-boot-1")
        self.evidence.chmod(0o755)
        self.rejected("unsafe-private-directory", self.context)
        self.evidence.chmod(0o700)
        wrong_vm = self.vm.parent / "Unknown.macopenvm"
        wrong_vm.mkdir(mode=0o700)
        self.rejected("recovery-copy-path-invalid", proof.FixtureRecovery, self.owner, wrong_vm,
                      self.vm_id, self.evidence, "installed-boot-1")
        self.assertEqual(self.owner.writes, [])
        self.assertFalse((self.evidence / "recovery-challenge.json").exists())

    def test_complete_staged_rename_publication_is_pending_until_fixed_name_exists(self):
        context = self.context()
        staged = self.evidence / "request-staged-public-fixture"
        descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write((json.dumps(context.challenge) + "\n").encode())
            stream.flush(); os.fsync(stream.fileno())
        self.assertFalse(context.consume(self.owner))
        self.assertFalse(context.attempted)
        self.assertFalse(context.request_file.exists())
        staged.rename(context.request_file)  # Fixture destination is still absent; one filesystem rename.
        self.assertEqual(context.request_file.stat().st_nlink, 1)
        self.assertTrue(context.consume(self.owner))
        self.assertEqual(self.owner.writes, [b"\n", b"root\n", b"poweroff\n"])

    def test_same_named_replaced_evidence_or_copy_directory_cannot_rebind_owner(self):
        context = self.context()
        old = self.evidence.with_name("preserved-evidence")
        self.evidence.rename(old); self.evidence.mkdir(mode=0o700)
        self.request(context)
        self.rejected("recovery-directory-changed", context.consume, self.owner)
        self.assertEqual(self.owner.writes, [])
        shutil.rmtree(self.evidence); old.rename(self.evidence)
        displaced = self.vm.with_name("Preserved.macopenvm")
        self.vm.rename(displaced); self.vm.mkdir(mode=0o700)
        self.rejected("recovery-directory-changed", context.current, self.owner)
        self.assertEqual(self.owner.writes, [])
        self.assertTrue(self.owner.active)

    def test_retainer_services_request_without_stdin_and_awaits_separate_terminal_observation(self):
        context = self.context(); self.request(context)
        def after(data):
            if data == b"poweroff\n":
                self.owner.active = False  # Explicit synthetic terminal observation, not delivery inference.
        self.owner.after_write = after
        with mock.patch.object(proof.select, "select", return_value=([], [], [])), redirect_stdout(io.StringIO()):
            observed = proof.retain_actual_owner(self.owner, self.evidence, "installed-boot-1", recovery=context)
        self.assertFalse(observed.is_active)
        self.assertEqual(self.owner.writes, [b"\n", b"root\n", b"poweroff\n"])
        ack = json.loads((self.evidence / "recovery-input.json").read_bytes())
        self.assertEqual(ack, {"normalPoweroffWriteConfirmed": True, "runtimeSettlementObserved": False})
        self.assertEqual(json.loads((self.vm / "runtime-intent.json").read_bytes())["state"], "unsettled")


if __name__ == "__main__":
    unittest.main()
