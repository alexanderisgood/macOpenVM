# SPDX-License-Identifier: Apache-2.0
"""The inventory check must detect drift without repairing its own input."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class SBOMTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        source = Path(__file__).resolve().parents[2] / "scripts" / "sbom.py"
        shutil.copyfile(source, self.root / "scripts" / "sbom.py")
        manifest = {"scope": "Test fixture.", "components": [{
            "name": "Fixture", "version": "1", "sourceURL": "https://example.invalid/fixture",
            "license": "Apache-2.0", "modifications": "None", "scope": "test",
            "redistributed": False, "obligations": "Retain notice",
            "copyrightText": "Copyright 2026 Fixture Authors",
        }]}
        (self.root / "dependencies.json").write_text(json.dumps(manifest))
        self.output = self.root / "sbom.spdx.json"

    def run_generator(self, *arguments):
        return subprocess.run(
            [sys.executable, str(self.root / "scripts" / "sbom.py"), *arguments],
            capture_output=True, text=True, timeout=10, check=False)

    def test_generation_preserves_declared_copyright(self):
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        package = json.loads(self.output.read_text())["packages"][0]
        self.assertEqual(package["copyrightText"], "Copyright 2026 Fixture Authors")

    def test_matching_check_does_not_rewrite_inventory(self):
        self.assertEqual(self.run_generator().returncode, 0)
        before = self.output.read_bytes(), self.output.stat().st_mtime_ns
        result = self.run_generator("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output.read_bytes(), self.output.stat().st_mtime_ns), before)

    def test_drift_check_refuses_and_preserves_stale_inventory(self):
        self.output.write_text("Deliberately stale inventory\n")
        before = self.output.read_bytes(), self.output.stat().st_mtime_ns
        result = self.run_generator("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("out of date", result.stderr)
        self.assertEqual((self.output.read_bytes(), self.output.stat().st_mtime_ns), before)

    def test_missing_check_does_not_create_inventory(self):
        result = self.run_generator("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
