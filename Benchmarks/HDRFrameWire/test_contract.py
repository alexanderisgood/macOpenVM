#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Portable CPU-only contract checks for the actual HDR foundation C source."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WIRE = ROOT / "Backends" / "SharedFrameWire"
FIXTURE = Path(__file__).with_name("test_shared_hdr_frame_wire.c")


class HDRFrameWireContract(unittest.TestCase):
    def run_owned(self, command, directory, environment):
        """Own/reap each CPU process, with a 30-second process-group deadline."""
        child = subprocess.Popen(command, cwd=directory, env=environment,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=os.name == "posix")
        try:
            stdout, stderr = child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                child.kill()
            stdout, stderr = child.communicate()
            self.fail("CPU check exceeded 30 seconds: " + str(command) + "\n" +
                      stderr[-16000:].decode("utf-8", errors="replace"))
        self.assertEqual(child.returncode, 0, "Command failed: " + str(command) + "\n" +
                         stderr[-16000:].decode("utf-8", errors="replace") + "\n" +
                         stdout[-16000:].decode("utf-8", errors="replace"))
        return stdout

    def check_variant(self, sanitized):
        # CC is an executable name/path, never shell text. No network, Swift,
        # Metal, app, VM, guest, driver or global installation is invoked.
        compiler = shutil.which(os.environ.get("CC", "clang"))
        self.assertIsNotNone(compiler, "Clang is required; set CC to its executable path")
        with tempfile.TemporaryDirectory(prefix="mvo-hdr-frame-wire-") as temporary:
            directory = Path(temporary)
            executable = directory / ("contract.exe" if os.name == "nt" else "contract")
            environment = os.environ.copy()
            environment.update({"LC_ALL": "C", "TMPDIR": temporary,
                                "ASAN_OPTIONS": "detect_leaks=0:abort_on_error=1"})
            flags = ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if sanitized else ["-O2"]
            command = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wconversion",
                       "-Wshadow", "-Wstrict-prototypes", "-pedantic"] + flags + [
                           "-I", str(WIRE / "include"), str(WIRE / "SharedHDRFrameWire.c"),
                           str(FIXTURE), "-o", str(executable)]
            self.run_owned(command, directory, environment)
            result = json.loads(self.run_owned([str(executable)], directory, environment))
            self.assertIs(result.get("passed"), True)
            self.assertEqual(result.get("groups"), 8)
            self.assertEqual(result.get("randomized_operations"), 20000)
            self.assertGreater(result.get("assertions", 0), 50000)

    def test_address_and_undefined_behavior_sanitizers(self):
        self.check_variant(sanitized=True)

    def test_optimized(self):
        self.check_variant(sanitized=False)


if __name__ == "__main__":
    unittest.main()
