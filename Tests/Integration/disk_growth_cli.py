#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fresh raw-container CLI qualification; never opens an existing VM or boots a guest.

Pending CLI cases deliberately alter a fresh completed record to pending. They
prove command admission only, not an actual interruption. Swift fault tests cover
real transaction boundaries. All fixtures and transcripts are retained.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import stat
import subprocess
import time
import uuid

GIB = 1 << 30
PREFIX = bytes((i * 7 + 3) & 255 for i in range(512))
OLD_TAIL = bytes((i * 11 + 9) & 255 for i in range(512))
CLI_IDENTITY = None


def cli_identity(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and before.st_nlink == 1
        assert before.st_uid == os.geteuid() and before.st_size <= 32 << 20
        digest = hashlib.sha256()
        while data := os.read(fd, 1 << 20):
            digest.update(data)
        after = os.fstat(fd)
        named = path.lstat()
        def stamp(info):
            return (info.st_dev, info.st_ino, info.st_size, info.st_mode, info.st_uid,
                    info.st_nlink, info.st_mtime_ns, info.st_ctime_ns)
        assert stamp(before) == stamp(after) == stamp(named)
        return stamp(after), digest.hexdigest()
    finally:
        os.close(fd)


def write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def inventory(directory):
    result = {}
    for path in sorted(directory.iterdir()):
        info = path.lstat()
        assert stat.S_ISREG(info.st_mode) and info.st_nlink == 1
        result[path.name] = [info.st_dev, info.st_ino, info.st_mode, info.st_uid,
                             info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
        if path.name != "disk.raw":
            assert info.st_size <= 65536
            result[path.name].append(hashlib.sha256(path.read_bytes()).hexdigest())
    return result


def run(cli, artifacts, label, args, expected):
    assert cli_identity(cli) == CLI_IDENTITY
    outputs = {"stdout": bytearray(), "stderr": bytearray()}
    selector = None
    deadline = time.monotonic() + 20
    timed_out = False
    overflow = False
    eof = False
    process = subprocess.Popen([str(cli), *args], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        selector = selectors.DefaultSelector()
        for name in outputs:
            pipe = getattr(process, name)
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, name)
        while selector.get_map():
            if time.monotonic() >= deadline:
                timed_out = True
                break
            for key, _ in selector.select(timeout=0.1):
                data = os.read(key.fileobj.fileno(), 4096)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                room = 65536 - sum(len(value) for value in outputs.values())
                outputs[key.data].extend(data[:max(0, room)])
                if len(data) > room:
                    overflow = True
                    break
            if overflow:
                break
        eof = not selector.get_map()
        if timed_out or overflow:
            if process.poll() is None:
                process.kill()  # Only this retained owned Popen, never a stored PID.
        try:
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
    finally:
        custody_record_attempted = False
        while process.returncode is None:
            try:
                if process.poll() is not None:
                    break
                try:
                    process.kill()
                except OSError:
                    # No exit is inferred from a failed signal; keep the same handle.
                    pass
                process.wait(timeout=5)
            except (subprocess.TimeoutExpired, OSError, KeyboardInterrupt):
                if not custody_record_attempted:
                    custody_record_attempted = True
                    try:
                        write_new(artifacts / (label + ".unconfirmed.stdout"), bytes(outputs["stdout"]))
                        write_new(artifacts / (label + ".unconfirmed.stderr"), bytes(outputs["stderr"]))
                        write_new(artifacts / (label + ".unconfirmed.json"),
                                  b'{"exitUnconfirmed":true,"ownedHandleRetained":true}\n')
                        print("Owned CLI exit is unconfirmed; retaining custody without restarting.", flush=True)
                    except (OSError, KeyboardInterrupt):
                        pass  # Evidence failure must not abandon the actual owned child.
        if selector is not None:
            selector.close()
        process.stdout.close()
        process.stderr.close()
        write_new(artifacts / (label + ".stdout"), bytes(outputs["stdout"]))
        write_new(artifacts / (label + ".stderr"), bytes(outputs["stderr"]))
        write_new(artifacts / (label + ".status.json"), (json.dumps(dict(
            returncode=process.returncode, timedOut=timed_out,
            outputOverflow=overflow, bothOutputEOF=eof)) + "\n").encode())
    assert not timed_out and not overflow and eof, label
    assert cli_identity(cli) == CLI_IDENTITY
    completed = subprocess.CompletedProcess([str(cli), *args], process.returncode,
                                            bytes(outputs["stdout"]), bytes(outputs["stderr"]))
    assert completed.returncode == expected, (label, completed.returncode)
    return json.loads(completed.stdout) if expected == 0 else completed


def preserved_run(cli, artifacts, directory, label, args, expected=1):
    before = inventory(directory)
    result = run(cli, artifacts, label, args, expected)
    assert inventory(directory) == before, label
    return result


def fixture(root, windows):
    directory = root / ("windows-container.macopenvm" if windows else "linux-container.macopenvm")
    directory.mkdir(mode=0o700)
    old = (64 if windows else 1) * GIB
    config = dict(schemaVersion=1, id=str(uuid.uuid4()).upper(), name="fresh private fixture",
                  guest="windows11" if windows else "linux", architecture="arm64",
                  backend="qemuHVF", cpuCount=2, memoryBytes=4 * GIB, diskBytes=old,
                  diskFile="disk.raw", boot="efi", kernelArguments="console=hvc0",
                  network="disconnected", macAddress="02:01:02:03:04:05")
    original = (json.dumps(config, indent=2) + "\n \n").encode()
    write_new(directory / "configuration.json", original)
    fd = os.open(directory / "disk.raw", os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.ftruncate(fd, old)
        assert os.pwrite(fd, PREFIX, 0) == len(PREFIX)
        assert os.pwrite(fd, OLD_TAIL, old - len(OLD_TAIL)) == len(OLD_TAIL)
        os.fsync(fd)
    finally:
        os.close(fd)
    return directory, config, original


def main():
    global CLI_IDENTITY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    options = parser.parse_args()
    cli = options.cli.resolve(strict=True)
    assert cli.is_file() and os.access(cli, os.X_OK)
    CLI_IDENTITY = cli_identity(cli)
    root = options.artifacts.absolute()
    assert not root.exists() and shutil.disk_usage(root.parent).free >= 2 * GIB
    root.mkdir(mode=0o700)
    rows = []
    for windows in (False, True):
        directory, config, original = fixture(root, windows)
        old = config["diskBytes"]
        target = old + GIB
        label = "windows" if windows else "linux"
        stamp = (directory / "disk.raw").stat()
        result = run(cli, root, label + "-grow", ["grow-disk", "--directory", str(directory),
                     "--disk-gib", str(target // GIB)], 0)
        assert result["oldBytes"] == old and result["targetBytes"] == target
        assert result["changed"] is True and result["recovered"] is False
        assert (directory / result["backupFile"]).read_bytes() == original
        desired = original.replace(('"diskBytes": ' + str(old)).encode(),
                                   ('"diskBytes": ' + str(target)).encode())
        assert (directory / "configuration.json").read_bytes() == desired
        current = (directory / "disk.raw").stat()
        assert (current.st_dev, current.st_ino, current.st_mode, current.st_uid, current.st_nlink) == (
            stamp.st_dev, stamp.st_ino, stamp.st_mode, stamp.st_uid, stamp.st_nlink)
        assert current.st_size == target and current.st_blocks * 512 < GIB
        fd = os.open(directory / "disk.raw", os.O_RDONLY | os.O_NOFOLLOW)
        try:
            assert os.pread(fd, 512, 0) == PREFIX
            assert os.pread(fd, 512, old - 512) == OLD_TAIL
            # Independently scan the whole newly added GiB, not merely its last sector.
            for offset in range(old, target, 1 << 20):
                assert os.pread(fd, 1 << 20, offset) == bytes(1 << 20)
        finally:
            os.close(fd)
        preserved_run(cli, root, directory, label + "-equal", ["grow-disk", "--directory",
                      str(directory), "--disk-gib", str(target // GIB)])
        preserved_run(cli, root, directory, label + "-shrink", ["grow-disk", "--directory",
                      str(directory), "--disk-gib", str(old // GIB)])
        preserved_run(cli, root, directory, label + "-no-pending", ["finish-disk-growth",
                      "--directory", str(directory)])
        preserved_run(cli, root, directory, label + "-missing-size", ["grow-disk",
                      "--directory", str(directory)])
        preserved_run(cli, root, directory, label + "-overflow", ["grow-disk", "--directory",
                      str(directory), "--disk-gib", str((1 << 63) - 1)])
        preserved_run(cli, root, directory, label + "-finish-override", ["finish-disk-growth",
                      "--directory", str(directory), "--disk-gib", "100"])
        marker = directory / "disk-growth-intent.json"
        completed_bytes = marker.read_bytes()
        pending_bytes = completed_bytes.replace(b'"state":"completed"', b'"state":"pending"')
        assert pending_bytes != completed_bytes
        # Explicit synthetic admission fixture, not crash/recovery evidence.
        marker_fd = os.open(marker, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            held = os.fstat(marker_fd)
            assert stat.S_ISREG(held.st_mode) and held.st_nlink == 1
            assert held.st_uid == os.geteuid() and stat.S_IMODE(held.st_mode) == 0o600
            assert os.pread(marker_fd, 4096, 0) == completed_bytes
            assert os.pwrite(marker_fd, pending_bytes, 0) == len(pending_bytes)
            os.ftruncate(marker_fd, len(pending_bytes))
            os.fsync(marker_fd)
            named = marker.lstat()
            assert (held.st_dev, held.st_ino) == (named.st_dev, named.st_ino)
        finally:
            os.close(marker_fd)
        for command in ("validate", "run", "detach-media", "grow-disk"):
            args = [command, "--directory", str(directory)]
            if command == "grow-disk":
                args += ["--disk-gib", str(target // GIB + 1)]
            refusal = preserved_run(cli, root, directory, label + "-pending-" + command, args)
            assert b"Disk growth could not be confirmed." in refusal.stderr
            assert not refusal.stdout
        doctor = preserved_run(cli, root, directory, label + "-pending-doctor",
                               ["doctor", "--directory", str(directory)], expected=2)
        assert any(item["code"] == "disk-growth-pending" for item in json.loads(doctor.stdout)["findings"])
        text = doctor.stdout.decode()
        assert str(directory) not in text and config["id"] not in text and config["name"] not in text
        before_finish = (directory / "disk.raw").stat()
        finished = run(cli, root, label + "-finish-synthetic-pending",
                       ["finish-disk-growth", "--directory", str(directory)], 0)
        assert finished["recovered"] is True and finished["targetBytes"] == target
        after_finish = (directory / "disk.raw").stat()
        assert (before_finish.st_ino, before_finish.st_size, before_finish.st_mtime_ns,
                before_finish.st_ctime_ns) == (after_finish.st_ino, after_finish.st_size,
                                              after_finish.st_mtime_ns, after_finish.st_ctime_ns)
        rows.append(dict(guestConfiguration=config["guest"], oldBytes=old, targetBytes=target,
                         addedZeroBytesScanned=GIB, originalSeedsPreserved=True,
                         diskInodeModeLinksPreserved=True, syntheticPendingAdmissionOnly=True,
                         syntheticTargetLengthFinishDidNotRetruncate=True))
    assert cli_identity(cli) == CLI_IDENTITY
    write_new(root / "result.json", (json.dumps(dict(schemaVersion=1,
              cliSHA256=CLI_IDENTITY[1], rows=rows), indent=2) + "\n").encode())
    print("Fresh Linux/Windows container growth, zero-tail scans and synthetic CLI admission passed.")


if __name__ == "__main__":
    main()
