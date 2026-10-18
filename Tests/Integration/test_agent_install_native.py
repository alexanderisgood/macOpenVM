# SPDX-License-Identifier: Apache-2.0
"""Private public-byte fixtures only; no keys, certificates, carriers, or VM actions."""
from contextlib import ExitStack, redirect_stdout
import io
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock
import uuid

import agent_install_native as proof


class AgentInstallNativeGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mvo-agent-guard-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.original = self.directory("original")
        self.fresh = self.directory("fresh")

    def directory(self, label):
        path = Path("/private/tmp") / ("mvo-agent-tls-" + uuid.uuid4().hex)
        path.mkdir(mode=0o700)
        self.addCleanup(self.remove_directory, path)
        for name in ("client.der", "guest.der"):
            file = path / name
            # Arbitrary public bytes exercise admission, not certificate validation.
            file.write_bytes((label + "-" + name + "\n").encode("ascii"))
            file.chmod(0o600)
        return path

    @staticmethod
    def remove_directory(path):
        if path.is_symlink():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path)

    def rejected(self, code, function, *arguments):
        with self.assertRaises(proof.InstallationProofError) as error:
            function(*arguments)
        self.assertEqual(str(error.exception), code)

    def test_distinct_private_directories_and_public_leaves_are_admitted(self):
        identities = proof.distinct_credentials(self.original, self.fresh)
        self.assertNotEqual(identities[0], identities[1])
        self.assertTrue(all(identities[2][name] != identities[3][name] for name in identities[2]))
        proof.same_credentials(self.original, self.fresh, identities)
        self.assertEqual(set(path.name for path in self.original.iterdir()), {"client.der", "guest.der"})

    def test_same_directory_is_rejected(self):
        self.rejected("reenrollment-directory-reused", proof.distinct_credentials,
                      self.original, self.original)

    def test_symlinked_directory_is_rejected(self):
        self.fresh.rename(self.base / "moved-fresh")
        self.fresh.symlink_to(self.original, target_is_directory=True)
        self.rejected("unsafe-private-directory", proof.distinct_credentials, self.original, self.fresh)

    def test_nonprivate_directory_mode_is_rejected(self):
        self.fresh.chmod(0o755)
        self.rejected("unsafe-private-directory", proof.distinct_credentials, self.original, self.fresh)

    def test_unapproved_directory_namespace_is_rejected(self):
        self.rejected("invalid-private-credentials", proof.distinct_credentials, self.original, self.base)

    def test_either_reused_public_leaf_is_rejected(self):
        for name in ("client.der", "guest.der"):
            with self.subTest(name=name):
                file = self.fresh / name
                previous = file.read_bytes()
                file.write_bytes((self.original / name).read_bytes())
                self.rejected("reenrollment-leaf-reused", proof.distinct_credentials, self.original, self.fresh)
                file.write_bytes(previous)

    def test_symlinked_public_leaf_is_rejected(self):
        file = self.fresh / "guest.der"
        file.unlink()
        file.symlink_to(self.original / "guest.der")
        with self.assertRaises(OSError):
            proof.distinct_credentials(self.original, self.fresh)

    def test_hardlinked_public_leaf_is_rejected(self):
        file = self.fresh / "client.der"
        file.unlink()
        os.link(self.original / "client.der", file)
        self.rejected("unsafe-input-file", proof.distinct_credentials, self.original, self.fresh)

    def test_changed_public_leaf_in_either_directory_is_rejected(self):
        identities = proof.distinct_credentials(self.original, self.fresh)
        for directory in (self.original, self.fresh):
            for name in ("client.der", "guest.der"):
                with self.subTest(directory=directory.name, name=name):
                    file = directory / name
                    previous = file.read_bytes()
                    file.write_bytes(previous + b"changed\n")
                    self.rejected("credential-input-changed", proof.same_credentials,
                                  self.original, self.fresh, identities)
                    file.write_bytes(previous)

    def test_replaced_directory_with_identical_public_bytes_is_rejected(self):
        identities = proof.distinct_credentials(self.original, self.fresh)
        moved = self.base / "moved-fresh"
        self.fresh.rename(moved)
        self.fresh.mkdir(mode=0o700)
        for name in ("client.der", "guest.der"):
            shutil.copyfile(moved / name, self.fresh / name)
            (self.fresh / name).chmod(0o600)
        self.rejected("credential-input-changed", proof.same_credentials,
                      self.original, self.fresh, identities)

    def test_changed_directory_mode_is_rejected(self):
        identities = proof.distinct_credentials(self.original, self.fresh)
        self.fresh.chmod(0o750)
        self.rejected("unsafe-private-directory", proof.same_credentials,
                      self.original, self.fresh, identities)

    def test_no_run_skips_all_input_and_execution_boundaries(self):
        arguments = ["agent_install_native", "--cli", str(self.base / "missing-cli"),
                     "--payload", str(self.base / "missing-payload"), "--issuer", "invalid",
                     "--credentials", str(self.base / "missing-original"),
                     "--reenrollment-credentials", str(self.base / "missing-fresh")]
        output = io.StringIO()
        with ExitStack() as stack:
            stack.enter_context(mock.patch("sys.argv", arguments))
            stack.enter_context(redirect_stdout(output))
            boundaries = [stack.enter_context(mock.patch.object(proof, name)) for name in
                          ("distinct_credentials", "code_snapshot", "source_identity", "command", "carrier", "ManagedSerial")]
            boundaries.append(stack.enter_context(mock.patch.object(proof.subprocess, "run")))
            boundaries.append(stack.enter_context(mock.patch.object(Path, "mkdir")))
            self.assertEqual(proof.main(), 0)
            for boundary in boundaries:
                boundary.assert_not_called()
        self.assertIn("SKIP: explicit --run required", output.getvalue())


if __name__ == "__main__":
    unittest.main()
