#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Staged disposable Linux installation and disc-detached cold-boot qualification.

The prerequisite stage deliberately ends before GPT/root mutation. Its records
qualify the actual filesystem tools and packaged service inputs for the subsequent
new-target install/cold-boot stage. Existing fixtures are never accepted as targets.
"""
import argparse
import base64
import fcntl
import hashlib
import gzip
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import time
import uuid

from alpine_live_preflight import (
    ROOT, ASSETS, BOOT_ARGUMENTS, DISK_BYTES, ZERO_SHA, GuestConsole, PreflightFailure,
    cleanup_actual, inspect_blank_disk, read_json, run_tool, safe_directory, save,
    stable_file, status, verify_guest_rows, writer_available,
)
from managed_serial import ManagedSerial
from support_media_live import (
    DeliveryFailure, TOOLS_PATH, apk_inventory, guest_value, preparation_bounds,
    prepare_apk_root, prepare_apk_tools, require, simulate_apks, simulation_blob,
    verify_apks, verify_inputs,
)

HELPERS = {
    "support_media_live.py": "44701fc2c0142863b024a769c9e5712291f93335c16a6999ef25f97cdb232f4f",
    "alpine_live_preflight.py": "b07af3c02ed377fe3c73149dbcab188b9da7e2ab27bc8f674593a6362cc531f1",
    "managed_serial.py": "3083cb626c9f0c2df62b9792ffed6166ae52c3a0a504a1dce932a9ee317ebb2d",
}
SERVICES = ROOT / ".lab/persistent-service-metadata-5a86f8a4c02d4ad9a1216bb1df2c812e"
SERVICES_SHA = "5b93045e0887bd02598e5472fd275c650a5f0e0424909dac9262e220c9cdebac"
IMAGE = ROOT / ".lab/alpine-kernel-0a18c0a17648476589503adca6e5bc16/Image"
IMAGE_SHA = "27e0c04b7b7cfa4d34af20c23a3ff4d321aad83e7ab72674ebb747ba7b8a2868"
GENERATED = ROOT / ".lab/support-media-live-f26f1e3ac5c0441ebd001328cec2cfda"
ARCHIVE_SHA = "a3789f934f54cd21f102bc1d92c04423fd3bd4d6f4315ef6b46f864a665c0c5c"
SERVICE_PATHS = (
    "etc/init.d/devfs", "etc/init.d/sysfs", "etc/init.d/dmesg", "etc/init.d/mdev",
    "etc/init.d/hwdrivers", "etc/init.d/modules", "etc/init.d/fsck", "etc/init.d/root",
    "etc/init.d/localmount", "etc/init.d/hostname", "etc/init.d/sysctl", "etc/init.d/bootmisc",
    "etc/init.d/local", "etc/init.d/killprocs", "etc/init.d/mount-ro", "etc/inittab",
    "etc/securetty",
)


CANONICAL_PATHS = ("/bin/mkdir", "/bin/cpio", "/usr/bin/awk", "/usr/bin/find", "/usr/bin/sort", "/usr/bin/install")
TOOL_QUERIES = {"sfdisk": ("--version", "sfdisk", "2.42.3"), "mkfs.ext4": ("-V", "mke2fs", "1.47.4"),
                "e2fsck": ("-V", "e2fsck", "1.47.4"), "mkfs.fat": ("--help", "mkfs.fat", "4.2"),
                "openrc": ("--version", "openrc (OpenRC)", "0.63.2")}


def parse_prerequisite_log(log, service_rows):
    require(isinstance(log, bytes) and len(log) <= 32768
            and all(byte in (9, 10) or 32 <= byte <= 126 for byte in log), "apkToolsObservation")
    lines = log.decode("ascii").splitlines()
    prefix, rows, positions, tools, canonical, initial, hashes = "mvo-persistent.", {}, {}, {}, {}, None, {}
    allowed = {"tools", "canonical", "services"} | {"output." + name + ".begin" for name in TOOL_QUERIES}
    allowed |= {"rc." + name for name in TOOL_QUERIES}
    for index, line in enumerate(lines):
        if line.startswith(prefix):
            key, separator, value = line[len(prefix):].partition("=")
            require(separator and key in allowed and key not in rows and 0 < len(value) <= 256, "apkToolsObservation")
            rows[key], positions[key] = value, index
        elif line.startswith("TOOL:"):
            name, separator, value = line[5:].partition("=")
            require(separator and name in TOOL_QUERIES and name not in tools
                    and value in tuple(parent + "/" + name for parent in ("/sbin", "/usr/sbin", "/bin", "/usr/bin")), "apkToolsObservation")
            tools[name] = dict(path=value)
        elif line.startswith("CANONICAL:"):
            path, separator, value = line[10:].partition("=")
            require(separator and path in CANONICAL_PATHS and path not in canonical, "apkToolsObservation")
            canonical[path] = value
        elif line.startswith("INIT:"):
            path, separator, value = line[5:].partition("=")
            require(separator and path == "/sbin/init" and initial is None, "apkToolsObservation")
            initial = value
        elif re.match(r"^[0-9a-f]{64}  /etc/", line):
            digest, path = line.split("  /", 1)
            require(path in SERVICE_PATHS and path not in hashes, "apkToolsObservation")
            hashes[path] = digest
    require(set(rows) == allowed and set(tools) == set(TOOL_QUERIES)
            and set(canonical) == set(CANONICAL_PATHS) and initial is not None, "apkToolsObservation")
    require(all(rows[key] in ("0", "1") for key in ("tools", "canonical", "services")), "apkToolsObservation")
    versions_match = True
    for name, (query, banner, version) in TOOL_QUERIES.items():
        begin, end = "output." + name + ".begin", "rc." + name
        code = rows[end]
        require(rows[begin] == "1" and re.fullmatch(r"[0-9]{1,3}", code) and int(code) <= 255
                and positions[begin] < positions[end], "apkToolsObservation")
        output = "\n".join(lines[positions[begin] + 1:positions[end]])
        seen = re.search(r"(?m)^" + re.escape(banner) + r"[^\n]*\b" + re.escape(version) + r"\b", output)
        tools[name].update(exitStatus=int(code), queryKind="help-banner" if query == "--help" else "version",
                           version=version if seen else None, output=output)
        versions_match = versions_match and code == "0" and seen is not None
    def observation(path, value):
        if value == "missing":
            return dict(kind="missing", executable=False, linkTarget=None)
        if value in ("regular:0", "regular:1"):
            return dict(kind="regular", executable=value.endswith("1"), linkTarget=None)
        require(value.startswith("symlink:0:"), "apkToolsObservation")
        target, parts = value[10:], [] if value[10:].startswith("/") else path.split("/")[1:-1]
        for part in target.split("/"):
            if part == "..":
                require(bool(parts), "apkToolsObservation"); parts.pop()
            elif part not in ("", "."):
                parts.append(part)
        require(parts == ["bin", "busybox"], "apkToolsObservation")
        return dict(kind="symlink", executable=True, linkTarget=target)
    canonical = {path: observation(path, value) for path, value in canonical.items()}
    initial = observation("/sbin/init", initial)
    canonical_ready = initial["executable"] and all(row["executable"] for row in canonical.values())
    service_match = set(hashes) == set(SERVICE_PATHS) and all(hashes[path] == service_rows[path]["sha256"] for path in hashes)
    return dict(tools=tools, canonical=canonical, init=initial, serviceHashesMatch=service_match,
                toolVersionsMatch=bool(versions_match), canonicalPersistentBootLinksReady=bool(canonical_ready),
                probeQualified=bool(versions_match and service_match and rows["tools"] == rows["services"] == "0"),
                statuses={key: int(rows[key]) for key in ("tools", "canonical", "services")})


def source_inputs(options):
    for name, digest in HELPERS.items():
        stable_file(Path(__file__).with_name(name), limit=131072, expected_sha=digest)
    candidate, carrier, source_identity = verify_inputs(options)
    preparation_bounds(options, carrier)
    safe_directory(SERVICES, private=True)
    service = read_json(SERVICES / "service-metadata-result.json", maximum=65536, expected_sha=SERVICES_SHA)
    require(service["status"] == "passed" and service["manifestSHA256"]
            == "5756d984a22517c2b6313b3643cf58d6151944b4a9c10e67894d4c0e0e5f599a", "initramfsMetadata")
    by_path = {row["path"]: row for row in service["selected"]}
    for path in SERVICE_PATHS:
        require(path in by_path and by_path[path]["type"] == "regular", "initramfsMetadata")
    for row in service["selected"]:
        if row["path"] == "etc/shadow":
            require("savedBasename" not in row and service["shadowContentCollected"] is False, "initramfsMetadata")
            continue
        require(row["type"] == "regular" and "savedBasename" in row, "initramfsMetadata")
        require(re.fullmatch(r"selected-[0-9]{3}\.txt", row["savedBasename"]), "initramfsMetadata")
        stable_file(SERVICES / row["savedBasename"], limit=32768,
                    expected_bytes=row["size"], expected_sha=row["sha256"])
    safe_directory(IMAGE.parent, private=True)
    safe_directory(GENERATED, private=True)
    image = stable_file(IMAGE, limit=64 << 20, expected_bytes=36306944, expected_sha=IMAGE_SHA)[:2]
    archive = stable_file(GENERATED / "generated-initramfs.gz", limit=32 << 20,
                         expected_bytes=9545016, expected_sha=ARCHIVE_SHA)[:2]
    generation = read_json(GENERATED / "delivery-result.json", maximum=65536,
        expected_sha="0c6f36df92b7e4807ef9a09ea0f81943effee228fbbe2780cdbb798fb51ab6c9")
    require(generation["status"] == "passed" and generation["archiveInspection"]["closureComplete"] is True
            and generation["retainedArchiveSHA256"] == ARCHIVE_SHA, "initramfsSource")
    # Historical archive provenance is independent of the newly selected production candidate.
    return candidate, carrier, (source_identity, image, archive), by_path


def send(console, owner, marker, command, key, expected, seconds=30):
    require(console.queries <= 62 and len(command.encode()) <= 1024, "cursorBudget")
    owner.write(command.encode(), deadline=time.monotonic() + 3)
    console.line((marker + "." + key + "=" + expected).encode(), seconds)
    console.expect(b"localhost:~# ", 10)


def writer_busy(directory):
    path = directory / "writer.lock"
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        stamp = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid() and st.st_nlink == 1
                and stat.S_IMODE(st.st_mode) == 0o600 and stamp(st) == stamp(path.lstat()), "initramfsSource")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            require(stamp(st) == stamp(os.fstat(fd)) == stamp(path.lstat()), "initramfsSource")
            return
        raise DeliveryFailure("initramfsSource")
    finally:
        os.close(fd)


def probe_prerequisites(console, owner, marker, artifacts, result, facts, service_rows):
    result.update(persistentToolProbeRequested=True, persistentToolProbeComplete=False)
    if not result["apkToolsPreparationComplete"] or console.queries > 57:
        result["persistentToolProbeSkipped"] = "ram-root-or-cursor-prerequisite"
        return
    tools = (
        'r=0; for c in sfdisk mkfs.ext4 e2fsck mkfs.fat openrc; do p=$(command -v "$c"); s=$?; '
        '[ "$s" -eq 0 ] && [ -n "$p" ] || r=1; printf "TOOL:%s=%s\\n" "$c" "$p"; done; '
        'q() { printf "mvo-persistent.output.%s.begin=1\\n" "$1"; c=$1; shift; "$c" "$@"; s=$?; '
        '[ "$s" -eq 0 ] || r=1; printf "mvo-persistent.rc.%s=%s\\n" "$c" "$s"; }; '
        'q sfdisk --version; q mkfs.ext4 -V; q e2fsck -V; q mkfs.fat --help; q openrc --version; '
        'printf "mvo-persistent.tools=%s\\n" "$r"; exit "$r"')
    canonical = (
        'inv() { v=missing; if [ -L "$2" ]; then t=$(readlink "$2"); s=$?; v="symlink:$s:$t"; '
        'elif [ -f "$2" ]; then x=0; [ ! -x "$2" ] || x=1; v="regular:$x"; fi; '
        'printf "%s:%s=%s\\n" "$1" "$2" "$v"; }; '
        'inv INIT /sbin/init; for p in ' + " ".join(CANONICAL_PATHS) + '; do inv CANONICAL "$p"; done; '
        'printf "mvo-persistent.canonical=0\\n"')
    services = (
        'r=0; '
        'for p in ' + " ".join(SERVICE_PATHS) + '; do '
        'if [ -f "/$p" ] && [ ! -L "/$p" ]; then n=$(wc -c <"/$p"); s=$?; '
        '[ "$s" -eq 0 ] && [ "$n" -le 32768 ] || r=1; sha256sum "/$p" || r=1; '
        'else r=1; printf "MISSING:%s\\n" "$p"; fi; done; '
        'printf "mvo-persistent.services=%s\\n" "$r"; exit "$r"')
    codes = []
    for key, script, redirect in (("persistentTools", tools, ">"), ("persistentCanonical", canonical, ">>"),
                                  ("persistentServices", services, ">>")):
        command = (
            f'(ulimit -f 32 || exit 125; /bin/busybox env -i PATH={TOOLS_PATH} LC_ALL=C '
            f'/bin/busybox chroot "$mvo_ram" /bin/sh -c \'{script}\') '
            f'{redirect}"$mvo_dir/persistent-prerequisites.log" 2>&1; mvo_pr=$?; '
            f'mvo_pf {key}Exit "$mvo_pr"; mvo_pf {key}Done 1\n')
        send(console, owner, marker, command, key + "Done", "1", seconds=60)
        code = guest_value(console, marker, key + "Exit")
        require(re.fullmatch(r"[0-9]{1,3}", code) and int(code) <= 255, "apkToolsObservation")
        facts.update({key + "Exit": code, key + "Done": "1"})
        codes.append(int(code))
    log = simulation_blob(console, owner, marker, "persistentProbeLog", '"$mvo_dir/persistent-prerequisites.log"',
                          32768, facts, artifacts, sender=send, dynamic_markers=True)
    result.update(persistentToolProbeExitStatuses=codes, persistentProbeLogBytes=len(log),
                  persistentToolProbeLogSHA256=hashlib.sha256(log).hexdigest(),
                  persistentToolProbeComplete=False, canonicalPersistentBootLinksReady=False,
                  persistentBootPrerequisitesComplete=False,
                  persistentServiceMetadataSHA256=SERVICES_SHA)
    try:
        parsed = parse_prerequisite_log(log, service_rows)
        result.update(persistentPrerequisiteObservations=parsed,
                      persistentToolProbeComplete=codes == [0, 0, 0] and parsed["probeQualified"],
                      canonicalPersistentBootLinksReady=parsed["canonicalPersistentBootLinksReady"])
    except DeliveryFailure as error:
        result["persistentPrerequisiteObservationFailure"] = error.code


def install_commands(script, marker, root_uuid):
    """Bounded compressed transfer into guest tmpfs; no shell interpolation of data."""
    require(re.fullmatch(r"mvo-support-[0-9a-f]{32}", marker)
            and str(uuid.UUID(root_uuid)) == root_uuid and 0 < len(script) <= 16384, "initramfsSource")
    encoded = base64.b64encode(gzip.compress(script, mtime=0)).decode("ascii")
    require(len(encoded) <= 5 * 840, "cursorBudget")
    commands = []
    for offset in range(0, len(encoded), 840):
        key = "installUpload" + str(offset // 840)
        redirect = ">" if offset == 0 else ">>"
        command = (f"printf '%s' '{encoded[offset:offset + 840]}' {redirect}\"$mvo_dir/install.b64\"; "
                   f'mvo_pf {key} "$?"\n')
        commands.append((key, command))
    digest = hashlib.sha256(script).hexdigest()
    command = (
        'base64 -d "$mvo_dir/install.b64" >"$mvo_dir/install.gz" && '
        'gzip -dc "$mvo_dir/install.gz" >"$mvo_dir/install.sh" && '
        f'[ "$(sha256sum "$mvo_dir/install.sh" | cut -d\' \' -f1)" = {digest} ] && '
        f'/bin/sh "$mvo_dir/install.sh" "$mvo_ram" "$mvo_dir" {marker} {root_uuid}; '
        'mvo_pf installCommandExit "$?"; mvo_pf installCommandDone 1\n')
    commands.append(("installCommandDone", command))
    require(all(len(command.encode()) <= 1024 for _, command in commands), "commandLimit")
    return commands


def install_persistent(console, owner, marker, directory, artifacts, result, config, registration, disk):
    require(result.get("persistentToolProbeComplete") is True, "apkToolsObservation")
    script = stable_file(Path(__file__).with_name("persistent_linux_guest.sh"), limit=16384, content=True)[2]
    root_uuid = str(uuid.uuid4())
    commands = install_commands(script, marker, root_uuid)
    require(console.queries + len(commands) + 1 <= 64, "cursorBudget")
    for key, command in commands[:-1]:
        send(console, owner, marker, command, key, "0")
    # Rebind immediately before mutation; uploads only touched guest temporary RAM.
    require(inspect_blank_disk(directory) == disk, "blankTargetChanged")
    require({name: stable_file(directory / name, limit=1 << 20)[:2] for name in registration} == registration,
            "registrationChanged")
    require(not owner.snapshot(deadline=time.monotonic() + 2).returncode
            and owner.snapshot(deadline=time.monotonic() + 2).is_active, "guestExit")
    writer_busy(directory)
    save(artifacts / "target-write-intent.json", dict(schemaVersion=1, vmID=config["id"],
         diskIdentity=list(disk), rootUUID=root_uuid, serialMarker=marker,
         scriptSHA256=hashlib.sha256(script).hexdigest(), targetWriteAttempted=True,
         targetDirty=True, freshBlankVerified=True, writerHeld=True))
    result.update(targetWriteAttempted=True, targetDirty=True, rootUUID=root_uuid,
                  formattingPerformed=None, installScriptSHA256=hashlib.sha256(script).hexdigest())
    key, command = commands[-1]
    send(console, owner, marker, command, key, "1", seconds=180)
    code = guest_value(console, marker, "installCommandExit")
    result["installCommandExit"] = code
    fields = {}
    for line in console.lines(time.monotonic() + 3):
        prefix = (marker + ".install.").encode()
        if line.startswith(prefix):
            name, sep, value = line[len(prefix):].decode("ascii").partition("=")
            require(sep and name not in fields and len(value) <= 64, "apkToolsObservation")
            fields[name] = value
    result["installObservations"] = fields
    if fields.get("rootFormatted") == fields.get("fatFormatted") == "1":
        result["formattingPerformed"] = True
    complete = (code == "0" and fields.get("exit") == "0" and fields.get("phase") == "complete"
            and all(fields.get(k) == "0" for k in ("partition", "format", "configured", "filesystemCheck"))
            and fields.get("packages") == "49" and fields.get("rootUUID") == root_uuid
            and re.fullmatch(r"[0-9A-F]{4}-[0-9A-F]{4}", fields.get("espUUID", "")) is not None)
    result.update(persistentInstallationPerformed=complete, installFilesystemChecksPassed=complete,
                  espUUID=fields.get("espUUID"))


def parse_cold_boot(lines, marker, root_uuid, esp_uuid, prior_write="0"):
    expected = dict(services="0", kernel="6.18.55-0-virt", modules="6.18.55-0-virt", network="lo",
                    rootUUID=root_uuid, rootRW="1", espUUID=esp_uuid, discsAbsent="1",
                    priorWrite=prior_write, persistentWrite="1", complete="1", exit="0")
    require(prior_write in ("0", "1"), "apkToolsObservation")
    found, prefix = {}, (marker + ".cold.").encode()
    for line in lines:
        if not line.startswith(prefix):
            continue
        key, sep, value = line[len(prefix):].decode("ascii").partition("=")
        require(sep and key in expected and key not in found, "apkToolsObservation")
        found[key] = value
    require(found == expected, "apkToolsObservation")
    return found


def stopped_history(directory):
    history = read_json(directory / "runtime.json", 4096)
    require(history["schemaVersion"] == 1 and history["sequence"] > 0
            and history["snapshot"]["state"] == "stopped" and history["snapshot"]["backendActive"] is False
            and history["snapshot"]["outcome"] == "guestStopped"
            and history["snapshot"].get("operation") is None, "guestHistory")
    writer_available(directory)
    return history


def same_disk(directory, original):
    info = (directory / "disk.raw").lstat()
    require((info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink, info.st_size)
            == tuple(original[:6]), "blankTargetChanged")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--stage", choices=("prerequisites", "install"), default="prerequisites")
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--carrier", type=Path, required=True)
    parser.add_argument("--carrier-sha", required=True)
    parser.add_argument("--payload-bounds", type=Path, required=True)
    parser.add_argument("--payload-bounds-sha", required=True)
    options = parser.parse_args()
    if not options.run:
        print("SKIP: explicit --run required; install stage formats only a newly created disposable disk.")
        return 0
    safe_directory(ROOT / ".lab")
    artifacts = ROOT / (".lab/persistent-linux-install-" + uuid.uuid4().hex)
    artifacts.mkdir(mode=0o700)
    directory = artifacts / "Persistent.macopenvm"
    owner = observed = None
    active_label = "prerequisites"
    phase = "inputs"
    result = dict(schemaVersion=1, scope="fresh-persistent-linux-" + options.stage, status="failed",
                  stage=options.stage, targetWriteAttempted=False, targetDirty=False,
                  formattingPerformed=False, persistentInstallationPerformed=False,
                  coldBootVerified=False, credentialsModified=False, autologinEnabled=False,
                  networkActionPerformed=False, GUIActionPerformed=False, windowsCompatibilityVerified=False,
                  guestShutdownVerified=False, forcedCleanupUsed=False)
    try:
        candidate, carrier, protected_inputs, service_rows = source_inputs(options)
        packages = apk_inventory(carrier, options.carrier.parent / "staging")
        manifest = read_json(options.carrier.parent / "staging/license-source-manifest.json", expected_sha=
            next(row["sha256"] for row in carrier["stagingInventory"] if row["path"] == "license-source-manifest.json"))
        versions, identities = ({row["P"]: row["V"] for row in manifest["packages"]},
                               {row["P"]: row for row in manifest["packages"]})
        cli, iso = options.candidate.parent / "macopenvm", options.carrier.parent / "support-carrier.iso"
        run_tool(Path("/usr/bin/codesign"), ["--verify", "--strict", str(cli)], artifacts, "signature")
        out, err = run_tool(Path("/usr/bin/codesign"), ["-d", "--entitlements", ":-", str(cli)], artifacts, "entitlements")
        body = re.search(rb"<\?xml.*?</plist>", out + err, re.DOTALL)
        require(body is not None and plistlib.loads(body.group()) == {"com.apple.security.virtualization": True}, "signatureScope")
        phase = "create"
        run_tool(cli, ["create", "--directory", str(directory), "--name", "Original persistent install prerequisites",
            "--media", str(ROOT / ASSETS[0][0]), "--support-media", str(iso),
            "--kernel", str(ROOT / ASSETS[1][0]), "--initrd", str(ROOT / ASSETS[2][0]),
            "--kernel-arguments", BOOT_ARGUMENTS, "--cpus", "2", "--memory-mib", "2048",
            "--disk-gib", "8", "--network", "disconnected"], artifacts, "create")
        config = read_json(directory / "configuration.json")
        require(config["guest"] == "linux" and config["architecture"] == "arm64" and config["backend"] == "appleVz"
                and config["boot"] == "linuxKernel" and config["kernel"] == str(ROOT / ASSETS[1][0])
                and config["initialRamdisk"] == str(ROOT / ASSETS[2][0]) and config["kernelArguments"] == BOOT_ARGUMENTS
                and config["installationMedia"] == str(ROOT / ASSETS[0][0]) and config["supportMedia"] == str(iso)
                and config["cpuCount"] == 2 and config["memoryBytes"] == 2 << 30 and config["diskBytes"] == DISK_BYTES
                and config["diskFile"] == "disk.raw" and config["network"] == "disconnected", "createdScope")
        registration = {name: stable_file(directory / name, limit=1 << 20)[:2]
                        for name in ("configuration.json", "machine-identity.bin")}
        disk = inspect_blank_disk(directory)
        owner = ManagedSerial(cli, ["run", "--directory", str(directory), "--seconds", "600"],
                              cwd=artifacts, artifacts=artifacts, label="prerequisites")
        phase = "live-root"
        owner.launch(); console = GuestConsole(owner)
        console.expect(b"localhost login: ", 120); owner.write(b"root\n", deadline=time.monotonic() + 3)
        console.expect(b"localhost:~# ", 30)
        writer_busy(directory)
        # Preserve the qualified helper command geometry: longer literal prefixes
        # can wrap an echoed printf argument onto a line resembling a fact.
        # The random UUID still isolates every run; duplicate facts still reject.
        marker = "mvo-support-" + uuid.uuid4().hex
        command = (f"mvo_marker='{marker}'; printf '\\n%s.complete version=1\\n' \"$mvo_marker\"; "
            'mvo_fact() { printf "\\n%s.%s=%s\\n" "$mvo_marker" "$1" "$2"; }; '
            'mvo_fact arch "$(uname -m)"; mvo_fact kernel "$(uname -r)"; '
            'mvo_fact root "$(awk \'$2=="/"{print $1":"$3}\' /proc/mounts)"; '
            'mvo_fact net "$(ls /sys/class/net)"; mvo_fact ready 1\n')
        send(console, owner, marker, command, "ready", "1")
        facts = {key: guest_value(console, marker, key) for key in ("arch", "kernel", "net")}
        facts["ready"] = "1"
        require(facts["arch"] == "aarch64" and facts["kernel"] == "6.18.52-0-virt" and facts["net"] == "lo", "createdScope")
        command = ('mvo_fact diskBlocks "$(cat /sys/class/block/vda/size)"; '
            'mvo_fact diskRO "$(cat /sys/class/block/vda/ro)"; mvo_dm=1; '
            'grep -q "^/dev/vda" /proc/mounts /proc/swaps; [ "$?" -ne 1 ] || mvo_dm=0; '
            'mvo_parts=0; for p in /sys/class/block/vda/vda*; do [ ! -e "$p" ] || mvo_parts=1; done; '
            'mvo_fact diskMounted "$mvo_dm"; mvo_fact diskPartitions "$mvo_parts"; '
            'mvo_fact diskHead "$(dd if=/dev/vda bs=512 count=1 2>/dev/null|sha256sum|cut -d\' \' -f1)"; '
            'mvo_fact diskTail "$(dd if=/dev/vda bs=512 skip=16777215 count=1 2>/dev/null|sha256sum|cut -d\' \' -f1)"; '
            'mvo_fact diskDone 1\n')
        send(console, owner, marker, command, "diskDone", "1")
        for key in ("diskBlocks", "diskRO", "diskMounted", "diskPartitions", "diskHead", "diskTail"):
            facts[key] = guest_value(console, marker, key)
        facts["diskDone"] = "1"
        require(facts["diskBlocks"] == "16777216" and facts["diskRO"] == "0"
                and facts["diskMounted"] == facts["diskPartitions"] == "0"
                and facts["diskHead"] == facts["diskTail"] == ZERO_SHA, "blankTargetChanged")
        command = ('mvo_dev=; for p in /dev/sda /dev/sdb; do '
            'if [ -b "$p" ] && [ ! -L "$p" ] && blkid "$p" 2>/dev/null|grep -q \'LABEL="MVO_SUPPORT"\'; '
            'then mvo_dev=$p; fi; done; '
            'mkdir /media/mvo-support && mount -t iso9660 -o ro,norock "$mvo_dev" /media/mvo-support; '
            'mvo_fact carrierMount "$?"; mvo_fact carrierDevice "$mvo_dev"; '
            'mvo_fact carrierRO "$(cat /sys/class/block/${mvo_dev#/dev/}/ro)"; '
            'mvo_fact carrierBlocks "$(cat /sys/class/block/${mvo_dev#/dev/}/size)"; '
            'mvo_fact carrierFlags "$(awk \'$2=="/media/mvo-support"{print $3":"$4}\' /proc/mounts)"\n')
        send(console, owner, marker, command, "carrierMount", "0")
        facts["carrierMount"] = "0"
        for key in ("carrierDevice", "carrierRO", "carrierBlocks", "carrierFlags"):
            facts[key] = guest_value(console, marker, key)
        require(facts["carrierDevice"] in ("/dev/sda", "/dev/sdb") and facts["carrierRO"] == "1"
                and facts["carrierBlocks"] == str(carrier["isoBytes"] // 512)
                and re.fullmatch(r"iso9660:ro(?:,[a-z0-9=._-]+)*", facts["carrierFlags"]), "mountReadOnly")
        mount_options = facts["carrierFlags"].split(":", 1)[1].split(",")
        require("norock" in mount_options and "nojoliet" not in mount_options, "mountReadOnly")
        command = ('mvo_count=0; mvo_iso=; for p in /dev/sda /dev/sdb; do '
            'if [ -b "$p" ] && [ ! -L "$p" ] && [ "$(cat /sys/class/block/${p#/dev/}/size)" = 182236 ] '
            '&& [ "$(cat /sys/class/block/${p#/dev/}/ro)" = 1 ]; then mvo_iso=$p; mvo_count=$((mvo_count+1)); fi; done; '
            'mvo_h=error; [ "$mvo_count" -ne 1 ] || mvo_h=$(sha256sum "$mvo_iso"); '
            'mvo_fact installerCount "$mvo_count"; mvo_fact installerHash "${mvo_h%% *}"; '
            'mvo_h=$(sha256sum "$mvo_dev"); mvo_fact carrierHash "${mvo_h%% *}"\n')
        send(console, owner, marker, command, "carrierHash", carrier["isoSHA256"])
        for key in ("installerCount", "installerHash", "carrierHash"):
            facts[key] = guest_value(console, marker, key)
        require(facts["installerCount"] == "1" and facts["installerHash"] == ASSETS[0][2]
                and facts["carrierHash"] == carrier["isoSHA256"], "inputsChanged")
        command = ('cd /media/mvo-support && sha256sum -c SHA256SUMS > /tmp/mvo-persistent-hashes 2>&1; r=$?; cd /root; '
            'mvo_fact payloadHashExit "$r"; mvo_fact payloadHashCount "$(grep -c \' OK$\' /tmp/mvo-persistent-hashes)"\n')
        send(console, owner, marker, command, "payloadHashExit", "0")
        facts.update(payloadHashExit="0", payloadHashCount=guest_value(console, marker, "payloadHashCount"))
        require(facts["payloadHashCount"] == "54", "checksumDocument")
        phase = "verified-ram-root"
        facts.update(verify_apks(console, owner, marker, packages, artifacts, result, batch_size=25))
        facts.update(simulate_apks(console, owner, marker, versions, artifacts, result))
        facts.update(prepare_apk_root(console, owner, marker, versions, identities, artifacts, result, facts))
        facts.update(prepare_apk_tools(console, owner, marker, artifacts, result, facts))
        phase = "persistent-prerequisites"
        probe_prerequisites(console, owner, marker, artifacts, result, facts, service_rows)
        verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        result.update(guestFacts=facts, serialMarker=marker, cursorReports=console.queries,
                      candidateSourceSHA256=candidate["sourceSHA256"], candidateCLI_SHA256=candidate["cliSHA256"],
                      image55SHA256=IMAGE_SHA, archive55SHA256=ARCHIVE_SHA)
        if options.stage == "install":
            phase = "persistent-install"
            install_persistent(console, owner, marker, directory, artifacts, result, config, registration, disk)
            result["cursorReports"] = console.queries
        phase = "normal-poweroff"
        owner.write(b"poweroff\n", deadline=time.monotonic() + 3)
        observed = owner.wait(deadline=time.monotonic() + 45)
        require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
                and observed.executable_unchanged, "guestExit")
        stopped_history(directory)
        same_disk(directory, disk)
        if options.stage == "prerequisites":
            require(inspect_blank_disk(directory) == disk, "blankTargetChanged")
        require({name: stable_file(directory / name, limit=1 << 20)[:2] for name in registration} == registration, "registrationChanged")
        require(source_inputs(options)[2] == protected_inputs, "inputsChanged")
        require(read_json(directory / "configuration.json")["id"] == config["id"], "registrationChanged")
        result.update(status="probe-qualified" if result.get("persistentToolProbeComplete") else "prerequisites-incomplete",
                      guestShutdownVerified=True, blankTargetPreserved=options.stage == "prerequisites", writerAvailable=True,
                      vmID=config["id"], historyVMIDFieldAvailable=False)
        if options.stage == "install":
            result["installRunner"] = status(observed)
            phase = "installation-validation"
            require(result["persistentInstallationPerformed"], "apkToolsObservation")
            save(artifacts / "installation-complete.json", result)
            phase = "stopped-boot-selection"
            arguments = ("console=hvc0 root=UUID=" + result["rootUUID"]
                         + " rootfstype=ext4 rootflags=ro modules=virtio_blk,virtio_mmio,ext4")
            for label, args in (
                ("select-installed-boot", ["set-linux-kernel-boot", "--kernel", str(IMAGE), "--initrd",
                                         str(GENERATED / "generated-initramfs.gz"), "--kernel-arguments", arguments]),
                ("detach-installer", ["detach-media"]), ("detach-support", ["detach-support-media"])):
                before_config = stable_file(directory / "configuration.json", limit=1 << 20, content=True)[2]
                before_backups = set(directory.glob("configuration-*-backup-*.json"))
                run_tool(cli, args + ["--directory", str(directory)], artifacts, label)
                added = set(directory.glob("configuration-*-backup-*.json")) - before_backups
                require(len(added) == 1 and stable_file(added.pop(), limit=1 << 20, content=True)[2]
                        == before_config, "registrationChanged")
            selected = read_json(directory / "configuration.json")
            expected = dict(config, kernel=str(IMAGE), initialRamdisk=str(GENERATED / "generated-initramfs.gz"),
                            kernelArguments=arguments)
            for key in ("installationMedia", "supportMedia"):
                expected.pop(key, None)
            require(selected == expected, "registrationChanged")
            result["coldBoots"] = []
            for boot in range(2):
                active_label, phase = "coldboot-" + str(boot + 1), "disc-detached-cold-boot"
                same_disk(directory, disk)
                owner = ManagedSerial(cli, ["run", "--directory", str(directory), "--seconds", "240"],
                                      cwd=artifacts, artifacts=artifacts, label=active_label)
                observed = None
                owner.launch()
                cold = GuestConsole(owner)
                cold.line((marker + ".cold.exit=0").encode(), 150)
                observations = parse_cold_boot(cold.lines(time.monotonic() + 3), marker,
                                              result["rootUUID"], result["espUUID"], str(boot))
                observed = owner.wait(deadline=time.monotonic() + 45)
                require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
                        and observed.executable_unchanged, "guestExit")
                stopped_history(directory)
                same_disk(directory, disk)
                require(read_json(directory / "configuration.json") == selected, "registrationChanged")
                require(stable_file(directory / "machine-identity.bin", limit=1 << 20)[:2]
                        == registration["machine-identity.bin"], "registrationChanged")
                row = dict(boot=boot + 1, observations=observations, runner=status(observed))
                result["coldBoots"].append(row)
                save(artifacts / (active_label + "-result.json"), row)
            require(source_inputs(options)[2] == protected_inputs, "inputsChanged")
            result.update(status="installed-cold-boot-qualified", coldBootVerified=True,
                          coldBootNormalShutdownVerified=True, discsDetached=True,
                          writeSurvivedColdBoot=True, stoppedMetadataBackupsExact=True)
    except BaseException as error:
        result.update(status="failed", failurePhase=phase, failureKind=type(error).__name__)
        if isinstance(error, (DeliveryFailure, PreflightFailure)):
            result["failureCode"] = error.code
    finally:
        if owner is not None:
            final, requested = cleanup_actual(owner, artifacts, active_label, observed)
            result.update(runner=status(final), forcedCleanupUsed=requested and final.started)
            if requested:
                result.update(status="failed", guestShutdownVerified=False)
        try:
            save(artifacts / "persistent-result.json", result)
        except BaseException:
            result.update(status="failed")
    print("Persistent Linux qualification: " + result["status"] + "; private evidence retained.")
    return 0 if result["status"] in ("probe-qualified", "installed-cold-boot-qualified") else 1


if __name__ == "__main__":
    raise SystemExit(main())
