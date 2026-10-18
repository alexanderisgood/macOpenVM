#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build an isolated ad-hoc signed app; never replaces the primary app.

The Windows wrapper selects an existing experiment's display route. The Linux
option opens the ordinary desktop. Launch through desktop control for UI tests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import build_manifest

HUMAN_RUN = ROOT / ".lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0/run-4805dfc7548144148c98a3ff9870e30e"
HUMAN_VM_ID = "11111111-1111-4111-8111-111111111111"
HUMAN_SESSION_ID = "22222222-2222-4222-8222-222222222222"
EXTERNAL_VM = Path("/Users/developer/Library/Application Support/macOpenVM/PrivateEvaluation") / HUMAN_VM_ID
EXTERNAL_RUNS = EXTERNAL_VM / "continuation-runs"


def private_display_route(run):
    """Read public correlation only; never contact or adopt the runtime."""
    route = run / "swift-display-ready.json"
    descriptor = os.open(route, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600
                or not 0 < before.st_size <= 4096):
            raise ValueError("The human-input route must be private public metadata")
        data = os.read(descriptor, 4097)
        after = os.fstat(descriptor)
        named = route.lstat()
        fields = ("st_dev", "st_ino", "st_size", "st_mode", "st_uid", "st_gid", "st_nlink", "st_mtime_ns", "st_ctime_ns")
        if (len(data) != before.st_size
                or any(getattr(before, key) != getattr(after, key) for key in fields)
                or any(getattr(after, key) != getattr(named, key) for key in fields)):
            raise ValueError("The human-input route changed")
    finally:
        os.close(descriptor)
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("Duplicate human-input route key")
            value[key] = item
        return value
    value = json.loads(data, object_pairs_hook=unique)
    if (not isinstance(value, dict)
            or set(value) != {"schemaVersion", "scope", "vmID", "sessionID", "controlSocket", "displaySocket",
                             "parentDevice", "parentInode", "socketDevice", "socketInode"}
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1):
        raise ValueError("The human-input route has an invalid bounded shape")
    return value, data


def human_input_binding(run):
    if run != HUMAN_RUN:
        raise ValueError("Select only the approved human-input continuation run")
    value, _ = private_display_route(run)
    if (value["scope"] != "approved-windows-network-continuation-display-route"
            or value["vmID"] != HUMAN_VM_ID or value["sessionID"] != HUMAN_SESSION_ID):
        raise ValueError("The human-input route does not match the approved VM and session")


def external_human_input_binding(run, session, route_sha):
    if (run.parent != EXTERNAL_RUNS or not re.fullmatch(r"run-[0-9a-f]{32}", run.name)
            or session is None or not re.fullmatch(r"[0-9A-Fa-f-]{36}", session)
            or str(uuid.UUID(session)).upper() != session.upper()
            or session.upper() in {HUMAN_SESSION_ID, "33333333-3333-4333-8333-333333333333"}
            or route_sha is None or not re.fullmatch(r"[0-9a-f]{64}", route_sha)):
        raise ValueError("Supply the exact fresh external run, independently expected session and route digest")
    for item in (run, *run.parents):
        value = item.lstat()
        if (not stat.S_ISDIR(value.st_mode) or value.st_uid not in {0, os.geteuid()}
                or value.st_mode & 0o022):
            raise ValueError("The external human-input ancestry is unsafe")
    value = run.lstat()
    if value.st_uid != os.geteuid() or stat.S_IMODE(value.st_mode) != 0o700:
        raise ValueError("The external human-input run must be private and owned")
    value, data = private_display_route(run)
    endpoint = value["controlSocket"]
    if (value["scope"] != "approved-windows-external-continuation-display-route"
            or value["vmID"] != HUMAN_VM_ID or value["sessionID"].upper() != session.upper()
            or hashlib.sha256(data).hexdigest() != route_sha
            or not isinstance(endpoint, str)
            or not re.fullmatch(r"/private/tmp/mvo-win-external-[0-9a-f]{16}/worker\.sock", endpoint)
            or value["displaySocket"] != endpoint.removesuffix("worker.sock") + "vnc.sock"):
        raise ValueError("The external human-input route does not match the independently supplied binding")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--fixture", type=Path)
    mode.add_argument("--continuation-run", type=Path)
    mode.add_argument("--human-input-continuation-run", type=Path)
    mode.add_argument("--external-human-input-run", type=Path)
    mode.add_argument("--linux-desktop", action="store_true")
    parser.add_argument("--expected-session")
    parser.add_argument("--expected-route-sha256")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    if args.configuration != "debug" and not args.linux_desktop:
        raise ValueError("Release profile is available only for an isolated ordinary desktop build")
    fixture = args.fixture
    human_input = args.human_input_continuation_run is not None
    external_run = args.external_human_input_run
    external_input = external_run is not None
    continuation = args.human_input_continuation_run if human_input else args.continuation_run
    if fixture is not None and (fixture.parent != ROOT / ".lab"
            or not re.fullmatch(r"windows-installer-boot-[0-9a-f]{32}", fixture.name)
            or fixture != fixture.resolve() or not fixture.is_dir()):
        raise ValueError("Select a normalized existing private installer fixture")
    if continuation is not None:
        staging = ROOT / ".lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0"
        if (continuation.parent != staging or continuation != continuation.resolve()
                or not re.fullmatch(r"run-[0-9a-f]{32}", continuation.name)
                or not continuation.is_dir() or continuation.stat().st_uid != os.geteuid()
                or continuation.stat().st_mode & 0o7777 != 0o700):
            raise ValueError("Select only an existing owned private continuation run")
    if human_input:
        human_input_binding(continuation)
    if external_input:
        external_human_input_binding(external_run, args.expected_session, args.expected_route_sha256)
    elif args.expected_session is not None or args.expected_route_sha256 is not None:
        raise ValueError("An expected external binding is valid only in the external human-input mode")
    os.umask(0o077)
    token = uuid.uuid4().hex
    prefix = "linux-desktop-artifacts-" if args.linux_desktop else "windows-external-human-input-artifacts-" if external_input else "windows-human-input-artifacts-" if human_input else "windows-network-display-artifacts-" if continuation is not None else "windows-display-artifacts-"
    artifact = ROOT / ".lab" / (prefix + token)
    artifact.mkdir(mode=0o700)
    before = build_manifest.source_snapshot(ROOT)
    with (artifact / "build.log").open("xb") as log:
        process = subprocess.run([str(ROOT / "scripts/swift.sh"), "build", "--configuration", args.configuration], cwd=ROOT,
                                 stdout=log, stderr=subprocess.STDOUT, timeout=300)
        log.flush()
        os.fsync(log.fileno())
    if process.returncode or before != build_manifest.source_snapshot(ROOT):
        raise ValueError("Build failed or source changed; preserve this artifact without adoption")
    binary_directory = Path(subprocess.check_output(
        [str(ROOT / "scripts/swift.sh"), "build", "--configuration", args.configuration, "--show-bin-path"],
        cwd=ROOT, stderr=subprocess.PIPE, text=True, timeout=30).strip())
    if not binary_directory.is_absolute() or not binary_directory.is_dir():
        raise ValueError("The selected build output directory could not be confirmed")
    cli = artifact / "macopenvm"
    shutil.copyfile(binary_directory / "macopenvm", cli)
    cli.chmod(0o700)
    app = artifact / "macOpenVM.app"
    macos, resources = app / "Contents/MacOS", app / "Contents/Resources"
    macos.mkdir(parents=True, mode=0o700)
    resources.mkdir(mode=0o700)
    native = macos / "macOpenVMNative"
    shutil.copyfile(binary_directory / "macOpenVMDesktop", native)
    native.chmod(0o700)
    worker = macos / build_manifest.WORKER_NAME
    shutil.copyfile(binary_directory / "macopenvm", worker)
    worker.chmod(0o700)
    wrapper = macos / "macOpenVM"
    arguments = "" if fixture is None else " --windows-installer-display-lab " + shlex.quote(str(fixture))
    if continuation is not None:
        flag = "--windows-network-human-input-display-lab" if human_input else "--windows-network-continuation-display-lab"
        arguments = " " + flag + " " + shlex.quote(str(continuation))
    if external_input:
        arguments = " --windows-external-human-input-display-lab " + " ".join(
            shlex.quote(value) for value in (str(external_run), args.expected_session, args.expected_route_sha256))
    wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(str(native)) + arguments + "\n")
    wrapper.chmod(0o700)
    for name in ("LICENSE", "NOTICE"):
        shutil.copyfile(ROOT / name, resources / name)
    shutil.copyfile(ROOT / "packaging/PrivacyInfo.xcprivacy", resources / "PrivacyInfo.xcprivacy")
    bundle_id = "local.macOpenVM." + ("linuxTrial." if args.linux_desktop else "windowsExternalHumanInputTrial." if external_input else "windowsHumanInputTrial." if human_input else "windowsNetworkTrial." if continuation is not None else "windowsTrial.") + token
    info = {"CFBundleName": "macOpenVM", "CFBundleDisplayName": "macOpenVM",
            "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "macOpenVM", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    with (artifact / "signature.log").open("xb") as log:
        for target in (cli, native):
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", bundle_id + "." + target.name,
                            "--entitlements", str(ROOT / "packaging/virtualization.entitlements"), str(target)],
                           stdout=log, stderr=log, check=True, timeout=20)
            target.chmod(0o500)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", bundle_id + ".worker",
                        "--entitlements", str(ROOT / "packaging/virtualization.entitlements"), str(worker)],
                       stdout=log, stderr=log, check=True, timeout=20)
        worker.chmod(0o500)
        build_manifest.write_worker_descriptor(worker, resources / build_manifest.WORKER_DESCRIPTOR, bundle_id + ".worker", exclusive=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", '=identifier "' + bundle_id + '.worker"', str(worker)],
                       stdout=log, stderr=log, check=True, timeout=20)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                       stdout=log, stderr=log, check=True, timeout=20)
        wrapper.chmod(0o500)
        for target in (cli, native, worker, app):
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(target)],
                           stdout=log, stderr=log, check=True, timeout=20)
    record = {"schemaVersion": 1, "configuration": args.configuration,
              "scope": "private-linux-desktop-build" if args.linux_desktop else "private-approved-external-human-input-display-build" if external_input else "private-approved-human-input-display-build" if human_input else "private-approved-continuation-display-build" if continuation is not None else "private-approved-installer-display-build", "sources": before,
              "builderSHA256": build_manifest.sha256_file(Path(__file__)), "cliSHA256": build_manifest.sha256_file(cli),
              "appExecutableSHA256": build_manifest.sha256_file(native), "wrapperSHA256": build_manifest.sha256_file(wrapper),
              "appWorkerSHA256": build_manifest.sha256_file(worker),
              "appWorkerDescriptorSHA256": build_manifest.sha256_file(resources / build_manifest.WORKER_DESCRIPTOR),
              "appWorkerIdentifier": bundle_id + ".worker",
              "fixture": str(fixture) if fixture is not None else None, "continuationRun": str(continuation) if continuation is not None else None, "bundleID": bundle_id, "signing": "adHocDevelopment", "releaseCleared": False,
              "primaryApplicationChanged": False, "humanInput": human_input or external_input,
              "externalVMDirectory": str(EXTERNAL_VM) if external_input else None,
              "externalRun": str(external_run) if external_input else None,
              "expectedVMID": HUMAN_VM_ID if human_input or external_input else None,
              "expectedSessionID": args.expected_session if external_input else HUMAN_SESSION_ID if human_input else None,
              "expectedRouteSHA256": args.expected_route_sha256 if external_input else None,
              "credentialsAuthorized": False}
    build_manifest.write_json(artifact / "build-record.json", record, exclusive=True)
    print(json.dumps({"artifact": str(artifact), "app": str(app), "cli": str(cli)}), flush=True)


if __name__ == "__main__":
    main()
