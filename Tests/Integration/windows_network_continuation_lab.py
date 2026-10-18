#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read-only gate for one prepared same-VM Windows networking continuation.

No process launch, input, shutdown, network connection, adoption, or repair occurs.
The actual parent must supply terminal observations after reaping its owned handle.
Passing this gate is advisory; a future launcher must acquire its own writer permit.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import uuid

ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = ROOT / ".lab/qemu-slirp-candidate-50c20db5653a47dd8a73d36439f45e66"
CANDIDATE_SHA = "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745"
DRIVER = ROOT / ".lab/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso"
DRIVER_SHA = "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394"
NAT = "user,id=net0,ipv4=on,ipv6=off,restrict=off,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15"
APPROVAL_KEYS = {"schemaVersion", "scope", "directory", "vmID", "previousSessionID", "planSHA256",
                 "macAddress", "candidateSHA256", "driverISOSHA256", "networkAuthorized",
                 "driverInstallationAuthorized", "normalShutdownAuthorized", "resumeAuthorized",
                 "credentialsAuthorized", "consoleReviewedSHA256"}


def require(condition, code):
    if not condition:
        raise ValueError(code)


def plain(path, directory=False, mode=None):
    require(path.is_absolute() and path == Path(os.path.abspath(path)), "normalized-absolute-path-required")
    for item in (path, *path.parents):
        value = item.lstat()
        require(not stat.S_ISLNK(value.st_mode), "symlink-rejected")
    value = path.lstat()
    require((stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode))
            and value.st_uid == os.geteuid() and (directory or value.st_nlink == 1), "owned-plain-path-required")
    require(mode is None or stat.S_IMODE(value.st_mode) == mode, "unexpected-private-mode")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-json-key")
        result[key] = value
    return result


def read(path, limit=65536):
    value = plain(path, mode=0o600)
    require(0 < value.st_size <= limit, "metadata-size-bound")
    data = path.read_bytes()
    require(len(data) == value.st_size, "metadata-changed")
    return data, json.loads(data, object_pairs_hook=unique_object)


def sha(path):
    value = plain(path)
    require(0 < value.st_size <= 128 << 20, "readonly-asset-size-bound")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validated_approval(plan_data, plan, approval):
    require(set(approval) == APPROVAL_KEYS and type(approval["schemaVersion"]) is int
            and approval["schemaVersion"] == 1
            and approval["scope"] == "approved-same-vm-windows-network-lab", "approval-scope")
    for key in ("directory", "vmID", "previousSessionID", "macAddress", "candidateSHA256", "driverISOSHA256"):
        require(approval[key] == plan[key], "approval-identity-or-resource-mismatch")
    require(approval["planSHA256"] == hashlib.sha256(plan_data).hexdigest(), "approval-plan-mismatch")
    for key in ("networkAuthorized", "driverInstallationAuthorized", "normalShutdownAuthorized", "resumeAuthorized"):
        require(approval[key] is True, "explicit-human-approval-required")
    require(approval["credentialsAuthorized"] is False, "credentials-outside-scope")
    require(approval["candidateSHA256"] == CANDIDATE_SHA and approval["driverISOSHA256"] == DRIVER_SHA,
            "qualified-assets-required")
    require(isinstance(approval["consoleReviewedSHA256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", approval["consoleReviewedSHA256"]),
            "reviewed-console-digest-required")


def expected_input(original, mac):
    expected = dict(original)
    argv = original["qemuArgv"][:]
    require(argv.count("-nic") == 1 and argv[argv.index("-nic") + 1] == "none", "original-offline-profile-changed")
    argv[0] = str(CANDIDATE / "qemu-system-aarch64")
    index = argv.index("-nic")
    argv[index:index + 2] = ["-netdev", NAT, "-device",
        "virtio-net-pci,id=nic0,netdev=net0,disable-legacy=on,disable-modern=off,mac=" + mac]
    argv[argv.index("-L") + 1] = str(CANDIDATE / "source/pc-bios")
    argv[argv.index("-k") + 1] = str(CANDIDATE / "source/pc-bios/keymaps/en-us")
    argv += ["-drive", "if=none,id=networkdrivers,format=raw,media=cdrom,readonly=on,file=" + str(DRIVER),
             "-device", "usb-storage,drive=networkdrivers,bus=xhci0.0"]
    expected.update(scope="approved-same-vm-windows-network-fixture", qemuArgv=argv)
    return expected


def require_terminal(terminal, plan, provenance):
    require(terminal.get("scope") == "actual-parent-owned-windows-continuation-terminal"
            and terminal.get("vmID") == plan["vmID"]
            and terminal.get("sessionID") == plan["previousSessionID"], "terminal-identity")
    for key in ("actualOwnerReaped", "allChildrenTerminal", "drainsFinished", "pipesClosed", "leasesClosed",
                "runtimeIntentSettled", "opaqueExitAdvisoryReviewed"):
        require(terminal.get(key) is True, "actual-terminal-observation-required")
    require(type(terminal.get("qemuExit")) is int and terminal["qemuExit"] == 0
            and type(terminal.get("tpmExit")) is int and terminal["tpmExit"] == 0
            and terminal.get("forceStopUsed") is False and terminal.get("guestCleanShutdownClaimed") is False,
            "normal-request-and-opaque-outcome-required")
    require(type(terminal.get("workerExit")) is int and terminal["workerExit"] in (0, 1),
            "actual-worker-terminal-status-required")
    require(provenance.get("scope") == "approved-fixed-windows-network-shutdown-input"
            and provenance.get("action") == "normal-shutdown"
            and provenance.get("vmID") == plan["vmID"]
            and provenance.get("sessionID") == plan["previousSessionID"]
            and provenance.get("fixedCommand") == "shutdown /s /t 0"
            and provenance.get("inputSequenceCompleted") is True
            and provenance.get("guestShutdownVerified") is False
            and provenance.get("forceStopUsed") is False, "reviewed-fixed-shutdown-provenance-required")


def check(args):
    require(args.check, "explicit-readonly-check-required")
    plain(args.plan.parent, directory=True, mode=0o700)
    require(args.plan.name == "plan.json" and args.approval.parent == args.plan.parent
            and args.approval.name == "approval.json" and args.plan.parent.parent == ROOT / ".lab"
            and re.fullmatch(r"windows-network-adoption-[0-9a-f]{32}", args.plan.parent.name), "private-plan-scope")
    plan_data, plan = read(args.plan)
    _, approval = read(args.approval, 32768)
    require(type(plan.get("schemaVersion")) is int and plan["schemaVersion"] == 1
            and plan.get("scope") == "prepared-same-vm-windows-network-lab",
            "plan-scope")
    validated_approval(plan_data, plan, approval)
    fixture = Path(plan["directory"])
    plain(fixture, directory=True, mode=0o700)
    require(fixture.parent == ROOT / ".lab" and re.fullmatch(r"windows-installer-boot-[0-9a-f]{32}", fixture.name),
            "same-approved-fixture-required")
    original_data, original = read(fixture / "swift-runtime-input.json")
    require(hashlib.sha256(original_data).hexdigest() == plan["originalInputSHA256"]
            and original == plan["originalInput"], "original-input-preservation-required")
    mac = ":".join(f"{value:02x}" for value in b"\x02" + uuid.UUID(plan["vmID"]).bytes[:5])
    require(plan["macAddress"] == mac and plan["proposedInput"] == expected_input(original, mac), "fixed-network-recipe-required")
    require(sha(CANDIDATE / "qemu-system-aarch64") == CANDIDATE_SHA and sha(DRIVER) == DRIVER_SHA,
            "qualified-assets-changed")
    plain(CANDIDATE / "qemu-system-aarch64", mode=0o500)
    plain(DRIVER, mode=0o400)
    _, terminal = read(args.terminal)
    _, provenance = read(args.shutdown_record)
    require_terminal(terminal, plan, provenance)
    require(terminal.get("shutdownRecordSHA256") == sha(args.shutdown_record), "terminal-provenance-binding")
    require(provenance.get("reviewedFrameSHA256") == approval["consoleReviewedSHA256"],
            "terminal-reviewed-console-binding")
    _, intent = read(fixture / "runtime-intent.json")
    require(intent.get("vmID") == plan["vmID"] and intent.get("sessionID") == plan["previousSessionID"]
            and intent.get("state") == "settled", "settled-original-intent-required")
    _, result = read(fixture / "swift-worker-result.json")
    require(result.get("runtimeIntentSettled") is True and result.get("drainsFinished") is True
            and type(result.get("qemuExit")) is int and result["qemuExit"] == 0
            and type(result.get("tpmExit")) is int and result["tpmExit"] == 0
            and result.get("guestCleanShutdownVerified") is False, "settled-opaque-worker-result-required")
    require(set(plan["resources"]) == {"blank-nvme.raw", "firmware-code.fd", "uefi-vars.json", "tpm-state"},
            "exact-preserved-resource-set-required")
    plain(fixture / "firmware-code.fd", mode=0o400)
    require(sha(fixture / "firmware-code.fd") == "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532",
            "preserved-firmware-changed")
    writer = fixture / "writer.lock"
    plain(writer, mode=0o600)
    descriptor = os.open(writer, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        for name, snapshot in plan["resources"].items():
            require(name in ("blank-nvme.raw", "firmware-code.fd", "uefi-vars.json", "tpm-state")
                    and snapshot["path"] == str(fixture / name), "resource-path-changed")
            value = plain(fixture / name, directory=name == "tpm-state")
            if name != "uefi-vars.json":
                require((value.st_dev, value.st_ino) == (snapshot["device"], snapshot["inode"]), "resource-identity-changed")
            if name == "blank-nvme.raw":
                require(value.st_size == snapshot["bytes"] == 64 * 1073741824, "disk-size-changed")
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--approval", type=Path, required=True)
    parser.add_argument("--terminal", type=Path, required=True)
    parser.add_argument("--shutdown-record", type=Path, required=True)
    plan = check(parser.parse_args())
    print(json.dumps({"scope": "readonly-same-vm-network-continuation-gate", "status": "requirements-matched",
                      "vmID": plan["vmID"], "macAddress": plan["macAddress"], "launchAuthorityMinted": False,
                      "guestCleanShutdownClaimed": False, "adoptionPerformed": False,
                      "networkExposed": False, "actualNewWriterPermitStillRequired": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
