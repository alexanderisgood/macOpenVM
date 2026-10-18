#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""One explicit fresh no-OS SDK sheet test; retained child, no forced cleanup.

The app actuates its ordinary controller, not a mouse/menu/button. Actual native
sheet attachment and dismissal are separately reported. No guest is started.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import build_manifest


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(directory):
    rows = {}
    for path in directory.iterdir():
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600,
                "fresh fixture members must be private regular files")
        row = {"device": info.st_dev, "inode": info.st_ino, "bytes": info.st_size,
               "allocatedBytes": info.st_blocks * 512, "mode": stat.S_IMODE(info.st_mode)}
        if path.name != "disk.raw":
            require(info.st_size <= 262144, "fixture metadata outside bound")
            row["sha256"] = digest(path)
        rows[path.name] = row
    require(not any(name in rows for name in ("runtime.json", "runtime-intent.json", ".runtime")),
            "fixture already has runtime records")
    require(rows["disk.raw"]["allocatedBytes"] == 0, "fixture disk is no longer unused")
    return rows


def save(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def sdk_observation(value):
    fields = {"phase", "passed", "events", "vmID", "sameOwner", "controllerActuation",
              "guestStarted", "networkSaved", "pixelsRead", "idleQuitRequested", "configurationSHA256"}
    require(isinstance(value, dict) and set(value) == fields, "closed SDK result required")
    require(isinstance(value["phase"], str)
            and value["phase"] in {"admission", "owner-window", "library-sheet", "network-route", "cancel", "complete"},
            "known SDK phase required")
    for field in ("passed", "sameOwner", "controllerActuation", "guestStarted", "networkSaved", "pixelsRead", "idleQuitRequested"):
        require(type(value[field]) is bool, "SDK result booleans required")
    require(isinstance(value["events"], list) and len(value["events"]) <= 5
            and all(isinstance(event, str) and event in {
                "sdk-owner-visible", "sdk-library-attached-to-owner", "sdk-network-sheet-attached-same-owner",
                "sdk-network-sheet-detached-after-controller-cancel", "qualification-refused",
            } for event in value["events"]), "bounded SDK events required")
    require(isinstance(value["vmID"], str) and re.fullmatch(r"[0-9A-F]{8}-(?:[0-9A-F]{4}-){3}[0-9A-F]{12}", value["vmID"])
            and isinstance(value["configurationSHA256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", value["configurationSHA256"]), "SDK correlation/hash required")
    return value


def writer_available(directory, expected):
    descriptor = os.open(directory / "writer.lock", os.O_RDWR | os.O_NOFOLLOW)
    try:
        held = os.fstat(descriptor)
        named = (directory / "writer.lock").lstat()
        require(stat.S_ISREG(held.st_mode) and held.st_uid == os.geteuid() and held.st_nlink == 1
                and stat.S_IMODE(held.st_mode) == 0o600 and held.st_size == expected["bytes"]
                and (held.st_dev, held.st_ino) == (expected["device"], expected["inode"])
                and (named.st_dev, named.st_ino) == (held.st_dev, held.st_ino),
                "exact prepared writer required")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    if not args.run:
        print("SKIP: explicit native SDK test required; no app or guest started")
        return 0
    artifact, directory = args.artifact, args.directory
    require(artifact is not None and artifact.parent == ROOT / ".lab"
            and re.fullmatch(r"linux-desktop-artifacts-[0-9a-f]{32}", artifact.name),
            "choose one qualified private app build")
    require(directory is not None and re.fullmatch(
        r"/private/tmp/mvo-library-network-[0-9a-f]{32}/Library Network\.macopenvm", str(directory)),
        "choose one fresh isolated fixture")
    evidence = directory.parent / "evidence"
    for path in (directory.parent, directory, evidence):
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
                and stat.S_IMODE(info.st_mode) == 0o700, "private plain fixture required")
    build = build_manifest.bounded_json(artifact / "build-record.json")
    require(build["sources"] == build_manifest.source_snapshot(ROOT)
            and build["primaryApplicationChanged"] is False, "current exact build required")
    app = artifact / "macOpenVM.app/Contents/MacOS/macOpenVMNative"
    require(digest(app) == build["appExecutableSHA256"], "native app hash changed")
    before = snapshot(directory)
    prepared = build_manifest.bounded_json(evidence / "prepared.json")
    # Preparation also retains regular-file type facts; match the common fields.
    require(set(prepared["files"]) == set(before), "prepared fixture membership changed")
    for name, row in before.items():
        require(all(prepared["files"][name].get(key) == value for key, value in row.items()),
                "prepared fixture changed")
    require(not (evidence / "sdk-result.json").exists()
            and not (evidence / "native-admission.json").exists(), "fixture was already consumed")
    configuration = build_manifest.bounded_json(directory / "configuration.json")
    require(configuration["id"] == prepared["vmID"] and configuration["network"] == "disconnected"
            and configuration.get("installationMedia") is None
            and configuration.get("supportMedia") is None, "fixture configuration changed")
    writer_available(directory, before["writer.lock"])
    save(evidence / "native-admission.json", {
        "scope": "fresh-no-OS-native-SDK-sheets", "sourceSnapshot": build["sources"],
        "appSHA256": build["appExecutableSHA256"], "before": before,
        "controllerActuation": True, "guestStartAuthorized": False,
    })
    environment = dict(os.environ)
    environment["MVO_LIBRARY_NETWORK_APP_QUALIFICATION"] = "1"
    with (evidence / "app.stdout").open("xb") as stdout, (evidence / "app.stderr").open("xb") as stderr:
        child = subprocess.Popen([
            str(app), "--library-network-app-qualification", "--run", "--directory", str(directory),
            "--expected-vm", prepared["vmID"], "--output-directory", str(evidence),
        ], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, env=environment, close_fds=True)
        print(json.dumps({"scope": "retained-own-native-app", "evidence": str(evidence)}), flush=True)
        last = None
        began = time.monotonic()
        while child.poll() is None:
            result_path = evidence / "sdk-result.json"
            if result_path.exists() and last is None:
                # A file can be visible before fsync/close. Read only a complete
                # bounded JSON observation; failed reads never kill the child.
                try:
                    candidate = sdk_observation(build_manifest.bounded_json(result_path, 4096))
                    last = candidate
                    print(json.dumps({"observedPhase": candidate["phase"],
                                      "sdkPassed": candidate["passed"], "parentStillRetained": True}), flush=True)
                except (ValueError, OSError, json.JSONDecodeError):
                    pass
            if time.monotonic() - began >= 45:
                print(json.dumps({"observationPending": True, "parentStillRetained": True,
                                  "automaticQuitOrSignal": False}), flush=True)
                began = time.monotonic()
            time.sleep(0.1)
        exit_code = child.wait()
    after = snapshot(directory)
    result = sdk_observation(build_manifest.bounded_json(evidence / "sdk-result.json", 4096))
    passed = exit_code == 0 and result["passed"] is True and result["phase"] == "complete"
    passed = passed and result["sameOwner"] is True and result["controllerActuation"] is True
    passed = passed and result["guestStarted"] is False and result["networkSaved"] is False
    passed = passed and result["pixelsRead"] is False and result["idleQuitRequested"] is True
    passed = passed and result["vmID"] == configuration["id"] and before == after
    passed = passed and result["configurationSHA256"] == before["configuration.json"]["sha256"]
    passed = passed and result["events"] == [
        "sdk-owner-visible", "sdk-library-attached-to-owner",
        "sdk-network-sheet-attached-same-owner", "sdk-network-sheet-detached-after-controller-cancel",
    ]
    writer_available(directory, after["writer.lock"])
    require(build["sources"] == build_manifest.source_snapshot(ROOT)
            and digest(app) == build["appExecutableSHA256"], "qualification inputs changed")
    save(evidence / "native-result.json", {
        "scope": "actual-native-SDK-sheet-transitions-with-controller-actuation", "passed": passed,
        "actualAppExit": exit_code, "sdkResult": result, "fixturePreserved": before == after,
        "writerAvailableAfterAppExit": True,
        "appSHA256": build["appExecutableSHA256"], "credentialsCreated": False,
        "guestStarted": False, "networkEnabled": False, "pixelsRead": False,
        "contextMenuOrButtonClickQualified": False,
    })
    print(json.dumps({"passed": passed, "actualAppExit": exit_code,
                      "fixturePreserved": before == after, "evidence": str(evidence)}), flush=True)
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
