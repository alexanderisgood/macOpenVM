# SPDX-License-Identifier: Apache-2.0
"""Pure bounded parser checks; these tests never launch a worker or guest."""
import unittest
from pathlib import Path
import tempfile

from runtime_worker_loss_lab import settled_cleanup_result, strict_platform_observation
from runtime_worker_lab import save


CANONICAL = b"\n".join((
    b"mvo.platform-probe.begin version=1",
    b"mvo.platform-probe.arch=aarch64",
    b"mvo.platform-probe.setup status=Success value=1",
    b"mvo.platform-probe.secure-boot status=Success value=0",
    b"mvo.platform-probe.tcg2 status=Success present=1 active-banks=0x00000002",
    b"mvo.platform-probe.tpm-public-manufacturer=0x49424d00",
    b"mvo.platform-probe.complete setup=1 secure-boot=0",
)) + b"\n"


class RuntimeWorkerLossParserTests(unittest.TestCase):
    def test_canonical_and_incomplete(self):
        self.assertEqual(strict_platform_observation(CANONICAL)["setupMode"], 1)
        self.assertIsNone(strict_platform_observation(CANONICAL.splitlines()[0] + b"\n"))

    def test_each_duplicate_row_is_rejected(self):
        for row in CANONICAL.splitlines():
            with self.subTest(row=row), self.assertRaises(ValueError):
                strict_platform_observation(CANONICAL + row + b"\n")

    def test_contradictory_architecture_and_completion_are_rejected(self):
        for row in (b"mvo.platform-probe.arch=x86_64",
                    b"mvo.platform-probe.complete setup=0 secure-boot=1"):
            with self.subTest(row=row), self.assertRaises(ValueError):
                strict_platform_observation(CANONICAL + row + b"\n")

    def test_bound_and_encoding(self):
        with self.assertRaises(ValueError):
            strict_platform_observation(bytes(2097153))
        with self.assertRaises(UnicodeDecodeError):
            strict_platform_observation(CANONICAL + b"\xff")

    def test_embedded_matching_fields_do_not_replace_an_exact_row(self):
        for row in (b"mvo.platform-probe.setup status=Success value=1",
                    b"mvo.platform-probe.tpm-public-manufacturer=0x49424d00"):
            with self.subTest(row=row), self.assertRaises(ValueError):
                strict_platform_observation(CANONICAL.replace(row, b"mvo.platform-probe.setup bad " + row))

    def test_normal_worker_cleanup_needs_actual_matching_records(self):
        record = {"vmID": "vm", "sessionID": "session"}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.assertFalse(settled_cleanup_result(directory, record))
            save(directory / "swift-worker-result.json", {
                "status": "passed", "runtimeIntentSettled": True, "drainsFinished": True})
            save(directory / "runtime-intent.json", {"state": "settled", **record})
            save(directory / "runtime.json", {"sessionID": "session"})
            self.assertTrue(settled_cleanup_result(directory, record))
            self.assertFalse(settled_cleanup_result(directory, {"vmID": "vm", "sessionID": "other"}))
            (directory / "runtime-intent.json").unlink()
            save(directory / "runtime-intent.json", {"state": "unsettled", **record})
            self.assertFalse(settled_cleanup_result(directory, record))


if __name__ == "__main__":
    unittest.main()
