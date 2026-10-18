#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build and preserve one immutable release decoder benchmark; never execute it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import build_manifest


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def save_json(path, value):
    save(path, (json.dumps(value, indent=2) + "\n").encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    if not args.build:
        print("SKIP: explicit component build required; no benchmark or guest executed")
        return 0
    snapshot = build_manifest.source_snapshot(ROOT)
    benchmark = ROOT / "Benchmarks/RfbReceive/main.swift"
    benchmark_pin, builder_pin = digest(benchmark), digest(Path(__file__))
    artifact = ROOT / ".lab" / ("rfb-receive-artifacts-" + uuid.uuid4().hex)
    artifact.mkdir(mode=0o700)
    decoder_pin = next(row["sha256"] for row in snapshot["files"] if row["path"] == "Backends/Qemu/RfbDecoder.swift")
    save(artifact / "decoder.swift", (ROOT / "Backends/Qemu/RfbDecoder.swift").read_bytes())
    save(artifact / "benchmark.swift", benchmark.read_bytes())
    if digest(artifact / "decoder.swift") != decoder_pin or digest(artifact / "benchmark.swift") != benchmark_pin:
        raise ValueError("Retained component source differs from admission")
    save_json(artifact / "source-snapshot.json", snapshot)
    command = ["./scripts/swift.sh", "build", "--configuration", "release", "--product", "RfbReceiveBenchmark"]
    save_json(artifact / "admission.json", {"sourceSnapshot": snapshot, "benchmarkSHA256": benchmark_pin,
                                           "builderSHA256": builder_pin, "command": command})
    with (artifact / "build.log").open("xb") as out:
        child = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=subprocess.STDOUT, close_fds=True)
        exit_code = child.wait()
    if exit_code:
        save_json(artifact / "failure.json", {"buildExit": exit_code, "command": command,
                                              "benchmarkExecuted": False})
        print(json.dumps({"artifact": str(artifact), "buildExit": exit_code}), flush=True)
        return exit_code
    if (snapshot != build_manifest.source_snapshot(ROOT) or digest(benchmark) != benchmark_pin
            or digest(Path(__file__)) != builder_pin):
        raise ValueError("Component build inputs changed; preserve without adoption")
    location = subprocess.check_output(["./scripts/swift.sh", "build", "--configuration", "release", "--show-bin-path"],
                                       cwd=ROOT, stderr=subprocess.PIPE, text=True).strip()
    binary = artifact / "RfbReceiveBenchmark"
    produced = Path(location) / binary.name
    before_binary = produced.stat()
    binary_pin = digest(produced)
    save(binary, produced.read_bytes())
    after_binary = produced.stat()
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if (any(getattr(before_binary, key) != getattr(after_binary, key) for key in fields)
            or digest(produced) != binary_pin or digest(binary) != binary_pin):
        raise ValueError("Produced component binary changed during copy")
    binary.chmod(0o500)
    toolchain = {
        "swift": subprocess.check_output(["xcrun", "swift", "--version"], stderr=subprocess.STDOUT).decode().strip(),
        "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).decode().strip(),
        "hostArchitecture": platform.machine(),
    }
    record = {"schemaVersion": 1, "scope": "RFB-decoder-component-release-build", "configuration": "release",
              "sourceSnapshot": snapshot, "benchmarkSHA256": benchmark_pin,
              "decoderSHA256": digest(artifact / "decoder.swift"), "binarySHA256": digest(binary),
              "binaryBytes": binary.stat().st_size, "toolchain": toolchain, "buildExit": 0,
              "command": command, "builderSHA256": builder_pin, "guestStarted": False, "UIQualified": False}
    if (snapshot != build_manifest.source_snapshot(ROOT) or digest(benchmark) != benchmark_pin
            or digest(Path(__file__)) != builder_pin or digest(artifact / "decoder.swift") != decoder_pin
            or digest(artifact / "benchmark.swift") != benchmark_pin or digest(binary) != binary_pin):
        raise ValueError("Final component build inputs changed; preserve without adoption")
    save_json(artifact / "build-record.json", record)
    for path in artifact.iterdir():
        if path != binary:
            path.chmod(0o600)
    print(json.dumps({"artifact": str(artifact), "binarySHA256": record["binarySHA256"], "buildExit": 0}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
