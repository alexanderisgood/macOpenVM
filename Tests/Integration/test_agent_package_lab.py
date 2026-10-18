# SPDX-License-Identifier: Apache-2.0
"""Temporary test issuer only; no VM, enrollment, or release signing authority."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import agent_package_lab as package


class AgentPackagePublisherTests(unittest.TestCase):
    def setUp(self):
        self.inputs = tempfile.TemporaryDirectory(prefix="mvo-package-input-", dir="/private/tmp")
        self.publisher = tempfile.TemporaryDirectory(prefix="mvo-package-publisher-", dir="/private/tmp")
        self.addCleanup(self.inputs.cleanup)
        self.addCleanup(self.publisher.cleanup)
        self.base = Path(self.publisher.name)
        self.a = Path(self.inputs.name) / "a"
        self.b = Path(self.inputs.name) / "b"
        self.a.write_bytes(b"public test binary A\n")
        self.b.write_bytes(b"public test binary B\n")

    def test_same_issuer_two_signed_manifests_and_no_private_material(self):
        openssl = shutil.which("openssl")
        if not openssl:
            self.skipTest("OpenSSL test issuer unavailable")
        payloads, issuer = package.publish_generations(self.a, self.b, self.base)
        self.assertEqual(len(payloads), 2)
        public = (payloads[0] / "issuer.raw").read_bytes()
        self.assertEqual(len(public), 32)
        self.assertEqual(issuer, hashlib.sha256(public).hexdigest())
        verifier = Path(self.inputs.name) / "public.der"
        verifier.write_bytes(package.SPKI_PREFIX + public)
        for payload in payloads:
            self.assertEqual((payload / "issuer.raw").read_bytes(), public)
            self.assertEqual(set(p.name for p in payload.iterdir()),
                             {"agent", "initd", "setup.sh", "SHA256SUMS", "manifest.sig", "issuer.raw"})
            signed = Path(self.inputs.name) / "verify-input"
            signed.write_bytes(package.CONTEXT + (payload / "SHA256SUMS").read_bytes())
            result = subprocess.run([openssl, "pkeyutl", "-verify", "-rawin", "-pubin",
                                     "-keyform", "DER", "-inkey", str(verifier), "-in", str(signed),
                                     "-sigfile", str(payload / "manifest.sig")], capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0)
            for file in payload.iterdir():
                self.assertEqual(file.stat().st_mode & 0o7777, 0o600)
        self.assertEqual(set(p.name for p in self.base.iterdir()), {"payload-a", "payload-b"})
        self.assertNotEqual((payloads[0] / "SHA256SUMS").read_bytes(),
                            (payloads[1] / "SHA256SUMS").read_bytes())
        for name in ("setup.sh", "initd"):
            self.assertEqual((payloads[0] / name).read_bytes(), (payloads[1] / name).read_bytes())

    def test_single_payload_api_preserves_its_return_shape(self):
        if not shutil.which("openssl"):
            self.skipTest("OpenSSL test issuer unavailable")
        payload, issuer = package.publish(self.a, self.base)
        self.assertEqual(payload, self.base / "payload")
        self.assertEqual(len(issuer), 64)
        self.assertEqual(set(p.name for p in self.base.iterdir()), {"payload"})

    def test_same_binary_is_rejected_before_any_publish(self):
        with self.assertRaises(ValueError):
            package.publish_generations(self.a, self.a, self.base)
        self.assertEqual(list(self.base.iterdir()), [])

    def test_occupied_parent_preserves_unrelated_material_before_signing(self):
        sentinel = self.base / "signed-input"
        sentinel.write_bytes(b"unrelated\n")
        with mock.patch.object(package.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                package.publish_generations(self.a, self.b, self.base)
            run.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b"unrelated\n")
        self.assertEqual(list(self.base.iterdir()), [sentinel])

    def test_partial_issuer_failure_removes_transient_key_only(self):
        def failure(arguments, **kwargs):
            key = Path(arguments[arguments.index("-out") + 1])
            key.write_bytes(b"synthetic secret fixture\n")
            return subprocess.CompletedProcess(arguments, 1)
        with mock.patch.object(package.subprocess, "run", side_effect=failure):
            with self.assertRaises(RuntimeError):
                package.publish_generations(self.a, self.b, self.base)
        self.assertEqual(set(p.name for p in self.base.iterdir()), {"payload-a", "payload-b"})
        self.assertTrue(all(not (p / "manifest.sig").exists() for p in self.base.iterdir()))

    def test_second_signature_failure_preserves_first_payload_and_removes_issuer_key(self):
        if not shutil.which("openssl"):
            self.skipTest("OpenSSL test issuer unavailable")
        real_run = subprocess.run
        calls = 0
        def fail_second_signature(arguments, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 4:
                return subprocess.CompletedProcess(arguments, 1)
            return real_run(arguments, **kwargs)
        with mock.patch.object(package.subprocess, "run", side_effect=fail_second_signature):
            with self.assertRaises(RuntimeError):
                package.publish_generations(self.a, self.b, self.base)
        self.assertEqual(calls, 4)
        self.assertEqual(set(p.name for p in self.base.iterdir()), {"payload-a", "payload-b"})
        self.assertEqual((self.base / "payload-a/manifest.sig").stat().st_size, 64)
        self.assertEqual((self.base / "payload-a/issuer.raw").stat().st_size, 32)
        self.assertFalse((self.base / "payload-b/manifest.sig").exists())
        self.assertFalse((self.base / "payload-b/issuer.raw").exists())


if __name__ == "__main__":
    unittest.main()
