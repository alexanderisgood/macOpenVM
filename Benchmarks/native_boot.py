#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline console feasibility timings. No guest-agent readiness or parity claim.
Requires an explicit run, pinned local fixture and current packaged build provenance.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import select
import selectors
import subprocess
import sys
import time
import uuid
from safety import PINNED_MEDIA, bounded_json, new_session, publish_result, sha256_file, verified_build, verify_current_cli, verify_media, write_json
from validate_result import validate_result

ROOT = Path(__file__).resolve().parents[1]


def run_trial(cli, directory, session, number, root, manifest):
    verify_current_cli(root, manifest)
    phase = "spawn"
    process = None
    ownership = session / "ownership.json"
    selector = selectors.DefaultSelector()
    transcript = (session / f"trial-{number}.log").open("xb")
    output = bytearray(); errors = bytearray(); query_tail = b""
    transcript_writable = True
    sample = {}

    def receive(timeout, recovery=False):
        nonlocal query_tail, transcript_writable
        for key, _ in selector.select(timeout):
            chunk = os.read(key.fileobj.fileno(), 65_536)
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            if transcript_writable:
                try:
                    transcript.write(chunk); transcript.flush()
                except OSError:
                    transcript_writable = False
                    if not recovery:
                        raise
            if key.data == "guest":
                query = query_tail + chunk
                for _ in range(query.count(b"\x1b[6n")):
                    process.stdin.write(b"\x1b[1;1R")
                query_tail = query[-3:]
            if recovery:
                sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
            else:
                (output if key.data == "guest" else errors).extend(chunk)
                if len(output) > 2_097_152 or len(errors) > 2_097_152:
                    raise RuntimeError("Benchmark console response exceeded its bound")

    def wait_for(pattern, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if re.search(pattern, bytes(output)):
                return time.monotonic()
            if process.poll() is not None:
                raise RuntimeError("Runner exited before the expected console state")
            receive(0.25)
        raise RuntimeError("Expected console state timed out")

    try:
        start = time.monotonic()
        process = subprocess.Popen([str(cli), "run", "--directory", str(directory), "--seconds", "300"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        print(f"Trial {number} runner PID {process.pid}; private session {session.name}", flush=True)
        selector.register(process.stdout, selectors.EVENT_READ, "guest")
        selector.register(process.stderr, selectors.EVENT_READ, "host")
        write_json(ownership, {"pid": process.pid, "trial": number, "active": True})
        phase = "login"
        login = wait_for(rb"localhost login: ")
        sample["process_to_console_login"] = (login - start) * 1000
        process.stdin.write(b"root\n")
        wait_for(rb"localhost:~# ")
        phase = "architecture"
        nonce = "mvo" + uuid.uuid4().hex
        output.clear()
        process.stdin.write(f"printf '\\n{nonce}:%s\\n' \"$(uname -m)\"; uname -r\n".encode())
        wait_for(rb"[\r\n]" + nonce.encode() + rb":aarch64[\r\n]")
        wait_for(rb"[\r\n]([A-Za-z0-9_.-]+-virt)[\r\n]")
        match = re.search(rb"[\r\n]([A-Za-z0-9_.-]+-virt)[\r\n]", bytes(output))
        kernel = match.group(1).decode()
        match = re.search(rb"vm.framework-start.completed ms=([0-9.]+)", bytes(errors))
        if not match:
            raise RuntimeError("Framework timing event missing")
        sample["framework_start"] = float(match.group(1))
        phase = "poweroff"
        shutdown = time.monotonic()
        process.stdin.write(b"poweroff\n")
        while process.poll() is None and time.monotonic() - shutdown < 45:
            receive(0.25)
        if process.poll() != 0:
            raise RuntimeError("Clean guest shutdown did not complete")
        sample["guest_poweroff_to_process_exit"] = (time.monotonic() - shutdown) * 1000
        # Drain any final pipe data without changing the observed exit timestamp.
        receive(0)
        write_json(ownership, {"pid": process.pid, "trial": number, "active": False, "exitStatus": 0})
        write_json(session / f"trial-{number}.json", {"sample": sample, "guestKernel": kernel}, exclusive=True)
        print(f"Trial {number}: ARM64 console verified, clean exit; framework start {sample['framework_start']:.2f} ms", flush=True)
        return sample, kernel
    except BaseException as error:
        status = process.poll() if process is not None else None
        try:
            write_json(session / f"failure-{number}.json", {"phase": phase, "error": str(error),
                       "pid": process.pid if process is not None else None,
                       "active": process is not None and status is None, "exitStatus": status,
                       "partialSample": sample}, exclusive=True)
        except OSError:
            print("Failure record could not be written; use the process handle reported above.", flush=True)
        print(f"Benchmark failed in {phase}; evidence retained in {session.name}.", flush=True)
        if process is not None and process.poll() is None:
            print("Live guest retained. This session forwards console input; establish its actual shell before commands.", flush=True)
            sys.stdout.buffer.write(bytes(output[-4096:])); sys.stdout.buffer.flush()
            inputs = [sys.stdin]
            while process.poll() is None:
                receive(0.25, recovery=True)
                if inputs and select.select(inputs, [], [], 0)[0]:
                    chunk = os.read(sys.stdin.fileno(), 4096)
                    if chunk:
                        process.stdin.write(chunk)
                    else:
                        inputs.clear()
            try:
                write_json(ownership, {"pid": process.pid, "trial": number, "active": False, "exitStatus": process.returncode})
            except OSError:
                print(f"Recovered runner exited with status {process.returncode}; ownership record may be stale.", flush=True)
        raise
    finally:
        try:
            transcript.close()
        except OSError:
            print("Private transcript close failed; retained evidence may be incomplete.", flush=True)
        selector.close()
        if process is not None and process.poll() is not None:
            process.stdin.close(); process.stdout.close(); process.stderr.close()


def sysctl_value(key):
    try:
        return subprocess.check_output(["/usr/sbin/sysctl", "-n", key], stderr=subprocess.DEVNULL).decode().strip()
    except subprocess.CalledProcessError:
        return None


def result_for(probe, manifest, config, samples, guest_kernel, trials):
    core_counts = {"performance": None, "efficiency": None}
    for level in range(4):
        label = sysctl_value(f"hw.perflevel{level}.name")
        count = sysctl_value(f"hw.perflevel{level}.physicalcpu")
        if label and count and label.lower() in core_counts:
            core_counts[label.lower()] = int(count)
    harness = hashlib.sha256()
    for name in ("native_boot.py", "safety.py", "validate_result.py", "result.schema.json"):
        data = (ROOT / "Benchmarks" / name).read_bytes()
        harness.update(name.encode() + b"\0" + hashlib.sha256(data).digest())
    result = {
        "schemaVersion": 1, "recordedAt": datetime.now(timezone.utc).isoformat(), "status": "measured",
        "host": {"model": probe["model"], "chip": sysctl_value("machdep.cpu.brand_string"),
                 "performanceCores": core_counts["performance"], "efficiencyCores": core_counts["efficiency"],
                 "gpuCores": None, "ramBytes": probe["memoryBytes"], "storageModel": None,
                 "storageFreeBytes": os.statvfs(ROOT).f_bavail * os.statvfs(ROOT).f_frsize,
                 "powerMode": None, "thermalState": None, "displays": probe["displays"],
                 "macOSVersion": probe["osVersion"], "macOSBuild": probe["osBuild"]},
        "application": {"revision": manifest["revision"], "sourceSHA256": manifest["sources"]["sha256"],
                        "version": manifest["version"], "backend": "AppleVz", "backendVersion": probe["osBuild"],
                        "entitlements": sorted(manifest["artifacts"]["cli"]["entitlements"]),
                        "configuration": {"build": manifest["configuration"],
                                          "runnerSHA256": manifest["artifacts"]["cli"]["sha256"],
                                          "sourceScope": manifest["sources"]["scope"], "toolchain": manifest["toolchain"],
                                          "buildRecordSHA256": sha256_file(ROOT / "build/build-manifest.json"),
                                          "harnessSHA256": harness.hexdigest(), "mediaSHA256": dict(PINNED_MEDIA),
                                          "graphics": "headless serial", "boot": "linuxKernel",
                                          "cpuCount": config["cpuCount"], "memoryBytes": config["memoryBytes"],
                                          "diskBytes": config["diskBytes"], "durability": "VZ full synchronization; sparse raw"}},
        "guest": {"os": "Alpine Linux", "edition": "virt live media 3.24.2", "build": guest_kernel,
                  "architecture": "aarch64", "patchLevel": "Pinned official fixture; no online patches",
                  "agentVersion": None, "driverVersions": None, "vCPU": config["cpuCount"], "ramBytes": config["memoryBytes"],
                  "disk": {"format": "raw", "virtualBytes": config["diskBytes"], "liveRoot": "RAM; not installed"},
                  "network": "disconnected; no guest NIC"},
        "method": {"cache": "uncontrolled", "trialCount": trials, "outlierPolicy": "retain all; no exclusions",
                   "confidenceInterval": None, "backgroundWorkload": "Interactive development host; not quiesced"},
        "metrics": [{"name": name, "unit": "ms", "samples": samples[name], "definition": definition} for name, definition in [
            ("framework_start", "AppleVz monotonic machine.start invocation to completion; Core prelaunch history IO excluded; not guest readiness"),
            ("process_to_console_login", "Monotonic CLI spawn to received guest login prompt; no authenticated agent"),
            ("guest_poweroff_to_process_exit", "Serial poweroff to CLI exit after observed guest stop; includes polling")]],
        "unknownReasons": {},
        "limitations": ["Named-host feasibility only; not a release or parity benchmark.",
                        "Live RAM-root guest; no GUI, installed disk, agent or network workload. Cache and host load uncontrolled.",
                        "Raw transcripts remain private in ignored .lab. Local build provenance is not a signed attestation.",
                        "Current source scope/profile differ from the historical debug report; no regression comparison."]
    }
    reasons = {"application.revision": "Workspace has no Git repository or commit", "guest.agentVersion": "No guest agent installed",
               "guest.driverVersions": "Individual driver builds not inventoried", "method.confidenceInterval": "Uncontrolled feasibility trials; no statistical claim"}
    for section in ("host", "application", "guest", "method"):
        for field, value in result[section].items():
            if value is None:
                key = f"{section}.{field}"
                result["unknownReasons"][key] = reasons.get(key, "Not collected or unavailable through this host probe")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--trials", type=int, default=5)
    args = parser.parse_args()
    if not args.run or not 1 <= args.trials <= 20:
        raise SystemExit("SKIP: explicit --run and 1–20 trials required; prepare the local offline fixture first.")
    cli = ROOT / "build/bin/macopenvm"
    directory = ROOT / ".lab/Alpine-native.macopenvm"
    try:
        manifest = verified_build(ROOT)
        config = bounded_json(directory / "configuration.json", 65_536)
        verify_media(config)
        probe = json.loads(subprocess.check_output([str(cli), "probe"]))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit("Prerequisite failed before guest start: " + str(error))
    if not probe["virtualizationSupported"] or not probe["virtualizationEntitled"]:
        raise SystemExit("SKIP: signed native virtualization unavailable in this execution environment.")
    subprocess.run([str(cli), "validate", "--directory", str(directory)], check=True, stdout=subprocess.DEVNULL)
    session, destination = new_session(ROOT)
    write_json(session / "build-record.json", manifest, exclusive=True)
    samples = {"framework_start": [], "process_to_console_login": [], "guest_poweroff_to_process_exit": []}
    guest_kernel = None
    for trial in range(1, args.trials + 1):
        sample, kernel = run_trial(cli, directory, session, trial, ROOT, manifest)
        if guest_kernel is not None and kernel != guest_kernel:
            raise RuntimeError("Guest kernel changed between trials; private evidence retained")
        guest_kernel = kernel
        for name in samples:
            samples[name].append(sample[name])
    verify_current_cli(ROOT, manifest)
    if bounded_json(ROOT / "build/build-manifest.json") != manifest:
        raise RuntimeError("Build record changed during trials; private evidence retained")
    result = result_for(probe, manifest, config, samples, guest_kernel, args.trials)
    failures = validate_result(result)
    if failures:
        raise SystemExit("\n".join(failures))
    write_json(session / "candidate-result.json", result, exclusive=True)
    publish_result(destination, result)
    print("Unique structured result saved: " + destination.name + "; no performance claim.")


if __name__ == "__main__":
    main()
