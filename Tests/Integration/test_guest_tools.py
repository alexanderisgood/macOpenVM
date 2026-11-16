# SPDX-License-Identifier: Apache-2.0
"""Bootstrap input rejection and actual generated media checks, never guest execution."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import shutil
import subprocess
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("guest_tools_build", ROOT / "scripts/build-guest-tools.py")
tools = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tools)


class GuestToolsInputTests(unittest.TestCase):
    def test_storage_sequence_reports_failures_and_opt_out_without_mutation(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        if not compiler:
            self.skipTest("A C compiler is required for the storage orchestration fixture")
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "storage-plan"
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "GuestAgent/Windows/Tools"),
                            str(ROOT / "Tests/Integration/fixtures/windows_storage_plan.c"),
                            "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def archive(self, entries):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "drivers.zip"
        with zipfile.ZipFile(path, "w") as output:
            for name, data in entries:
                output.writestr(name, data)
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def test_changed_archive_is_refused_before_extraction(self):
        path, checksum = self.archive([("driver.inf", b"original")])
        path.write_bytes(path.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            tools.archive(path, checksum)

    def test_path_traversal_absolute_and_case_collision_are_refused(self):
        for entries in [
            [("../outside", b"x")], [("/outside", b"x")], [("a/../outside", b"x")],
            [("driver.inf", b"one"), ("DRIVER.INF", b"two")],
        ]:
            with self.subTest(entries=entries):
                path, checksum = self.archive(entries)
                with self.assertRaises(ValueError):
                    tools.archive(path, checksum)

    def test_symlink_payload_and_archive_are_refused(self):
        entry = zipfile.ZipInfo("driver.inf")
        entry.create_system = 3
        entry.external_attr = 0o120777 << 16
        path, checksum = self.archive([(entry, b"outside")])
        with self.assertRaises(ValueError):
            tools.archive(path, checksum)
        link = path.with_name("alias.zip")
        link.symlink_to(path)
        with self.assertRaises(ValueError):
            tools.archive(link, checksum)

    def test_valid_payload_remains_byte_exact(self):
        path, checksum = self.archive([("drivers/netkvm.inf", bytes(range(256)))])
        self.assertEqual(tools.archive(path, checksum), {"drivers/netkvm.inf": bytes(range(256))})

    def test_corrupt_or_unbounded_iso_is_refused(self):
        for data in (b"", bytes(21 * 2048), bytes(33 << 20)):
            with self.assertRaises(ValueError):
                tools.iso_files(data)

    def test_header_pins_complete_payload_and_correct_services(self):
        value = tools.header({"drivers/network/file.inf": b"payload"}, tools.PACKAGES)
        self.assertIn('L"drivers\\\\network\\\\file.inf"', value)
        self.assertIn('L"VirtioSerial"', value)
        self.assertNotIn('L"vioser",', value)
        self.assertIn("0x" + hashlib.sha256(b"payload").hexdigest()[:2], value)

    def test_both_graphics_profiles_require_a_present_gpu(self):
        # 2D does not need registry restoration, but still promises a GPU.
        # Missing hardware must not silently produce the optional-device skip.
        for service, restoration in (("VioGpuDod", False), ("VioGpu3D", True)):
            with self.subTest(service=service):
                packages = tools.PACKAGES + [
                    ("Graphics", "graphics.inf", "PCI\\VEN_1AF4&DEV_1050",
                     "PCI\\VEN_1AF4&DEV_1050", service, restoration)
                ]
                value = tools.header({"graphics.inf": b"payload"}, packages)
                self.assertIn('L"' + service + '",' + str(int(restoration)) + ',1}', value)
                self.assertIn('L"netkvm",0,0}', value)
                self.assertIn('L"VirtioSerial",0,0}', value)


if __name__ == "__main__":
    unittest.main()
