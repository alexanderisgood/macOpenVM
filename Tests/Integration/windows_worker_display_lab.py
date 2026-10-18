#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Approved new offline installer worker/display owner; GUI actions are separate.

Retains the actual worker until its correlated owner confirms stop and is reaped.
A display-client disconnect never implies runtime termination.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import sys
import time
import uuid

from runtime_worker_lab import ROOT, read_json, save
from rfb_observer_lab import private_log, status, force_owned_runtime, retain_until_reaped
from windows_efi_probe import checked_directory
from windows_installer_boot import ppm_to_png


def read_route(fixture):
    value = read_json(fixture / "swift-worker-ready.json")
    inputs = read_json(fixture / "swift-runtime-input.json", 65536)
    if (set(value) != {"schemaVersion", "scope", "vmID", "sessionID", "socket"}
            or value["schemaVersion"] != 1 or value["scope"] != "approved-windows-installer-worker-route"
            or value["socket"] != str(Path(inputs["qmpSocket"]).parent / "worker.sock")):
        raise ValueError("Unexpected installer worker route")
    uuid.UUID(value["vmID"])
    uuid.UUID(value["sessionID"])
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--approved-checksum-discrepancy", action="store_true")
    parser.add_argument("--approved-installation", action="store_true",
                        help="Retain the owned fresh installation until an explicit stop")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    if not args.run or not args.approved_checksum_discrepancy:
        raise SystemExit("SKIP: explicit approved installer trial required")
    fixture, cli = args.fixture, args.cli
    if (fixture.parent != ROOT / ".lab" or not re.fullmatch(r"windows-installer-boot-[0-9a-f]{32}", fixture.name)
            or not cli.is_relative_to(ROOT / ".lab") or cli != Path(os.path.abspath(cli))):
        raise ValueError("Select only a new installer fixture and private CLI")
    checked_directory(fixture, ROOT, private=True)
    checked_directory(cli.parent, ROOT, private=True)
    info = cli.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o222:
        raise ValueError("Private CLI must be an owned immutable executable copy")
    if any((fixture / name).exists() for name in ("swift-runtime.claim", "runtime-intent.json", "swift-worker-ready.json")):
        raise ValueError("Never reuse a claimed fixture")
    prepared = read_json(fixture / "result.json")
    if prepared != {"status": "prepared", "preparedOnly": True, "nativeChildrenLaunched": False,
                    "windowsCompatibilityVerified": False}:
        raise ValueError("Fixture is not newly prepared")
    if args.approved_installation:
        recipe = read_json(fixture / "recipe.json", 65536)
        if recipe.get("licenseAcceptanceAuthorized") is not True:
            raise ValueError("Fresh installation requires its recorded human authorization")
    os.umask(0o077)
    evidence = {"scope": "approved-offline-installer-worker-display-trial", "cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest(),
                "installationAuthorized": args.approved_installation,
                "licenseAccepted": None if args.approved_installation else False,
                "windowsInstalled": None if args.approved_installation else False,
                "visibleWindowVerified": False}
    save(fixture / "managed-runner-source.json", {"sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
    worker = record = None
    failure = None
    try:
        with private_log(fixture / "managed-worker-stdout.log") as output, private_log(fixture / "managed-worker-stderr.log") as errors:
            command = "qemu-windows-installation-worker-lab" if args.approved_installation else "qemu-windows-installer-worker-lab"
            worker = subprocess.Popen([str(cli), command, "--directory", str(fixture)],
                                      stdin=subprocess.DEVNULL, stdout=output, stderr=errors, cwd=fixture, close_fds=True)
            save(fixture / "managed-worker-start.json", {"pid": worker.pid, "scope": "actual-parent-owned-worker-handle"})
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if worker.poll() is not None:
                    raise ValueError("Worker exited before display readiness")
                if (fixture / "swift-display-ready.json").exists():
                    record = read_route(fixture)
                    evidence["initialStatus"] = status(record)
                    break
                time.sleep(0.03)
            else:
                raise TimeoutError("Display route deadline expired")
            with private_log(fixture / "installer-observer-stdout.log") as out, private_log(fixture / "installer-observer-stderr.log") as err:
                observer = subprocess.Popen([str(cli), "qemu-windows-installer-observer-lab", "--directory", str(fixture)],
                                            stdin=subprocess.DEVNULL, stdout=out, stderr=err, cwd=fixture, close_fds=True)
                try:
                    evidence["observerExit"] = observer.wait(timeout=90)
                finally:
                    if observer.poll() is None:
                        observer.terminate()
                    retain_until_reaped(observer)
                if observer.returncode != 0:
                    raise ValueError("Native installer display observation failed")
            evidence["frame"] = ppm_to_png(fixture / "swift-installer-frame.ppm", fixture / "swift-installer-frame.png")
            evidence["afterObserverStatus"] = status(record)
            print("READY " + str(fixture / "swift-installer-frame.png") + "\nCommands: status | stop", flush=True)
            deadline = None if args.approved_installation else time.monotonic() + 900
            input_open = True
            while deadline is None or time.monotonic() < deadline:
                if worker.poll() is not None:
                    if args.approved_installation and worker.returncode == 0:
                        break
                    raise ValueError("Worker exited during display observation")
                readable, _, _ = select.select([sys.stdin] if input_open else [], [], [], 1)
                if not readable:
                    continue
                line = sys.stdin.readline()
                if not line and args.approved_installation:
                    # Losing terminal input cannot force an installation off.
                    # Keep the actual process owner and wait for external stop.
                    input_open = False
                    continue
                if not line or line.strip() == "stop":
                    break
                if line.strip() == "status":
                    print(status(record), flush=True)
    except Exception as error:
        failure = type(error).__name__ + ": " + str(error)[:200]
    finally:
        if worker is not None:
            try:
                if worker.poll() is None:
                    if record is None and (fixture / "swift-worker-ready.json").exists():
                        record = read_route(fixture)
                    if record is not None:
                        evidence["cleanupStatus"] = force_owned_runtime(record)
            except Exception as error:
                failure = failure or type(error).__name__
                print("Actual worker handle retained; live-owner recovery required.", flush=True)
            finally:
                retain_until_reaped(worker)
            evidence["workerExit"] = worker.returncode
        evidence["failure"] = failure
        evidence["blankDiskAllocatedBytes"] = (fixture / "blank-nvme.raw").stat().st_blocks * 512
        save(fixture / "managed-installer-display-result.json", evidence)
        print(evidence, flush=True)
    return 0 if failure is None and worker is not None and worker.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
