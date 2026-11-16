#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded QEMU cache comparison on exclusive disposable files, never a VM disk."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time


def run(tool, path, mode, commands, readonly=False):
    args = [str(tool), "-f", "raw", "-t", mode]
    if readonly:
        args.append("-r")
    for command in commands:
        args.extend(["-c", command])
    args.append(str(path))
    started = time.monotonic()
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    elapsed = time.monotonic() - started
    if result.returncode:
        raise RuntimeError(f"QEMU failed ({result.returncode}): {result.stdout}{result.stderr}")
    if result.stdout.strip() or result.stderr.strip():
        raise RuntimeError(f"Unexpected QEMU output: {result.stdout}{result.stderr}")
    return elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qemu-io", type=Path, required=True)
    parser.add_argument("--scratch-parent", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This fixture measures the macOS POSIX storage path.")
    tool = args.qemu_io.resolve(strict=True)
    parent = args.scratch_parent.resolve(strict=True)
    version = subprocess.check_output([str(tool), "--version"], text=True).splitlines()[0]
    tool_hash = hashlib.sha256(tool.read_bytes()).hexdigest()
    block_size, blocks = 4096, 4096
    size = block_size * blocks
    report = {
        "schemaVersion": 1, "qemuVersion": version, "qemuSHA256": tool_hash,
        "harnessSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "hostArchitecture": platform.machine(), "macOSVersion": platform.mac_ver()[0],
        "bytesPerTrial": size, "writeSize": block_size, "samples": [],
        "scope": "Host QEMU block fixture; not a Windows/native-speed comparison.",
        "timing": "Process startup, writes and final flush; excludes reopened verification.",
        "load": "Uncontrolled; record concurrent host workloads separately.",
    }
    # Refuse overwriting evidence and accept no path to an existing disk.
    with args.output.open("x") as output:
        try:
            with tempfile.TemporaryDirectory(prefix="macopenvm-cache-", dir=parent) as scratch:
                disk = Path(scratch) / "fixture.raw"
                for trial in range(3):
                    modes = ("none", "writeback") if trial % 2 == 0 else ("writeback", "none")
                    for mode in modes:
                        fd = os.open(disk, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
                        try:
                            os.ftruncate(fd, size)
                        finally:
                            os.close(fd)
                        pattern = 40 + trial
                        # A coprime permutation exercises small writes across the file.
                        commands = [
                            f"write -q -P {pattern} {((i * 73) % blocks) * block_size} {block_size}"
                            for i in range(blocks)
                        ]
                        seconds = run(tool, disk, mode, commands + ["flush"])
                        run(tool, disk, "writeback", [f"read -q -P {pattern} 0 {size}"], True)
                        run(tool, disk, mode, ["write -q -f -P 91 0 4096"])
                        run(tool, disk, "writeback", ["read -q -P 91 0 4096"], True)
                        report["samples"].append({
                            "trial": trial, "cache": mode, "seconds": seconds,
                            "MiBPerSecondIncludingFlush": size / (1 << 20) / seconds,
                            "reopenVerified": True, "fuaReopenVerified": True,
                        })
                        disk.unlink()
            report["passed"] = True
        except Exception as error:
            report["passed"] = False
            report["error"] = str(error)
            raise
        finally:
            json.dump(report, output, indent=2)
            output.write("\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
