#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit, offline HVF firmware/TCG2 probe; never a Windows compatibility test.

Requires --run and the reviewed, locally built private Windows platform lab.
Creates a new fixture, attaches no OS disk, and preserves all stores and logs.
The artifact hashes deliberately select one reviewed build, not arbitrary EFI.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import resource
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
FIRMWARE = "source/edk2/Build/ArmVirtQemu-AArch64/NOOPT_CLANGDWARF/FV/QEMU_EFI.fd"
PROBE = "source/edk2/Build/MacOpenVMFirmwareLab/NOOPT_CLANGDWARF/AARCH64/MacOpenVMPlatformProbe.efi"
PINS = {
    FIRMWARE: (3_145_728, "c29ba1fa0d27148ab96a2805c1ec576777024c6e4412647e16911790c1a1c851"),
    PROBE: (28_672, "7186d46978eca379293c0d1efb32e1be80082705890e42a1f0d58a2e9c9b92bb"),
}
QEMU_SOURCE_SHA256 = "6ee1d1a61f68212476b27108c26da5f449dc09b626d42f8279ba0dc2e08fa858"
QEMU_PATCHED_HVF_SHA256 = "31e1ac2ba4b77ba282cd119a65ac204e5a9db44a906a7c6d92a769ba666960c2"
QEMU_GIC_KCONFIG_SHA256 = "1e0b95b19a306c3360a7a506dd59f41d3dcb3c7c02312f2cf58c539a92630098"
QEMU_TIMER_DIAGNOSTIC_SOURCES = {
    "target/arm/hvf/hvf.c": "82bec4345ec080be0b5684f40b0721dc29736ade3797cf3661ea6958e0be0bc1",
    "target/arm/hvf/trace-events": "7c565b53849acbeb858213c6797f93811350f686ba8d07f61c0cc26e45c31ec4",
}
QEMU_TIMER_DIAGNOSTIC_BINARY = "f634feb12498691e37e7d0017639dc7dcdae397bfb337103978ed38d0b4947e6"
QEMU_GIC_FEATURE_SOURCES = {
    "target/arm/hvf/hvf.c": "63fcea950f2a1b2025e4d0a79bf6d50b29e86ba564ec3c5b7107d79df455265e",
    "target/arm/hvf/trace-events": "71f328a44371d33e18ed1e628ba19808794ef1582865f59e52ed8b3247e1c41b",
}
QEMU_GIC_FEATURE_BINARY = "5084212a682087ab08cec89cacbae7043d00047bb74ad8a88f6221601b69f64c"
QEMU_PKCS7_ENVELOPE_BINARY = "ed753107501522f937d6293e7119a6a3ee2c5c9b0294e13e1fc0c5671ff0528c"
QEMU_VNC_BINARY = "26674b130d910136b31c7c576277639e8b4c5bc2bc499165acb8f39919e58529"
QEMU_VNC_DIRECTORY = "tools/qemu-vnc-candidate-1b9f04f265434bd08993c175502f5b89"
QEMU_VNC_KEYMAP = (27_086, "52cf4c523e686078699ed58761c7e1443080305237a5f67a3716832570c5c8e5")
QEMU_PKCS7_ENVELOPE_SOURCE = "599d0b762f8ba5326fe0387b9ec68e0117b09929665ca8612ad5569713f2dedc"
PK_PROBE = "tools/efi-pk-enrollment-candidate-0a4eb23b74e740bd96f02b3651ab2eb1/MacOpenVMPkEnrollmentProbe.efi"
PK_PROBE_PIN = (32_768, "a374ad5c4056d5bce64509d724c0a73e49ab2ff0c65807bda161ed1b315cb07e")
PK_VECTOR_PINS = {
    "full": ("PK-full.AUTH", 2044, "cf6ba07feec7d8c24e5ed1fd9711cea0e2a8f13764b8d6c1ec0d58797ecae9fc"),
    "bare": ("PK-bare.AUTH", 2025, "d8660faa5dd17ae3b4b2f1e32c57d3594e85d119864ca707fa4b24682ba5f93a"),
}
PK_ESL_PIN = (823, "ba87e4d66927f1793522eb6d1c949d4e18bd45763118363877349ec37d23c517")
CHAIN_PROBE = "tools/efi-positive-marker-boundary-candidate-ad57e3a0d7484bc0a1c857d6b45bc2df/MacOpenVMPositiveTrustChainProbe.efi"
CHAIN_PROBE_PIN = (40_960, "fcc1b912e156c5f9a3d48521d139335e3fd71eaa820171c5817316ce2b49dc2c")
CHAIN_INPUT_PINS = {
    "PK.AUTH": ("PK-full.AUTH", 2044, "04477cf227553386267fa3b15ee8ced92979da3574d618f6d3e1bf58a143718e"),
    "KEK.AUTH": ("KEK-full.AUTH", 2044, "3ff43600f0c646a44aa8cbcbb046cc82d945df10ff0249e5fd00855f92a8e78e"),
    "DB.AUTH": ("DB-full.AUTH", 2044, "cdb4132893a003451ca33ddaaf27ce82b490b6216f79eab772bd79ca766a8d02"),
    "PK.ESL": ("PK.ESL", *PK_ESL_PIN),
}
SIGNED_CHILD = "results/osslsigncode-positive-contract-20261006T214138Z-bf46e8bde01f41f39ec1934738e26623/outputs/MacOpenVMPlatformProbe.signed.efi"
SIGNED_CHILD_PIN = (30_120, "147c5e11d3c81459e174a77930eba3e4205c4df1b8b9def19f37c69018c4df72")
DISPLAY_PROBE = "tools/efi-display-input-candidate-1be71d8127ae4ccfbc03e4cde28b19e4/MacOpenVMDisplayInputProbe.efi"
DISPLAY_PROBE_PIN = (32_768, "d98fea5975ef70a5cf87abd756321e5218d6c4154ad5d9d1f9e437a24f0381ff")
MEASUREMENT_PROBE = "tools/efi-measurement-consistency-candidate-1e8e6f876f694c4eaf049069027d16d6/MacOpenVMMeasurementConsistencyProbe.efi"
MEASUREMENT_PROBE_PIN = (36_864, "309c91578ae11ad79b2ef2a5174ca2b14dc8d7f974e2352465a70dacd1a7c5be")
ANSI_CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
GUEST_LIMIT = 2_097_152
OTHER_LIMIT = 1_048_576
QMP_LIMIT = 65_536


class ProbeFailure(Exception):
    pass


def exclusive_file(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as destination:
        destination.write(content)
        destination.flush()
        os.fsync(destination.fileno())


def exclusive_json(path, value):
    exclusive_file(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def checked_directory(path, boundary, private=False):
    if not path.is_absolute() or path != Path(os.path.abspath(path)):
        raise ProbeFailure("A normalized absolute directory is required")
    try:
        relative = path.relative_to(boundary)
    except ValueError as error:
        raise ProbeFailure("Directory lies outside the allowed project boundary") from error
    current = boundary
    for component in (None, *relative.parts):
        if component is not None:
            current = current / component
        metadata = current.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            raise ProbeFailure("Directory must be owned, real, and protected from other writers")
    if private and stat.S_IMODE(path.lstat().st_mode) != 0o700:
        raise ProbeFailure("The platform directory must have private 0700 permissions")


def regular_bytes(path, maximum, minimum=1, owner=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        owners = {os.getuid()} if owner is None else owner
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in owners or before.st_nlink != 1 or
                before.st_mode & 0o022 or not minimum <= before.st_size <= maximum):
            raise ProbeFailure("Input must be an owned, bounded, single-link regular file")
        content = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        if len(content) != before.st_size or identity(before) != identity(after) or len(content) > maximum:
            raise ProbeFailure("Input changed during its bounded read")
    return content


def asset(path, boundary, maximum, minimum=1):
    checked_directory(path.parent, boundary)
    content = regular_bytes(path, maximum, minimum)
    return content, {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}


def checked_media(media, pk_enrollment=False, trust_chain=False):
    expected = {"EFI", "EFI/BOOT", "EFI/BOOT/BOOTAA64.EFI", "startup.nsh"}
    if pk_enrollment:
        expected |= {"PK.AUTH", "PK.ESL"}
    if trust_chain:
        expected |= {"PK.AUTH", "KEK.AUTH", "DB.AUTH", "PK.ESL", "SIGNED.EFI"}
    found = set()
    for directory, directories, files in os.walk(media, followlinks=False):
        for name in (*directories, *files):
            path = Path(directory) / name
            relative = str(path.relative_to(media))
            if relative not in expected:
                raise ProbeFailure("The readonly media directory has an unexpected entry")
            metadata = path.lstat()
            if relative in {"EFI", "EFI/BOOT"}:
                checked_directory(path, media)
            elif not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise ProbeFailure("Readonly media contains a link or special file")
            found.add(relative)
    if found != expected:
        raise ProbeFailure("The readonly media directory is incomplete")


def executable(name, version):
    candidate = Path("/opt/homebrew/bin") / name
    resolved = candidate.resolve(strict=True)
    expected = Path("/opt/homebrew/Cellar") / ("qemu" if name.startswith("qemu-") else "swtpm") / version / "bin" / name
    if resolved != expected or not os.access(resolved, os.X_OK):
        raise ProbeFailure("The expected installed Homebrew tool/version is required")
    content = regular_bytes(resolved, 134_217_728, owner={0, os.getuid()})
    return resolved, {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}


def private_qemu(record_path, platform_directory, diagnostic=False, display=False):
    """Accept only the separately reviewed source correction and its owned build record."""
    checked_directory(record_path.parent, platform_directory)
    record = json.loads(regular_bytes(record_path, 65_536))
    if not isinstance(record, dict):
        raise ProbeFailure("Private QEMU record must be an object")
    timer_diagnostic = record.get("diagnosticOnly") is True
    native_gic_feature = record.get("nativeGicFeatureAdvertised") is True
    pkcs7_envelope = record.get("pkcs7EnvelopeRecognitionCorrected") is True
    if timer_diagnostic and not diagnostic:
        raise ProbeFailure("The timer-instrumented binary requires diagnostic-only invocation")
    expected = {
        "schemaVersion": 1, "version": "11.1.0", "scope": "private-firmware-evaluation",
        "sourceArchiveSHA256": QEMU_SOURCE_SHA256,
        "patchedHvfSHA256": QEMU_PATCHED_HVF_SHA256,
        "gicKconfigSHA256": QEMU_GIC_KCONFIG_SHA256,
        "gicBackportCommit": "a0c093900d84f6668c27eaeab4ca74935b5857b2",
        "target": "aarch64-softmmu", "hvfEnabled": True, "tcgEnabled": False,
        "gnutlsEnabled": True, "vvfatEnabled": True, "windowsCompatibilityVerified": False,
    }
    if timer_diagnostic:
        expected.update({
            "scope": "private-firmware-evaluation-diagnostic", "diagnosticOnly": True,
            "diagnosticSourceHashes": QEMU_TIMER_DIAGNOSTIC_SOURCES,
            "binarySHA256": QEMU_TIMER_DIAGNOSTIC_BINARY,
            "traceEvent": "hvf_timer_gic_diag", "defaultTraceEnabled": False,
            "nativeRegisterReadsOnly": True, "interruptAcknowledgementReads": False,
            "timerOrGicRegisterWrites": False, "guestMemoryReads": False,
        })
    if native_gic_feature:
        expected.update({
            "diagnosticOnly": False, "nativeGicFeatureAdvertised": True,
            "binarySHA256": QEMU_GIC_FEATURE_BINARY,
            "nativeGicFeaturePatchSHA256": "8a9cccee0277857652ad4f1ba78c0c23e7eaccb058bdd2b5f4a163b2c8895a1a",
            "targetHvfSHA256": QEMU_GIC_FEATURE_SOURCES["target/arm/hvf/hvf.c"],
            "traceEventsSHA256": QEMU_GIC_FEATURE_SOURCES["target/arm/hvf/trace-events"],
            "traceInstrumentationRemoved": True, "diagnosticEventRegistered": False,
            "unrelatedVHEEL3PrivateAPIPatchesExcluded": True, "timerIRQSecurityPolicyChanges": False,
        })
    if pkcs7_envelope:
        if not native_gic_feature:
            raise ProbeFailure("Envelope candidate requires the reviewed native-GIC baseline")
        expected.update({
            "binarySHA256": QEMU_PKCS7_ENVELOPE_BINARY,
            "pkcs7EnvelopeRecognitionCorrected": True,
            "pkcs7EnvelopeSourceSHA256": QEMU_PKCS7_ENVELOPE_SOURCE,
            "pkcs7EnvelopePatchSHA256": "fc8e09fb4beb16e0d7707f0316467c3842b2b4111cffbb0d3138fd096315dca1",
            "authenticationPolicyChanged": False, "verificationSkipped": False,
            "timestampOrReplayPolicyChanged": False,
        })
    if display:
        if diagnostic or timer_diagnostic or not native_gic_feature or not pkcs7_envelope:
            raise ProbeFailure("Native display requires the non-diagnostic four-correction candidate")
        expected.update({
            "scope": "private-vnc-enabled-evaluation", "binarySHA256": QEMU_VNC_BINARY,
            "sizeBytes": 26_832_496, "vncEnabled": True, "vncJpegEnabled": False,
            "vncSaslEnabled": False, "vncTLSCredentialsConfigured": False,
            "unixVNCNoCPUHandshakeVerified": True, "hostMinimum": "27.0",
        })
    if not isinstance(record, dict) or any(
            type(record.get(key)) is not type(value) or record.get(key) != value
            for key, value in expected.items()):
        raise ProbeFailure("Private QEMU record is not the reviewed HVF/PPI candidate")
    source_root = platform_directory / "source/qemu"
    if display:
        candidate = platform_directory / QEMU_VNC_DIRECTORY
        if record_path != candidate / "candidate.json":
            raise ProbeFailure("Display preparation requires the exact isolated candidate record")
        binary = candidate / "qemu-system-aarch64"
        source_root = candidate / "source"
        data_directory = source_root / "pc-bios"
        if record.get("executable") != str(binary) or record.get("runtimeDataDirectory") != str(data_directory):
            raise ProbeFailure("The isolated display candidate paths differ")
        keymap = data_directory / "keymaps/en-us"
        content, keymap_record = asset(keymap, platform_directory, QEMU_VNC_KEYMAP[0])
        if keymap_record != {"bytes": QEMU_VNC_KEYMAP[0], "sha256": QEMU_VNC_KEYMAP[1]}:
            raise ProbeFailure("The original VNC keyboard data differs from its reviewed source")
        relative = str(binary.relative_to(platform_directory))
    else:
        relative = record.get("executable")
    if (not isinstance(relative, str) or not relative or len(relative.encode()) > 4096 or
            "\0" in relative or Path(relative).is_absolute() or
            any(part in {".", ".."} for part in Path(relative).parts)):
        raise ProbeFailure("Private QEMU record requires a local relative executable")
    binary = platform_directory / relative
    checked_directory(binary.parent, platform_directory)
    content = regular_bytes(binary, 134_217_728)
    digest = hashlib.sha256(content).hexdigest()
    if not os.access(binary, os.X_OK) or digest != record.get("binarySHA256"):
        raise ProbeFailure("Private QEMU binary differs from its source/build record")
    patched_source = source_root / "accel/hvf/hvf-all.c"
    checked_directory(patched_source.parent, platform_directory)
    if hashlib.sha256(regular_bytes(patched_source, 65_536)).hexdigest() != QEMU_PATCHED_HVF_SHA256:
        raise ProbeFailure("Private HVF source differs from the narrow reviewed correction")
    gic_source = source_root / "hw/intc/Kconfig"
    checked_directory(gic_source.parent, platform_directory)
    if hashlib.sha256(regular_bytes(gic_source, 65_536)).hexdigest() != QEMU_GIC_KCONFIG_SHA256:
        raise ProbeFailure("Private interrupt-controller source differs from the reviewed backport")
    source_pins = QEMU_TIMER_DIAGNOSTIC_SOURCES if timer_diagnostic else (
        QEMU_GIC_FEATURE_SOURCES if native_gic_feature else {})
    if source_pins:
        for relative, expected_digest in source_pins.items():
            diagnostic_source = source_root / relative
            checked_directory(diagnostic_source.parent, platform_directory)
            if hashlib.sha256(regular_bytes(diagnostic_source, 262_144)).hexdigest() != expected_digest:
                raise ProbeFailure("Private ARM HVF source differs from the selected reviewed variant")
    if pkcs7_envelope:
        crypto_source = source_root / "hw/uefi/var-service-pkcs7.c"
        checked_directory(crypto_source.parent, platform_directory)
        if hashlib.sha256(regular_bytes(crypto_source, 262_144)).hexdigest() != QEMU_PKCS7_ENVELOPE_SOURCE:
            raise ProbeFailure("Private envelope recognition source differs from the reviewed correction")
    return binary, {"bytes": len(content), "sha256": digest,
                    "candidateRecordSHA256": hashlib.sha256(regular_bytes(record_path, 65_536)).hexdigest(),
                    "sourceArchiveSHA256": QEMU_SOURCE_SHA256,
                    "patchedHvfSHA256": QEMU_PATCHED_HVF_SHA256,
                    "gicKconfigSHA256": QEMU_GIC_KCONFIG_SHA256,
                    "timerRegisterDiagnostic": timer_diagnostic,
                    "pkcs7EnvelopeRecognitionCorrected": pkcs7_envelope,
                    "nativeGicFeatureAdvertised": native_gic_feature,
                    "nativeDisplayCandidate": display,
                    "runtimeDataDirectory": str(source_root / "pc-bios") if display else None}


class Drain:
    """Drain continuously after a bound/error, so child pipes cannot deadlock."""

    def __init__(self, pipe, destination, limit, cursor_reply=None):
        self.pipe = pipe
        self.destination = destination
        self.limit = limit
        self.cursor_reply = cursor_reply
        self.data = bytearray()
        self.error = None
        self.lock = threading.Lock()
        self.cursor_replies = 0
        self.tail = b""
        self.thread = threading.Thread(target=self.read, daemon=True)

    def read(self):
        try:
            while chunk := os.read(self.pipe.fileno(), 65_536):
                with self.lock:
                    available = max(0, self.limit - len(self.data))
                    kept = chunk[:available]
                    self.data.extend(kept)
                    if len(kept) != len(chunk) and self.error is None:
                        self.error = "Child output exceeded its preserved log bound"
                    try:
                        self.destination.write(kept)
                        self.destination.flush()
                    except OSError:
                        self.error = "Could not preserve child output"
                    if self.cursor_reply is not None:
                        combined = self.tail + chunk
                        queries = combined.count(b"\x1b[6n")
                        self.tail = combined[-3:]
                        if self.cursor_replies + queries > 32:
                            self.error = "Serial cursor queries exceeded their bound"
                        else:
                            for _ in range(queries):
                                # Minimal fixed test-terminal response, not screen geometry evidence.
                                try:
                                    os.write(self.cursor_reply.fileno(), b"\x1b[1;1R")
                                    self.cursor_replies += 1
                                except OSError:
                                    self.error = "Serial test-terminal reply failed"
        except OSError:
            with self.lock:
                self.error = "Child pipe drain failed"
        finally:
            self.pipe.close()
            try:
                self.destination.flush()
                os.fsync(self.destination.fileno())
            except OSError:
                with self.lock:
                    self.error = "Could not flush the preserved child log"
            self.destination.close()

    def snapshot(self):
        with self.lock:
            return bytes(self.data)


class Child:
    def __init__(self, argv, prefix, fixture, environment, owned, serial=False):
        outputs = []
        try:
            for suffix in ("stdout", "stderr"):
                descriptor = os.open(fixture / (prefix + "-" + suffix + ".log"),
                                     os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                outputs.append(os.fdopen(descriptor, "wb"))
            self.process = subprocess.Popen(argv, stdin=subprocess.PIPE if serial else subprocess.DEVNULL,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            cwd=fixture, env=environment, close_fds=True, start_new_session=True)
            # Register every process, including prerequisite tools, before starting readers.
            owned.append(self)
        except BaseException:
            for output in outputs:
                output.close()
            raise
        self.stdout = Drain(self.process.stdout, outputs[0], GUEST_LIMIT if serial else OTHER_LIMIT,
                            self.process.stdin if serial else None)
        self.stderr = Drain(self.process.stderr, outputs[1], OTHER_LIMIT)
        self.stdout.thread.start()
        self.stderr.thread.start()

    def errors(self):
        return [item.error for item in (self.stdout, self.stderr) if item.error]

    def finish(self):
        if self.process.poll() is None:
            raise ProbeFailure("Child is still active; ownership cannot be released")
        for drain in (self.stdout, self.stderr):
            drain.thread.join(5)
            if drain.thread.is_alive():
                raise ProbeFailure("A child log drain has not finished")
        if self.process.stdin is not None:
            self.process.stdin.close()


def bounded_tool(argv, prefix, fixture, environment, owned):
    child = Child(argv, prefix, fixture, environment, owned)
    try:
        child.process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        child.process.terminate()
        child.process.wait(timeout=10)
        raise ProbeFailure("Prerequisite command timed out")
    finally:
        if child.process.poll() is not None:
            child.finish()
    if child.errors() or child.process.returncode != 0:
        raise ProbeFailure("Prerequisite command failed or exceeded its output bound")
    return child.stdout.snapshot(), child.stderr.snapshot()


class QMP:
    def __init__(self, path, records):
        metadata = path.lstat()
        if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise ProbeFailure("QMP needs the owned private Unix socket")
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connection.settimeout(3)
        self.connection.connect(str(path))
        self.buffer = b""
        self.received = 0
        self.records = records
        try:
            greeting = self.receive()
            version = greeting.get("QMP", {}).get("version", {}).get("qemu", {})
            if version != {"major": 11, "minor": 1, "micro": 0}:
                raise ProbeFailure("Unexpected QMP version/greeting")
            self.execute("qmp_capabilities", 1)
        except BaseException:
            self.connection.close()
            raise

    def receive(self, deadline=None):
        if deadline is None:
            deadline = time.monotonic() + 3
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeFailure("QMP response deadline expired")
            self.connection.settimeout(remaining)
            chunk = self.connection.recv(4096)
            if not chunk:
                raise ProbeFailure("QMP closed before its response")
            self.received += len(chunk)
            self.buffer += chunk
            if len(self.buffer) > QMP_LIMIT or self.received > 262_144:
                raise ProbeFailure("QMP exceeded its response bound")
        line, self.buffer = self.buffer.split(b"\n", 1)
        value = json.loads(line)
        if not isinstance(value, dict) or len(self.records) >= 64:
            raise ProbeFailure("Invalid or excessive QMP responses")
        self.records.append(value)
        return value

    def execute(self, command, identifier, arguments=None, deadline=None):
        request = {"execute": command, "id": identifier}
        if arguments is not None:
            request["arguments"] = arguments
        deadline = min(time.monotonic() + 3, deadline) if deadline is not None else time.monotonic() + 3
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProbeFailure("QMP command deadline expired before sending")
        self.connection.settimeout(remaining)
        self.connection.sendall((json.dumps(request) + "\n").encode())
        while time.monotonic() < deadline:
            value = self.receive(deadline)
            if value.get("id") == identifier:
                if "error" in value or "return" not in value:
                    raise ProbeFailure("QMP command was rejected")
                return value["return"]
        raise ProbeFailure("QMP command did not return before its deadline")

    def close(self):
        self.connection.close()


def display_ready(output, stage):
    clean = ANSI_CSI.sub(b"", output).replace(b"\r", b"")
    if b"mvo.display-input.failure" in clean:
        raise ProbeFailure("The display/input application reported a controlled failure")
    pattern = (rb"(?:^|\n)mvo\.display-input\.ready stage=" + str(stage).encode() +
               rb" width=([0-9]{1,4}) height=([0-9]{1,4}) mode=([0-9]{1,2})\n")
    matches = re.findall(pattern, clean)
    if len(matches) > 1:
        raise ProbeFailure("A display readiness marker was repeated")
    if not matches:
        return None
    width, height, mode = map(int, matches[0])
    if not 64 <= width <= 4096 or not 64 <= height <= 4096 or mode >= 64:
        raise ProbeFailure("The applied guest mode exceeds the experiment bounds")
    return {"stage": stage, "width": width, "height": height, "mode": mode}


def wait_display_line(guest, children, line, deadline):
    deadline = min(time.monotonic() + 5, deadline)
    while time.monotonic() < deadline:
        clean = ANSI_CSI.sub(b"", guest.stdout.snapshot()).replace(b"\r", b"")
        if b"mvo.display-input.failure" in clean or any(child.errors() for child in children):
            raise ProbeFailure("Display/input execution or its bounded output failed")
        count = clean.splitlines().count(line)
        if count > 1:
            raise ProbeFailure("An input marker was repeated")
        if count == 1:
            return
        if any(child.process.poll() is not None for child in children):
            raise ProbeFailure("An owned child exited before the input acknowledgement")
        time.sleep(0.02)
    raise ProbeFailure("The actual input target or acknowledgement did not arrive")


def capture_display_grid(qmp, fixture, mode, identifier, deadline):
    path = fixture / ("display-stage-" + str(mode["stage"]) + ".ppm")
    if path.exists() or path.is_symlink():
        raise ProbeFailure("The framebuffer capture destination already exists")
    response = qmp.execute("screendump", identifier,
                           {"filename": str(path), "device": "display0", "head": 0, "format": "ppm"}, deadline)
    if response != {}:
        raise ProbeFailure("The framebuffer capture returned an unexpected acknowledgement")
    content = regular_bytes(path, 50_332_672)
    if stat.S_IMODE(path.lstat().st_mode) != 0o600:
        raise ProbeFailure("The framebuffer capture is not private")
    header = re.match(rb"P6\n([0-9]{1,4}) ([0-9]{1,4})\n255\n", content)
    if header is None:
        raise ProbeFailure("The capture is not the pinned QEMU PPM format")
    width, height = map(int, header.groups())
    if (width, height) != (mode["width"], mode["height"]) or len(content) != header.end() + width * height * 3:
        raise ProbeFailure("The captured framebuffer differs from the guest's actual mode")
    palette = ((240, 32, 16), (32, 224, 64), (16, 64, 240), (224, 192, 32))
    samples = []
    for quadrant in range(4):
        x_center = width // 4 if quadrant % 2 == 0 else 3 * width // 4
        y_center = height // 4 if quadrant < 2 else 3 * height // 4
        expected = palette[(quadrant + mode["stage"]) % 4]
        for y_offset in (-1, 0, 1):
            for x_offset in (-1, 0, 1):
                x, y = x_center + x_offset, y_center + y_offset
                offset = header.end() + (y * width + x) * 3
                actual = tuple(content[offset:offset + 3])
                if actual != expected:
                    raise ProbeFailure("The captured pixels do not match the guest's stage-specific grid")
                samples.append({"x": x, "y": y, "rgb": list(actual)})
    if time.monotonic() >= deadline:
        raise ProbeFailure("Framebuffer verification exceeded the overall guest completion deadline")
    return {**mode, "filename": path.name, "bytes": len(content),
            "sha256": hashlib.sha256(content).hexdigest(), "samples": samples}


def send_display_key(qmp, guest, children, key, acknowledgement, identifier, deadline):
    def event(down):
        return {"device": "display0", "head": 0,
                "events": [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": key}}}]}
    try:
        if qmp.execute("input-send-event", identifier, event(True), deadline) != {}:
            raise ProbeFailure("The key-down event was not acknowledged")
        wait_display_line(guest, children, acknowledgement, deadline)
    finally:
        # Release the same key even when the actual guest acknowledgement fails.
        if qmp.execute("input-send-event", identifier + 1, event(False)) != {}:
            raise ProbeFailure("The key-up event was not acknowledged")
    # Allow the USB polling path to observe the release before a repeated digit.
    # This is not evidence for physical keys, held modifiers or OS input behavior.
    time.sleep(0.1)
    if time.monotonic() >= deadline:
        raise ProbeFailure("Input exchange exceeded the overall guest completion deadline")


def display_exchange(qmp, guest, children, fixture, initial_mode, deadline):
    captures = [capture_display_grid(qmp, fixture, initial_mode, 10, deadline)]
    send_display_key(qmp, guest, children, "1", b"mvo.display-input.ack stage=0 key=1", 11, deadline)
    mode_deadline = min(time.monotonic() + 5, deadline)
    second_mode = None
    while time.monotonic() < mode_deadline:
        second_mode = display_ready(guest.stdout.snapshot(), 1)
        if second_mode is not None:
            break
        if any(child.errors() or child.process.poll() is not None for child in children):
            raise ProbeFailure("An owned child failed during the guest mode change")
        time.sleep(0.02)
    if second_mode is None or (second_mode["width"], second_mode["height"]) == (initial_mode["width"], initial_mode["height"]):
        raise ProbeFailure("A distinct applied guest mode did not arrive")
    captures.append(capture_display_grid(qmp, fixture, second_mode, 13, deadline))
    send_display_key(qmp, guest, children, "2", b"mvo.display-input.ack stage=1 key=2", 14, deadline)
    for index, key in enumerate("11221122"):
        wait_display_line(guest, children, f"mvo.display-input.key-ready index={index}".encode(), deadline)
        acknowledgement = f"mvo.display-input.key-ack index={index} unicode={ord(key)} scan=0".encode()
        send_display_key(qmp, guest, children, key, acknowledgement, 20 + index * 2, deadline)
    wait_display_line(guest, children, b"mvo.display-input.complete modes=2 keys=8", deadline)
    exclusive_json(fixture / "display-observation.json", {"schemaVersion": 1, "captures": captures,
                   "acknowledgedDigits": "11221122", "serialInputAttached": False,
                   "windowsDisplayVerified": False, "pointerVerified": False,
                   "nativePresentationVerified": False, "retinaVerified": False})


def probe_observation(output, pk_enrollment=False, trust_chain=False, display_input=False, measurement=False,
                      measurement_decoder=None):
    clean = ANSI_CSI.sub(b"", output).replace(b"\r", b"")
    if measurement:
        if measurement_decoder is None:
            raise ProbeFailure("Measurement parsing requires its preserved decoder")
        parse_probe_output, EventLogFailure = measurement_decoder
        try:
            parsed = parse_probe_output(clean)
        except EventLogFailure as error:
            raise ProbeFailure(str(error)) from error
        return parsed[0] if parsed is not None else None
    if display_input:
        modes = [display_ready(output, stage) for stage in (0, 1)]
        lines = clean.splitlines()
        complete = b"mvo.display-input.complete modes=2 keys=8"
        if complete not in lines:
            return None
        required = [b"mvo.display-input.begin version=1", b"mvo.display-input.ack stage=0 key=1",
                    b"mvo.display-input.ack stage=1 key=2", complete]
        for index, key in enumerate("11221122"):
            required += [f"mvo.display-input.key-ready index={index}".encode(),
                         f"mvo.display-input.key-ack index={index} unicode={ord(key)} scan=0".encode()]
        if any(lines.count(line) != 1 for line in required) or any(mode is None for mode in modes):
            raise ProbeFailure("Display completion lacks its unique actual mode/input observations")
        return {"appliedModes": modes, "acknowledgedDigitCount": 8, "windowsDisplayVerified": False}
    if trust_chain:
        if b"mvo.positive-trust-chain.failure" in clean or b"mvo.platform-probe.failure" in clean:
            raise ProbeFailure("The positive trust-chain or original child reported a failure")
        lines = clean.lower().splitlines()
        complete = (b"mvo.positive-trust-chain.complete attributes=0x00000027 setup-mode=0 secure-boot=1 "
                    b"pk-verified=1 kek-verified=1 db-verified=1 signed-image-executed=1")
        if complete not in lines:
            return None
        required = [b"mvo.positive-trust-chain.begin version=1",
                    b"mvo.positive-trust-chain.load status=success", b"mvo.positive-trust-chain.start status=success",
                    b"mvo.platform-probe.begin version=1", b"mvo.platform-probe.complete setup=0 secure-boot=1"]
        required += [f"mvo.positive-trust-chain.update variable={name} status=success".encode()
                     for name in ("pk", "kek", "db")]
        if lines.count(complete) != 1 or any(item not in lines for item in required):
            raise ProbeFailure("Positive trust-chain completion lacks its actual update/child observations")
        return {"setupMode": 0, "secureBoot": 1, "publicTestTrustChainReadbackVerified": True,
                "signedOriginalChildLoadedAndExecuted": True, "signatureRejectionVerified": False}
    if pk_enrollment:
        if b"mvo.pk-enrollment.failure" in clean:
            raise ProbeFailure("The positive PK payload reported a controlled failure")
        lines = clean.lower().splitlines()
        complete = b"mvo.pk-enrollment.complete attributes=0x00000027 setup-mode=0 secure-boot=1 pk-verified=1"
        if complete not in lines:
            return None
        if lines.count(complete) != 1 or b"mvo.pk-enrollment.begin version=1" not in lines:
            raise ProbeFailure("PK completion lacks a unique preceding observation")
        return {"setupMode": 0, "secureBoot": 1, "pkAttributes": 39,
                "publicTestPkReadbackVerified": True}
    if b"mvo.platform-probe.failure=" in clean:
        raise ProbeFailure("The EFI payload reported a controlled probe failure")
    if not re.search(rb"(?:^|\n)mvo\.platform-probe\.complete setup=1 secure-boot=0\n", clean):
        return None
    required = (b"mvo.platform-probe.begin version=1\n", b"mvo.platform-probe.arch=aarch64\n",
                b"mvo.platform-probe.setup status=Success value=1\n",
                b"mvo.platform-probe.secure-boot status=Success value=0\n")
    if any(item not in clean for item in required):
        raise ProbeFailure("EFI completion lacks the required preceding observations")
    banks = re.search(rb"mvo\.platform-probe\.tcg2 status=Success present=1 active-banks=0x([0-9a-fA-F]{8})\n", clean)
    manufacturer = re.search(rb"mvo\.platform-probe\.tpm-public-manufacturer=0x([0-9a-fA-F]{8})\n", clean)
    if not banks or not int(banks[1], 16) & 2 or not manufacturer:
        raise ProbeFailure("EFI completion lacks SHA-256 capability or the public TPM command result")
    return {"setupMode": 1, "secureBoot": 0, "activePcrBanks": int(banks[1], 16),
            "publicManufacturer": "0x" + manufacturer[1].decode().lower()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--prepare-only", action="store_true",
                        help="Prepare a new pinned original EFI fixture for the Swift runtime; no VM launch")
    parser.add_argument("--prepare-display-only", action="store_true",
                        help="Prepare a new original RAMFB/USB/VNC fixture for a Swift worker; no VM launch")
    parser.add_argument("--platform-directory", type=Path)
    parser.add_argument("--qemu-candidate-record", type=Path,
                        help="Owned build record for the separately reviewed private HVF correction")
    parser.add_argument("--diagnose-boot-timer", action="store_true",
                        help="Capture two processor snapshots at the first boot countdown; never acceptance")
    parser.add_argument("--pk-enrollment-vector", choices=("full", "bare"),
                        help="Positive public-test PK enrollment in a newly created no-OS fixture only")
    parser.add_argument("--pk-vectors-directory", type=Path)
    parser.add_argument("--positive-trust-chain", action="store_true",
                        help="Positive public-test updates and original signed child in a new no-OS fixture")
    parser.add_argument("--display-input-probe", action="store_true",
                        help="Original two-mode RAMFB and acknowledged USB digits in a new no-OS fixture")
    parser.add_argument("--measurement-consistency-probe", action="store_true",
                        help="Read-only bounded TCG2 main log and public SHA256 PCR consistency in a new fixture")
    args = parser.parse_args()
    if not args.run:
        raise SystemExit("SKIP: requires --run and the reviewed locally built platform directory.")
    if args.platform_directory is None:
        raise SystemExit("SKIP: --platform-directory is required; no implicit source/media acquisition.")
    pk_enrollment = args.pk_enrollment_vector is not None
    trust_chain = args.positive_trust_chain
    display_input = args.display_input_probe or args.prepare_display_only
    measurement = args.measurement_consistency_probe
    if args.prepare_only and (pk_enrollment or trust_chain or display_input or measurement or args.diagnose_boot_timer):
        raise ProbeFailure("Swift fixture preparation selects only the original read-only platform payload")
    if args.prepare_display_only and (args.prepare_only or pk_enrollment or trust_chain or measurement or args.diagnose_boot_timer):
        raise ProbeFailure("Display preparation selects only the original display/input payload")
    if args.prepare_only and args.qemu_candidate_record is None:
        raise ProbeFailure("Swift fixture preparation requires the reviewed private QEMU candidate")
    if sum((pk_enrollment, trust_chain, display_input, measurement, args.diagnose_boot_timer)) > 1:
        raise ProbeFailure("Select only one explicitly scoped firmware profile")
    if display_input and args.qemu_candidate_record is None:
        raise ProbeFailure("Display/input mode requires the reviewed private QEMU candidate")
    if measurement and args.qemu_candidate_record is None:
        raise ProbeFailure("Measurement mode requires the reviewed private QEMU candidate")
    if pk_enrollment and (args.diagnose_boot_timer or args.pk_vectors_directory is None or
                          args.qemu_candidate_record is None):
        raise ProbeFailure("PK mode requires reviewed vector/candidate paths and excludes timer diagnostics")
    if trust_chain and (pk_enrollment or args.diagnose_boot_timer or args.pk_vectors_directory is None or
                        args.qemu_candidate_record is None):
        raise ProbeFailure("Positive chain requires explicit vectors/candidate and excludes other profiles")
    if not pk_enrollment and not trust_chain and args.pk_vectors_directory is not None:
        raise ProbeFailure("Vector directory requires explicit PK enrollment mode")
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("SKIP: this probe requires an Apple-silicon macOS host and HVF.")
    # Darwin cannot honor QEMU's MADV_DONTDUMP-based guest-memory exclusion.
    # Disable crash core files in this runner and every inherited child instead.
    # This does not claim protection from privileged live-memory inspection.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    lab = ROOT / ".lab"
    source = args.platform_directory
    if source.parent != lab or not re.fullmatch(r"windows-platform-[0-9a-f]{32}", source.name):
        raise ProbeFailure("Select only a private platform build directly inside this project's .lab")
    checked_directory(source, ROOT, private=True)
    identifier = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex
    fixture = lab / ("windows-efi-probe-" + identifier)
    fixture.mkdir(mode=0o700)
    previous_umask = os.umask(0o077)
    lock_fd = os.open(fixture / "writer.lock", os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    children = []
    owned = []
    qmp = None
    qmp_records = []
    qmp_quit = False
    fallback_terminated = []
    phase = "preflight"
    failure = None
    observation = None
    measurement_decoder = None
    result = {"schemaVersion": 1, "windowsCompatibilityVerified": False, "secureBootProvisioned": False,
              "osDiskAttached": False, "networkAttached": False, "accelerator": "hvf",
              "guestOsCleanShutdownVerified": False, "authenticatedVariableProtectionVerified": False,
              "measuredBootVerified": False, "tpmPersistenceVerified": False,
              "publicTestPkEnrollmentRequested": pk_enrollment,
              "publicTestTrustOnly": pk_enrollment or trust_chain,
              "positiveTrustChainRequested": trust_chain,
              "displayInputProbeRequested": display_input,
              "measurementConsistencyProbeRequested": measurement,
              "windowsDisplayVerified": False, "nativePresentationVerified": False,
              "retinaVerified": False, "pointerVerified": False,
              "serialInputAttached": not display_input,
              "signatureRejectionVerified": False,
              "pkVectorKind": args.pk_enrollment_vector,
              "diagnosticOnly": args.diagnose_boot_timer,
              "guestMemoryMadviceExclusionAvailable": False, "inheritedCoreFileLimitBytes": 0}
    try:
        short = Path("/private/tmp") / ("mvo-efi-" + uuid.uuid4().hex[:16])
        short.mkdir(mode=0o700)
        for name in ("qmp.sock", "tpm.sock"):
            if len(os.fsencode(short / name)) >= 104:
                raise ProbeFailure("Darwin Unix socket path exceeds its bound")
        environment = {"PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C", "TMPDIR": str(short)}
        exclusive_json(fixture / "paths.json", {"platformDirectory": str(source), "socketDirectory": str(short)})
        runner_source = regular_bytes(Path(__file__).resolve(), 131_072)
        exclusive_file(fixture / "runner-source.py", runner_source)
        if measurement:
            decoder = Path(__file__).resolve().parent / "tcg_eventlog.py"
            decoder_source = regular_bytes(decoder, 32_768)
            exclusive_file(fixture / "tcg_eventlog.py", decoder_source)
            result["measurementDecoderSHA256"] = hashlib.sha256(decoder_source).hexdigest()
            # Execute exactly the bounded bytes retained for this invocation.
            # Compiling them directly avoids a later source import or pycache write.
            namespace = {"__name__": "macopenvm_fixture_tcg_eventlog", "__builtins__": __builtins__}
            exec(compile(decoder_source, str(fixture / "tcg_eventlog.py"), "exec", dont_inherit=True), namespace)
            measurement_decoder = (namespace["parse_probe_output"], namespace["EventLogFailure"])
        original = {}
        payloads = {}
        selected_pins = ({FIRMWARE: PINS[FIRMWARE], MEASUREMENT_PROBE: MEASUREMENT_PROBE_PIN} if measurement else
                         {FIRMWARE: PINS[FIRMWARE], DISPLAY_PROBE: DISPLAY_PROBE_PIN} if display_input else
                         {FIRMWARE: PINS[FIRMWARE], CHAIN_PROBE: CHAIN_PROBE_PIN, SIGNED_CHILD: SIGNED_CHILD_PIN}
                         if trust_chain else {FIRMWARE: PINS[FIRMWARE], PK_PROBE: PK_PROBE_PIN}
                         if pk_enrollment else PINS)
        for relative, (length, digest) in selected_pins.items():
            content, record = asset(source / relative, source, 16_777_216)
            if record != {"bytes": length, "sha256": digest}:
                raise ProbeFailure("The firmware or original EFI payload differs from the reviewed build")
            original[relative] = record
            payloads[relative] = content
        probe = payloads[MEASUREMENT_PROBE if measurement else DISPLAY_PROBE if display_input else
                         CHAIN_PROBE if trust_chain else PK_PROBE if pk_enrollment else PROBE]
        pe = int.from_bytes(probe[60:64], "little")
        if (probe[:2] != b"MZ" or pe > len(probe) - 94 or probe[pe:pe + 4] != b"PE\0\0" or
                int.from_bytes(probe[pe + 4:pe + 6], "little") != 0xAA64 or
                int.from_bytes(probe[pe + 24:pe + 26], "little") != 0x20B or
                int.from_bytes(probe[pe + 92:pe + 94], "little") != 10):
            raise ProbeFailure("Expected an AArch64 PE32+ EFI application")
        if args.qemu_candidate_record is None:
            qemu, qemu_record = executable("qemu-system-aarch64", "11.1.0")
        else:
            qemu, qemu_record = private_qemu(args.qemu_candidate_record, source, args.diagnose_boot_timer, args.prepare_display_only)
        if pk_enrollment and not qemu_record.get("nativeGicFeatureAdvertised"):
            raise ProbeFailure("PK mode requires the corrected standard native-GIC candidate")
        if trust_chain and not qemu_record.get("pkcs7EnvelopeRecognitionCorrected"):
            raise ProbeFailure("Positive chain requires the reviewed standard envelope-corrected candidate")
        if display_input and not qemu_record.get("pkcs7EnvelopeRecognitionCorrected"):
            raise ProbeFailure("Display/input mode requires the exact reviewed four-correction candidate")
        if measurement and not qemu_record.get("pkcs7EnvelopeRecognitionCorrected"):
            raise ProbeFailure("Measurement mode requires the exact reviewed four-correction candidate")
        swtpm, swtpm_record = executable("swtpm", "0.10.2")
        qemu_version, _ = bounded_tool([str(qemu), "--version"], "qemu-version", fixture, environment, owned)
        tpm_version, _ = bounded_tool([str(swtpm), "--version"], "swtpm-version", fixture, environment, owned)
        if not qemu_version.startswith(b"QEMU emulator version 11.1.0") or b"version 0.10.2" not in tpm_version:
            raise ProbeFailure("Expected QEMU 11.1.0 and swtpm 0.10.2")
        for name, binary in (("qemu", qemu), ("swtpm", swtpm)):
            bounded_tool(["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                         name + "-signature", fixture, environment, owned)
        entitlements, _ = bounded_tool(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(qemu)],
                                      "qemu-entitlements", fixture, environment, owned)
        if plistlib.loads(entitlements).get("com.apple.security.hypervisor") is not True:
            raise ProbeFailure("The installed QEMU lacks its required hypervisor entitlement")
        hvf, _ = bounded_tool([str(qemu), "-accel", "help"], "qemu-accelerators", fixture, environment, owned)
        if b"hvf" not in hvf.split():
            raise ProbeFailure("The installed QEMU does not offer HVF")
        formats, _ = bounded_tool(
            [str(qemu), "-no-user-config", "-machine", "none", "-nodefaults",
             "-display", "none", "-monitor", "none", "-serial", "none",
             "-drive", "if=none,format=help"],
            "qemu-block-formats", fixture, environment, owned)
        if b"vvfat" not in formats.split():
            raise ProbeFailure("The QEMU candidate lacks the readonly FAT directory driver")
        gic_help, gic_errors = bounded_tool([str(qemu), "-device", "hvf-arm-gicv3,help"],
                                           "qemu-native-gic", fixture, environment, owned)
        if gic_errors or not gic_help.startswith(b"hvf-arm-gicv3 options:") or b"num-cpu" not in gic_help:
            raise ProbeFailure("The QEMU candidate lacks its native ARM interrupt-controller device")
        if args.prepare_display_only:
            help_output, _ = bounded_tool([str(qemu), "-help"], "qemu-display-help", fixture, environment, owned)
            if not any(line.startswith(b"-vnc ") for line in help_output.splitlines()):
                raise ProbeFailure("The exact display candidate does not offer VNC")
        code = fixture / "firmware-code-64m.fd"
        exclusive_file(code, payloads[FIRMWARE])
        code_fd = os.open(code, os.O_RDWR | os.O_NOFOLLOW)
        with os.fdopen(code_fd, "r+b") as destination:
            destination.truncate(67_108_864)
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(code, 0o400)
        media = fixture / "efi-media"
        media.mkdir(mode=0o700)
        (media / "EFI").mkdir(mode=0o700)
        (media / "EFI/BOOT").mkdir(mode=0o700)
        boot = media / "EFI/BOOT/BOOTAA64.EFI"
        startup = media / "startup.nsh"
        exclusive_file(boot, probe)
        exclusive_file(startup, b"@echo -off\r\nfs0:\\EFI\\BOOT\\BOOTAA64.EFI\r\n")
        for path in (boot, startup):
            os.chmod(path, 0o400)
        pk_inputs = []
        if pk_enrollment or trust_chain:
            vector_directory = args.pk_vectors_directory
            if vector_directory.parent != lab or not re.fullmatch(r"pk-positive-vectors-[0-9a-f]{32}", vector_directory.name):
                raise ProbeFailure("Select only a newly prepared private PK vector directory")
            checked_directory(vector_directory, ROOT, private=True)
            filename, length, digest = PK_VECTOR_PINS[args.pk_enrollment_vector] if pk_enrollment else (None, 0, None)
            inputs = [(target, filename, (length, digest))
                      for target, (filename, length, digest) in CHAIN_INPUT_PINS.items()] if trust_chain else [
                          ("PK.AUTH", filename, (length, digest)), ("PK.ESL", "PK.ESL", PK_ESL_PIN)]
            for target_name, source_name, expected in inputs:
                content, record = asset(vector_directory / source_name, ROOT, 8192)
                if record != {"bytes": expected[0], "sha256": expected[1]}:
                    raise ProbeFailure("PK vector differs from the reviewed signed input")
                target = media / target_name
                exclusive_file(target, content)
                os.chmod(target, 0o400)
                pk_inputs.append(target)
        if trust_chain:
            target = media / "SIGNED.EFI"
            exclusive_file(target, payloads[SIGNED_CHILD])
            os.chmod(target, 0o400)
            pk_inputs.append(target)
        checked_media(media, pk_enrollment, trust_chain)
        variables = fixture / "uefi-vars.json"
        exclusive_file(variables, b"")
        tpmstate = fixture / "tpm-state"
        tpmstate.mkdir(mode=0o700)
        staged = {str(path.relative_to(fixture)): asset(path, fixture, 67_108_864)[1]
                  for path in (code, boot, startup, *pk_inputs)}
        qemu_argv = [str(qemu), "-no-user-config", "-nodefaults", "-machine",
                     "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off",
                     "-accel", "hvf", "-cpu", "host", "-smp", "2", "-m", "2048",
                     "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none",
                     "-qmp", f"unix:{short}/qmp.sock,server=on,wait=off",
                     "-drive", f"if=pflash,unit=0,format=raw,readonly=on,file={code}",
                     "-device", f"uefi-vars-sysbus,jsonfile={variables},size=262144,force-secure-boot=off,disable-custom-mode=on",
                     "-chardev", f"socket,id=chrtpm,path={short}/tpm.sock",
                     "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                     "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on",
                     "-drive", f"if=none,id=efimedia,format=raw,readonly=on,file=fat:16:{media}",
                     "-device", "virtio-blk-pci,drive=efimedia,bootindex=1"]
        if display_input:
            qemu_argv += ["-device", "ramfb,id=display0", "-device", "qemu-xhci,id=xhci0",
                          "-device", "usb-kbd,id=keyboard0,bus=xhci0.0"]
        if args.prepare_display_only:
            qemu_argv += ["-L", qemu_record["runtimeDataDirectory"], "-k",
                          str(Path(qemu_record["runtimeDataDirectory"]) / "keymaps/en-us"),
                          "-vnc", f"unix:{short}/vnc.sock,share=force-shared"]
        tpm_argv = [str(swtpm), "socket", "--tpm2", "--tpmstate", f"dir={tpmstate},mode=0600,lock",
                    "--ctrl", f"type=unixio,path={short}/tpm.sock,mode=0600,terminate",
                    "--flags", "startup-none", "--log", "file=-"]
        if any("," in str(path) or ":" in str(path) for path in (fixture, source, short)):
            raise ProbeFailure("The QEMU recipe requires separator-free private paths")
        exclusive_json(fixture / "recipe.json", {"qemuArgv": qemu_argv, "swtpmArgv": tpm_argv,
                                                "runnerSourceSHA256": hashlib.sha256(runner_source).hexdigest(),
                                                "sourceArtifacts": original, "stagedReadonly": staged,
                                                "qemu": qemu_record, "swtpm": swtpm_record})
        print("Firmware fixture created: " + fixture.name, flush=True)
        if args.prepare_only or args.prepare_display_only:
            if not qemu_record.get("pkcs7EnvelopeRecognitionCorrected"):
                raise ProbeFailure("Swift preparation requires the exact four-correction candidate")
            exclusive_json(fixture / "swift-runtime-input.json", {
                "schemaVersion": 1, "scope": ("new-owned-offline-no-os-display-fixture"
                                                if args.prepare_display_only else "new-owned-offline-no-os-fixture"),
                "qemuArgv": qemu_argv, "swtpmArgv": tpm_argv, "environment": environment,
                "qmpSocket": str(short / "qmp.sock"), "tpmSocket": str(short / "tpm.sock"),
                "sourceArtifacts": original, "stagedReadonly": staged,
                "qemu": qemu_record, "swtpm": swtpm_record,
                "originalPayload": DISPLAY_PROBE if args.prepare_display_only else PROBE, "guestLaunched": False,
                "windowsCompatibilityVerified": False})
            result.update({"status": "prepared", "preparedOnly": True, "nativeChildrenLaunched": False})
            print(json.dumps({"status": "prepared", "fixture": fixture.name}), flush=True)
            return 0
        phase = "tpm-start"
        tpm = Child(tpm_argv, "tpm", fixture, environment, owned)
        children.append(tpm)
        exclusive_json(fixture / "tpm-start.json", {"pid": tpm.process.pid, "active": True})
        readiness = time.monotonic() + 5
        while not (short / "tpm.sock").exists():
            if tpm.process.poll() is not None or tpm.errors() or time.monotonic() >= readiness:
                raise ProbeFailure("TPM control socket did not become available")
            time.sleep(0.05)
        control_metadata = (short / "tpm.sock").lstat()
        if (not stat.S_ISSOCK(control_metadata.st_mode) or control_metadata.st_uid != os.getuid() or
                stat.S_IMODE(control_metadata.st_mode) != 0o600):
            raise ProbeFailure("TPM control channel must be an owned private Unix socket")
        phase = "efi-boot"
        guest = Child(qemu_argv, "guest", fixture, environment, owned, serial=not display_input)
        children.append(guest)
        exclusive_json(fixture / "qemu-start.json", {"pid": guest.process.pid, "active": True})
        boot_started = time.monotonic()
        deadline = boot_started + 60
        while time.monotonic() < deadline:
            if any(child.errors() for child in children):
                raise ProbeFailure("A child log/serial stream failed or exceeded its bound")
            if display_input:
                initial_mode = display_ready(guest.stdout.snapshot(), 0)
                if initial_mode is not None:
                    phase = "display-input-exchange"
                    qmp = QMP(short / "qmp.sock", qmp_records)
                    display_exchange(qmp, guest, children, fixture, initial_mode, deadline)
            observation = probe_observation(guest.stdout.snapshot(), pk_enrollment, trust_chain, display_input,
                                            measurement, measurement_decoder)
            if observation is not None:
                if time.monotonic() >= deadline:
                    raise ProbeFailure("The guest completed after the overall 60-second deadline")
                result["guestCompletionSeconds"] = time.monotonic() - boot_started
                result["guestCompletionDeadlineSeconds"] = 60
                break
            if args.diagnose_boot_timer and b"[Bds]BdsWait(5)" in guest.stdout.snapshot():
                # HMP synchronizes processor state, so these are explicitly diagnostic,
                # potentially perturbing observations of this new, diskless fixture.
                phase = "boot-timer-diagnostic"
                qmp = QMP(short / "qmp.sock", qmp_records)
                timer_trace = qemu_record.get("timerRegisterDiagnostic", False)
                if timer_trace:
                    # Enable only after the countdown starts. The log backend writes
                    # into the bounded, preserved guest stderr stream.
                    response = qmp.execute("human-monitor-command", 20,
                                           {"command-line": "log trace:hvf_timer_gic_diag"})
                    states = qmp.execute("trace-event-get-state", 21,
                                         {"name": "hvf_timer_gic_diag"})
                    if response != "" or states != [{"name": "hvf_timer_gic_diag", "state": "enabled"}]:
                        raise ProbeFailure("The single reviewed diagnostic trace could not be enabled")
                samples = []
                for index in range(2):
                    if index:
                        time.sleep(0.5)
                    status = qmp.execute("query-status", 10 + index * 3)
                    cpus = qmp.execute("query-cpus-fast", 11 + index * 3)
                    registers = qmp.execute("human-monitor-command", 12 + index * 3,
                                            {"command-line": "info registers -a"})
                    if (not isinstance(status, dict) or status.get("status") != "running" or
                            not isinstance(cpus, list) or not isinstance(registers, str) or
                            len(registers.encode()) > 16_384):
                        raise ProbeFailure("Unexpected bounded processor diagnostic response")
                    samples.append({"monotonicSeconds": time.monotonic(), "status": status,
                                    "cpus": cpus, "registers": registers})
                if timer_trace:
                    qmp.execute("trace-event-set-state", 22,
                                {"name": "hvf_timer_gic_diag", "enable": False})
                exclusive_json(fixture / "boot-timer-diagnostic.json",
                               {"schemaVersion": 1, "acceptanceEvidence": False,
                                "processorSynchronizationMayPerturbGuest": True,
                                "timerRegisterTraceEnabled": timer_trace,
                                "subsequentProcessorSnapshotsMayUseCachedState": True,
                                "nativeGetterRowsNeedIndependentInspection": True, "samples": samples})
                raise ProbeFailure("Boot timer diagnostic captured; firmware acceptance remains unverified")
            if guest.process.poll() is not None or tpm.process.poll() is not None:
                raise ProbeFailure("A child exited before the EFI probe completed")
            time.sleep(0.05)
        if observation is None:
            raise ProbeFailure("The EFI probe did not complete within 60 seconds")
        if args.diagnose_boot_timer:
            raise ProbeFailure("Diagnostic-only invocation cannot establish firmware acceptance")
        phase = "qmp-shutdown"
        if qmp is None:
            qmp = QMP(short / "qmp.sock", qmp_records)
        guest_status = qmp.execute("query-status", 2)
        if not isinstance(guest_status, dict) or guest_status.get("status") != "running":
            raise ProbeFailure("QMP did not report the expected running firmware guest")
        qmp.execute("quit", 3)
        qmp_quit = True
        guest.process.wait(timeout=10)
        tpm.process.wait(timeout=10)
        for child in children:
            child.finish()
        if any(child.errors() for child in children) or guest.process.returncode != 0 or tpm.process.returncode != 0:
            raise ProbeFailure("Controlled firmware shutdown or final log preservation failed")
        observation = probe_observation(guest.stdout.snapshot(), pk_enrollment, trust_chain, display_input,
                                        measurement, measurement_decoder)
        if observation is None:
            raise ProbeFailure("Final preserved log lacks the EFI result")
        if measurement:
            parse_probe_output = measurement_decoder[0]
            parsed = parse_probe_output(ANSI_CSI.sub(b"", guest.stdout.snapshot()).replace(b"\r", b""))
            exclusive_file(fixture / "eventlog-used.bin", parsed[1])
            os.chmod(fixture / "eventlog-used.bin", 0o400)
        phase = "readonly-verification"
        for relative, record in original.items():
            if asset(source / relative, source, 16_777_216)[1] != record:
                raise ProbeFailure("An original readonly artifact changed during the run")
        for relative, record in staged.items():
            if asset(fixture / relative, fixture, 67_108_864)[1] != record:
                raise ProbeFailure("A staged readonly artifact changed during the run")
        checked_media(media, pk_enrollment, trust_chain)
        for name, binary, expected in (("qemu", qemu, qemu_record), ("swtpm", swtpm, swtpm_record)):
            if hashlib.sha256(regular_bytes(binary, 134_217_728, owner={0, os.getuid()})).hexdigest() != expected["sha256"]:
                raise ProbeFailure(name + " changed during the run")
        variable_data = regular_bytes(variables, 1_048_576, minimum=0)
        if not variable_data or not isinstance(json.loads(variable_data), dict):
            raise ProbeFailure("The resulting private UEFI variable store is absent or invalid")
        state_records = []
        for path in tpmstate.iterdir():
            metadata = path.lstat()
            if (len(state_records) >= 16 or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or
                    metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600 or
                    metadata.st_size > 16_777_216):
                raise ProbeFailure("TPM state inventory exceeds the private regular-file contract")
            state_records.append({"name": path.name, "bytes": metadata.st_size, "mode": "0600"})
        result.update({"status": "passed", "observation": observation, "qmpStatus": guest_status,
                       "readonlyHashesPreserved": True, "cursorReplies": guest.stdout.cursor_replies,
                       "tpmStateFiles": sorted(state_records, key=lambda record: record["name"]),
                       "publicTestPkEnrolled": pk_enrollment or trust_chain,
                       "firmwareGuestExecuted": True})
    except BaseException as error:
        failure = error
        result.update({"status": "failed", "phase": phase, "error": str(error)[:2000]})
        exclusive_json(fixture / "failure-observed.json", {"phase": phase, "error": str(error)[:2000],
                                                           "activePids": [child.process.pid for child in owned
                                                                          if child.process.poll() is None]})
    finally:
        # This is an exclusively owned new firmware fixture with no OS disk.
        # QMP quit/fallback SIGTERM is explicit test cleanup, never an OS-clean-stop claim.
        if len(children) > 1 and children[1].process.poll() is None and not qmp_quit:
            try:
                if qmp is None:
                    qmp = QMP(short / "qmp.sock", qmp_records)
                qmp.execute("quit", 100)
                qmp_quit = True
            except (OSError, ValueError, ProbeFailure):
                pass
        if qmp is not None:
            qmp.close()
        for child in reversed(owned):
            if child.process.poll() is None:
                try:
                    child.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.process.terminate()
                    fallback_terminated.append(child.process.pid)
                    result["status"] = "failed"
                    try:
                        child.process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        pass
        live = [child for child in owned if child.process.poll() is None]
        if live:
            try:
                exclusive_json(fixture / "failure-retained.json", {"pids": [child.process.pid for child in live],
                                                                  "phase": phase, "ownershipRetained": True})
                print("Owned firmware processes remain active; the runner retains its lock and logs.", flush=True)
            except (OSError, KeyboardInterrupt):
                # Reporting failure cannot abandon the live-child ownership loop.
                pass
            while True:
                try:
                    if all(child.process.poll() is not None for child in owned):
                        break
                    time.sleep(1)
                except KeyboardInterrupt:
                    pass
        for child in owned:
            try:
                child.finish()
            except (OSError, ProbeFailure) as error:
                result.update({"status": "failed", "cleanupError": str(error)[:2000]})
        result.update({"qmpQuitAcknowledged": qmp_quit, "fallbackTerminatedPids": fallback_terminated,
                       "childExits": [{"pid": child.process.pid, "exit": child.process.returncode} for child in children],
                       "ownershipReleased": True})
        exclusive_json(fixture / "qmp.json", qmp_records)
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
        os.umask(previous_umask)
        exclusive_json(fixture / "result.json", result)
    print(json.dumps({"status": result["status"], "fixture": fixture.name,
                      "windowsCompatibilityVerified": False}), flush=True)
    return 0 if result["status"] == "passed" and failure is None else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, ProbeFailure) as error:
        raise SystemExit("Firmware probe prerequisite failed: " + str(error)) from error
