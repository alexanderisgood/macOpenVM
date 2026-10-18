#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Local build provenance, not a signed attestation or release trust anchor."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import tempfile

SOURCE_DIRECTORIES = ("App", "Backends", "CLI", "Core", "Storage", "RuntimeIPC", "GuestAgent")
SOURCE_PATTERNS = ("*.swift", "*.c", "*.h", "*.m", "*.mm", "*.modulemap")
RECIPE_FILES = ("Package.swift", "scripts/build.sh", "scripts/swift.sh", "scripts/build_manifest.py",
                "packaging/virtualization.entitlements", "packaging/PrivacyInfo.xcprivacy", "LICENSE", "NOTICE", "dependencies.json")
SOURCE_SCOPE = "Production Swift, C/Objective-C, headers/modulemaps and guest agent schema, Package.swift, build/signing recipe, entitlement, licenses and dependency inventory"
ENTITLEMENTS = {"com.apple.security.virtualization": True}
WORKER_SCOPE = "macopenvm-bundled-worker"
WORKER_NAME = "macopenvm-worker"
WORKER_DESCRIPTOR = "macopenvm-worker.json"


def worker_ancestry(path):
    for directory in path.absolute().parents:
        value = directory.lstat()
        temporary = directory == Path('/private/tmp') and value.st_uid == 0 and value.st_mode & stat.S_ISVTX
        if (not stat.S_ISDIR(value.st_mode) or value.st_uid not in {0, os.geteuid()}
                or value.st_mode & 0o022 and not temporary):
            raise ValueError("Bundled worker ancestry is unsafe")


def worker_artifact(path):
    """Hash only the actual bounded, immutable regular helper through one no-follow FD."""
    worker_ancestry(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in {0, os.geteuid()}
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o500
                or not 0 < before.st_size <= 134217728):
            raise ValueError("The bundled worker is not an immutable regular executable")
        digest = hashlib.sha256()
        count = 0
        while chunk := os.read(descriptor, 1048576):
            count += len(chunk)
            if count > before.st_size:
                raise ValueError("The bundled worker changed while hashing")
            digest.update(chunk)
        after, named = os.fstat(descriptor), path.lstat()
        fields = ("st_dev", "st_ino", "st_size", "st_mode", "st_uid", "st_gid", "st_nlink", "st_mtime_ns", "st_ctime_ns")
        if (count != before.st_size
                or any(getattr(before, key) != getattr(after, key) for key in fields)
                or any(getattr(after, key) != getattr(named, key) for key in fields)):
            raise ValueError("The bundled worker changed while hashing")
        return {"sha256": digest.hexdigest(), "bytes": count}
    finally:
        os.close(descriptor)


def worker_descriptor(worker, identifier):
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9.-]{1,255}", identifier):
        raise ValueError("Invalid fixed bundled worker identifier")
    return {"schemaVersion": 1, "scope": WORKER_SCOPE, "identifier": identifier, **worker_artifact(worker)}


def verify_worker_descriptor(worker, descriptor, identifier):
    expected = worker_descriptor(worker, identifier)
    worker_ancestry(descriptor)
    fd = os.open(descriptor, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in {0, os.geteuid()}
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600
                or not 0 < before.st_size <= 1024):
            raise ValueError("Invalid bounded bundled worker descriptor")
        data = os.read(fd, 1025)
        after, named = os.fstat(fd), descriptor.lstat()
        fields = ("st_dev", "st_ino", "st_size", "st_mode", "st_uid", "st_gid", "st_nlink", "st_mtime_ns", "st_ctime_ns")
        if (len(data) != before.st_size
                or any(getattr(before, key) != getattr(after, key) for key in fields)
                or any(getattr(after, key) != getattr(named, key) for key in fields)):
            raise ValueError("Bundled worker descriptor changed")
    finally:
        os.close(fd)
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("Duplicate bundled worker descriptor field")
            value[key] = item
        return value
    actual = json.loads(data, object_pairs_hook=unique)
    if (not isinstance(actual, dict) or set(actual) != set(expected)
            or type(actual["schemaVersion"]) is not int or type(actual["bytes"]) is not int
            or actual != expected):
        raise ValueError("Bundled worker descriptor does not match the actual helper")
    return expected


def write_worker_descriptor(worker, descriptor, identifier, exclusive=False):
    worker_ancestry(descriptor)
    write_json(descriptor, worker_descriptor(worker, identifier), exclusive=exclusive)
    return verify_worker_descriptor(worker, descriptor, identifier)


def actual_worker_entitlements(worker, identifier):
    value = actual_entitlements(worker)
    if not re.fullmatch(r"[A-Za-z0-9.-]{1,255}", identifier):
        raise ValueError("Invalid fixed bundled worker identifier")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", '=identifier "' + identifier + '"', str(worker)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return value


def verify_bundled_worker(root, manifest):
    app = root / "build/macOpenVM.app"
    worker = app / "Contents/MacOS" / WORKER_NAME
    descriptor = app / "Contents/Resources" / WORKER_DESCRIPTOR
    identifier = "local.macOpenVM.worker"
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    expected = verify_worker_descriptor(worker, descriptor, identifier)
    artifact = manifest.get("artifacts", {}).get("appWorker")
    if artifact != {"sha256": expected["sha256"], "bytes": expected["bytes"],
                    "identifier": identifier, "entitlements": actual_worker_entitlements(worker, identifier)}:
        raise ValueError("Bundled worker differs from actual packaged provenance")
    return artifact


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1_048_576):
            digest.update(chunk)
    return digest.hexdigest()


def bounded_json(path, maximum=262_144):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum:
            raise ValueError("Provenance must be bounded regular JSON")
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("Provenance exceeds its bound")
    def invalid_constant(_):
        raise ValueError("Nonfinite JSON is not provenance")
    return json.loads(data, parse_constant=invalid_constant)


def source_snapshot(root):
    paths = {root / name for name in RECIPE_FILES}
    # Keep the declared production roots: build/.lab output, tests and
    # benchmark fixtures elsewhere in the repository are not packaged inputs.
    for name in SOURCE_DIRECTORIES:
        for pattern in SOURCE_PATTERNS:
            paths.update((root / name).rglob(pattern))
    for extension in ("*.json", "*.py"):
        paths.update((root / "GuestAgent").rglob(extension))
    records = []
    for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix()):
        if path.is_symlink() or not path.is_file():
            raise ValueError("Build inputs must be regular local source files")
        records.append({"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size,
                        "sha256": sha256_file(path)})
    canonical = json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
    return {"scope": SOURCE_SCOPE, "files": records, "sha256": hashlib.sha256(canonical).hexdigest()}


def write_json(path, value, exclusive=False):
    data = (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()
    if exclusive:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data); output.flush(); os.fsync(output.fileno())
    else:
        descriptor, temporary = tempfile.mkstemp(prefix=".macopenvm-provenance-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(data); output.flush(); os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def verify_current_cli(root, manifest):
    if not isinstance(manifest, dict) or type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
        raise ValueError("Unknown build provenance schema")
    if manifest.get("configuration") not in ("debug", "release"):
        raise ValueError("Missing actual build configuration")
    if manifest.get("sources") != source_snapshot(root):
        raise ValueError("Source or build recipe changed; rebuild before benchmarking")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or not isinstance(artifacts.get("cli"), dict):
        raise ValueError("Missing CLI artifact provenance")
    artifact = artifacts["cli"]
    if not isinstance(manifest.get("version"), str) or not manifest["version"]:
        raise ValueError("Missing packaged version")
    toolchain = manifest.get("toolchain")
    if not isinstance(toolchain, dict) or not all(isinstance(toolchain.get(key), str) and toolchain[key]
                                                for key in ("swift", "sdk", "hostArchitecture")):
        raise ValueError("Missing build toolchain provenance")
    if manifest.get("revision") is not None and not isinstance(manifest["revision"], str):
        raise ValueError("Invalid build revision")
    cli = root / "build/bin/macopenvm"
    if cli.is_symlink() or not cli.is_file():
        raise ValueError("The packaged runner is not a regular local artifact")
    if artifact.get("sha256") != sha256_file(cli) or artifact.get("bytes") != cli.stat().st_size:
        raise ValueError("Packaged runner differs from recorded build; rebuild before benchmarking")
    if artifact.get("entitlements") != ENTITLEMENTS or manifest.get("signing") != "adHoc":
        raise ValueError("This harness requires the recorded minimal development signing profile")
    return artifact


def actual_entitlements(path):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data = subprocess.check_output(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(path)],
                                   stderr=subprocess.DEVNULL)
    value = plistlib.loads(data)
    if value != ENTITLEMENTS:
        raise ValueError("Unexpected development entitlements")
    return value


def record(root, configuration, before):
    snapshot = source_snapshot(root)
    if before != snapshot:
        raise ValueError("Build inputs changed during packaging; provenance not committed")
    artifacts = {}
    for role, relative in (("cli", "build/bin/macopenvm"), ("appExecutable", "build/macOpenVM.app/Contents/MacOS/macOpenVM")):
        path = root / relative
        artifacts[role] = {"sha256": sha256_file(path), "bytes": path.stat().st_size,
                           "entitlements": actual_entitlements(path)}
    worker = root / "build/macOpenVM.app/Contents/MacOS" / WORKER_NAME
    artifacts["appWorker"] = {**worker_artifact(worker), "identifier": "local.macOpenVM.worker",
                              "entitlements": actual_worker_entitlements(worker, "local.macOpenVM.worker")}
    revision = None
    git = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True)
    if git.returncode == 0:
        revision = git.stdout.strip()
    with (root / "build/macOpenVM.app/Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    manifest = {"schemaVersion": 1, "builtAt": datetime.now(timezone.utc).isoformat(),
                "configuration": configuration, "version": info["CFBundleShortVersionString"],
                "revision": revision, "signing": "adHoc", "sources": snapshot, "artifacts": artifacts,
                "toolchain": {"swift": subprocess.check_output(["xcrun", "swift", "--version"], stderr=subprocess.STDOUT).decode().strip(),
                              "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).decode().strip(),
                              "hostArchitecture": platform.machine()}}
    verify_current_cli(root, manifest)
    verify_bundled_worker(root, manifest)
    write_json(root / "build/build-manifest.json", manifest)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("snapshot", "record", "verify", "worker-descriptor"))
    parser.add_argument("--configuration", choices=("debug", "release"))
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--worker", type=Path)
    parser.add_argument("--descriptor", type=Path)
    parser.add_argument("--identifier")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.command == "worker-descriptor":
        if args.worker is None or args.descriptor is None or args.identifier is None:
            parser.error("--worker, --descriptor and --identifier are required")
        write_worker_descriptor(args.worker, args.descriptor, args.identifier)
    elif args.command == "snapshot":
        if args.snapshot is None:
            parser.error("--snapshot is required")
        write_json(args.snapshot, source_snapshot(root))
    elif args.command == "record":
        if args.snapshot is None or args.configuration is None:
            parser.error("--snapshot and --configuration are required")
        record(root, args.configuration, bounded_json(args.snapshot))
    else:
        manifest = bounded_json(root / "build/build-manifest.json")
        verify_current_cli(root, manifest)
        verify_bundled_worker(root, manifest)
        actual_entitlements(root / "build/bin/macopenvm")
        print("Packaged CLI hash, source recipe and development signature match build provenance.")


if __name__ == "__main__":
    main()
