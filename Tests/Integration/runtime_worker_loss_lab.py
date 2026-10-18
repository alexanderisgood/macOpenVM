#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit hard loss of an owned worker for one fresh paused diskless EFI trial."""
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import time

from runtime_worker_lab import (Client, ROOT, bounded_serial, read_json, route, save,
                                selected_fixture, wait_record, wait_running, writer_probe)
from windows_efi_probe import ANSI_CSI, QMP, ProbeFailure, probe_observation


class EndpointFailure(ValueError):
    def __init__(self, message, metadata):
        super().__init__(message)
        self.metadata = metadata


def strict_platform_observation(output):
    if len(output) > 2097152:
        raise ValueError("Original EFI output exceeded its bound")
    clean = ANSI_CSI.sub(b"", output).replace(b"\r", b"")
    clean.decode("utf-8", "strict")
    lines = clean.splitlines()
    if b"mvo.platform-probe.complete setup=1 secure-boot=0" in lines:
        required = (b"mvo.platform-probe.begin version=1", b"mvo.platform-probe.arch=aarch64",
                    b"mvo.platform-probe.setup status=Success value=1",
                    b"mvo.platform-probe.secure-boot status=Success value=0",
                    b"mvo.platform-probe.complete setup=1 secure-boot=0")
        prefixes = (b"mvo.platform-probe.begin ", b"mvo.platform-probe.arch=",
                    b"mvo.platform-probe.setup ", b"mvo.platform-probe.secure-boot ",
                    b"mvo.platform-probe.complete ", b"mvo.platform-probe.tcg2 ",
                    b"mvo.platform-probe.tpm-public-manufacturer=")
        if any(sum(line.startswith(prefix) for line in lines) != 1 for prefix in prefixes):
            raise ValueError("EFI output contains duplicate or contradictory platform rows")
        if any(lines.count(row) != 1 for row in required):
            raise ValueError("EFI completion lacks exact required platform rows")
        patterns = (rb"mvo\.platform-probe\.tcg2 status=Success present=1 active-banks=0x[0-9a-fA-F]{8}",
                    rb"mvo\.platform-probe\.tpm-public-manufacturer=0x[0-9a-fA-F]{8}")
        if any(sum(re.fullmatch(pattern, line) is not None for line in lines) != 1 for pattern in patterns):
            raise ValueError("EFI completion lacks exact public capability rows")
    return probe_observation(output)


def socket_identity(path):
    if not path.is_absolute() or str(path) != os.path.abspath(path) or len(os.fsencode(path)) > 103:
        raise ValueError("Select a normalized bounded Unix endpoint")
    current = Path("/")
    for part in path.parts[1:-1]:
        current /= part
        info = current.lstat()
        root_temporary = current == Path("/private/tmp") and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid())
                or (info.st_mode & 0o022 and not root_temporary)):
            raise ValueError("Unsafe Unix endpoint ancestry")
    parent, endpoint = path.parent.lstat(), path.lstat()
    if (parent.st_uid != os.geteuid() or parent.st_mode & 0o777 != 0o700
            or not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.geteuid()
            or endpoint.st_nlink != 1 or endpoint.st_mode & 0o077
            or endpoint.st_mode & 0o600 != 0o600 or endpoint.st_mode & 0o7000):
        # Darwin unix(4) requires a writable endpoint. QEMU binds normally under
        # the worker's 077 umask, leaving owner0700; the owner execute bit neither
        # grants another user access nor changes this socket into an executable.
        raise EndpointFailure("Unsafe private Unix endpoint", {
            "parentMode": oct(stat.S_IMODE(parent.st_mode)),
            "endpointMode": oct(stat.S_IMODE(endpoint.st_mode)),
            "endpointUID": endpoint.st_uid, "endpointLinks": endpoint.st_nlink,
            "endpointIsSocket": stat.S_ISSOCK(endpoint.st_mode)})
    return (parent.st_dev, parent.st_ino, endpoint.st_dev, endpoint.st_ino)


def same_uid(connection):
    user, group = ctypes.c_uint(), ctypes.c_uint()
    peer = ctypes.CDLL(None, use_errno=True).getpeereid
    peer.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
    peer.restype = ctypes.c_int
    if peer(connection.fileno(), ctypes.byref(user), ctypes.byref(group)) or user.value != os.geteuid():
        raise ValueError("Unexpected private socket peer")


class PrivateQMP(QMP):
    """The original bounded helper, with peer checks before its first greeting read."""
    def __init__(self, path, records, expected_identity=None):
        self.path = path
        self.identity = socket_identity(path)
        if expected_identity is not None and self.identity != expected_identity:
            raise ValueError("QMP differs from the observed pre-loss endpoint")
        self.peer_checked = False
        super().__init__(path, records)

    def receive(self, deadline=None):
        if not self.peer_checked:
            same_uid(self.connection)
            if socket_identity(self.path) != self.identity:
                raise ValueError("QMP endpoint changed during connection")
            self.peer_checked = True
        return super().receive(deadline)

    def execute(self, command, identifier, arguments=None, deadline=None):
        if socket_identity(self.path) != self.identity:
            raise ValueError("QMP endpoint changed before command")
        return super().execute(command, identifier, arguments, deadline)


def bounded_command(argv):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=3, check=False,
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, close_fds=True)
    if len(result.stdout) > 4096 or len(result.stderr) > 4096:
        raise ValueError("Read-only process observation exceeded its bound")
    if result.returncode:
        raise ValueError("Read-only process observation was unavailable")
    return result.stdout.decode("utf-8", "strict")


def process_identity(pid):
    # No command arguments, environment, unfiltered host inventory or child signals.
    line = bounded_command(["/bin/ps", "-ww", "-p", str(pid), "-o", "pid=,ppid=,state=,lstart=,comm="]).strip()
    parts = line.split(maxsplit=8)
    if len(parts) != 9 or int(parts[0]) != pid or any(ch in parts[2] for ch in "ZX"):
        raise ValueError("Expected actual child is absent or no longer live")
    return {"pid": pid, "parentPID": int(parts[1]), "state": parts[2],
            "started": " ".join(parts[3:8]), "command": Path(parts[8]).name,
            "sessionID": os.getsid(pid)}


def direct_children(worker):
    output = bounded_command(["/usr/bin/pgrep", "-P", str(worker.pid)])
    identifiers = output.split()
    if len(identifiers) != 2 or any(not value.isdecimal() for value in identifiers):
        raise ValueError("Worker must have exactly its two directly launched children")
    children = [process_identity(int(value)) for value in identifiers]
    if ({child["command"] for child in children} != {"qemu-system-aarch64", "swtpm"}
            or any(child["parentPID"] != worker.pid or child["sessionID"] != worker.pid for child in children)):
        raise ValueError("Direct child identity/session did not match the original pair")
    return children


def surviving_children(before):
    result = []
    for child in before:
        current = process_identity(child["pid"])
        for field in ("pid", "command", "started", "sessionID"):
            if current[field] != child[field]:
                raise ValueError("An actual child identity changed after worker loss")
        result.append(current)
    return result


def bounded_hash(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
                or before.st_nlink != 1 or before.st_size > limit):
            raise ValueError("Unsafe bounded owned evidence file")
        digest = hashlib.sha256()
        for _ in range((limit // 1048576) + 1):
            chunk = source.read(1048576)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(source.fileno())
        current = path.lstat()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("Evidence changed while hashing")
        if (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError("Evidence path identity changed")
    return digest.hexdigest()


def protected_pins(directory, recipe):
    result = {}
    for relative, expected in recipe["stagedReadonly"].items():
        path = Path(relative)
        if path.is_absolute() or any(part in (".", "..") for part in path.parts):
            raise ValueError("Unexpected fixture readonly path")
        full = directory / path
        info = full.lstat()
        if info.st_mode & 0o777 != 0o400 or info.st_size != expected["bytes"]:
            raise ValueError("Readonly fixture identity/size changed")
        actual = bounded_hash(full, 134217728)
        if actual != expected["sha256"]:
            raise ValueError("Readonly fixture hash changed")
        result[relative] = {"device": info.st_dev, "inode": info.st_ino,
                            "bytes": info.st_size, "sha256": actual}
    return result


def quiesce_public_qmp(path, records, expected_identity=None):
    monitor = PrivateQMP(path, records, expected_identity)
    try:
        monitor.execute("quit", 3)
    finally:
        monitor.close()


def unused_socket_directory(inputs):
    qmp, tpm = Path(inputs["qmpSocket"]), Path(inputs["tpmSocket"])
    parent = qmp.parent
    if (parent.parent != Path("/private/tmp") or not re.fullmatch(r"mvo-efi-[0-9a-f]{16}", parent.name)
            or qmp.name != "qmp.sock" or tpm.name != "tpm.sock" or tpm.parent != parent
            or str(qmp) != os.path.abspath(qmp) or str(tpm) != os.path.abspath(tpm)
            or len(os.fsencode(parent / "worker.sock")) > 103):
        raise ValueError("Only the new short original socket directory is admitted")
    info = parent.lstat()
    root = parent.parent.lstat()
    if (not stat.S_ISDIR(root.st_mode) or root.st_uid != 0 or not root.st_mode & stat.S_ISVTX
            or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_mode & 0o777 != 0o700 or any(parent.iterdir())):
        raise ValueError("The original socket directory must be private, canonical and empty")
    return (info.st_dev, info.st_ino)


def settled_cleanup_result(directory, record):
    """Bounded same-session evidence prevents a second cleanup of a normal exit."""
    if record is None:
        return False
    try:
        result = read_json(directory / "swift-worker-result.json")
        intent = read_json(directory / "runtime-intent.json")
        history = read_json(directory / "runtime.json")
    except (OSError, ValueError):
        return False
    return (result.get("status") == "passed" and result.get("runtimeIntentSettled") is True
            and result.get("drainsFinished") is True and intent.get("state") == "settled"
            and intent.get("vmID") == record["vmID"]
            and intent.get("sessionID") == record["sessionID"]
            and history.get("sessionID") == record["sessionID"])


def run(cli, directory):
    selected_fixture(directory)
    if (directory / "swift-runtime.claim").exists():
        raise ValueError("The original fixture was already claimed")
    info = cli.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or not os.access(cli, os.X_OK):
        raise ValueError("Select the actual owned signed CLI artifact")
    inputs = read_json(directory / "swift-runtime-input.json", 65536)
    if (inputs.get("scope") != "new-owned-offline-no-os-fixture" or inputs.get("guestLaunched") is not False
            or inputs.get("windowsCompatibilityVerified") is not False):
        raise ValueError("Only a fresh original diskless fixture is admitted")
    recipe = read_json(directory / "recipe.json", 65536)
    pins = protected_pins(directory, recipe)
    socket_parent_identity = unused_socket_directory(inputs)
    qmp_path = Path(inputs["qmpSocket"])
    phases, qmp_records = [], []
    worker = None
    worker_killed = False
    cleanup_requested = False
    live_cleanup_confirmed = False
    record = None
    qmp_identity = None
    result = {"schemaVersion": 1, "status": "failed",
              "scope": "fresh-paused-original-diskless-hard-worker-loss",
              "windowsCompatibilityVerified": False, "guestCleanShutdownVerified": False,
              "childTerminalStatusesObserved": False, "childEOFAndDrainsObserved": False,
              "runtimeIntentSettled": False, "cooperatingAdmissionVerified": False,
              "cooperatingAdmissionStatus": "pending-independent-Storage-test"}
    try:
        descriptors = []
        try:
            for name in ("loss-worker-stdout.log", "loss-worker-stderr.log"):
                descriptors.append(os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                           | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600))
            worker = subprocess.Popen([str(cli), "qemu-worker-lab", "--directory", str(directory)],
                                      stdin=subprocess.DEVNULL, stdout=descriptors[0], stderr=descriptors[1],
                                      close_fds=True, cwd=ROOT)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)
        wait_record(directory / "swift-worker-ready.json")
        record = route(directory)
        if worker.poll() is not None or os.getsid(worker.pid) != worker.pid:
            raise ValueError("The directly owned worker did not separate its session")
        wait_running(record)
        deadline = time.monotonic() + 60
        observation = None
        while time.monotonic() < deadline:
            if worker.poll() is not None:
                raise ValueError("The owned worker exited before qualification")
            serial = directory / "swift-qemu-stdout.log"
            if serial.exists():
                observation = strict_platform_observation(bounded_serial(serial))
                if observation is not None:
                    break
            time.sleep(0.05)
        if observation is None:
            raise TimeoutError("Strict original EFI completion was not observed")
        client = Client(record)
        try:
            current = client.request()
            paused = client.request(1, current["revision"])
            if (paused["error"] or paused["state"] != 4 or not paused["backendActive"]
                    or paused["operationPending"] or paused["ownership"] != 0):
                raise ValueError("Actual paused runtime was not observed")
        finally:
            client.close()
        children = direct_children(worker)
        qmp_identity = socket_identity(qmp_path)
        qmp_owner_mode = oct(stat.S_IMODE(qmp_path.lstat().st_mode))
        if qmp_identity[:2] != socket_parent_identity:
            raise ValueError("Original socket parent changed before worker loss")
        before = writer_probe(directory, True)
        intent = read_json(directory / "runtime-intent.json")
        history = read_json(directory / "runtime.json")
        if (intent.get("state") != "unsettled" or intent.get("sessionID") != record["sessionID"]
                or history.get("sessionID") != record["sessionID"]
                or history.get("snapshot", {}).get("outcome") != "pending"):
            raise ValueError("Same-session interrupted intent/history was not pending")
        recorded_hashes = {name: bounded_hash(directory / name, 4096)
                           for name in ("runtime-intent.json", "runtime.json")}
        phases.append("strict-efi-complete-ipc-paused-direct-two-children-same-inode-busy")
        worker.kill()  # Only this exact directly registered Popen child; never stored child PIDs.
        if worker.wait(timeout=10) != -signal.SIGKILL:
            raise ValueError("Owned worker SIGKILL terminal status was not observed")
        worker_killed = True
        survivors = surviving_children(children)
        after = writer_probe(directory, True)
        if after != before:
            raise ValueError("Shared kernel writer identity changed after worker loss")
        monitor = PrivateQMP(qmp_path, qmp_records, qmp_identity)
        try:
            status = monitor.execute("query-status", 2)
            if status.get("running") is not False or status.get("status") != "paused":
                raise ValueError("The actual surviving QEMU did not remain paused")
        finally:
            monitor.close()
        surviving_children(children)
        phases.append("owned-worker-sigkill-both-child-identities-live-qmp-paused-same-inode-busy")
        cleanup_requested = True
        quiesce_public_qmp(qmp_path, qmp_records, qmp_identity)
        deadline = time.monotonic() + 15
        while True:
            try:
                final = writer_probe(directory, False)
                break
            except ValueError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
        if (final["device"], final["inode"]) != (before["device"], before["inode"]):
            raise ValueError("Available writer was a different inode")
        if protected_pins(directory, recipe) != pins:
            raise ValueError("Protected original assets changed")
        for name, expected in recorded_hashes.items():
            if bounded_hash(directory / name, 4096) != expected:
                raise ValueError("Interrupted intent/history was changed or relabeled")
        if (directory / "swift-worker-result.json").exists():
            raise ValueError("A dead worker unexpectedly produced a settled result")
        phases.append("public-qmp-quit-same-inode-available-intent-history-unchanged-unsettled")
        result.update(status="passed", hardWorkerLossVerified=True, workerExit=-signal.SIGKILL,
                      originalEFIObservation=observation, pausedBeforeLoss=paused,
                      childrenBeforeLoss=children, childrenAfterLoss=survivors,
                      writerBeforeLoss=before, writerAfterLoss=after, writerAfterPublicCleanup=final,
                      interruptedRecordHashes=recorded_hashes, readonlyPins=pins,
                      qmpEndpointIdentityBeforeAndAfterLoss=qmp_identity,
                      qmpEndpointOwnerModeBeforeLoss=qmp_owner_mode,
                      sameSession=True, qmpRecords=qmp_records)
    except BaseException as error:
        result["failure"] = type(error).__name__ + ": " + str(error)[:256]
        if isinstance(error, EndpointFailure):
            result["failureSocketMetadata"] = error.metadata
        raise
    finally:
        # Before hard loss, prefer the actual same-session worker's explicit force.
        # After hard loss, only this fresh fixture's checked public QMP can clean up.
        if record is None and worker is not None and (directory / "swift-worker-ready.json").exists():
            try:
                record = route(directory)
            except (OSError, ValueError):
                pass  # An incomplete/unsafe route grants no cleanup authority.
        if worker is not None and not worker_killed and worker.poll() is None and record is not None:
            try:
                client = Client(record)
                try:
                    state = client.request()
                    if state["backendActive"] and not state["operationPending"]:
                        reply = client.request(3, state["revision"])
                        live_cleanup_confirmed = (reply["ownership"] == 2 and not reply["backendActive"]
                                                  and not reply["operationPending"] and reply["error"] == 0)
                finally:
                    client.close()
                worker.wait(timeout=10)
            except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
                result["cleanupLimitation"] = "Owned worker cleanup remains uncertain; preserve custody."
        normal_cleanup = live_cleanup_confirmed or settled_cleanup_result(directory, record)
        if normal_cleanup:
            result["liveWorkerCleanupSettled"] = True
            result["runtimeIntentSettled"] = True
        if (worker is not None and worker.poll() is not None and not cleanup_requested
                and not normal_cleanup):
            try:
                interrupted = read_json(directory / "runtime-intent.json")
                if (record is None or interrupted.get("state") != "unsettled"
                        or interrupted.get("vmID") != record["vmID"]
                        or interrupted.get("sessionID") != record["sessionID"]):
                    raise ValueError("No matching unsettled intent authorizes this fallback")
                quiesce_public_qmp(qmp_path, qmp_records, qmp_identity)
            except (OSError, ValueError, ProbeFailure):
                result["cleanupLimitation"] = "Checked fallback cleanup unavailable; preserve actual intent/state."
        result["phases"] = phases
        result["cliSHA256"] = bounded_hash(cli, 67108864)
        result["harnessSHA256"] = bounded_hash(Path(__file__), 1048576)
        save(directory / "worker-hard-loss-result.json", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or not args.run:
        raise SystemExit("SKIP: explicit --run, named macOS host and a new pinned diskless fixture required")
    run(args.cli, args.directory)
    print("Paused diskless worker-loss physical proof passed; Storage admission test remains separate.")


if __name__ == "__main__":
    main()
