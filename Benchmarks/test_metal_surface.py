# SPDX-License-Identifier: Apache-2.0
"""Synthetic evidence-admission vectors only; never exercise a GPU or VM."""
import copy
import json
import math
import unittest

from metal_surface import public_build, validate_cases, validate_transport


def cases(cross):
    result = []
    for index in range(8):
        samples = []
        for trial in range(5):
            sample = {"exportSubmitAndWaitMS": .5, "consumerDrawAndWaitMS": .4}
            if cross:
                sample.update(consumerNoticeMS=.1, deliberateConsumerPauseMS=32 if trial == 0 else 0,
                              validatedACKRoundTripMS=33 if trial == 0 else 1)
            else:
                sample["combinedMS"] = .9
            samples.append(sample)
        case = {"width": 3456 if index < 4 else 3840, "height": 2168 if index < 4 else 2160,
                "sourceFormat": [80, 81, 70, 71][index % 4], "surfaceFormat": [80, 81][index % 2],
                "slots": 2, "trials": 5, "warmups": 2, "samples": samples}
        if cross:
            case.update(allConsumerPixelsCorrect=True, maximumInFlight=1)
        else:
            case.update(allPixelsCorrect=True, alphaForcedOpaque=True, machPortsDeallocatedAfterImport=True)
        result.append(case)
    return {"cases": result}


def transport():
    return {"scope": "cross-process-generated-IOSurface-GPU-delivery-component", "passed": True,
            "mode": "healthy", "expectedProtocolRejectionObserved": False, "actualChildExit": 0,
            "actualParentReaped": True, "forcedOwnedCleanup": False, "registeredPortsRestored": True,
            "namedServiceOrGlobalSurfaceIDUsed": False, "kernelPeerAuditUIDAndOwnedChildPIDChecked": True,
            "productionAuthenticationQualified": False, "guestOrPhysicalPresentationQualified": False,
            "noGuestPixelsOrScreenFiles": True, "consumerShaderReadUsageIsAccessControl": False,
            "timingScope": "Synthetic validator vector, not a measurement", "cases": cases(True)["cases"]}


class MetalSurfaceAdmissionTests(unittest.TestCase):
    def test_reference_shapes_and_fault_outcomes(self):
        validate_cases(cases(False), False)
        validate_cases(cases(True), True)
        validate_transport(transport(), "run")
        for mode, exit_code in [("replay-ack", 0), ("stale-epoch", 0), ("early-exit", 7),
                                ("stalled-consumer", 0), ("malformed-attach", 24)]:
            raw = transport()
            raw.update(mode=mode, actualChildExit=exit_code, expectedProtocolRejectionObserved=True, cases=[])
            validate_transport(raw, mode)

    def test_wrong_geometry_format_type_counts_or_pixel_check_are_rejected(self):
        for key, value in [("width", 1920), ("height", 2168.0), ("surfaceFormat", 70),
                           ("sourceFormat", 999), ("slots", 3), ("trials", 4),
                           ("allConsumerPixelsCorrect", False), ("maximumInFlight", True)]:
            with self.subTest(key=key):
                raw = cases(True)
                raw["cases"][0][key] = value
                with self.assertRaises(ValueError):
                    validate_cases(raw, True)

    def test_scope_cannot_drop_pause_or_cpu_oracle_and_must_stay_finite(self):
        for key, value in [("deliberateConsumerPauseMS", 0), ("validatedACKRoundTripMS", .5),
                           ("consumerNoticeMS", math.nan), ("consumerDrawAndWaitMS", math.inf),
                           ("exportSubmitAndWaitMS", -1), ("consumerNoticeMS", True)]:
            with self.subTest(key=key, value=value):
                raw = cases(True)
                raw["cases"][0]["samples"][0][key] = value
                with self.assertRaises(ValueError):
                    validate_cases(raw, True)
        raw = cases(False)
        raw["cases"][0]["samples"][0]["combinedMS"] = .1
        with self.assertRaises(ValueError):
            validate_cases(raw, False)

    def test_unknown_fields_and_unsupported_claims_are_rejected(self):
        for key, value in [("productionAuthenticationQualified", True),
                           ("guestOrPhysicalPresentationQualified", True),
                           ("actualParentReaped", 1), ("forcedOwnedCleanup", True),
                           ("consumerShaderReadUsageIsAccessControl", True), ("unknown", 0)]:
            with self.subTest(key=key):
                raw = transport()
                raw[key] = value
                with self.assertRaises(ValueError):
                    validate_transport(raw, "run")
        raw = cases(False)
        raw["cases"][0]["samples"][0]["unexpectedMetric"] = 1
        with self.assertRaises(ValueError):
            validate_cases(raw, False)

    def test_public_export_omits_local_commands_and_paths(self):
        private = {"scope": "build", "inputs": {"relative/file": "hash"}, "binaries": {},
                   "toolchain": {"sdk": "test"},
                   "operations": [{"actualExit": 0, "command": ["/private/local/workspace/compiler"]}]}
        before = copy.deepcopy(private)
        exported = public_build(private)
        self.assertEqual(private, before)
        self.assertNotIn("/private/local/workspace", json.dumps(exported))
        self.assertEqual(exported["actualBuildExits"], [0])


if __name__ == "__main__":
    unittest.main()
