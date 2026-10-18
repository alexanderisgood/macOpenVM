#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Qualify signed CLI networking metadata saves on fresh fixtures, without VM boot."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
GIB = 2**30


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    cli = parser.parse_args().cli.resolve()
    if cli.parent.parent != ROOT / ".lab" or cli.name != "macopenvm":
        raise ValueError("Use a retained private build")
    os.umask(0o077)
    root = ROOT / ".lab" / ("network-settings-" + uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    results = []
    for guest, backend in [("linux", "appleVz"), ("windows11", "qemuHVF")]:
        vm = root / guest
        vm.mkdir(mode=0o700)
        mode = "disconnected" if guest == "linux" else "shared"
        configuration = {
            "schemaVersion": 1, "id": str(uuid.uuid4()).upper(),
            "name": "literal shared disconnected network", "guest": guest,
            "architecture": "arm64", "backend": backend, "cpuCount": 2,
            "memoryBytes": 4 * GIB, "diskBytes": (64 if guest == "windows11" else 1) * GIB,
            "diskFile": "disk.raw", "boot": "efi", "kernelArguments": "console=hvc0",
            "network": mode, "macAddress": "02:00:00:00:12:34"}
        encoded = json.dumps(configuration, indent=2).replace('"network":', '"\\u006eetwork":')
        original = b"\xef\xbb\xbf" + encoded.encode() + b"\n \n"
        registration = vm / "configuration.json"
        registration.write_bytes(original)
        with (vm / "disk.raw").open("xb") as disk:
            disk.truncate(configuration["diskBytes"])
            disk.write(b"network save preservation witness")
            disk.flush()
            os.fsync(disk.fileno())
        for name in ["machine-identity.bin", "efi-variables.bin", "tpm-state.bin"]:
            (vm / name).write_bytes(("synthetic state: " + name).encode())
        protected = {name: digest(vm / name) for name in [
            "machine-identity.bin", "efi-variables.bin", "tpm-state.bin"]}
        disk_before = (vm / "disk.raw").stat()

        def run(label, requested, expected_code, diagnostic=None):
            process = subprocess.run(
                [str(cli), "set-network", "--directory", str(vm), "--network", requested],
                capture_output=True, timeout=30)
            (vm / (label + ".stdout")).write_bytes(process.stdout)
            (vm / (label + ".stderr")).write_bytes(process.stderr)
            if process.returncode != expected_code or (diagnostic and diagnostic not in process.stderr):
                raise ValueError("Unexpected CLI result: " + label)
            results.append({"guest": guest, "case": label, "exitCode": process.returncode})
            return json.loads(process.stdout) if not expected_code else None

        run("invalid-mode", "bridged", 1, b"Choose an explicit")
        assert registration.read_bytes() == original
        if guest == "windows11":
            run("unsupported-shared", "shared", 1, b"requires native Linux")
            assert registration.read_bytes() == original
        else:
            with (vm / "writer.lock").open("xb+") as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                run("held-writer", "shared", 1, b"already owned by another writer")
                assert registration.read_bytes() == original
        selected = "shared" if guest == "linux" else "disconnected"
        result = run("save", selected, 0)
        expected_bytes = original.replace(
            ('"\\u006eetwork": "' + mode + '"').encode(),
            ('"\\u006eetwork": "' + selected + '"').encode())
        assert expected_bytes != original and registration.read_bytes() == expected_bytes
        assert result["changed"] and (vm / result["backupFile"]).read_bytes() == original
        expected = dict(configuration, network=selected)
        assert result["configuration"] == expected
        inode = registration.stat().st_ino
        no_op = run("no-op", selected, 0)
        assert not no_op["changed"] and "backupFile" not in no_op
        assert registration.stat().st_ino == inode and registration.read_bytes() == expected_bytes
        assert len(list(vm.glob("configuration-network-backup-*"))) == 1
        if guest == "linux":
            returned = run("disconnect", "disconnected", 0)
            assert returned["changed"] and registration.read_bytes() == original
            assert (vm / returned["backupFile"]).read_bytes() == expected_bytes
        assert all(digest(vm / name) == checksum for name, checksum in protected.items())
        disk_after = (vm / "disk.raw").stat()
        assert (disk_before.st_ino, disk_before.st_size, disk_before.st_blocks, disk_before.st_mtime_ns) == (
            disk_after.st_ino, disk_after.st_size, disk_after.st_blocks, disk_after.st_mtime_ns)
        with (vm / "disk.raw").open("rb") as disk:
            assert disk.read(33) == b"network save preservation witness"
        assert not (vm / "runtime.json").exists()
    record = {"scope": "stopped CLI save/reject/no-op; no VM, connectivity or native platform qualification",
              "cliSHA256": digest(cli), "runnerSHA256": digest(Path(__file__)), "results": results}
    output = root / "result.json"
    output.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"directory": str(root), "casesPassed": len(results), "resultSHA256": digest(output)}))


if __name__ == "__main__":
    main()
