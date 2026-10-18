#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit original diskless RFB trial; no installed OS or visible-window claim.

The parent retains and reaps its actual worker Popen. Only that newly selected
fixture's live, correlated IPC owner receives the explicit force-stop cleanup.
Observer errors do not imply child exit or authorize signaling stored PIDs.
"""
import argparse
import hashlib
import os
from pathlib import Path
import resource
import stat
import subprocess
import time

from runtime_worker_lab import Client, ROOT, read_json, route, save, selected_fixture


def private_log(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    return os.fdopen(fd, "wb")


def retain_until_reaped(worker):
    while True:
        try:
            worker.wait(timeout=30)
            return
        except (subprocess.TimeoutExpired, KeyboardInterrupt, OSError):
            # A terminal/signal or polling failure does not establish child exit.
            try:
                time.sleep(0.1)
            except KeyboardInterrupt:
                pass


def wait_route(fixture, worker, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if (fixture / "swift-worker-ready.json").exists():
            return route(fixture)
        if worker.poll() is not None:
            raise ValueError("Owned worker exited before its route was available")
        time.sleep(0.05)
    raise TimeoutError("Worker route deadline expired; no PID signaling is inferred")


def status(record):
    peer = Client(record)
    try:
        return peer.request()
    finally:
        peer.close()


def wait_display(fixture, worker, record, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = status(record)
        if value["backendActive"] and value["state"] == 2 and not value["operationPending"]:
            if (fixture / "swift-display-ready.json").exists():
                read_json(fixture / "swift-display-ready.json")
                return value
        if worker.poll() is not None or value["state"] == 10:
            raise ValueError("The original display worker failed before readiness")
        time.sleep(0.05)
    raise TimeoutError("The original display worker did not become ready")


def force_owned_runtime(record):
    # This --run harness expressly authorizes ending its NEW diskless test runtime.
    # One fresh status and one correlated mutation; never replay a failed command.
    peer = Client(record)
    try:
        before = peer.request()
        if before["ownership"] == 2:
            return before
        if before["ownership"] != 0 or before["operationPending"]:
            raise ValueError("Runtime cleanup requires retained live owner attention")
        result = peer.request(3, before["revision"])
        if result["backendActive"] or result["ownership"] != 2 or result["error"]:
            raise ValueError("The runtime did not confirm owned quiescence and settlement")
        return result
    finally:
        peer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        raise SystemExit("SKIP: requires --run, a newly prepared display fixture and private signed CLI.")
    selected_fixture(args.fixture)
    prepared = read_json(args.fixture / "result.json", 32768)
    inputs = read_json(args.fixture / "swift-runtime-input.json", 65536)
    if (prepared.get("status") != "prepared" or prepared.get("preparedOnly") is not True
            or prepared.get("nativeChildrenLaunched") is not False
            or inputs.get("scope") != "new-owned-offline-no-os-display-fixture"):
        raise ValueError("Select only a newly prepared original no-OS display fixture")
    if any((args.fixture / name).exists() for name in (
            "swift-runtime.claim", "runtime-intent.json", "swift-worker-ready.json")):
        raise ValueError("The display fixture was already claimed; never reuse it")
    cli = args.cli
    if (not cli.is_absolute() or cli != Path(os.path.abspath(cli))
            or not cli.is_relative_to(ROOT / ".lab")):
        raise ValueError("Use a normalized executable in this project's private artifact directory")
    ancestor = Path("/")
    for component in cli.parent.parts[1:]:
        ancestor /= component
        metadata = ancestor.lstat()
        if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid not in (0, os.getuid())
                or metadata.st_mode & 0o022):
            raise ValueError("Private executable ancestry is unsafe")
    selected = cli.lstat()
    if (not stat.S_ISREG(selected.st_mode) or selected.st_uid != os.getuid()
            or selected.st_nlink != 1 or selected.st_mode & 0o022
            or selected.st_size > 134217728 or not os.access(cli, os.X_OK)):
        raise ValueError("The private CLI executable has unsafe metadata")
    cli_hash = hashlib.sha256(cli.read_bytes()).hexdigest()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    previous_mask = os.umask(0o077)
    worker = None
    record = None
    observer_exit = None
    failure = None
    evidence = {"schemaVersion": 1, "scope": "new-original-diskless-headless-rfb-trial",
                "cliSHA256": cli_hash, "windowsCompatibilityVerified": False,
                "nativeVisibleWindowVerified": False, "retinaVerified": False}
    try:
        with private_log(args.fixture / "managed-worker-stdout.log") as output, \
                private_log(args.fixture / "managed-worker-stderr.log") as errors:
            worker = subprocess.Popen(
                [str(cli), "qemu-display-worker-lab", "--directory", str(args.fixture)],
                stdin=subprocess.DEVNULL, stdout=output, stderr=errors, cwd=args.fixture,
                close_fds=True)
            save(args.fixture / "managed-worker-start.json", {"pid": worker.pid,
                 "scope": "actual-parent-owned-worker-handle", "cliSHA256": cli_hash})
            record = wait_route(args.fixture, worker)
            evidence["initialStatus"] = wait_display(args.fixture, worker, record)
            with private_log(args.fixture / "observer-stdout.log") as observed, \
                    private_log(args.fixture / "observer-stderr.log") as observer_errors:
                observer = subprocess.Popen(
                    [str(cli), "qemu-rfb-observer-lab", "--directory", str(args.fixture)],
                    stdin=subprocess.DEVNULL, stdout=observed, stderr=observer_errors,
                    cwd=args.fixture, close_fds=True)
                try:
                    observer_exit = observer.wait(timeout=90)
                except subprocess.TimeoutExpired:
                    # Only this observer is signaled; it has no runtime custody.
                    observer.terminate()
                    observer_exit = observer.wait(timeout=10)
                    raise TimeoutError("The registered RFB observer exceeded its deadline")
                finally:
                    try:
                        if observer.poll() is None:
                            # This exact registered observer has no VM processes,
                            # writer lease or runtime-control operation to abandon.
                            observer.kill()
                    finally:
                        retain_until_reaped(observer)
                        observer_exit = observer.returncode
            evidence["observerExit"] = observer_exit
            if observer_exit != 0:
                raise ValueError("The native RFB observer did not pass")
            evidence["afterObserverStatus"] = status(record)
            after = evidence["afterObserverStatus"]
            if (after["state"] != 2 or not after["backendActive"] or after["ownership"] != 0
                    or after["operationPending"] or after["error"]):
                raise ValueError("Observer detach did not preserve the live unsettled runtime")
    except Exception as error:
        failure = type(error).__name__
    finally:
        if worker is not None:
            try:
                if worker.poll() is None:
                    if record is None and (args.fixture / "swift-worker-ready.json").exists():
                        record = route(args.fixture)
                    if record is not None:
                        evidence["cleanupStatus"] = force_owned_runtime(record)
            except Exception as error:
                evidence["cleanupFailure"] = type(error).__name__
                failure = failure or type(error).__name__
                try:
                    print("Owned runtime remains retained; awaiting explicit live-owner recovery.", flush=True)
                except OSError:
                    pass
            finally:
                # Keep the actual parent handle alive even after a diagnostic or
                # route-recovery failure. A timeout never establishes child exit.
                retain_until_reaped(worker)
            evidence["workerExit"] = worker.returncode
        os.umask(previous_mask)
    if worker is not None and worker.returncode == 0:
        evidence["workerResult"] = read_json(args.fixture / "swift-worker-result.json", 32768)
    evidence["status"] = "passed" if failure is None and worker is not None and worker.returncode == 0 else "failed"
    if failure is not None:
        evidence["failureClass"] = failure
    save(args.fixture / "managed-rfb-trial.json", evidence)
    print("Original diskless RFB trial: " + evidence["status"], flush=True)
    return 0 if evidence["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
