#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit single-child lease survival after hard loss of its registered lab worker."""
import argparse
import os
from pathlib import Path
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid

from runtime_worker_lab import ROOT, bounded_serial, read_json, save, selected_fixture, wait_record, writer_probe
from runtime_worker_loss_lab import (PrivateQMP, bounded_hash, process_identity, protected_pins, same_uid,
                                    socket_identity, strict_platform_observation, unused_socket_directory)
from windows_efi_probe import ProbeFailure


class PrivateTPM:
    """Only public capability/shutdown control messages; no guest TPM state operations.

    swtpm v0.10.2 include/swtpm/tpm_ioctl.h: BE CMD_GET_CAPABILITY1 and
    CMD_SHUTDOWN3. ctrlchannel.c returns result+caps8 and shutdown result4.
    """
    def __init__(self, path, expected_identity):
        self.path = path
        self.identity = socket_identity(path)
        if self.identity != expected_identity:
            raise ValueError("TPM differs from the observed survivor endpoint")
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connection.settimeout(3)
        try:
            self.connection.connect(str(path))
            same_uid(self.connection)
            if socket_identity(path) != self.identity:
                raise ValueError("TPM endpoint changed during connection")
        except BaseException:
            self.close()
            raise

    def close(self):
        self.connection.close()

    def command(self, command):
        if command not in (1, 3):
            raise ValueError("Only public capability/shutdown commands belong to this trial")
        if socket_identity(self.path) != self.identity:
            raise ValueError("TPM endpoint changed before control command")
        deadline = time.monotonic() + 3
        self.connection.settimeout(max(0.001, deadline - time.monotonic()))
        self.connection.sendall(struct.pack(">I", command))
        size = 8 if command == 1 else 4
        response = bytearray()
        while len(response) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Public TPM control exchange exceeded its deadline")
            self.connection.settimeout(remaining)
            chunk = self.connection.recv(size - len(response))
            if not chunk:
                raise ValueError("Public TPM peer closed before its bounded response")
            response.extend(chunk)
        if time.monotonic() >= deadline or struct.unpack(">I", response[:4])[0] != 0:
            raise ValueError("Public TPM control reply was late or unsuccessful")
        if command == 1:
            capabilities = struct.unpack(">I", response[4:])[0]
            if not capabilities & 2:
                raise ValueError("Actual TPM peer does not advertise public shutdown")
            return capabilities
        return 0


def ready_record(directory, worker, first_exit, inputs, parent_identity):
    value = read_json(directory / "swift-survivor-ready.json", 4096)
    required = {"schemaVersion", "scope", "vmID", "sessionID", "firstExit", "workerPID",
                "survivorKind", "survivorPID", "firstChildExit", "lockIdentity", "survivorSocket",
                "holdSeconds", "historyOutcome"}
    survivor = "tpm" if first_exit == "qemu" else "qemu"
    if (set(value) != required or value["schemaVersion"] != 1
            or value["scope"] != "original-diskless-single-survivor-worker"
            or value["firstExit"] != first_exit or value["workerPID"] != worker.pid
            or value["survivorKind"] != survivor or value["holdSeconds"] != 60
            or value["historyOutcome"] != "failed"):
        raise ValueError("Unexpected bounded single-survivor ready record")
    uuid.UUID(value["vmID"])
    uuid.UUID(value["sessionID"])
    first = value["firstChildExit"]
    if (set(first) != {"status", "wasSignalled", "drainsFinished"} or type(first["status"]) is not int
            or first["drainsFinished"] is not True
            or first["status"] != (signal.SIGKILL if first_exit == "qemu" else 0)
            or first["wasSignalled"] is not (first_exit == "qemu")):
        raise ValueError("Actual selected first-child terminal/drain evidence did not match")
    endpoint = value["survivorSocket"]
    if set(endpoint) != {"path", "parentDevice", "parentInode", "device", "inode", "ownerMode"}:
        raise ValueError("Unexpected survivor endpoint shape")
    path = Path(inputs["tpmSocket"] if survivor == "tpm" else inputs["qmpSocket"])
    expected = tuple(endpoint[key] for key in ("parentDevice", "parentInode", "device", "inode"))
    if (endpoint["path"] != str(path) or expected[:2] != parent_identity
            or endpoint["ownerMode"] not in (0o600, 0o700) or socket_identity(path) != expected):
        raise ValueError("Survivor endpoint differs from the original captured node")
    return value, path, expected


def observe_survivor(record, expected=None):
    pid = record["survivorPID"]
    if type(pid) is not int or pid <= 1:
        raise ValueError("Survivor identity is invalid")
    current = process_identity(pid)
    command = "swtpm" if record["survivorKind"] == "tpm" else "qemu-system-aarch64"
    if current["command"] != command or current["sessionID"] != record["workerPID"]:
        raise ValueError("The actual survivor identity/session is unavailable")
    if expected is None:
        if current["parentPID"] != record["workerPID"]:
            raise ValueError("The ready survivor is not this worker's direct child")
    else:
        for key in ("pid", "command", "started", "sessionID"):
            if current[key] != expected[key]:
                raise ValueError("Survivor identity changed after worker loss")
    return current


def survivor_control(kind, path, identity, records, cleanup=False):
    if kind == "qemu":
        monitor = PrivateQMP(path, records, identity)
        try:
            status = monitor.execute("query-status", 2)
            if status.get("running") is not False or status.get("status") != "paused":
                raise ValueError("QEMU survivor did not remain paused")
            if cleanup:
                monitor.execute("quit", 3)
            return {"status": "paused", "running": False}
        finally:
            monitor.close()
    peer = PrivateTPM(path, identity)
    try:
        capabilities = peer.command(1)
        if cleanup:
            peer.command(3)
        return {"publicCapabilities": capabilities, "guestRuntimeActive": False}
    finally:
        peer.close()


def run(cli, directory, first_exit):
    if first_exit not in ("qemu", "tpm"):
        raise ValueError("Select the fixed qemu or tpm first exit")
    selected_fixture(directory)
    if (directory / "swift-runtime.claim").exists():
        raise ValueError("The original fixture was already claimed")
    metadata = cli.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or not os.access(cli, os.X_OK):
        raise ValueError("Select the actual owned signed CLI artifact")
    inputs = read_json(directory / "swift-runtime-input.json", 65536)
    if (inputs.get("scope") != "new-owned-offline-no-os-fixture" or inputs.get("guestLaunched") is not False
            or inputs.get("windowsCompatibilityVerified") is not False):
        raise ValueError("Only the original fresh diskless fixture is admitted")
    recipe = read_json(directory / "recipe.json", 65536)
    pins = protected_pins(directory, recipe)
    parent_identity = unused_socket_directory(inputs)
    worker = None
    record = None
    path = None
    identity = None
    cleanup_requested = False
    qmp_records = []
    phases = []
    result = {"schemaVersion": 1, "status": "failed", "firstExit": first_exit,
              "scope": "fresh-original-single-survivor-hard-worker-loss",
              "survivorTerminalStatusObserved": False, "survivorEOFAndDrainsObserved": False,
              "runtimeIntentSettled": False, "cooperatingAdmissionVerified": False,
              "cooperatingAdmissionStatus": "pending-independent-Storage-test",
              "windowsCompatibilityVerified": False, "guestCleanShutdownVerified": False}
    try:
        descriptors = []
        try:
            for name in ("survivor-worker-stdout.log", "survivor-worker-stderr.log"):
                descriptors.append(os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                           | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600))
            worker = subprocess.Popen([str(cli), "qemu-survivor-worker-lab", "--directory", str(directory),
                                       "--first-exit", first_exit], stdin=subprocess.DEVNULL,
                                      stdout=descriptors[0], stderr=descriptors[1], close_fds=True, cwd=ROOT)
        finally:
            for fd in descriptors:
                os.close(fd)
        wait_record(directory / "swift-survivor-ready.json", seconds=90)
        if worker.poll() is not None or os.getsid(worker.pid) != worker.pid:
            raise ValueError("Actual lab worker ended before the intended loss step")
        record, path, identity = ready_record(directory, worker, first_exit, inputs, parent_identity)
        if (directory / "swift-survivor-cleanup-started.json").exists():
            raise ValueError("Preauthorized worker fallback cleanup fired before hard loss")
        observation = strict_platform_observation(bounded_serial(directory / "swift-qemu-stdout.log"))
        if observation is None:
            raise ValueError("Unique original EFI completion is absent")
        before_child = observe_survivor(record)
        before = writer_probe(directory, True)
        if {"device": before["device"], "inode": before["inode"]} != record["lockIdentity"]:
            raise ValueError("Ready record did not bind the actual same writer inode")
        intent, history = read_json(directory / "runtime-intent.json"), read_json(directory / "runtime.json")
        snapshot = history.get("snapshot", {})
        if (intent.get("state") != "unsettled" or intent.get("vmID") != record["vmID"]
                or intent.get("sessionID") != record["sessionID"]
                or history.get("sessionID") != record["sessionID"]
                or snapshot.get("state") != "failed" or snapshot.get("outcome") != "failed"
                or snapshot.get("backendActive") is not True):
            raise ValueError("Actual partial-failure intent/history was not honest and unsettled")
        hashes = {name: bounded_hash(directory / name, 4096)
                  for name in ("runtime-intent.json", "runtime.json")}
        pre_control = survivor_control(record["survivorKind"], path, identity, qmp_records)
        phases.append("actual-first-child-terminal-drained-survivor-live-failed-active-history-writer-busy")
        if worker.poll() is not None or (directory / "swift-survivor-cleanup-started.json").exists():
            raise ValueError("Lab fallback/exit preceded intended hard worker loss")
        worker.kill()  # Only this exact registered worker; observation PIDs never authorize signals.
        if worker.wait(timeout=10) != -signal.SIGKILL:
            raise ValueError("Actual owned worker SIGKILL status was not observed")
        if (directory / "swift-survivor-cleanup-started.json").exists():
            raise ValueError("Lab fallback started before the worker died")
        after_child = observe_survivor(record, before_child)
        after = writer_probe(directory, True)
        if before != after:
            raise ValueError("Single survivor did not retain the same kernel writer")
        post_control = survivor_control(record["survivorKind"], path, identity, qmp_records)
        observe_survivor(record, before_child)
        phases.append("owned-worker-sigkill-exact-single-survivor-live-public-control-same-inode-busy")
        cleanup_requested = True
        survivor_control(record["survivorKind"], path, identity, qmp_records, cleanup=True)
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
        for name, expected in hashes.items():
            if bounded_hash(directory / name, 4096) != expected:
                raise ValueError("Interrupted intent or failed active history was changed")
        if protected_pins(directory, recipe) != pins:
            raise ValueError("Original readonly fixture assets changed")
        if (directory / "swift-survivor-result.json").exists():
            raise ValueError("A killed worker unexpectedly published fallback completion")
        phases.append("public-survivor-cleanup-same-inode-available-unsettled-failed-history-unchanged")
        result.update(status="passed", hardWorkerLossVerified=True, survivorKind=record["survivorKind"],
                      sameSession=True, firstChildExitBeforeWorkerLoss=record["firstChildExit"],
                      workerExit=-signal.SIGKILL, survivorBeforeLoss=before_child, survivorAfterLoss=after_child,
                      writerBeforeLoss=before, writerAfterLoss=after, writerAfterPublicCleanup=final,
                      preLossPublicControl=pre_control, postLossPublicControl=post_control,
                      interruptedRecordHashes=hashes, survivorSocketIdentity=identity,
                      originalEFIObservation=observation, readonlyPins=pins, qmpRecords=qmp_records)
    except BaseException as error:
        result["failure"] = type(error).__name__ + ": " + str(error)[:256]
        raise
    finally:
        if worker is not None and worker.poll() is not None and record is not None and not cleanup_requested:
            try:
                survivor_control(record["survivorKind"], path, identity, qmp_records, cleanup=True)
            except (OSError, ValueError, TimeoutError, ProbeFailure):
                result["cleanupLimitation"] = "Captured public survivor cleanup unavailable; preserve intent."
        elif worker is not None and worker.poll() is None:
            result["cleanupLimitation"] = "Exact live lab worker retains custody for its preauthorized 60s fallback."
        result["phases"] = phases
        result["cliSHA256"] = bounded_hash(cli, 67108864)
        result["harnessSHA256"] = bounded_hash(Path(__file__), 1048576)
        save(directory / "worker-single-survivor-loss-result.json", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--first-exit", choices=("qemu", "tpm"), required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or not args.run:
        raise SystemExit("SKIP: explicit --run and a new original diskless macOS fixture are required")
    run(args.cli, args.directory, args.first_exit)
    print("Single-survivor physical worker-loss proof passed; Storage admission remains a separate check.")


if __name__ == "__main__":
    main()
