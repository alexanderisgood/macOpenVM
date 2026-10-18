#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate the project's schema subset and additional honest-measurement rules."""
import json
import math
import sys
from pathlib import Path


def validate_schema(value, schema, path="$", errors=None):
    errors = [] if errors is None else errors
    kinds = schema.get("type", [])
    kinds = [kinds] if isinstance(kinds, str) else kinds
    checks = {"null": value is None, "object": isinstance(value, dict), "array": isinstance(value, list),
              "string": isinstance(value, str), "integer": type(value) is int,
              "number": type(value) in (int, float) and math.isfinite(value)}
    if kinds and not any(checks[kind] for kind in kinds):
        errors.append(path + ": wrong type")
        return errors
    if "const" in schema and value != schema["const"]:
        errors.append(path + ": wrong constant")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(path + ": invalid enum")
    if type(value) in (int, float) and value < schema.get("minimum", -math.inf):
        errors.append(path + ": below minimum")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(path + ": missing " + key)
        for key, child in value.items():
            child_schema = schema.get("properties", {}).get(key)
            if child_schema is None:
                additional = schema.get("additionalProperties", True)
                if additional is False:
                    errors.append(path + ": unknown " + key)
                elif isinstance(additional, dict):
                    validate_schema(child, additional, path + "." + key, errors)
            else:
                validate_schema(child, child_schema, path + "." + key, errors)
    if isinstance(value, list) and "items" in schema:
        for index, child in enumerate(value):
            validate_schema(child, schema["items"], f"{path}[{index}]", errors)
    return errors


def validate_result(result):
    schema = json.loads(Path(__file__).with_name("result.schema.json").read_text())
    errors = validate_schema(result, schema)
    if errors:
        return errors
    for section in ["host", "application", "guest", "method"]:
        for field, value in result[section].items():
            if value is None and not result["unknownReasons"].get(f"{section}.{field}"):
                errors.append(f"{section}.{field}: null requires a reason")
    for metric in result["metrics"]:
        if len(metric["samples"]) != result["method"]["trialCount"]:
            errors.append("Metric trial count mismatch")
    if result["status"] == "measured" and (not result["metrics"] or result["method"]["trialCount"] < 1):
        errors.append("Measured results need actual samples")
    if result["status"] != "measured" and not result["limitations"]:
        errors.append("Failed/skipped results require an explanation")
    return errors


if __name__ == "__main__":
    for filename in sys.argv[1:]:
        failures = validate_result(json.loads(Path(filename).read_text()))
        if failures:
            raise SystemExit("\n".join(failures))
        print(Path(filename).name + ": valid benchmark evidence structure")
