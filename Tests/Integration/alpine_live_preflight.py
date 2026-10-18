#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit fresh offline Alpine live serial preflight; no format/install/package action.

The caller owns one NEW disposable VM only. Observation failure never restarts it;
explicit failure cleanup retains the actual supervisor until its child is reaped.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
PAIR = ROOT / ".lab/paired-linux-boot-5c8f39b498064e0187880d7d9926a126"
CLI = PAIR / "macopenvm"
CLI_SHA = "daa48d710afa07f8b890ad8570150efe6801c0ed2d60b4fec2c72e63978aefde"
SOURCE_SHA = "ea458fa98e4c4f42b1249cfbd1a9702a375f815a87beed113c368bf1ef0c7bda"
CANDIDATE_SHA = "319e0a99d1905a7ab92740150bdbd9e0752bd4f2e394c918e55602df6091eab9"
MANIFEST_SHA = "103455ea0e224bd3dae1d538f2867ba56682b90d63e64499d1098242b04afbe4"
SUPERVISOR_SHA = "3083cb626c9f0c2df62b9792ffed6166ae52c3a0a504a1dce932a9ee317ebb2d"
ASSETS = (
    (".lab/media/alpine-virt-3.24.2-aarch64.iso", 93304832,
     "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"),
    (".lab/linux/Image", 36241408,
     "e698a107e4d04117db1a7b0daee99bdae5f0647fba2af50f3cd020a666950ab9"),
    (".lab/linux/initramfs-virt", 10161578,
     "5b9de8ff7b4f3055f6cf940e1ff869790415cf81b7ea1e399ee60448bc1a2c4d"),
)
DISK_BYTES = 8 << 30
BLOCKS = DISK_BYTES // 512
ZERO_SHA = hashlib.sha256(bytes(512)).hexdigest()
BOOT_ARGUMENTS = "console=hvc0 modules=loop,squashfs,sd-mod,usb-storage"
FAILURE_CODES = frozenset((
    "blankTargetChanged", "conflictingGuestFact", "createdConfigurationMismatch", "cursorQueryLimit",
    "duplicateGuestMarker", "duplicateMetadataKey", "duplicateOrMalformedGuestMarker", "evidenceLimit",
    "evidenceWrite", "existingVMForbidden", "guestCommandLimit", "guestExitNotConfirmed",
    "guestHistoryNotConfirmed", "guestMarkerDeadline", "guestPromptDeadline", "incompleteGuestMarkers",
    "malformedGuestMarker", "nativeUnavailable", "newArtifactSelection", "nonMinimalSignature",
    "pinnedFileChanged", "pinnedHashMismatch", "pinnedSizeMismatch", "protectedRegistrationChanged",
    "serialCaptureIncomplete", "shortPinnedRead", "sourceAssociation", "sourceManifestLimit",
    "sourceManifestPath", "sourceOrMediaChanged", "sourceSetChanged", "targetChangedDuringRead",
    "targetNotFreshBlankSparse", "targetSeedNotZero", "toolDidNotPass", "toolEvidenceNotRecorded",
    "unexpectedHistoryIdentityField", "unexpectedLiveRoot", "unknownGuestMarker", "unsafeDirectoryAncestry",
    "unsafeDirectorySelection", "unsafeOwnedDirectory", "unsafePinnedFile", "unsafeWriterRecord",
    "writerChangedDuringProbe",
))


class PreflightFailure(RuntimeError):
    def __init__(self, code):
        # Call sites use fixed app-owned guard names, never paths or guest text.
        self.code = code if code in FAILURE_CODES else "invalidFailureCode"
        super().__init__(self.code)


def require(value, code):
    if not value:
        raise PreflightFailure(code)


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def safe_directory(path, *, private=False):
    require(path.is_absolute() and path == Path(os.path.abspath(path))
            and len(path.parts) <= 32, "unsafeDirectorySelection")
    for component in reversed((path, *path.parents)):
        info = component.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid in (0, os.geteuid())
                and info.st_mode & 0o022 == 0, "unsafeDirectoryAncestry")
    info = path.lstat()
    require(info.st_uid == os.geteuid()
            and (not private or stat.S_IMODE(info.st_mode) == 0o700), "unsafeOwnedDirectory")


def verify_ancestry():
    safe_directory(ROOT / ".lab")
    safe_directory(PAIR, private=True)
    for name, _, _ in ASSETS:
        safe_directory((ROOT / name).parent)


def stable_file(path, *, limit, expected_bytes=None, expected_sha=None, content=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid in (0, os.geteuid())
                and before.st_nlink == 1 and before.st_mode & 0o022 == 0
                and 0 <= before.st_size <= limit, "unsafePinnedFile")
        require(expected_bytes is None or before.st_size == expected_bytes, "pinnedSizeMismatch")
        digest = hashlib.sha256()
        body = bytearray()
        remaining = before.st_size
        while remaining:
            chunk = os.read(fd, min(1 << 20, remaining))
            require(chunk, "shortPinnedRead")
            remaining -= len(chunk)
            digest.update(chunk)
            if content:
                body.extend(chunk)
        require(not os.read(fd, 1) and stamp(before) == stamp(os.fstat(fd)) == stamp(path.lstat()),
                "pinnedFileChanged")
        value = digest.hexdigest()
        require(expected_sha is None or value == expected_sha, "pinnedHashMismatch")
        return (stamp(before), value, bytes(body))
    finally:
        os.close(fd)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicateMetadataKey")
        result[key] = value
    return result


def read_json(path, maximum=65536, expected_sha=None):
    body = stable_file(path, limit=maximum, expected_sha=expected_sha, content=True)[2]
    return json.loads(body, object_pairs_hook=unique_object)


def save(path, value):
    body = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    require(len(body) <= 65536, "evidenceLimit")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        view = memoryview(body)
        while view:
            count = os.write(fd, view)
            require(count > 0, "evidenceWrite")
            view = view[count:]
        os.fsync(fd)
    finally:
        os.close(fd)


def verify_inputs():
    verify_ancestry()
    candidate = read_json(PAIR / "candidate.json", expected_sha=CANDIDATE_SHA)
    manifest = read_json(PAIR / "production-before.json", expected_sha=MANIFEST_SHA)
    require(candidate["cliSHA256"] == CLI_SHA and candidate["sourceSHA256"] == SOURCE_SHA
            and manifest["sha256"] == SOURCE_SHA, "sourceAssociation")
    files = manifest["files"]
    require(isinstance(files, list) and 1 <= len(files) <= 128, "sourceManifestLimit")
    expected = set()
    for entry in files:
        name = entry["path"]
        require(isinstance(name, str) and not Path(name).is_absolute()
                and ".." not in Path(name).parts and name not in expected, "sourceManifestPath")
        expected.add(name)
        stable_file(ROOT / name, limit=2 << 20, expected_bytes=entry["bytes"], expected_sha=entry["sha256"])
    actual_swift = {str(path.relative_to(ROOT)) for folder in
        ("App", "Backends", "CLI", "Core", "RuntimeIPC", "Storage")
        for path in (ROOT / folder).rglob("*.swift")}
    actual_swift.add("Package.swift")  # The manifest also pins the root package definition.
    require(actual_swift == {name for name in expected if name.endswith(".swift")}, "sourceSetChanged")
    identity = stable_file(CLI, limit=32 << 20, expected_bytes=candidate["cliBytes"], expected_sha=CLI_SHA)[:2]
    assets = [stable_file(ROOT / name, limit=size, expected_bytes=size, expected_sha=digest)[:2]
              for name, size, digest in ASSETS]
    stable_file(Path(__file__).with_name("managed_serial.py"), limit=65536, expected_sha=SUPERVISOR_SHA)
    return identity, assets


def status(value):
    return dict(started=value.started, returncode=value.returncode,
                stdoutBytes=value.stdout_bytes, stderrBytes=value.stderr_bytes,
                bothEOF=value.stdout_eof and value.stderr_eof,
                drainsFinished=value.drains_finished, pipesClosed=value.pipes_closed,
                transcriptsClosed=value.transcripts_closed, firstError=value.first_error,
                transcriptTruncated=value.transcript_truncated,
                executableUnchanged=value.executable_unchanged)


def closed_resources(owner, value):
    if not value.started:
        # No child means no invented terminal status or pipe EOF. A failed launch
        # still has to finish every prepared transcript/drain before return.
        return not owner._launch_attempted or (owner._launch_resolved
            and value.drains_finished and value.transcripts_closed)
    return (value.returncode is not None and value.stdout_eof and value.stderr_eof
            and value.drains_finished and value.pipes_closed and value.transcripts_closed)


def cleanup_actual(owner, artifacts, label, observed=None):
    """Retain the actual owner until wait/cleanup proves closure, despite reporting faults."""
    recorded = False
    cleanup_requested = False
    while True:
        try:
            if observed is not None and closed_resources(owner, observed):
                return observed, cleanup_requested
            if not owner._launch_attempted:
                observed = owner.snapshot(deadline=time.monotonic() + 1)
                continue
            try:
                observed = owner.wait(deadline=time.monotonic() + .2)
                continue
            except BaseException:
                pass
            cleanup_requested = True
            observed = owner.cleanup(deadline=time.monotonic() + 10, kill_after=1)
        except BaseException:
            observed = None
            if not recorded:
                try:
                    value = owner.snapshot(deadline=time.monotonic() + 1)
                    save(artifacts / (label + "-cleanup-unconfirmed.json"), status(value))
                    recorded = True
                except BaseException:
                    pass
            try:
                print("Owned disposable runner remains retained; no restart.", flush=True)
            except BaseException:
                pass
            try:
                time.sleep(.2)
            except BaseException:
                pass


def run_tool(executable, args, artifacts, label, timeout=30):
    from managed_serial import ManagedSerial
    owner = ManagedSerial(executable, args, cwd=artifacts, artifacts=artifacts, label=label)
    observed = None
    try:
        owner.launch()
        observed = owner.wait(deadline=time.monotonic() + timeout)
        require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
                and observed.executable_unchanged, "toolDidNotPass")
        return observed.stdout, observed.stderr
    finally:
        final, _ = cleanup_actual(owner, artifacts, label, observed)
        try:
            save(artifacts / (label + "-status.json"), status(final))
        except BaseException:
            raise PreflightFailure("toolEvidenceNotRecorded") from None


class GuestConsole:
    def __init__(self, owner):
        self.owner = owner
        self.queries = 0

    def lines(self, deadline=None):
        value = self.owner.snapshot(deadline=deadline)
        require(value.first_error is None and value.stdout_bytes == len(value.stdout), "serialCaptureIncomplete")
        raw = value.stdout
        count = raw.count(b"\x1b[6n")
        require(self.queries <= count <= 64, "cursorQueryLimit")
        while self.queries < count:
            self.owner.write(b"\x1b[1;1R", deadline=min(deadline, time.monotonic() + 3) if deadline is not None else time.monotonic() + 3)
            self.queries += 1
        raw = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw).replace(b"\r", b"")
        return raw.split(b"\n")[:-1]

    def expect(self, needle, seconds):
        from managed_serial import ManagedSerialError
        deadline = time.monotonic() + seconds
        while True:
            self.lines(deadline)
            try:
                result = self.owner.expect(needle, deadline=min(deadline, time.monotonic() + .2))
                self.lines(deadline)
                require(time.monotonic() < deadline, "guestPromptDeadline")
                return result
            except ManagedSerialError as error:
                if error.code != "deadlineExceeded" or time.monotonic() >= deadline:
                    raise

    def line(self, exact, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            rows = [line for line in self.lines(deadline) if line == exact]
            require(len(rows) <= 1, "duplicateGuestMarker")
            if rows:
                require(time.monotonic() < deadline, "guestMarkerDeadline")
                return
            time.sleep(.025)
        raise PreflightFailure("guestMarkerDeadline")


def verify_guest_rows(lines, marker, facts):
    prefix = (marker + ".").encode()
    allowed = {key.encode(): value.encode() for key, value in facts.items()}
    found = {}
    for line in lines:
        if not line.startswith(prefix):
            continue  # Shell echoes contain the nonce inside a command, not at line start.
        row = line[len(prefix):]
        if row == b"complete version=1":
            key, value = b"complete", b"version=1"
        else:
            require(b"=" in row, "malformedGuestMarker")
            key, value = row.split(b"=", 1)
            require(key in allowed or key == b"root", "unknownGuestMarker")
        require(key not in found and 1 <= len(value) <= 256, "duplicateOrMalformedGuestMarker")
        found[key] = value
    require(set(found) == set(allowed) | {b"root", b"complete"}, "incompleteGuestMarkers")
    require(all(found[key] == value for key, value in allowed.items()), "conflictingGuestFact")
    require(re.fullmatch(rb"[^:\x00-\x20]{1,128}:(tmpfs|rootfs|ramfs|overlay)", found[b"root"])
            is not None, "unexpectedLiveRoot")
    return prefix + b"root=" + found[b"root"]


def inspect_blank_disk(directory):
    path = directory / "disk.raw"
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600
                and before.st_size == DISK_BYTES and before.st_blocks == 0, "targetNotFreshBlankSparse")
        require(os.pread(fd, 512, 0) == bytes(512)
                and os.pread(fd, 512, DISK_BYTES - 512) == bytes(512), "targetSeedNotZero")
        require(stamp(before) == stamp(os.fstat(fd)) == stamp(path.lstat()), "targetChangedDuringRead")
        return stamp(before)
    finally:
        os.close(fd)


def writer_available(directory):
    path = directory / "writer.lock"
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600, "unsafeWriterRecord")
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        require(stamp(before) == stamp(os.fstat(fd)) == stamp(path.lstat()), "writerChangedDuringProbe")
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--artifacts", type=Path)
    options = parser.parse_args()
    if not options.run:
        print("SKIP: explicit --run is required for one new disposable offline live fixture.")
        return 0
    artifacts = options.artifacts or ROOT / (".lab/alpine-live-preflight-" + uuid.uuid4().hex)
    require(artifacts.is_absolute() and artifacts == Path(os.path.abspath(artifacts))
            and artifacts.parent == ROOT / ".lab"
            and re.fullmatch(r"alpine-live-preflight-[0-9a-f]{32}", artifacts.name), "newArtifactSelection")
    verify_ancestry()
    artifacts.mkdir(mode=0o700)
    safe_directory(artifacts, private=True)
    directory = artifacts / "Live.macopenvm"
    owner = None
    observed = None
    phase = "pins"
    result = dict(schemaVersion=1, scope="new-offline-live-linux-readonly-preflight", status="failed",
        formattingPerformed=False, installationPerformed=False, apkActionPerformed=False,
        networkActionPerformed=False, GUIActionPerformed=False, credentialsStored=False,
        windowsCompatibilityVerified=False, minimumMacOS14Verified=False,
        guestShutdownVerified=False, forcedCleanupUsed=False)
    try:
        identity, assets = verify_inputs()
        result.update(cliSHA256=CLI_SHA, productionSourceSHA256=SOURCE_SHA,
                      supervisorSHA256=SUPERVISOR_SHA, bootAssetSHA256=[entry[2] for entry in ASSETS])
        phase = "signature"
        run_tool(Path("/usr/bin/codesign"), ["--verify", "--strict", str(CLI)], artifacts, "signature")
        out, err = run_tool(Path("/usr/bin/codesign"), ["-d", "--entitlements", ":-", str(CLI)], artifacts, "entitlements")
        plist = re.search(rb"<\?xml.*?</plist>", out + err, re.DOTALL)
        require(plist is not None and plistlib.loads(plist.group()) == {"com.apple.security.virtualization": True}, "nonMinimalSignature")
        phase = "host-probe"
        probe = json.loads(run_tool(CLI, ["probe"], artifacts, "probe")[0], object_pairs_hook=unique_object)
        require(probe["virtualizationSupported"] is True and probe["virtualizationEntitled"] is True, "nativeUnavailable")
        phase = "create"
        require(not directory.exists(), "existingVMForbidden")
        run_tool(CLI, ["create", "--directory", str(directory), "--name", "Original offline live preflight",
            "--media", str(ROOT / ASSETS[0][0]), "--kernel", str(ROOT / ASSETS[1][0]),
            "--initrd", str(ROOT / ASSETS[2][0]), "--kernel-arguments", BOOT_ARGUMENTS,
            "--cpus", "2", "--memory-mib", "2048", "--disk-gib", "8", "--network", "disconnected"], artifacts, "create")
        configuration = read_json(directory / "configuration.json")
        require(configuration["guest"] == "linux" and configuration["backend"] == "appleVz"
                and configuration["boot"] == "linuxKernel" and configuration["architecture"] == "arm64"
                and configuration["cpuCount"] == 2 and configuration["memoryBytes"] == 2 << 30
                and configuration["diskBytes"] == DISK_BYTES and configuration["diskFile"] == "disk.raw"
                and configuration["network"] == "disconnected" and configuration["kernelArguments"] == BOOT_ARGUMENTS
                and configuration["kernel"] == str(ROOT / ASSETS[1][0])
                and configuration["initialRamdisk"] == str(ROOT / ASSETS[2][0])
                and configuration["installationMedia"] == str(ROOT / ASSETS[0][0]), "createdConfigurationMismatch")
        protected = {name: stable_file(directory / name, limit=1 << 20)[:2]
                     for name in ("configuration.json", "machine-identity.bin")}
        disk = inspect_blank_disk(directory)
        from managed_serial import ManagedSerial
        owner = ManagedSerial(CLI, ["run", "--directory", str(directory), "--seconds", "600"],
            cwd=artifacts, artifacts=artifacts, label="live")
        phase = "login"
        owner.launch()
        console = GuestConsole(owner)
        console.expect(b"localhost login: ", 120)
        owner.write(b"root\n", deadline=time.monotonic() + 3)
        console.expect(b"localhost:~# ", 30)
        phase = "readonly-guest-facts"
        marker = "mvo-live-" + uuid.uuid4().hex
        first = (
            f"printf '\\n{marker}.arch=%s\\n' \"$(uname -m)\"; "
            f"printf '\\n{marker}.kernel=%s\\n' \"$(uname -r)\"; "
            f"printf '\\n{marker}.release=%s\\n' \"$(cat /etc/alpine-release)\"; "
            f"printf '\\n{marker}.root=%s\\n' \"$(awk '$2==\"/\"{{print $1\":\"$3}}' /proc/mounts)\"\n")
        second = (
            f"printf '\\n{marker}.blocks=%s\\n' \"$(cat /sys/class/block/vda/size)\"; "
            f"printf '\\n{marker}.ro=%s\\n' \"$(cat /sys/class/block/vda/ro)\"; "
            f"if grep -q '^/dev/vda' /proc/mounts; then printf '\\n{marker}.mounted=1\\n'; "
            f"else printf '\\n{marker}.mounted=0\\n'; fi\n")
        third = (
            f"printf '\\n{marker}.head=%s\\n' \"$(dd if=/dev/vda bs=512 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)\"; "
            f"printf '\\n{marker}.tail=%s\\n' \"$(dd if=/dev/vda bs=512 skip={BLOCKS - 1} count=1 2>/dev/null | sha256sum | cut -d' ' -f1)\"\n")
        fourth = (
            f"printf '\\n{marker}.net=%s\\n' \"$(ls /sys/class/net)\"; "
            f"printf '\\n{marker}.complete version=1\\n'\n")
        # Keep each original read-only shell line below the live console editor's
        # small input bound, and acknowledge each group before sending another.
        for command, acknowledgement in ((first, ".release=3.24.2"),
                (second, ".mounted=0"), (third, ".tail=" + ZERO_SHA),
                (fourth, ".complete version=1")):
            require(len(command.encode()) <= 1024, "guestCommandLimit")
            owner.write(command.encode(), deadline=time.monotonic() + 3)
            console.line((marker + acknowledgement).encode(), 30)
            console.expect(b"localhost:~# ", 10)
        facts = {"arch": "aarch64", "kernel": "6.18.52-0-virt", "release": "3.24.2",
                 "blocks": str(BLOCKS), "ro": "0", "mounted": "0", "head": ZERO_SHA,
                 "tail": ZERO_SHA, "net": "lo"}
        for key, expected in facts.items():
            console.line((marker + "." + key + "=" + expected).encode(), 30)
        console.line((marker + ".complete version=1").encode(), 30)
        root_row = verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        result.update(serialMarker=marker, guestFacts=facts, rootMountDeclaration=root_row.decode(), cursorReports=console.queries)
        phase = "guest-poweroff"
        owner.write(b"poweroff\n", deadline=time.monotonic() + 3)
        observed = owner.wait(deadline=time.monotonic() + 45)
        require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
                and observed.executable_unchanged, "guestExitNotConfirmed")
        phase = "post-shutdown"
        history = read_json(directory / "runtime.json", 4096)
        require(history["schemaVersion"] == 1 and history["sequence"] > 0
                and history["snapshot"]["state"] == "stopped"
                and history["snapshot"]["backendActive"] is False
                and history["snapshot"].get("operation") is None
                and history["snapshot"]["outcome"] == "guestStopped", "guestHistoryNotConfirmed")
        # RuntimeRecord currently carries a session ID, but no VM ID field. Do
        # not claim an in-record VM identity binding from the fresh path alone.
        require("vmID" not in history, "unexpectedHistoryIdentityField")
        writer_available(directory)
        require(inspect_blank_disk(directory) == disk, "blankTargetChanged")
        require({name: stable_file(directory / name, limit=1 << 20)[:2] for name in protected} == protected, "protectedRegistrationChanged")
        require(verify_inputs() == (identity, assets), "sourceOrMediaChanged")
        result.update(status="passed", guestShutdownVerified=True, writerAvailable=True,
                      historyOutcome="guestStopped", historyVMIDFieldAvailable=False,
                      historyIdentityScope="fresh-owned-directory", blankTargetPreserved=True)
    except BaseException as error:
        result.update(status="failed", guestShutdownVerified=False,
                      failurePhase=phase, failureKind=type(error).__name__)
        if isinstance(error, PreflightFailure):
            result["failureCode"] = error.code
    finally:
        # Finalization is unconditional; no snapshot, report or print precedes
        # retention of the actual runner through terminal + EOF + closed drains.
        if owner is not None:
            final, cleanup_requested = cleanup_actual(owner, artifacts, "live", observed)
            result["forcedCleanupUsed"] = cleanup_requested and final.started
            result["runner"] = status(final)
            if cleanup_requested:
                result.update(status="failed", guestShutdownVerified=False)
        try:
            save(artifacts / "preflight-result.json", result)
        except BaseException:
            result.update(status="failed", guestShutdownVerified=False)
    try:
        print("Offline live serial preflight: " + result["status"] + "; private evidence preserved.")
    except BaseException:
        pass
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
