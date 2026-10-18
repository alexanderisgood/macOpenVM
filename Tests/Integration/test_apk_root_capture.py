# SPDX-License-Identifier: Apache-2.0
"""Exercise real report commands with wrapped echo; no APK or guest execution."""
import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

from support_media_live import DeliveryFailure, simulation_blob


class ReportConsole:
    def __init__(self):
        self.rows = []

    def lines(self, deadline=None):
        return self.rows


class APKRootCaptureTests(unittest.TestCase):
    marker = "mvo-support-" + "0" * 32
    body = b"fixed public package log\n"

    def capture(self, width, duplicate=False):
        with tempfile.TemporaryDirectory(prefix="mvo-report-") as directory:
            root = Path(directory)
            (root / "apply.log").write_bytes(self.body)
            console = ReportConsole()
            python = shlex.quote(sys.executable)
            # These portable fixture tools read actual bytes. The report commands
            # and mvo_pf formatting themselves execute unchanged in a real shell.
            hash_code = "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()+'  '+sys.argv[1])"
            base_code = "import base64,sys; print(base64.b64encode(open(sys.argv[1],'rb').read()).decode())"
            prelude = ('mvo_pf() { printf "\\n%s.%s=%s\\n" "$mvo_sim_marker" "$1" "$2"; }; '
                       + "sha256sum() { " + python + " -c " + shlex.quote(hash_code) + ' "$1"; }; '
                       + "base64() { " + python + " -c " + shlex.quote(base_code) + ' "$1"; }; ')
            env = dict(os.environ, mvo_dir=str(root), mvo_sim_marker=self.marker)

            def sender(observed, owner, marker, command, key, expected, seconds=30):
                self.assertLessEqual(len(command.encode()), 1024)
                echo = ("localhost:~# " + command.rstrip("\n")).encode()
                observed.rows.extend(echo[start:start + width] for start in range(0, len(echo), width))
                run = subprocess.run(["/bin/sh"], input=(prelude + command).encode(),
                                     env=env, capture_output=True, timeout=5)
                self.assertEqual(run.returncode, 0, run.stderr)
                observed.rows.extend(run.stdout.splitlines())
                if duplicate and key == "prepLogInfo":
                    observed.rows.append((marker + ".prepLogSHA256="
                        + hashlib.sha256(self.body).hexdigest()).encode())

            return simulation_blob(console, None, self.marker, "prepLog", '"$mvo_dir/apply.log"',
                                   32768, {}, root, sender=sender, dynamic_markers=True)

    def test_real_report_survives_wrapped_terminal_echo(self):
        for width in (72, 80, 96):
            with self.subTest(width=width):
                self.assertEqual(self.capture(width), self.body)

    def test_actual_duplicate_observation_still_rejects(self):
        with self.assertRaisesRegex(DeliveryFailure, "^apkRead$"):
            self.capture(80, duplicate=True)


if __name__ == "__main__":
    unittest.main()
