#!/usr/bin/env python3
"""Exercise the production display sender in a windowless QEMU event loop."""
# SPDX-License-Identifier: Apache-2.0
import argparse
import json
import shlex
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("qemu_build", type=Path, help="configured, built macOS QEMU directory")
    args = parser.parse_args()
    build = args.qemu_build.resolve()
    fixtures = Path(__file__).resolve().parent
    repo = fixtures.parents[1]
    wire = repo / "Backends/SharedFrameWire"
    platform_fixture = repo / "Tests/SharedFrameFixture"

    entries = json.loads((build / "compile_commands.json").read_text())
    entry = next(row for row in entries if row["file"].endswith("/ui/mvo-shared-frame.c"))
    compiler = shlex.split(entry["command"])
    # Reuse the QEMU compile flags and the unit test's event-loop link closure.
    with tempfile.TemporaryDirectory(prefix="mvo-qemu-scanout.", dir="/tmp") as output:
        output = Path(output)
        obj = output / "test.o"
        subprocess.run(
            compiler[:compiler.index("-MD")] + [
                "-I" + str(wire / "include"), "-I" + str(platform_fixture / "include"),
                "-c", str(fixtures / "QemuScanoutHandoff.c"), "-o", str(obj),
            ], cwd=build, check=True,
        )
        ninja = (build / "build.ninja").read_text().splitlines()
        target = next(i for i, line in enumerate(ninja) if line.startswith("build tests/unit/test-util-sockets:"))
        objects = shlex.split(ninja[target])[3:]
        objects = [item for item in objects[:objects.index("|")] if not item.startswith("tests/unit/")]
        link = shlex.split(ninja[target + 1].partition(" = ")[2])
        subprocess.run(
            [compiler[0], "-arch", "arm64", str(obj), *objects,
             "libsystem.a.p/ui_mvo-shared-frame.c.o", "libsystem.a.p/ui_mvo-metal-readback.m.o",
             "-I" + str(wire / "include"), "-I" + str(platform_fixture / "include"),
             str(wire / "SharedFrameWire.c"), str(wire / "SharedHDRFrameWire.c"),
             str(wire / "SharedHDRFrameTransport.c"), str(wire / "ScanoutLeasePool.c"),
             str(platform_fixture / "SharedFrameFixture.c"), *link,
             "-lproc", "-framework", "Foundation", "-framework", "Metal",
             "-o", str(output / "test")], cwd=build, check=True,
        )
        subprocess.run([str(output / "test"), str(output / "frames.sock")], check=True, timeout=15)


if __name__ == "__main__":
    main()
