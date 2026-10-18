# SPDX-License-Identifier: Apache-2.0
import copy
import json
import unittest
from pathlib import Path
from validate_result import validate_result


def fixture():
    schema = json.loads(Path(__file__).with_name("result.schema.json").read_text())
    result = {"schemaVersion": 1, "recordedAt": "2026-10-06T00:00:00Z", "status": "skipped",
              "unknownReasons": {}, "metrics": [], "limitations": ["No guest boot measurement supplied."]}
    for section in ["host", "application", "guest", "method"]:
        result[section] = {}
        for field, field_schema in schema["properties"][section]["properties"].items():
            kinds = field_schema.get("type", [])
            if "null" in kinds:
                result[section][field] = None
                result["unknownReasons"][f"{section}.{field}"] = "Not measured in this fixture."
    result["application"].update(sourceSHA256="test-fixture", version="test", backend="none", entitlements=[], configuration={})
    result["method"].update(cache="uncontrolled", trialCount=0, outlierPolicy="retain all")
    return result


class EvidenceValidation(unittest.TestCase):
    def test_skip_and_unknowns_are_explicit(self):
        result = fixture()
        self.assertEqual(validate_result(result), [])
        result["unknownReasons"].pop("host.gpuCores")
        self.assertIn("host.gpuCores: null requires a reason", validate_result(result))

    def test_no_measurement_claim_without_samples(self):
        result = fixture(); result["status"] = "measured"
        self.assertIn("Measured results need actual samples", validate_result(result))

    def test_trial_count_and_nonfinite_samples(self):
        result = fixture(); result["status"] = "measured"; result["method"]["trialCount"] = 2
        result["metrics"] = [{"name": "framework-start", "unit": "ms", "samples": [1.0], "definition": "Not guest ready"}]
        self.assertIn("Metric trial count mismatch", validate_result(result))
        result["metrics"][0]["samples"] = [float("nan"), 1.0]
        self.assertTrue(validate_result(result))

    def test_unknown_fields_and_missing_required_fields_fail(self):
        original = fixture(); altered = copy.deepcopy(original); altered["guest"]["secret"] = "never"
        self.assertTrue(validate_result(altered))
        altered = copy.deepcopy(original); del altered["host"]["ramBytes"]
        self.assertTrue(validate_result(altered))
