#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Admit a complete finite fixture and produce a compact paired component summary."""
import argparse
import json
import math
from pathlib import Path
import random
import statistics

SOURCES = {(3456, 2168), (2560, 1600), (1920, 1080), (1728, 1084)}
GEOMETRIES = {"aspectFit", "integer"}
RAW = {"gpu": "rawGpuMS", "submitToCallback": "rawSubmitToCallbackMS", "encoding": "rawEncodingMS"}


def require(value, message):
    if not value:
        raise ValueError(message)


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def interval(values, replicates=10000):
    rng = random.Random(20261018)
    means = [sum(rng.choices(values, k=len(values))) / len(values) for _ in range(replicates)]
    return [percentile(means, .025), percentile(means, .975)]


def expected_viewport(width, height, geometry):
    scale = min(3456 / width, 2168 / height)
    if geometry == "integer":
        scale = math.floor(scale)
    w, h = width * scale, height * scale
    x, y = (3456 - w) / 2, (2168 - h) / 2
    if geometry == "integer":
        x, y = math.floor(x), math.floor(y)
    return [x, y, w, h]


def validate(data):
    require(data.get("schemaVersion") == 2, "Expected version2 exact historical-default oracle fixture")
    require(data.get("fixture") == "exact-production-shader-cache-copy-plus-final-pass", "Unexpected fixture scope")
    require(data.get("targetWidth") == 3456 and data.get("targetHeight") == 2168, "Unexpected target raster")
    for key in ("liveFPSMeasured", "physicalScanoutMeasured", "includesProducerTransport", "includesDrawableAcquisition"):
        require(data.get(key) is False, f"Fixture must not claim {key}")
    require(data.get("copyAndDrawCombinedForFixture") is True and data.get("inFlightCommandBuffers") == 1,
            "Preserve combined command-buffer and in-flight scope")
    require(data.get("separateProductionShaderLibraries") is True and data.get("exactHistoricalDefaultOutputMatches") is True,
            "Separate exact shader libraries and historical-default oracle required")
    require(data.get("pairs") == 6 and data.get("samplesPerBlock") == 300 and
            data.get("initialWarmPerVariant") == 120 and data.get("switchWarmPerBlock") == 12,
            "Finite counterbalanced work counts changed")
    expected = {(w, h, geometry) for w, h in SOURCES for geometry in GEOMETRIES}
    images = data.get("images")
    require(type(images) is list and len(images) == 8, "Eight image oracles required")
    image_keys = set()
    for image in images:
        key = (image.get("sourceWidth"), image.get("sourceHeight"), image.get("geometry"))
        require(key in expected and key not in image_keys, "Duplicate or unsupported image geometry")
        image_keys.add(key)
        require(image.get("status") == "passed" and image.get("exactHistoricalDefaultOutputMatches") is True,
                "Every image must pass the historical-default oracle")
        for field in ("flatPixelsChecked", "byteExactNearestPixelsChecked", "blackLetterboxPixelsChecked",
                      "changedSharpPixels", "localFiveTapRangePixelsChecked"):
            require(type(image.get(field)) is int and image[field] >= 0, "Image check count missing")
        viewport = expected_viewport(*key)
        upscaled = viewport[2] > key[0] and viewport[3] > key[1]
        exact = key[2] == "integer" or key[:2] == (3456, 2168)
        require(image["flatPixelsChecked"] > 0 and (image["byteExactNearestPixelsChecked"] > 0) == exact,
                "Missing constant-field/native/integer image oracle")
        # The Objective-C fixture boxes unary ! as NSNumber(int), so its
        # NSJSONSerialization representation is the canonical integer0/1 rather
        # than a JSON boolean on some SDK/architecture combinations.
        skipped = image.get("fractionalFitExactReferenceSkipped")
        expected_skipped = not exact
        require(skipped is expected_skipped or
                (type(skipped) is int and skipped in (0, 1) and skipped == int(expected_skipped)),
                "Exact-reference scope changed")
        require((image["changedSharpPixels"] > 0) == upscaled and
                (image["localFiveTapRangePixelsChecked"] > 0) == (upscaled and exact),
                "Missing sharpen bypass/range/change oracle")
    require(type(data.get("blocks")) is list and len(data["blocks"]) == 96, "Eight cases times six complete pairs required")
    cases = {}
    for block in data["blocks"]:
        key = (block.get("sourceWidth"), block.get("sourceHeight"), block.get("geometry"))
        require(key in expected and block.get("targetWidth") == 3456 and block.get("targetHeight") == 2168,
                "Unsupported block geometry")
        pair_index, position, variant = block.get("pair"), block.get("position"), block.get("variant")
        require(type(pair_index) is int and 0 <= pair_index < 6 and type(position) is int and position in (0, 1),
                "Invalid counterbalance index")
        order = ["nearest", "automaticSharp"] if pair_index % 2 == 0 else ["automaticSharp", "nearest"]
        require(variant == order[position], "Unexpected AB/BA order")
        pair = cases.setdefault(key, {}).setdefault(pair_index, {})
        require(variant not in pair, "Duplicate variant within pair")
        pair[variant] = block
        require(block.get("frames") == 300, "Measured sample count changed")
        viewport = block.get("viewport")
        require(type(viewport) is list and len(viewport) == 4 and
                all(type(x) in (int, float) and math.isfinite(x) for x in viewport), "Invalid viewport")
        x, y, width, height = viewport
        require(x >= 0 and y >= 0 and width > 0 and height > 0 and x + width <= 3456 and y + height <= 2168,
                "Viewport escapes target")
        require(all(abs(a-b) <= 1e-8 for a, b in zip(viewport, expected_viewport(*key))),
                "Measured coverage differs from the declared geometry matrix")
        upscaled = width > key[0] and height > key[1]
        require(block.get("effectiveFragment") == ("lightSharp" if variant == "automaticSharp" and upscaled else "opaque"),
                "Effective shader does not match production bypass")
        for category, raw_key in RAW.items():
            values = block.get(raw_key)
            require(type(values) is list and len(values) == 300 and
                    all(type(x) in (int, float) and math.isfinite(x) and x >= 0 for x in values),
                    "Finite nonnegative complete timing arrays required")
            for metric, fraction in (("p50MS", .5), ("p95MS", .95), ("p99MS", .99)):
                require(abs(block[category][metric] - percentile(values, fraction)) <= 1e-9,
                        "Reported percentile differs from raw samples")
        for category, raw_key in RAW.items():
            for metric, budget in (("over120HzBudget", 1000/120), ("over60HzBudget", 1000/60)):
                require(type(block[category].get(metric)) is int and
                        block[category][metric] == sum(x > budget for x in block[raw_key]),
                        "Frame-budget count differs from raw samples")
    require(set(cases) == expected and all(set(pairs) == set(range(6)) for pairs in cases.values()),
            "Missing geometry or pair")
    for pairs in cases.values():
        for pair in pairs.values():
            require(set(pair) == {"nearest", "automaticSharp"}, "Incomplete counterbalanced pair")
            require(pair["nearest"]["viewport"] == pair["automaticSharp"]["viewport"],
                    "Paired shader comparison must use identical coverage")
    return cases


def summarize(data, detailed=False):
    cases = validate(data)
    summaries = []
    for (width, height, geometry), pairs in sorted(cases.items()):
        summary = {"sourceWidth": width, "sourceHeight": height, "geometry": geometry,
                   "effectiveCandidateFragments": sorted({p["automaticSharp"]["effectiveFragment"] for p in pairs.values()}),
                   "comparisons": {}}
        summary["gpuBudgetMissesByVariant"] = {
            variant: {metric: sum(pair[variant]["gpu"][metric] for pair in pairs.values())
                      for metric in ("over120HzBudget", "over60HzBudget")}
            for variant in ("nearest", "automaticSharp")}
        categories = RAW if detailed else ("gpu", "submitToCallback")
        for category in categories:
            comparison = {}
            for metric in (("p50MS", "p95MS", "p99MS") if detailed else ("p50MS", "p95MS")):
                baseline = [pair["nearest"][category][metric] for _, pair in sorted(pairs.items())]
                candidate = [pair["automaticSharp"][category][metric] for _, pair in sorted(pairs.items())]
                require(all(x > 0 for x in baseline), "Ratios require positive baseline metrics")
                deltas = [b-a for a, b in zip(baseline, candidate)]
                ratios = [b/a for a, b in zip(baseline, candidate)]
                result = {"baselineBlockMedianMS": statistics.median(baseline),
                          "candidateBlockMedianMS": statistics.median(candidate),
                          "meanPairedDifferenceMS": statistics.mean(deltas),
                          "meanPairedDifferenceBootstrap95CI": interval(deltas),
                          "meanPairedRatioBootstrap95CI": interval(ratios)}
                if detailed:
                    result.update(pairedDifferenceMS=deltas, pairedRatio=ratios, meanPairedRatio=statistics.mean(ratios))
                comparison[metric] = result
            summary["comparisons"][category] = comparison
        summaries.append(summary)
    return {"schemaVersion": 2, "liveFPSMeasured": False, "historicalDefaultPixelsMatch": True,
            "performanceAcceptanceDecision": "Requires separate default hotpath and live cadence qualification",
            "confidenceIntervalLimit": "Six paired blocks; bootstrap describes this component experiment only",
            "sameShaderControls": "Native/integer1x automaticSharp selects opaque; this controls noise, not app scheduling",
            "cases": summaries}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture_json", type=Path)
    parser.add_argument("--detailed", action="store_true")
    args = parser.parse_args()
    print(json.dumps(summarize(json.loads(args.fixture_json.read_text()), args.detailed), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
