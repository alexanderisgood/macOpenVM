#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare one new original offline NVMe fixture; this never launches a guest."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import uuid

import windows_efi_probe as lab

DISK_BYTES = 33_554_432
QEMU_BYTES = 26_756_880
QEMU_HASH = "ed753107501522f937d6293e7119a6a3ee2c5c9b0294e13e1fc0c5671ff0528c"
CODE_HASH = "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532"
SOURCE_NAMES = {
    "prepare": "MacOpenVMNvmePrepareProbe.efi",
    "verify": "MacOpenVMNvmeVerifyProbe.efi",
}


def pinned(path, size, digest, boundary):
    data, record = lab.asset(path, boundary, size)
    if record != {"bytes": size, "sha256": digest}:
        raise lab.ProbeFailure("The qualified NVMe asset differs from its build record")
    return data


def candidate_record(path, platform):
    if (path.name != "candidate.json" or path.parent.parent != platform / "tools"
            or not re.fullmatch(r"efi-nvme-candidate-[0-9a-f]{32}", path.parent.name)):
        raise lab.ProbeFailure("Select only the separately qualified original NVMe payload build")
    lab.checked_directory(path.parent, platform, private=True)
    value = json.loads(lab.regular_bytes(path, 65536))
    if (value.get("schemaVersion") != 1 or value.get("scope") != "original-nvme-probe-build"
            or value.get("moduleOnly") is not True or value.get("buildExitCode") != 0
            or value.get("guestExecuted") is not False or set(value.get("payloads", {})) != {"prepare", "verify"}):
        raise lab.ProbeFailure("The original NVMe module build is not qualified")
    data = {}
    for phase, name in SOURCE_NAMES.items():
        entry = value["payloads"][phase]
        if (entry.get("file") != name or type(entry.get("bytes")) is not int
                or not 4096 <= entry["bytes"] <= 65536
                or not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", ""))):
            raise lab.ProbeFailure("The NVMe payload build record is invalid")
        content = pinned(path.parent / name, entry["bytes"], entry["sha256"], platform)
        pe = int.from_bytes(content[60:64], "little")
        if (content[:2] != b"MZ" or pe > len(content) - 94 or content[pe:pe + 4] != b"PE\0\0"
                or int.from_bytes(content[pe + 4:pe + 6], "little") != 0xAA64
                or int.from_bytes(content[pe + 24:pe + 26], "little") != 0x20B
                or int.from_bytes(content[pe + 92:pe + 94], "little") != 10):
            raise lab.ProbeFailure("Expected an original AArch64 EFI application")
        data[phase] = content
    return value, data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--platform-directory", type=Path, required=True)
    parser.add_argument("--payload-candidate-record", type=Path, required=True)
    args = parser.parse_args()
    if not args.prepare:
        raise SystemExit("SKIP: explicit --prepare and qualified payload/platform paths required")
    platform = args.platform_directory
    if (platform.parent != lab.ROOT / ".lab"
            or platform.name != "windows-platform-a77101301bb14ba085a3a6e4b4f070ab"):
        raise lab.ProbeFailure("Select the exact retained original platform build")
    lab.checked_directory(platform, lab.ROOT, private=True)
    candidate, payloads = candidate_record(args.payload_candidate_record, platform)
    qemu = platform / "tools/qemu-pkcs7-envelope-candidate-158d2cad44c94efbab3e1880329ed8f3/qemu-system-aarch64"
    pinned(qemu, QEMU_BYTES, QEMU_HASH, platform)
    firmware = pinned(platform / lab.FIRMWARE, *lab.PINS[lab.FIRMWARE], platform)
    # Reserve stays explicit even though the initial disk/code files are sparse.
    if os.statvfs(lab.ROOT).f_bavail * os.statvfs(lab.ROOT).f_frsize < 20 * 1024**3 + DISK_BYTES:
        raise lab.ProbeFailure("The fixture would breach the retained host-space reserve")
    previous_mask = os.umask(0o077)
    try:
        identifier = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex
        fixture = lab.ROOT / ".lab" / ("windows-nvme-probe-" + identifier)
        fixture.mkdir(mode=0o700)
        short = Path("/private/tmp") / ("mvo-nvme-" + uuid.uuid4().hex[:16])
        short.mkdir(mode=0o700)
        if len(os.fsencode(short / "qmp.sock")) >= 104:
            raise lab.ProbeFailure("The private Unix endpoint path exceeds its bound")
        code = fixture / "firmware-code-64m.fd"
        lab.exclusive_file(code, firmware)
        fd = os.open(code, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.ftruncate(fd, 67_108_864)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(code, 0o400)
        if hashlib.sha256(lab.regular_bytes(code, 67_108_864)).hexdigest() != CODE_HASH:
            raise lab.ProbeFailure("The padded firmware differs from the exact retained code")
        disk = fixture / "nvme-test.raw"
        fd = os.open(disk, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            os.ftruncate(fd, DISK_BYTES)
            os.fsync(fd)
        finally:
            os.close(fd)
        if any(lab.regular_bytes(disk, DISK_BYTES)):
            raise lab.ProbeFailure("The new disposable disk is not zero initialized")
        lab.exclusive_file(fixture / "uefi-vars.json", b"")
        groups = [secrets.token_bytes(length) for length in (16, 8, 32)]
        if not all(any(value) for value in groups):
            raise lab.ProbeFailure("The original fixture identity generator returned a zero group")
        fixture_data = b"MVONVME1" + b"".join(groups)
        for phase in ("prepare", "verify"):
            media = fixture / (phase + "-media")
            (media / "EFI/BOOT").mkdir(parents=True, mode=0o700)
            for target, content in ((media / "EFI/BOOT/BOOTAA64.EFI", payloads[phase]),
                                    (media / "MVO-NVME-DATA.BIN", fixture_data)):
                lab.exclusive_file(target, content)
                os.chmod(target, 0o400)
        # This file is a prepared recipe only, never runtime continuation authority.
        lab.exclusive_json(fixture / "nvme-prepared.json", {
            "schemaVersion": 1, "scope": "new-owned-offline-no-os-nvme-fixture",
            "status": "prepared", "nativeChildrenLaunched": False, "vmID": str(uuid.uuid4()),
            "qemuExecutable": str(qemu), "socketDirectory": str(short),
        })
        lab.exclusive_json(fixture / "preparation-record.json", {
            "schemaVersion": 1, "scope": "new-original-nvme-fixture-assets",
            "payloadCandidateRecordSHA256": hashlib.sha256(lab.regular_bytes(args.payload_candidate_record, 65536)).hexdigest(),
            "payloads": candidate["payloads"], "firmwareCodeSHA256": CODE_HASH,
            "diskBytes": DISK_BYTES, "initialDiskZero": True,
            "fixtureDataSHA256": hashlib.sha256(fixture_data).hexdigest(),
            "windowsCompatibilityVerified": False, "guestLaunched": False,
        })
        print(json.dumps({"status": "prepared", "fixture": fixture.name}), flush=True)
        return 0
    finally:
        os.umask(previous_mask)


if __name__ == "__main__":
    raise SystemExit(main())
