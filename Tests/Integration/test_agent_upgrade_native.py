# SPDX-License-Identifier: Apache-2.0
"""Native-runner admission guards using public dummy bytes; no key or VM actions."""
from contextlib import ExitStack, redirect_stdout
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

import agent_upgrade_native as proof
from managed_serial import ManagedSerialError


class AgentUpgradeNativeGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mvo-upgrade-guard-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.credentials = Path("/private/tmp") / ("mvo-agent-tls-" + uuid.uuid4().hex)
        self.credentials.mkdir(mode=0o700)
        self.addCleanup(shutil.rmtree, self.credentials)
        for name in ("guest.pem", "guest-key.pem", "ca.pem", "guest.der", "client.der", "client-key.der", "ca.der"):
            path = self.credentials / name
            path.write_bytes(("public dummy fixture " + name + "\n").encode())
            path.chmod(0o600)

    def rejected(self, code, operation, *arguments, **kwargs):
        with self.assertRaises(proof.base.InstallationProofError) as error:
            operation(*arguments, **kwargs)
        self.assertEqual(str(error.exception), code)

    def test_no_run_skips_every_input_and_mutation_boundary(self):
        output = io.StringIO()
        with ExitStack() as stack:
            stack.enter_context(redirect_stdout(output))
            calls = [stack.enter_context(mock.patch.object(proof, name)) for name in
                     ("admit_inputs", "code_snapshot", "carrier_generations", "ManagedSerial")]
            calls += [stack.enter_context(mock.patch.object(proof.base, name)) for name in
                      ("source_identity", "command")]
            calls.append(stack.enter_context(mock.patch.object(Path, "mkdir")))
            self.assertEqual(proof.main(["--cli", "/missing-cli", "--credentials", "/missing-input"]), 0)
            for call in calls:
                call.assert_not_called()
        self.assertIn("SKIP: explicit --run required", output.getvalue())

    def test_run_requires_all_explicit_inputs_before_admission(self):
        with mock.patch.object(proof, "admit_inputs") as admit:
            self.rejected("explicit-generation-inputs-required", proof.main, ["--run"])
            admit.assert_not_called()

    def test_wrong_cli_or_issuer_refuses_before_any_file_or_crypto_read(self):
        with mock.patch.object(proof, "plain_file_identity") as read:
            self.rejected("unapproved-cli-or-issuer", proof.admit_inputs, self.base / "wrong-cli",
                          self.base, self.base, proof.ISSUER_SHA256, self.credentials)
            self.rejected("unapproved-cli-or-issuer", proof.admit_inputs, proof.CLI_PATH,
                          self.base, self.base, "0" * 64, self.credentials)
            read.assert_not_called()

    def test_private_public_byte_credentials_are_identified_without_key_hashes(self):
        identity = proof.credential_identity(self.credentials)
        self.assertEqual(set(identity[1]), {p.name for p in self.credentials.iterdir()})
        self.assertEqual(set(identity[2]), {"client.der", "guest.der"})
        self.assertTrue(all(isinstance(value, tuple) for value in identity[1].values()))

    def test_credential_namespace_and_nonprivate_directory_refuse(self):
        self.rejected("credential-path-invalid", proof.credential_identity, self.base)
        self.credentials.chmod(0o755)
        self.rejected("unsafe-private-directory", proof.credential_identity, self.credentials)

    def test_credential_permission_drift_is_rejected(self):
        (self.credentials / "guest-key.pem").chmod(0o644)
        self.rejected("input-mode-invalid", proof.credential_identity, self.credentials)

    def test_symbolic_and_hardlinked_credential_inputs_are_rejected(self):
        selected = self.credentials / "client-key.der"
        selected.unlink()
        selected.symlink_to(self.credentials / "guest.der")
        self.rejected("input-ancestor-invalid", proof.credential_identity, self.credentials)
        selected.unlink()
        os.link(self.credentials / "guest.der", selected)
        self.rejected("input-file-invalid", proof.credential_identity, self.credentials)

    def test_file_size_hash_and_mode_admission_reject_changed_inputs(self):
        path = self.base / "input"
        path.write_bytes(b"public bytes\n")
        path.chmod(0o600)
        identity = proof.plain_file_identity(path, 100, mode=0o600)
        self.assertEqual(identity, proof.base.stamp(path.stat()))
        self.rejected("input-file-invalid", proof.plain_file_identity, path, 1)
        self.rejected("input-hash-invalid", proof.plain_file_identity, path, 100, expected_sha256="0" * 64)
        path.chmod(0o644)
        self.rejected("input-mode-invalid", proof.plain_file_identity, path, 100, mode=0o600)

    def test_same_public_bytes_in_replaced_inode_change_credential_identity(self):
        before = proof.credential_identity(self.credentials)
        path = self.credentials / "guest.der"
        data = path.read_bytes()
        path.rename(self.base / "prior-public-leaf")
        path.write_bytes(data)
        path.chmod(0o600)
        after = proof.credential_identity(self.credentials)
        self.assertNotEqual(before, after)
        self.assertEqual(before[2], after[2])

    def test_symbolic_link_in_file_ancestor_is_refused(self):
        directory = self.base / "real-parent"
        directory.mkdir(mode=0o700)
        file = directory / "input"
        file.write_bytes(b"public bytes\n")
        file.chmod(0o600)
        alias = self.base / "alias-parent"
        alias.symlink_to(directory, target_is_directory=True)
        self.rejected("input-ancestor-invalid", proof.plain_file_identity, alias / "input", 100)

    def test_present_or_dangling_intent_is_preserved_and_refused(self):
        proof.initial_intent_absent(self.base)
        intent = self.base / "runtime-intent.json"
        intent.write_bytes(b"unrelated record\n")
        self.rejected("initial-intent-present", proof.initial_intent_absent, self.base)
        self.assertEqual(intent.read_bytes(), b"unrelated record\n")
        intent.unlink()
        intent.symlink_to(self.base / "missing")
        self.rejected("initial-intent-present", proof.initial_intent_absent, self.base)
        self.assertTrue(intent.is_symlink())

    def test_present_intent_prevents_selection_mutation_before_cli_invocation(self):
        intent = self.base / "runtime-intent.json"
        intent.write_bytes(b"preserve uncertain owner\n")
        with mock.patch.object(proof.base, "command") as command:
            self.rejected("initial-intent-present", proof.change_vm_selection,
                          proof.CLI_PATH, self.base, ["detach-support-media", "--directory", str(self.base)])
            command.assert_not_called()
        self.assertEqual(intent.read_bytes(), b"preserve uncertain owner\n")

    def owner_metadata(self):
        vm_id = str(uuid.uuid4()).upper()
        session = str(uuid.uuid4()).upper()
        for name, value in (("configuration.json", {"id": vm_id}),
                            ("runtime.json", {"sessionID": session, "snapshot": {"state": "stopped", "backendActive": False, "outcome": "guestStopped"}}),
                            ("runtime-intent.json", {"schemaVersion": 1, "vmID": vm_id, "sessionID": session, "state": "settled"})):
            path = self.base / name
            path.write_text(json.dumps(value))
            path.chmod(0o600)
        lock = self.base / "writer.lock"
        lock.touch(mode=0o600)
        observation = SimpleNamespace(started=True, stdout_eof=True, stderr_eof=True,
                                      drains_finished=True, pipes_closed=True, transcripts_closed=True)
        return vm_id, session, lock, observation

    def test_completion_checks_real_writer_exclusion_and_matching_recorded_profile(self):
        vm_id, session, lock, observation = self.owner_metadata()
        with mock.patch.object(proof.base, "complete_owner", return_value=observation):
            with lock.open("rb") as holder:
                fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    proof.complete_generation_owner(object(), self.base, vm_id, session)
            receipt = proof.complete_generation_owner(object(), self.base, vm_id, session)
        self.assertTrue(receipt["kernelWriterLeaseAvailable"])
        self.assertEqual(receipt["runtimeIntentProfile"], "recordedSettled")
        self.assertTrue(receipt["recordedOwnershipQualified"])

    def test_wrong_session_and_unfinished_drains_prevent_completion(self):
        vm_id, session, _, observation = self.owner_metadata()
        with mock.patch.object(proof.base, "complete_owner", return_value=observation):
            self.rejected("owner-history-identity-changed", proof.complete_generation_owner,
                          object(), self.base, vm_id, str(uuid.uuid4()).upper())
            observation.drains_finished = False
            self.rejected("owner-drains-unsettled", proof.complete_generation_owner,
                          object(), self.base, vm_id, session)

    def test_recorded_settlement_refuses_missing_foreign_unsettled_and_extra_fields(self):
        vm_id, session, _, observation = self.owner_metadata()
        path = self.base / "runtime-intent.json"
        valid = json.loads(path.read_text())
        cases = ({**valid, "state": "unsettled"}, {**valid, "vmID": str(uuid.uuid4()).upper()},
                 {**valid, "sessionID": str(uuid.uuid4()).upper()}, {**valid, "schemaVersion": True},
                 {**valid, "extra": "preserve"})
        with mock.patch.object(proof.base, "complete_owner", return_value=observation):
            for value in cases:
                with self.subTest(value=value):
                    path.write_text(json.dumps(value))
                    before = path.read_bytes()
                    self.rejected("recorded-intent-mismatch", proof.complete_generation_owner,
                                  object(), self.base, vm_id, session)
                    self.assertEqual(path.read_bytes(), before)
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                proof.complete_generation_owner(object(), self.base, vm_id, session)

    def test_duplicate_recorded_identity_cannot_use_last_json_field(self):
        vm_id, session, _, _ = self.owner_metadata()
        path = self.base / "runtime-intent.json"
        path.write_text('{"schemaVersion":1,"vmID":"' + vm_id + '","sessionID":"' + session
                        + '","state":"unsettled","state":"settled"}')
        self.rejected("metadata-duplicate-field", proof.recorded_intent,
                      self.base, vm_id, session, "settled")

    def test_final_boot_cannot_qualify_active_pending_or_numeric_false_history(self):
        vm_id, session, _, observation = self.owner_metadata()
        path = self.base / "runtime.json"
        valid = json.loads(path.read_text())
        for change in ({"backendActive": True}, {"backendActive": 0}, {"operation": "stop"},
                       {"operation": None}, {"outcome": "forcedStopped"}):
            with self.subTest(change=change), mock.patch.object(proof.base, "complete_owner", return_value=observation):
                value = {**valid, "snapshot": {**valid["snapshot"], **change}}
                path.write_text(json.dumps(value))
                self.rejected("owner-terminal-history-invalid", proof.complete_generation_owner,
                              object(), self.base, vm_id, session)

    def test_generation_observations_admit_only_the_exact_support_label_with_underscores(self):
        owner = mock.Mock()
        marker = "mvo-fixture.boot1"
        owner.snapshot.return_value = SimpleNamespace(stdout=(marker + ".support.label=MVO_AGENT_ABA\n"
                                                             + marker + ".upgrade.exit=0\n").encode())
        self.assertEqual(proof.generation_rows(owner, marker), {"support.label": "MVO_AGENT_ABA", "upgrade.exit": "0"})
        for line in ("support.label=MVO_AGENT_OTHER", "upgrade.exit=bad_value", "support.label=MVO_AGENT_ABA\n"
                     + marker + ".support.label=MVO_AGENT_ABA"):
            with self.subTest(line=line):
                owner.snapshot.return_value = SimpleNamespace(stdout=(marker + "." + line + "\n").encode())
                self.rejected("invalid-guest-observation", proof.generation_rows, owner, marker)

    def test_next_operation_requires_the_actual_previous_completion_and_unchanged_records(self):
        vm_id, session, _, observation = self.owner_metadata()
        with mock.patch.object(proof.base, "complete_owner", return_value=observation):
            receipt = proof.complete_generation_owner(object(), self.base, vm_id, session)
        proof.admit_next_operation(self.base, receipt)
        with mock.patch.object(proof.base, "command") as command:
            self.rejected("previous-owner-not-qualified", proof.change_vm_selection,
                          proof.CLI_PATH, self.base, [], {**receipt, "recordedOwnershipQualified": False})
            history = self.base / "runtime.json"
            value = json.loads(history.read_text())
            value["snapshot"]["outcome"] = "forcedStopped"
            history.write_text(json.dumps(value))
            self.rejected("previous-owner-records-changed", proof.change_vm_selection,
                          proof.CLI_PATH, self.base, [], receipt)
            command.assert_not_called()

    def test_post_spawn_error_prioritizes_the_new_actual_owner_on_later_boots(self):
        old_terminal_owner = object()
        for boot in (2, 3):
            with self.subTest(boot=boot):
                newly_started_owner = object()
                error = SimpleNamespace(owner=newly_started_owner)
                self.assertIs(proof.failure_owner(error, old_terminal_owner), newly_started_owner)

    def test_failure_without_an_attached_owner_keeps_current_custody(self):
        current = object()
        self.assertIs(proof.failure_owner(RuntimeError("fixture failure"), current), current)

    def test_launch_protects_only_owned_local_child_and_restores_parent_sigint(self):
        before = signal.getsignal(signal.SIGINT)
        # This is a short local shell fixture, not a VM. It sends SIGINT to itself.
        owner = proof.ManagedSerial(Path("/bin/sh"),
                    ["-c", "kill -INT $$; printf 'mvo.fixture.survived\\n'"],
                    cwd=self.base, artifacts=self.base, label="signal-fixture")
        self.assertIs(proof.launch_serial(owner), owner)
        observed = owner.wait(deadline=time.monotonic() + 10)
        self.assertEqual(observed.returncode, 0)
        self.assertIn(b"mvo.fixture.survived\n", observed.stdout)
        self.assertFalse(observed.is_active)
        self.assertTrue(observed.drains_finished and observed.transcripts_closed)
        self.assertEqual(signal.getsignal(signal.SIGINT), before)

    def test_launch_error_restores_parent_handler_and_attaches_actual_owner(self):
        before = signal.getsignal(signal.SIGINT)
        owner = mock.Mock()
        owner.launch.side_effect = ManagedSerialError("setupFailed", owner)
        with self.assertRaises(ManagedSerialError) as error:
            proof.launch_serial(owner)
        self.assertIs(error.exception.owner, owner)
        self.assertEqual(signal.getsignal(signal.SIGINT), before)

    def test_retention_survives_snapshot_and_receipt_errors_until_actual_terminal_state(self):
        before = signal.getsignal(signal.SIGINT)
        owner = mock.Mock()
        owner.snapshot.side_effect = [RuntimeError("private fixture snapshot timeout"),
                                      SimpleNamespace(is_active=True), SimpleNamespace(is_active=False)]
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(proof.base, "save", side_effect=OSError("fixture output failure")))
            stack.enter_context(mock.patch.object(proof.select, "select", return_value=([], [], [])))
            stack.enter_context(mock.patch.object(proof.time, "sleep"))
            stack.enter_context(redirect_stdout(io.StringIO()))
            proof.retain_actual_owner(owner, self.base, "installed-boot-2")
        self.assertEqual(owner.snapshot.call_count, 3)
        owner.kill.assert_not_called()
        owner.terminate.assert_not_called()
        self.assertEqual(signal.getsignal(signal.SIGINT), before)

    def test_result_write_failure_reports_failed_and_preserves_existing_evidence(self):
        result = {"status": "passed"}
        prior = self.base / "result.json"
        prior.write_bytes(b"unrelated preserved evidence\n")
        carrier = self.base / "private-carrier.iso"
        carrier.write_bytes(b"public dummy carrier\n")
        with self.assertRaises(FileExistsError):
            proof.publish_success(result, self.base)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(prior.read_bytes(), b"unrelated preserved evidence\n")
        self.assertEqual(carrier.read_bytes(), b"public dummy carrier\n")

    def test_success_output_failure_cannot_trigger_success_cleanup(self):
        result = {"status": "failed"}
        carrier = self.base / "private-carrier.iso"
        carrier.write_bytes(b"public dummy carrier\n")
        with mock.patch("builtins.print", side_effect=BrokenPipeError("fixture output closed")):
            with self.assertRaises(BrokenPipeError):
                proof.publish_success(result, self.base)
        self.assertEqual(result["status"], "failed")
        self.assertTrue((self.base / "result.json").is_file())
        self.assertEqual(carrier.read_bytes(), b"public dummy carrier\n")

    def test_published_success_requires_both_saved_record_and_success_output(self):
        result = {"status": "failed"}
        output = io.StringIO()
        with redirect_stdout(output):
            proof.publish_success(result, self.base)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(json.loads((self.base / "result.json").read_text())["status"], "passed")
        self.assertEqual(json.loads(output.getvalue())["status"], "passed")

    def test_capture_real_live_owner_uses_current_identity_before_terminal_wait(self):
        vm_id, session, _, _ = self.owner_metadata()
        history = self.base / "runtime.json"
        history.write_text(json.dumps({"sessionID": session, "snapshot": {"state": "running"}}))
        intent = self.base / "runtime-intent.json"
        intent.write_text(json.dumps({"schemaVersion": 1, "vmID": vm_id, "sessionID": session, "state": "unsettled"}))
        owner = proof.ManagedSerial(Path("/bin/cat"), [], cwd=self.base,
                                    artifacts=self.base, label="live-identity-fixture")
        proof.launch_serial(owner)
        try:
            live = owner.snapshot(deadline=time.monotonic() + 5)
            self.assertTrue(live.is_active)
            self.assertIsNone(live.executable_unchanged)
            self.assertEqual(proof.capture_session(owner, self.base, vm_id), session)
        finally:
            owner.close_input(deadline=time.monotonic() + 5)
            terminal = owner.wait(deadline=time.monotonic() + 10)
            self.assertEqual(terminal.returncode, 0)
            self.assertTrue(terminal.executable_unchanged)

    def test_real_public_dummy_carrier_has_identical_primary_and_joliet_labels(self):
        if not Path("/usr/bin/hdiutil").is_file():
            self.skipTest("macOS ISO construction tool unavailable")
        payloads = []
        pins = []
        for label in ("a", "b"):
            payload = self.base / ("payload-" + label)
            payload.mkdir(mode=0o700)
            for name in ("agent", "initd", "setup.sh"):
                (payload / name).write_bytes(("public dummy " + label + " " + name + "\n").encode())
            manifest = "".join(hashlib.sha256((payload / name).read_bytes()).hexdigest()
                               + "  " + name + "\n" for name in ("agent", "initd", "setup.sh"))
            (payload / "SHA256SUMS").write_text(manifest)
            pins.append(hashlib.sha256(manifest.encode()).hexdigest())
            payloads.append(payload)
        image, _ = proof.carrier_generations(self.credentials, *payloads, str(uuid.uuid4()))
        with mock.patch.object(proof, "MANIFEST_PINS", tuple(pins)):
            catalog = proof.public_generation_carrier_catalog(image)
        self.assertEqual(catalog["volumeLabel"], proof.VOLUME_LABEL)
        self.assertFalse(catalog["enrollmentTraversed"])
        with image.open("rb") as stream:
            stream.seek(16 * 2048)
            primary = stream.read(2048)
            supplementary = stream.read(2048)
        self.assertEqual(primary[40:72].decode("ascii").rstrip(" \x00"), proof.VOLUME_LABEL)
        self.assertEqual(supplementary[40:72].decode("utf-16-be").rstrip(" \x00"), proof.VOLUME_LABEL)


if __name__ == "__main__":
    unittest.main()
