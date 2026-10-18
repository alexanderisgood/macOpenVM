# SPDX-License-Identifier: Apache-2.0
"""Source inventory checks only; never build, sign, execute native code or open a VM."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build_manifest.py"
SPEC = importlib.util.spec_from_file_location("build_manifest_sources_fixture", SCRIPT)
build_manifest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_manifest)


class BuildManifestSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in build_manifest.RECIPE_FILES:
            self.write(name, "recipe\n")
        for name in build_manifest.SOURCE_DIRECTORIES:
            (self.root / name).mkdir(exist_ok=True)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def snapshot(self):
        return build_manifest.source_snapshot(self.root)

    def test_all_declared_production_roots_include_native_sources_and_maps(self):
        expected = set(build_manifest.RECIPE_FILES)
        for directory in build_manifest.SOURCE_DIRECTORIES:
            for extension in ("swift", "c", "h", "m", "mm", "modulemap"):
                name = f"{directory}/Nested/source.{extension}"
                self.write(name, f"fixture {name}\n")
                expected.add(name)
        snapshot = self.snapshot()
        self.assertEqual({row["path"] for row in snapshot["files"]}, expected)

    def test_c_header_and_modulemap_mutations_change_file_and_aggregate_pins(self):
        for name in ("Backends/SharedFrameWire/SharedHDRFrameWire.c",
                     "Backends/SharedFrameWire/include/SharedHDRFrameWire.h",
                     "Backends/SharedFrameWire/include/module.modulemap"):
            with self.subTest(path=name):
                path = self.write(name, "first\n")
                before = self.snapshot()
                path.write_text("other\n")  # Same length: content hash must matter.
                after = self.snapshot()
                old = next(row for row in before["files"] if row["path"] == name)
                new = next(row for row in after["files"] if row["path"] == name)
                self.assertEqual(old["bytes"], new["bytes"])
                self.assertNotEqual(old["sha256"], new["sha256"])
                self.assertNotEqual(before["sha256"], after["sha256"])

    def test_nonproduction_fixtures_build_and_lab_outputs_are_ignored(self):
        self.write("App/Main.swift", "production\n")
        before = self.snapshot()
        for directory in ("Benchmarks", "Tests", "build", ".build", ".lab", "unrelated"):
            for extension in ("swift", "c", "h", "m", "mm", "modulemap", "json", "py"):
                self.write(f"{directory}/fixture.{extension}", "not production\n")
        self.assertEqual(self.snapshot(), before)

    def test_guest_agent_schema_and_python_curation_is_preserved(self):
        self.write("GuestAgent/Protocol/agent.json", '{"schema":1}\n')
        self.write("GuestAgent/Protocol/generate.py", "schema = 1\n")
        before = self.snapshot()
        self.write("App/example.json", '{"fixture":true}\n')
        self.write("Backends/example.py", "fixture = True\n")
        self.assertEqual(self.snapshot(), before)
        paths = {row["path"] for row in before["files"]}
        self.assertIn("GuestAgent/Protocol/agent.json", paths)
        self.assertIn("GuestAgent/Protocol/generate.py", paths)

    def test_output_is_unique_sorted_deterministic_and_canonically_hashed(self):
        for name in ("Core/Z.swift", "Backends/Z.c", "App/A.mm", "App/A.h", "App/A.m"):
            self.write(name, name + "\n")
        first = self.snapshot()
        self.assertEqual(first, self.snapshot())
        paths = [row["path"] for row in first["files"]]
        self.assertEqual(paths, sorted(set(paths)))
        encoded = json.dumps(first["files"], sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(first["sha256"], hashlib.sha256(encoded).hexdigest())
        for row in first["files"]:
            data = (self.root / row["path"]).read_bytes()
            self.assertEqual(row["bytes"], len(data))
            self.assertEqual(row["sha256"], hashlib.sha256(data).hexdigest())

    def test_native_source_symlinks_and_nonregular_matches_are_rejected(self):
        original = self.write("Backends/actual.c", "source\n")
        alias = self.root / "App/alias.c"
        alias.symlink_to(original)
        with self.assertRaises(ValueError):
            self.snapshot()
        alias.unlink()
        (self.root / "Backends/not-a-file.h").mkdir()
        with self.assertRaises(ValueError):
            self.snapshot()


if __name__ == "__main__":
    unittest.main()
