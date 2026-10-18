#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit approved same-VM continuation owner; never prepares a new Windows disk.

No implicit shutdown, quit, signal, force cleanup or replay. Once launched, the actual
worker handle is retained until reaped, including after client/terminal input loss.
The native runtime remains experimental; process exit does not prove guest cleanliness.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time
import uuid

import windows_network_continuation_lab as gate
from rfb_observer_lab import private_log, retain_until_reaped
from runtime_worker_lab import Client, read_json, save

PLAN_SHA = "15ddb48ed4b2153957f48fc21ebadcd324800c40ef894f5e27c1417c3fb2ab12"


def rebound_input(input_value, short):
    if not re.fullmatch(r"/private/tmp/mvo-win-net-[0-9a-f]{16}", str(short)):
        raise ValueError("Fresh bounded continuation socket directory required")
    value = copy.deepcopy(input_value)
    previous = str(Path(value["qmpSocket"]).parent)
    for field in ("qemuArgv", "swtpmArgv"):
        value[field] = [row.replace(previous, str(short)) for row in value[field]]
    value["qmpSocket"] = str(short / "qmp.sock")
    value["tpmSocket"] = str(short / "tpm.sock")
    value["environment"]["TMPDIR"] = str(short)
    return value


def worker_command(cli, fixture, args, run):
    return [str(cli), "qemu-windows-network-continuation-worker-lab", "--directory", str(fixture),
            "--plan", str(args.plan), "--approval", str(args.approval), "--terminal", str(args.terminal),
            "--shutdown-record", str(args.shutdown_record), "--run-directory", str(run)]


def route(run, plan, worker):
    value = read_json(run / "swift-worker-ready.json")
    input_value = read_json(run / "input.json", 65536)
    if (set(value) != {"schemaVersion", "scope", "vmID", "sessionID", "socket"}
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or value["scope"] != "approved-windows-network-continuation-worker-route"
            or value["vmID"] != plan["vmID"] or value["sessionID"] == plan["previousSessionID"]
            or value["socket"] != str(Path(input_value["qmpSocket"]).parent / "worker.sock")
            or worker.poll() is not None):
        raise ValueError("New actual continuation owner route did not match")
    uuid.UUID(value["sessionID"])
    return value


def status(value):
    client = Client(value)
    try:
        return client.request()
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--approval", type=Path, required=True)
    parser.add_argument("--terminal", type=Path, required=True)
    parser.add_argument("--shutdown-record", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        raise SystemExit("SKIP: explicit approved continuation required")
    args.check = True
    plan = gate.check(args)  # Includes explicit approval, prior terminal evidence and available lease.
    if gate.sha(args.plan) != PLAN_SHA:
        raise ValueError("Only the exact reviewed same-VM plan is supported")
    cli = args.cli
    gate.plain(cli.parent, directory=True, mode=0o700)
    gate.plain(cli, mode=0o500)
    if (cli.parent.parent != gate.ROOT / ".lab" or cli.name != "macopenvm"
            or not re.fullmatch(r"linux-desktop-artifacts-[0-9a-f]{32}", cli.parent.name)):
        raise ValueError("Select an isolated private CLI build")
    _, build = gate.read(cli.parent / "build-record.json", 131072)
    if build.get("cliSHA256") != gate.sha(cli) or build.get("primaryApplicationChanged") is not False:
        raise ValueError("Private CLI build hash did not match")
    os.umask(0o077)
    token = uuid.uuid4().hex
    run = args.plan.parent / ("run-" + token)
    short = Path("/private/tmp") / ("mvo-win-net-" + token[:16])
    run.mkdir(mode=0o700)
    short.mkdir(mode=0o700)
    save(run / "input.json", rebound_input(plan["proposedInput"], short))
    save(run / "runner-source.json", {"sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                      "planSHA256": PLAN_SHA, "cliSHA256": build["cliSHA256"]})
    worker = None
    failure = None
    record = None
    try:
        with private_log(run / "owner-stdout.log") as output, private_log(run / "owner-stderr.log") as errors:
            worker = subprocess.Popen(worker_command(cli, Path(plan["directory"]), args, run),
                                      stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                      cwd=run, close_fds=True)
            save(run / "actual-worker-start.json", {"pid": worker.pid, "scope": "actual-parent-owned-worker-handle"})
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if worker.poll() is not None:
                    raise ValueError("Continuation worker exited before readiness")
                if (run / "swift-display-ready.json").exists():
                    record = route(run, plan, worker)
                    observed = status(record)
                    if (observed["state"] == 2 and observed["backendActive"] and not observed["operationPending"]
                            and observed["ownership"] == 0 and observed["error"] == 0):
                        break
                    if observed["state"] == 10 or observed["ownership"] != 0:
                        raise ValueError("Continuation worker needs retained owner recovery")
                time.sleep(0.05)
            else:
                raise TimeoutError("Continuation readiness deadline; actual owner remains retained")
            print("READY " + str(run) + "\nCommands: status (shutdown/input handled separately)", flush=True)
            input_open = True
            while worker.poll() is None:
                readable, _, _ = select.select([sys.stdin] if input_open else [], [], [], 1)
                if not readable:
                    continue
                line = sys.stdin.readline()
                if not line:
                    input_open = False
                elif line.strip() == "status":
                    print(json.dumps(status(record), sort_keys=True), flush=True)
    except BaseException as error:
        failure = type(error).__name__
        if worker is not None and worker.poll() is None:
            print("Actual continuation owner retained; no implicit stop or signal was requested.", flush=True)
    finally:
        if worker is not None:
            retain_until_reaped(worker)
            result = {"scope": "actual-parent-owned-continuation-terminal", "vmID": plan["vmID"],
                      "workerExit": worker.returncode, "actualWorkerReaped": True, "failureKind": failure,
                      "guestCleanShutdownClaimed": False, "forceStopUsed": False}
            if record is not None:
                result["sessionID"] = record["sessionID"]
            save(run / "runner-terminal.json", result)
            print(json.dumps(result, sort_keys=True), flush=True)
    return 0 if failure is None and worker is not None and worker.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
