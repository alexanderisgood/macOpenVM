# SPDX-License-Identifier: Apache-2.0
"""Pure bounded fixtures for observed APK simulation output; never execute APK or a guest."""
import unittest

from support_media_live import DeliveryFailure, parse_apk_simulation


class APKSimulationParserTests(unittest.TestCase):
    versions = {"alpha": "1.0-r0", "beta": "2.0-r1"}
    valid = (b"( 1/2) Installing alpha (1.0-r0)\n"
             b"( 2/2) Installing beta (2.0-r1)\nOK: 12.5 MiB in 2 packages\n")

    def test_complete_padded_empty_selection(self):
        parsed = parse_apk_simulation(self.valid, self.versions, "empty", 0)
        self.assertEqual(parsed["scope"], "empty-target-selection")
        self.assertTrue(parsed["matchesVerifiedKit"])
        self.assertTrue(parsed["payloadsAvailable"])
        self.assertEqual([(r["name"], r["version"]) for r in parsed["changes"]],
                         list(self.versions.items()))

    def test_live_changes_do_not_claim_full_selection(self):
        output = (b"(1/2) Upgrading alpha (0.9-r0 -> 1.0-r0)\n"
                  b"(2/2) Purging legacy (1.0-r0)\nOK: 2 MiB in 8 packages\n")
        parsed = parse_apk_simulation(output, self.versions, "live", 0)
        self.assertEqual(parsed["scope"], "proposed-live-changes")
        self.assertFalse(parsed["matchesVerifiedKit"])
        self.assertEqual(parsed["changes"][0]["oldVersion"], "0.9-r0")
        self.assertIsNone(parsed["changes"][1]["version"])

    def test_missing_or_wrong_version_is_not_payload_availability(self):
        for replacement in (b"Installing beta (2.0-r2)", b"Installing gamma (2.0-r1)"):
            with self.subTest(replacement=replacement):
                output = self.valid.replace(b"Installing beta (2.0-r1)", replacement)
                parsed = parse_apk_simulation(output, self.versions, "empty", 0)
                self.assertFalse(parsed["payloadsAvailable"])
                self.assertFalse(parsed["matchesVerifiedKit"])
                self.assertEqual(len(parsed["unverifiedPayloads"]), 1)

    def test_duplicate_names_counter_gaps_and_changed_totals_reject(self):
        for output in (
                self.valid.replace(b"beta (2.0-r1)", b"alpha (1.0-r0)"),
                self.valid.replace(b"( 2/2)", b"( 1/2)"),
                self.valid.replace(b"( 2/2)", b"( 2/3)"),
                self.valid.replace(b"in 2 packages", b"in 3 packages")):
            with self.subTest(output=output):
                with self.assertRaisesRegex(DeliveryFailure, "^apkSimulationOutput$"):
                    parse_apk_simulation(output, self.versions, "empty", 0)

    def test_unknown_or_tagged_rows_and_trailing_output_reject(self):
        for output in (b"unexpected output\n" + self.valid,
                       self.valid.replace(b"alpha (", b"alpha@foreign ("),
                       self.valid + b"(3/3) Installing extra (1-r0)\n"):
            with self.subTest(output=output):
                with self.assertRaisesRegex(DeliveryFailure, "^apkSimulationOutput$"):
                    parse_apk_simulation(output, self.versions, "empty", 0)

    def test_nonzero_status_wins_over_success_looking_output(self):
        parsed = parse_apk_simulation(self.valid, self.versions, "empty", 1)
        self.assertEqual(parsed["observation"], "solver-failed")
        self.assertFalse(parsed["solverSucceeded"])
        self.assertFalse(parsed["payloadsAvailable"])
        self.assertEqual(parsed["changes"], [])

    def test_bounded_lines_and_output_reject(self):
        for output in (b"x" * 32769, b"x" * 513 + b"\n", b"\n" * 513):
            with self.subTest(size=len(output)):
                with self.assertRaisesRegex(DeliveryFailure, "^apkSimulationOutput$"):
                    parse_apk_simulation(output, self.versions, "empty", 0)


if __name__ == "__main__":
    unittest.main()
