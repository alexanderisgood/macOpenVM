#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit, user-approved offline installer observation; no installation claim.

Creates only a new fixture. Its retained parent owns QEMU/TPM handles until exit.
The English checksum association remains unresolved. This test never accepts a
licence, enters credentials, patches media, or changes the production launch gate.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import resource
import select
import shutil
import stat
import struct
import sys
import time
import uuid
import zlib

from windows_efi_probe import (ROOT, QEMU_VNC_DIRECTORY, QMP, Child, ProbeFailure,
                               private_qemu, executable, exclusive_file,
                               exclusive_json, regular_bytes, checked_directory)

PLATFORM = ROOT / ".lab/windows-platform-a77101301bb14ba085a3a6e4b4f070ab"
REFERENCE = ROOT / ".lab/windows-efi-probe-20261007T172609Z-b871dda885f443e68fe3f97458dbcc43"
MEDIA = ROOT / ".lab/windows-media-48f5f2b7600e4010b813985fcea79ef8/Windows11_Client_arm64_en-us_26300_9457.iso.partial"
MEDIA_BYTES = 8_528_523_264
MEDIA_HASH = "8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c"
ENGLISH_HASH = "dbf606ceb4ce1390f9f21ad1d96331848bc6b701cbab0012785881a1a1c0ec63"
CODE_HASH = "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532"


def is_boot_prompt(data):
    """Exact observed prompt pixels, excluding its changing countdown dots.

    A completely black lower area excludes the expired prompt's Boot Manager
    message. No text entry or general screen heuristic can trigger this action.
    """
    header = b"P6\n800 600\n255\n"
    if not data.startswith(header) or len(data) != len(header) + 800 * 600 * 3:
        return False
    pixels = data[len(header):]
    prefix = b"".join(pixels[y * 800 * 3:y * 800 * 3 + 260 * 3] for y in range(24))
    return (hashlib.sha256(prefix).hexdigest() == "8ee6493d8bf3c7a55a45e22bdebc902c046141602f5c7a1967f9f822058060ba"
            and not any(pixels[800 * 30 * 3:]))


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mode,
            info.st_uid, info.st_nlink, info.st_mtime_ns, info.st_ctime_ns)


def media_digest():
    checked_directory(MEDIA.parent, ROOT, private=True)
    fd = os.open(MEDIA, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        before = os.fstat(source.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_uid != os.getuid() or before.st_size != MEDIA_BYTES
                or stat.S_IMODE(before.st_mode) != 0o600):
            raise ProbeFailure("Expected the preserved private Microsoft download")
        digest = hashlib.file_digest(source, "sha256").hexdigest()
        if identity(before) != identity(os.fstat(source.fileno())) or identity(before) != identity(MEDIA.lstat()):
            raise ProbeFailure("Media changed while verifying it")
    if digest != MEDIA_HASH:
        raise ProbeFailure("Downloaded media differs from the expressly approved file")
    return identity(before)


def ppm_to_png(source, destination):
    # Lossless display-test representation; original PPM is always retained.
    data = regular_bytes(source, 64 * 1024 * 1024)
    import re
    header = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\n", data[:80])
    if header is None:
        raise ProbeFailure("Unexpected screenshot format")
    width, height = map(int, header.groups())
    pixels = data[header.end():]
    if not 1 <= width <= 8192 or not 1 <= height <= 8192 or len(pixels) != width * height * 3:
        raise ProbeFailure("Screenshot dimensions do not match pixels")
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value))
    scan = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(scan)) + chunk(b"IEND", b"")
    exclusive_file(destination, png)
    return {"width": width, "height": height, "ppmSHA256": hashlib.sha256(data).hexdigest(),
            "pngSHA256": hashlib.sha256(png).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--approved-checksum-discrepancy", action="store_true")
    parser.add_argument("--prepare-worker-only", action="store_true")
    parser.add_argument("--approved-installation", action="store_true",
                        help="Record explicit human authorization for a fresh VM installation")
    args = parser.parse_args()
    if not args.run or not args.approved_checksum_discrepancy:
        raise SystemExit("SKIP: explicit run and human-approved checksum discrepancy required")
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if shutil.disk_usage(ROOT).free < 20 * 2**30:
        raise ProbeFailure("Keep twenty GiB of host free-space reserve")
    before_media = media_digest()
    qemu, qemu_record = private_qemu(PLATFORM / QEMU_VNC_DIRECTORY / "candidate.json", PLATFORM, display=True)
    tpm, tpm_record = executable("swtpm", "0.10.2")
    if tpm_record["sha256"] != "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a":
        raise ProbeFailure("TPM tool changed")
    code = regular_bytes(REFERENCE / "firmware-code-64m.fd", 67_108_864)
    if len(code) != 67_108_864 or hashlib.sha256(code).hexdigest() != CODE_HASH:
        raise ProbeFailure("Firmware code differs from the qualified fixture")
    fixture = ROOT / ".lab" / ("windows-installer-boot-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    short = Path("/private/tmp") / ("mvo-win-" + uuid.uuid4().hex[:16])
    short.mkdir(mode=0o700)
    lock = os.open(fixture / "writer.lock", os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    exclusive_file(fixture / "firmware-code.fd", code)
    os.chmod(fixture / "firmware-code.fd", 0o400)
    exclusive_file(fixture / "uefi-vars.json", b"")
    (fixture / "tpm-state").mkdir(mode=0o700)
    disk = os.open(fixture / "blank-nvme.raw", os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    os.ftruncate(disk, 64 * 2**30)
    os.fsync(disk)
    os.close(disk)
    env = {"PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C", "TMPDIR": str(short)}
    qargs = [str(qemu), "-no-user-config", "-nodefaults", "-machine",
             "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off",
             "-accel", "hvf", "-cpu", "host", "-smp", "4", "-m", "6144",
             "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none",
             "-qmp", f"unix:{short}/qmp.sock,server=on,wait=off",
             "-drive", f"if=pflash,unit=0,format=raw,readonly=on,file={fixture}/firmware-code.fd",
             "-device", f"uefi-vars-sysbus,jsonfile={fixture}/uefi-vars.json,size=262144,force-secure-boot=off,disable-custom-mode=on",
             "-chardev", f"socket,id=chrtpm,path={short}/tpm.sock", "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
             "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on", "-device", "ramfb,id=display0",
             "-device", "qemu-xhci,id=xhci0", "-device", "usb-kbd,id=keyboard0,bus=xhci0.0",
             "-device", "usb-tablet,id=pointer0,bus=xhci0.0",
             "-drive", f"if=none,id=installer,format=raw,media=cdrom,readonly=on,file={MEDIA}",
             "-device", "usb-storage,drive=installer,bus=xhci0.0,bootindex=1",
             "-drive", f"if=none,id=target,format=raw,file={fixture}/blank-nvme.raw",
             "-device", "nvme,drive=target,serial=MVO-NEW-WIN-BOOT",
             "-L", qemu_record["runtimeDataDirectory"], "-k", qemu_record["runtimeDataDirectory"] + "/keymaps/en-us",
             "-vnc", f"unix:{short}/vnc.sock,share=force-shared"]
    targs = [str(tpm), "socket", "--tpm2", "--tpmstate", f"dir={fixture}/tpm-state,mode=0600,lock",
             "--ctrl", f"type=unixio,path={short}/tpm.sock,mode=0600,terminate", "--flags", "startup-none", "--log", "file=-"]
    exclusive_file(fixture / "runner-source.py", Path(__file__).read_bytes())
    exclusive_json(fixture / "recipe.json", {"qemuArgv": qargs, "swtpmArgv": targs, "qemu": qemu_record,
                   "tpm": tpm_record, "mediaSHA256": MEDIA_HASH, "selectedEnglishSHA256": ENGLISH_HASH,
                   "checksumAssociationResolved": False, "humanApprovedIsolatedBoot": True,
                   "secureBootProvisioned": False, "networkAttached": False, "newBlankDiskGiB": 64,
                   "licenseAcceptanceAuthorized": args.approved_installation,
                   "credentialsAuthorized": False})
    print("FIXTURE " + str(fixture), flush=True)
    if args.prepare_worker_only:
        exclusive_json(fixture / "swift-runtime-input.json", {
            "schemaVersion": 1, "scope": "approved-offline-windows-installer-fixture",
            "qemuArgv": qargs, "swtpmArgv": targs, "environment": env,
            "qmpSocket": str(short / "qmp.sock"), "tpmSocket": str(short / "tpm.sock"),
            "guestLaunched": False, "windowsCompatibilityVerified": False})
        exclusive_json(fixture / "result.json", {"status": "prepared", "preparedOnly": True,
            "nativeChildrenLaunched": False, "windowsCompatibilityVerified": False})
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)
        return 0
    owned = []
    guest = tpm_child = qmp = None
    records = []
    captures = []
    events = []
    failure = None
    try:
        tpm_child = Child(targs, "tpm", fixture, env, owned)
        deadline = time.monotonic() + 10
        while not (short / "tpm.sock").exists():
            if tpm_child.process.poll() is not None or time.monotonic() > deadline:
                raise ProbeFailure("TPM startup failed")
            time.sleep(0.05)
        guest = Child(qargs, "guest", fixture, env, owned)
        exclusive_json(fixture / "owned-processes.json", {"qemu": guest.process.pid, "tpm": tpm_child.process.pid})
        deadline = time.monotonic() + 10
        while not (short / "qmp.sock").exists():
            if guest.process.poll() is not None or time.monotonic() > deadline:
                raise ProbeFailure("QEMU startup failed")
            time.sleep(0.05)
        qmp = QMP(short / "qmp.sock", records)
        # Observe this known media prompt while it is live; one key, no blind
        # delay-based typing, no installer navigation or licence interaction.
        for attempt in range(36):
            target = fixture / f"boot-prompt-{attempt:02d}.ppm"
            try:
                qmp.execute("screendump", 10 + attempt, {"filename": str(target)})
            except ProbeFailure as error:
                # Before GOP initialization QEMU legitimately has no framebuffer.
                if not records or "There is no console" not in str(records[-1].get("error", {})):
                    raise error
            if target.exists() and is_boot_prompt(regular_bytes(target, 64 * 1024 * 1024)):
                qmp.execute("send-key", 60, {"keys": [{"type": "qcode", "data": "spc"}], "hold-time": 100})
                events.append({"scope": "one-space-for-exact-observed-media-boot-prompt",
                               "evidence": target.name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
                print("Matched live Windows boot prompt; sent one space", flush=True)
                break
            time.sleep(0.4)
        identifier = 100
        deadline = time.monotonic() + 600
        print("READY: capture | boot-key (only after observing boot prompt) | stop", flush=True)
        while time.monotonic() < deadline:
            if any(c.process.poll() is not None or c.errors() for c in owned):
                raise ProbeFailure("A runtime child ended or its log drain failed")
            readable, _, _ = select.select([sys.stdin], [], [], 1)
            if not readable:
                continue
            line = sys.stdin.readline()
            if not line:
                break
            command = line.strip()
            identifier += 1
            if command == "stop":
                break
            if command == "capture" and len(captures) < 12:
                target = fixture / f"capture-{len(captures):02d}.ppm"
                qmp.execute("screendump", identifier, {"filename": str(target)})
                snapshot = ppm_to_png(target, target.with_suffix(".png"))
                snapshot["name"] = target.with_suffix(".png").name
                captures.append(snapshot)
                print("CAPTURE " + str(target.with_suffix(".png")), flush=True)
            elif command == "boot-key" and not events:
                qmp.execute("send-key", identifier, {"keys": [{"type": "qcode", "data": "spc"}], "hold-time": 100})
                events.append({"scope": "one-space-for-observed-media-boot-prompt"})
                print("Boot-prompt space sent once", flush=True)
            else:
                print("No action: unknown command or fixed limit reached", flush=True)
    except BaseException as error:
        failure = type(error).__name__ + ": " + str(error)[:500]
    finally:
        # Actual retained child handles only, never stored-PID reconstruction.
        if guest is not None and guest.process.poll() is None:
            try:
                if qmp is None:
                    qmp = QMP(short / "qmp.sock", records)
                qmp.execute("quit", 1000)
            except (OSError, ValueError, ProbeFailure):
                guest.process.terminate()
        if qmp is not None:
            qmp.close()
        for child in reversed(owned):
            try:
                child.process.wait(timeout=15)
            except Exception:
                child.process.terminate()
                # Retain the actual handle until it is reaped; no timeout is exit.
                child.process.wait()
            child.finish()
        after_media = media_digest()
        result = {"scope": "approved-offline-Windows-installer-boot-observation", "failure": failure,
                  "captures": captures, "inputEvents": events, "mediaPreserved": before_media == after_media,
                  "qemuExit": guest.process.returncode if guest else None,
                  "tpmExit": tpm_child.process.returncode if tpm_child else None,
                  "drainsFinished": all(not d.thread.is_alive() and not d.error for c in owned for d in (c.stdout, c.stderr)),
                  "blankDiskAllocatedBytes": (fixture / "blank-nvme.raw").stat().st_blocks * 512,
                  "windowsInstalled": False, "windowsCompatibilityVerified": False,
                  "licenseAccepted": False, "credentialsEntered": False, "checksumAssociationResolved": False}
        exclusive_json(fixture / "qmp.json", records)
        exclusive_json(fixture / "result.json", result)
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)
        print(json.dumps(result), flush=True)
    return 0 if failure is None and result["mediaPreserved"] and result["drainsFinished"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
