#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit signed-CLI media contract on one newly created, never-booted VM.

Preserves the fixture and exact metadata backups; never selects an existing VM.
This tests cooperating ownership and metadata preservation, not guest bootability.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
MEDIA_SHA256 = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args()
    if not args.run:
        raise SystemExit("SKIP: explicit --run and signed native CLI are required.")
    cli = ROOT / "build/bin/macopenvm"
    media = ROOT / ".lab/media/alpine-virt-3.24.2-aarch64.iso"
    if not media.is_file() or digest(media) != MEDIA_SHA256:
        raise SystemExit("SKIP: verified local Alpine ARM64 test media is required.")
    subprocess.run(["codesign", "--verify", "--strict", str(cli)], check=True)
    probe = json.loads(subprocess.check_output([str(cli), "probe"]))
    if not probe["virtualizationSupported"] or not probe["virtualizationEntitled"]:
        raise SystemExit("SKIP: signed native virtualization is unavailable.")
    session = ROOT / (".lab/installation-media-contract-" + uuid.uuid4().hex)
    session.mkdir(mode=0o700)
    directory = session / "VM.macopenvm"
    command_count = 0

    def command(arguments, expected=0):
        nonlocal command_count
        command_count += 1
        result = subprocess.run([str(cli), *arguments], capture_output=True, timeout=15)
        if len(result.stdout) + len(result.stderr) > 131_072:
            raise RuntimeError("CLI output exceeded the contract bound")
        for suffix, data in (("out", result.stdout), ("err", result.stderr)):
            path = session / f"command-{command_count}.{suffix}"
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
        assert result.returncode == expected, "Unexpected CLI exit status"
        return json.loads(result.stdout) if expected == 0 else result.stderr

    print("New disposable fixture: " + session.name, flush=True)
    try:
        command(["create", "--directory", str(directory), "--media", str(media),
                 "--name", "Disposable media contract", "--cpus", "2",
                 "--memory-mib", "2048", "--disk-gib", "2", "--network", "disconnected"])
        registration = directory / "configuration.json"
        original_bytes = registration.read_bytes()
        original = json.loads(original_bytes)
        identity = {name: digest(directory / name)
                    for name in ("machine-identity.bin", "efi-variables.bin")}
        disk = directory / "disk.raw"
        disk_before = disk.stat()
        non_media = {key: value for key, value in original.items() if key != "installationMedia"}

        detached = command(["detach-media", "--directory", str(directory)])
        assert detached["changed"] and "installationMedia" not in detached["configuration"]
        first_backup = directory / detached["backupFile"]
        assert first_backup.read_bytes() == original_bytes
        assert stat.S_IMODE(first_backup.stat().st_mode) == 0o600
        assert first_backup.stat().st_nlink == 1
        detached_bytes = registration.read_bytes()
        assert json.loads(detached_bytes) == non_media

        noop = command(["detach-media", "--directory", str(directory)])
        assert not noop["changed"] and noop.get("backupFile") is None
        assert registration.read_bytes() == detached_bytes
        assert len(list(directory.glob("configuration-media-backup-*.json"))) == 1

        attached = command(["attach-media", "--directory", str(directory), "--media", str(media)])
        assert attached["changed"] and attached["configuration"] == original
        second_backup = directory / attached["backupFile"]
        assert second_backup.read_bytes() == detached_bytes
        assert stat.S_IMODE(second_backup.stat().st_mode) == 0o600
        assert second_backup.stat().st_nlink == 1
        assert json.loads(registration.read_bytes()) == original
        reattached_bytes = registration.read_bytes()

        empty = session / "empty.iso"
        empty.touch(mode=0o600, exist_ok=False)
        error = command(["attach-media", "--directory", str(directory), "--media", str(empty)], 1)
        assert b"empty" in error
        assert registration.read_bytes() == reattached_bytes
        assert len(list(directory.glob("configuration-media-backup-*.json"))) == 2

        # Simulate a separate cooperating writer using the same lifetime flock.
        # No guest is launched, and ownership is released by closing this descriptor.
        with (directory / "writer.lock").open("r+b") as writer:
            fcntl.flock(writer.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            error = command(["detach-media", "--directory", str(directory)], 1)
            assert b"another writer" in error
            assert registration.read_bytes() == reattached_bytes
            assert len(list(directory.glob("configuration-media-backup-*.json"))) == 2

        command(["validate", "--directory", str(directory)])
        assert {name: digest(directory / name) for name in identity} == identity
        disk_after = disk.stat()
        assert (disk_after.st_size, disk_after.st_blocks, disk_after.st_mtime_ns) == (
            disk_before.st_size, disk_before.st_blocks, disk_before.st_mtime_ns)
        assert first_backup.read_bytes() == original_bytes
        assert second_backup.read_bytes() == detached_bytes
        assert stat.S_IMODE(registration.stat().st_mode) == 0o600
        report = {"status": "passed", "cliSHA256": digest(cli),
                  "detachAndReattach": True, "exactPrivateBackups": True,
                  "noopPreservesBytes": True, "emptyImagePreservesRegistration": True,
                  "cooperatingWriterExcluded": True, "ownershipReleased": True,
                  "configurationValuesRestored": True, "nativeIdentityAndEFIUnchanged": True,
                  "diskLogicalBytes": disk_after.st_size,
                  "diskAllocatedBytes": disk_after.st_blocks * 512,
                  "diskModificationTimeUnchanged": True,
                  "limitations": "Never booted fixture; no installed-guest, filesystem or power-loss claim"}
        (session / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report), flush=True)
    except Exception as error:
        (session / "failure.json").write_text(json.dumps({"error": str(error),
                                                       "commandsRun": command_count,
                                                       "guestLaunched": False}) + "\n")
        print("Evidence preserved: " + session.name, flush=True)
        raise


if __name__ == "__main__":
    main()
