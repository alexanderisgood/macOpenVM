#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit generated-frame decoder measurement, with immutable build provenance."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import build_manifest
from validate_result import validate_result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sysctl(key):
    result = subprocess.run(["/usr/sbin/sysctl", "-n", key], capture_output=True, text=True, timeout=10, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def save(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def validate_component(raw):
    expected = {"schemaVersion", "scope", "decodeScope", "cachePolicy", "hostOS", "trials",
                "maximumFeedBytes", "fragmentPattern", "workloadWallBudgetSeconds",
                "correctnessOutsideTiming", "snapshotMeasuredSeparately",
                "guestPerformanceVerified", "uiFramePacingVerified", "cases"}
    require(isinstance(raw, dict) and set(raw) == expected and raw["schemaVersion"] == 1
            and raw["scope"] == "generated-public-RFB-decoder-component" and raw["trials"] == 5,
            "closed component result required")
    require(raw["decodeScope"] == "feed-dispatch-buffering-and-empty-feed-drain"
            and raw["cachePolicy"] == "sequential-process-trials-no-cache-reset"
            and isinstance(raw["hostOS"], str) and 0 < len(raw["hostOS"]) <= 128,
            "fixed timing/cache scope required")
    require(raw["maximumFeedBytes"] == 65536 and raw["fragmentPattern"] == [1, 3, 7, 65536, 65533, 31]
            and raw["workloadWallBudgetSeconds"] == 120 and raw["correctnessOutsideTiming"] is True
            and raw["snapshotMeasuredSeparately"] is True and raw["guestPerformanceVerified"] is False
            and raw["uiFramePacingVerified"] is False, "component scope changed")
    require(isinstance(raw["cases"], list) and len(raw["cases"]) == 9, "nine component cases required")
    seen = set()
    expected_hashes = {}
    for case in raw["cases"]:
        require(isinstance(case, dict) and set(case) == {"name", "width", "height", "rectangleWidth", "rectangleHeight",
                             "rectangles", "wireBytes", "chunks", "snapshotBytes", "frameSHA256", "samples"},
                "closed case required")
        require(isinstance(case["name"], str)
                and all(type(case[field]) is int for field in ("width", "height", "rectangleWidth", "rectangleHeight",
                                                               "rectangles", "wireBytes", "chunks", "snapshotBytes")),
                "typed case geometry required")
        key = (case["name"], case["width"], case["height"])
        require(key not in seen and key[0] in ("initial-full", "steady-full", "dirty")
                and key[1:] in ((1280, 720), (2560, 1440), (3840, 2160)), "unique fixed case required")
        seen.add(key)
        rect = (48, 32) if case["name"] == "dirty" else key[1:]
        require((case["rectangleWidth"], case["rectangleHeight"]) == rect and case["rectangles"] == 1
                and case["wireBytes"] == 16 + rect[0] * rect[1] * 4
                and case["snapshotBytes"] == case["width"] * case["height"] * 4
                and case["chunks"] == fragment_count(case["wireBytes"])
                and isinstance(case["frameSHA256"], str)
                and re.fullmatch(r"[0-9a-f]{64}", case["frameSHA256"]), "case geometry/hash required")
        hash_key = (case["width"], case["height"], case["name"] == "dirty")
        if hash_key not in expected_hashes:
            expected_hashes[hash_key] = reference_frame_hash(*hash_key)
        require(case["frameSHA256"] == expected_hashes[hash_key], "independent expected public-frame hash required")
        require(isinstance(case["samples"], list) and len(case["samples"]) == 5, "five retained samples required")
        for sample in case["samples"]:
            require(isinstance(sample, dict) and set(sample) == {"decodeMS", "snapshotMS"}
                    and all(type(value) in (int, float) and math.isfinite(value) and value >= 0
                            for value in sample.values()), "finite timing samples required")


def fragment_count(count):
    sizes = (1, 3, 7, 65536, 65533, 31)
    offset = index = 0
    while offset < count:
        offset += min(sizes[index % len(sizes)], count - offset)
        index += 1
    return index


def reference_frame_hash(width, height, dirty):
    # Independent row-oriented RGBA construction. This runs after the child has
    # exited, outside every measured interval, and stores no image artifact.
    value = hashlib.sha256()
    base = [bytes((x & 255, y, (x + y) & 255, 255)) for y in range(256) for x in range(256)]
    for y in range(height):
        start = (y & 255) * 256
        tile = b"".join(base[start:start + 256])
        row = bytearray((tile * ((width + 255) // 256))[:width * 4])
        if dirty and 23 <= y < 55:
            for x in range(17, 65):
                at = x * 4
                row[at:at + 4] = bytes(((x + 17) & 255, (y + 11) & 255, (x + y + 7) & 255, 255))
        value.update(row)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--label", choices=("baseline", "row-segments", "buffer-reuse", "borrowed-raw"))
    args = parser.parse_args()
    if not args.run:
        print("SKIP: explicit decoder component run required; no guest or app started")
        return 0
    artifact = args.artifact
    require(artifact is not None and artifact.parent == ROOT / ".lab"
            and re.fullmatch(r"rfb-decode-artifacts-[0-9a-f]{32}", artifact.name)
            and args.label is not None, "qualified immutable component build required")
    build = build_manifest.bounded_json(artifact / "build-record.json")
    binary = artifact / "RfbDecodeBenchmark"
    info = binary.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid()
            and stat.S_IMODE(info.st_mode) == 0o500 and digest(binary) == build["binarySHA256"]
            and build["configuration"] == "release" and build["buildExit"] == 0,
            "immutable release benchmark required")
    require(build["sourceSnapshot"] == build_manifest.source_snapshot(ROOT)
            and digest(ROOT / "Benchmarks/RfbDecode/main.swift") == build["benchmarkSHA256"],
            "current exact build inputs required")
    harness_pin = digest(Path(__file__))
    helper_pins = {str(path.relative_to(ROOT)): digest(path) for path in (
        ROOT / "scripts/build_manifest.py", ROOT / "Benchmarks/validate_result.py",
        ROOT / "Benchmarks/result.schema.json")}
    token = uuid.uuid4().hex
    session = ROOT / ".lab" / ("rfb-decode-measurement-" + token)
    session.mkdir(mode=0o700)
    save(session / "admission.json", {"label": args.label, "buildRecordSHA256": digest(artifact / "build-record.json"),
                                     "harnessSHA256": harness_pin, "guestStarted": False})
    # This child has no VM, sockets or persistent state. Its bounded workload
    # self-refuses on budget; the parent waits for its actual terminal result.
    with (session / "component.stdout").open("xb") as out, (session / "component.stderr").open("xb") as err:
        child = subprocess.Popen([str(binary), "--run", "--trials", "5"], stdin=subprocess.DEVNULL,
                                 stdout=out, stderr=err, close_fds=True)
        exit_code = child.wait()
    require(exit_code == 0 and (session / "component.stderr").stat().st_size == 0,
            "component child did not complete successfully")
    raw = build_manifest.bounded_json(session / "component.stdout", 16384)
    validate_component(raw)
    require(build["sourceSnapshot"] == build_manifest.source_snapshot(ROOT)
            and digest(binary) == build["binarySHA256"] and digest(Path(__file__)) == harness_pin
            and digest(ROOT / "Benchmarks/RfbDecode/main.swift") == build["benchmarkSHA256"],
            "measurement inputs changed")
    require(all(digest(ROOT / path) == pin for path, pin in helper_pins.items()),
            "measurement helper inputs changed")
    metrics = []
    for case in raw["cases"]:
        for field, definition in [("decodeMS", "All production feed calls and empty-feed draining; fixture generation, handshake and correctness checks excluded"),
                                  ("snapshotMS", "Production Data(canvas) snapshot only; hashing and pixel validation excluded")]:
            metrics.append({"name": f"{case['name']}_{case['width']}x{case['height']}_{field}",
                            "unit": "ms", "samples": [sample[field] for sample in case["samples"]],
                            "definition": definition})
    raw_ram = sysctl("hw.memsize")
    filesystem = os.statvfs(ROOT)
    host = {"model": sysctl("hw.model"), "chip": sysctl("machdep.cpu.brand_string"),
            "performanceCores": None, "efficiencyCores": None, "gpuCores": None,
            "ramBytes": int(raw_ram) if raw_ram and raw_ram.isdigit() else None,
            "storageModel": None, "storageFreeBytes": filesystem.f_bavail * filesystem.f_frsize,
            "powerMode": None, "thermalState": None, "displays": None,
            "macOSVersion": raw["hostOS"], "macOSBuild": sysctl("kern.osversion")}
    guest = {name: None for name in ("os", "edition", "build", "architecture", "patchLevel", "agentVersion",
                                    "driverVersions", "vCPU", "ramBytes", "disk", "network")}
    result = {
        "schemaVersion": 1, "recordedAt": datetime.now(timezone.utc).isoformat(), "status": "measured",
        "host": host, "guest": guest,
        "application": {"revision": None, "sourceSHA256": build["sourceSnapshot"]["sha256"],
                        "version": "0.1.0-dev", "backend": "original RFB raw decoder host component",
                        "backendVersion": "RFC6143 raw scope", "entitlements": [],
                        "configuration": {"build": "release", "label": args.label,
                                          "binarySHA256": build["binarySHA256"], "decoderSHA256": build["decoderSHA256"],
                                          "benchmarkSHA256": build["benchmarkSHA256"], "harnessSHA256": harness_pin,
                                          "helperInputs": helper_pins,
                                          "toolchain": build["toolchain"], "cases": raw["cases"],
                                          "fragmentPattern": raw["fragmentPattern"]}},
        "method": {"cache": "uncontrolled", "trialCount": 5, "outlierPolicy": "retain all; no exclusions",
                   "confidenceInterval": None, "backgroundWorkload": "Interactive development host; not quiesced"},
        "metrics": metrics, "unknownReasons": {},
        "limitations": ["Generated public frames; no guest, network transport, AppKit drawing or display scanout.",
                        "Decoder and snapshot component timings are not frame pacing, input latency or virtualization parity.",
                        "Five sequential trials per case; cache, host background load, power and thermal state uncontrolled.",
                        "Build provenance is local and unsigned; no clean-machine release reproduction claim."]}
    for section in ("host", "guest", "application", "method"):
        for field, value in result[section].items():
            if value is None:
                result["unknownReasons"][f"{section}.{field}"] = (
                    "No guest exists in this component measurement" if section == "guest"
                    else "No statistical confidence interval claimed" if field == "confidenceInterval"
                    else "Not collected or unavailable in this component run")
    require(not validate_result(result), "benchmark evidence schema refused")
    save(session / "result.json", result)
    destination = ROOT / "Benchmarks/results" / ("rfb-decoder-" + args.label + "-" + token + ".json")
    save(destination, result)
    print(json.dumps({"session": str(session), "result": str(destination), "cases": 9,
                      "trialCount": 5, "actualChildExit": exit_code, "guestStarted": False}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
