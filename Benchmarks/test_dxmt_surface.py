# SPDX-License-Identifier: Apache-2.0
"""Admission vectors only; no native library, GPU, guest or VM access."""
import math
import unittest
from dxmt_surface import validate_ordering


def reference():
    cases = []
    for index in range(8):
        cases.append({"width": 3456 if index < 4 else 3840, "height": 2168 if index < 4 else 2160,
                      "dxgiFormat": [87, 91, 28, 29][index % 4], "sourceFormat": [80, 81, 70, 71][index % 4],
                      "surfaceFormat": [80, 81][index % 2], "allPixelsCorrectAfterSourceOverwrite": True,
                      "warmups": 2, "samples": [dict(producerFenceWaitMS=.2, exportSubmitAndWaitMS=.4,
                          consumerDrawAndWaitMS=.3, sourceOverwriteFenceWaitMS=.1) for _ in range(5)]})
    return {"scope": "native-DXMT-completed-shared-source-IOSurface-component", "passed": True,
            "sourceExclusiveOwnershipIsFixtureOnly": True, "windowsPresentOrPhysicalPresentationQualified": False,
            "pollableEventAndFenceValueBothChecked": True, "earlyEventHandleCloseExercised": True,
            "noPixelFiles": True, "cases": cases}


class DxmtOrderingAdmissionTests(unittest.TestCase):
    def test_closed_reference_and_claims(self):
        validate_ordering(reference())
        for key, value in [("passed", 1), ("windowsPresentOrPhysicalPresentationQualified", True),
                           ("pollableEventAndFenceValueBothChecked", False),
                           ("sourceExclusiveOwnershipIsFixtureOnly", False), ("unknown", True)]:
            with self.subTest(key=key):
                raw = reference()
                raw[key] = value
                with self.assertRaises(ValueError):
                    validate_ordering(raw)

    def test_geometry_format_count_or_source_integrity_cannot_change(self):
        for key, value in [("width", 1920), ("height", 2168.0), ("dxgiFormat", 28),
                           ("sourceFormat", 70), ("surfaceFormat", 81), ("warmups", True),
                           ("allPixelsCorrectAfterSourceOverwrite", False), ("samples", [])]:
            with self.subTest(key=key):
                raw = reference()
                raw["cases"][0][key] = value
                with self.assertRaises(ValueError):
                    validate_ordering(raw)

    def test_finite_distinct_scopes_required(self):
        for value in [math.nan, math.inf, -1, True, "0.2"]:
            raw = reference()
            raw["cases"][0]["samples"][0]["producerFenceWaitMS"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_ordering(raw)
        raw = reference()
        del raw["cases"][0]["samples"][0]["sourceOverwriteFenceWaitMS"]
        with self.assertRaises(ValueError):
            validate_ordering(raw)


if __name__ == "__main__":
    unittest.main()
