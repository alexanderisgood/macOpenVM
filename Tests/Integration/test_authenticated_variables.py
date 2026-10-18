# SPDX-License-Identifier: Apache-2.0
"""Fail-closed interpretation of guest-reported security evidence."""

import unittest

import authenticated_variables_lab as probe
import windows_efi_probe as lab


def transcript(failure=False):
    lines = [b"mvo.auth-variable.begin version=1"]
    for name in probe.CASES:
        expected = 0 if name in probe.CASES[:3] or name == probe.CASES[-1] else 0x800000000000001a
        bad = failure and name == "equal-replay"
        lines.append((f"mvo.auth-variable.case name={name} status=0x{0 if bad else expected:016x} "
                      f"expected=0x{expected:016x} readback=1 mode=1 passed={int(not bad)}").encode())
    lines.append(f"mvo.auth-variable.complete cases=11 failures={int(failure)}".encode())
    return b"\r\n".join(lines) + b"\r\n"


class AuthenticatedVariablesTests(unittest.TestCase):
    def test_complete_positive_and_observed_policy_failure(self):
        self.assertTrue(probe.observe(transcript())["allPassed"])
        result = probe.observe(transcript(True))
        self.assertFalse(result["allPassed"])
        self.assertEqual(result["failures"], 1)
        self.assertEqual(result["cases"][8]["status"], "0x0")

    def test_partial_stream_is_not_completion(self):
        data = transcript()
        for length in (0, 17, 200, data.index(b"mvo.auth-variable.complete")):
            self.assertIsNone(probe.observe(data[:length]))

    def test_forged_policy_or_assertion_rejected(self):
        original = transcript(True)
        for data in (original.replace(b"passed=0", b"passed=1"),
                     original.replace(b"expected=0x800000000000001a", b"expected=0x0000000000000000"),
                     transcript().replace(b"readback=1", b"readback=0", 1),
                     transcript().replace(b"mode=1", b"mode=0", 1)):
            with self.subTest(data=data), self.assertRaises(lab.ProbeFailure):
                probe.observe(data)

    def test_duplicate_reordered_and_missing_cases_rejected(self):
        lines = transcript().splitlines(keepends=True)
        for data in (b"".join(lines[:3] + [lines[2]] + lines[3:]),
                     b"".join([lines[0], lines[2], lines[1], *lines[3:]]),
                     b"".join(lines[:3] + lines[4:]),
                     transcript() + lines[-1]):
            with self.subTest(data=data), self.assertRaises(lab.ProbeFailure):
                probe.observe(data)

    def test_count_failure_and_partial_line_rejected(self):
        for data in (transcript(True).replace(b"failures=1", b"failures=0"),
                     transcript().replace(b"cases=11", b"cases=10"),
                     transcript().replace(b"status=0x0000000000000000", b"status=0x0", 1),
                     b"mvo.auth-variable.failure stage=inputs status=bad\n"):
            with self.subTest(data=data), self.assertRaises(lab.ProbeFailure):
                probe.observe(data)


if __name__ == "__main__":
    unittest.main()
