#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit generated GPU surface experiment; never open or control a VM."""
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
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build_manifest import bounded_json
from validate_result import validate_result

SOURCES = ["Fixture.h", "SingleProcess.m", "TransportProbe.m"]
INPUTS = ["Benchmarks/metal_surface.py", "Benchmarks/validate_result.py",
          "Benchmarks/result.schema.json", "scripts/build_manifest.py"] + [
    "Benchmarks/MetalSurface/" + name for name in SOURCES]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    return {name: digest(ROOT / name) for name in INPUTS}


def save(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def owned_child(command, directory, stem):
    with (directory / (stem + ".stdout")).open("xb") as out, (directory / (stem + ".stderr")).open("xb") as err:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=err, close_fds=True, cwd=ROOT)
        code = child.wait()
    return {"actualExit": code, "actualParentReaped": True, "command": command}


def build():
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "Apple-silicon macOS build required")
    before = inputs()
    artifact = ROOT / ".lab" / ("metal-surface-artifacts-" + uuid.uuid4().hex)
    artifact.mkdir(mode=0o700)
    for name in INPUTS:
        retained = artifact / "recipe" / name
        retained.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, retained)
        retained.chmod(0o400)
    for name in SOURCES:
        shutil.copyfile(ROOT / "Benchmarks/MetalSurface" / name, artifact / name)
    operations = []
    binaries = {}
    for name, source, checked in [("SurfaceSingle", "SingleProcess.m", False),
                                  ("SurfaceTransport", "TransportProbe.m", False),
                                  ("SurfaceTransportChecked", "TransportProbe.m", True)]:
        command = ["/usr/bin/xcrun", "clang", "-O1" if checked else "-O2", "-Wall", "-Wextra", "-Werror",
                   "-fno-objc-arc", "-arch", "arm64", "-mmacosx-version-min=14.0"]
        if checked:
            command += ["-g", "-fsanitize=address,undefined"]
        command += ["-framework", "Foundation", "-framework", "Metal", "-framework", "IOSurface",
                    "-lbsm", str(artifact / source), "-o", str(artifact / name)]
        operation = owned_child(command, artifact, name + "-build")
        operations.append(operation)
        if operation["actualExit"]:
            save(artifact / "failed-build.json", {"operations": operations, "inputs": before})
            raise ValueError("Component build failed; retained diagnostics at " + str(artifact))
        (artifact / name).chmod(0o500)
        binaries[name] = {"sha256": digest(artifact / name), "bytes": (artifact / name).stat().st_size}
    require(before == inputs(), "Component inputs changed during build")
    require(all(digest(artifact / name) == before["Benchmarks/MetalSurface/" + name] for name in SOURCES),
            "Retained component sources changed")
    toolchain = {"clang": subprocess.check_output(["xcrun", "clang", "--version"], text=True).strip(),
                 "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
                 "target": "arm64-apple-macos14"}
    save(artifact / "build-record.json", {"scope": "generated-Metal-surface-component-build", "inputs": before,
                                        "binaries": binaries, "operations": operations, "toolchain": toolchain,
                                        "noVMAccess": True})
    for name in SOURCES + ["build-record.json"]:
        (artifact / name).chmod(0o400)
    print(json.dumps({"artifact": str(artifact), "buildActualExits": [x["actualExit"] for x in operations],
                      "noVMAccess": True}))


def sysctl(key):
    result = subprocess.run(["/usr/sbin/sysctl", "-n", key], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def validate_cases(raw, cross):
    require(type(raw) is dict, "Object component result required")
    cases = raw.get("cases")
    require(isinstance(cases, list) and len(cases) == 8, "Eight generated geometry/format cases required")
    for index, case in enumerate(cases):
        expected = {"width", "height", "sourceFormat", "surfaceFormat", "slots", "trials", "warmups", "samples"}
        expected |= {"allConsumerPixelsCorrect", "maximumInFlight"} if cross else {
            "allPixelsCorrect", "alphaForcedOpaque", "machPortsDeallocatedAfterImport"}
        require(type(case) is dict and set(case) == expected, "Closed generated case schema required")
        require(all(type(case[key]) is int for key in
                    ["width", "height", "sourceFormat", "surfaceFormat", "slots", "trials", "warmups"]),
                "Exact integer geometry and work counts required")
        require([case["width"], case["height"]] == ([3456, 2168] if index < 4 else [3840, 2160])
                and case["sourceFormat"] == [80, 81, 70, 71][index % 4]
                and case["surfaceFormat"] == [80, 81][index % 2]
                and case["trials"] == 5 and case["warmups"] == 2
                and case["slots"] == 2 and len(case["samples"]) == 5,
                "Generated case dimensions, format or work count changed")
        require(case["allConsumerPixelsCorrect" if cross else "allPixelsCorrect"] is True,
                "Every pixel must pass the independent oracle")
        if cross:
            require(type(case["maximumInFlight"]) is int and case["maximumInFlight"] == 1,
                    "One in-flight frame required")
        else:
            require(case["alphaForcedOpaque"] is True and case["machPortsDeallocatedAfterImport"] is True,
                    "Opaque output and balanced imported rights required")
        for trial, sample in enumerate(case["samples"]):
            fields = {"exportSubmitAndWaitMS", "consumerDrawAndWaitMS"} | (
                {"consumerNoticeMS", "validatedACKRoundTripMS", "deliberateConsumerPauseMS"}
                if cross else {"combinedMS"})
            require(type(sample) is dict and set(sample) == fields, "Closed timing sample schema required")
            require(all(type(value) in (int, float) and math.isfinite(value) and value >= 0
                        for value in sample.values()), "Finite nonnegative component timings required")
            if cross:
                require(sample["deliberateConsumerPauseMS"] == (32 if trial == 0 else 0)
                        and sample["validatedACKRoundTripMS"] + 0.001 >= sample["consumerNoticeMS"]
                        + sample["consumerDrawAndWaitMS"] + sample["deliberateConsumerPauseMS"],
                        "Retain the declared pause and full ACK scope")
            else:
                require(abs(sample["combinedMS"] - sample["exportSubmitAndWaitMS"]
                            - sample["consumerDrawAndWaitMS"]) <= 0.001,
                        "Combined scope must include both completed GPU operations")


def validate_transport(raw, mode):
    fields = {"scope", "passed", "mode", "expectedProtocolRejectionObserved", "actualChildExit",
              "actualParentReaped", "forcedOwnedCleanup", "registeredPortsRestored",
              "namedServiceOrGlobalSurfaceIDUsed", "kernelPeerAuditUIDAndOwnedChildPIDChecked",
              "productionAuthenticationQualified", "guestOrPhysicalPresentationQualified",
              "noGuestPixelsOrScreenFiles", "consumerShaderReadUsageIsAccessControl", "timingScope", "cases"}
    require(type(raw) is dict and set(raw) == fields and
            raw["scope"] == "cross-process-generated-IOSurface-GPU-delivery-component", "Closed transport schema required")
    require(raw["passed"] is True and raw["actualParentReaped"] is True
            and raw["forcedOwnedCleanup"] is False and raw["registeredPortsRestored"] is True
            and raw["kernelPeerAuditUIDAndOwnedChildPIDChecked"] is True
            and raw["noGuestPixelsOrScreenFiles"] is True,
            "Consumer must terminate/reap normally with verified private peer and restored capabilities")
    require(all(raw[name] is False for name in ["namedServiceOrGlobalSurfaceIDUsed", "productionAuthenticationQualified",
                "guestOrPhysicalPresentationQualified", "consumerShaderReadUsageIsAccessControl"]),
            "Component cannot promote unqualified access, presentation or guest claims")
    require(raw["mode"] == ("healthy" if mode == "run" else mode)
            and type(raw["actualChildExit"]) is int
            and raw["actualChildExit"] == {"early-exit": 7, "malformed-attach": 24}.get(mode, 0)
            and raw["expectedProtocolRejectionObserved"] is (mode != "run"), "Expected fault outcome required")
    if mode == "run":
        validate_cases(raw, True)
    else:
        require(raw["cases"] == [], "Fault cases must not report successful performance samples")


def public_build(record):
    # Full compiler commands and local paths remain in the private artifact.
    return {"scope": record["scope"], "inputs": record["inputs"], "binaries": record["binaries"],
            "toolchain": record["toolchain"], "actualBuildExits": [op["actualExit"] for op in record["operations"]]}


def validate_single(raw):
    fields = {"scope", "device", "cases", "sameProcessMachPortRoundTrip", "crossProcessIPCQualified",
              "physicalPresentationQualified", "guestPerformanceQualified", "guestPixelsOrScreenFiles",
              "consumerShaderReadUsageIsAccessControl", "timingScope", "synchronization"}
    require(type(raw) is dict and set(raw) == fields and
            raw["scope"] == "single-process-generated-IOSurface-GPU-delivery-component"
            and raw["sameProcessMachPortRoundTrip"] is True, "Closed single-process schema required")
    require(all(raw[name] is False for name in ["crossProcessIPCQualified", "physicalPresentationQualified",
                "guestPerformanceQualified", "guestPixelsOrScreenFiles", "consumerShaderReadUsageIsAccessControl"]),
            "Single-process component cannot promote unqualified claims")
    validate_cases(raw, False)


def run(artifact):
    require(artifact is not None and artifact.parent == ROOT / ".lab"
            and re.fullmatch(r"metal-surface-artifacts-[0-9a-f]{32}", artifact.name), "Use one frozen component artifact")
    record = bounded_json(artifact / "build-record.json")
    require(record["inputs"] == inputs() and all(op["actualExit"] == 0 for op in record["operations"]),
            "Current exact component inputs and successful build required")
    require(all(digest(artifact / "recipe" / name) == pin for name, pin in record["inputs"].items()),
            "Retained complete component recipe differs from admission")
    for name, pin in record["binaries"].items():
        path = artifact / name
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
                and stat.S_IMODE(info.st_mode) == 0o500 and info.st_size == pin["bytes"] and digest(path) == pin["sha256"],
                "Immutable owned component executable required")
    session = ROOT / ".lab" / ("metal-surface-measurement-" + uuid.uuid4().hex)
    session.mkdir(mode=0o700)
    save(session / "admission.json", {"buildRecordSHA256": digest(artifact / "build-record.json"), "inputs": record["inputs"]})
    operations, measurements = [], {}
    modes = [("single", "SurfaceSingle", "run"), ("transport", "SurfaceTransport", "run")] + [
        (mode, "SurfaceTransportChecked", mode) for mode in
        ["replay-ack", "stale-epoch", "early-exit", "stalled-consumer", "malformed-attach"]]
    for label, binary, mode in modes:
        operation = owned_child([str(artifact / binary), "--" + mode], session, label)
        operations.append(operation)
        save(session / (label + "-operation.json"), operation)
        require(operation["actualExit"] == 0, "Generated component failed; diagnostics at " + str(session))
        raw = bounded_json(session / (label + ".stdout"))
        stderr = (session / (label + ".stderr")).read_text(errors="replace")
        require("ERROR: AddressSanitizer" not in stderr and "runtime error:" not in stderr, "Sanitizer finding")
        if label != "single":
            validate_transport(raw, mode)
        else:
            validate_single(raw)
        measurements[label] = raw
    require(record["inputs"] == inputs() and all(digest(artifact / n) == p["sha256"] for n, p in record["binaries"].items()),
            "Component inputs changed during measurement")
    metrics = []
    for label in ("single", "transport"):
        for case in measurements[label]["cases"]:
            for field in case["samples"][0]:
                if field == "deliberateConsumerPauseMS":
                    continue
                metrics.append({"name": f"{label}_{case['width']}x{case['height']}_{case['sourceFormat']}_{field}",
                                "unit": "ms", "samples": [s[field] for s in case["samples"]],
                                "definition": "Generated GPU export/draw/notice component only; ACK includes the all-pixel CPU oracle and one declared32ms pause"})
    ram = sysctl("hw.memsize")
    filesystem = os.statvfs(ROOT)
    host = {"model": sysctl("hw.model"), "chip": sysctl("machdep.cpu.brand_string"), "performanceCores": None,
            "efficiencyCores": None, "gpuCores": None, "ramBytes": int(ram) if ram and ram.isdigit() else None,
            "storageModel": None, "storageFreeBytes": filesystem.f_bavail * filesystem.f_frsize,
            "powerMode": None, "thermalState": None, "displays": None,
            "macOSVersion": platform.mac_ver()[0] or None, "macOSBuild": sysctl("kern.osversion")}
    guest = {key: None for key in ["os", "edition", "build", "architecture", "patchLevel", "agentVersion",
                                  "driverVersions", "vCPU", "ramBytes", "disk", "network"]}
    result = {"schemaVersion": 1, "recordedAt": datetime.now(timezone.utc).isoformat(), "status": "measured",
              "host": host, "guest": guest,
              "application": {"revision": None, "sourceSHA256": hashlib.sha256(json.dumps(record["inputs"], sort_keys=True).encode()).hexdigest(),
                              "version": "0.1.0-dev", "backend": "generated Metal/IOSurface component", "backendVersion": "public SDK APIs",
                              "entitlements": [], "configuration": {"build": public_build(record), "measurements": measurements}},
              "method": {"cache": "uncontrolled", "trialCount": 5, "outlierPolicy": "retain all; two declared warmups per case",
                         "confidenceInterval": None, "backgroundWorkload": "Interactive development host; other CPU/GPU work uncontrolled"},
              "metrics": metrics, "unknownReasons": {}, "limitations": [
                  "Generated quadrants only; no VM access, guest pixels, screen files or real display presentation.",
                  "Five sequential samples per format/geometry; no CI, FPS, gameplay or120Hz claim.",
                  "Cross-process GPU draw is not physical scanout; ACK includes CPU correctness checks and a declared pause.",
                  "Mach peer UID/owned-child identity and protocol faults are tested; production VM/session/authentication binding is not.",
                  "Shader-read usage is a role, not enforced read-only access to an IOSurface capability.",
                  "Local unsigned build provenance; no clean-machine release reproduction or distribution clearance."]}
    for section in ("host", "guest", "application", "method"):
        for key, value in result[section].items():
            if value is None:
                result["unknownReasons"][section + "." + key] = (
                    "No guest exists in this component" if section == "guest" else "Not collected or no statistical claim")
    require(not validate_result(result), "Benchmark evidence schema refused")
    save(session / "result.json", result)
    destination = ROOT / "Benchmarks/results" / ("metal-surface-" + uuid.uuid4().hex + ".json")
    save(destination, result)
    print(json.dumps({"result": str(destination), "session": str(session), "operations": len(operations),
                      "allActualProducerExits": [op["actualExit"] for op in operations], "noVMAccess": True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--build", action="store_true")
    choice.add_argument("--run", action="store_true")
    parser.add_argument("--artifact", type=Path)
    args = parser.parse_args()
    if args.build:
        build()
    elif args.run:
        run(args.artifact)
    else:
        print("SKIP: explicit generated GPU component build/run required; no VM or display opened")


if __name__ == "__main__":
    main()
