# SPDX-License-Identifier: Apache-2.0
"""Portable extraction/evidence admission tests; never compile or execute native code."""
import copy
from pathlib import Path
import tempfile
import unittest

if __package__:
    from .extract_shaders import extract, literal
    from .prepare_geometry import portable, prepare
    from .summarize import expected_viewport, validate
else:
    from extract_shaders import extract, literal
    from prepare_geometry import portable, prepare
    from summarize import expected_viewport, validate


BASE = "vertex Vertex plane(uint i) { return {}; }\nfragment half4 opaque() { return {}; }\n"
SHARP = "vertex Vertex plane(uint i) { return {}; }\nfragment half4 lightSharp() { return {}; }\n"


def swift(name, text, static=True):
    prefix = "static " if static else ""
    body = "\n".join("  " + line for line in text.rstrip().splitlines())
    return f'{prefix}let {name} = """\n{body}\n  """\n'.encode()


def evidence():
    result = {"schemaVersion": 2, "fixture": "exact-production-shader-cache-copy-plus-final-pass",
              "targetWidth": 3456, "targetHeight": 2168, "liveFPSMeasured": False,
              "physicalScanoutMeasured": False, "includesProducerTransport": False,
              "includesDrawableAcquisition": False, "copyAndDrawCombinedForFixture": True,
              "inFlightCommandBuffers": 1, "separateProductionShaderLibraries": True,
              "exactHistoricalDefaultOutputMatches": True, "pairs": 6, "samplesPerBlock": 300,
              "initialWarmPerVariant": 120, "switchWarmPerBlock": 12, "images": [], "blocks": []}
    for width, height in ((3456, 2168), (2560, 1600), (1920, 1080), (1728, 1084)):
        for geometry in ("aspectFit", "integer"):
            viewport = expected_viewport(width, height, geometry)
            upscaled = viewport[2] > width and viewport[3] > height
            exact = geometry == "integer" or (width, height) == (3456, 2168)
            # These are synthetic admission vectors, never GPU measurements.
            result["images"].append({"sourceWidth": width, "sourceHeight": height, "geometry": geometry,
                                     "status": "passed", "exactHistoricalDefaultOutputMatches": True,
                                     "flatPixelsChecked": 100, "byteExactNearestPixelsChecked": 100 if exact else 0,
                                     "blackLetterboxPixelsChecked": 0, "changedSharpPixels": 100 if upscaled else 0,
                                     "localFiveTapRangePixelsChecked": 100 if upscaled and exact else 0,
                                     "fractionalFitExactReferenceSkipped": not exact})
            for pair in range(6):
                order = ["nearest", "automaticSharp"] if pair % 2 == 0 else ["automaticSharp", "nearest"]
                for position, variant in enumerate(order):
                    block = {"sourceWidth": width, "sourceHeight": height, "geometry": geometry,
                             "targetWidth": 3456, "targetHeight": 2168, "pair": pair, "position": position,
                             "variant": variant, "frames": 300, "viewport": viewport.copy(),
                             "effectiveFragment": "lightSharp" if variant == "automaticSharp" and upscaled else "opaque"}
                    for category, raw in (("gpu", "rawGpuMS"), ("submitToCallback", "rawSubmitToCallbackMS"),
                                          ("encoding", "rawEncodingMS")):
                        block[raw] = [.2] * 300
                        block[category] = {"p50MS": .2, "p95MS": .2, "p99MS": .2,
                                           "over120HzBudget": 0, "over60HzBudget": 0}
                    result["blocks"].append(block)
    return result


class DisplayScalingToolsTests(unittest.TestCase):
    def test_exact_separate_libraries_and_original_default_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            current, old = root / "current.swift", root / "old.swift"
            current.write_bytes(swift("shader", BASE) + swift("sharpeningShader", SHARP))
            old.write_bytes(swift("shader", BASE, False))
            receipt = extract(current, old, root / "output")
            self.assertTrue(receipt["defaultShaderByteExact"])
            self.assertEqual((root / "output/baseline.metal").read_text(), BASE)
            self.assertEqual((root / "output/sharpening.metal").read_text(), SHARP)
            self.assertEqual((root / "output/original.metal").read_text(), BASE)
            with self.assertRaises(FileExistsError):
                extract(current, old, root / "output")

    def test_modified_default_or_ambiguous_or_interpolated_source_is_rejected(self):
        for raw in (swift("shader", BASE) * 2, swift("shader", BASE + "\\(value)\n")):
            with self.assertRaises(ValueError):
                literal(raw, "shader")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            current, old = root / "current.swift", root / "old.swift"
            current.write_bytes(swift("shader", BASE + "// modified\n") + swift("sharpeningShader", SHARP))
            old.write_bytes(swift("shader", BASE, False))
            with self.assertRaises(ValueError):
                extract(current, old, root / "output")

    def test_geometry_source_body_is_untouched_and_package_is_exclusive(self):
        raw = b"import BackendAPI\nimport CoreGraphics\nimport Foundation\nstruct ExactBody { let n = 4 }\n"
        self.assertEqual(portable(raw).split(b"#endif\n")[1], raw.split(b"import CoreGraphics\n")[1])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.swift"
            source.write_bytes(raw)
            receipt = prepare(source, source, root / "package")
            self.assertFalse(receipt["nativeExecutionPerformed"])
            self.assertIn("platforms: [.macOS(.v14)]", (root / "package/Package.swift").read_text())
            self.assertEqual((root / "package/Sources/BaselineGeometry/GuestViewport.swift").read_bytes(), portable(raw))
            with self.assertRaises(FileExistsError):
                prepare(source, source, root / "package")

    def test_complete_finite_evidence_is_admitted_without_running_a_gpu(self):
        self.assertEqual(len(validate(evidence())), 8)

    def test_objc_boxed_unary_not_scope_flag_accepts_only_boolean_or_exact_zero_one(self):
        sample = evidence()
        for image in sample["images"]:
            image["fractionalFitExactReferenceSkipped"] = int(image["fractionalFitExactReferenceSkipped"])
        self.assertEqual(len(validate(sample)), 8)
        for value in (2, -1, "0", None):
            bad = copy.deepcopy(sample)
            bad["images"][0]["fractionalFitExactReferenceSkipped"] = value
            with self.assertRaises(ValueError):
                validate(bad)

    def test_false_claims_incomplete_trials_or_wrong_shader_are_rejected(self):
        mutations = [
            lambda x: x.update(liveFPSMeasured=True),
            lambda x: x.update(schemaVersion=1),
            lambda x: x["blocks"].pop(),
            lambda x: x["images"][0].update(exactHistoricalDefaultOutputMatches=False),
            lambda x: x["blocks"][0].update(position=1),
            lambda x: x["blocks"][0].update(effectiveFragment="lightSharp"),
            lambda x: x["blocks"][0]["rawGpuMS"].__setitem__(0, float("nan")),
            lambda x: x["blocks"][0]["gpu"].update(p95MS=.3),
            lambda x: x["blocks"][1].update(viewport=[0, 0, 100, 100]),
        ]
        for mutate in mutations:
            sample = copy.deepcopy(evidence())
            mutate(sample)
            with self.assertRaises(ValueError):
                validate(sample)


if __name__ == "__main__":
    unittest.main()
