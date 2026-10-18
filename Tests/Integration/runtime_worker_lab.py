#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit new diskless worker/client-loss trial; never an installed guest launcher."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def read_json(path, limit=4096):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        metadata = os.fstat(source.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or metadata.st_nlink != 1 or metadata.st_mode & 0o777 != 0o600
                or metadata.st_size > limit):
            raise ValueError("Unsafe bounded private trial record")
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Trial record exceeded bound")
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate trial record field")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique_pairs)


def save(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    if len(data) > 32768:
        raise ValueError("Trial evidence exceeded bound")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def selected_fixture(directory):
    if not directory.is_absolute() or directory != Path(os.path.abspath(directory)):
        raise ValueError("Select a normalized absolute private fixture")
    if (directory.parent != ROOT / ".lab"
            or not re.fullmatch(r"windows-efi-probe-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}", directory.name)):
        raise ValueError("Select only a new private original EFI fixture")
    current = Path("/")
    for component in directory.parts[1:]:
        current = current / component
        ancestor = current.lstat()
        root_temporary = current == Path("/private/tmp") and ancestor.st_uid == 0 and ancestor.st_mode & stat.S_ISVTX
        if (not stat.S_ISDIR(ancestor.st_mode) or ancestor.st_uid not in (0, os.geteuid())
                or (ancestor.st_mode & 0o022 and not root_temporary)):
            raise ValueError("Fixture ancestry is unsafe")
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o777 != 0o700:
        raise ValueError("Fixture is not private and owned")


def route(directory):
    value = read_json(directory / "swift-worker-ready.json")
    if (set(value) != {"schemaVersion", "scope", "vmID", "sessionID", "socket"}
            or value["schemaVersion"] != 1 or value["scope"] != "original-diskless-worker-route"):
        raise ValueError("Unexpected private worker route")
    uuid.UUID(value["vmID"])
    uuid.UUID(value["sessionID"])
    inputs = read_json(directory / "swift-runtime-input.json", 65536)
    if value["socket"] != str(Path(inputs["qmpSocket"]).parent / "worker.sock"):
        raise ValueError("Worker route differs from the original private socket directory")
    return value


class Client:
    def __init__(self, record):
        self.record = record
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(30)
        self.next_id = 1
        self.reconciled = False
        path = Path(record["socket"])
        parent, endpoint = path.parent.lstat(), path.lstat()
        if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid()
                or parent.st_mode & 0o777 != 0o700 or not stat.S_ISSOCK(endpoint.st_mode)
                or endpoint.st_uid != os.getuid() or endpoint.st_mode & 0o777 != 0o600):
            self.close()
            raise ValueError("Unsafe worker endpoint")
        try:
            self.socket.connect(record["socket"])
            uid, gid = ctypes.c_uint(), ctypes.c_uint()
            peer = ctypes.CDLL(None, use_errno=True).getpeereid
            peer.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
            peer.restype = ctypes.c_int
            if peer(self.socket.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0 or uid.value != os.geteuid():
                raise ValueError("Unexpected worker peer UID")
            after = path.lstat()
            if (endpoint.st_dev, endpoint.st_ino) != (after.st_dev, after.st_ino):
                raise ValueError("Worker endpoint changed during connection")
        except BaseException:
            self.close()
            raise

    def close(self):
        self.socket.close()

    def remaining(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Worker exchange deadline elapsed")
        self.socket.settimeout(remaining)

    def receive(self, size, deadline):
        result = bytearray()
        while len(result) < size:
            self.remaining(deadline)
            chunk = self.socket.recv(size - len(result))
            if not chunk:
                raise ValueError("Worker disconnected before reply")
            result.extend(chunk)
        return bytes(result)

    def request(self, command=0, revision=0):
        deadline = time.monotonic() + 30
        if command and not self.reconciled:
            raise ValueError("Inspect status before each explicit mutation")
        identifier = self.next_id
        self.next_id += 1
        vm_id = uuid.UUID(self.record["vmID"]).bytes
        session = uuid.UUID(self.record["sessionID"]).bytes
        payload = (bytes([1, 1, 0, 0]) + vm_id + session
                   + struct.pack(">QQB", identifier, revision, command) + bytes(3))
        self.remaining(deadline)
        self.socket.sendall(struct.pack(">I", len(payload)) + payload)
        size = struct.unpack(">I", self.receive(4, deadline))[0]
        if size != 64:
            raise ValueError("Unexpected bounded worker reply size")
        reply = self.receive(size, deadline)
        if (reply[:4] != bytes([1, 2, 0, 0]) or reply[4:20] != vm_id or reply[20:36] != session
                or struct.unpack(">Q", reply[36:44])[0] != identifier or any(reply[57:])
                or reply[52] > 10 or reply[53] > 3 or reply[54] > 1 or reply[55] > 1 or reply[56] > 5):
            raise ValueError("Unexpected worker response correlation or fields")
        self.reconciled = command == 0
        return dict(revision=struct.unpack(">Q", reply[44:52])[0], state=reply[52],
                    ownership=reply[53], backendActive=bool(reply[54]),
                    operationPending=bool(reply[55]), error=reply[56])


def wait_record(path, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists():
            try:
                return read_json(path)
            except (json.JSONDecodeError, ValueError):
                pass  # Exclusive writes may be in flight; bounded fresh read only.
        time.sleep(0.05)
    raise TimeoutError("Worker trial record was not published")


def bounded_serial(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                or info.st_mode & 0o777 != 0o600 or info.st_size > 2097152):
            raise ValueError("Unsafe capped serial evidence")
        data = source.read(2097153)
    if len(data) > 2097152:
        raise ValueError("Serial evidence exceeded bound")
    return data


def wait_running(record, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        client = Client(record)
        try:
            value = client.request()
        finally:
            client.close()
        if value["state"] == 2 and value["backendActive"] and not value["operationPending"]:
            return value
        if value["state"] == 10 or value["ownership"] != 0:
            raise ValueError("Worker failed before running")
        time.sleep(0.05)
    raise TimeoutError("Worker did not report actual running state")


def client_parent(cli, directory):
    selected_fixture(directory)
    with open("/dev/null", "rb") as input_stream:
        descriptors = [os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                       for name in ("worker-stdout.log", "worker-stderr.log")]
        try:
            worker = subprocess.Popen([str(cli), "qemu-worker-lab", "--directory", str(directory)],
                                      stdin=input_stream, stdout=descriptors[0], stderr=descriptors[1],
                                      close_fds=True, cwd=ROOT)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)
    save(directory / "client-worker-launch.json", {"schemaVersion": 1, "workerPID": worker.pid,
                                                 "clientPID": os.getpid()})
    wait_record(directory / "swift-worker-ready.json")
    record = route(directory)
    initial = wait_running(record)
    save(directory / "client-observed-running.json", {"schemaVersion": 1, "snapshot": initial})
    return worker.wait()


def writer_probe(directory, expected_busy):
    path = directory / "writer.lock"
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            busy = False
        except BlockingIOError:
            busy = True
        after = path.lstat()
        if busy != expected_busy or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError("Unexpected independent writer custody")
        return {"busy": busy, "device": before.st_dev, "inode": before.st_ino}
    finally:
        os.close(descriptor)  # Never LOCK_UN on a shared duplicate.


def run(cli, directory):
    selected_fixture(directory)
    if (directory / "swift-runtime.claim").exists():
        raise ValueError("The fixture has already been claimed")
    metadata = cli.lstat()
    if not stat.S_ISREG(metadata.st_mode) or not os.access(cli, os.X_OK):
        raise ValueError("Select the actual locally built signed CLI")
    with open("/dev/null", "rb") as input_stream:
        descriptors = [os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                       for name in ("client-stdout.log", "client-stderr.log")]
        try:
            parent = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                       "--internal-client-parent", "--cli", str(cli),
                                       "--directory", str(directory)], stdin=input_stream,
                                      stdout=descriptors[0], stderr=descriptors[1], close_fds=True, cwd=ROOT)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)
    phases = []
    record = None
    stopped = False
    try:
        wait_record(directory / "client-observed-running.json")
        record = route(directory)
        launch = read_json(directory / "client-worker-launch.json")
        if launch["clientPID"] != parent.pid or os.getsid(launch["workerPID"]) != launch["workerPID"]:
            raise ValueError("Worker session separation was not observed")
        deadline = time.monotonic() + 60
        serial = directory / "swift-qemu-stdout.log"
        completed = False
        while time.monotonic() < deadline:
            if serial.exists():
                data = bounded_serial(serial)
                if b"mvo.platform-probe.complete setup=1 secure-boot=0" in data:
                    completed = True
                    break
            time.sleep(0.05)
        if not completed:
            raise TimeoutError("Original EFI probe did not complete")
        before = writer_probe(directory, True)
        phases.append("native-running-original-efi-complete-writer-busy")
        # The harness owns this disposable client parent. Its child worker created an
        # independent session and has regular-file stdio, not a client-held pipe.
        parent.kill()
        parent.wait(timeout=10)
        time.sleep(0.1)
        current = route(directory)
        if current != record:
            raise ValueError("Reconnect route changed after client loss")
        after = writer_probe(directory, True)
        if before != after:
            raise ValueError("Writer lease identity changed after client loss")
        client = Client(record)
        try:
            running = client.request()
            if running["state"] != 2 or not running["backendActive"] or running["operationPending"]:
                raise ValueError("Same-session worker did not survive client loss")
            phases.append("client-parent-sigkill-same-session-reconnect-writer-busy")
            paused = client.request(1, running["revision"])
            if paused["error"] or paused["state"] != 4 or not paused["backendActive"]:
                raise ValueError("Pause was not observed through IPC")
            observed = client.request()
            resumed = client.request(2, observed["revision"])
            if resumed["error"] or resumed["state"] != 2 or not resumed["backendActive"]:
                raise ValueError("Resume was not observed through IPC")
            phases.append("ipc-pause-resume-observed")
            observed = client.request()
            stopped_reply = client.request(3, observed["revision"])
            if (stopped_reply["error"] or stopped_reply["state"] != 0 or stopped_reply["ownership"] != 2
                    or stopped_reply["backendActive"] or stopped_reply["operationPending"]):
                raise ValueError("Explicit stop did not settle actual ownership")
            stopped = True
        finally:
            client.close()
        result = wait_record(directory / "swift-worker-result.json")
        if (result["status"] != "passed" or not result["drainsFinished"]
                or not result["runtimeIntentSettled"] or not result["platformProbeCompleted"]):
            raise ValueError("Actual worker result failed")
        intent, history = read_json(directory / "runtime-intent.json"), read_json(directory / "runtime.json")
        if (intent["state"] != "settled" or intent["sessionID"] != history["sessionID"]
                or intent["sessionID"] != record["sessionID"] or history["snapshot"]["outcome"] != "forcedStopped"):
            raise ValueError("Final recorded evidence did not match the same session")
        deadline = time.monotonic() + 10
        while True:
            try:
                final_probe = writer_probe(directory, False)
                break
            except ValueError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
        phases.append("terminal-drains-history-intent-settled-final-writer-available")
        save(directory / "worker-client-loss-result.json", {
            "schemaVersion": 1, "status": "passed", "scope": "fresh-original-diskless-worker-client-loss",
            "phases": phases, "sameSession": True, "lockIdentityPreserved": True,
            "writerProbeAfterSettlement": final_probe, "workerResult": result,
            "cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest(),
            "harnessSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "hardWorkerLossVerified": False, "windowsCompatibilityVerified": False,
            "guestCleanShutdownVerified": False})
    finally:
        if parent.poll() is None:
            parent.kill()  # This exact registered disposable client only.
            parent.wait(timeout=10)
        if record is None and (directory / "swift-worker-ready.json").exists():
            try:
                record = route(directory)
            except (OSError, ValueError, json.JSONDecodeError):
                pass  # Unsafe/incomplete route cannot authorize any cleanup.
        if record is not None and not stopped:
            # Explicit cleanup of this new diskless trial uses its live authenticated
            # same-session IPC. Stored/orphan PIDs never authorize child signaling.
            try:
                client = Client(record)
                try:
                    observed = client.request()
                    if observed["backendActive"] and not observed["operationPending"]:
                        client.request(3, observed["revision"])
                finally:
                    client.close()
            except (OSError, ValueError, TimeoutError):
                pass  # Preserve uncertainty/intent and the actual independent worker.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--internal-client-parent", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("SKIP: requires the named Apple-silicon macOS native worker fixture")
    if args.internal_client_parent:
        raise SystemExit(client_parent(args.cli, args.directory))
    if not args.run:
        raise SystemExit("SKIP: explicit --run and a newly prepared pinned no-OS fixture are required")
    run(args.cli, args.directory)
    print("Diskless independent worker client-loss/reconnect trial passed; Windows remains unverified.")


if __name__ == "__main__":
    main()
