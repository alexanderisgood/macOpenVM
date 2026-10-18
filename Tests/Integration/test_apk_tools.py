# SPDX-License-Identifier: Apache-2.0
"""Pure tool-probe framing fixtures; never execute a guest, APK or target helper."""
import unittest

from support_media_live import DeliveryFailure, parse_tool_probe


class APKToolsProbeTests(unittest.TestCase):
    valid = b"mvo-tools.probe=0\nmvo-tools.dependencies=0\n"

    def reject(self, log):
        with self.assertRaisesRegex(DeliveryFailure, "^apkToolsObservation$"):
            parse_tool_probe(log)

    def test_exact_unique_success_rows(self):
        self.assertEqual(parse_tool_probe(self.valid),
                         dict(probeSucceeded=True, dependenciesSucceeded=True))

    def test_ordinary_diagnostics_and_embedded_prefix_do_not_become_rows(self):
        log = (b"checking target helpers\nnote: mvo-tools.probe=1\n"
               + self.valid + b"diagnostic complete\n")
        self.assertEqual(parse_tool_probe(log),
                         dict(probeSucceeded=True, dependenciesSucceeded=True))

    def test_missing_either_required_row_rejects(self):
        for log in (b"", b"mvo-tools.probe=0\n", b"mvo-tools.dependencies=0\n"):
            with self.subTest(log=log):
                self.reject(log)

    def test_duplicate_success_and_contradictory_rows_reject(self):
        for extra in (b"mvo-tools.probe=0\n", b"mvo-tools.dependencies=0\n",
                      b"mvo-tools.probe=1\n", b"mvo-tools.dependencies=1\n"):
            with self.subTest(extra=extra):
                self.reject(self.valid + extra)

    def test_unknown_or_malformed_prefixed_rows_reject(self):
        for extra in (b"mvo-tools.other=0\n", b"mvo-tools.probe\n",
                      b"mvo-tools.dependencies=00\n", b"mvo-tools.probe=0 extra\n"):
            with self.subTest(extra=extra):
                self.reject(self.valid + extra)

    def test_nonzero_values_reject_without_duplicate_rows(self):
        for log in (self.valid.replace(b"probe=0", b"probe=1"),
                    self.valid.replace(b"dependencies=0", b"dependencies=125")):
            with self.subTest(log=log):
                self.reject(log)

    def test_controls_and_nonascii_in_diagnostics_reject(self):
        for diagnostic in (b"bad\x00line\n", b"bad\tline\n", b"bad\x7fline\n",
                           b"bad\x1bline\n", b"bad\xffline\n"):
            with self.subTest(diagnostic=diagnostic):
                self.reject(diagnostic + self.valid)
        self.reject(self.valid.replace(b"\n", b"\r\n"))

    def test_output_bound_has_valid_control_at_limit(self):
        at_limit = b"x" * (32768 - len(self.valid) - 1) + b"\n" + self.valid
        self.assertEqual(len(at_limit), 32768)
        self.assertTrue(parse_tool_probe(at_limit)["probeSucceeded"])
        self.reject(b"x" + at_limit)


if __name__ == "__main__":
    unittest.main()
