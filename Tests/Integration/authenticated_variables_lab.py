#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run an isolated, diskless AUTH2 rejection experiment on the pinned HVF candidate."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import stat
import subprocess
import time
import uuid

import windows_efi_probe as lab

PROBE_PIN = (86016, "660660078584529557b7385c253d886b6b1f22651d0843b5f47165227ca2d03c")
VECTOR_SET_SHA256 = "398b248fc0bf6bab59ffef337f2cb03e7ae5b35dacf21614991ccd2729fa7ac7"
STRICT_TIME_DIRECTORY = "tools/qemu-auth-time-candidate-7d071ec45e0647ed8e7085929f8627b7"
STRICT_TIME_BINARY = "abc60310b8bdb218fd13ce81c1709edb39be547b792fdc18cada1775c7513352"
STRICT_TIME_SOURCE = "e5763db5676b8243b3705ba45ef321c7669c710958abd9676752653fbad1ae05"
CASES = ("pk-bootstrap", "kek-initial", "kek-newer", "older-timestamp", "tampered-payload",
         "tampered-signature", "missing-auth", "truncated-auth", "equal-replay",
         "equal-replacement", "valid-after-rejections")
CASE = re.compile(rb"mvo.auth-variable.case name=([a-z-]+) status=0x([0-9a-fA-F]{16}) "
                  rb"expected=0x([0-9a-fA-F]{16}) readback=([01]) mode=([01]) passed=([01])")


def observe(raw):
    lines = lab.ANSI_CSI.sub(b"", raw).replace(b"\r", b"").splitlines()
    markers = [line for line in lines if line.startswith(b"mvo.auth-variable.")]
    if any(line.startswith(b"mvo.auth-variable.failure ") for line in markers):
        raise lab.ProbeFailure("Guest prerequisite failed; inspect its preserved log")
    completions = [line for line in markers if line.startswith(b"mvo.auth-variable.complete ")]
    if not completions:
        return None
    if len(markers) != 13 or markers[0] != b"mvo.auth-variable.begin version=1":
        raise lab.ProbeFailure("Unexpected marker count/order")
    results = []
    for name, line in zip(CASES, markers[1:12]):
        match = CASE.fullmatch(line)
        if match is None or match[1].decode() != name:
            raise lab.ProbeFailure("Malformed, missing, or reordered case marker")
        status, expected = int(match[2], 16), int(match[3], 16)
        policy = 0 if name in CASES[:3] or name == CASES[-1] else 0x800000000000001a
        readback, mode, passed = [value == b"1" for value in match.groups()[3:]]
        if expected != policy or passed != (status == policy and readback and mode):
            raise lab.ProbeFailure("Guest assertion disagrees with independent host policy")
        results.append({"name": name, "status": hex(status), "expected": hex(policy),
                        "readbackMatches": readback, "userModeSecureBoot": mode, "passed": passed})
    failures = sum(not row["passed"] for row in results)
    if markers[-1] != f"mvo.auth-variable.complete cases=11 failures={failures}".encode():
        raise lab.ProbeFailure("Guest completion count differs from observed cases")
    return {"cases": results, "failures": failures, "allPassed": failures == 0}


def run(args, profile=None):
    # Profiles come only from original, reviewed Python modules, never guest data
    # or a command-line configuration. Each retains exact input and observer pins.
    if profile is None:
        profile = {"probePin": PROBE_PIN, "vectorSetSHA256": VECTOR_SET_SHA256,
                   "inputs": {prefix + suffix for prefix in ("PK", "KEK0", "KEK1", "KEK2", "EQUAL")
                              for suffix in (".AUTH", ".ESL")},
                   "inputLimit": 8192, "fixturePrefix": "auth-variable-run-",
                   "scope": "boot-services KEK replacement", "observer": observe,
                   "profileSource": str(Path(__file__).resolve())}
    observer = profile["observer"]
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise lab.ProbeFailure("This fixture requires the reviewed Apple silicon host")
    root = lab.ROOT
    source = args.platform_directory
    lab.checked_directory(source, root / ".lab", private=True)
    lab.checked_directory(args.vectors_directory, root / ".lab", private=True)
    probe, probe_record = lab.asset(args.probe, root / ".lab", 1_048_576)
    if (probe_record["bytes"], probe_record["sha256"]) != profile["probePin"]:
        raise lab.ProbeFailure("Original test executable differs from its reviewed build")
    qemu, qemu_record = lab.private_qemu(args.qemu_record, source)
    if args.strict_time_candidate:
        candidate = source / STRICT_TIME_DIRECTORY
        lab.checked_directory(candidate, source, private=True)
        expected_sources = {"accel/hvf/hvf-all.c": lab.QEMU_PATCHED_HVF_SHA256,
                            "hw/intc/Kconfig": lab.QEMU_GIC_KCONFIG_SHA256,
                            "hw/uefi/var-service-pkcs7.c": lab.QEMU_PKCS7_ENVELOPE_SOURCE,
                            "hw/uefi/var-service-vars.c": STRICT_TIME_SOURCE,
                            **lab.QEMU_GIC_FEATURE_SOURCES}
        for relative, digest in expected_sources.items():
            if lab.asset(candidate / "source" / relative, candidate, 1_048_576)[1]["sha256"] != digest:
                raise lab.ProbeFailure("Corrected candidate source differs")
        qemu = candidate / "qemu-system-aarch64"
        _, qemu_record = lab.asset(qemu, candidate, 134_217_728)
        if qemu_record != {"bytes": 26627760, "sha256": STRICT_TIME_BINARY}:
            raise lab.ProbeFailure("Corrected binary differs from the signed reviewed build")
        qemu_record.update(strictTimestamp=True, baseCandidateSHA256=lab.QEMU_PKCS7_ENVELOPE_BINARY)
    firmware, firmware_record = lab.asset(source / lab.FIRMWARE, source, 16_777_216)
    if (firmware_record["bytes"], firmware_record["sha256"]) != lab.PINS[lab.FIRMWARE]:
        raise lab.ProbeFailure("Firmware pin differs")
    swtpm, tpm_record = lab.executable("swtpm", "0.10.2")
    if tpm_record["sha256"] != "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a":
        raise lab.ProbeFailure("TPM pin differs")
    vector_record = json.loads(lab.regular_bytes(args.vectors_directory / "record.json", 65_536))
    names = profile["inputs"]
    if set(vector_record["artifacts"]) != names:
        raise lab.ProbeFailure("Unexpected vector set")
    if hashlib.sha256(json.dumps(vector_record["artifacts"], sort_keys=True,
                                 separators=(",", ":")).encode()).hexdigest() != profile["vectorSetSHA256"]:
        raise lab.ProbeFailure("Vectors differ from the independently verified deterministic cases")
    vectors = {}
    for name in sorted(names):
        data, record = lab.asset(args.vectors_directory / name, root / ".lab", profile["inputLimit"])
        if record != vector_record["artifacts"][name]:
            raise lab.ProbeFailure("Prepared vector changed")
        vectors[name] = data
    fixture = root / ".lab" / (profile["fixturePrefix"] + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    short = Path("/private/tmp") / ("mvo-auth-" + uuid.uuid4().hex[:16])
    short.mkdir(mode=0o700)
    mask = os.umask(0o077)
    lock = os.open(fixture / "owner.lock", os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    owned, records, forced = [], [], []
    qmp = guest = tpm = None
    quit_ack = False
    result = {"schemaVersion": 1, "status": "failed", "windowsCompatibilityVerified": False,
              "osDiskAttached": False, "networkEnabled": False, "scope": profile["scope"]}
    environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": str(short)}
    try:
        code = fixture / "firmware-code-64m.fd"
        lab.exclusive_file(code, firmware + bytes(67_108_864 - len(firmware)))
        os.chmod(code, 0o400)
        media = fixture / "efi-media"
        (media / "EFI/BOOT").mkdir(parents=True, mode=0o700)
        for relative, data in {"EFI/BOOT/BOOTAA64.EFI": probe,
                               "startup.nsh": b"@echo -off\r\nfs0:\\EFI\\BOOT\\BOOTAA64.EFI\r\n",
                               **vectors}.items():
            lab.exclusive_file(media / relative, data)
            os.chmod(media / relative, 0o400)
        variables = fixture / "uefi-vars.json"
        lab.exclusive_file(variables, b"")
        tpmstate = fixture / "tpm-state"
        tpmstate.mkdir(mode=0o700)
        staged = {str(path.relative_to(fixture)): lab.asset(path, fixture, 67_108_864)[1]
                  for path in (code, *sorted(path for path in media.rglob("*") if path.is_file()))}
        qemu_argv = [str(qemu), "-no-user-config", "-nodefaults", "-machine",
                     "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off",
                     "-accel", "hvf", "-cpu", "host", "-smp", "2", "-m", "2048",
                     "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none",
                     "-qmp", f"unix:{short}/qmp.sock,server=on,wait=off",
                     "-drive", f"if=pflash,unit=0,format=raw,readonly=on,file={code}",
                     "-device", f"uefi-vars-sysbus,jsonfile={variables},size=262144,force-secure-boot=off,disable-custom-mode=on",
                     "-chardev", f"socket,id=chrtpm,path={short}/tpm.sock",
                     "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                     "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on",
                     "-drive", f"if=none,id=efimedia,format=raw,readonly=on,file=fat:16:{media}",
                     "-device", "virtio-blk-pci,drive=efimedia,bootindex=1"]
        tpm_argv = [str(swtpm), "socket", "--tpm2", "--tpmstate", f"dir={tpmstate},mode=0600,lock",
                    "--ctrl", f"type=unixio,path={short}/tpm.sock,mode=0600,terminate",
                    "--flags", "startup-none", "--log", "file=-"]
        if any("," in str(path) or ":" in str(path) for path in (fixture, source, short)):
            raise lab.ProbeFailure("Unsafe separators in fixture paths")
        lab.exclusive_json(fixture / "recipe.json", {
            "qemuArgv": qemu_argv, "swtpmArgv": tpm_argv, "qemu": qemu_record, "swtpm": tpm_record,
            "probe": probe_record, "firmware": firmware_record, "stagedReadonly": staged,
            "vectorRecord": vector_record,
            "runnerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "profileSourceSHA256": hashlib.sha256(Path(profile["profileSource"]).read_bytes()).hexdigest()})
        print("AUTH2 fixture: " + fixture.name, flush=True)
        tpm = lab.Child(tpm_argv, "tpm", fixture, environment, owned)
        deadline = time.monotonic() + 5
        while not (short / "tpm.sock").exists():
            if tpm.process.poll() is not None or tpm.errors() or time.monotonic() >= deadline:
                raise lab.ProbeFailure("TPM readiness failed")
            time.sleep(0.05)
        metadata = (short / "tpm.sock").lstat()
        if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise lab.ProbeFailure("TPM socket is not private")
        guest = lab.Child(qemu_argv, "guest", fixture, environment, owned, serial=True)
        lab.exclusive_json(fixture / "children.json", {"qemuPid": guest.process.pid, "tpmPid": tpm.process.pid})
        started = time.monotonic()
        observation = None
        while time.monotonic() < started + 60:
            if any(child.errors() for child in owned):
                raise lab.ProbeFailure("Child output failed its bound")
            observation = observer(guest.stdout.snapshot())
            if observation is not None:
                break
            if any(child.process.poll() is not None for child in owned):
                raise lab.ProbeFailure("A child exited before completing observations")
            time.sleep(0.05)
        if observation is None:
            raise lab.ProbeFailure("No complete guest observations within 60 seconds")
        result["guestCompletionSeconds"] = time.monotonic() - started
        result["observation"] = observation
        qmp = lab.QMP(short / "qmp.sock", records)
        if qmp.execute("query-status", 2).get("status") != "running":
            raise lab.ProbeFailure("Unexpected terminal guest status")
        qmp.execute("quit", 3)
        quit_ack = True
        for child in (guest, tpm):
            child.process.wait(timeout=10)
            child.finish()
            if child.process.returncode or child.errors():
                raise lab.ProbeFailure("Owned firmware cleanup failed")
        if observer(guest.stdout.snapshot()) != observation:
            raise lab.ProbeFailure("Final log changed observations")
        for relative, record in staged.items():
            if lab.asset(fixture / relative, fixture, 67_108_864)[1] != record:
                raise lab.ProbeFailure("Readonly input changed")
        for path, expected in ((qemu, qemu_record), (swtpm, tpm_record)):
            if hashlib.sha256(lab.regular_bytes(path, 134_217_728, owner={0, os.getuid()})).hexdigest() != expected["sha256"]:
                raise lab.ProbeFailure("Runtime binary changed")
        result.update(status="passed" if observation["allPassed"] else "policy-failed",
                      observationsComplete=True, readonlyHashesPreserved=True)
    except BaseException as error:
        result.update(status="failed", error=str(error)[:2000])
    finally:
        if guest is not None and guest.process.poll() is None and not quit_ack:
            try:
                if qmp is None:
                    qmp = lab.QMP(short / "qmp.sock", records)
                qmp.execute("quit", 100)
                quit_ack = True
            except (OSError, ValueError, lab.ProbeFailure):
                pass
        if qmp is not None:
            qmp.close()
        for child in reversed(owned):
            if child.process.poll() is None:
                try:
                    child.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.process.terminate()
                    forced.append(child.process.pid)
                    result["status"] = "failed"
        while any(child.process.poll() is None for child in owned):
            # Do not abandon an actual process handle or unlock a live fixture.
            try:
                time.sleep(1)
            except KeyboardInterrupt:
                pass
        for child in owned:
            try:
                child.finish()
                if child.errors() or child.process.returncode:
                    result["status"] = "failed"
            except (OSError, lab.ProbeFailure) as error:
                result.update(status="failed", cleanupError=str(error)[:2000])
        result.update(qmpQuitAcknowledged=quit_ack, fallbackTerminatedPids=forced,
                      childExits=[child.process.returncode for child in owned], ownershipReleased=True)
        lab.exclusive_json(fixture / "qmp.json", records)
        lab.exclusive_json(fixture / "result.json", result)
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)
        os.umask(mask)
    print(json.dumps({"fixture": fixture.name, **result}), flush=True)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--platform-directory", type=Path, required=True)
    parser.add_argument("--qemu-record", type=Path, required=True)
    parser.add_argument("--vectors-directory", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--strict-time-candidate", action="store_true",
                        help="Use only the separately pinned timestamp-corrected candidate")
    raise SystemExit(run(parser.parse_args()))
