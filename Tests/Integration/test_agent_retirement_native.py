# SPDX-License-Identifier: Apache-2.0
"""Public filesystem and admission fixtures; no agent, guest, keys or sockets."""
from contextlib import redirect_stdout
from dataclasses import replace
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import uuid

import agent_upgrade_native as proof


class AgentRetirementNativeGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mvo-retirement-guard-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.identifier = "756a151a-96a3-4b02-9ec7-ff64bbda56f5"

    def rejected(self, code, function, *args, **kwargs):
        with self.assertRaises(proof.base.InstallationProofError) as error:
            function(*args, **kwargs)
        self.assertEqual(str(error.exception), code)

    def test_retirement_is_explicit_and_uuid_canonical_before_any_input_read(self):
        self.assertEqual(proof.selected_profile(), proof.historical_profile())
        self.assertIs(proof.selected_profile(True, self.identifier), proof.RETIREMENT_PROFILE)
        for identifier in (None, "", self.identifier.upper(), "0" * 32,
                           "00000000-0000-0000-0000-000000000000", self.identifier + "\n"):
            with self.subTest(identifier=identifier):
                self.rejected("explicit-canonical-retirement-id-required", proof.selected_profile, True, identifier)
        self.rejected("retirement-id-without-profile", proof.selected_profile, False, self.identifier)
        inputs = ["--run", "--payload-a", "/missing-a", "--payload-b", "/missing-b",
                  "--issuer", "0" * 64, "--credentials", "/missing-enrollment"]
        with mock.patch.object(proof, "admit_inputs") as admit:
            self.rejected("explicit-canonical-retirement-id-required", proof.main,
                          inputs + ["--retire-failed"])
            self.rejected("retirement-id-without-profile", proof.main,
                          inputs + ["--retirement-id", self.identifier])
            admit.assert_not_called()

    def test_no_run_retirement_mode_never_inspects_or_makes_inputs(self):
        with mock.patch.object(proof, "admit_inputs") as admit, \
                mock.patch.object(proof, "code_snapshot") as snapshot, \
                mock.patch.object(proof, "ManagedSerial") as owner, \
                mock.patch.object(Path, "mkdir") as mkdir, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(proof.main(["--retire-failed", "--retirement-id", "invalid"]), 0)
            for boundary in (admit, snapshot, owner, mkdir):
                boundary.assert_not_called()
        self.assertIn("SKIP", output.getvalue())

    def test_profiles_cannot_mix_historical_cli_issuer_or_generation_pins(self):
        old = proof.historical_profile()
        new = proof.RETIREMENT_PROFILE
        self.assertEqual(old.manager_limit, 65536)
        self.assertEqual(new.manager_limit, 131072)
        self.assertNotEqual(old.manifest_pins, new.manifest_pins)
        self.assertNotEqual(old.manager_sha256, new.manager_sha256)
        with mock.patch.object(proof, "plain_file_identity") as read:
            for cli, issuer in ((old.cli, new.issuer_sha256), (new.cli, old.issuer_sha256)):
                self.rejected("unapproved-cli-or-issuer", proof.admit_inputs, cli, self.root,
                              self.root, issuer, self.root, new)
            read.assert_not_called()

    def test_prepare_arguments_keep_historical_shape_and_bind_retirement_identity(self):
        marker = "mvo-agent-upgrade-" + "a" * 32
        vm_id = "7412dc9e-3d08-4199-ac0a-93b1c6aa2cb4"
        historical = proof.preparation_arguments(marker, vm_id, proof.historical_profile())
        current = proof.preparation_arguments(marker, vm_id, proof.RETIREMENT_PROFILE, self.identifier)
        self.assertEqual(len(historical), 6)
        self.assertEqual(historical[2:4], proof.historical_profile().manifest_pins)
        self.assertEqual(len(current), 8)
        self.assertEqual(current[2:4], proof.RETIREMENT_PROFILE.manifest_pins)
        self.assertEqual(current[-2:], ("retirement-v1", self.identifier))
        self.rejected("retirement-id-without-profile", proof.preparation_arguments,
                      marker, vm_id, proof.historical_profile(), self.identifier)
        self.rejected("guest-argument-invalid", proof.preparation_arguments,
                      marker + ";input", vm_id, proof.RETIREMENT_PROFILE, self.identifier)

    def fixture_inputs(self):
        cli = self.root / "cli"
        cli.write_bytes(b"public executable fixture\n"); cli.chmod(0o500)
        credentials = Path("/private/tmp") / ("mvo-agent-tls-" + uuid.uuid4().hex)
        credentials.mkdir(mode=0o700)
        self.addCleanup(shutil.rmtree, credentials)
        for name in ("guest.pem", "guest-key.pem", "ca.pem", "guest.der", "client.der", "client-key.der", "ca.der"):
            path = credentials / name
            path.write_bytes(b"public dummy credential fixture\n"); path.chmod(0o600)
        manager = b"# public manager fixture\n".ljust(131072, b" ")
        payloads, pins = [], []
        for label in ("a", "b"):
            directory = self.root / label
            directory.mkdir(mode=0o700)
            for name, data in (("agent", ("public agent " + label).encode()), ("initd", b"public initd"),
                               ("setup.sh", manager), ("issuer.raw", b"i" * 32), ("manifest.sig", b"s" * 64)):
                path = directory / name
                path.write_bytes(data); path.chmod(0o600)
            manifest = b"".join((hashlib.sha256((directory / name).read_bytes()).hexdigest()
                                 + "  " + name + "\n").encode() for name in ("agent", "initd", "setup.sh"))
            (directory / "SHA256SUMS").write_bytes(manifest)
            (directory / "SHA256SUMS").chmod(0o600)
            payloads.append(directory); pins.append(hashlib.sha256(manifest).hexdigest())
        profile = replace(proof.RETIREMENT_PROFILE, cli=cli, cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                          manifest_pins=tuple(pins), manager_sha256=hashlib.sha256(manager).hexdigest())
        record = cli.parent / "build-record.json"
        record.write_text(json.dumps({"schemaVersion": 1, "cliSHA256": profile.cli_sha256,
                                      "sources": {"files": [{"path": "GuestAgent/Host/AgentPackageVerifier.swift",
                                      "sha256": "d31f0a29d39c75248dd3d589a02f5949b9269c07d583b976c6809f32181c29ba"}]}}))
        record.chmod(0o600)
        return cli, payloads, credentials, profile, hashlib.sha256(record.read_bytes()).hexdigest()

    def test_actual_files_enforce_only_manager_128k_and_preserve_other_limits(self):
        cli, payloads, credentials, profile, record_pin = self.fixture_inputs()
        def verified(_cli, arguments):
            # Cryptographic verification is injected; actual namespace, bytes,
            # modes, links, file bounds and independently approved pins are exercised.
            index = payloads.index(Path(arguments[2]))
            return json.dumps({"manifestSHA256": profile.manifest_pins[index], "filesVerified": 3,
                               "issuerSHA256": profile.issuer_sha256})
        with mock.patch.object(proof, "RETIREMENT_BUILD_RECORD_SHA256", record_pin), \
                mock.patch.object(proof.base, "command", side_effect=verified):
            identity = proof.admit_inputs(cli, *payloads, profile.issuer_sha256, credentials, profile)
            self.assertEqual(len(identity[0]), 2)
            for path, maximum in ((payloads[0] / "setup.sh", 131072), (payloads[0] / "initd", 16384),
                                  (payloads[0] / "SHA256SUMS", 512), (credentials / "guest-key.pem", 65536)):
                with self.subTest(name=path.name):
                    before = path.read_bytes()
                    path.write_bytes(b"p" * (maximum + 1))
                    self.rejected("input-file-invalid", proof.admit_inputs,
                                  cli, *payloads, profile.issuer_sha256, credentials, profile)
                    self.assertEqual(path.read_bytes(), b"p" * (maximum + 1))
                    path.write_bytes(before)
            self.rejected("input-file-invalid", proof.admit_inputs,
                          cli, *payloads, profile.issuer_sha256, credentials, replace(profile, manager_limit=65536))
            wrong_pin = replace(profile, manifest_pins=("0" * 64, profile.manifest_pins[1]))
            self.rejected("input-hash-invalid", proof.admit_inputs,
                          cli, *payloads, profile.issuer_sha256, credentials, wrong_pin)
            after = proof.admit_inputs(cli, *payloads, profile.issuer_sha256, credentials, profile)
            self.assertNotEqual(after, identity)  # Rewrites remain detectable even when bytes are restored.
            self.assertEqual(after[1][2], identity[1][2])
            self.rejected("approved-inputs-changed", proof.same_inputs, cli, *payloads,
                          profile.issuer_sha256, credentials, identity, profile)

    def test_current_cli_record_requires_exact_pin_and_unique_verifier_association(self):
        cli, payloads, credentials, profile, record_pin = self.fixture_inputs()
        record = cli.parent / "build-record.json"
        with mock.patch.object(proof, "RETIREMENT_BUILD_RECORD_SHA256", "0" * 64), \
                mock.patch.object(proof.base, "command") as command:
            self.rejected("input-hash-invalid", proof.admit_inputs,
                          cli, *payloads, profile.issuer_sha256, credentials, profile)
            command.assert_not_called()
        original = json.loads(record.read_bytes())
        for changed in ({**original, "schemaVersion": True}, {**original, "cliSHA256": "0" * 64},
                        {**original, "sources": {"files": original["sources"]["files"] * 2}}):
            record.write_text(json.dumps(changed))
            with self.subTest(changed=changed), \
                    mock.patch.object(proof, "RETIREMENT_BUILD_RECORD_SHA256", hashlib.sha256(record.read_bytes()).hexdigest()), \
                    mock.patch.object(proof.base, "command") as command:
                code = ("retirement-verifier-source-mismatch" if changed["sources"] != original["sources"]
                        else "retirement-cli-build-mismatch")
                self.rejected(code, proof.admit_inputs, cli, *payloads,
                              profile.issuer_sha256, credentials, profile)
                command.assert_not_called()

    def observations(self, boot):
        rows = {"exit": "0", "phase": "complete", "normalRoot": "1", "accountsPreserved": "1",
                "identityPreserved": "1", "retirement.id": self.identifier,
                "retirementConfirmed": "1", "currentAPreserved": "1", "archivedBPreserved": "1",
                "cohortPreserved": "1", "retirementKernelLockPreserved": "1"}
        if boot == 1: rows.update({"install.exit": "0", "upgrade.exit": "0"})
        if boot == 2: rows.update({"rollback.exit": "0", "retire.exit": "0", "serviceStopped": "1"})
        return rows

    def test_retirement_and_cold_boot_require_all_matching_witnesses(self):
        for boot in (1, 2, 3):
            rows = self.observations(boot)
            proof.validate_boot_observations(rows, boot, proof.RETIREMENT_PROFILE, self.identifier)
        for boot in (2, 3):
            rows = self.observations(boot)
            for key in ("retirement.id", "retirementConfirmed", "currentAPreserved", "archivedBPreserved",
                        "cohortPreserved", "retirementKernelLockPreserved"):
                with self.subTest(boot=boot, key=key):
                    self.rejected("retirement-evidence-missing", proof.validate_boot_observations,
                                  {k: v for k, v in rows.items() if k != key}, boot,
                                  proof.RETIREMENT_PROFILE, self.identifier)
            self.rejected("retirement-evidence-missing", proof.validate_boot_observations,
                          {**rows, "retirement.id": "cf522a9d-698d-470a-a4bf-ed2e1c535fe6"}, boot,
                          proof.RETIREMENT_PROFILE, self.identifier)
        for changes in ({"retire.exit": "1"}, {"serviceStopped": "0"}, {"serviceStopped": True}):
            self.rejected("retirement-stop-not-confirmed", proof.validate_boot_observations,
                          {**self.observations(2), **changes}, 2, proof.RETIREMENT_PROFILE, self.identifier)

    def test_failed_phase_is_not_relabelled_by_complete_archive_flags(self):
        for phase in ("retire-failed-b", "post-retirement-cold-a", "normal-installed-boot"):
            self.rejected("guest-generation-observation-failed", proof.validate_boot_observations,
                          {**self.observations(3), "phase": phase}, 3, proof.RETIREMENT_PROFILE, self.identifier)
        self.rejected("guest-generation-observation-failed", proof.validate_boot_observations,
                      {**self.observations(3), "exit": "1"}, 3, proof.RETIREMENT_PROFILE, self.identifier)
        historical = {**self.observations(3), "failedBPreserved": "1"}
        proof.validate_boot_observations(historical, 3, proof.historical_profile())
        self.rejected("failed-generation-evidence-missing", proof.validate_boot_observations,
                      self.observations(3), 3, proof.historical_profile())

    def execute_config_case(self, lines):
        (self.root / "config").write_text("\n".join(lines) + "\n")
        source = proof.GUEST_SCRIPT.read_text()
        # Execute the actual function definitions and boot configuration case.
        # No prepare/boot body, guest command, service function or trap is run.
        definitions = source[:source.index('if [ "$mode" = prepare ]; then')]
        start = source.index('case "$(awk \'END{print NR}\' "$state/config")" in')
        end = source.index('\nesac\n', start) + len('\nesac\n')
        script = (definitions + '\nstate=$2\n' + source[start:end]
                  + '\nprintf "%s:%s\\n" "$manager_limit" "$retirement_id"\n')
        return subprocess.run(["/bin/sh", "-eu", "-c", script, "retirement-config-fixture", "fixture", str(self.root)],
                              cwd=self.root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=5, close_fds=True)

    def test_actual_shell_config_parser_accepts_historical_and_retirement_branches(self):
        public = ["mvo-agent-upgrade-" + "a" * 32, "7412dc9e-3d08-4199-ac0a-93b1c6aa2cb4",
                  "a" * 64, "b" * 64, "82f313c7-975d-42e5-a789-b7c8ff414521", "ABCD-EF12"]
        historical = self.execute_config_case(public)
        self.assertEqual(historical.returncode, 0, historical.stderr.decode())
        self.assertEqual(historical.stdout, b"65536:\n")
        retirement = self.execute_config_case(public + ["retirement-v1", self.identifier])
        self.assertEqual(retirement.returncode, 0, retirement.stderr.decode())
        self.assertEqual(retirement.stdout, ("131072:" + self.identifier + "\n").encode())

    def test_actual_shell_config_parser_rejects_partial_extra_wrong_profile_and_uuid(self):
        public = ["public"] * 6
        cases = (public[:5], public + ["retirement-v1"], public + ["wrong-profile", self.identifier],
                 public + ["retirement-v1", self.identifier, "extra"],
                 public + ["retirement-v1", self.identifier.upper()],
                 public + ["retirement-v1", "00000000-0000-0000-0000-000000000000"],
                 public + ["retirement-v1", "invalid"])
        for lines in cases:
            with self.subTest(lines=lines):
                refused = self.execute_config_case(lines)
                self.assertNotEqual(refused.returncode, 0)
                self.assertEqual(refused.stdout, b"")


if __name__ == "__main__":
    unittest.main()
