#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare or explicitly run one fresh diskless firmware shutdown observation.

No OS image, NIC, shares or guest secrets. Failure/timeout never authorizes signals,
QMP quit or force stop: the actual child handle stays retained until reaped.
Firmware ResetSystem is not Windows ACPI or guest filesystem qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / ".lab/efi-shutdown-probe-5f2c5b261b454ea687e604109f9fb3e4"
PROFILE_SHA = "b65782f00802d937bc042373e845af3cd2f3edca3a95454bb1387da18548d4c4"
PINNED_SWTPM = Path("/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm")
SWTPM_SHA = "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a"
PINS = {
    "firmware-code-64m.fd": (67108864, "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532"),
    "efi-media/EFI/BOOT/BOOTAA64.EFI": (24576, "3c2bac406642468004f7dffa06ab93be51fec9fe45b6b8104d6aaecbfef3e92f"),
    "efi-media/startup.nsh": (27, "7da73d5c619b7bbcbbc9d20b894b62fae55ef5dabe9f4775911cd753fe38e3c8"),
}
SOURCE_NAMES = [
    "Backends/Qemu/QMPClient.swift", "Backends/Qemu/QemuMachineBackend.swift",
    "Backends/Qemu/OwnedProcess.swift", "Backends/Qemu/LeaseSpawn.swift",
    "Core/VMController.swift", "Core/RecordedRuntimeOwner.swift", "Core/RuntimeWorkerCoordinator.swift",
    "CLI/QemuShutdownLab.swift", "CLI/Main.swift", "Tests/Integration/qemu_shutdown_native.py",
    "Tests/EFI/MacOpenVMLabPkg/ShutdownProbe/ShutdownProbe.c",
    "Tests/EFI/MacOpenVMLabPkg/ShutdownProbe/ShutdownProbe.inf",
    "Tests/EFI/MacOpenVMLabPkg/ShutdownProbe/ShutdownProbe.dsc",
]


def require(condition, code):
    if not condition:
        raise ValueError(code)


def ancestry(path, pinned_swtpm=False):
    require(path.is_absolute() and str(path) == os.path.abspath(path), "normalized-absolute-path-required")
    for part in (path, *path.parents):
        value = part.lstat()
        temporary = part == Path("/private/tmp") and value.st_uid == 0 and value.st_mode & stat.S_ISVTX
        # Read-only exception for this already-pinned tool: the existing Cellar is
        # owned by this user and admin-group writable. Other paths remain strict.
        cellar = pinned_swtpm and part == Path("/opt/homebrew/Cellar") and value.st_uid == os.geteuid() \
            and value.st_gid == 80 and stat.S_IMODE(value.st_mode) == 0o775
        require(stat.S_ISDIR(value.st_mode) and value.st_uid in (0, os.geteuid())
                and (not value.st_mode & 0o022 or temporary or cellar), "plain-owned-ancestry-required")


def hash_file(path, maximum=128 << 20, mode=None, pinned_swtpm=False):
    require(not pinned_swtpm or path == PINNED_SWTPM, "pinned-tool-path-required")
    ancestry(path.parent, pinned_swtpm=pinned_swtpm)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid in (0, os.geteuid()) and before.st_nlink == 1
                and not before.st_mode & 0o022 and 0 < before.st_size <= maximum
                and (mode is None or stat.S_IMODE(before.st_mode) == mode), "bounded-plain-file-required")
        total = 0
        digest = hashlib.sha256()
        for data in iter(lambda: source.read(1 << 20), b""):
            total += len(data)
            require(total <= maximum, "file-size-bound")
            digest.update(data)
        after = os.fstat(source.fileno())
        named = path.lstat()
        require(total == before.st_size and all((x.st_dev, x.st_ino, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
                == (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                for x in (after, named)), "file-changed")
    return digest.hexdigest()


def verify_swtpm(path):
    require(path == PINNED_SWTPM, "pinned-tool-path-required")
    digest = hash_file(path, maximum=72192, mode=0o555, pinned_swtpm=True)
    require(path.stat().st_size == 72192 and digest == SWTPM_SHA, "pinned-swtpm-mismatch")
    return digest


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-json-field")
        result[key] = value
    return result


def read_json(path, maximum=65536):
    ancestry(path.parent)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == 0o600 and 0 < before.st_size <= maximum,
                "bounded-private-record-required")
        data = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        named = path.lstat()
        require(len(data) == before.st_size and all((x.st_dev, x.st_ino, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
                == (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                for x in (after, named)), "metadata-changed")
    return json.loads(data, object_pairs_hook=unique_object)


def new_file(path, data, mode=0o600):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def save(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    require(len(data) <= 65536, "record-size-bound")
    new_file(path, data)


def validated_inputs(cli):
    require(cli.is_relative_to(ROOT / ".lab") and cli.name == "macopenvm"
            and cli.lstat().st_uid == os.geteuid(), "explicit-private-cli-required")
    cli_sha = hash_file(cli, mode=0o500)
    require(cli.stat().st_mode & 0o100, "cli-executable-required")
    build_path = cli.parent / "build-record.json"
    build_sha = hash_file(build_path, maximum=131072, mode=0o600)
    build = read_json(build_path, 131072)
    require(type(build.get("schemaVersion")) is int and build["schemaVersion"] == 1
            and build.get("scope") == "private-linux-desktop-build" and build.get("cliSHA256") == cli_sha,
            "reviewed-private-build-required")
    source_pins = {name: hash_file(ROOT / name) for name in SOURCE_NAMES}
    files = build.get("sources", {}).get("files")
    require(isinstance(files, list), "compiled-source-record-required")
    compiled = {}
    for row in files:
        require(isinstance(row, dict) and isinstance(row.get("path"), str)
                and row["path"] not in compiled, "unique-build-source-record-required")
        compiled[row["path"]] = row
    for name in (name for name in SOURCE_NAMES if name.endswith(".swift")):
        row = compiled.get(name, {})
        require(row.get("sha256") == source_pins[name] and type(row.get("bytes")) is int
                and row["bytes"] == (ROOT / name).stat().st_size, "compiled-source-binding-required")
    original = read_json(ASSETS / "artifact.json").get("originalProbeSources")
    for name in (name for name in SOURCE_NAMES if name.endswith((".c", ".inf", ".dsc"))):
        require(isinstance(original, dict) and original.get(name) == source_pins[name], "probe-source-binding-required")
    return cli_sha, build_sha, source_pins


def prepare(directory, cli):
    require(directory.parent == ROOT / ".lab" and str(directory) == os.path.abspath(directory)
            and re.fullmatch(r"qemu-shutdown-native-[0-9a-f]{32}", directory.name), "fresh-fixture-scope-required")
    ancestry(directory.parent)
    require(not os.path.lexists(directory), "existing-fixture-never-reused")
    cli_sha, build_sha, source_pins = validated_inputs(cli)
    profile_path = ASSETS / "proposed-diskless-profile.json"
    require(hash_file(profile_path, mode=0o600) == PROFILE_SHA, "profile-pin-mismatch")
    profile = read_json(profile_path)
    for path, expected in profile["assets"].items():
        selected = Path(path)
        actual = verify_swtpm(selected) if selected == PINNED_SWTPM else hash_file(selected)
        require(actual == expected["sha256"] and selected.stat().st_size == expected["bytes"],
                "runtime-asset-pin-mismatch")
    token = uuid.uuid4().hex
    short = Path("/private/tmp") / ("mvo-stop-" + token[:16])
    ancestry(short.parent)
    directory.mkdir(mode=0o700)
    short.mkdir(mode=0o700)
    (directory / "tpm-state").mkdir(mode=0o700)
    new_file(directory / "uefi-vars.json", b"")
    for name, (length, digest) in PINS.items():
        target = directory / name
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        new_file(target, (ASSETS / name).read_bytes(), mode=0o400)
        require(target.stat().st_size == length and hash_file(target, mode=0o400) == digest,
                "copied-readonly-asset-pin-mismatch")
    def expand(value):
        return value.replace("{FRESH}", str(directory)).replace("{SHORT}", str(short))
    input_value = {"schemaVersion": 1, "scope": "new-owned-offline-no-os-shutdown-fixture",
                   "qemuArgv": [expand(x) for x in profile["qemuArgvTemplate"]],
                   "swtpmArgv": [expand(x) for x in profile["swtpmArgvTemplate"]],
                   "environment": {k: expand(v) for k, v in profile["environmentTemplate"].items()},
                   "qmpSocket": str(short / "qmp.sock"), "tpmSocket": str(short / "tpm.sock"),
                   "guestLaunched": False, "windowsCompatibilityVerified": False}
    save(directory / "swift-runtime-input.json", input_value)
    record = {"schemaVersion": 1, "scope": "original-diskless-shutdown-probe-v1", "vmID": str(uuid.uuid4()).upper(),
              "preparedOnly": True, "nativeChildrenLaunched": False, "cliPath": str(cli),
              "cliBytes": cli.stat().st_size, "cliSHA256": cli_sha, "profileSHA256": PROFILE_SHA,
              "buildRecordSHA256": build_sha,
              "sourcePins": source_pins, "inputSHA256": hash_file(directory / "swift-runtime-input.json")}
    save(directory / "shutdown-prepared.json", record)
    return record


def verify_terminal(directory, prepared):
    result = read_json(directory / "shutdown-result.json")
    runtime = read_json(directory / "runtime.json", 4096)
    intent = read_json(directory / "runtime-intent.json", 4096)
    require(type(result.get("schemaVersion")) is int and result["schemaVersion"] == 1 and result.get("status") == "passed"
            and result.get("scope") == prepared["scope"] and result.get("vmID") == prepared["vmID"],
            "native-result-identity")
    for key in ("probeReadySeen", "probeRequestSeen", "drainsFinished", "readonlyHashesPreserved",
                "sameOwnerGuestStoppedReceipt", "runtimeIntentSettled"):
        require(result.get(key) is True, "complete-native-result-required")
    for key in ("qemuSignalled", "tpmSignalled", "deadlineExceeded", "qmpQuitRequested", "forceStopRequested",
                "signalsRequested", "windowsCompatibilityVerified", "guestFilesystemVerified"):
        require(result.get(key) is False, "unforced-original-probe-only")
    require(type(result.get("qemuExit")) is int and result["qemuExit"] == 0
            and type(result.get("tpmExit")) is int and result["tpmExit"] == 0, "actual-exits-required")
    monitor = result.get("monitor", {})
    require(monitor.get("guest") is True and monitor.get("reason") == "guest-shutdown"
            and monitor.get("naturalEOF") is True and monitor.get("readerDrained") is True
            and monitor.get("intentionalClose") is False and monitor.get("failurePresent") is False,
            "original-natural-monitor-provenance-required")
    uuid.UUID(monitor["connectionEpoch"])
    require(type(monitor.get("sequence")) is int and monitor["sequence"] > 0, "monitor-sequence-required")
    session = result["sessionID"]
    uuid.UUID(session)
    require(type(runtime.get("schemaVersion")) is int and runtime["schemaVersion"] == 1
            and type(intent.get("schemaVersion")) is int and intent["schemaVersion"] == 1
            and runtime.get("sessionID") == session and runtime.get("snapshot", {}).get("outcome") == "guestStopped"
            and runtime["snapshot"].get("state") == "stopped" and runtime["snapshot"].get("backendActive") is False
            and intent.get("vmID") == prepared["vmID"] and intent.get("sessionID") == session
            and intent.get("state") == "settled", "actual-owner-history-and-intent-required")
    require(result.get("inputSHA256") == prepared["inputSHA256"]
            and result.get("profileSHA256") == PROFILE_SHA and result.get("cliSHA256") == prepared["cliSHA256"]
            and result.get("sourcePinsAtPreparation") == prepared["sourcePins"], "native-result-input-binding")
    for name, (length, digest) in PINS.items():
        require(hash_file(directory / name, mode=0o400) == digest and (directory / name).stat().st_size == length,
                "readonly-assets-changed")
    return result


def retain_until_reaped(child):
    while True:
        try:
            return child.wait(timeout=1)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            pass  # Neither EOF, interruption nor timeout is authority to signal the owned child.
        except OSError:
            time.sleep(0.1)  # Observation errors retain the actual handle; they never prove exit.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--run", action="store_true")
    mode.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--cli", type=Path)
    args = parser.parse_args()
    if not args.run and not args.prepare_only:
        print("SKIP: explicit preparation or native run required")
        return 0
    require(args.cli is not None, "caller-selected-private-cli-required")
    os.umask(0o077)
    directory = args.directory or ROOT / ".lab" / ("qemu-shutdown-native-" + uuid.uuid4().hex)
    prepared = prepare(directory, args.cli)
    print(json.dumps({"directory": str(directory), "preparedOnly": True, "nativeChildrenLaunched": False}), flush=True)
    if args.prepare_only:
        return 0
    cli_sha, build_sha, source_pins = validated_inputs(args.cli)
    require(cli_sha == prepared["cliSHA256"] and build_sha == prepared["buildRecordSHA256"]
            and source_pins == prepared["sourcePins"]
            and hash_file(directory / "swift-runtime-input.json") == prepared["inputSHA256"],
            "prelaunch-input-binding-changed")
    # Parent evidence is outside the CLI's exact fresh-fixture admission namespace.
    evidence = directory.with_name(directory.name + "-owner")
    evidence.mkdir(mode=0o700)
    child = None
    deadline_exceeded = False
    interruption = None
    try:
        output_fd = os.open(directory / "worker-stdout.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(output_fd, "wb") as output:
            error_fd = os.open(directory / "worker-stderr.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(error_fd, "wb") as errors:
                child = subprocess.Popen([str(args.cli), "qemu-shutdown-lab", "--directory", str(directory)],
                                         stdin=subprocess.DEVNULL, stdout=output, stderr=errors, cwd=directory, close_fds=True)
                save(evidence / "actual-parent-handle.json", {"scope": "actual-owned-shutdown-worker-handle",
                     "directory": str(directory), "pid": child.pid})
                try:
                    child.wait(timeout=150)
                except subprocess.TimeoutExpired:
                    deadline_exceeded = True
                    print("Observation deadline elapsed; actual owner retained without stop or signal.", flush=True)
    except BaseException as error:
        interruption = type(error).__name__
        if child is not None and child.poll() is None:
            print("Interrupted observation; actual owner retained without stop or signal.", flush=True)
    finally:
        if child is not None:
            exit_code = retain_until_reaped(child)
            save(evidence / "parent-terminal.json", {"scope": "actual-parent-reaped-shutdown-worker",
                  "directory": str(directory), "workerExit": exit_code,
                  "actualOwnerReaped": True, "deadlineExceeded": deadline_exceeded, "interruptionKind": interruption,
                  "forceStopRequested": False, "signalsRequested": False})
    require(child is not None and child.returncode == 0 and not deadline_exceeded and interruption is None,
            "native-worker-terminal-success-required")
    result = verify_terminal(directory, prepared)
    print(json.dumps({"directory": str(directory), "status": "passed", "vmID": result["vmID"],
                      "sessionID": result["sessionID"], "actualOwnerReaped": True,
                      "windowsCompatibilityVerified": False, "guestFilesystemVerified": False}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
