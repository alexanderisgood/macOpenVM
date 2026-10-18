# SPDX-License-Identifier: Apache-2.0
"""Interpret firmware image-policy evidence without trusting its pass assertions."""

import unittest

import image_verification_lab as probe
import windows_efi_probe as lab


# These expected scenarios are stated independently of the decoder's case table.
SCENARIOS = (
    ("setup-unsigned", True, 1),
    ("setup-altered", True, 1),
    ("trusted-before", True, 0),
    ("unsigned-user", False, 0),
    ("altered-user", False, 0),
    ("trusted-after", True, 0),
    ("unrevoked-before", True, 0),
    ("revoked-signed", False, 0),
    ("unrevoked-after", True, 0),
)
DENIED = 0x800000000000000F


def execution_witness(setup):
    """Public observations made by the original application after entry."""
    return [
        b"mvo.platform-probe.begin version=1",
        b"mvo.platform-probe.arch=aarch64",
        f"mvo.platform-probe.setup status=Success value={setup}".encode(),
        f"mvo.platform-probe.secure-boot status=Success value={1 - setup}".encode(),
        b"mvo.platform-probe.tcg2 status=Success present=1 active-banks=0x0000000F",
        b"mvo.platform-probe.tpm-public-manufacturer=0x49424d00",
        f"mvo.platform-probe.complete setup={setup} secure-boot={1 - setup}".encode(),
    ]


def case_lines(name, allow, setup, changes=None):
    values = {"status": 0 if allow else DENIED, "handle": int(allow),
              "start": 0, "mode": 1, "cleanup": 0, "passed": 1}
    values.update(changes or {})
    lines = [
        f"mvo.image-verification.begin-case name={name}".encode(),
        (f"mvo.image-verification.load name={name} status=0x{values['status']:016x} "
         f"handle={values['handle']}").encode(),
    ]
    # A rejected negative image is never started, even when firmware erroneously
    # accepted its LoadImage request; any such returned handle is only unloaded.
    if allow and values["status"] == 0 and values["handle"] == 1:
        if values["start"] == 0:
            lines.extend(execution_witness(setup))
        lines.append((f"mvo.image-verification.start name={name} "
                      f"status=0x{values['start']:016x}").encode())
    lines.append((f"mvo.image-verification.end-case name={name} mode={values['mode']} "
                  f"cleanup=0x{values['cleanup']:016x} passed={values['passed']}").encode())
    return lines


def transcript(changes=None):
    changes = changes or {}
    lines = [b"mvo.image-verification.begin version=1"]
    for name, allow, setup in SCENARIOS:
        if name == "trusted-before":
            lines.extend([
                b"mvo.image-verification.update variable=PK status=Success",
                b"mvo.image-verification.update variable=KEK status=Success",
                b"mvo.image-verification.update variable=db status=Success",
            ])
        if name == "unrevoked-before":
            lines.extend([
                b"mvo.image-verification.revoke status=0x0000000000000000",
                b"mvo.image-verification.revocation-readback exact=1 bytes=76 attributes=0x00000027",
            ])
        lines.extend(case_lines(name, allow, setup, changes.get(name)))
    failures = sum(changes.get(name, {}).get("passed", 1) == 0 for name, _, _ in SCENARIOS)
    lines.append(f"mvo.image-verification.complete cases=9 failures={failures}".encode())
    return b"\r\n".join(lines) + b"\r\n"


class ImageVerificationTests(unittest.TestCase):
    def assert_rejected(self, variants):
        for index, data in enumerate(variants):
            with self.subTest(variant=index), self.assertRaises(lab.ProbeFailure):
                probe.observe(data)

    def test_complete_execution_and_selective_rejection_evidence(self):
        result = probe.observe(transcript())
        self.assertTrue(result["allPassed"])
        self.assertTrue(result["selectiveRevocationChecked"])
        self.assertEqual(result["failures"], 0)
        self.assertEqual(result["executedChildren"], 6)
        self.assertEqual([case["name"] for case in result["cases"]],
                         [name for name, _, _ in SCENARIOS])
        for case in result["cases"]:
            with self.subTest(case=case["name"]):
                self.assertTrue(case["modeVerified"])
                self.assertEqual(case["cleanupStatus"], "0x0")
                self.assertEqual(case["loadStatus"], "0x0" if case["allow"] else hex(DENIED))
                self.assertEqual(case["childExecuted"], case["allow"])
                self.assertEqual(case["startStatus"], "0x0" if case["allow"] else None)

    def test_sha256_can_be_active_alongside_other_tpm_banks(self):
        data = transcript()
        marker = b"active-banks=0x0000000F"
        self.assertEqual(data.count(marker), 6)
        # SHA256's public capability bit is 0x2. The actual native child reports
        # 0xF, so requiring that bit must not require it to be the only bank.
        for mask in (b"00000002", b"00000003", b"0000000F", b"0000000f"):
            with self.subTest(mask=mask):
                result = probe.observe(data.replace(marker, b"active-banks=0x" + mask))
                self.assertTrue(result["allPassed"])
                self.assertEqual(result["executedChildren"], 6)

    def test_missing_sha256_or_unbounded_tpm_bank_mask_is_rejected(self):
        data = transcript()
        marker = b"active-banks=0x0000000F"
        self.assert_rejected([
            data.replace(marker, b"active-banks=0x" + mask, 1)
            for mask in (b"00000000", b"00000001", b"00000004", b"00000008",
                         b"0000000D", b"fffffffd", b"F", b"00000000F", b"0000000G")
        ])

    def test_incomplete_stream_cannot_establish_completion(self):
        data = transcript()
        for length in (0, 17, 300, data.index(b"mvo.image-verification.complete")):
            with self.subTest(length=length):
                self.assertIsNone(probe.observe(data[:length]))

    def test_observed_policy_failures_cannot_become_passing_results(self):
        for outcome in ({"status": 0, "handle": 1, "passed": 0},
                        {"status": 0x800000000000001A, "handle": 1, "passed": 0},
                        {"status": DENIED, "handle": 1, "passed": 0}):
            with self.subTest(outcome=outcome):
                result = probe.observe(transcript({"unsigned-user": outcome}))
                self.assertFalse(result["allPassed"])
                self.assertEqual(result["failures"], 1)
                case = result["cases"][3]
                self.assertFalse(case["passed"])
                self.assertFalse(case["childExecuted"])
                self.assertIsNone(case["startStatus"])
                self.assertEqual(case["loadStatus"], hex(outcome["status"]))

    def test_negative_case_must_not_emit_start_or_execution_witness(self):
        data = transcript()
        boundary = b"mvo.image-verification.end-case name=unsigned-user"
        witnesses = [
            b"mvo.image-verification.start name=unsigned-user status=0x0000000000000000\r\n",
            b"\r\n".join(execution_witness(0)) + b"\r\n",
            b"mvo.platform-probe.complete setup=0 secure-boot=1\r\n",
        ]
        self.assert_rejected([data.replace(boundary, witness + boundary, 1)
                              for witness in witnesses])

    def test_successful_positive_requires_complete_consistent_child_observations(self):
        data = transcript()
        arch = b"mvo.platform-probe.arch=aarch64\r\n"
        manufacturer = b"mvo.platform-probe.tpm-public-manufacturer=0x49424d00"
        start = b"mvo.image-verification.start name=setup-unsigned status=0x0000000000000000\r\n"
        child = b"\r\n".join(execution_witness(1)) + b"\r\n"
        self.assert_rejected([
            data.replace(arch, b"", 1),
            data.replace(arch, arch + arch, 1),
            data.replace(manufacturer, manufacturer[:-1], 1),
            data.replace(b"mvo.platform-probe.setup status=Success value=1",
                         b"mvo.platform-probe.setup status=Success value=0", 1),
            data.replace(b"mvo.platform-probe.secure-boot status=Success value=0",
                         b"mvo.platform-probe.secure-boot status=Success value=1", 1),
            data.replace(b"mvo.platform-probe.tcg2 status=Success present=1",
                         b"mvo.platform-probe.tcg2 status=Success present=0", 1),
            data.replace(b"mvo.platform-probe.complete setup=1 secure-boot=0\r\n", b"", 1),
            data.replace(start, b"", 1),
            data.replace(start, start.replace(b"setup-unsigned", b"setup-altered"), 1),
            data.replace(child + start, start + child, 1),
        ])

    def test_missing_duplicate_reordered_or_misnamed_cases_are_rejected(self):
        data = transcript()
        first = b"\r\n".join(case_lines("setup-unsigned", True, 1)) + b"\r\n"
        second = b"\r\n".join(case_lines("setup-altered", True, 1)) + b"\r\n"
        self.assert_rejected([
            data.replace(first, b"", 1),
            data.replace(first, first + first, 1),
            data.replace(first + second, second + first, 1),
            data.replace(b"end-case name=setup-unsigned", b"end-case name=setup-altered", 1),
            data.replace(b"load name=unsigned-user", b"load name=unknown-user", 1),
            b"mvo.image-verification.begin version=1\r\n" + data,
            data + b"mvo.image-verification.complete cases=9 failures=0\r\n",
        ])

    def test_trust_enrollment_and_exact_revocation_readback_are_required(self):
        data = transcript()
        pk = b"mvo.image-verification.update variable=PK status=Success\r\n"
        kek = b"mvo.image-verification.update variable=KEK status=Success\r\n"
        self.assert_rejected([
            data.replace(pk, b"", 1),
            data.replace(pk + kek, kek + pk, 1),
            data.replace(b"revoke status=0x0000000000000000",
                         b"revoke status=0x800000000000001a", 1),
            data.replace(b"revocation-readback exact=1", b"revocation-readback exact=0", 1),
            data.replace(b"bytes=76 attributes=0x00000027", b"bytes=75 attributes=0x00000027", 1),
            data.replace(b"bytes=76 attributes=0x00000027", b"bytes=76 attributes=0x00000007", 1),
            b"mvo.image-verification.failure stage=inputs status=bad\r\n",
        ])

    def test_contradictory_pass_assertions_and_completion_counts_are_rejected(self):
        good = transcript()
        bad = transcript({"altered-user": {"status": 0, "handle": 1, "passed": 0}})
        self.assert_rejected([
            good.replace(b"name=unsigned-user mode=1 cleanup=0x0000000000000000 passed=1",
                         b"name=unsigned-user mode=0 cleanup=0x0000000000000000 passed=1", 1),
            good.replace(b"cleanup=0x0000000000000000 passed=1",
                         b"cleanup=0x8000000000000007 passed=1", 1),
            bad.replace(b"passed=0", b"passed=1", 1),
            bad.replace(b"failures=1", b"failures=0", 1),
            good.replace(b"cases=9", b"cases=8", 1),
            good.replace(b"status=0x0000000000000000", b"status=0x0", 1),
        ])

    def test_failed_mode_cleanup_or_positive_start_remains_a_policy_failure(self):
        for changes in ({"mode": 0, "passed": 0},
                        {"cleanup": 0x8000000000000007, "passed": 0},
                        {"start": 0x8000000000000003, "passed": 0}):
            with self.subTest(changes=changes):
                result = probe.observe(transcript({"trusted-after": changes}))
                self.assertFalse(result["allPassed"])
                self.assertEqual(result["failures"], 1)
                self.assertFalse(result["cases"][5]["passed"])

    def test_rejecting_all_images_after_dbx_is_not_selective_revocation_success(self):
        rejected = {"status": DENIED, "handle": 0, "passed": 0}
        result = probe.observe(transcript({"unrevoked-before": rejected,
                                           "unrevoked-after": rejected}))
        self.assertFalse(result["allPassed"])
        self.assertEqual(result["failures"], 2)
        self.assertEqual(result["executedChildren"], 4)
        self.assertTrue(result["cases"][7]["passed"])
        self.assertFalse(result["cases"][6]["passed"])
        self.assertFalse(result["cases"][8]["passed"])


if __name__ == "__main__":
    unittest.main()
