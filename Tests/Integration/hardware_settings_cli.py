#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise the real signed CLI on new private metadata fixtures; never boot a VM."""
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
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    args = parser.parse_args()
    cli = args.cli.resolve()
    if cli.parent.parent != ROOT / ".lab" or cli.name != "macopenvm":
        raise ValueError("Use a retained private build")
    os.umask(0o077)
    directory = ROOT / ".lab" / ("hardware-settings-" + uuid.uuid4().hex)
    directory.mkdir(mode=0o700)
    results = []
    for windows in [False, True]:
        vm = directory / ("windows-metadata" if windows else "linux-metadata")
        vm.mkdir(mode=0o700)
        c = {"schemaVersion": 1, "id": str(uuid.uuid4()).upper(), "name": "Hardware metadata trial",
             "guest": "windows11" if windows else "linux", "architecture": "arm64",
             "backend": "qemuHVF" if windows else "appleVz", "cpuCount": 2, "memoryBytes": 4 * GIB,
             "diskBytes": (64 if windows else 1) * GIB, "diskFile": "disk.raw", "boot": "efi",
             "kernelArguments": "console=hvc0", "network": "disconnected", "macAddress": "02:00:00:00:12:34"}
        original = json.dumps(c, indent=2).encode() + b"\n \n"
        (vm / "configuration.json").write_bytes(original)
        with (vm / "disk.raw").open("xb") as disk:
            disk.truncate(c["diskBytes"])
            disk.write(b"preserved test sector")
            disk.flush()
            os.fsync(disk.fileno())
        for name in ["machine-identity.bin", "efi-variables.bin", "tpm-state.bin"]:
            (vm / name).write_bytes(("synthetic identity fixture: " + name).encode())
        protected = {name: digest(vm / name) for name in ["machine-identity.bin", "efi-variables.bin", "tpm-state.bin"]}
        disk_info = (vm / "disk.raw").stat()

        def run(label, cpus, memory, expected_code, diagnostic=None):
            process = subprocess.run([str(cli), "set-hardware", "--directory", str(vm),
                                      "--cpus", str(cpus), "--memory-mib", str(memory)],
                                     capture_output=True, timeout=30)
            (vm / (label + ".stdout")).write_bytes(process.stdout)
            (vm / (label + ".stderr")).write_bytes(process.stderr)
            if process.returncode != expected_code or (diagnostic and diagnostic not in process.stderr):
                raise ValueError("Unexpected CLI result: " + label)
            results.append({"guest": c["guest"], "case": label, "exitCode": process.returncode})
            return json.loads(process.stdout) if not expected_code else None

        run("invalid-cpus", 999, 6144, 1, b"CPU allocation must leave host capacity")
        assert (vm / "configuration.json").read_bytes() == original
        if windows:
            run("windows-minimum", 1, 2048, 1, b"Windows requires")
            assert (vm / "configuration.json").read_bytes() == original
        with (vm / "writer.lock").open("xb+") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run("active-writer", 4, 6144, 1, b"already owned by another writer")
            assert (vm / "configuration.json").read_bytes() == original
        changed = run("save", 4, 6144, 0)
        assert changed["changed"] and (vm / changed["backupFile"]).read_bytes() == original
        expected = dict(c, cpuCount=4, memoryBytes=6 * GIB)
        assert changed["configuration"] == expected
        assert json.loads((vm / "configuration.json").read_bytes()) == expected
        before = (vm / "configuration.json").stat()
        no_op = run("no-op", 4, 6144, 0)
        assert not no_op["changed"] and "backupFile" not in no_op
        assert (vm / "configuration.json").stat().st_ino == before.st_ino
        assert len(list(vm.glob("configuration-hardware-backup-*"))) == 1
        assert all(digest(vm / name) == checksum for name, checksum in protected.items())
        after = (vm / "disk.raw").stat()
        assert (after.st_ino, after.st_size, after.st_blocks, after.st_mtime_ns) == (
            disk_info.st_ino, disk_info.st_size, disk_info.st_blocks, disk_info.st_mtime_ns)
        with (vm / "disk.raw").open("rb") as disk:
            assert disk.read(21) == b"preserved test sector"
    record = {"scope": "CLI metadata save/reject/no-op; no guest boot or platform identity qualification",
              "cliSHA256": digest(cli), "runnerSHA256": digest(Path(__file__)), "results": results}
    (directory / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"directory": str(directory), "casesPassed": len(results)}))


if __name__ == "__main__":
    main()
