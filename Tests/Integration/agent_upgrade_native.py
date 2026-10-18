#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit three-boot A/B/A proof on one fresh offline private Linux copy.

No --run means no input inspection, credentials, carrier, copy or guest action.
The caller supplies the signed generations, approved issuer and private credentials.
This runner generates no keys, never boots its source, and never force-stops an owner.
"""
import argparse
import base64
from dataclasses import dataclass
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import sys
import shutil
import stat
import subprocess
import time
import uuid

import agent_install_native as base
from alpine_live_preflight import ASSETS, BOOT_ARGUMENTS, GuestConsole
from managed_serial import ManagedSerial, executable_identity

ROOT = base.ROOT
SOURCE = base.SOURCE
GUEST_SCRIPT = Path(__file__).with_name("agent_upgrade_guest.sh")
CLI_PATH = ROOT / ".lab/linux-desktop-artifacts-6b9e876a972a40d88be5d94cad4a6511/macopenvm"
CLI_SHA256 = "446bf0448ff0ab56bac0e396bf39e12c50cb1620a4324f4744da0f241f827f7f"
MANAGER_SHA256 = "43d1e7fc58283de979f73c7ca3803a1a647036a6df50f58c723f90368aa2f722"
MANIFEST_PINS = ("d6fd134893bb31e65030783570cbcbd00d89c58a2737ac1485fcd52b3e5f5fbf",
                 "f79e23750e6fcd67f6095a7003abc9f37ad9f2c9af69a83cb2fe18d6a2992600")
ISSUER_SHA256 = "ceb8baa2dfc994f938500e6afdd43bfd9322dbbf55e391e4dab3e8742d7f7001"
VOLUME_LABEL = "MVO_AGENT_ABA"  # Fits both ASCII and 16-code-unit Joliet identifiers.
require = base.require


@dataclass(frozen=True)
class NativeGenerationProfile:
    name: str
    cli: Path
    cli_sha256: str
    manager_sha256: str
    manifest_pins: tuple[str, str]
    issuer_sha256: str
    manager_limit: int
    retirement: bool = False


RETIREMENT_PROFILE = NativeGenerationProfile(
    "current-manager-retirement", ROOT / ".lab/linux-desktop-artifacts-e5fef4292576402f8394826774fc78c2/macopenvm",
    "bc67a2575defd0849604c2981e35cbdff9aa3155e250fa14e32e935f47ed8516",
    "60c3a86f097e547faf73fed0466444d63eba3657eabc6390fa038545c89524d8",
    ("7a03df2181a1f06c8b4b8791c8fb42c4f6c28b3d799f346999833a2be7f0bdff",
     "db1306a6381f2dd9d878d2b1d1499d048746c7a88080c12ad36032a907f8175f"),
    "289fd01cdfbe9b0d55a08999bfbb780d33dbc7ab61b5fac42dc29fee50819db9", 131072, True)
RETIREMENT_BUILD_RECORD_SHA256 = "5c16d9e37dbd8315b73397ce8033ed62b1c7aba8954adaeaf65c2d7bb838e8e9"


def historical_profile():
    return NativeGenerationProfile("historical-compatible-manager", CLI_PATH, CLI_SHA256,
                                   MANAGER_SHA256, MANIFEST_PINS, ISSUER_SHA256, 65536)


def selected_profile(retire_failed=False, retirement_id=None):
    if not retire_failed:
        require(retirement_id is None, "retirement-id-without-profile")
        return historical_profile()
    require(isinstance(retirement_id, str)
            and re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", retirement_id)
            and uuid.UUID(retirement_id).int != 0, "explicit-canonical-retirement-id-required")
    return RETIREMENT_PROFILE


def plain_path(path):
    path = Path(path)
    require(path.is_absolute() and len(os.fspath(path)) <= 4096
            and path == Path(os.path.abspath(path)) and len(path.parts) <= 128, "input-path-invalid")
    current = Path("/")
    for component in path.parts[1:]:
        current = current / component
        info = current.lstat()
        require(not stat.S_ISLNK(info.st_mode)
                and (current == path or stat.S_ISDIR(info.st_mode)), "input-ancestor-invalid")
    return path


def plain_file_identity(path, limit, *, mode=None, expected_sha256=None):
    """Bounded regular input; never follows the selected file's symbolic link."""
    path = plain_path(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid == os.geteuid()
                and 0 < before.st_size <= limit, "input-file-invalid")
        if mode is not None:
            require(stat.S_IMODE(before.st_mode) == mode, "input-mode-invalid")
        if expected_sha256 is not None:
            require(base.digest(path, limit) == expected_sha256, "input-hash-invalid")
        require(base.stamp(before) == base.stamp(os.fstat(descriptor)) == base.stamp(path.lstat()),
                "input-file-changed")
        return base.stamp(before)
    finally:
        os.close(descriptor)


def credential_identity(credentials):
    require(re.fullmatch(r"/private/tmp/mvo-agent-tls-[0-9a-f]{32}", str(credentials)),
            "credential-path-invalid")
    plain_path(credentials)
    directory = base.private_directory(credentials)
    names = ("guest.pem", "guest-key.pem", "ca.pem", "guest.der", "client.der", "client-key.der", "ca.der")
    identities = {name: plain_file_identity(credentials / name, 65536, mode=0o600) for name in names}
    # Public certificates only. Private-key bytes/hashes never enter evidence or transcripts.
    public = base.public_credential_identity(credentials)
    return directory, identities, public


def admit_inputs(cli, payload_a, payload_b, issuer, credentials, profile=None):
    profile = profile or historical_profile()
    require(cli == profile.cli and issuer == profile.issuer_sha256, "unapproved-cli-or-issuer")
    plain_file_identity(cli, 128 << 20, mode=0o500, expected_sha256=profile.cli_sha256)
    if profile.retirement:
        build_record = cli.parent / "build-record.json"
        plain_file_identity(build_record, 262144, mode=0o600,
                            expected_sha256=RETIREMENT_BUILD_RECORD_SHA256)
        built = read_private_json(build_record, 262144)
        require(type(built.get("schemaVersion")) is int and built["schemaVersion"] == 1
                and built.get("cliSHA256") == profile.cli_sha256, "retirement-cli-build-mismatch")
        source_rows = built["sources"]["files"]
        require(sum(row.get("path") == "GuestAgent/Host/AgentPackageVerifier.swift"
                    and row.get("sha256") == "d31f0a29d39c75248dd3d589a02f5949b9269c07d583b976c6809f32181c29ba"
                    for row in source_rows) == 1, "retirement-verifier-source-mismatch")
    packages = []
    for payload, pin in zip((payload_a, payload_b), profile.manifest_pins):
        plain_path(payload)
        base.private_directory(payload)
        require(set(path.name for path in payload.iterdir()) ==
                {"SHA256SUMS", "agent", "initd", "setup.sh", "issuer.raw", "manifest.sig"}, "package-namespace-invalid")
        files = {name: plain_file_identity(payload / name, limit, mode=0o600)
                 for name, limit in (("agent", 16 << 20), ("initd", 16384), ("setup.sh", profile.manager_limit),
                                     ("SHA256SUMS", 512), ("issuer.raw", 32), ("manifest.sig", 64))}
        plain_file_identity(payload / "SHA256SUMS", 512, mode=0o600, expected_sha256=pin)
        plain_file_identity(payload / "setup.sh", profile.manager_limit, mode=0o600,
                            expected_sha256=profile.manager_sha256)
        require((payload / "issuer.raw").stat().st_size == 32 and (payload / "manifest.sig").stat().st_size == 64,
                "publisher-size-invalid")
        verification = json.loads(base.command(cli, ["verify-agent-package-lab", "--directory", str(payload),
                                                    "--issuer", issuer]))
        require(verification["manifestSHA256"] == pin and verification["filesVerified"] == 3
                and verification["issuerSHA256"] == issuer, "signed-package-invalid")
        packages.append((base.private_directory(payload), files))
    require(payload_a != payload_b and (payload_a / "initd").read_bytes() == (payload_b / "initd").read_bytes()
            and (payload_a / "setup.sh").read_bytes() == (payload_b / "setup.sh").read_bytes()
            and base.digest(payload_a / "agent", 16 << 20) != base.digest(payload_b / "agent", 16 << 20),
            "generations-not-compatible")
    return tuple(packages), credential_identity(credentials)


def same_inputs(cli, payload_a, payload_b, issuer, credentials, identity, profile=None):
    require(admit_inputs(cli, payload_a, payload_b, issuer, credentials, profile) == identity, "approved-inputs-changed")


def code_snapshot():
    paths = (Path(__file__), GUEST_SCRIPT, Path(base.__file__), Path(__file__).with_name("managed_serial.py"),
             Path(__file__).with_name("alpine_live_preflight.py"))
    return {path.relative_to(ROOT).as_posix(): base.digest(path, 1 << 20) for path in paths}


def same_code(snapshot):
    require(code_snapshot() == snapshot, "proof-code-changed")


def read_private_json(path, limit=16384):
    before = plain_file_identity(path, limit, mode=0o600)
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "metadata-duplicate-field")
            result[key] = value
        return result
    value = json.loads(path.read_text(), object_pairs_hook=unique_object)
    require(plain_file_identity(path, limit, mode=0o600) == before, "metadata-changed")
    return value


def initial_intent_absent(vm):
    path = vm / "runtime-intent.json"
    require(not path.exists() and not path.is_symlink(), "initial-intent-present")


def recorded_intent(vm, vm_id, session_id, state):
    intent = read_private_json(vm / "runtime-intent.json", 4096)
    require(isinstance(intent, dict) and set(intent) == {"schemaVersion", "vmID", "sessionID", "state"}
            and type(intent["schemaVersion"]) is int and intent["schemaVersion"] == 1
            and intent["vmID"] == vm_id and intent["sessionID"] == session_id
            and intent["state"] == state, "recorded-intent-mismatch")
    return intent


def terminal_guest_snapshot(history):
    snapshot = history.get("snapshot")
    return (isinstance(snapshot, dict)
            and set(snapshot) == {"state", "backendActive", "outcome"}
            and snapshot["state"] == "stopped" and snapshot["backendActive"] is False
            and snapshot["outcome"] == "guestStopped")


def generation_rows(owner, marker):
    # The single admitted support label contains underscores. Keep the existing
    # observation grammar for every other field instead of broadening it globally.
    raw = owner.snapshot(deadline=time.monotonic() + 1).stdout
    raw = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw).replace(b"\r", b"")
    found = {}
    prefix = (marker + ".").encode()
    for line in raw.splitlines():
        if not line.startswith(prefix):
            continue
        key, separator, value = line[len(prefix):].partition(b"=")
        valid_value = (value == VOLUME_LABEL.encode() if key == b"support.label"
                       else re.fullmatch(rb"[A-Za-z0-9.:-]+", value))
        require(separator and re.fullmatch(rb"[A-Za-z0-9.]+", key)
                and valid_value, "invalid-guest-observation")
        decoded = key.decode("ascii")
        require(decoded not in found, "invalid-guest-observation")
        found[decoded] = value.decode("ascii")
    return found


def validate_boot_observations(rows, boot, profile, retirement_id=None):
    require(boot in (1, 2, 3) and rows.get("exit") == "0" and rows.get("phase") == "complete"
            and all(rows.get(key) == "1" for key in
                    ("normalRoot", "accountsPreserved", "identityPreserved")),
            "guest-generation-observation-failed")
    if boot == 1:
        require(rows.get("install.exit") == "0" and rows.get("upgrade.exit") == "0", "upgrade-not-confirmed")
    if boot == 2:
        require(rows.get("rollback.exit") == "0", "rollback-not-confirmed")
    if not profile.retirement:
        if boot == 3:
            require(rows.get("failedBPreserved") == "1", "failed-generation-evidence-missing")
        return
    selected_profile(True, retirement_id)
    if boot in (2, 3):
        require(rows.get("retirement.id") == retirement_id
                and all(rows.get(key) == "1" for key in
                        ("retirementConfirmed", "currentAPreserved", "archivedBPreserved",
                         "cohortPreserved", "retirementKernelLockPreserved")),
                "retirement-evidence-missing")
    if boot == 2:
        require(rows.get("retire.exit") == "0" and rows.get("serviceStopped") == "1",
                "retirement-stop-not-confirmed")


def admit_next_operation(vm, completed_owner=None):
    # This is a diagnostic gate for this actual runner's previous completed owner,
    # never authority reconstructed from saved metadata or a PID.
    if completed_owner is None:
        initial_intent_absent(vm)
        return
    require(completed_owner.get("recordedOwnershipQualified") is True
            and completed_owner.get("kernelWriterLeaseAvailable") is True,
            "previous-owner-not-qualified")
    recorded_intent(vm, completed_owner["vmID"], completed_owner["sessionID"], "settled")
    history = read_private_json(vm / "runtime.json", 4096)
    configuration = read_private_json(vm / "configuration.json")
    require(history["sessionID"] == completed_owner["sessionID"]
            and configuration["id"] == completed_owner["vmID"]
            and terminal_guest_snapshot(history),
            "previous-owner-records-changed")


def complete_generation_owner(owner, vm, expected_vm_id, expected_session_id):
    observed = base.complete_owner(owner, vm)
    history = read_private_json(vm / "runtime.json", 4096)
    configuration = read_private_json(vm / "configuration.json")
    require(history["sessionID"] == expected_session_id and configuration["id"] == expected_vm_id,
            "owner-history-identity-changed")
    require(terminal_guest_snapshot(history), "owner-terminal-history-invalid")
    recorded_intent(vm, expected_vm_id, expected_session_id, "settled")
    require(observed.started and observed.stdout_eof and observed.stderr_eof and observed.drains_finished
            and observed.pipes_closed and observed.transcripts_closed, "owner-drains-unsettled")
    descriptor = os.open(vm / "writer.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid()
                and stat.S_IMODE(info.st_mode) == 0o600, "writer-file-invalid")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    finally:
        os.close(descriptor)
    return {"vmID": expected_vm_id, "sessionID": expected_session_id, "sameOwnerGuestStopped": True,
            "runtimeIntentProfile": "recordedSettled", "recordedOwnershipQualified": True,
            "kernelWriterLeaseAvailable": True, "stdoutEOF": True, "stderrEOF": True,
            "drainsFinished": True, "pipesClosed": True, "transcriptsClosed": True}


def preparation_arguments(marker, vm_id, profile, retirement_id=None):
    arguments = (marker, vm_id, *profile.manifest_pins, base.ROOT_UUID, base.ESP_UUID)
    if profile.retirement:
        selected_profile(True, retirement_id)
        arguments += ("retirement-v1", retirement_id)
    else:
        require(retirement_id is None, "retirement-id-without-profile")
    require(all(re.fullmatch(r"[A-Za-z0-9-]+", value) for value in arguments), "guest-argument-invalid")
    return arguments


def upload_generation_script(owner, console, marker, vm_id, profile=None, retirement_id=None):
    source = GUEST_SCRIPT.read_bytes()
    require(0 < len(source) <= 32768, "guest-script-bound")
    encoded = base64.b64encode(gzip.compress(source, mtime=0)).decode("ascii")
    for index, offset in enumerate(range(0, len(encoded), 720)):
        redirect = ">" if offset == 0 else ">>"
        owner.write(("printf '%s' '" + encoded[offset:offset + 720] + "' " + redirect
                     + "/tmp/mvo-upgrade.b64\n").encode(), deadline=time.monotonic() + 3)
        console.expect(b"localhost:~# ", 10)
    arguments = preparation_arguments(marker, vm_id, profile or historical_profile(), retirement_id)
    statement = ("base64 -d /tmp/mvo-upgrade.b64 | gzip -dc >/tmp/mvo-upgrade.sh; "
                 "test \"$(sha256sum /tmp/mvo-upgrade.sh | cut -d' ' -f1)\" = " + hashlib.sha256(source).hexdigest()
                 + " && /bin/sh /tmp/mvo-upgrade.sh prepare " + " ".join(arguments) + "\n")
    require(len(statement.encode()) <= 1024, "guest-command-bound")
    owner.write(statement.encode(), deadline=time.monotonic() + 3)
    console.line((marker + ".prepared=1").encode(), 60)


def carrier_generations(credentials, payload_a, payload_b, vm_id):
    staging = credentials / "upgrade-staging"
    image = credentials / "upgrade-support.iso"
    require(not staging.exists() and not staging.is_symlink() and not image.exists() and not image.is_symlink(),
            "carrier-path-occupied")
    staging.mkdir(mode=0o700)
    for payload, label in ((payload_a, "payload-a"), (payload_b, "payload-b")):
        directory = staging / label; directory.mkdir(mode=0o700)
        for name in ("SHA256SUMS", "agent", "initd", "setup.sh"):
            shutil.copyfile(payload / name, directory / name); (directory / name).chmod(0o600)
    enrollment = staging / "enrollment"; enrollment.mkdir(mode=0o700)
    for original, name in (("guest.pem", "cert.pem"), ("guest-key.pem", "key.pem"), ("ca.pem", "ca.pem")):
        shutil.copyfile(credentials / original, enrollment / name); (enrollment / name).chmod(0o600)
    (enrollment / "vm-id").write_text(vm_id + "\n"); (enrollment / "vm-id").chmod(0o600)
    result = subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name",
                             VOLUME_LABEL, "-o", str(image), str(staging)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=60)
    require(result.returncode == 0, "carrier-build-failed")
    image.chmod(0o600)
    return image, staging


def health_client(cli, owner, vm, credentials, vm_id, attempt, expected_version):
    request = vm / ("agent-connect-" + str(attempt) + ".request")
    require(not request.exists() and not request.is_symlink(), "stale-request")
    with request.open("xb") as stream: stream.write(b"connect\n")
    request.chmod(0o600)
    owner.expect(("mvo.host-agent.relay-ready attempt=" + str(attempt)).encode(),
                 deadline=time.monotonic() + 15, stream="stderr")
    response = subprocess.run([str(cli), "agent-tls-lab", "--socket", str(credentials / "relay.sock"),
                               "--credentials", str(credentials), "--vm-id", vm_id], capture_output=True, timeout=20)
    require(response.returncode == 0, "native-health-client-rejected")
    reply = json.loads(response.stdout); health = reply["health"]
    require(reply["nativePeerTrustVerified"] and reply["tlsVersion"] == "TLS1.3"
            and health["healthConfirmed"] and health["architecture"] == 1
            and (health["protocolMajor"], health["protocolMinor"]) == (1, 0)
            and (health["agentMajor"], health["agentMinor"], health["agentPatch"]) == expected_version,
            "authenticated-generation-unconfirmed")
    owner.expect(("mvo.host-agent.connection-finished attempt=" + str(attempt)).encode(),
                 deadline=time.monotonic() + 15, stream="stderr")
    return {"attempt": attempt, "nativeTLS13HealthValidated": True, "agentVersion": list(expected_version)}


def public_generation_carrier_catalog(image, manifest_pins=None):
    """Inspect only ISO directory metadata and the approved public manifest extent.

    No enrollment directory is traversed, and no credential content/hash is recorded.
    The guest explicitly selects this Joliet tree with the established norock recipe.
    """
    descriptor = os.open(image, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and 0 < before.st_size <= 128 << 20, "unsafe-carrier-image")

        def read(offset, count):
            require(offset >= 0 and 0 < count <= 65536 and offset + count <= before.st_size,
                    "carrier-directory-bound")
            value = os.pread(descriptor, count, offset)
            require(len(value) == count, "short-carrier-directory")
            return value

        def location(record):
            require(len(record) >= 34, "invalid-carrier-record")
            extent = int.from_bytes(record[2:6], "little")
            length = int.from_bytes(record[10:14], "little")
            require(extent == int.from_bytes(record[6:10], "big")
                    and length == int.from_bytes(record[14:18], "big"), "invalid-carrier-endian-record")
            return extent * 2048, length

        def directory(record):
            require(record[25] & 2, "carrier-entry-not-directory")
            offset, length = location(record)
            content = read(offset, length)
            cursor, found = 0, {}
            while cursor < len(content):
                size = content[cursor]
                if not size:
                    cursor = (cursor // 2048 + 1) * 2048
                    continue
                require(size >= 34 and cursor + size <= len(content), "invalid-carrier-directory-record")
                entry = content[cursor:cursor + size]
                name_size = entry[32]
                require(33 + name_size <= size, "invalid-carrier-name-bound")
                name = entry[33:33 + name_size]
                if name not in (b"\x00", b"\x01"):
                    require(name_size % 2 == 0, "invalid-carrier-joliet-name")
                    decoded = name.decode("utf-16-be")
                    require(decoded not in found and len(found) < 32, "duplicate-carrier-directory-entry")
                    found[decoded] = entry
                cursor += size
            return found

        supplementary = None
        primary_label = None
        for sector in range(16, 32):
            volume = read(sector * 2048, 2048)
            require(volume[1:6] == b"CD001" and volume[6] == 1, "invalid-carrier-volume-descriptor")
            if volume[0] == 255:
                break
            if volume[0] == 1:
                require(primary_label is None, "duplicate-primary-volume")
                primary_label = volume[40:72].decode("ascii").rstrip(" \x00")
                require(primary_label == VOLUME_LABEL, "carrier-primary-label-changed")
            if volume[0] == 2 and volume[88:91] in (b"%/@", b"%/C", b"%/E"):
                require(supplementary is None, "duplicate-joliet-volume")
                require(volume[40:72].decode("utf-16-be").rstrip(" \x00") == VOLUME_LABEL,
                        "carrier-joliet-label-changed")
                supplementary = volume
        require(primary_label is not None and supplementary is not None, "carrier-joliet-tree-absent")
        roots = directory(supplementary[156:156 + supplementary[156]])
        require(set(roots) == {"payload-a", "payload-b", "enrollment"}, "carrier-root-paths-changed")
        catalogs = []
        for label, approved_manifest in zip(("payload-a", "payload-b"), manifest_pins or MANIFEST_PINS):
            entries = directory(roots[label])
            require(set(entries) == {"SHA256SUMS", "agent", "initd", "setup.sh"}, "carrier-public-paths-changed")
            record = entries["SHA256SUMS"]
            require(not record[25] & 2, "carrier-manifest-not-file")
            offset, length = location(record)
            require(0 < length <= 512, "carrier-public-manifest-bound")
            require(hashlib.sha256(read(offset, length)).hexdigest() == approved_manifest,
                    "carrier-approved-manifest-changed")
            catalogs.append({"payload": label, "payloadPaths": sorted(entries), "manifestBytes": length,
                             "approvedManifestSHA256": approved_manifest})
        require(base.stamp(before) == base.stamp(os.fstat(descriptor)) == base.stamp(image.lstat()),
                "carrier-changed-during-catalog")
        return {"namespace": "Joliet", "volumeLabel": VOLUME_LABEL,
                "payloads": catalogs, "enrollmentTraversed": False}
    finally:
        os.close(descriptor)



def capture_session(owner, vm, vm_id):
    observed = owner.snapshot(deadline=time.monotonic() + 1)
    require(observed.started and observed.is_active and observed.first_error is None,
            "actual-owner-not-active")
    # The snapshot's terminal executable_unchanged field is populated only by
    # wait() after complete exit/drain. Compare the real executable now instead.
    require(executable_identity(owner.executable) == owner.identity, "live-owner-executable-changed")
    history = read_private_json(vm / "runtime.json")
    configuration = read_private_json(vm / "configuration.json")
    session = history["sessionID"]
    require(str(uuid.UUID(session)) == session.lower() and configuration["id"] == vm_id
            and history["snapshot"]["state"] == "running", "active-owner-identity-invalid")
    recorded_intent(vm, vm_id, session, "unsettled")
    return session


def launch_serial(owner):
    # Main-thread-only, this trial profile: ignored SIGINT is inherited across
    # exec; restore the parent's normal handler after the actual launch attempt.
    # This does not protect against SIGTERM, SIGKILL or host shutdown.
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        owner.launch()
    finally:
        signal.signal(signal.SIGINT, previous)
    return owner


def recovery_owner_snapshot(owner):
    observed = owner.snapshot(deadline=time.monotonic() + 1)
    require(observed.started and observed.is_active and observed.returncode is None
            and observed.first_error is None and not observed.transcript_truncated
            and observed.stdout_bytes == len(observed.stdout), "recovery-owner-not-active")
    require(executable_identity(owner.executable) == owner.identity, "live-owner-executable-changed")
    return observed


def recovery_session(owner, vm, vm_id):
    recovery_owner_snapshot(owner)
    history = read_private_json(vm / "runtime.json", 4096)
    configuration = read_private_json(vm / "configuration.json")
    session = history.get("sessionID")
    require(isinstance(session, str) and str(uuid.UUID(session)) == session.lower()
            and configuration.get("id") == vm_id, "recovery-owner-identity-invalid")
    snapshot = history.get("snapshot")
    require(isinstance(snapshot, dict) and snapshot.get("backendActive") is True
            and snapshot.get("outcome") == "pending"
            and ((snapshot.get("state") == "running" and snapshot.get("operation") is None)
                 or (snapshot.get("state") == "stopping" and snapshot.get("operation") == "stop")),
            "recovery-owner-state-invalid")
    recorded_intent(vm, vm_id, session, "unsettled")
    return session


def recovery_tail(raw):
    return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw).replace(b"\r", b"").split(b"\n")[-1]


class FixtureRecovery:
    """One explicit normal shutdown attempt through this actual retained object."""
    def __init__(self, owner, vm, vm_id, evidence, phase):
        require(re.fullmatch(r"installed-boot-[123]", phase), "recovery-phase-invalid")
        require(evidence.parent == ROOT / ".lab" and re.fullmatch(r"agent-upgrade-[0-9a-f]{32}", evidence.name),
                "recovery-evidence-path-invalid")
        plain_path(evidence); self.evidence_identity = base.private_directory(evidence)
        require(re.fullmatch(r"/private/tmp/agent-guest-[0-9a-f]{32}/Agent\.macopenvm", str(vm)),
                "recovery-copy-path-invalid")
        plain_path(vm); self.vm_identity = base.private_directory(vm)
        require(isinstance(vm_id, str) and str(uuid.UUID(vm_id)) == vm_id.lower(), "recovery-vm-id-invalid")
        self.owner, self.vm, self.vm_id, self.evidence, self.phase = owner, vm, vm_id, evidence, phase
        self.session = recovery_session(owner, vm, vm_id)
        self.nonce = str(uuid.uuid4())
        self.attempted = False
        self.request_file = evidence / "normal-poweroff.request.json"
        challenge_file = evidence / "recovery-challenge.json"
        require(not self.request_file.exists() and not self.request_file.is_symlink()
                and not challenge_file.exists() and not challenge_file.is_symlink(), "recovery-namespace-occupied")
        data = (json.dumps(self.challenge, sort_keys=True) + "\n").encode("ascii")
        descriptor = os.open(challenge_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())

    @property
    def challenge(self):
        return {"schemaVersion": 1, "scope": "approved-fresh-linux-fixture-normal-poweroff",
                "vmID": self.vm_id, "sessionID": self.session, "phase": self.phase,
                "nonce": self.nonce, "action": "login-root-and-poweroff"}

    def directories(self):
        plain_path(self.evidence); plain_path(self.vm)
        require(base.private_directory(self.evidence) == self.evidence_identity
                and base.private_directory(self.vm) == self.vm_identity, "recovery-directory-changed")

    def current(self, owner):
        self.directories()
        require(owner is self.owner, "recovery-foreign-owner")
        require(recovery_session(owner, self.vm, self.vm_id) == self.session, "recovery-session-changed")
        return recovery_owner_snapshot(owner)

    def prompt(self, owner, prompt, offset, *, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            observed = self.current(owner)
            if len(observed.stdout) > offset and recovery_tail(observed.stdout[offset:]) == prompt:
                return observed
            time.sleep(.05)
        require(False, "recovery-fresh-prompt-missing")

    def consume(self, owner):
        self.directories()
        if self.attempted or (not self.request_file.exists() and not self.request_file.is_symlink()):
            return False
        self.attempted = True  # An ambiguous/refused request is never retried or replaced automatically.
        request = read_private_json(self.request_file, 1024)
        require(isinstance(request, dict) and type(request.get("schemaVersion")) is int
                and request == self.challenge, "recovery-request-mismatch")
        observed = self.current(owner)
        require(recovery_tail(observed.stdout) == b"macopenvm-lab login: ", "recovery-login-not-observed")
        # Refresh the actual getty prompt after the current capture offset.
        owner.write(b"\n", deadline=time.monotonic() + 3)
        login = self.prompt(owner, b"macopenvm-lab login: ", len(observed.stdout))
        self.current(owner)
        owner.write(b"root\n", deadline=time.monotonic() + 3)
        self.prompt(owner, b"macopenvm-lab:~# ", len(login.stdout))
        self.current(owner)
        owner.write(b"poweroff\n", deadline=time.monotonic() + 3)
        return True  # Input delivery is not a guest-stop or owner-settlement receipt.


def retain_actual_owner(owner, evidence, phase, recovery=None):
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        try:
            base.save(evidence / "live-owner-retained.json", {"phase": phase, "actualOwnerRetained": True})
        except Exception:
            pass  # Failed evidence output cannot release the actual owner.
        ordinary_shell = phase == "ordinary-live-preparation"
        try:
            print("Actual copied guest owner retained. Commands: status" +
                  (" or guest poweroff." if ordinary_shell else "."), flush=True)
        except Exception:
            pass
        while True:
            try:
                observed = owner.snapshot(deadline=time.monotonic() + 1)
            except BaseException:
                time.sleep(1)
                continue  # An unreadable observation cannot release custody.
            if not observed.is_active:
                return observed
            if recovery is not None and not recovery.attempted:
                try:
                    delivered = recovery.consume(owner)
                    if delivered:
                        base.save(evidence / "recovery-input.json",
                                  {"normalPoweroffWriteConfirmed": True, "runtimeSettlementObserved": False})
                except BaseException:
                    try:
                        base.save(evidence / "recovery-input.json",
                                  {"normalPoweroffWriteConfirmed": False, "runtimeSettlementObserved": False})
                    except BaseException:
                        pass
            try:
                if select.select([sys.stdin], [], [], 1)[0]:
                    line = sys.stdin.readline().strip()
                    if line == "status":
                        value = owner.snapshot(deadline=time.monotonic() + 1)
                        print(json.dumps({"active": value.is_active, "returncode": value.returncode}), flush=True)
                    elif line == "guest poweroff" and ordinary_shell:
                        owner.write(b"poweroff\n", deadline=time.monotonic() + 3)
                    elif not line:
                        time.sleep(1)
            except BaseException:
                # SIGINT is ignored here; input/output failure preserves custody.
                time.sleep(1)
    finally:
        signal.signal(signal.SIGINT, previous)


def change_vm_selection(cli, vm, arguments, completed_owner=None):
    admit_next_operation(vm, completed_owner)
    return base.command(cli, arguments)


def publish_success(result, evidence):
    result["status"] = "passed"
    try:
        base.save(evidence / "result.json", result)
        print(json.dumps({"status": "passed", "evidence": str(evidence)}), flush=True)
    except BaseException:
        result["status"] = "failed"
        raise


def failure_owner(error, current_owner):
    # A post-spawn error carries its actual in-memory owner, never a saved PID.
    actual = getattr(error, "owner", None)
    return actual if actual is not None else current_owner


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--payload-a", type=Path)
    parser.add_argument("--payload-b", type=Path)
    parser.add_argument("--issuer")
    parser.add_argument("--credentials", type=Path)
    parser.add_argument("--retire-failed", action="store_true")
    parser.add_argument("--retirement-id")
    parser.add_argument("--recovery-request-file", action="store_true",
                        help="Allow one explicit normal-poweroff.request.json in this fresh run's private evidence directory")
    options = parser.parse_args(argv)
    if not options.run:
        print("SKIP: explicit --run required; no input, credential, copy, carrier or guest action performed.")
        return 0
    require(options.payload_a is not None and options.payload_b is not None and options.credentials is not None
            and options.issuer is not None, "explicit-generation-inputs-required")
    profile = selected_profile(options.retire_failed, options.retirement_id)
    cli, payload_a, payload_b, credentials = options.cli or profile.cli, options.payload_a, options.payload_b, options.credentials
    identity = admit_inputs(cli, payload_a, payload_b, options.issuer, credentials, profile)
    snapshot = code_snapshot()
    initial_intent_absent(SOURCE)
    configuration, source_ids, source_stamp = base.source_identity(SOURCE)
    os.umask(0o077)
    evidence = ROOT / ".lab" / ("agent-upgrade-" + uuid.uuid4().hex); evidence.mkdir(mode=0o700)
    private_root = Path("/private/tmp") / ("agent-guest-" + uuid.uuid4().hex); private_root.mkdir(mode=0o700)
    vm = private_root / "Agent.macopenvm"
    marker = "mvo-agent-upgrade-" + uuid.uuid4().hex
    owner = None; image = staging = None; completed_owner = None; phase = "fresh-copy"; recovery_vm_id = None
    result = {"status": "failed", "scope": ("experimental fresh offline Linux A/B/A retirement and cold-A proof"
              if profile.retirement else "experimental fresh offline Linux compatible-manager A/B/A proof"),
              "keysGeneratedByRunner": False, "forceStopUsed": False, "health": [], "boots": [],
              "runtimeIntentProfile": "recordedRequired", "recordedOwnershipQualified": False,
              "sourcePinsAtInvocation": snapshot, "cliSHA256": profile.cli_sha256,
              "manifestPins": list(profile.manifest_pins)}
    if profile.retirement:
        result.update(retirementID=options.retirement_id, managerSHA256=profile.manager_sha256,
                      nativeRetirementQualified=False, nextGenerationTested=False)
    base.save(evidence / "code-snapshot.json", result)
    try:
        initial_intent_absent(SOURCE)
        copied_result = json.loads(base.command(cli, ["clone", "--directory", str(SOURCE), "--destination", str(vm),
                                                     "--name", "Private agent generation proof"], timeout=180))
        copied = json.loads((vm / "configuration.json").read_text())
        require(copied_result["configuration"] == copied and copied["id"] != configuration["id"]
                and copied["macAddress"] != configuration["macAddress"]
                and base.digest(vm / "disk.raw") == source_ids["disk.raw"], "copy-identity-invalid")
        base.same_source(SOURCE, source_ids, source_stamp)
        recovery_vm_id = copied["id"]
        phase = "private-single-carrier"
        image, staging = carrier_generations(credentials, payload_a, payload_b, copied["id"])
        image_sha = base.digest(image, 128 << 20)
        result["carrierPublicCatalog"] = public_generation_carrier_catalog(image, profile.manifest_pins)
        change_vm_selection(cli, vm, ["set-linux-kernel-boot", "--directory", str(vm), "--kernel", str(ROOT / ASSETS[1][0]),
                           "--initrd", str(ROOT / ASSETS[2][0]), "--kernel-arguments", BOOT_ARGUMENTS])
        change_vm_selection(cli, vm, ["attach-media", "--directory", str(vm), "--media", str(ROOT / ASSETS[0][0])])
        phase = "ordinary-live-preparation"
        admit_next_operation(vm, completed_owner)
        owner = ManagedSerial(cli, ["run", "--directory", str(vm), "--seconds", "180"], cwd=evidence,
                              artifacts=evidence, label="prepare-copy")
        launch_serial(owner)
        console = GuestConsole(owner)
        console.expect(b"localhost login: ", 60); owner.write(b"root\n", deadline=time.monotonic() + 3)
        console.expect(b"localhost:~# ", 30)
        preparation_session = capture_session(owner, vm, copied["id"])
        upload_generation_script(owner, console, marker, copied["id"], profile, options.retirement_id)
        completed_owner = complete_generation_owner(owner, vm, copied["id"], preparation_session)
        result["preparationOwner"] = completed_owner
        require(base.guest_rows(owner, marker).get("exit") == "0", "copied-root-preparation-failed")
        change_vm_selection(cli, vm, ["set-linux-kernel-boot", "--directory", str(vm), "--kernel", configuration["kernel"],
                           "--initrd", configuration["initialRamdisk"], "--kernel-arguments", configuration["kernelArguments"]], completed_owner)
        change_vm_selection(cli, vm, ["detach-media", "--directory", str(vm)], completed_owner)
        change_vm_selection(cli, vm, ["attach-support-media", "--directory", str(vm), "--support-media", str(image)], completed_owner)
        sessions = {preparation_session}; uid_gid = None
        for boot, attempts in ((1, "1,2"), (2, "3,4"), (3, "5")):
            phase = "installed-boot-" + str(boot)
            same_code(snapshot); same_inputs(cli, payload_a, payload_b, options.issuer, credentials, identity, profile)
            base.same_source(SOURCE, source_ids, source_stamp)
            selected = json.loads((vm / "configuration.json").read_text())
            require(selected["id"] == copied["id"] and selected["macAddress"] == copied["macAddress"]
                    and selected["network"] == "disconnected" and "installationMedia" not in selected
                    and all(selected[key] == configuration[key] for key in
                            ("kernel", "initialRamdisk", "kernelArguments")), "installed-selection-changed")
            require(selected.get("supportMedia") == str(image) if boot == 1 else "supportMedia" not in selected,
                    "support-selection-changed")
            admit_next_operation(vm, completed_owner)
            owner = ManagedSerial(cli, ["run-agent-transport-lab", "--directory", str(vm), "--socket",
                                      str(credentials / "relay.sock"), "--agent-attempts", attempts, "--seconds", "180"],
                                  cwd=evidence, artifacts=evidence, label="installed-boot-" + str(boot))
            launch_serial(owner)
            prefix = marker + ".boot" + str(boot)
            owner.expect((prefix + ".ready=1").encode(), deadline=time.monotonic() + 90)
            session = capture_session(owner, vm, copied["id"])
            require(session not in sessions, "runtime-session-reused"); sessions.add(session)
            first = {1: 1, 2: 3, 3: 5}[boot]
            version = (0, 1, 1) if boot == 2 else (0, 1, 0)
            result["health"].append(health_client(cli, owner, vm, credentials, copied["id"], first, version))
            if boot != 3:
                second_ready = "upgradedReady" if boot == 1 else "rollbackReady"
                owner.expect((prefix + "." + second_ready + "=1").encode(), deadline=time.monotonic() + 45)
                result["health"].append(health_client(cli, owner, vm, credentials, copied["id"], first + 1,
                                                      (0, 1, 1) if boot == 1 else (0, 1, 0)))
            terminal = complete_generation_owner(owner, vm, copied["id"], session)
            completed_owner = terminal
            rows = generation_rows(owner, prefix)
            validate_boot_observations(rows, boot, profile, options.retirement_id)
            labels = {1: ("initialA", "upgradedB"), 2: ("coldB", "rolledA"), 3: ("coldA",)}[boot]
            processes = [base.observed_process(rows, label) for label in labels]
            for process in processes:
                current = (process["uid"], process["gid"])
                if uid_gid is None: uid_gid = current
                require(current == uid_gid, "reserved-service-identity-changed")
            result["boots"].append({"boot": boot, "observations": rows, "processes": processes, "owner": terminal})
            require(base.digest(image, 128 << 20) == image_sha, "private-carrier-changed")
            if boot == 1:
                # Actual recorded owner/history/intent/drain/lease evidence precedes media mutation.
                change_vm_selection(cli, vm, ["detach-support-media", "--directory", str(vm)], completed_owner)
        same_code(snapshot); same_inputs(cli, payload_a, payload_b, options.issuer, credentials, identity, profile)
        base.same_source(SOURCE, source_ids, source_stamp)
        result.update(sourceDiskPreserved=True, normalInstalledColdBoots=3,
                      runtimeIntentProfile="recordedSettled", recordedOwnershipQualified=True,
                      authenticatedVersions=[[0, 1, 0], [0, 1, 1], [0, 1, 1], [0, 1, 0], [0, 1, 0]],
                      sameAccountAndCredentialIdentity=True, failedBRecoveryEvidenceRetained=True)
        if profile.retirement:
            result.update(nativeRetirementQualified=True, failedBArchivedEvidenceRetained=True,
                          postRetirementColdAAuthenticated=True)
        publish_success(result, evidence)
        return 0
    except BaseException as error:
        result["status"] = "failed"
        owner = failure_owner(error, owner)
        try:
            try:
                base.same_source(SOURCE, source_ids, source_stamp)
                result["sourceDiskPreserved"] = True
            except Exception as preservation_error:
                result["sourcePreservationFailure"] = type(preservation_error).__name__
            result.update(failurePhase=phase, failureType=type(error).__name__)
            if isinstance(error, base.InstallationProofError): result["failureCode"] = str(error)
            base.save(evidence / "failure.json", result)
            print(json.dumps({"status": "failed", "phase": phase, "evidence": str(evidence)}))
        finally:
            if owner is not None:
                recovery = None
                if options.recovery_request_file and recovery_vm_id is not None:
                    try:
                        recovery = FixtureRecovery(owner, vm, recovery_vm_id, evidence, phase)
                    except BaseException:
                        pass  # Failed registration does not grant recovery or release the owner.
                settled = retain_actual_owner(owner, evidence, phase, recovery=recovery)
                if settled.started:
                    base.record_terminal_owner(owner, vm, evidence)
        return 1
    finally:
        if result["status"] == "passed" and owner is not None and not owner.snapshot(deadline=time.monotonic() + 1).is_active:
            # Only exact app-created outside-project carrier objects after complete success.
            if staging is not None: shutil.rmtree(staging)
            if image is not None: image.unlink()


if __name__ == "__main__":
    raise SystemExit(main())
