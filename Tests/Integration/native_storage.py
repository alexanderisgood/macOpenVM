#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Real bounded sector durability and optional runner-crash contract.
Creates a unique new offline test VM; never writes a pre-existing VM or physical host disk.
"""
import argparse
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

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--run", action="store_true")
parser.add_argument("--crash-trial", action="store_true")
args = parser.parse_args()
template = ROOT / ".lab/Alpine-native.macopenvm/configuration.json"
if not args.run or not template.is_file():
    raise SystemExit("SKIP: --run, a signed CLI and the prepared offline Alpine direct-kernel fixture are required.")
if template.stat().st_size > 65_536:
    raise SystemExit("Template metadata exceeds its bound.")
c = json.loads(template.read_text())
if c["guest"] != "linux" or c["boot"] != "linuxKernel" or c["network"] != "disconnected":
    raise SystemExit("SKIP: only the prepared offline direct-kernel fixture is permitted as a media template.")
cli = ROOT / "build/bin/macopenvm"
probe = json.loads(subprocess.check_output([str(cli), "probe"]))
if not probe["virtualizationSupported"] or not probe["virtualizationEntitled"]:
    raise SystemExit("SKIP: signed native virtualization is unavailable.")
session = ROOT / (".lab/storage-contract-" + uuid.uuid4().hex)
session.mkdir(mode=0o700)
directory = session / "VM.macopenvm"
command = [str(cli), "create", "--directory", str(directory), "--name", "Disposable storage contract",
           "--kernel", c["kernel"], "--initrd", c["initialRamdisk"], "--kernel-arguments", c["kernelArguments"],
           "--media", c["installationMedia"], "--cpus", "2", "--memory-mib", "2048", "--disk-gib", "2",
           "--network", "disconnected"]
subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
print("New disposable fixture: " + session.name, flush=True)
identity_files = ("configuration.json", "machine-identity.bin", "efi-variables.bin")
original = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in identity_files}
marker = "mvo-data-" + uuid.uuid4().hex
payload = (marker + "\n").encode().ljust(4096, b"\0")
digest = hashlib.sha256(payload).hexdigest()
outcomes = []

for cycle in range(1, 4):
    runtime = directory / "runtime.json"
    prior_bytes = runtime.read_bytes() if runtime.exists() else None
    prior = json.loads(prior_bytes) if prior_bytes is not None else None
    process = subprocess.Popen([str(cli), "run", "--directory", str(directory), "--seconds", "300"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    ownership = session / "ownership.json"
    ownership.write_text(json.dumps({"pid": process.pid, "cycle": cycle, "active": True}) + "\n")
    print(f"Cycle {cycle} runner PID {process.pid}", flush=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "guest")
    selector.register(process.stderr, selectors.EVENT_READ, "host")
    transcript = (session / f"cycle-{cycle}.log").open("xb")
    output = bytearray()
    query_tail = b""
    phase = "boot"

    def receive(timeout):
        global query_tail
        for key, _ in selector.select(timeout):
            chunk = os.read(key.fileobj.fileno(), 65_536)
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            transcript.write(chunk); transcript.flush()
            if key.data == "guest":
                output.extend(chunk)
                query = query_tail + chunk
                for _ in range(query.count(b"\x1b[6n")):
                    process.stdin.write(b"\x1b[1;1R")
                query_tail = query[-3:]
            if len(output) > 2_097_152:
                raise RuntimeError("Guest response exceeded its bound")

    def wait_for(pattern, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if re.search(pattern, bytes(output)):
                return
            if process.poll() is not None:
                raise RuntimeError("Runner exited before the expected guest response")
            receive(0.25)
        raise RuntimeError("Guest response timed out")

    def guest(text):
        global phase
        phase = text.split(" ", 1)[0]
        output.clear()
        process.stdin.write(text.encode() + b"\n")

    try:
        wait_for(rb"localhost login: ", 45)
        guest("root")
        wait_for(rb"localhost:~# ")
        nonce = "mvo" + uuid.uuid4().hex
        guest(f"printf '\\n{nonce}arch:%s\\n' \"$(uname -m)\"; "
              f"printf '\\n{nonce}size:%s\\n' \"$(cat /sys/block/vda/size)\"; "
              f"if grep -q '/dev/vda' /proc/mounts; then echo {nonce}mounted; else echo {nonce}unmounted; fi")
        wait_for(rb"[\r\n]" + nonce.encode() + rb"arch:aarch64[\r\n]")
        wait_for(rb"[\r\n]" + nonce.encode() + rb"size:4194304[\r\n]")
        wait_for(rb"[\r\n]" + nonce.encode() + rb"unmounted[\r\n]")
        if cycle == 1:
            guest("dd if=/dev/zero of=/tmp/macopenvm-block bs=4096 count=1 2>/dev/null && "
                  f"printf '{marker}\\n' | dd of=/tmp/macopenvm-block conv=notrunc 2>/dev/null && "
                  "dd if=/tmp/macopenvm-block of=/dev/vda bs=4096 seek=256 count=1 conv=fsync 2>/dev/null; "
                  f"printf '\\n{nonce}write:%s\\n' \"$?\"")
            wait_for(rb"[\r\n]" + nonce.encode() + rb"write:0[\r\n]")
        guest(f"printf '\\n{nonce}hash:%s\\n' \"$(dd if=/dev/vda bs=4096 skip=256 count=1 2>/dev/null | sha256sum)\"")
        wait_for(rb"[\r\n]" + nonce.encode() + rb"hash:" + digest.encode() + rb"\s")
        competing = subprocess.run([str(cli), "validate", "--directory", str(directory)], capture_output=True, text=True, timeout=5)
        assert competing.returncode == 1 and "another writer" in competing.stderr
        diagnostic = subprocess.run([str(cli), "doctor", "--directory", str(directory)], capture_output=True, text=True, timeout=5)
        assert diagnostic.returncode == 2 and json.loads(diagnostic.stdout)["writer"] == "held"
        assert json.loads(diagnostic.stdout)["history"] == "writerHeld"
        if prior is not None:
            archive = directory / ("runtime-" + prior["sessionID"].lower() + ".json")
            assert archive.read_bytes() == prior_bytes, "Prior run history was not preserved exactly"
        if cycle == 2 and args.crash_trial:
            phase = "explicit-test-runner-crash"
            # Only this freshly created, verified test runner is terminated; no user VM is selected.
            process.kill()
            assert process.wait(timeout=10) == -9
            stop = "runner-SIGKILL-after-flushed-sector"
        else:
            guest("poweroff")
            deadline = time.monotonic() + 45
            while process.poll() is None and time.monotonic() < deadline:
                receive(0.25)
            assert process.poll() == 0, "Clean guest shutdown did not complete"
            stop = "guest-poweroff"
        ownership.write_text(json.dumps({"pid": process.pid, "cycle": cycle, "active": False}) + "\n")
        subprocess.run([str(cli), "validate", "--directory", str(directory)], check=True, stdout=subprocess.DEVNULL)
        diagnostic = subprocess.run([str(cli), "doctor", "--directory", str(directory)], capture_output=True, text=True, timeout=5)
        if stop == "guest-poweroff":
            assert diagnostic.returncode == 0 and json.loads(diagnostic.stdout)["history"] == "guestStopRecorded"
        else:
            assert diagnostic.returncode == 2 and json.loads(diagnostic.stdout)["history"] == "interruptedOrUnreconciled"
        history = json.loads(runtime.read_bytes())
        assert history["snapshot"]["outcome"] == ("guestStopped" if stop == "guest-poweroff" else "pending")
        with (directory / "disk.raw").open("rb") as disk:
            disk.seek(1_048_576)
            assert disk.read(4096) == payload, "Host-side durable sector differs"
        assert (directory / "disk.raw").stat().st_size == 2_147_483_648
        assert {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in identity_files} == original
        outcomes.append({"cycle": cycle, "guestHashMatched": True, "hostSectorMatched": True,
                         "writerExcludedAndReleased": True, "identityAndConfigurationUnchanged": True,
                         "historyClassificationMatched": True, "priorHistoryPreserved": prior is not None,
                         "stop": stop})
        print(f"Cycle {cycle} verified; {stop}; ownership released.", flush=True)
    except Exception as error:
        (session / "failure.json").write_text(json.dumps({"error": str(error), "phase": phase, "pid": process.pid,
                                                        "active": process.poll() is None}) + "\n")
        print(f"Contract failed in {phase}: {error}. Evidence: {session.name}.", flush=True)
        if process.poll() is None:
            print("Live guest retained; session now forwards console input. Establish its shell before commands.", flush=True)
            inputs = [sys.stdin]
            while process.poll() is None:
                receive(0.25)
                if inputs and select.select(inputs, [], [], 0)[0]:
                    chunk = os.read(sys.stdin.fileno(), 4096)
                    if chunk:
                        process.stdin.write(chunk)
                    else:
                        inputs.clear()
                if output:
                    sys.stdout.buffer.write(output); sys.stdout.buffer.flush(); output.clear()
        raise
    finally:
        transcript.close(); selector.close()

report = {"status": "passed", "cycles": outcomes, "sectorBytes": 4096, "sectorOffset": 1_048_576,
          "durability": "guest dd conv=fsync; AppleVz full synchronization",
          "limitations": "Unformatted test sector; not installed-OS, filesystem, snapshot or host-power-loss proof"}
(session / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report), flush=True)
