#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit two-boot NV test in a new offline diskless fixture; never Windows acceptance."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import resource
import stat
import sys
import time
import uuid

import windows_efi_probe as lab

PAYLOAD_ROOT = "source/edk2/Build/MacOpenVMFirmwareLab/NOOPT_CLANGDWARF/AARCH64/"
PAYLOADS = {
    "prepare": ("MacOpenVMTpmNvPrepareProbe.efi", "fbfbcd89b386d12f14f3556c90303da76b68858aa371c459cdeb0fec88251131"),
    "verify": ("MacOpenVMTpmNvVerifyProbe.efi", "cc47fe61c2ba1084023a6e764da6ab214be1b11cd78befec65d71ab58634e99d"),
}


def snapshot_store(directory, fixture):
    lab.checked_directory(directory, fixture, private=True)
    records = {}
    for path in sorted(directory.iterdir()):
        if len(records) >= 8 or path.name not in {
                ".lock", "tpm2-00.permall", "tpm2-00.volatilestate", "tpm2-00.savestate"}:
            raise lab.ProbeFailure("Unexpected TPM store entry")
        if stat.S_IMODE(path.lstat().st_mode) != 0o600:
            raise lab.ProbeFailure("TPM store file permissions changed")
        content = lab.regular_bytes(path, 4_194_304, minimum=0)
        records[path.name] = {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}
    if "tpm2-00.permall" not in records:
        raise lab.ProbeFailure("Persistent TPM state was not saved")
    return records


def observation(output, phase):
    clean = lab.ANSI_CSI.sub(b"", output).replace(b"\r", b"")
    if b"mvo.nv-probe.failure" in clean:
        raise lab.ProbeFailure("The NV payload reported a controlled failure")
    begin = f"mvo.nv-probe.begin version=1 phase={phase} index=0x01804d56".encode()
    count = 5 if phase == "prepare" else 2
    complete = (f"mvo.nv-probe.complete phase={phase} index=0x01804d56 "
                f"bytes=32 commands={count} marker-verified=1").encode()
    lines = clean.lower().splitlines()
    if complete not in lines:
        return False
    if begin not in lines or lines.count(complete) != 1:
        raise lab.ProbeFailure("Missing or repeated NV phase observations")
    rows = re.findall(rb"^mvo\.nv-probe\.command phase=([a-z]+) code=0x([0-9a-f]{8}) "
                      rb"status=success rc=0x([0-9a-f]{8}) response-bytes=([0-9]+)$", clean.lower(), re.M)
    expected = ([("00000169", "0000018b", 10), ("0000012a", "00000000", 19),
                 ("00000137", "00000000", 19)] if phase == "prepare" else [])
    expected += [("00000169", "00000000", 62), ("0000014e", "00000000", 53)]
    if [(code.decode(), rc.decode(), int(size)) for found_phase, code, rc, size in rows
            if found_phase.decode() == phase] != expected or len(rows) != count:
        raise lab.ProbeFailure("NV completion lacks the exact bounded command sequence")
    return True


def checked_media(directory, fixture):
    expected = {"EFI", "EFI/BOOT", "EFI/BOOT/BOOTAA64.EFI", "MVO-NV-NONCE.TXT"}
    found = set()
    for root, directories, files in os.walk(directory, followlinks=False):
        for name in (*directories, *files):
            path = Path(root) / name
            relative = str(path.relative_to(directory))
            if relative not in expected:
                raise lab.ProbeFailure("Unexpected readonly NV media entry")
            if relative in {"EFI", "EFI/BOOT"}:
                lab.checked_directory(path, fixture)
            else:
                lab.regular_bytes(path, 65_536)
                if stat.S_IMODE(path.lstat().st_mode) != 0o400:
                    raise lab.ProbeFailure("NV media is not readonly")
            found.add(relative)
    if found != expected:
        raise lab.ProbeFailure("Readonly NV media is incomplete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--platform-directory", type=Path)
    parser.add_argument("--qemu-candidate-record", type=Path)
    parser.add_argument("--crash-after-prepare", action="store_true",
                        help="SIGKILL only the new owned TPM/QEMU test pair after verified preparation")
    args = parser.parse_args()
    if not args.run or args.platform_directory is None or args.qemu_candidate_record is None:
        raise SystemExit("SKIP: requires --run and explicit reviewed platform/candidate paths")
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("SKIP: requires Apple-silicon macOS and native HVF")
    source = args.platform_directory
    if source.parent != lab.ROOT / ".lab" or not re.fullmatch(r"windows-platform-[0-9a-f]{32}", source.name):
        raise lab.ProbeFailure("Select only the reviewed private platform lab")
    lab.checked_directory(source, lab.ROOT, private=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    fixture = lab.ROOT / ".lab" / ("tpm-nv-persistence-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    old_umask = os.umask(0o077)
    lock = os.open(fixture / "writer.lock", os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    owned = []
    pairs = []
    qmp = None
    qmp_records = []
    phases = []
    fallback = []
    intentional_crash = []
    failure = None
    result = {"schemaVersion": 1, "status": "failed", "windowsCompatibilityVerified": False,
              "secureBootProvisioned": False, "crashPersistenceVerified": False,
              "powerLossPersistenceVerified": False,
              "guestOsShutdownVerified": False, "osDiskAttached": False, "networkAttached": False,
              "accelerator": "hvf", "inheritedCoreFileLimitBytes": 0}
    try:
        short = Path("/private/tmp") / ("mvo-nv-" + uuid.uuid4().hex[:16])
        short.mkdir(mode=0o700)
        environment = {"PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C", "TMPDIR": str(short)}
        lab.exclusive_json(fixture / "paths.json", {"platformDirectory": str(source), "socketDirectory": str(short)})
        runner = lab.regular_bytes(Path(__file__).resolve(), 131_072)
        lab.exclusive_file(fixture / "runner-source.py", runner)
        lab.exclusive_file(fixture / "shared-runner-source.py", lab.regular_bytes(Path(lab.__file__).resolve(), 131_072))
        qemu, qemu_record = lab.private_qemu(args.qemu_candidate_record, source)
        if not qemu_record.get("nativeGicFeatureAdvertised"):
            raise lab.ProbeFailure("Requires the reviewed native-GIC-corrected standard binary")
        swtpm, tpm_record = lab.executable("swtpm", "0.10.2")
        for name, binary in (("qemu", qemu), ("swtpm", swtpm)):
            lab.bounded_tool(["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                             name + "-signature", fixture, environment, owned)
        entitlements, _ = lab.bounded_tool(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(qemu)],
                                           "qemu-entitlements", fixture, environment, owned)
        if plistlib.loads(entitlements) != {"com.apple.security.hypervisor": True}:
            raise lab.ProbeFailure("Requires the exact reviewed Hypervisor entitlement")
        qemu_version, _ = lab.bounded_tool([str(qemu), "--version"], "qemu-version", fixture, environment, owned)
        tpm_version, _ = lab.bounded_tool([str(swtpm), "--version"], "swtpm-version", fixture, environment, owned)
        if not qemu_version.startswith(b"QEMU emulator version 11.1.0") or b"version 0.10.2" not in tpm_version:
            raise lab.ProbeFailure("Tool versions changed")
        original = {}
        firmware, record = lab.asset(source / lab.FIRMWARE, source, 16_777_216)
        size, digest = lab.PINS[lab.FIRMWARE]
        if record != {"bytes": size, "sha256": digest}:
            raise lab.ProbeFailure("Firmware changed")
        original[lab.FIRMWARE] = record
        code = fixture / "firmware-code-64m.fd"
        lab.exclusive_file(code, firmware)
        descriptor = os.open(code, os.O_RDWR | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "r+b") as destination:
            destination.truncate(67_108_864)
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(code, 0o400)
        readonly = {str(code.relative_to(fixture)): lab.asset(code, fixture, 67_108_864)[1]}
        nonce = uuid.uuid4().hex.encode("ascii")
        result["nonceSHA256"] = hashlib.sha256(nonce).hexdigest()
        media = {}
        for phase, (filename, expected_hash) in PAYLOADS.items():
            relative = PAYLOAD_ROOT + filename
            payload, record = lab.asset(source / relative, source, 65_536)
            if record != {"bytes": 32_768, "sha256": expected_hash}:
                raise lab.ProbeFailure("NV payload differs from the reviewed build")
            pe = int.from_bytes(payload[60:64], "little")
            if (payload[:2] != b"MZ" or pe > len(payload) - 94 or payload[pe:pe + 4] != b"PE\0\0" or
                    int.from_bytes(payload[pe + 4:pe + 6], "little") != 0xAA64 or
                    int.from_bytes(payload[pe + 92:pe + 94], "little") != 10):
                raise lab.ProbeFailure("Requires an AArch64 EFI payload")
            original[relative] = record
            directory = fixture / (phase + "-media")
            directory.mkdir(mode=0o700)
            (directory / "EFI").mkdir(mode=0o700)
            (directory / "EFI/BOOT").mkdir(mode=0o700)
            for target, content in ((directory / "EFI/BOOT/BOOTAA64.EFI", payload),
                                    (directory / "MVO-NV-NONCE.TXT", nonce)):
                lab.exclusive_file(target, content)
                os.chmod(target, 0o400)
                readonly[str(target.relative_to(fixture))] = lab.asset(target, fixture, 65_536)[1]
            checked_media(directory, fixture)
            media[phase] = directory
        variables = fixture / "uefi-vars.json"
        lab.exclusive_file(variables, b"")
        store = fixture / "tpm-state"
        store.mkdir(mode=0o700)
        if any(store.iterdir()):
            raise lab.ProbeFailure("New TPM store is not empty")
        if any("," in str(path) or ":" in str(path) for path in (fixture, source, short)):
            raise lab.ProbeFailure("Private QEMU paths contain separators")
        lab.exclusive_json(fixture / "assets.json", {"sourceArtifacts": original, "readonly": readonly,
                                                    "qemu": qemu_record, "swtpm": tpm_record,
                                                    "runnerSHA256": hashlib.sha256(runner).hexdigest()})
        print("NV fixture created: " + fixture.name, flush=True)
        saved = None
        for phase in ("prepare", "verify"):
            if phase == "verify" and snapshot_store(store, fixture) != saved:
                raise lab.ProbeFailure("Saved TPM state changed before the second daemon launch")
            tpm_socket = short / (phase + "-tpm.sock")
            qmp_socket = short / (phase + "-qmp.sock")
            if any(len(os.fsencode(path)) >= 104 for path in (tpm_socket, qmp_socket)):
                raise lab.ProbeFailure("Darwin socket path exceeds its bound")
            tpm_argv = [str(swtpm), "socket", "--tpm2", "--tpmstate", f"dir={store},mode=0600,lock",
                        "--ctrl", f"type=unixio,path={tpm_socket},mode=0600,terminate",
                        "--flags", "startup-none", "--log", "file=-"]
            qemu_argv = [str(qemu), "-no-user-config", "-nodefaults", "-machine",
                         "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off",
                         "-accel", "hvf", "-cpu", "host", "-smp", "2", "-m", "2048",
                         "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none",
                         "-qmp", f"unix:{qmp_socket},server=on,wait=off",
                         "-drive", f"if=pflash,unit=0,format=raw,readonly=on,file={code}",
                         "-device", f"uefi-vars-sysbus,jsonfile={variables},size=262144,force-secure-boot=off,disable-custom-mode=on",
                         "-chardev", f"socket,id=chrtpm,path={tpm_socket}",
                         "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                         "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on",
                         "-drive", f"if=none,id=efimedia,format=raw,readonly=on,file=fat:16:{media[phase]}",
                         "-device", "virtio-blk-pci,drive=efimedia,bootindex=1"]
            lab.exclusive_json(fixture / (phase + "-recipe.json"),
                               {"qemuArgv": qemu_argv, "swtpmArgv": tpm_argv})
            tpm = lab.Child(tpm_argv, phase + "-tpm", fixture, environment, owned)
            readiness = time.monotonic() + 5
            while not tpm_socket.exists():
                if tpm.process.poll() is not None or tpm.errors() or time.monotonic() >= readiness:
                    raise lab.ProbeFailure("TPM socket readiness failed")
                time.sleep(0.05)
            metadata = tpm_socket.lstat()
            if (not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid() or
                    stat.S_IMODE(metadata.st_mode) != 0o600):
                raise lab.ProbeFailure("TPM socket is not private and owned")
            guest = lab.Child(qemu_argv, phase + "-guest", fixture, environment, owned, serial=True)
            pairs.append((guest, tpm, qmp_socket))
            lab.exclusive_json(fixture / (phase + "-start.json"),
                               {"qemuPid": guest.process.pid, "swtpmPid": tpm.process.pid})
            deadline = time.monotonic() + 60
            while not observation(guest.stdout.snapshot(), phase):
                if (guest.process.poll() is not None or tpm.process.poll() is not None or
                        guest.errors() or tpm.errors() or time.monotonic() >= deadline):
                    raise lab.ProbeFailure("NV phase failed before completion or exceeded its deadline")
                time.sleep(0.05)
            qmp = lab.QMP(qmp_socket, qmp_records)
            status = qmp.execute("query-status", 2)
            if not isinstance(status, dict) or status.get("status") != "running":
                raise lab.ProbeFailure("Firmware is not running at controlled completion")
            crash = args.crash_after_prepare and phase == "prepare"
            if crash:
                # These Popen owners were created above in this new diskless test
                # fixture. Kill TPM first so it cannot save state during an
                # orderly socket close; then stop the owned firmware runner.
                if guest.process.poll() is not None or tpm.process.poll() is not None:
                    raise lab.ProbeFailure("Owned test pair exited before the scoped crash injection")
                lab.exclusive_json(fixture / "crash-intent.json",
                                   {"scope": "new-diskless-test-pair", "signal": "SIGKILL",
                                    "tpmPid": tpm.process.pid, "qemuPid": guest.process.pid})
                tpm.process.kill()
                intentional_crash.append(tpm.process.pid)
                tpm.process.wait(timeout=10)
                if guest.process.poll() is None:
                    guest.process.kill()
                    intentional_crash.append(guest.process.pid)
                guest.process.wait(timeout=10)
            else:
                qmp.execute("quit", 100)
                guest.process.wait(timeout=10)
                tpm.process.wait(timeout=10)
            guest.finish()
            tpm.finish()
            qmp.close()
            qmp = None
            expected_exit = -9 if crash else 0
            if (guest.process.returncode != expected_exit or tpm.process.returncode != expected_exit or guest.errors() or
                    tpm.errors() or not observation(guest.stdout.snapshot(), phase)):
                raise lab.ProbeFailure("Final NV observations or owned shutdown failed")
            state = snapshot_store(store, fixture)
            phases.append({"phase": phase, "qmpQuitAcknowledged": not crash,
                           "shutdownKind": "scoped-owned-SIGKILL" if crash else "acknowledged-QMP-quit",
                           "qemuExit": guest.process.returncode, "swtpmExit": tpm.process.returncode,
                           "savedStore": state})
            if phase == "prepare":
                saved = state
                lab.exclusive_json(fixture / "saved-after-prepare.json", state)
            print("NV phase complete: " + phase, flush=True)
        for relative, record in original.items():
            if lab.asset(source / relative, source, 16_777_216)[1] != record:
                raise lab.ProbeFailure("Original readonly source artifact changed")
        for relative, record in readonly.items():
            if lab.asset(fixture / relative, fixture, 67_108_864)[1] != record:
                raise lab.ProbeFailure("Staged readonly artifact changed")
        for directory in media.values():
            checked_media(directory, fixture)
        result.update(status="passed", orderlyRestartNvPersistenceVerified=not args.crash_after_prepare,
                      crashPersistenceVerified=args.crash_after_prepare,
                      verifyPayloadContainsWriteCommands=False, readonlyHashesPreserved=True,
                      savedStoreUnchangedBeforeSecondLaunch=True)
    except BaseException as error:
        failure = error
        result["error"] = str(error) if isinstance(error, lab.ProbeFailure) else type(error).__name__
    finally:
        if qmp is not None:
            qmp.close()
        for guest, tpm, socket_path in pairs:
            if guest.process.poll() is None:
                connection = None
                try:
                    connection = lab.QMP(socket_path, qmp_records)
                    connection.execute("quit", 100)
                except BaseException:
                    pass
                finally:
                    if connection is not None:
                        connection.close()
        for child in reversed(owned):
            if child.process.poll() is None:
                try:
                    child.process.wait(timeout=5)
                except BaseException:
                    child.process.terminate()
                    fallback.append(child.process.pid)
                    failure = failure or lab.ProbeFailure("Owned test child needed fallback termination")
                    try:
                        child.process.wait(timeout=10)
                    except BaseException:
                        # Keep the fixture lock and process owner until actual exit.
                        print("Owned child remains active; retaining the test fixture lock", flush=True)
                        child.process.wait()
            try:
                child.finish()
            except BaseException:
                failure = failure or lab.ProbeFailure("Final bounded child log preservation failed")
        if failure is not None:
            result["status"] = "failed"
            result["orderlyRestartNvPersistenceVerified"] = False
            result["crashPersistenceVerified"] = False
        result.update(phases=phases, fallbackTerminatedPids=fallback,
                      intentionallyKilledTestPids=intentional_crash, ownershipReleased=True,
                      childExits=[{"pid": child.process.pid, "exit": child.process.returncode}
                                  for child in owned if any(child in pair[:2] for pair in pairs)])
        lab.exclusive_json(fixture / "qmp.json", qmp_records)
        lab.exclusive_json(fixture / "result.json", result)
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)
        os.umask(old_umask)
    print(json.dumps({"status": result["status"], "fixture": fixture.name,
                      "windowsCompatibilityVerified": False}), flush=True)
    return 1 if failure is not None else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except lab.ProbeFailure as error:
        raise SystemExit("FAIL: " + str(error)) from error
