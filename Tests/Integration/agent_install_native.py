#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit installed-agent proof on a fresh private copy; never boot the source.

The caller supplies a signed generic payload, independently approved issuer pin,
and two distinct private TLS lab identities. This runner generates no key. Guest disks,
carriers and pairing material stay outside the project. Failures retain the actual
native owner; this runner never force-stops, reconstructs ownership, or retries.
"""
import argparse
import base64
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import stat
import subprocess
import sys
import time
import uuid

from alpine_live_preflight import ASSETS, BOOT_ARGUMENTS, GuestConsole
from managed_serial import ManagedSerial

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / ".lab/persistent-linux-install-e05257f1c6f24cb5bc6ad3afac75f7e6/Persistent.macopenvm"
GUEST_SCRIPT = Path(__file__).with_name("agent_install_guest.sh")
ROOT_UUID = "d162e367-e6aa-4638-955b-56e2075b5dab"
ESP_UUID = "536B-64DE"
INSTALLED_IMAGE_SHA = "27e0c04b7b7cfa4d34af20c23a3ff4d321aad83e7ab72674ebb747ba7b8a2868"
INSTALLED_INITRD_SHA = "a3789f934f54cd21f102bc1d92c04423fd3bd4d6f4315ef6b46f864a665c0c5c"


class InstallationProofError(RuntimeError):
    pass


def require(value, code):
    if not value:
        raise InstallationProofError(code)


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def digest(path, limit=16 << 30):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and before.st_uid in (0, os.geteuid()) and 0 < before.st_size <= limit,
                "unsafe-input-file")
        value = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            block = os.read(descriptor, min(1 << 20, remaining))
            require(block, "short-input-read")
            value.update(block)
            remaining -= len(block)
        require(not os.read(descriptor, 1) and stamp(before) == stamp(os.fstat(descriptor))
                == stamp(path.lstat()), "input-changed")
        return value.hexdigest()
    finally:
        os.close(descriptor)


def private_directory(path):
    require(path.is_absolute() and path == Path(os.path.abspath(path))
            and not path.is_symlink(), "unsafe-private-directory")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
            and stat.S_IMODE(info.st_mode) == 0o700, "unsafe-private-directory")
    return info.st_dev, info.st_ino


def public_credential_identity(credentials):
    """Compare public leaf fingerprints privately; never inspect a private key."""
    return {name: digest(credentials / name, 65536) for name in ("client.der", "guest.der")}


def distinct_credentials(credentials, reenrollment):
    for directory in (credentials, reenrollment):
        require(re.fullmatch(r"/private/tmp/mvo-agent-tls-[0-9a-f]{32}", str(directory)),
                "invalid-private-credentials")
    original_directory = private_directory(credentials)
    fresh_directory = private_directory(reenrollment)
    require(credentials != reenrollment and original_directory != fresh_directory,
            "reenrollment-directory-reused")
    original = public_credential_identity(credentials)
    fresh = public_credential_identity(reenrollment)
    require(all(original[name] != fresh[name] for name in original), "reenrollment-leaf-reused")
    return original_directory, fresh_directory, original, fresh


def same_credentials(credentials, reenrollment, identities):
    require(private_directory(credentials) == identities[0]
            and private_directory(reenrollment) == identities[1]
            and public_credential_identity(credentials) == identities[2]
            and public_credential_identity(reenrollment) == identities[3], "credential-input-changed")


def save(path, value):
    with path.open("x") as destination:
        json.dump(value, destination, indent=2)
        destination.write("\n")


def code_snapshot(cli):
    paths = [Path(__file__), GUEST_SCRIPT, Path(__file__).with_name("managed_serial.py"),
             Path(__file__).with_name("alpine_live_preflight.py")]
    return {"format": "agent-install-code-snapshot-v1", "cliSHA256": digest(cli, 128 << 20),
            "sources": [{"path": path.relative_to(ROOT).as_posix(), "bytes": path.stat().st_size,
                         "sha256": digest(path, 1 << 20)} for path in paths]}


def same_code(cli, snapshot):
    require(digest(cli, 128 << 20) == snapshot["cliSHA256"]
            and all(digest(ROOT / row["path"], 1 << 20) == row["sha256"] for row in snapshot["sources"]),
            "proof-code-changed")


def command(cli, arguments, timeout=60):
    process = subprocess.run([str(cli), *arguments], capture_output=True, timeout=timeout)
    require(process.returncode == 0, "protected-tool-failed")
    return process.stdout


def source_identity(source):
    require(source == SOURCE and not source.is_symlink(), "unapproved-source")
    configuration = json.loads((source / "configuration.json").read_text())
    history = json.loads((source / "runtime.json").read_text())
    require(configuration["guest"] == "linux" and configuration["backend"] == "appleVz"
            and configuration["network"] == "disconnected" and configuration["boot"] == "linuxKernel"
            and configuration["diskFile"] == "disk.raw" and configuration["diskBytes"] == 8 << 30
            and "installationMedia" not in configuration and "supportMedia" not in configuration,
            "unqualified-installed-source")
    require(configuration["kernelArguments"] == "console=hvc0 root=UUID=" + ROOT_UUID
            + " rootfstype=ext4 rootflags=ro modules=virtio_blk,virtio_mmio,ext4",
            "unqualified-installed-boot")
    require(history["snapshot"]["state"] == "stopped"
            and history["snapshot"]["outcome"] == "guestStopped", "source-not-stopped")
    require(digest(Path(configuration["kernel"]), 64 << 20) == INSTALLED_IMAGE_SHA
            and digest(Path(configuration["initialRamdisk"]), 32 << 20) == INSTALLED_INITRD_SHA,
            "installed-boot-input-changed")
    writer = os.open(source / "writer.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        identities = {name: digest(source / name) for name in
                      ("disk.raw", "configuration.json", "machine-identity.bin")}
        disk_stamp = stamp((source / "disk.raw").lstat())
    finally:
        os.close(writer)
    return configuration, identities, disk_stamp


def same_source(source, identities, disk_stamp):
    require(stamp((source / "disk.raw").lstat()) == disk_stamp
            and all(digest(source / name) == value for name, value in identities.items()),
            "source-changed")


def complete_owner(owner, vm, seconds=60):
    observed = owner.wait(deadline=time.monotonic() + seconds)
    require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
            and observed.executable_unchanged and not observed.transcript_truncated,
            "guest-owner-not-terminal")
    history = json.loads((vm / "runtime.json").read_text())
    require(history["snapshot"]["state"] == "stopped"
            and history["snapshot"]["outcome"] == "guestStopped", "guest-shutdown-unconfirmed")
    return observed


def guest_rows(owner, marker):
    raw = owner.snapshot(deadline=time.monotonic() + 1).stdout
    raw = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw).replace(b"\r", b"")
    found = {}
    prefix = (marker + ".").encode()
    for line in raw.splitlines():
        if not line.startswith(prefix):
            continue
        key, separator, value = line[len(prefix):].partition(b"=")
        require(separator and key not in found and re.fullmatch(rb"[A-Za-z0-9.]+", key)
                and re.fullmatch(rb"[A-Za-z0-9.:-]+", value), "invalid-guest-observation")
        found[key.decode("ascii")] = value.decode("ascii")
    return found


def upload_script(owner, console, marker, arguments):
    source = GUEST_SCRIPT.read_bytes()
    require(0 < len(source) <= 32768, "guest-script-bound")
    encoded = base64.b64encode(gzip.compress(source, mtime=0)).decode("ascii")
    for index, offset in enumerate(range(0, len(encoded), 720)):
        redirect = ">" if offset == 0 else ">>"
        owner.write(("printf '%s' '" + encoded[offset:offset + 720] + "' " + redirect
                     + "/tmp/mvo-install.b64\n").encode(), deadline=time.monotonic() + 3)
        console.expect(b"localhost:~# ", 10)
    script_sha = hashlib.sha256(source).hexdigest()
    statement = ("base64 -d /tmp/mvo-install.b64 | gzip -dc >/tmp/mvo-install.sh; "
                 "test \"$(sha256sum /tmp/mvo-install.sh | cut -d' ' -f1)\" = " + script_sha
                 + " && /bin/sh /tmp/mvo-install.sh prepare " + " ".join(arguments) + "\n")
    require(len(statement.encode()) <= 1024, "guest-command-bound")
    owner.write(statement.encode(), deadline=time.monotonic() + 3)
    console.line((marker + ".prepared=1").encode(), 60)


def carrier(credentials, payload, vm_id):
    staging = credentials / "installed-staging"
    require(not staging.exists(), "existing-carrier-staging")
    staging.mkdir(mode=0o700)
    generic = staging / "payload"
    enrollment = staging / "enrollment"
    generic.mkdir(mode=0o700)
    enrollment.mkdir(mode=0o700)
    for name in ("SHA256SUMS", "agent", "initd", "setup.sh"):
        shutil.copyfile(payload / name, generic / name)
        (generic / name).chmod(0o600)
    for source, name in (("guest.pem", "cert.pem"), ("guest-key.pem", "key.pem"), ("ca.pem", "ca.pem")):
        shutil.copyfile(credentials / source, enrollment / name)
        (enrollment / name).chmod(0o600)
    (enrollment / "vm-id").write_text(vm_id + "\n")
    (enrollment / "vm-id").chmod(0o600)
    image = credentials / "installed-support.iso"
    require(not image.exists(), "existing-carrier")
    result = subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet",
                             "-default-volume-name", "MVO_AGENT_INSTALL", "-o", str(image), str(staging)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    require(result.returncode == 0, "carrier-build-failed")
    image.chmod(0o600)
    return image, staging


def public_carrier_catalog(image, approved_manifest):
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
        for sector in range(16, 32):
            volume = read(sector * 2048, 2048)
            require(volume[1:6] == b"CD001" and volume[6] == 1, "invalid-carrier-volume-descriptor")
            if volume[0] == 255:
                break
            if volume[0] == 2 and volume[88:91] in (b"%/@", b"%/C", b"%/E"):
                require(supplementary is None, "duplicate-joliet-volume")
                supplementary = volume
        require(supplementary is not None, "carrier-joliet-tree-absent")
        roots = directory(supplementary[156:156 + supplementary[156]])
        require("payload" in roots, "carrier-public-payload-absent")
        entries = directory(roots["payload"])
        require(set(entries) == {"SHA256SUMS", "agent", "initd", "setup.sh"}, "carrier-public-paths-changed")
        record = entries["SHA256SUMS"]
        require(not record[25] & 2, "carrier-manifest-not-file")
        offset, length = location(record)
        require(0 < length <= 512, "carrier-public-manifest-bound")
        require(hashlib.sha256(read(offset, length)).hexdigest() == approved_manifest,
                "carrier-approved-manifest-changed")
        require(stamp(before) == stamp(os.fstat(descriptor)) == stamp(image.lstat()), "carrier-changed-during-catalog")
        return {"namespace": "Joliet", "escapeSequenceHex": supplementary[88:91].hex(),
                "payloadPaths": sorted(entries), "manifestBytes": length,
                "approvedManifestSHA256": approved_manifest, "enrollmentTraversed": False}
    finally:
        os.close(descriptor)


def observed_process(rows, prefix):
    require(all(rows.get(prefix + "." + key) == expected for key, expected in
                (("capEff", "0000000000000000"), ("noNewPrivs", "1"), ("openssl", "3.5.9"), ("nic", "lo"))),
            "unqualified-service-process")
    values = {key: int(rows[prefix + "." + key]) for key in ("pid", "uid", "gid")}
    require(all(value > 0 for value in values.values()), "privileged-service-process")
    return values


def health_client(cli, owner, vm, credentials, configuration, attempt, results):
    request = vm / ("agent-connect-" + str(attempt) + ".request")
    require(not request.exists() and not request.is_symlink(), "stale-request")
    with request.open("xb") as stream:
        stream.write(b"connect\n")
    request.chmod(0o600)
    owner.expect(("mvo.host-agent.relay-ready attempt=" + str(attempt)).encode(),
                 deadline=time.monotonic() + 15, stream="stderr")
    response = subprocess.run([str(cli), "agent-tls-lab", "--socket", str(credentials / "relay.sock"),
                               "--credentials", str(credentials), "--vm-id", configuration["id"]],
                              capture_output=True, timeout=20)
    require(response.returncode == 0, "native-health-client-rejected")
    health = json.loads(response.stdout)
    require(health["nativePeerTrustVerified"] and health["tlsVersion"] == "TLS1.3"
            and health["health"]["healthConfirmed"] and health["health"]["architecture"] == 1,
            "native-health-unconfirmed")
    owner.expect(("mvo.host-agent.connection-finished attempt=" + str(attempt)).encode(),
                 deadline=time.monotonic() + 15, stream="stderr")
    results.append({"attempt": attempt, "nativeTLS13HealthValidated": True, "guestUID": None})


def refused_client(owner, vm, attempt):
    request = vm / ("agent-connect-" + str(attempt) + ".request")
    require(not request.exists() and not request.is_symlink(), "stale-uninstall-request")
    require(owner.snapshot(deadline=time.monotonic() + 1).is_active
            and json.loads((vm / "runtime.json").read_text())["snapshot"]["state"] == "running",
            "refusal-guest-not-running")
    with request.open("xb") as stream:
        stream.write(b"connect\n")
    request.chmod(0o600)
    owner.expect(("mvo.host-agent.connection-closed-with-error attempt=" + str(attempt)).encode(),
                 deadline=time.monotonic() + 12, stream="stderr")
    owner.expect(("mvo.host-agent.connection-finished attempt=" + str(attempt)).encode(),
                 deadline=time.monotonic() + 3, stream="stderr")
    require(("mvo.host-agent.relay-ready attempt=" + str(attempt)).encode() not in
            owner.snapshot(deadline=time.monotonic() + 1).stderr, "uninstalled-listener-still-admitted")
    require(owner.snapshot(deadline=time.monotonic() + 1).is_active
            and json.loads((vm / "runtime.json").read_text())["snapshot"]["state"] == "running",
            "refusal-guest-stopped")


def preserve_live_owner(owner, evidence, phase):
    snapshot = owner.snapshot(deadline=time.monotonic() + 1)
    if not snapshot.is_active:
        return
    save(evidence / "live-owner-retained.json", {"phase": phase, "actualOwnerRetained": True})
    ordinary_live_shell = phase == "ordinary-live-preparation"
    print("Live copied guest owner retained. Commands: status"
          + (" or guest poweroff." if ordinary_live_shell else "."), flush=True)
    while owner.snapshot(deadline=time.monotonic() + 1).is_active:
        if select.select([sys.stdin], [], [], 1)[0]:
            line = sys.stdin.readline().strip()
            if line == "status":
                value = owner.snapshot(deadline=time.monotonic() + 1)
                print(json.dumps({"active": value.is_active, "returncode": value.returncode}), flush=True)
            elif line == "guest poweroff" and ordinary_live_shell:
                owner.write(b"poweroff\n", deadline=time.monotonic() + 3)
            elif not line:
                time.sleep(1)


def record_terminal_owner(owner, vm, evidence):
    """Record settled observation after any transient retained-owner notice.

    These facts never authorize reconstructing a process from a saved identifier.
    """
    snapshot = owner.snapshot(deadline=time.monotonic() + 1)
    require(not snapshot.is_active, "owner-still-active")
    snapshot = owner.wait(deadline=time.monotonic() + 2)
    history = json.loads((vm / "runtime.json").read_text())["snapshot"]
    save(evidence / "owner-terminal.json", {
        "actualOwnerActive": snapshot.is_active, "returncode": snapshot.returncode,
        "stdoutEOF": snapshot.stdout_eof, "stderrEOF": snapshot.stderr_eof,
        "drainsFinished": snapshot.drains_finished, "pipesClosed": snapshot.pipes_closed,
        "transcriptsClosed": snapshot.transcripts_closed,
        "transcriptTruncated": snapshot.transcript_truncated,
        "executableUnchanged": snapshot.executable_unchanged,
        "guestState": history["state"], "guestOutcome": history.get("outcome"),
        "privateVMRetained": str(vm), "forceStopUsed": False,
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--payload", required=True, type=Path)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--credentials", required=True, type=Path)
    parser.add_argument("--reenrollment-credentials", required=True, type=Path,
                        help="Separate caller-supplied fresh private TLS identity for boot three.")
    options = parser.parse_args()
    if not options.run:
        print("SKIP: explicit --run required; no copy, VM, carrier or credential action performed.")
        return 0
    cli, payload, credentials = options.cli.absolute(), options.payload.absolute(), options.credentials.absolute()
    reenrollment = options.reenrollment_credentials.absolute()
    require(re.fullmatch(r"[0-9a-f]{64}", options.issuer), "invalid-approved-issuer")
    credential_identities = distinct_credentials(credentials, reenrollment)
    os.umask(0o077)
    evidence = ROOT / ".lab" / ("agent-install-" + uuid.uuid4().hex)
    evidence.mkdir(mode=0o700)
    private_root = Path("/private/tmp") / ("agent-guest-" + uuid.uuid4().hex)
    private_root.mkdir(mode=0o700)
    vm = private_root / "Agent.macopenvm"
    marker = "mvo-agent-install-" + uuid.uuid4().hex
    owner = None
    image = staging = None
    carriers = []
    identities = disk_stamp = None
    phase = "approved-inputs"
    result = {"scope": "fresh private installed Linux agent proof; no Windows or product installer UI proof",
              "status": "failed", "sourceDiskPreserved": False, "keysGeneratedByRunner": False,
              "credentialsOutsideProject": True, "forceStopUsed": False, "health": [],
              "reenrollmentPublicLeavesDistinct": True}
    try:
        snapshot = code_snapshot(cli)
        cli_sha = snapshot["cliSHA256"]
        save(evidence / "code-snapshot.json", snapshot)
        configuration, identities, disk_stamp = source_identity(SOURCE)
        result["sourceDiskSHA256"] = identities["disk.raw"]
        require(os.stat(private_root).st_dev == os.stat(SOURCE).st_dev, "copy-not-same-volume")
        protected_assets = {name: checksum for name, _, checksum in ASSETS}
        require(all(digest(ROOT / name) == expected for name, expected in protected_assets.items()), "live-input-changed")
        verification = json.loads(command(cli, ["verify-agent-package-lab", "--directory", str(payload),
                                               "--issuer", options.issuer]))
        require(verification["filesVerified"] == 3 and verification["issuerSHA256"] == options.issuer,
                "publisher-verification-failed")
        pin = verification["manifestSHA256"]
        require(re.fullmatch(r"[0-9a-f]{64}", pin), "invalid-verified-manifest")
        result["signedPackage"] = verification
        phase = "protected-fresh-copy"
        copy = json.loads(command(cli, ["clone", "--directory", str(SOURCE), "--destination", str(vm),
                                      "--name", "Private installed agent proof"], timeout=180))
        copied = json.loads((vm / "configuration.json").read_text())
        require(copy["configuration"] == copied and copied["id"] != configuration["id"]
                and copied["macAddress"] != configuration["macAddress"]
                and digest(vm / "disk.raw") == identities["disk.raw"], "copy-identity-failed")
        result["copiedIdentityDistinct"] = True
        same_source(SOURCE, identities, disk_stamp)
        phase = "carrier-public-path-preflight"
        image, staging = carrier(credentials, payload, copied["id"])
        carriers.append((image, staging))
        image_sha = digest(image)
        result["carrierPublicCatalog"] = public_carrier_catalog(image, pin)
        save(evidence / "carrier-public-catalog.json", result["carrierPublicCatalog"])
        phase = "stock-live-boot-selection"
        command(cli, ["set-linux-kernel-boot", "--directory", str(vm), "--kernel", str(ROOT / ASSETS[1][0]),
                      "--initrd", str(ROOT / ASSETS[2][0]), "--kernel-arguments", BOOT_ARGUMENTS])
        command(cli, ["attach-media", "--directory", str(vm), "--media", str(ROOT / ASSETS[0][0])])
        owner = ManagedSerial(cli, ["run", "--directory", str(vm), "--seconds", "180"],
                              cwd=evidence, artifacts=evidence, label="prepare-copy").launch()
        console = GuestConsole(owner)
        phase = "ordinary-live-preparation"
        console.expect(b"localhost login: ", 60)
        owner.write(b"root\n", deadline=time.monotonic() + 3)
        console.expect(b"localhost:~# ", 30)
        upload_script(owner, console, marker, [marker, copied["id"], pin, ROOT_UUID, ESP_UUID])
        complete_owner(owner, vm)
        require(guest_rows(owner, marker).get("exit") == "0", "copied-root-preparation-failed")
        phase = "restore-normal-installed-boot"
        command(cli, ["set-linux-kernel-boot", "--directory", str(vm), "--kernel", configuration["kernel"],
                      "--initrd", configuration["initialRamdisk"], "--kernel-arguments", configuration["kernelArguments"]])
        command(cli, ["detach-media", "--directory", str(vm)])
        command(cli, ["attach-support-media", "--directory", str(vm), "--support-media", str(image)])
        for boot, attempts in ((1, "1,2,3,4"), (2, "5,6,7"), (3, "8")):
            same_code(cli, snapshot)
            same_credentials(credentials, reenrollment, credential_identities)
            active_credentials = credentials
            if boot == 3:
                phase = "reenrollment-carrier-public-path-preflight"
                image, staging = carrier(reenrollment, payload, copied["id"])
                carriers.append((image, staging))
                image_sha = digest(image)
                result["reenrollmentCarrierPublicCatalog"] = public_carrier_catalog(image, pin)
                save(evidence / "reenrollment-carrier-public-catalog.json", result["reenrollmentCarrierPublicCatalog"])
                command(cli, ["attach-support-media", "--directory", str(vm), "--support-media", str(image)])
                active_credentials = reenrollment
            phase = "installed-cold-boot-" + str(boot)
            selected = json.loads((vm / "configuration.json").read_text())
            require(selected["kernel"] == configuration["kernel"]
                    and selected["initialRamdisk"] == configuration["initialRamdisk"]
                    and selected["kernelArguments"] == configuration["kernelArguments"]
                    and selected["network"] == "disconnected" and "installationMedia" not in selected,
                    "installed-boot-selection-changed")
            if boot == 2:
                require("supportMedia" not in selected, "cold-boot-carrier-still-attached")
            else:
                require(selected.get("supportMedia") == str(image), "installed-carrier-selection-changed")
            owner = ManagedSerial(cli, ["run-agent-transport-lab", "--directory", str(vm),
                                       "--socket", str(active_credentials / "relay.sock"), "--agent-attempts", attempts,
                                       "--seconds", "180"], cwd=evidence, artifacts=evidence,
                                  label="installed-boot-" + str(boot)).launch()
            prefix = marker + ".boot" + str(boot)
            owner.expect((prefix + ".ready=1").encode(), deadline=time.monotonic() + 90)
            first = {1: 1, 2: 5, 3: 8}[boot]
            health_client(cli, owner, vm, active_credentials, copied, first, result["health"])
            if boot == 2:
                owner.expect((prefix + ".restartReady=1").encode(), deadline=time.monotonic() + 30)
            if boot != 3:
                health_client(cli, owner, vm, active_credentials, copied, first + 1, result["health"])
            if boot == 1:
                owner.expect((prefix + ".keptCredentials=1").encode(), deadline=time.monotonic() + 30)
                refused_client(owner, vm, 3)
                result["connectionRefusedAfterRetainedUninstall"] = True
                owner.expect((prefix + ".reinstalledReady=1").encode(), deadline=time.monotonic() + 30)
                health_client(cli, owner, vm, credentials, copied, 4, result["health"])
            if boot == 2:
                owner.expect((prefix + ".uninstalled=1").encode(), deadline=time.monotonic() + 30)
                refused_client(owner, vm, 7)
                result["connectionRefusedAfterUninstall"] = True
            complete_owner(owner, vm)
            rows = guest_rows(owner, prefix)
            require(rows.get("exit") == "0" and rows.get("normalRoot") == "1"
                    and rows.get("accountsPreserved") == "1", "installed-guest-observation-failed")
            labels = {1: ("started", "reconnected", "reinstalled"),
                      2: ("cold", "restarted"), 3: ("reenrolled",)}[boot]
            processes = [observed_process(rows, label) for label in labels]
            require(all(processes[0]["uid"] == process["uid"]
                        and processes[0]["gid"] == process["gid"] for process in processes),
                    "service-identity-changed")
            if boot == 1:
                require(rows.get("reconnect") == "1" and processes[0]["pid"] == processes[1]["pid"]
                        and all(rows.get(key) == "1" for key in
                                ("supportDrivers", "supportReadOnly", "signedCarrierManifest", "payloadBytesVerified",
                                 "keptCredentials", "enrollmentPreservedAfterReinstall", "reinstalledReady"))
                        and processes[0]["pid"] != processes[2]["pid"]
                        and all(rows.get(label + ".exit") == "0" for label in ("install", "keepUninstall", "reinstall")),
                        "live-reconnect-unconfirmed")
                first_uid = processes[0]["uid"]
                first_gid = processes[0]["gid"]
                require(digest(image) == image_sha, "per-vm-carrier-changed")
                command(cli, ["detach-support-media", "--directory", str(vm)])
            elif boot == 2:
                require(processes[0]["uid"] == first_uid and processes[0]["gid"] == first_gid
                        and rows.get("discsAbsent") == "1"
                        and processes[0]["pid"] != processes[1]["pid"]
                        and rows.get("accountsPreservedAfterUninstall") == "1"
                        and rows.get("sentinelPreserved") == "1" and rows.get("accountLockedNonlogin") == "1"
                        and rows.get("enrollmentPreservedOnColdBoot") == "1"
                        and rows.get("enrollmentPreservedAfterRestart") == "1"
                        and rows.get("removeUninstall.exit") == "0" and rows.get("reservationRemoved") == "1",
                        "cold-restart-uninstall-unconfirmed")
            else:
                require(processes[0]["uid"] == first_uid and processes[0]["gid"] == first_gid
                        and all(rows.get(key) == "1" for key in
                                ("supportDrivers", "supportReadOnly", "signedCarrierManifest", "payloadBytesVerified",
                                 "reservationRemovedBeforeReenroll", "reservationInstalledAfterReenroll",
                                 "freshEnrollmentDistinct", "accountsPreservedAfterUninstall", "sentinelPreserved",
                                 "accountLockedNonlogin", "uninstalled", "reservationRemovedAfterReenroll"))
                        and all(rows.get(label + ".exit") == "0" for label in ("reenroll", "reenrollRemoveUninstall")),
                        "fresh-reenrollment-unconfirmed")
                require(digest(image) == image_sha, "reenrollment-carrier-changed")
                command(cli, ["detach-support-media", "--directory", str(vm)])
                result["freshEnrollmentNativeTLS13HealthValidated"] = True
                result["reenrollmentSameReservedAccount"] = True
                result["credentialsRemovedAfterReenrollment"] = True
            for row, process in zip(result["health"][-len(processes):], processes):
                row["guestUID"] = process["uid"]
            result["boot" + str(boot)] = {"observations": rows, "processes": processes, "normalShutdown": True}
        phase = "source-preservation"
        same_code(cli, snapshot)
        same_source(SOURCE, identities, disk_stamp)
        require(digest(cli, 128 << 20) == cli_sha
                and all(digest(ROOT / name) == expected for name, expected in protected_assets.items()),
                "protected-input-changed")
        same_credentials(credentials, reenrollment, credential_identities)
        result.update(status="passed", sourceDiskPreserved=True, normalColdBoots=3,
                      callerCLI_SHA256=cli_sha, runnerSHA256=digest(Path(__file__), 1 << 20),
                      guestScriptSHA256=digest(GUEST_SCRIPT, 1 << 20), outsideProjectVM=str(vm),
                      authBypassUsed=False, keysInProject=False, signedGenericPayloadVerified=True)
        save(evidence / "result.json", result)
        print(json.dumps({"evidence": str(evidence), "status": "passed", "privateVMRetained": str(vm)}), flush=True)
        return 0
    except Exception as error:
        result.update(failurePhase=phase, failureType=type(error).__name__)
        result["privateCarrierPreserved"] = any(image.exists() for image, _ in carriers)
        if isinstance(error, InstallationProofError):
            result["failureCode"] = str(error)
        if identities is not None and disk_stamp is not None:
            try:
                same_source(SOURCE, identities, disk_stamp)
                result["sourceDiskPreserved"] = True
            except Exception as preservation_error:
                result["sourcePreservationFailure"] = type(preservation_error).__name__
        save(evidence / "failure.json", result)
        print(json.dumps({"evidence": str(evidence), "phase": phase, "status": "failed"}), flush=True)
        if owner is not None:
            preserve_live_owner(owner, evidence, phase)
            record_terminal_owner(owner, vm, evidence)
        return 1
    finally:
        if result["status"] == "passed" and (owner is None or not owner.snapshot(deadline=time.monotonic() + 1).is_active):
            for image, staging in carriers:
                if staging.exists():
                    shutil.rmtree(staging)
                if image.exists():
                    image.unlink()


if __name__ == "__main__":
    raise SystemExit(main())
