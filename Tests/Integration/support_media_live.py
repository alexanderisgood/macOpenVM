#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fresh offline support delivery; optional verified APK application to temporary memory."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid

from alpine_live_preflight import (
    ASSETS, BOOT_ARGUMENTS, DISK_BYTES, ROOT, ZERO_SHA, GuestConsole, PreflightFailure,
    cleanup_actual, inspect_blank_disk, read_json, run_tool, safe_directory,
    save, stable_file, status, unique_object, verify_guest_rows, writer_available,
)

HELPER_SHA = "b07af3c02ed377fe3c73149dbcab188b9da7e2ab27bc8f674593a6362cc531f1"
SUPERVISOR_SHA = "3083cb626c9f0c2df62b9792ffed6166ae52c3a0a504a1dce932a9ee317ebb2d"
SIMULATION_ROOTS = (
    "alpine-base=3.24.2-r0", "sfdisk=2.42.3-r1", "e2fsprogs=1.47.4-r0",
    "linux-virt=6.18.55-r0", "mkinitfs=3.14.1-r0", "dosfstools=4.2-r2",
)


class DeliveryFailure(RuntimeError):
    CODES = frozenset((
        "recordSelection", "sourceAssociation", "sourceLimit", "sourcePath", "sourceSet", "cliMode",
        "carrierScope", "carrierInventory", "carrierPath", "carrierFileSet", "carrierImage",
        "checksumDocument", "commandLimit", "signatureScope", "hostUnavailable", "createdScope",
        "supportDevice", "mountReadOnly", "guestExit", "guestHistory", "blankTargetChanged",
        "registrationChanged", "inputsChanged",
        "apkManifest", "apkSetup", "apkPath", "apkVersion", "apkRead", "apkLog",
        "apkVerification", "apkDatabaseChanged", "cursorBudget",
        "apkSimulationRead", "apkSimulationOutput", "apkSimulationSetup", "apkSimulationChanged",
        "apkRootBounds", "apkRootObservation", "apkRootSetup", "apkRootChanged",
        "apkToolsObservation", "apkToolsChanged",
        "initramfsMetadata", "initramfsObservation", "initramfsExport", "initramfsSource",
    ))

    def __init__(self, code):
        self.code = code if code in self.CODES else "invalidFailureCode"
        super().__init__(self.code)


def require(value, code):
    if not value:
        raise DeliveryFailure(code)  # All call sites are fixed application-owned names.


def selected_record(path, digest):
    require(path.is_absolute() and path == Path(os.path.abspath(path))
            and path.parent.parent == ROOT / ".lab" and re.fullmatch(r"[0-9a-f]{64}", digest),
            "recordSelection")
    safe_directory(path.parent, private=True)
    return read_json(path, maximum=65536, expected_sha=digest)


def verify_inputs(options):
    safe_directory(ROOT / ".lab")
    candidate = selected_record(options.candidate, options.candidate_sha)
    directory = options.candidate.parent
    manifest = read_json(directory / "production-before.json",
                         expected_sha=candidate["productionManifestSHA256"])
    require(manifest["sha256"] == candidate["sourceSHA256"], "sourceAssociation")
    files = manifest["files"]
    require(isinstance(files, list) and 1 <= len(files) <= 128, "sourceLimit")
    names = set()
    for entry in files:
        name = entry["path"]
        require(isinstance(name, str) and not Path(name).is_absolute()
                and ".." not in Path(name).parts and name not in names, "sourcePath")
        names.add(name)
        safe_directory((ROOT / name).parent)
        stable_file(ROOT / name, limit=2 << 20, expected_bytes=entry["bytes"],
                    expected_sha=entry["sha256"])
    actual = {str(path.relative_to(ROOT)) for folder in
              ("App", "Backends", "CLI", "Core", "RuntimeIPC", "Storage")
              for path in (ROOT / folder).rglob("*.swift")} | {"Package.swift"}
    require(actual == {name for name in names if name.endswith(".swift")}, "sourceSet")
    cli = directory / "macopenvm"
    cli_identity = stable_file(cli, limit=32 << 20, expected_bytes=candidate["cliBytes"],
                               expected_sha=candidate["cliSHA256"])[:2]
    require(stat.S_IMODE(cli.lstat().st_mode) == 0o500, "cliMode")
    carrier = selected_record(options.carrier, options.carrier_sha)
    require(carrier["schemaVersion"] == 1 and carrier["status"] == "built"
            and carrier["label"] == "MVO_SUPPORT"
            and carrier["isoBasename"] == "support-carrier.iso"
            and carrier["stagingDirectory"] == "staging"
            and carrier["sha256SumsPath"] == "SHA256SUMS"
            and carrier["sha256SumsEntryCount"] == 54, "carrierScope")
    staging = options.carrier.parent / "staging"
    safe_directory(staging)
    inventory = carrier["stagingInventory"]
    require(isinstance(inventory, list) and len(inventory) == 55, "carrierInventory")
    seen = set()
    for entry in inventory:
        name = entry["path"]
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9@+_.-]+(?:/[A-Za-z0-9@+_.-]+){0,3}", name)
                and all(part not in (".", "..") for part in Path(name).parts)
                and name not in seen, "carrierPath")
        seen.add(name)
        safe_directory((staging / name).parent)
        stable_file(staging / name, limit=128 << 20, expected_bytes=entry["bytes"],
                    expected_sha=entry["sha256"])
    require(not any(Path(name).name == ".boot_repository"
                    or ".apkovl" in Path(name).name or Path(name).name.startswith("modloop") for name in seen),
            "carrierScope")
    require(seen == {str(path.relative_to(staging)) for path in staging.rglob("*") if path.is_file()},
            "carrierFileSet")
    sums = stable_file(staging / "SHA256SUMS", limit=65536,
                       expected_sha=carrier["sha256SumsSHA256"], content=True)[2].decode("ascii")
    by_name = {entry["path"]: entry["sha256"] for entry in inventory if entry["path"] != "SHA256SUMS"}
    checksum_rows = sums.splitlines()
    require(len(checksum_rows) == 54 and sums.endswith("\n")
            and checksum_rows == [digest + "  " + name for name, digest in sorted(by_name.items())],
            "checksumDocument")
    iso = options.carrier.parent / "support-carrier.iso"
    iso_identity = stable_file(iso, limit=128 << 20, expected_bytes=carrier["isoBytes"],
                               expected_sha=carrier["isoSHA256"])[:2]
    require(carrier["isoBytes"] > 0 and carrier["isoBytes"] % 512 == 0
            and stat.S_IMODE(iso.lstat().st_mode) == 0o400, "carrierImage")
    assets = []
    for name, size, digest in ASSETS:
        safe_directory((ROOT / name).parent)
        assets.append(stable_file(ROOT / name, limit=size, expected_bytes=size, expected_sha=digest)[:2])
    for name, digest in (("alpine_live_preflight.py", HELPER_SHA), ("managed_serial.py", SUPERVISOR_SHA)):
        stable_file(Path(__file__).with_name(name), limit=65536, expected_sha=digest)
    return candidate, carrier, (cli_identity, iso_identity, assets)


def send(console, owner, marker, command, key, expected):
    require(len(command.encode()) <= 1024, "commandLimit")
    owner.write(command.encode(), deadline=time.monotonic() + 3)
    console.line((marker + "." + key + "=" + expected).encode(), 30)
    console.expect(b"localhost:~# ", 10)


def apk_inventory(carrier, staging):
    entries = {entry["path"]: entry for entry in carrier["stagingInventory"]}
    manifest = read_json(staging / "license-source-manifest.json",
                         expected_sha=entries["license-source-manifest.json"]["sha256"])
    require(manifest["schemaVersion"] == 1 and manifest["archiveChecksPassed"] is True
            and manifest["packageCount"] == 49 and len(manifest["packages"]) == 49
            and manifest["repositoryRelativePath"] == "apks/aarch64"
            and manifest["keyRelativePath"] == "keys", "apkManifest")
    packages = {}
    for row in manifest["packages"]:
        name = row["filename"]
        require(isinstance(name, str) and re.fullmatch(r"[a-z0-9][A-Za-z0-9+_.-]{0,127}\.apk", name)
                and name == row["P"] + "-" + row["V"] + ".apk" and name not in packages,
                "apkManifest")
        path = "apks/aarch64/" + name
        require(path in entries and entries[path]["sha256"] == row["wholeSHA256"], "apkManifest")
        packages[name] = row["wholeSHA256"]
    require({"apks/aarch64/" + name for name in packages}
            == {name for name in entries if name.endswith(".apk")}, "apkManifest")
    require({name for name in entries if name.startswith("keys/")} == {
        "keys/alpine-devel@lists.alpinelinux.org-58199dcc.rsa.pub",
        "keys/alpine-devel@lists.alpinelinux.org-616ae350.rsa.pub"}, "apkManifest")
    return sorted(packages)


def guest_value(console, marker, key):
    prefix = (marker + "." + key + "=").encode()
    values = [line[len(prefix):] for line in console.lines(time.monotonic() + 3)
              if line.startswith(prefix)]
    require(len(values) == 1 and 1 <= len(values[0]) <= 256, "apkRead")
    return values[0].decode("ascii")


def apk_send(console, owner, marker, command, key, expected, seconds=30):
    require(console.queries <= 56, "cursorBudget")  # Preserve the helper's actual 64-query cap.
    require(len(command.encode()) <= 1024, "commandLimit")
    owner.write(command.encode(), deadline=time.monotonic() + 3)
    console.line((marker + "." + key + "=" + expected).encode(), seconds)
    console.expect(b"localhost:~# ", 10)


def preparation_send(console, owner, marker, command, key, expected, seconds=30):
    # This longer opt-in stage reserves four responses within the unchanged
    # GuestConsole 64-query limit; other paths retain their 56-query precondition.
    require(console.queries <= 60, "cursorBudget")
    require(len(command.encode()) <= 1024, "commandLimit")
    owner.write(command.encode(), deadline=time.monotonic() + 3)
    console.line((marker + "." + key + "=" + expected).encode(), seconds)
    console.expect(b"localhost:~# ", 10)


def tools_send(console, owner, marker, command, key, expected, seconds=30):
    # The explicit tools mode batches the same 49 verifications six at a time.
    # Its fixed seven extra groups fit inside the unchanged actual 64-query cap.
    require(console.queries <= 62, "cursorBudget")
    require(len(command.encode()) <= 1024, "commandLimit")
    owner.write(command.encode(), deadline=time.monotonic() + 3)
    console.line((marker + "." + key + "=" + expected).encode(), seconds)
    console.expect(b"localhost:~# ", 10)


def database_hash(console, owner, marker, name, path, limit):
    command = (
        f"mvo_h=error; mvo_r=1; if [ -f {path} ] && [ ! -L {path} ]; then "
        f"mvo_n=$(wc -c <{path}); mvo_s=$?; if [ \"$mvo_s\" -eq 0 ] && "
        f"[ \"$mvo_n\" -ge 0 ] && [ \"$mvo_n\" -le {limit} ]; then "
        f"mvo_h=$(sha256sum {path}); mvo_r=$?; mvo_h=${{mvo_h%% *}}; fi; fi; "
        f"printf '\\n{marker}.{name}Status=%s\\n{marker}.{name}=%s\\n' \"$mvo_r\" \"$mvo_h\"\n")
    apk_send(console, owner, marker, command, name + "Status", "0")
    value = guest_value(console, marker, name)
    require(re.fullmatch(r"[0-9a-f]{64}", value), "apkRead")
    return {name + "Status": "0", name: value}


def verify_apks(console, owner, marker, packages, artifacts, result, batch_size=4):
    require(batch_size in (4, 6, 25), "apkManifest")
    result["apkVerificationBatchSize"] = batch_size
    """Run the stock live verifier only; its applet has no commit/script option group."""
    facts = {}
    command = (
        f"umask 077; mvo_tmpfs=$(stat -f -c %T /tmp); mvo_t=$?; mvo_setup=1; "
        f"mvo_dir=/tmp/mvo-apk-{marker.rsplit('-', 1)[1]}; "
        f"if [ \"$mvo_t\" -eq 0 ] && [ \"$mvo_tmpfs\" = tmpfs ]; then "
        f"mkdir -m 700 \"$mvo_dir\" && : >\"$mvo_dir/verify.log\"; mvo_setup=$?; fi; "
        f"printf '\\n{marker}.apkTmpfsStatus=%s\\n{marker}.apkTmpfs=%s\\n{marker}.apkSetup=%s\\n' "
        f"\"$mvo_t\" \"$mvo_tmpfs\" \"$mvo_setup\"\n")
    apk_send(console, owner, marker, command, "apkSetup", "0")
    require(guest_value(console, marker, "apkTmpfsStatus") == "0"
            and guest_value(console, marker, "apkTmpfs") == "tmpfs", "apkSetup")
    facts.update(apkSetup="0", apkTmpfsStatus="0", apkTmpfs="tmpfs")
    command = (
        f"mvo_apk=$(command -v apk); mvo_lookup=$?; mvo_vr=125; mvo_invoked=0; "
        f"case \"$mvo_apk\" in /sbin/apk|/usr/sbin/apk) "
        f"mvo_invoked=1; (ulimit -f 1 || exit 125; "
        f"APK_CONFIG=/dev/null \"$mvo_apk\" --no-network --no-cache --no-logfile "
        f"--no-progress --no-pretty-print --no-interactive --version "
        f") >\"$mvo_dir/version\" 2>&1; mvo_vr=$?;; *) mvo_apk=invalid;; esac; "
        f"printf '\\n{marker}.apkLookup=%s\\n{marker}.apkPath=%s\\n{marker}.apkVersionStatus=%s\\n' "
        f"\"$mvo_lookup\" \"$mvo_apk\" \"$mvo_vr\"; "
        f"printf '\\n{marker}.apkInvocationAttempted=%s\\n{marker}.apkVersionQueryFinished=1\\n' \"$mvo_invoked\"\n")
    # Submission is known before a reply; lost acknowledgement cannot imply that
    # the stock tool did not run. The passive branch never enters this state.
    result.update(stockAPKInvocationRequested=True, stockAPKInvocationAttempted=None,
                  apkActionPerformed=None)
    apk_send(console, owner, marker, command, "apkVersionQueryFinished", "1")
    attempted = guest_value(console, marker, "apkInvocationAttempted") == "1"
    result.update(apkActionPerformed=attempted, stockAPKInvocationAttempted=attempted)
    path = guest_value(console, marker, "apkPath")
    require(guest_value(console, marker, "apkLookup") == "0"
            and path in ("/sbin/apk", "/usr/sbin/apk"), "apkPath")
    version_status = guest_value(console, marker, "apkVersionStatus")
    require(re.fullmatch(r"[0-9]{1,3}", version_status) and int(version_status) <= 255, "apkVersion")
    result["stockAPKVersionExitStatus"] = int(version_status)
    # The pinned ISO APKINDEX and package commit 4588b452... identify 3.0.8-r0.
    # Its official APKBUILD exports VERSION=$pkgver-r$pkgrel; upstream Meson
    # passes that exact value to APK_VERSION. This is not inferred from output size.
    expected_version = "apk-tools 3.0.8-r0, compiled for aarch64."
    command = (
        f"mvo_vbytes=$(wc -c <\"$mvo_dir/version\"); mvo_w=$?; mvo_vhash=unavailable; mvo_hs=125; mvo_b=125; "
        f"if [ \"$mvo_w\" -eq 0 ]; then mvo_vbytes=$((mvo_vbytes+0)); fi; "
        f"if [ \"$mvo_w\" -eq 0 ] && [ \"$mvo_vbytes\" -ge 0 ] && [ \"$mvo_vbytes\" -le 256 ]; then "
        f"mvo_vhash=$(sha256sum \"$mvo_dir/version\"); mvo_hs=$?; mvo_vhash=${{mvo_vhash%% *}}; "
        f"printf '\\n{marker}.apkVersionBegin=1\\n'; base64 \"$mvo_dir/version\"; mvo_b=$?; "
        f"printf '\\n{marker}.apkVersionEnd=%s\\n' \"$mvo_b\"; fi; "
        f"printf '\\n{marker}.apkVersionSizeStatus=%s\\n{marker}.apkVersionBytes=%s\\n' \"$mvo_w\" \"$mvo_vbytes\"; "
        f"printf '\\n{marker}.apkVersionHashStatus=%s\\n{marker}.apkVersionSHA256=%s\\n{marker}.apkVersionCaptureFinished=1\\n' "
        f"\"$mvo_hs\" \"$mvo_vhash\"\n")
    apk_send(console, owner, marker, command, "apkVersionCaptureFinished", "1")
    size = guest_value(console, marker, "apkVersionBytes")
    version_hash = guest_value(console, marker, "apkVersionSHA256")
    result.update(stockAPKVersionOutputBytes=size, stockAPKVersionOutputCaptured=False)
    require(re.fullmatch(r"[0-9]{1,3}", size) and int(size) <= 256
            and guest_value(console, marker, "apkVersionSizeStatus") == "0"
            and guest_value(console, marker, "apkVersionHashStatus") == "0"
            and re.fullmatch(r"[0-9a-f]{64}", version_hash), "apkRead")
    lines = console.lines(time.monotonic() + 3)
    begin, end = (marker + ".apkVersionBegin=1").encode(), (marker + ".apkVersionEnd=0").encode()
    require(lines.count(begin) == 1 and lines.count(end) == 1, "apkRead")
    start, stop = lines.index(begin), lines.index(end)
    encoded = b"".join(lines[start + 1:stop])
    require(start < stop and len(encoded) <= 344, "apkRead")
    try:
        version_bytes = base64.b64decode(encoded, validate=True)
    except ValueError:
        raise DeliveryFailure("apkRead") from None
    require(len(version_bytes) == int(size)
            and hashlib.sha256(version_bytes).hexdigest() == version_hash, "apkRead")
    save(artifacts / "apk-version-output.json", dict(schemaVersion=1, encoding="base64",
         stream="combined-stdout-stderr", exitStatus=int(version_status),
         bytes=len(version_bytes), sha256=version_hash, data=encoded.decode("ascii")))
    result.update(stockAPKVersionOutputCaptured=True, stockAPKVersionOutputSHA256=version_hash)
    require(attempted and version_status == "0"
            and version_bytes == (expected_version + "\n").encode(), "apkVersion")
    facts.update(apkLookup="0", apkPath=path, apkVersionStatus="0", apkVersionSizeStatus="0",
                 apkVersionBytes=size, apkVersionHashStatus="0", apkVersionSHA256=version_hash,
                 apkVersionBegin="1", apkVersionEnd="0", apkVersionCaptureFinished="1",
                 apkInvocationAttempted="1", apkVersionQueryFinished="1")
    for name, file, limit in (("apkWorldBefore", "/etc/apk/world", 4096),
                              ("apkDatabaseBefore", "/lib/apk/db/installed", 1 << 20)):
        facts.update(database_hash(console, owner, marker, name, file, limit))
    command = (
        f"mvo_apk_count=0; mvo_apk_failures=0; set -- /media/mvo-support/keys/*; "
        f"mvo_keys=$#; mvo_verify_pkg() {{ (ulimit -f 32 || exit 125; "
        f"APK_CONFIG=/dev/null \"$mvo_apk\" --no-network "
        f"--no-cache --no-logfile --no-progress --no-pretty-print --no-interactive "
        f"--repositories-file /dev/null --keys-dir /media/mvo-support/keys "
        f"verify \"/media/mvo-support/apks/aarch64/$1\" ) >>\"$mvo_dir/verify.log\" 2>&1; "
        f"mvo_pkg_rc=$?; mvo_apk_count=$((mvo_apk_count+1)); "
        f"[ \"$mvo_pkg_rc\" -eq 0 ] || mvo_apk_failures=$((mvo_apk_failures+1)); "
        f"printf '\\n{marker}.apkPackage.%s=%s\\n' \"$1\" \"$mvo_pkg_rc\"; }}; "
        f"printf '\\n{marker}.apkKeyCount=%s\\n' \"$mvo_keys\"\n")
    apk_send(console, owner, marker, command, "apkKeyCount", "2")
    facts["apkKeyCount"] = "2"
    for offset in range(0, len(packages), batch_size):
        batch = " ".join("'" + name + "'" for name in packages[offset:offset + batch_size])
        key = "apkBatch" + str(offset // batch_size)
        count = min(offset + batch_size, len(packages))
        if batch_size == 25:
            command = (f"for mvo_p in {batch}; do mvo_verify_pkg \"$mvo_p\"; done; "
                       f"printf '\\n%s.{key}=%s\\n' '{marker}' \"$mvo_apk_count\"\n")
        else:
            command = (f"for mvo_p in {batch}; do mvo_verify_pkg \"$mvo_p\"; done; "
                       f"printf '\\n{marker}.{key}=%s\\n' \"$mvo_apk_count\"\n")
        apk_send(console, owner, marker, command, key, str(count), seconds=120)
        facts[key] = str(count)
    command = (
        f"mvo_log_n=$(wc -c <\"$mvo_dir/verify.log\"); mvo_w=$?; "
        f"if [ \"$mvo_w\" -eq 0 ]; then mvo_log_n=$((mvo_log_n+0)); fi; "
        f"mvo_log_h=$(sha256sum \"$mvo_dir/verify.log\"); mvo_s=$?; mvo_log_h=${{mvo_log_h%% *}}; "
        f"printf '\\n{marker}.apkCount=%s\\n{marker}.apkFailures=%s\\n' \"$mvo_apk_count\" \"$mvo_apk_failures\"; "
        f"printf '\\n{marker}.apkLogSizeStatus=%s\\n{marker}.apkLogHashStatus=%s\\n' \"$mvo_w\" \"$mvo_s\"; "
        f"printf '\\n{marker}.apkLogBytes=%s\\n{marker}.apkLogSHA256=%s\\n{marker}.apkLogInfo=0\\n' "
        f"\"$mvo_log_n\" \"$mvo_log_h\"\n")
    apk_send(console, owner, marker, command, "apkLogInfo", "0")
    log_size = guest_value(console, marker, "apkLogBytes")
    log_hash = guest_value(console, marker, "apkLogSHA256")
    require(re.fullmatch(r"[0-9]{1,5}", log_size) and 0 < int(log_size) <= 32768
            and re.fullmatch(r"[0-9a-f]{64}", log_hash)
            and guest_value(console, marker, "apkLogSizeStatus") == "0"
            and guest_value(console, marker, "apkLogHashStatus") == "0", "apkLog")
    command = (f"printf '\\n{marker}.apkLogBegin=1\\n'; base64 \"$mvo_dir/verify.log\"; mvo_b=$?; "
               f"printf '\\n{marker}.apkLogEnd=%s\\n' \"$mvo_b\"\n")
    apk_send(console, owner, marker, command, "apkLogEnd", "0")
    lines = console.lines(time.monotonic() + 3)
    begin, end = (marker + ".apkLogBegin=1").encode(), (marker + ".apkLogEnd=0").encode()
    require(lines.count(begin) == 1 and lines.count(end) == 1, "apkLog")
    start, stop = lines.index(begin), lines.index(end)
    encoded = b"".join(lines[start + 1:stop])
    require(start < stop and len(encoded) <= 43692, "apkLog")
    try:
        log = base64.b64decode(encoded, validate=True)
    except ValueError:
        raise DeliveryFailure("apkLog") from None
    require(len(log) == int(log_size) and hashlib.sha256(log).hexdigest() == log_hash, "apkLog")
    save(artifacts / "apk-verification-log.json", dict(schemaVersion=1, encoding="base64",
         bytes=len(log), sha256=log_hash, data=encoded.decode("ascii")))
    facts.update(apkCount="49", apkFailures="0", apkLogInfo="0", apkLogBytes=log_size,
                 apkLogSHA256=log_hash, apkLogSizeStatus="0", apkLogHashStatus="0",
                 apkLogBegin="1", apkLogEnd="0")
    for name in packages:
        key = "apkPackage." + name
        require(guest_value(console, marker, key) == "0", "apkVerification")
        facts[key] = "0"
    require(guest_value(console, marker, "apkCount") == "49"
            and guest_value(console, marker, "apkFailures") == "0", "apkVerification")
    for name, file, limit, before in (
            ("apkWorldAfter", "/etc/apk/world", 4096, "apkWorldBefore"),
            ("apkDatabaseAfter", "/lib/apk/db/installed", 1 << 20, "apkDatabaseBefore")):
        current = database_hash(console, owner, marker, name, file, limit)
        require(current[name] == facts[before], "apkDatabaseChanged")
        facts.update(current)
    result.update(apkVerificationPerformed=True, apkVerificationCount=49,
                  apkVerificationLogSHA256=log_hash, liveDatabaseWorldBytesPreserved=True,
                  runtimeAPKVersion=expected_version, runtimeAPKPath=path)
    return facts


def parse_apk_simulation(log, versions, scope, exit_status):
    """Human changes are observations; archive identity/architecture come from the pinned manifest."""
    require(isinstance(log, bytes) and len(log) <= 32768 and scope in ("live", "empty")
            and type(exit_status) is int and 0 <= exit_status <= 255, "apkSimulationOutput")
    report = dict(scope="proposed-live-changes" if scope == "live" else "empty-target-selection",
                  exitStatus=exit_status, solverSucceeded=exit_status == 0, changes=[],
                  payloadsAvailable=False, matchesVerifiedKit=False,
                  payloadAssociation="inference-from-manifest-name-version")
    if exit_status != 0:
        report["observation"] = "solver-failed"
        return report  # Diagnostics remain in the complete private log; no chosen set is claimed.
    try:
        lines = log.decode("ascii").splitlines()
    except UnicodeError:
        raise DeliveryFailure("apkSimulationOutput") from None
    require(len(lines) <= 512 and all(len(line) <= 512 for line in lines), "apkSimulationOutput")
    simple = re.compile(r"^\(\s*([1-9][0-9]{0,2})/([1-9][0-9]{0,2})\) "
                        r"(Installing|Reinstalling|Updating pinning|Purging) "
                        r"([a-z0-9][a-z0-9+_.-]{0,63}) \(([A-Za-z0-9+_.-]{1,64})\)$")
    changed = re.compile(r"^\(\s*([1-9][0-9]{0,2})/([1-9][0-9]{0,2})\) "
                         r"(Upgrading|Downgrading|Replacing) ([a-z0-9][a-z0-9+_.-]{0,63}) "
                         r"\(([A-Za-z0-9+_.-]{1,64}) -> ([A-Za-z0-9+_.-]{1,64})\)$")
    summary = None
    total = None
    names = set()
    listing = False
    headers = {
        "The following packages will be REMOVED:", "The following packages will be DOWNGRADED:",
        "The following NEW packages will be installed:", "The following packages will be upgraded:",
        "The following packages will be reinstalled:",
    }
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        end = re.fullmatch(r"OK: [0-9]+(?:\.[0-9]+)? (?:B|KiB|MiB|GiB|TiB) in ([0-9]+) packages", line)
        if end:
            require(summary is None, "apkSimulationOutput")
            summary = int(end[1])
            continue
        require(summary is None, "apkSimulationOutput")
        if scope == "live" and line in headers:
            listing = True
            continue
        if scope == "live" and listing and raw.startswith(" ") and re.fullmatch(
                r"[a-z0-9][a-z0-9+_.-]*(?: +[a-z0-9][a-z0-9+_.-]*)*", line):
            continue  # Informational lists are not interpreted as the actual changeset.
        if scope == "live" and re.fullmatch(
                r"After this operation, [0-9]+(?:\.[0-9]+)? (?:B|KiB|MiB|GiB|TiB) of "
                r"(?:additional disk space will be used|disk space will be freed)\.", line):
            listing = False
            continue
        match = simple.fullmatch(line) or changed.fullmatch(line)
        require(match is not None, "apkSimulationOutput")
        listing = False
        number, common, operation, name = int(match[1]), int(match[2]), match[3], match[4]
        require(common <= 128 and number == len(report["changes"]) + 1 and number <= common
                and (total is None or common == total) and name not in names, "apkSimulationOutput")
        total = common
        names.add(name)
        old = match[5] if operation in ("Upgrading", "Downgrading", "Replacing", "Purging") else None
        version = None if operation == "Purging" else match[6] if match.lastindex == 6 else match[5]
        require(scope != "empty" or operation == "Installing", "apkSimulationOutput")
        available = version is None or versions.get(name) == version
        report["changes"].append(dict(operation=operation, name=name, oldVersion=old,
                                      version=version, verifiedPayloadAvailable=available))
    require(summary is not None and (total is None or total == len(report["changes"]))
            and (scope != "empty" or summary == len(report["changes"])), "apkSimulationOutput")
    chosen = {(row["name"], row["version"]) for row in report["changes"] if row["version"] is not None}
    report.update(observation="parsed", summaryPackageCount=summary,
                  payloadsAvailable=all(row["verifiedPayloadAvailable"] for row in report["changes"]),
                  matchesVerifiedKit=scope == "empty" and chosen == set(versions.items()),
                  unverifiedPayloads=[dict(name=row["name"], version=row["version"])
                                      for row in report["changes"] if not row["verifiedPayloadAvailable"]])
    return report


def simulation_blob(console, owner, marker, key, file, limit, facts, artifacts,
                    sender=apk_send, dynamic_markers=False):
    command = (
        f"mvo_bn=$(wc -c <{file}); mvo_bw=$?; mvo_bh=unavailable; mvo_bs=125; "
        f"if [ \"$mvo_bw\" -eq 0 ]; then mvo_bn=$((mvo_bn+0)); fi; "
        f"if [ \"$mvo_bw\" -eq 0 ] && [ \"$mvo_bn\" -ge 0 ] && [ \"$mvo_bn\" -le {limit} ]; then "
        f"mvo_bh=$(sha256sum {file}); mvo_bs=$?; mvo_bh=${{mvo_bh%% *}}; fi; ")
    if dynamic_markers:
        # Construct the nonce only in printf. Terminal echo can wrap a literal
        # nonce onto its own line and otherwise resemble a duplicate result.
        command += (f'mvo_pf {key}Bytes "$mvo_bn"; mvo_pf {key}SizeStatus "$mvo_bw"; '
                    f'mvo_pf {key}SHA256 "$mvo_bh"; mvo_pf {key}HashStatus "$mvo_bs"; '
                    f'mvo_pf {key}Info 1\n')
    else:
        command += (f"printf '\\n{marker}.{key}Bytes=%s\\n{marker}.{key}SizeStatus=%s\\n' \"$mvo_bn\" \"$mvo_bw\"; "
        f"printf '\\n{marker}.{key}SHA256=%s\\n{marker}.{key}HashStatus=%s\\n{marker}.{key}Info=1\\n' "
        f"\"$mvo_bh\" \"$mvo_bs\"\n")
    sender(console, owner, marker, command, key + "Info", "1")
    size, digest = guest_value(console, marker, key + "Bytes"), guest_value(console, marker, key + "SHA256")
    require(re.fullmatch(r"[0-9]{1,5}", size) and int(size) <= limit
            and re.fullmatch(r"[0-9a-f]{64}", digest)
            and guest_value(console, marker, key + "SizeStatus") == "0"
            and guest_value(console, marker, key + "HashStatus") == "0", "apkSimulationRead")
    if dynamic_markers:
        command = (f'mvo_pf {key}Begin 1; base64 {file}; mvo_br=$?; '
                   f'mvo_pf {key}End "$mvo_br"\n')
    else:
        command = (f"printf '\\n{marker}.{key}Begin=1\\n'; base64 {file}; mvo_br=$?; "
                   f"printf '\\n{marker}.{key}End=%s\\n' \"$mvo_br\"\n")
    sender(console, owner, marker, command, key + "End", "0")
    lines = console.lines(time.monotonic() + 3)
    begin, end = (marker + "." + key + "Begin=1").encode(), (marker + "." + key + "End=0").encode()
    require(lines.count(begin) == 1 and lines.count(end) == 1, "apkSimulationRead")
    start, stop = lines.index(begin), lines.index(end)
    encoded = b"".join(lines[start + 1:stop])
    require(start < stop and len(encoded) <= 4 * ((limit + 2) // 3), "apkSimulationRead")
    try:
        blob = base64.b64decode(encoded, validate=True)
    except ValueError:
        raise DeliveryFailure("apkSimulationRead") from None
    require(len(blob) == int(size) and hashlib.sha256(blob).hexdigest() == digest, "apkSimulationRead")
    save(artifacts / (key + "-output.json"), dict(schemaVersion=1, encoding="base64",
         bytes=len(blob), sha256=digest, data=encoded.decode("ascii")))
    facts.update({key + "Bytes": size, key + "SHA256": digest, key + "Info": "1",
                  key + "SizeStatus": "0", key + "HashStatus": "0", key + "Begin": "1", key + "End": "0"})
    return blob


def simulate_apks(console, owner, marker, versions, artifacts, result):
    facts = {}
    result.update(dependencySimulationRequested=True, dependencySimulationPerformed=None,
                  dependencyClosureComplete=False, simulationCases={})
    command = (
        f"mvo_sim_marker='{marker}'; mvo_empty=\"$mvo_dir/empty\"; mvo_setup=1; "
        f"mvo_fs=$(stat -f -c %T \"$mvo_dir\"); mvo_fr=$?; "
        f"if [ \"$mvo_fr\" -eq 0 ] && [ \"$mvo_fs\" = tmpfs ] && mkdir -m 700 \"$mvo_empty\" "
        f"&& mkdir -p \"$mvo_empty/etc/apk\" \"$mvo_empty/lib/apk/db\" "
        f"&& printf '\\n' >\"$mvo_empty/etc/apk/world\" && : >\"$mvo_empty/lib/apk/db/installed\" "
        f"&& printf '%s\\n' 'ndx /media/mvo-support/apks/aarch64/APKINDEX.tar.gz' >\"$mvo_dir/sim.repositories\"; "
        f"then mvo_setup=0; fi; printf '\\n{marker}.simSetup=%s\\n' \"$mvo_setup\"\n")
    apk_send(console, owner, marker, command, "simSetup", "0")
    facts["simSetup"] = "0"
    result["emptyTargetPreparation"] = "real-tmpfs-only-world-and-installed-metadata"
    command = (
        "mvo_sim_hash() { mvo_h=error; mvo_r=1; if [ -f \"$2\" ] && [ ! -L \"$2\" ]; then "
        "mvo_n=$(wc -c <\"$2\"); mvo_s=$?; if [ \"$mvo_s\" -eq 0 ] && [ \"$mvo_n\" -ge 0 ] "
        "&& [ \"$mvo_n\" -le \"$3\" ]; then mvo_h=$(sha256sum \"$2\"); mvo_r=$?; "
        "mvo_h=${mvo_h%% *}; fi; fi; printf '\\n%s.%sStatus=%s\\n%s.%s=%s\\n' "
        "\"$mvo_sim_marker\" \"$1\" \"$mvo_r\" \"$mvo_sim_marker\" \"$1\" \"$mvo_h\"; }; "
        f"printf '\\n{marker}.simHashFunction=1\\n'\n")
    apk_send(console, owner, marker, command, "simHashFunction", "1")
    facts["simHashFunction"] = "1"
    files = (
        ("simWorld", "/etc/apk/world", 4096), ("simDatabase", "/lib/apk/db/installed", 1 << 20),
        ("simRepositories", "/etc/apk/repositories", 4096),
        ("simEmptyWorld", '"$mvo_empty/etc/apk/world"', 4096),
        ("simEmptyDatabase", '"$mvo_empty/lib/apk/db/installed"', 1 << 20),
        ("simExplicitRepositories", '"$mvo_dir/sim.repositories"', 4096),
    )
    def snapshot(phase):
        command = "; ".join(f"mvo_sim_hash {key + phase} {file} {limit}" for key, file, limit in files)
        command += f"; printf '\\n{marker}.sim{phase}Done=1\\n'\n"
        apk_send(console, owner, marker, command, "sim" + phase + "Done", "1")
        facts["sim" + phase + "Done"] = "1"
        for key, _, _ in files:
            field = key + phase
            value = guest_value(console, marker, field)
            require(guest_value(console, marker, field + "Status") == "0"
                    and re.fullmatch(r"[0-9a-f]{64}", value), "apkSimulationRead")
            facts.update({field: value, field + "Status": "0"})
    snapshot("Before")
    require(facts["simEmptyWorldBefore"] == hashlib.sha256(b"\n").hexdigest()
            and facts["simEmptyDatabaseBefore"] == hashlib.sha256(b"").hexdigest()
            and facts["simExplicitRepositoriesBefore"] == hashlib.sha256(
                b"ndx /media/mvo-support/apks/aarch64/APKINDEX.tar.gz\n").hexdigest(), "apkSimulationSetup")
    world = simulation_blob(console, owner, marker, "simLiveWorld", "/etc/apk/world", 4096, facts, artifacts)
    require(hashlib.sha256(world).hexdigest() == facts["simWorldBefore"], "apkSimulationChanged")
    for scope, extra in (("live", ""), ("empty", '--root "$mvo_empty" ')):
        key = "sim" + scope.title()
        case = dict(requested=True, observedCompletion=False, exitStatus=None)
        result["simulationCases"][scope] = case
        command = (
            f"(ulimit -f 32 || exit 125; APK_CONFIG=/dev/null \"$mvo_apk\" --arch aarch64 "
            f"--no-network --no-cache --no-logfile --no-progress --no-pretty-print --no-interactive "
            f"--repositories-file \"$mvo_dir/sim.repositories\" --keys-dir /media/mvo-support/keys "
            f"{extra}add --simulate --no-scripts --no-commit-hooks {' '.join(SIMULATION_ROOTS)} "
            f") >\"$mvo_dir/{scope}-simulation.log\" 2>&1; mvo_sr=$?; "
            f"printf '\\n{marker}.{key}Exit=%s\\n{marker}.{key}Finished=1\\n' \"$mvo_sr\"\n")
        apk_send(console, owner, marker, command, key + "Finished", "1", seconds=120)
        code = guest_value(console, marker, key + "Exit")
        require(re.fullmatch(r"[0-9]{1,3}", code) and int(code) <= 255, "apkSimulationRead")
        facts.update({key + "Exit": code, key + "Finished": "1"})
        case.update(observedCompletion=True, exitStatus=int(code))
        result["dependencySimulationPerformed"] = True
        log = simulation_blob(console, owner, marker, key + "Log",
                              f'"$mvo_dir/{scope}-simulation.log"', 32768, facts, artifacts)
        case.update(logBytes=len(log), logSHA256=hashlib.sha256(log).hexdigest())
        try:
            case["plan"] = parse_apk_simulation(log, versions, scope, int(code))
        except DeliveryFailure as error:
            case["plan"] = dict(observation="unsupported-output", parseFailureCode=error.code,
                                solverSucceeded=int(code) == 0, payloadsAvailable=False, matchesVerifiedKit=False)
    snapshot("After")
    require(all(facts[key + "Before"] == facts[key + "After"] for key, _, _ in files), "apkSimulationChanged")
    cases = result["simulationCases"]
    result.update(simulationRoots=list(SIMULATION_ROOTS), liveStateBytesPreserved=True,
                  emptyTargetMetadataBytesPreserved=True,
                  dependencyClosureComplete=all(case["plan"]["solverSucceeded"]
                      and case["plan"]["payloadsAvailable"] for case in cases.values())
                      and cases["empty"]["plan"]["matchesVerifiedKit"])
    return facts


def preparation_bounds(options, carrier):
    require(options.payload_bounds is not None and options.payload_bounds_sha is not None, "apkRootBounds")
    record = selected_record(options.payload_bounds, options.payload_bounds_sha)
    require(record["schemaVersion"] == 1 and record["status"] == "passed"
            and record["scope"] == "verified-apk-header-only-logical-bounds"
            and record["manifestSHA256"] == "5756d984a22517c2b6313b3643cf58d6151944b4a9c10e67894d4c0e0e5f599a"
            and record["verificationResultSHA256"] == "917bd4974ec5700f99f55e1fcd85e0fb4f200e2debe1e19774d81c6af5c6f581"
            and record["packageCount"] == 49
            and record["maximumRegularFileLimitBytes"] == 134217728
            and record["aggregateRegularFileLimitBytes"] == 536870912
            and record["aggregateDecodedTarLimitBytes"] == 536870912
            and record["extractionPerformed"] is False and record["executionPerformed"] is False
            and record["linkResolutionPerformed"] is False
            and record["extractionSafetyVerified"] is False, "apkRootBounds")
    expected = {entry["path"].split("/")[-1]: entry["sha256"]
                for entry in carrier["stagingInventory"] if entry["path"].endswith(".apk")}
    seen = set()
    total = decoded = 0
    require(len(record["packages"]) == 49, "apkRootBounds")
    for row in record["packages"]:
        name = row["filename"]
        require(name in expected and name not in seen and row["wholeSHA256"] == expected[name]
                and row["status"] == "passed" and row["sparse"] is False
                and row["paxSizeOverride"] is False and row["framingComplete"] is True, "apkRootBounds")
        require(all(type(row[key]) is int and row[key] >= 0 for key in (
            "maximumRegularFileBytes", "totalRegularFileBytes", "decodedTarBytes",
            "logicalEntryCount", "physicalHeaderCount"))
            and row["maximumRegularFileBytes"] <= 134217728, "apkRootBounds")
        seen.add(name)
        total += row["totalRegularFileBytes"]
        decoded += row["decodedTarBytes"]
    require(seen == set(expected) and total <= 536870912 and decoded <= 536870912
            and record["aggregateRegularFileBytes"] == total
            and record["aggregateDecodedTarBytes"] == decoded, "apkRootBounds")


def parse_installed_projection(data, versions, identities):
    """Original record-boundary probe exports P/V/A/C; do not infer architecture from its path."""
    require(isinstance(data, bytes) and len(data) <= 32768
            and all(byte in (9, 10) or 32 <= byte <= 126 for byte in data), "apkRootObservation")
    try:
        lines = data.decode("ascii").splitlines()
    except UnicodeError:
        raise DeliveryFailure("apkRootObservation") from None
    require(len(lines) == len(versions), "apkRootObservation")
    rows = {}
    for line in lines:
        values = line.split("\t")
        require(len(values) == 4 and len(line) <= 512, "apkRootObservation")
        name, version, architecture, identity = values
        require(name in versions and name not in rows and version == versions[name]
                and architecture in ("aarch64", "noarch")
                and re.fullmatch(r"Q[12][A-Za-z0-9+/=]{20,88}", identity)
                and architecture == identities[name]["indexArchitecture"]
                and identity == identities[name]["C"], "apkRootObservation")
        rows[name] = dict(version=version, architecture=architecture,
                          signedControlArchitecture=identities[name]["signedControlArchitecture"],
                          architectureSource="authenticated-index-record", packageIdentity=identity)
    require(set(rows) == set(versions), "apkRootObservation")
    return rows


def parse_prepared_world(data):
    require(isinstance(data, bytes) and len(data) <= 4096 and data.endswith(b"\n")
            and all(byte == 10 or 32 <= byte <= 126 for byte in data), "apkRootObservation")
    try:
        roots = data.decode("ascii").splitlines()
    except UnicodeError:
        raise DeliveryFailure("apkRootObservation") from None
    require(len(roots) == len(SIMULATION_ROOTS) and len(set(roots)) == len(roots)
            and set(roots) == set(SIMULATION_ROOTS), "apkRootObservation")
    return roots


def prepare_apk_root(console, owner, marker, versions, identities, artifacts, result, existing_facts):
    facts = {}
    if not result["dependencyClosureComplete"]:
        result.update(apkRootPreparationRequested=True, apkRootPreparationSkipped="simulation-incomplete",
                      apkRootPreparationComplete=False)
        return facts
    result.update(apkRootPreparationRequested=True, apkRootApplicationAttempted=None,
                  packageApplicationPerformed=None, apkRootApplicationExitStatus=None,
                  apkRootPreparationComplete=False, targetHelperExecuted=False,
                  mkinitfsExecuted=False, chrootExecuted=False, liveGlobalTrustChanged=False)
    guard = (
        'mvo_safe() { mvo_b="$mvo_ram"; [ -d "$mvo_b" ] && [ ! -L "$mvo_b" ] || return 1; '
        'mvo_rest=$1; while [ "${mvo_rest#*/}" != "$mvo_rest" ]; do mvo_part=${mvo_rest%%/*}; '
        'mvo_b="$mvo_b/$mvo_part"; [ -d "$mvo_b" ] && [ ! -L "$mvo_b" ] || return 1; '
        'mvo_rest=${mvo_rest#*/}; done; }; mvo_pf prepPathGuard 1; ')
    command = (
        'mvo_ram="$mvo_dir/prepared"; mvo_ar=1; mvo_af=$(stat -f -c %T "$mvo_dir"); mvo_as=$?; '
        'if [ "$mvo_as" -eq 0 ] && [ "$mvo_af" = tmpfs ]; then mkdir -m 700 "$mvo_ram"; mvo_ar=$?; fi; '
        'mvo_pf() { printf "\\n%s.%s=%s\\n" "$mvo_sim_marker" "$1" "$2"; }; '
        'mvo_apply_drain() { dd bs=1 count=32768 >"$mvo_dir/apply.log" 2>/dev/null; mvo_dd=$?; '
        'wc -c >"$mvo_dir/apply.discard"; mvo_wc=$?; printf "%s %s\\n" "$mvo_dd" "$mvo_wc" '
        '>"$mvo_dir/apply.drain"; }; ' + guard + 'mvo_pf prepSetup "$mvo_ar"\n')
    preparation_send(console, owner, marker, command, "prepSetup", "0")
    facts.update(prepSetup="0", prepPathGuard="1")
    command = (
        '(mvo_inv=0; mvo_rc=125; if ulimit -f 262144; then mvo_inv=1; '
        'APK_CONFIG=/dev/null "$mvo_apk" --root "$mvo_ram" --arch aarch64 '
        '--no-network --no-cache --no-logfile --no-progress --no-pretty-print --no-interactive '
        '--repositories-file "$mvo_dir/sim.repositories" --keys-dir /media/mvo-support/keys '
        f'add --initdb --no-scripts --no-commit-hooks {" ".join(SIMULATION_ROOTS)}; mvo_rc=$?; fi; '
        'printf "%s %s\\n" "$mvo_inv" "$mvo_rc" >"$mvo_dir/apply.exit") 2>&1 | mvo_apply_drain; mvo_pipe=$?; '
        'read -r mvo_inv mvo_rc <"$mvo_dir/apply.exit"; mvo_read=$?; '
        'mvo_pf prepInvocation "$mvo_inv"; mvo_pf prepExit "$mvo_rc"; mvo_pf prepExitRead "$mvo_read"; '
        'mvo_pf prepPipeline "$mvo_pipe"; mvo_pf prepFinished 1\n')
    preparation_send(console, owner, marker, command, "prepFinished", "1", seconds=180)
    for key in ("prepInvocation", "prepExit", "prepExitRead", "prepPipeline"):
        facts[key] = guest_value(console, marker, key)
    facts["prepFinished"] = "1"
    code = facts["prepExit"]
    require(facts["prepExitRead"] == "0" and facts["prepInvocation"] in ("0", "1")
            and re.fullmatch(r"[0-9]{1,3}", code) and int(code) <= 255, "apkRootObservation")
    attempted = facts["prepInvocation"] == "1"
    result.update(apkRootApplicationAttempted=attempted, packageApplicationPerformed=attempted,
                  apkRootApplicationExitStatus=int(code))
    log = simulation_blob(console, owner, marker, "prepLog", '"$mvo_dir/apply.log"',
                          32768, facts, artifacts, sender=preparation_send, dynamic_markers=True)
    command = (
        'mvo_discard=$(cat "$mvo_dir/apply.discard"); mvo_c=$?; '
        'read -r mvo_dd mvo_wc <"$mvo_dir/apply.drain"; mvo_r=$?; '
        'mvo_kb=$(du -sk "$mvo_ram"); mvo_du=$?; mvo_kb=${mvo_kb%%[[:space:]]*}; '
        'mvo_pf prepDiscard "$mvo_discard"; mvo_pf prepDiscardRead "$mvo_c"; '
        'mvo_pf prepDrainRead "$mvo_r"; mvo_pf prepDD "$mvo_dd"; mvo_pf prepWC "$mvo_wc"; '
        'mvo_pf prepKiB "$mvo_kb"; mvo_pf prepDU "$mvo_du"; mvo_pf prepInfo 1\n')
    preparation_send(console, owner, marker, command, "prepInfo", "1")
    for key in ("prepDiscard", "prepDiscardRead", "prepDrainRead", "prepDD", "prepWC", "prepKiB", "prepDU"):
        facts[key] = guest_value(console, marker, key)
    facts["prepInfo"] = "1"
    require(re.fullmatch(r"[0-9]{1,10}", facts["prepDiscard"])
            and re.fullmatch(r"[0-9]{1,10}", facts["prepKiB"]), "apkRootObservation")
    clean_log = all(facts[key] == "0" for key in (
        "prepDiscard", "prepDiscardRead", "prepDrainRead", "prepDD", "prepWC", "prepDU", "prepPipeline"))
    result.update(apkRootApplicationLogSHA256=hashlib.sha256(log).hexdigest(),
                  apkRootApplicationLogComplete=clean_log, apkRootSizeKiB=int(facts["prepKiB"]))
    valid = attempted and int(code) == 0 and clean_log and int(facts["prepKiB"]) <= 524288
    if valid:
        probe = ('BEGIN{RS="";FS="\\n";n=0;e=0}{p=v=a=c="";pc=vc=ac=cc=0;'
                 'for(i=1;i<=NF;i++){if($i~/^P:/){p=substr($i,3);pc++}else if($i~/^V:/){v=substr($i,3);vc++}'
                 'else if($i~/^A:/){a=substr($i,3);ac++}else if($i~/^C:/){c=substr($i,3);cc++}}'
                 'if(pc!=1||vc!=1||ac!=1||cc!=1){e=1;next}print p"\\t"v"\\t"a"\\t"c;n++}'
                 'END{if(e||n!=49)exit 1}')
        command = (
            'mvo_db="$mvo_ram/lib/apk/db/installed"; mvo_pr=125; '
            'if mvo_safe lib/apk/db/installed && [ -f "$mvo_db" ] && [ ! -L "$mvo_db" ]; then '
            'mvo_dn=$(wc -c <"$mvo_db"); mvo_dr=$?; '
            'if [ "$mvo_dr" -eq 0 ] && [ "$mvo_dn" -le 1048576 ]; then '
            f'(ulimit -f 32 || exit 125; awk \'{probe}\' "$mvo_db") >"$mvo_dir/installed.rows"; '
            'mvo_pr=$?; fi; fi; mvo_pf prepProjection "$mvo_pr"; mvo_pf prepProjectionDone 1\n')
        preparation_send(console, owner, marker, command, "prepProjectionDone", "1")
        facts.update(prepProjection=guest_value(console, marker, "prepProjection"), prepProjectionDone="1")
        if facts["prepProjection"] == "0":
            projection = simulation_blob(console, owner, marker, "prepInstalled",
                '"$mvo_dir/installed.rows"', 32768, facts, artifacts,
                sender=preparation_send, dynamic_markers=True)
            try:
                result["preparedInstalledPackages"] = parse_installed_projection(projection, versions, identities)
            except DeliveryFailure as error:
                valid = False
                result["apkRootSemanticFailure"] = error.code
        else:
            valid = False
            result["apkRootSemanticFailure"] = "installed-projection-failed"
        command = (
            'mvo_n=0; mvo_ns=; mvo_md=; mvo_s=1; '
            'mvo_safe lib/x && mvo_safe usr/lib/x || mvo_s=0; '
            'if [ "$mvo_s" -eq 1 ]; then for mvo_ba in lib/modules usr/lib/modules; do '
            'if mvo_safe "$mvo_ba/x"; then for mvo_p in "$mvo_ram/$mvo_ba/"*; do '
            '[ -e "$mvo_p" ] || [ -L "$mvo_p" ] || continue; mvo_n=$((mvo_n+1)); '
            'mvo_ns=${mvo_p##*/}; mvo_md=$mvo_p; '
            '[ -d "$mvo_p" ] && [ ! -L "$mvo_p" ] || mvo_s=0; done; '
            'elif [ -e "$mvo_ram/$mvo_ba" ] || [ -L "$mvo_ram/$mvo_ba" ]; then mvo_s=0; fi; done; fi; '
            'mvo_pf prepModuleCount "$mvo_n"; mvo_pf prepModuleNamespace "$mvo_ns"; '
            'mvo_pf prepModuleSafe "$mvo_s"; mvo_pf prepModuleInfo 1\n')
        preparation_send(console, owner, marker, command, "prepModuleInfo", "1")
        for key in ("prepModuleCount", "prepModuleNamespace", "prepModuleSafe"):
            facts[key] = guest_value(console, marker, key)
        facts["prepModuleInfo"] = "1"
        command = (
            'mvo_k=error; mvo_kr=125; mvo_cf=0; mvo_p="$mvo_ram/boot/vmlinuz-virt"; '
            'if mvo_safe boot/vmlinuz-virt && [ -f "$mvo_p" ] && [ ! -L "$mvo_p" ] && [ -s "$mvo_p" ]; then '
            'mvo_kn=$(wc -c <"$mvo_p"); mvo_sz=$?; '
            'if [ "$mvo_sz" -eq 0 ] && [ "$mvo_kn" -le 134217728 ]; then '
            'mvo_k=$(sha256sum "$mvo_p"); mvo_kr=$?; mvo_k=${mvo_k%% *}; fi; fi; '
            'mvo_p="$mvo_ram/boot/config-6.18.55-0-virt"; mvo_safe boot/config-6.18.55-0-virt && [ -f "$mvo_p" ] '
            '&& [ ! -L "$mvo_p" ] && [ -s "$mvo_p" ] && mvo_cf=1; '
            'mvo_pf prepKernelStatus "$mvo_kr"; mvo_pf prepKernelSHA256 "$mvo_k"; '
            'mvo_pf prepConfig "$mvo_cf"; mvo_pf prepKernelInfo 1\n')
        preparation_send(console, owner, marker, command, "prepKernelInfo", "1")
        for key in ("prepKernelStatus", "prepKernelSHA256", "prepConfig"):
            facts[key] = guest_value(console, marker, key)
        facts["prepKernelInfo"] = "1"
        kernel_valid = (facts["prepModuleCount"] == "1" and facts["prepModuleSafe"] == "1"
            and facts["prepModuleNamespace"] == "6.18.55-0-virt" and facts["prepKernelStatus"] == "0"
            and facts["prepConfig"] == "1"
            and facts["prepKernelSHA256"] == "af8ad21e222dbff8c89909e1ef7b8b7607dd58188b2f3067128aac4f646d212d")
        if kernel_valid:
            command = (
                '(find "$mvo_md" -type f \\( -name "*.ko" -o -name "*.ko.gz" -o -name "*.ko.xz" '
                '-o -name "*.ko.zst" \\) -print; mvo_fr=$?; printf "%s\\n" "$mvo_fr" '
                '>"$mvo_dir/modules.find") | wc -l >"$mvo_dir/modules.count"; mvo_wr=$?; '
                'mvo_fc=$(cat "$mvo_dir/modules.find"); mvo_fcr=$?; '
                'mvo_nc=$(cat "$mvo_dir/modules.count"); mvo_ncr=$?; '
                'mvo_pf prepModuleFiles "$mvo_nc"; mvo_pf prepModuleFind "$mvo_fc"; '
                'mvo_pf prepModuleRead "$mvo_fcr:$mvo_ncr:$mvo_wr"; mvo_pf prepModuleFilesDone 1\n')
            preparation_send(console, owner, marker, command, "prepModuleFilesDone", "1")
            for key in ("prepModuleFiles", "prepModuleFind", "prepModuleRead"):
                facts[key] = guest_value(console, marker, key).strip()
            facts["prepModuleFilesDone"] = "1"
            kernel_valid = (re.fullmatch(r"[0-9]{1,5}", facts["prepModuleFiles"]) is not None
                and 0 < int(facts["prepModuleFiles"]) <= 16384 and facts["prepModuleFind"] == "0"
                and facts["prepModuleRead"] == "0:0:0")
        valid = valid and kernel_valid
        inventory_definition = (
            'mvo_inventory() { mvo_p="$mvo_ram/$1"; mvo_v=unsafe-ancestor; '
            'if mvo_safe "$1"; then mvo_v=missing; if [ -L "$mvo_p" ]; then '
            'mvo_l=$(readlink "$mvo_p"); mvo_lr=$?; mvo_v="symlink:$mvo_lr:$mvo_l"; '
            'elif [ -f "$mvo_p" ]; then mvo_n=$(wc -c <"$mvo_p"); mvo_nr=$?; mvo_v="regular:$mvo_nr:$mvo_n"; '
            'elif [ -e "$mvo_p" ]; then mvo_v=other; fi; fi; mvo_pf "prepPath.$1" "$mvo_v"; }; '
            'mvo_pf prepInventoryFunction 1; ')
        paths = ("bin/busybox", "bin/sh", "sbin/mkinitfs", "usr/bin/lddtree", "usr/bin/scanelf",
                 "bin/kmod", "usr/bin/kmod", "sbin/depmod", "sbin/modprobe", "sbin/modinfo",
                 "bin/mkdir", "bin/cpio", "usr/bin/find", "usr/bin/sort", "usr/bin/awk",
                 "usr/bin/install", "dev/null", "usr/share/mkinitfs/initramfs-init")
        command = inventory_definition + "; ".join("mvo_inventory " + path for path in paths)
        command += "; mvo_pf prepInventoryDone 1\n"
        preparation_send(console, owner, marker, command, "prepInventoryDone", "1")
        facts.update(prepInventoryDone="1", prepInventoryFunction="1")
        result["preparedHelperInventory"] = {}
        for path in paths:
            key = "prepPath." + path
            facts[key] = guest_value(console, marker, key)
            result["preparedHelperInventory"][path] = facts[key]
        command = ('mvo_wp=1; if mvo_safe etc/apk/world && [ -f "$mvo_ram/etc/apk/world" ] '
                   '&& [ ! -L "$mvo_ram/etc/apk/world" ]; then mvo_wp=0; fi; '
                   'mvo_pf prepWorldPath "$mvo_wp"\n')
        preparation_send(console, owner, marker, command, "prepWorldPath", "0")
        facts["prepWorldPath"] = "0"
        world = simulation_blob(console, owner, marker, "prepWorld",
            '"$mvo_ram/etc/apk/world"', 4096, facts, artifacts,
            sender=preparation_send, dynamic_markers=True)
        try:
            result["preparedWorldRoots"] = parse_prepared_world(world)
        except DeliveryFailure as error:
            valid = False
            result["apkRootSemanticFailure"] = error.code
    command = (
        'mvo_sim_hash prepLiveWorldAfter /etc/apk/world 4096; '
        'mvo_sim_hash prepLiveDatabaseAfter /lib/apk/db/installed 1048576; '
        'mvo_sim_hash prepLiveRepositoriesAfter /etc/apk/repositories 4096; mvo_pf prepLiveAfterDone 1\n')
    preparation_send(console, owner, marker, command, "prepLiveAfterDone", "1")
    facts["prepLiveAfterDone"] = "1"
    for key, before in (("prepLiveWorldAfter", "simWorldAfter"), ("prepLiveDatabaseAfter", "simDatabaseAfter"),
                        ("prepLiveRepositoriesAfter", "simRepositoriesAfter")):
        facts[key] = guest_value(console, marker, key)
        facts[key + "Status"] = guest_value(console, marker, key + "Status")
        require(facts[key + "Status"] == "0" and facts[key] == existing_facts[before], "apkRootChanged")
    result.update(apkRootPreparationComplete=bool(valid), apkRootLiveStateBytesPreserved=True)
    return facts


TOOLS_PATH = "/sbin:/usr/sbin:/usr/bin:/bin:/tmp/mvo-applets"


def parse_tool_probe(log):
    require(isinstance(log, bytes) and len(log) <= 32768
            and all(byte == 10 or 32 <= byte <= 126 for byte in log), "apkToolsObservation")
    rows = {}
    for line in log.decode("ascii").splitlines():
        if line.startswith("mvo-tools."):
            key, separator, value = line.partition("=")
            require(separator and key in ("mvo-tools.probe", "mvo-tools.dependencies")
                    and key not in rows and value == "0", "apkToolsObservation")
            rows[key] = value
    require(len(rows) == 2, "apkToolsObservation")
    return dict(probeSucceeded=True, dependenciesSucceeded=True)


def tool_exit_status(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]{1,3}", value)
            and int(value) <= 255, "apkToolsObservation")
    return int(value)


def prepare_apk_tools(console, owner, marker, artifacts, result, existing_facts):
    facts = {}
    result.update(apkToolsPreparationRequested=True, apkToolsPreparationComplete=False)
    if not result["apkRootPreparationComplete"] or console.queries > 56:
        result["apkToolsPreparationSkipped"] = "root-or-cursor-prerequisite"
        return facts
    result.update(targetHelperExecuted=None, chrootExecuted=None, apkToolsNullCreationAttempted=None,
                  apkToolsInstallationAttempted=None)
    command = (
        'mvo_ts=125; mvo_nr=125; mvo_ni=0; mvo_tkb=error; '
        'if mvo_safe bin/kmod && [ -f "$mvo_ram/bin/kmod" ] && [ ! -L "$mvo_ram/bin/kmod" ]; then '
        'mvo_tkb=$(sha256sum "$mvo_ram/bin/kmod"); mvo_tkb=${mvo_tkb%% *}; fi; '
        'if mvo_safe tmp/mvo-applets && mvo_safe dev/null && mvo_safe sbin/depmod '
        '&& mvo_safe bin/busybox && [ -f "$mvo_ram/bin/busybox" ] && [ ! -L "$mvo_ram/bin/busybox" ] '
        '&& [ ! -e "$mvo_ram/dev/null" ] '
        '&& [ ! -L "$mvo_ram/dev/null" ]; then mkdir -m 700 "$mvo_ram/tmp/mvo-applets"; mvo_ts=$?; '
        'if [ "$mvo_ts" -eq 0 ]; then mvo_ni=1; /bin/busybox mknod -m 666 "$mvo_ram/dev/null" c 1 3; mvo_nr=$?; fi; fi; '
        'mvo_pf toolsSetup "$mvo_ts"; mvo_pf toolsNullInvocation "$mvo_ni"; mvo_pf toolsNullExit "$mvo_nr"; '
        'mvo_pf toolsKmodBefore "$mvo_tkb"; '
        'for mvo_a in depmod modprobe modinfo; do mvo_l=$(readlink "$mvo_ram/sbin/$mvo_a"); mvo_r=$?; '
        'mvo_pf "toolsAliasBefore.$mvo_a" "$mvo_r:$mvo_l"; done; mvo_pf toolsSetupDone 1\n')
    tools_send(console, owner, marker, command, "toolsSetupDone", "1")
    for key in ("toolsSetup", "toolsNullInvocation", "toolsNullExit", "toolsKmodBefore",
                "toolsAliasBefore.depmod", "toolsAliasBefore.modprobe", "toolsAliasBefore.modinfo"):
        facts[key] = guest_value(console, marker, key)
    facts["toolsSetupDone"] = "1"
    require(facts["toolsNullInvocation"] in ("0", "1"), "apkToolsObservation")
    tool_exit_status(facts["toolsSetup"])
    tool_exit_status(facts["toolsNullExit"])
    result["apkToolsNullCreationAttempted"] = facts["toolsNullInvocation"] == "1"
    valid = (facts["toolsSetup"] == "0" and facts["toolsNullExit"] == "0"
             and re.fullmatch(r"[0-9a-f]{64}", facts["toolsKmodBefore"]) is not None
             and all(facts["toolsAliasBefore." + n] == "0:../bin/kmod" for n in ("depmod", "modprobe", "modinfo")))
    command = (
        'mvo_ti=0; mvo_ir=125; if [ "$mvo_ts" -eq 0 ] && [ "$mvo_nr" -eq 0 ]; then mvo_ti=1; '
        f'(ulimit -f 32 || exit 125; /bin/busybox env -i PATH={TOOLS_PATH} LC_ALL=C '
        '/bin/busybox chroot "$mvo_ram" /bin/busybox --install -s /tmp/mvo-applets) '
        '>"$mvo_dir/tools.log" 2>&1; mvo_ir=$?; else : >"$mvo_dir/tools.log"; fi; '
        'mvo_pf toolsInstallInvocation "$mvo_ti"; mvo_pf toolsInstallExit "$mvo_ir"; mvo_pf toolsInstallDone 1\n')
    tools_send(console, owner, marker, command, "toolsInstallDone", "1")
    for key in ("toolsInstallInvocation", "toolsInstallExit"):
        facts[key] = guest_value(console, marker, key)
    facts["toolsInstallDone"] = "1"
    require(facts["toolsInstallInvocation"] in ("0", "1"), "apkToolsObservation")
    result["apkToolsInstallationAttempted"] = facts["toolsInstallInvocation"] == "1"
    result["apkToolsInstallExitStatus"] = tool_exit_status(facts["toolsInstallExit"])
    if facts["toolsInstallInvocation"] == "0":
        result.update(targetHelperExecuted=False, chrootExecuted=False)
    elif facts["toolsInstallExit"] == "0":
        result.update(targetHelperExecuted=True, chrootExecuted=True)
    probe = (
        'r=0; printf "target-probe-entered=1\\n"; '
        'for x in mkdir cpio find sort awk install sed grep readlink stat sha256sum gzip cat dd wc; do '
        'p=$(command -v "$x"); [ "$?" -eq 0 ] && [ -n "$p" ] || r=1; printf "PATH:%s=%s\\n" "$x" "$p"; done; '
        '[ "$(command -v depmod)" = /sbin/depmod ] || r=1; '
        '[ -c /dev/null ] && [ "$(stat -c %t:%T:%a /dev/null)" = 1:3:666 ] '
        '&& printf test >/dev/null && [ "$(wc -c </dev/null)" -eq 0 ] || r=1; '
        '/bin/kmod --version && /usr/bin/scanelf -V && /bin/sh -n /sbin/mkinitfs '
        '&& /bin/sh -n /usr/bin/lddtree || r=1; '
        'printf "mvo-tools.probe=%s\\n" "$r"; exit "$r"')
    command = (
        'mvo_pr=125; if [ "$mvo_ir" -eq 0 ]; then '
        f'(ulimit -f 32 || exit 125; /bin/busybox env -i PATH={TOOLS_PATH} LC_ALL=C '
        f'/bin/busybox chroot "$mvo_ram" /bin/sh -c \'{probe}\') >>"$mvo_dir/tools.log" 2>&1; mvo_pr=$?; fi; '
        'mvo_pf toolsProbeExit "$mvo_pr"; mvo_pf toolsProbeDone 1\n')
    tools_send(console, owner, marker, command, "toolsProbeDone", "1")
    facts.update(toolsProbeExit=guest_value(console, marker, "toolsProbeExit"), toolsProbeDone="1")
    result["apkToolsProbeExitStatus"] = tool_exit_status(facts["toolsProbeExit"])
    dependencies = (
        'r=0; for x in /bin/busybox /bin/kmod /usr/bin/scanelf /sbin/nlplug-findfs; do '
        'y=$(/usr/bin/lddtree -l "$x"); s=$?; printf "DEPS:%s\\n%s\\n" "$x" "$y"; '
        '[ "$s" -eq 0 ] && [ -n "$y" ] || r=1; '
        'for p in $y; do case "$p" in /*) [ -f "$p" ] && [ -r "$p" ] || r=1;; *) r=1;; esac; done; done; '
        'printf "mvo-tools.dependencies=%s\\n" "$r"; exit "$r"')
    command = (
        'mvo_dr=125; if [ "$mvo_ir" -eq 0 ]; then '
        f'(ulimit -f 32 || exit 125; /bin/busybox env -i PATH={TOOLS_PATH} LC_ALL=C '
        f'/bin/busybox chroot "$mvo_ram" /bin/sh -c \'{dependencies}\') >>"$mvo_dir/tools.log" 2>&1; mvo_dr=$?; fi; '
        'mvo_pf toolsDependenciesExit "$mvo_dr"; mvo_pf toolsDependenciesDone 1\n')
    tools_send(console, owner, marker, command, "toolsDependenciesDone", "1")
    facts.update(toolsDependenciesExit=guest_value(console, marker, "toolsDependenciesExit"), toolsDependenciesDone="1")
    result["apkToolsDependenciesExitStatus"] = tool_exit_status(facts["toolsDependenciesExit"])
    log = simulation_blob(console, owner, marker, "toolsLog", '"$mvo_dir/tools.log"', 32768,
                          facts, artifacts, sender=tools_send, dynamic_markers=True)
    result.update(apkToolsLogBytes=len(log), apkToolsLogSHA256=hashlib.sha256(log).hexdigest())
    try:
        result["apkToolsProbe"] = parse_tool_probe(log)
    except DeliveryFailure as error:
        valid = False
        result["apkToolsSemanticFailure"] = error.code
    valid = valid and all(facts[k] == "0" for k in ("toolsInstallExit", "toolsProbeExit", "toolsDependenciesExit"))
    command = (
        'mvo_tka=error; if mvo_safe bin/kmod && [ -f "$mvo_ram/bin/kmod" ] && [ ! -L "$mvo_ram/bin/kmod" ]; then '
        'mvo_tka=$(sha256sum "$mvo_ram/bin/kmod"); mvo_tka=${mvo_tka%% *}; fi; mvo_pf toolsKmodAfter "$mvo_tka"; '
        'for mvo_a in depmod modprobe modinfo; do mvo_l=$(readlink "$mvo_ram/sbin/$mvo_a"); mvo_r=$?; '
        'mvo_pf "toolsAliasAfter.$mvo_a" "$mvo_r:$mvo_l"; done; '
        'mvo_sim_hash toolsLiveWorldAfter /etc/apk/world 4096; '
        'mvo_sim_hash toolsLiveDatabaseAfter /lib/apk/db/installed 1048576; '
        'mvo_sim_hash toolsLiveRepositoriesAfter /etc/apk/repositories 4096; mvo_pf toolsAfterDone 1\n')
    tools_send(console, owner, marker, command, "toolsAfterDone", "1")
    for key in ("toolsKmodAfter", "toolsAliasAfter.depmod", "toolsAliasAfter.modprobe", "toolsAliasAfter.modinfo"):
        facts[key] = guest_value(console, marker, key)
    facts["toolsAfterDone"] = "1"
    kmod_preserved = (re.fullmatch(r"[0-9a-f]{64}", facts["toolsKmodBefore"]) is not None
        and facts["toolsKmodAfter"] == facts["toolsKmodBefore"] and all(
            facts["toolsAliasAfter." + n] == facts["toolsAliasBefore." + n]
            for n in ("depmod", "modprobe", "modinfo")))
    valid = valid and kmod_preserved
    for key, before in (("toolsLiveWorldAfter", "prepLiveWorldAfter"),
                        ("toolsLiveDatabaseAfter", "prepLiveDatabaseAfter"),
                        ("toolsLiveRepositoriesAfter", "prepLiveRepositoriesAfter")):
        facts[key] = guest_value(console, marker, key)
        facts[key + "Status"] = guest_value(console, marker, key + "Status")
        require(facts[key + "Status"] == "0" and facts[key] == existing_facts[before], "apkToolsChanged")
    result.update(apkToolsPreparationComplete=bool(valid), apkToolsLiveStateBytesPreserved=True,
                  apkToolsPackagedKmodPreserved=kmod_preserved)
    return facts


KERNEL_RELEASE = "6.18.55-0-virt"
GENERATION_FEATURES = "base virtio ext4 scsi usb cdrom squashfs"
EXPORT_LIMIT = 32 << 20


def generation_metadata():
    directory = ROOT / ".lab/alpine-initramfs-metadata-822aeecd5dd84487b86068af07920174"
    metadata = read_json(directory / "metadata-provenance.json", maximum=65536,
        expected_sha="3022d868d4575afd41a7d6ee67a8939adbd60105e5c3128f02b3f9db872eaf8d")
    require(metadata["status"] == "passed" and metadata["boundsSHA256"]
            == "65e7e3103c37c459b6ecd8834aadcef27703dff751e69c5d9495d750b1f53815", "initramfsMetadata")
    for file in metadata["files"]:
        require(re.fullmatch(r"(?:kernel-config-6\.18\.55-0-virt|feature-[a-z0-9-]+)\.txt", file["name"]),
                "initramfsMetadata")
        stable_file(directory / file["name"], limit=262144, expected_bytes=file["bytes"], expected_sha=file["sha256"])


def capture_archive_inspector(expected_sha):
    require(isinstance(expected_sha, str) and re.fullmatch(r"[0-9a-f]{64}", expected_sha), "initramfsSource")
    path = Path(__file__).with_name("initramfs_inspection.py")
    safe_directory(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        stamp = lambda st: (st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid,
                            st.st_nlink, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and 0 < before.st_size <= 65536, "initramfsSource")
        raw = os.read(fd, 65536)
        require(len(raw) == before.st_size and not os.read(fd, 1)
                and stamp(before) == stamp(os.fstat(fd)) == stamp(path.lstat())
                and hashlib.sha256(raw).hexdigest() == expected_sha, "initramfsSource")
    finally:
        os.close(fd)
    namespace = {"__file__": str(path), "__name__": "qualified_archive_inspector"}
    exec(compile(raw, str(path), "exec"), namespace)
    return namespace["inspect_initramfs"]


def generation_send(console, owner, marker, command, key, expected, seconds=30):
    require(console.queries <= 63 and len(command.encode()) <= 1024, "cursorBudget")
    owner.write(command.encode(), deadline=time.monotonic() + 3)
    console.line((marker + "." + key + "=" + expected).encode(), seconds)
    console.expect(b"localhost:~# ", 10)


def generate_initramfs(console, owner, marker, artifacts, result, existing_facts):
    facts = {}
    result.update(initramfsGenerationRequested=True, initramfsGenerationComplete=False,
                  exportRequested=True, exportWriteAttempted=None, exportDiskUsed=None,
                  blankTargetPreserved=None, persistentInstallationPerformed=False)
    if not result["apkToolsPreparationComplete"] or console.queries > 56:
        result.update(initramfsGenerationSkipped="tools-or-cursor-prerequisite", exportWriteAttempted=False,
                      exportDiskUsed=False)
        return facts
    result.update(depmodExecuted=None, mkinitfsExecuted=None)
    command = (
        'mvo_gs=125; if mvo_safe tmp/mvo-initfs-build && mvo_safe boot/initramfs-virt '
        '&& [ ! -e "$mvo_ram/boot/initramfs-virt" ] && [ ! -L "$mvo_ram/boot/initramfs-virt" ]; '
        'then mkdir -m 700 "$mvo_ram/tmp/mvo-initfs-build"; mvo_gs=$?; fi; '
        'mvo_gdrain() { dd bs=1 count=32768 >"$mvo_dir/generation.log" 2>/dev/null; mvo_dd=$?; '
        'wc -c >"$mvo_dir/generation.discard"; mvo_wc=$?; '
        'printf "%s %s\\n" "$mvo_dd" "$mvo_wc" >"$mvo_dir/generation.drain"; }; '
        'mvo_pf genSetup "$mvo_gs"\n')
    generation_send(console, owner, marker, command, "genSetup", "0")
    facts["genSetup"] = "0"
    script = (
        'd=125;k=125;p=0; for f in /bin/busybox /bin/sh /sbin/modprobe /lib/mdev /sbin/apk '
        '/sbin/nlplug-findfs /usr/share/mkinitfs/initramfs-init; do [ -e "$f" ] || p=1; done; '
        f'if [ "$p" -eq 0 ]; then /sbin/depmod -a {KERNEL_RELEASE}; d=$?; '
        f'if [ "$d" -eq 0 ]; then /sbin/mkinitfs -c /dev/null -F "{GENERATION_FEATURES}" '
        f'-C gzip -k -t /tmp/mvo-initfs-build -o /boot/initramfs-virt {KERNEL_RELEASE}; k=$?; fi; fi; '
        'printf "%s %s %s\\n" "$p" "$d" "$k" >/tmp/mvo-generation.exit')
    command = (
        f'(ulimit -f 262144 || exit 125; /bin/busybox env -i PATH={TOOLS_PATH} LC_ALL=C '
        f'/bin/busybox chroot "$mvo_ram" /bin/sh -c \'{script}\') 2>&1 | mvo_gdrain; mvo_gp=$?; '
        'read -r mvo_bp mvo_de mvo_me <"$mvo_ram/tmp/mvo-generation.exit"; mvo_gr=$?; '
        'mvo_pf genBaseInputs "$mvo_bp"; mvo_pf genDepmodExit "$mvo_de"; mvo_pf genMkinitfsExit "$mvo_me"; '
        'mvo_pf genExitRead "$mvo_gr"; mvo_pf genPipeline "$mvo_gp"; mvo_pf genFinished 1\n')
    generation_send(console, owner, marker, command, "genFinished", "1", seconds=180)
    for key in ("genBaseInputs", "genDepmodExit", "genMkinitfsExit", "genExitRead", "genPipeline"):
        facts[key] = guest_value(console, marker, key)
    facts["genFinished"] = "1"
    require(facts["genExitRead"] == "0", "initramfsObservation")
    depcode, mkcode = tool_exit_status(facts["genDepmodExit"]), tool_exit_status(facts["genMkinitfsExit"])
    result.update(depmodExitStatus=depcode, mkinitfsExitStatus=mkcode,
                  depmodInvocationAttempted=facts["genBaseInputs"] == "0",
                  depmodExecuted=True if depcode == 0 else False if facts["genBaseInputs"] != "0" else None,
                  mkinitfsInvocationAttempted=depcode == 0,
                  mkinitfsExecuted=True if mkcode == 0 else False if depcode != 0 else None)
    probe = (
        'r=0; for f in modules.dep modules.dep.bin modules.alias modules.alias.bin; do '
        f'[ -s /lib/modules/{KERNEL_RELEASE}/$f ] || r=1; done; '
        'for n in virtio_blk virtio_mmio ext4 jbd2 scsi_mod sd_mod xhci_hcd xhci_pci usb_storage isofs loop squashfs; do '
        f'p=$(/sbin/modinfo -k {KERNEL_RELEASE} -F filename "$n"); a=$?; '
        f'v=$(/sbin/modinfo -k {KERNEL_RELEASE} -F vermagic "$n"); b=$?; '
        f'case "$v" in "{KERNEL_RELEASE} "*) ;; *) r=1;; esac; '
        '[ "$a:$b" = 0:0 ] && [ -f "$p" ] || r=1; printf "MODULE:%s=%s|%s\\n" "$n" "$p" "$v"; done; '
        'printf "mvo-generation.modules=%s\\n" "$r"; exit "$r"')
    command = (
        f'(ulimit -f 32 || exit 125; /bin/busybox env -i PATH={TOOLS_PATH} LC_ALL=C '
        f'/bin/busybox chroot "$mvo_ram" /bin/sh -c \'{probe}\') >>"$mvo_dir/generation.log" 2>&1; mvo_mp=$?; '
        'mvo_pf genModuleProbe "$mvo_mp"; mvo_pf genModulesDone 1\n')
    generation_send(console, owner, marker, command, "genModulesDone", "1", seconds=60)
    facts.update(genModuleProbe=guest_value(console, marker, "genModuleProbe"), genModulesDone="1")
    command = (
        'mvo_n=0; mvo_h=error; mvo_sr=125; mvo_z=125; '
        'if mvo_safe boot/initramfs-virt && [ -f "$mvo_ram/boot/initramfs-virt" ] && [ ! -L "$mvo_ram/boot/initramfs-virt" ]; '
        'then mvo_n=$(wc -c <"$mvo_ram/boot/initramfs-virt"); mvo_sr=$?; '
        'if [ "$mvo_sr" -eq 0 ] && [ "$mvo_n" -gt 0 ] && [ "$mvo_n" -le 33554432 ]; then '
        'mvo_h=$(sha256sum "$mvo_ram/boot/initramfs-virt"); mvo_h=${mvo_h%% *}; '
        '/bin/busybox gzip -t "$mvo_ram/boot/initramfs-virt"; mvo_z=$?; fi; fi; '
        'mvo_pf genArchiveBytes "$mvo_n"; mvo_pf genArchiveSHA256 "$mvo_h"; '
        'mvo_pf genArchiveSizeStatus "$mvo_sr"; mvo_pf genGzipTest "$mvo_z"; mvo_pf genInfo 1\n')
    generation_send(console, owner, marker, command, "genInfo", "1", seconds=60)
    for key in ("genModuleProbe", "genArchiveBytes", "genArchiveSHA256", "genArchiveSizeStatus", "genGzipTest"):
        facts[key] = guest_value(console, marker, key)
    facts["genInfo"] = "1"
    log = simulation_blob(console, owner, marker, "genLog", '"$mvo_dir/generation.log"', 32768,
                          facts, artifacts, sender=generation_send, dynamic_markers=True)
    result.update(generationLogBytes=len(log), generationLogSHA256=hashlib.sha256(log).hexdigest())
    valid = (depcode == 0 and mkcode == 0 and facts["genModuleProbe"] == "0"
             and facts["genArchiveSizeStatus"] == "0" and facts["genGzipTest"] == "0"
             and re.fullmatch(r"[0-9]{1,8}", facts["genArchiveBytes"]) is not None
             and 0 < int(facts["genArchiveBytes"]) <= EXPORT_LIMIT
             and re.fullmatch(r"[0-9a-f]{64}", facts["genArchiveSHA256"]) is not None)
    result.update(initramfsGenerationComplete=bool(valid), generatedArchiveBytes=int(facts["genArchiveBytes"]),
                  generatedArchiveSHA256=facts["genArchiveSHA256"])
    result["exportWriteAttempted"] = None  # A lost acknowledgment must preserve uncertainty.
    command = (
        'go=1; [ -b /dev/vda ] && [ ! -L /dev/vda ] && [ "$(cat /sys/class/block/vda/size)" = 16777216 ] '
        '&& [ "$(cat /sys/class/block/vda/ro)" = 0 ] || go=0; '
        'grep -q "^/dev/vda" /proc/mounts /proc/swaps; [ "$?" -eq 1 ] || go=0; '
        'for p in /sys/class/block/vda/vda*; do [ ! -e "$p" ] || go=0; done; '
        '/bin/busybox --list|grep -qx fsync || go=0; gi=0; gw=125; gf=125; gv=error; gb=125;gs=125; '
        'if [ "$go" -eq 1 ] && [ "$mvo_de:$mvo_me:$mvo_mp:$mvo_z" = 0:0:0:0 ] '
        '&& [ "$mvo_n" -gt 0 ] && [ "$mvo_n" -le 33554432 ]; then gi=1; '
        '(head -c "$mvo_n" "$mvo_ram/boot/initramfs-virt"; printf "%s\\n" "$?" >"$mvo_dir/hr") '
        '| dd of=/dev/vda bs=4096 conv=notrunc; gw=$?; '
        '/bin/busybox fsync /dev/vda; gf=$?; '
        'head -c "$mvo_n" /dev/vda >"$mvo_dir/rb"; gb=$?; '
        'gv=$(sha256sum "$mvo_dir/rb"); gs=$?; gv=${gv%% *}; fi; '
        'mvo_pf genExportPreflight "$go"; mvo_pf genExportInvocation "$gi"; '
        'gh=125; [ "$gi" -eq 0 ] || read -r gh <"$mvo_dir/hr"; '
        'mvo_pf genExportStatuses "$gh:$gw:$gf:$gb:$gs"; '
        'mvo_pf genExportSHA256 "$gv"; mvo_pf genExportDone 1\n')
    generation_send(console, owner, marker, command, "genExportDone", "1", seconds=60)
    for key in ("genExportPreflight", "genExportInvocation", "genExportStatuses", "genExportSHA256"):
        facts[key] = guest_value(console, marker, key)
    facts["genExportDone"] = "1"
    require(facts["genExportInvocation"] in ("0", "1"), "initramfsObservation")
    export_statuses = facts["genExportStatuses"].split(":")
    require(len(export_statuses) == 5, "initramfsObservation")
    for value in export_statuses:
        tool_exit_status(value)
    attempted = facts["genExportInvocation"] == "1"
    result.update(exportWriteAttempted=attempted, exportDiskUsed=attempted,
                  blankTargetPreserved=False if attempted else None,
                  exportProducerExitStatus=int(export_statuses[0]), exportWriteExitStatus=int(export_statuses[1]),
                  exportFlushExitStatus=int(export_statuses[2]), exportReadbackExitStatus=int(export_statuses[3]),
                  exportReadbackHashExitStatus=int(export_statuses[4]))
    exported = (valid and attempted and all(value == "0" for value in export_statuses)
                and facts["genExportSHA256"] == facts["genArchiveSHA256"])
    command = (
        'read -r mvo_dd mvo_wc <"$mvo_dir/generation.drain"; mvo_rr=$?; '
        'mvo_dc=$(cat "$mvo_dir/generation.discard"); mvo_cr=$?; '
        'mvo_pf genDrain "$mvo_rr:$mvo_dd:$mvo_wc:$mvo_cr:$mvo_dc"; '
        'mvo_sim_hash genLiveWorldAfter /etc/apk/world 4096; '
        'mvo_sim_hash genLiveDatabaseAfter /lib/apk/db/installed 1048576; '
        'mvo_sim_hash genLiveRepositoriesAfter /etc/apk/repositories 4096; mvo_pf genAfterDone 1\n')
    generation_send(console, owner, marker, command, "genAfterDone", "1")
    facts.update(genDrain=guest_value(console, marker, "genDrain"), genAfterDone="1")
    exported = exported and facts["genDrain"] == "0:0:0:0:0" and facts["genPipeline"] == "0"
    for key, before in (("genLiveWorldAfter", "toolsLiveWorldAfter"),
                        ("genLiveDatabaseAfter", "toolsLiveDatabaseAfter"),
                        ("genLiveRepositoriesAfter", "toolsLiveRepositoriesAfter")):
        facts[key], facts[key + "Status"] = guest_value(console, marker, key), guest_value(console, marker, key + "Status")
        require(facts[key + "Status"] == "0" and facts[key] == existing_facts[before], "apkToolsChanged")
    result.update(guestArchiveExportComplete=bool(exported), generationLiveStateBytesPreserved=True)
    return facts


def retain_generated_archive(directory, artifacts, original, result):
    require(result["guestArchiveExportComplete"] is True, "initramfsExport")
    length, expected = result["generatedArchiveBytes"], result["generatedArchiveSHA256"]
    require(type(length) is int and 0 < length <= EXPORT_LIMIT
            and re.fullmatch(r"[0-9a-f]{64}", expected), "initramfsExport")
    safe_directory(directory, private=True)
    lock = os.open(directory / "writer.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    disk = output = None
    try:
        locked = os.fstat(lock)
        require(stat.S_ISREG(locked.st_mode) and locked.st_uid == os.geteuid() and locked.st_nlink == 1
                and stat.S_IMODE(locked.st_mode) == 0o600, "initramfsSource")
        lock_stamp = lambda st: (st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid,
                                 st.st_nlink, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        require(lock_stamp(locked) == lock_stamp((directory / "writer.lock").lstat()), "initramfsSource")
        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        require(lock_stamp(locked) == lock_stamp(os.fstat(lock))
                == lock_stamp((directory / "writer.lock").lstat()), "initramfsSource")
        path = directory / "disk.raw"
        disk = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        before = os.fstat(disk)
        identity = lambda st: (st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid, st.st_nlink, st.st_size)
        require(stat.S_ISREG(before.st_mode) and identity(before) == tuple(original)
                and identity(before) == identity(path.lstat()), "initramfsSource")
        destination = artifacts / "generated-initramfs.gz"
        output = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        digest, offset = hashlib.sha256(), 0
        deadline = time.monotonic() + 30
        require(lock_stamp(locked) == lock_stamp(os.fstat(lock))
                == lock_stamp((directory / "writer.lock").lstat()), "initramfsSource")
        while offset < length:
            require(time.monotonic() < deadline, "initramfsExport")
            block = os.pread(disk, min(65536, length - offset), offset)
            require(bool(block), "initramfsExport")
            digest.update(block)
            view = memoryview(block)
            while view:
                count = os.write(output, view)
                require(count > 0, "initramfsExport")
                view = view[count:]
            offset += len(block)
        after = os.fstat(disk)
        stable = lambda st: (*identity(st), st.st_blocks, st.st_mtime_ns, st.st_ctime_ns)
        require(digest.hexdigest() == expected and stable(before) == stable(after) == stable(path.lstat()),
                "initramfsExport")
        require(lock_stamp(locked) == lock_stamp(os.fstat(lock))
                == lock_stamp((directory / "writer.lock").lstat()), "initramfsSource")
        os.fsync(output); os.fchmod(output, 0o400); os.fsync(output)
        parent = os.open(artifacts, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(parent)
        finally: os.close(parent)
        result.update(hostArchiveRetentionComplete=True, retainedArchiveBytes=length,
                      retainedArchiveSHA256=expected, retainedArchiveBasename=destination.name,
                      exportDiskIdentityPreserved=True, bytesBeyondExportVerified=False)
        return destination
    finally:
        if output is not None: os.close(output)
        if disk is not None: os.close(disk)
        os.close(lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--verify-apks", action="store_true",
                        help="Verify 49 carrier archives with the stock live APK tool; never apply packages.")
    parser.add_argument("--simulate-apks", action="store_true",
                        help="Also simulate dependency resolution over live and fresh tmpfs metadata; never apply packages.")
    parser.add_argument("--prepare-apk-root", action="store_true",
                        help="Apply the verified kit to one new tmpfs root with all package scripts disabled.")
    parser.add_argument("--prepare-apk-tools", action="store_true",
                        help="Also prepare and verify staged helper tools through a true chroot in temporary memory.")
    parser.add_argument("--generate-initramfs", action="store_true",
                        help="Generate and retain a matching archive through only the new lab disk; no OS installation.")
    parser.add_argument("--archive-inspector-sha")
    parser.add_argument("--payload-bounds", type=Path)
    parser.add_argument("--payload-bounds-sha")
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--carrier", type=Path, required=True)
    parser.add_argument("--carrier-sha", required=True)
    options = parser.parse_args()
    options.prepare_apk_tools = options.prepare_apk_tools or options.generate_initramfs
    options.prepare_apk_root = options.prepare_apk_root or options.prepare_apk_tools
    options.simulate_apks = options.simulate_apks or options.prepare_apk_root
    options.verify_apks = options.verify_apks or options.simulate_apks
    if not options.run:
        print("SKIP: explicit --run required for one new disposable offline delivery fixture.")
        return 0
    safe_directory(ROOT / ".lab")
    artifacts = ROOT / (".lab/support-media-live-" + uuid.uuid4().hex)
    artifacts.mkdir(mode=0o700)
    safe_directory(artifacts, private=True)
    directory = artifacts / "Delivery.macopenvm"
    owner = observed = None
    phase = "pins"
    result = dict(schemaVersion=1, scope="new-offline-readonly-support-delivery", status="failed",
                  formattingPerformed=False, installationPerformed=False, apkActionPerformed=False,
                  networkActionPerformed=False, GUIActionPerformed=False, credentialsStored=False,
                  windowsCompatibilityVerified=False, minimumMacOS14Verified=False,
                  guestShutdownVerified=False, forcedCleanupUsed=False)
    try:
        candidate, carrier, identities = verify_inputs(options)
        if options.prepare_apk_root:
            preparation_bounds(options, carrier)
        if options.generate_initramfs:
            generation_metadata()
            archive_inspector = capture_archive_inspector(options.archive_inspector_sha)
            result["archiveInspectorSHA256"] = options.archive_inspector_sha
        packages = apk_inventory(carrier, options.carrier.parent / "staging") if options.verify_apks else None
        if options.verify_apks:
            result.update(apkVerificationRequested=True, apkVerificationPerformed=False,
                          packageApplicationPerformed=False, dependencySimulationPerformed=False,
                          verificationPackageScriptsExecuted=False, trustImported=False,
                          apkBootstrapSource="normal-stock-live-ISO")
        versions = package_identities = None
        if options.simulate_apks:
            manifest = read_json(options.carrier.parent / "staging/license-source-manifest.json",
                expected_sha=next(entry["sha256"] for entry in carrier["stagingInventory"]
                                  if entry["path"] == "license-source-manifest.json"))
            versions = {row["P"]: row["V"] for row in manifest["packages"]}
            package_identities = {row["P"]: row for row in manifest["packages"]}
            require(len(versions) == 49, "apkManifest")
        cli = options.candidate.parent / "macopenvm"
        iso = options.carrier.parent / "support-carrier.iso"
        result.update(cliSHA256=candidate["cliSHA256"], sourceSHA256=candidate["sourceSHA256"],
                      supportImageSHA256=carrier["isoSHA256"], supportChecksumCount=54)
        phase = "signature"
        run_tool(Path("/usr/bin/codesign"), ["--verify", "--strict", str(cli)], artifacts, "signature")
        out, err = run_tool(Path("/usr/bin/codesign"), ["-d", "--entitlements", ":-", str(cli)], artifacts, "entitlements")
        import plistlib
        plist = re.search(rb"<\?xml.*?</plist>", out + err, re.DOTALL)
        require(plist is not None and plistlib.loads(plist.group()) == {"com.apple.security.virtualization": True},
                "signatureScope")
        phase = "host"
        probe = json.loads(run_tool(cli, ["probe"], artifacts, "probe")[0], object_pairs_hook=unique_object)
        require(probe["virtualizationSupported"] is True and probe["virtualizationEntitled"] is True, "hostUnavailable")
        phase = "create"
        run_tool(cli, ["create", "--directory", str(directory), "--name", "Original support delivery preflight",
                       "--media", str(ROOT / ASSETS[0][0]), "--support-media", str(iso),
                       "--kernel", str(ROOT / ASSETS[1][0]), "--initrd", str(ROOT / ASSETS[2][0]),
                       "--kernel-arguments", BOOT_ARGUMENTS, "--cpus", "2", "--memory-mib", "2048",
                       "--disk-gib", "8", "--network", "disconnected"], artifacts, "create")
        config = read_json(directory / "configuration.json")
        require(config["guest"] == "linux" and config["backend"] == "appleVz"
                and config["boot"] == "linuxKernel" and config["architecture"] == "arm64"
                and config["cpuCount"] == 2 and config["memoryBytes"] == 2 << 30
                and config["diskBytes"] == DISK_BYTES and config["diskFile"] == "disk.raw"
                and config["network"] == "disconnected" and config["kernelArguments"] == BOOT_ARGUMENTS
                and config["installationMedia"] == str(ROOT / ASSETS[0][0])
                and config["supportMedia"] == str(iso)
                and config["kernel"] == str(ROOT / ASSETS[1][0])
                and config["initialRamdisk"] == str(ROOT / ASSETS[2][0]), "createdScope")
        protected = {name: stable_file(directory / name, limit=1 << 20)[:2]
                     for name in ("configuration.json", "machine-identity.bin")}
        disk = inspect_blank_disk(directory)
        disk_stat = (directory / "disk.raw").lstat()
        original_disk_identity = (disk_stat.st_dev, disk_stat.st_ino, disk_stat.st_mode,
                                  disk_stat.st_uid, disk_stat.st_gid, disk_stat.st_nlink, disk_stat.st_size)
        from managed_serial import ManagedSerial
        owner = ManagedSerial(cli, ["run", "--directory", str(directory), "--seconds", "600"],
                              cwd=artifacts, artifacts=artifacts, label="live")
        phase = "login"
        owner.launch()
        console = GuestConsole(owner)
        console.expect(b"localhost login: ", 120)
        owner.write(b"root\n", deadline=time.monotonic() + 3)
        console.expect(b"localhost:~# ", 30)
        marker = "mvo-support-" + uuid.uuid4().hex
        phase = "guest-facts"
        commands = [
            (f"printf '\\n{marker}.arch=%s\\n' \"$(uname -m)\"; printf '\\n{marker}.kernel=%s\\n' \"$(uname -r)\"; printf '\\n{marker}.release=%s\\n' \"$(cat /etc/alpine-release)\"; printf '\\n{marker}.root=%s\\n' \"$(awk '$2==\"/\"{{print $1\":\"$3}}' /proc/mounts)\"\n", "release", "3.24.2"),
            (f"printf '\\n{marker}.blocks=%s\\n' \"$(cat /sys/class/block/vda/size)\"; printf '\\n{marker}.ro=%s\\n' \"$(cat /sys/class/block/vda/ro)\"; if grep -q '^/dev/vda' /proc/mounts; then printf '\\n{marker}.mounted=1\\n'; else printf '\\n{marker}.mounted=0\\n'; fi\n", "mounted", "0"),
            (f"printf '\\n{marker}.head=%s\\n' \"$(dd if=/dev/vda bs=512 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)\"; printf '\\n{marker}.tail=%s\\n' \"$(dd if=/dev/vda bs=512 skip={DISK_BYTES // 512 - 1} count=1 2>/dev/null | sha256sum | cut -d' ' -f1)\"; printf '\\n{marker}.net=%s\\n' \"$(ls /sys/class/net)\"\n", "net", "lo"),
        ]
        for command, key, expected in commands:
            send(console, owner, marker, command, key, expected)
        phase = "support-discovery"
        command = f"mvo_dev=; mvo_count=0; for d in /dev/sda /dev/sdb; do if blkid \"$d\" 2>/dev/null | grep -q 'LABEL=\"MVO_SUPPORT\"'; then mvo_dev=$d; mvo_count=$((mvo_count+1)); fi; done; printf '\\n{marker}.supportDevice=%s\\n' \"$mvo_dev\"; printf '\\n{marker}.supportCount=%s\\n' \"$mvo_count\"\n"
        send(console, owner, marker, command, "supportCount", "1")
        prefix = (marker + ".supportDevice=").encode()
        rows = [line[len(prefix):] for line in console.lines(time.monotonic() + 3) if line.startswith(prefix)]
        require(len(rows) == 1 and rows[0] in (b"/dev/sda", b"/dev/sdb"), "supportDevice")
        device = rows[0].decode()
        command = f"printf '\\n{marker}.supportRO=%s\\n' \"$(cat /sys/class/block/${{mvo_dev#/dev/}}/ro)\"; printf '\\n{marker}.supportBlocks=%s\\n' \"$(cat /sys/class/block/${{mvo_dev#/dev/}}/size)\"\n"
        send(console, owner, marker, command, "supportBlocks", str(carrier["isoBytes"] // 512))
        console.line((marker + ".supportRO=1").encode(), 10)
        phase = "support-mount"
        command = f"mkdir /media/mvo-support && mount -t iso9660 -o ro,norock \"$mvo_dev\" /media/mvo-support; printf '\\n{marker}.mountStatus=%s\\n' \"$?\"; printf '\\n{marker}.mountRO=%s\\n' \"$(awk '$2==\"/media/mvo-support\"{{print $3\":\"$4}}' /proc/mounts)\"\n"
        send(console, owner, marker, command, "mountStatus", "0")
        mount_prefix = (marker + ".mountRO=").encode()
        mount_rows = [line[len(mount_prefix):] for line in console.lines(time.monotonic() + 3) if line.startswith(mount_prefix)]
        require(len(mount_rows) == 1 and re.fullmatch(rb"iso9660:ro(?:,[a-z0-9=._-]+)*", mount_rows[0]), "mountReadOnly")
        options_applied = mount_rows[0].split(b":", 1)[1].split(b",")
        require(b"norock" in options_applied and b"nojoliet" not in options_applied, "mountReadOnly")
        phase = "passive-repository-scope"
        command = f"mvo_repo_ok=0; if [ -s /etc/apk/repositories ]; then mvo_repo_ok=1; for token in MVO_SUPPORT /media/mvo-support \"/media/${{mvo_dev#/dev/}}\"; do grep -Fq \"$token\" /etc/apk/repositories; mvo_grep=$?; [ \"$mvo_grep\" -eq 1 ] || mvo_repo_ok=0; done; fi; mvo_markers=error; mvo_marker_paths=$(find /media/mvo-support -maxdepth 3 -name .boot_repository -type f); mvo_find=$?; if [ \"$mvo_find\" -eq 0 ] && [ -z \"$mvo_marker_paths\" ]; then mvo_markers=0; fi; printf '\\n{marker}.repositoryCarrierAbsent=%s\\n' \"$mvo_repo_ok\"; printf '\\n{marker}.supportBootMarkers=%s\\n' \"$mvo_markers\"\n"
        send(console, owner, marker, command, "supportBootMarkers", "0")
        console.line((marker + ".repositoryCarrierAbsent=1").encode(), 10)
        phase = "support-hashes"
        command = f"printf '\\n{marker}.supportHash=%s\\n' \"$(sha256sum \"$mvo_dev\" | cut -d' ' -f1)\"; printf '\\n{marker}.sumsHash=%s\\n' \"$(sha256sum /media/mvo-support/SHA256SUMS | cut -d' ' -f1)\"\n"
        send(console, owner, marker, command, "sumsHash", carrier["sha256SumsSHA256"])
        console.line((marker + ".supportHash=" + carrier["isoSHA256"]).encode(), 10)
        command = f"cd /media/mvo-support && sha256sum -c SHA256SUMS >/tmp/mvo-support-checks 2>&1; mvo_rc=$?; cd /root; printf '\\n{marker}.checksumStatus=%s\\n' \"$mvo_rc\"; printf '\\n{marker}.checksumOK=%s\\n' \"$(grep -c ': OK$' /tmp/mvo-support-checks)\"; printf '\\n{marker}.complete version=1\\n'\n"
        send(console, owner, marker, command, "checksumOK", "54")
        facts = dict(arch="aarch64", kernel="6.18.52-0-virt", release="3.24.2", blocks=str(DISK_BYTES // 512),
                     ro="0", mounted="0", head=ZERO_SHA, tail=ZERO_SHA, net="lo", supportDevice=device,
                     supportCount="1", supportRO="1", supportBlocks=str(carrier["isoBytes"] // 512),
                     mountStatus="0", mountRO=mount_rows[0].decode(), supportHash=carrier["isoSHA256"],
                     sumsHash=carrier["sha256SumsSHA256"], checksumStatus="0", checksumOK="54",
                     repositoryCarrierAbsent="1", supportBootMarkers="0")
        verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        if options.verify_apks:
            phase = "apk-verification"
            facts.update(verify_apks(console, owner, marker, packages, artifacts, result,
                                    batch_size=25 if options.generate_initramfs else 6 if options.prepare_apk_tools else 4))
            verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        if options.simulate_apks:
            phase = "apk-simulation"
            facts.update(simulate_apks(console, owner, marker, versions, artifacts, result))
            verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        if options.prepare_apk_root:
            phase = "apk-root-preparation"
            facts.update(prepare_apk_root(console, owner, marker, versions, package_identities,
                                         artifacts, result, facts))
            verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        if options.prepare_apk_tools:
            phase = "apk-tools-preparation"
            facts.update(prepare_apk_tools(console, owner, marker, artifacts, result, facts))
            verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        if options.generate_initramfs:
            phase = "initramfs-generation"
            facts.update(generate_initramfs(console, owner, marker, artifacts, result, facts))
            verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        result.update(guestFacts=facts, serialMarker=marker, cursorReports=console.queries)
        phase = "guest-poweroff"
        owner.write(b"poweroff\n", deadline=time.monotonic() + 3)
        observed = owner.wait(deadline=time.monotonic() + 45)
        require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
                and observed.executable_unchanged, "guestExit")
        phase = "post-shutdown"
        history = read_json(directory / "runtime.json", 4096)
        require(history["schemaVersion"] == 1 and history["sequence"] > 0
                and history["snapshot"]["state"] == "stopped" and history["snapshot"]["backendActive"] is False
                and history["snapshot"].get("operation") is None
                and history["snapshot"]["outcome"] == "guestStopped" and "vmID" not in history, "guestHistory")
        writer_available(directory)
        if not options.generate_initramfs or result.get("exportWriteAttempted") is False:
            require(inspect_blank_disk(directory) == disk, "blankTargetChanged")
        require({name: stable_file(directory / name, limit=1 << 20)[:2] for name in protected} == protected,
                "registrationChanged")
        require(verify_inputs(options)[2] == identities, "inputsChanged")
        result.update(status="passed", guestShutdownVerified=True,
                      blankTargetPreserved=not bool(result.get("exportWriteAttempted")),
                      writerAvailable=True, historyOutcome="guestStopped", historyVMIDFieldAvailable=False)
        if options.generate_initramfs and result.get("guestArchiveExportComplete"):
            phase = "initramfs-host-retention"
            archive = retain_generated_archive(directory, artifacts, original_disk_identity, result)
            inspection = archive_inspector(archive, result["generatedArchiveBytes"],
                                          result["generatedArchiveSHA256"])
            inventory = (json.dumps(inspection, indent=2, sort_keys=True) + "\n").encode()
            require(len(inventory) <= 2 << 20, "initramfsObservation")
            inspection_path = artifacts / "archive-inspection.json"
            with inspection_path.open("xb") as out:
                out.write(inventory); out.flush(); os.fsync(out.fileno())
            inspection_path.chmod(0o400)
            result["archiveInspection"] = {key: value for key, value in inspection.items()
                                           if key != "inventory"}
            result.update(archiveInspectionBasename=inspection_path.name,
                          archiveInspectionSHA256=hashlib.sha256(inventory).hexdigest(),
                          archiveInventoryCount=len(inspection["inventory"]))
        if options.simulate_apks and not result["dependencyClosureComplete"]:
            result.update(status="closure-incomplete", failurePhase="apk-simulation",
                          failureCode="apkSimulationOutput")
        elif options.prepare_apk_root and not result["apkRootPreparationComplete"]:
            result.update(status="preparation-incomplete", failurePhase="apk-root-preparation",
                          failureCode="apkRootObservation")
        elif options.prepare_apk_tools and not result["apkToolsPreparationComplete"]:
            result.update(status="tools-incomplete", failurePhase="apk-tools-preparation",
                          failureCode="apkToolsObservation")
        elif options.generate_initramfs and (not result.get("hostArchiveRetentionComplete")
                                            or not result.get("archiveInspection", {}).get("closureComplete")):
            result.update(status="archive-incomplete", failurePhase="initramfs-verification",
                          failureCode="initramfsObservation")
    except BaseException as error:
        result.update(status="failed", failurePhase=phase, failureKind=type(error).__name__)
        if isinstance(error, (DeliveryFailure, PreflightFailure)):
            result["failureCode"] = error.code
    finally:
        if owner is not None:
            final, requested = cleanup_actual(owner, artifacts, "live", observed)
            result["runner"] = status(final)
            result["forcedCleanupUsed"] = requested and final.started
            if requested:
                result.update(status="failed", guestShutdownVerified=False)
        try:
            save(artifacts / "delivery-result.json", result)
        except BaseException:
            result.update(status="failed", guestShutdownVerified=False)
    print("Offline support delivery: " + result["status"] + "; private evidence preserved.")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
