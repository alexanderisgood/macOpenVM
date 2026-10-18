#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit native DXMT shared-source ordering component; never access a VM."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import sys

from metal_surface import ROOT, bounded_json, digest, owned_child, public_build, require, save, sysctl, validate_result

LIBRARY_SHA256 = "c6ec27b5ec818e8d13e5a3f09419f524c6990f500af7c4e1e870b966302f6b80"
HEADER_TREE_SHA256 = "7334cb857dfba447796e6896d287a6e4abb398fc6bc86dd474fd54cb2903c1ab"
SOURCES = ["Fixture.h", "DxmtSource.h", "DxmtSource.cpp", "ProducerOrdering.m"]
INPUTS = ["Benchmarks/dxmt_surface.py", "Benchmarks/metal_surface.py", "Benchmarks/validate_result.py",
          "Benchmarks/result.schema.json", "scripts/build_manifest.py"] + [
    "Benchmarks/MetalSurface/" + name for name in SOURCES]


def inputs():
    return {name: digest(ROOT / name) for name in INPUTS}


def headers(source):
    require(source is not None, "Explicit reviewed DXMT source directory required")
    names = []
    for top in ["include/native/windows", "include/native/directx"]:
        names += [p.relative_to(source).as_posix() for p in sorted((source / top).rglob("*")) if p.is_file()]
    names += ["src/dxmt-native/dxmt_native.h"]
    require(all(not (source / n).is_symlink() for n in names), "Ordinary reviewed headers required")
    pins = {n: digest(source / n) for n in names}
    aggregate = hashlib.sha256(json.dumps(pins, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    require(len(pins) == 79 and aggregate == HEADER_TREE_SHA256, "Headers differ from reviewed DXMT source")
    return pins


def build(source, library):
    import subprocess
    import uuid
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "Apple-silicon macOS required")
    before, header_pins = inputs(), headers(source)
    require(library is not None and not library.is_symlink() and library.is_file() and
            library.stat().st_size == 29387984 and digest(library) == LIBRARY_SHA256,
            "Exact reviewed native DXMT library required; see private GPU catalog")
    artifact = ROOT / ".lab" / ("dxmt-surface-artifacts-" + uuid.uuid4().hex)
    artifact.mkdir(mode=0o700)
    for name in INPUTS:
        retained = artifact / "recipe" / name
        retained.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, retained)
        retained.chmod(0o400)
    for name in SOURCES:
        shutil.copyfile(ROOT / "Benchmarks/MetalSurface" / name, artifact / name)
        (artifact / name).chmod(0o400)
    for name in header_pins:
        destination = artifact / "headers" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, destination)
        destination.chmod(0o400)
    copied_library = artifact / "libdxmt-native.dylib"
    shutil.copyfile(library, copied_library)
    copied_library.chmod(0o400)
    require(digest(copied_library) == LIBRARY_SHA256, "Copied DXMT changed")
    operations, binaries = [], {}
    verify = owned_child(["/usr/bin/codesign", "--verify", "--strict", str(copied_library)], artifact, "library-signature")
    operations.append(verify)
    require(verify["actualExit"] == 0, "Reviewed local library signature invalid")
    for suffix, checked in [("Release", False), ("Checked", True)]:
        flags = ["-O1" if checked else "-O2", "-Wall", "-Wextra", "-Werror", "-arch", "arm64",
                 "-mmacosx-version-min=14.0"]
        if checked:
            flags += ["-g", "-fsanitize=address,undefined"]
        include = artifact / "headers"
        commands = [
            ["/usr/bin/xcrun", "clang++", "-std=c++20", "-Wno-unused-parameter"] + flags +
            ["-isystem", str(include / "include/native/windows"), "-isystem", str(include / "include/native/directx"),
             "-isystem", str(include / "src/dxmt-native"), "-c", str(artifact / "DxmtSource.cpp"),
             "-o", str(artifact / (suffix + "-source.o"))],
            ["/usr/bin/xcrun", "clang", "-fno-objc-arc"] + flags +
            ["-c", str(artifact / "ProducerOrdering.m"), "-o", str(artifact / (suffix + "-ordering.o"))],
            ["/usr/bin/xcrun", "clang++"] + flags +
            [str(artifact / (suffix + "-source.o")), str(artifact / (suffix + "-ordering.o")),
             "-framework", "Foundation", "-framework", "Metal", "-framework", "IOSurface",
             "-L" + str(artifact), "-ldxmt-native", "-Wl,-rpath," + str(artifact),
             "-o", str(artifact / suffix)]]
        for index, command in enumerate(commands):
            operation = owned_child(command, artifact, suffix + "-build-" + str(index))
            operations.append(operation)
            if operation["actualExit"]:
                save(artifact / "failed-build.json", {"inputs": before, "operations": operations})
                raise ValueError("Component build failed; diagnostics at " + str(artifact))
        (artifact / suffix).chmod(0o500)
        binaries[suffix] = {"bytes": (artifact / suffix).stat().st_size, "sha256": digest(artifact / suffix)}
    require(before == inputs() and header_pins == headers(source), "Source changed during build")
    require(all(digest(artifact / "headers" / n) == pin for n, pin in header_pins.items()), "Copied header changed")
    record = {"scope": "native-DXMT-shared-source-ordering-component-build", "inputs": before,
              "binaries": binaries, "operations": operations, "headers": header_pins,
              "librarySHA256": LIBRARY_SHA256,
              "toolchain": {"clang": subprocess.check_output(["xcrun", "clang", "--version"], text=True).strip(),
                            "sdk": subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip(),
                            "target": "arm64-apple-macos14"}}
    save(artifact / "build-record.json", record)
    (artifact / "build-record.json").chmod(0o400)
    print(json.dumps({"artifact": str(artifact), "actualBuildExits": [op["actualExit"] for op in operations]}))


def validate_ordering(raw):
    fields = {"scope", "passed", "sourceExclusiveOwnershipIsFixtureOnly", "windowsPresentOrPhysicalPresentationQualified",
              "pollableEventAndFenceValueBothChecked", "earlyEventHandleCloseExercised", "noPixelFiles", "cases"}
    require(type(raw) is dict and set(raw) == fields and
            raw["scope"] == "native-DXMT-completed-shared-source-IOSurface-component", "Closed source-ordering result required")
    require(all(raw[n] is True for n in fields - {"scope", "cases", "windowsPresentOrPhysicalPresentationQualified"}) and
            raw["windowsPresentOrPhysicalPresentationQualified"] is False, "Narrow component claim required")
    require(type(raw["cases"]) is list and len(raw["cases"]) == 8, "Eight source cases required")
    for index, case in enumerate(raw["cases"]):
        expected = {"width", "height", "dxgiFormat", "sourceFormat", "surfaceFormat",
                    "allPixelsCorrectAfterSourceOverwrite", "warmups", "samples"}
        require(type(case) is dict and set(case) == expected and
                all(type(case[n]) is int for n in expected - {"allPixelsCorrectAfterSourceOverwrite", "samples"}),
                "Closed integer source geometry required")
        require((case["width"], case["height"]) == ((3456, 2168) if index < 4 else (3840, 2160)) and
                case["dxgiFormat"] == [87, 91, 28, 29][index % 4] and
                case["sourceFormat"] == [80, 81, 70, 71][index % 4] and case["surfaceFormat"] == [80, 81][index % 2] and
                case["allPixelsCorrectAfterSourceOverwrite"] is True and case["warmups"] == 2 and
                type(case["samples"]) is list and len(case["samples"]) == 5,
                "Exact native/4K formats, overwrite correctness and sample count required")
        for sample in case["samples"]:
            require(type(sample) is dict and set(sample) == {"producerFenceWaitMS", "exportSubmitAndWaitMS",
                    "consumerDrawAndWaitMS", "sourceOverwriteFenceWaitMS"} and
                    all(type(v) in (int, float) and math.isfinite(v) and v >= 0 for v in sample.values()),
                    "Closed finite source/export/draw timing scopes required")


def run(artifact):
    import uuid
    require(artifact is not None and artifact.parent == ROOT / ".lab" and
            re.fullmatch(r"dxmt-surface-artifacts-[0-9a-f]{32}", artifact.name), "Use one frozen DXMT component artifact")
    record = bounded_json(artifact / "build-record.json")
    require(record["inputs"] == inputs() and all(op["actualExit"] == 0 for op in record["operations"]),
            "Current exact successful build required")
    require(all(digest(artifact / "recipe" / n) == pin for n, pin in record["inputs"].items()) and
            all(digest(artifact / "headers" / n) == pin for n, pin in record["headers"].items()) and
            digest(artifact / "libdxmt-native.dylib") == LIBRARY_SHA256, "Retained recipe or DXMT changed")
    for name, pin in record["binaries"].items():
        info = (artifact / name).lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1 and
                stat.S_IMODE(info.st_mode) == 0o500 and info.st_size == pin["bytes"] and
                digest(artifact / name) == pin["sha256"], "Immutable owned executable required")
    session = ROOT / ".lab" / ("dxmt-surface-measurement-" + uuid.uuid4().hex)
    session.mkdir(mode=0o700)
    measurements, operations = {}, []
    for name in ["Release", "Checked"]:
        operation = owned_child([str(artifact / name), "--run"], session, name)
        operations.append(operation)
        save(session / (name + "-operation.json"), operation)
        require(operation["actualExit"] == 0, "DXMT ordering failed; diagnostics at " + str(session))
        raw = bounded_json(session / (name + ".stdout"))
        validate_ordering(raw)
        errors = (session / (name + ".stderr")).read_text(errors="replace")
        require("ERROR: AddressSanitizer" not in errors and "runtime error:" not in errors, "Sanitizer finding")
        measurements[name] = raw
    # Sanitizer timing is retained privately, not used as a performance comparison.
    public = public_build(record)
    public.update(headersSHA256=HEADER_TREE_SHA256, librarySHA256=LIBRARY_SHA256)
    ram, filesystem = sysctl("hw.memsize"), os.statvfs(ROOT)
    host = {"model": sysctl("hw.model"), "chip": sysctl("machdep.cpu.brand_string"), "performanceCores": None,
            "efficiencyCores": None, "gpuCores": None, "ramBytes": int(ram) if ram and ram.isdigit() else None,
            "storageModel": None, "storageFreeBytes": filesystem.f_bavail * filesystem.f_frsize,
            "powerMode": None, "thermalState": None, "displays": None,
            "macOSVersion": platform.mac_ver()[0] or None, "macOSBuild": sysctl("kern.osversion")}
    guest = {n: None for n in ["os", "edition", "build", "architecture", "patchLevel", "agentVersion",
                              "driverVersions", "vCPU", "ramBytes", "disk", "network"]}
    metrics = []
    for case in measurements["Release"]["cases"]:
        for field in case["samples"][0]:
            metrics.append({"name": f"{case['width']}x{case['height']}_{case['dxgiFormat']}_{field}", "unit": "ms",
                            "samples": [sample[field] for sample in case["samples"]],
                            "definition": "Native DXMT generated shared-source completion/export component; excludes Windows present and scanout"})
    result = {"schemaVersion": 1, "recordedAt": datetime.now(timezone.utc).isoformat(), "status": "measured",
              "host": host, "guest": guest,
              "application": {"revision": None, "sourceSHA256": hashlib.sha256(json.dumps(record["inputs"], sort_keys=True).encode()).hexdigest(),
                              "version": "0.1.0-dev", "backend": "native DXMT/Metal/IOSurface component", "backendVersion": "reviewed DXMT native library",
                              "entitlements": [], "configuration": {"build": public, "release": measurements["Release"],
                              "checkedCorrectnessPassed": True, "actualProducerExits": [op["actualExit"] for op in operations]}},
              "method": {"cache": "uncontrolled", "trialCount": 5, "outlierPolicy": "retain all; two declared warmups per case",
                         "confidenceInterval": None, "backgroundWorkload": "Live Windows VM and interactive development host; load uncontrolled"},
              "metrics": metrics, "unknownReasons": {}, "limitations": [
                  "No VM, Windows present path or physical display is exercised; generated offscreen D3D11 only.",
                  "Source ownership is enforced by this single-purpose fixture; real guest ownership and failure paths remain unqualified.",
                  "All pixels checked after source overwrite; one-process source import/export and consumer draw, not a new cross-process claim.",
                  "Producer event/fence wait scope is separate and is not full rendering or presentation latency.",
                  "Five release samples per case, no CI, FPS,120Hz or regression claim; sanitizer timings excluded from performance metrics.",
                  "Local unsigned component provenance, reviewed library signature and hashes; no release-distribution clearance."]}
    for section in ["host", "guest", "application", "method"]:
        for key, value in result[section].items():
            if value is None:
                result["unknownReasons"][section + "." + key] = "No guest in this component" if section == "guest" else "Not collected or no statistical claim"
    require(record["inputs"] == inputs() and digest(artifact / "libdxmt-native.dylib") == LIBRARY_SHA256 and
            all(digest(artifact / n) == p["sha256"] for n, p in record["binaries"].items()), "Inputs changed during run")
    require(not validate_result(result), "Benchmark schema refused")
    save(session / "result.json", result)
    destination = ROOT / "Benchmarks/results" / ("dxmt-surface-" + uuid.uuid4().hex + ".json")
    save(destination, result)
    print(json.dumps({"result": str(destination), "session": str(session), "actualProducerExits": [op["actualExit"] for op in operations]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--build", action="store_true")
    choice.add_argument("--run", action="store_true")
    parser.add_argument("--dxmt-source", type=Path)
    parser.add_argument("--dxmt-library", type=Path)
    parser.add_argument("--artifact", type=Path)
    args = parser.parse_args()
    if args.build:
        build(args.dxmt_source, args.dxmt_library)
    elif args.run:
        run(args.artifact)
    else:
        print("SKIP: explicit native DXMT component build/run required; no VM or screen opened")


if __name__ == "__main__":
    main()
