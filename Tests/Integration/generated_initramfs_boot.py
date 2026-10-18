#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fresh paired55 early-initramfs boot; no persistent root or ordinary OpenRC bootstrap."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import time
import uuid

from alpine_live_preflight import (
    ROOT, ASSETS, GuestConsole, PreflightFailure, cleanup_actual, inspect_blank_disk,
    read_json, run_tool, safe_directory, save, stable_file, status, verify_guest_rows, writer_available,
)
from support_media_live import DeliveryFailure, require, verify_inputs
from managed_serial import ManagedSerial

IMAGE = ROOT / ".lab/alpine-kernel-0a18c0a17648476589503adca6e5bc16/Image"
IMAGE_SHA = "27e0c04b7b7cfa4d34af20c23a3ff4d321aad83e7ab72674ebb747ba7b8a2868"
GENERATION = ROOT / ".lab/support-media-live-f26f1e3ac5c0441ebd001328cec2cfda"
ARCHIVE_SHA = "a3789f934f54cd21f102bc1d92c04423fd3bd4d6f4315ef6b46f864a665c0c5c"
ARCHIVE_BYTES = 9545016
ARGUMENTS = "console=hvc0 single modules=virtio_blk,virtio_mmio,ext4,sd_mod,usb_storage,xhci_pci,isofs"
RELEASE = "6.18.55-0-virt"
EARLY_MARKER = b"Entering single mode. Type 'exit' to continue booting."
ZERO_SHA = hashlib.sha256(bytes(512)).hexdigest()


def inputs(options):
    for name, digest in (
        ("support_media_live.py", "44701fc2c0142863b024a769c9e5712291f93335c16a6999ef25f97cdb232f4f"),
        ("alpine_live_preflight.py", "b07af3c02ed377fe3c73149dbcab188b9da7e2ab27bc8f674593a6362cc531f1"),
        ("managed_serial.py", "3083cb626c9f0c2df62b9792ffed6166ae52c3a0a504a1dce932a9ee317ebb2d"),
    ):
        stable_file(Path(__file__).with_name(name), limit=131072, expected_sha=digest)
    candidate, carrier, old = verify_inputs(options)
    safe_directory(IMAGE.parent, private=True)
    safe_directory(GENERATION, private=True)
    observed = read_json(GENERATION / "delivery-result.json", expected_sha=
        "0c6f36df92b7e4807ef9a09ea0f81943effee228fbbe2780cdbb798fb51ab6c9")
    require(observed["status"] == "passed" and observed["hostArchiveRetentionComplete"]
            and observed["archiveInspection"]["closureComplete"] is True
            and observed["retainedArchiveSHA256"] == ARCHIVE_SHA
            and observed["retainedArchiveBytes"] == ARCHIVE_BYTES, "initramfsSource")
    image = stable_file(IMAGE, limit=64 << 20, expected_bytes=36306944, expected_sha=IMAGE_SHA)[:2]
    archive = stable_file(GENERATION / "generated-initramfs.gz", limit=32 << 20,
                          expected_bytes=ARCHIVE_BYTES, expected_sha=ARCHIVE_SHA)[:2]
    return candidate, (old, image, archive)


def send(console, owner, marker, command, key, expected):
    require(len(command.encode()) <= 1024, "commandLimit")
    owner.write(command.encode(), deadline=time.monotonic() + 3)
    console.line((marker + "." + key + "=" + expected).encode(), 30)
    console.expect(b"~ # ", 10)


def value(console, marker, key):
    prefix = (marker + "." + key + "=").encode()
    found = [row[len(prefix):] for row in console.lines(time.monotonic() + 3) if row.startswith(prefix)]
    require(len(found) == 1 and 0 < len(found[0]) <= 256, "apkRead")
    return found[0].decode("ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--carrier", type=Path, required=True)
    parser.add_argument("--carrier-sha", required=True)
    options = parser.parse_args()
    if not options.run:
        print("SKIP: explicit --run required for one new paired-image early boot.")
        return 0
    safe_directory(ROOT / ".lab")
    artifacts = ROOT / (".lab/paired55-early-boot-" + uuid.uuid4().hex)
    artifacts.mkdir(mode=0o700)
    directory = artifacts / "Early.macopenvm"
    result = dict(schemaVersion=1, scope="paired55-early-initramfs-only", status="failed",
                  ordinaryLiveBootVerified=False, persistentInstallationPerformed=False,
                  packageActionPerformed=False, networkActionPerformed=False, GUIActionPerformed=False,
                  windowsCompatibilityVerified=False, guestShutdownVerified=False, forcedCleanupUsed=False)
    owner = observed = None
    phase = "inputs"
    try:
        candidate, protected_inputs = inputs(options)
        cli = options.candidate.parent / "macopenvm"
        phase = "signature"
        run_tool(Path("/usr/bin/codesign"), ["--verify", "--strict", str(cli)], artifacts, "signature")
        out, err = run_tool(Path("/usr/bin/codesign"), ["-d", "--entitlements", ":-", str(cli)], artifacts, "entitlements")
        body = re.search(rb"<\?xml.*?</plist>", out + err, re.DOTALL)
        require(body is not None and plistlib.loads(body.group()) == {"com.apple.security.virtualization": True},
                "signatureScope")
        phase = "create"
        run_tool(cli, ["create", "--directory", str(directory), "--name", "Original paired55 early boot",
            "--media", str(ROOT / ASSETS[0][0]), "--kernel", str(IMAGE),
            "--initrd", str(GENERATION / "generated-initramfs.gz"), "--kernel-arguments", ARGUMENTS,
            "--cpus", "2", "--memory-mib", "2048", "--disk-gib", "8", "--network", "disconnected"], artifacts, "create")
        config = read_json(directory / "configuration.json")
        require(config["guest"] == "linux" and config["architecture"] == "arm64"
            and config["backend"] == "appleVz" and config["boot"] == "linuxKernel"
            and config["kernel"] == str(IMAGE) and config["initialRamdisk"] == str(GENERATION / "generated-initramfs.gz")
            and config["kernelArguments"] == ARGUMENTS and config["installationMedia"] == str(ROOT / ASSETS[0][0])
            and config.get("supportMedia") is None and config["network"] == "disconnected"
            and config["cpuCount"] == 2 and config["memoryBytes"] == 2 << 30
            and config["diskBytes"] == 8 << 30 and config["diskFile"] == "disk.raw", "createdScope")
        registration = {n: stable_file(directory / n, limit=1 << 20)[:2]
                        for n in ("configuration.json", "machine-identity.bin")}
        disk = inspect_blank_disk(directory)
        owner = ManagedSerial(cli, ["run", "--directory", str(directory), "--seconds", "300"],
                              cwd=artifacts, artifacts=artifacts, label="early")
        phase = "early-shell"
        owner.launch()
        console = GuestConsole(owner)
        console.expect(EARLY_MARKER, 120)
        console.expect(b"~ # ", 30)
        marker = "mvo-early55-" + uuid.uuid4().hex
        setup = (f"mvo_marker='{marker}'; mvo_fact() {{ printf '\\n%s.%s=%s\\n' \"$mvo_marker\" \"$1\" \"$2\"; }}; "
                 "mvo_fact setup 1\n")
        send(console, owner, marker, setup, "setup", "1")
        facts = {"setup": "1"}
        command = ('mvo_fact arch "$(uname -m)"; mvo_fact release "$(uname -r)"; '
                   'mvo_fact root "$(awk \'$2=="/"{print $1":"$3}\' /proc/mounts)"; '
                   'mvo_fact moduleNames "$(ls /lib/modules)"; mvo_fact net "$(ls /sys/class/net)"; mvo_fact basic 1\n')
        send(console, owner, marker, command, "basic", "1")
        for key in ("arch", "release", "root", "moduleNames", "net"):
            facts[key] = value(console, marker, key)
        facts["basic"] = "1"
        require(facts["arch"] == "aarch64" and facts["release"] == RELEASE and facts["moduleNames"] == RELEASE
                and facts["root"].split(":")[-1] in ("rootfs", "ramfs", "tmpfs") and facts["net"] == "lo", "createdScope")
        command = ('mvo_fact diskBlocks "$(cat /sys/class/block/vda/size)"; '
                   'mvo_fact diskRO "$(cat /sys/class/block/vda/ro)"; '
                   'mvo_dm=1; grep -q "^/dev/vda" /proc/mounts /proc/swaps; [ "$?" -ne 1 ] || mvo_dm=0; '
                   'mvo_fact diskMounted "$mvo_dm"; '
                   'mvo_fact diskHead "$(dd if=/dev/vda bs=512 count=1 2>/dev/null | sha256sum | cut -d\' \' -f1)"; '
                   'mvo_fact diskTail "$(dd if=/dev/vda bs=512 skip=16777215 count=1 2>/dev/null | sha256sum | cut -d\' \' -f1)"; '
                   'mvo_fact diskDone 1\n')
        send(console, owner, marker, command, "diskDone", "1")
        for key in ("diskBlocks", "diskRO", "diskMounted", "diskHead", "diskTail"):
            facts[key] = value(console, marker, key)
        facts["diskDone"] = "1"
        require(facts["diskBlocks"] == "16777216" and facts["diskRO"] == "0" and facts["diskMounted"] == "0"
                and facts["diskHead"] == facts["diskTail"] == ZERO_SHA, "blankTargetChanged")
        command = ('mvo_count=0; mvo_dev=; for p in /dev/sda /dev/sdb; do '
                   'if [ -b "$p" ] && [ "$(cat /sys/class/block/${p#/dev/}/ro)" = 1 ] '
                   '&& [ "$(cat /sys/class/block/${p#/dev/}/size)" = 182236 ]; then '
                   'mvo_count=$((mvo_count+1)); mvo_dev=$p; fi; done; '
                   'mvo_h=error; [ "$mvo_count" -ne 1 ] || mvo_h=$(sha256sum "$mvo_dev"); mvo_h=${mvo_h%% *}; '
                   'mvo_fact mediaCount "$mvo_count"; mvo_fact mediaDevice "${mvo_dev:-none}"; '
                   'mvo_fact mediaSHA256 "$mvo_h"; mvo_fact mediaDone 1\n')
        send(console, owner, marker, command, "mediaDone", "1")
        for key in ("mediaCount", "mediaDevice", "mediaSHA256"):
            facts[key] = value(console, marker, key)
        facts["mediaDone"] = "1"
        require(facts["mediaCount"] == "1" and facts["mediaDevice"] in ("/dev/sda", "/dev/sdb")
                and facts["mediaSHA256"] == ASSETS[0][2], "inputsChanged")
        command = ('mvo_l=1; for n in virtio_blk ext4 sd_mod usb_storage xhci_pci isofs; do '
                   'grep -q "^$n " /proc/modules || mvo_l=0; done; '
                   'mvo_fact requiredLoaded "$mvo_l"; printf "\\n%s.complete version=1\\n" "$mvo_marker"; '
                   'mvo_fact loadedDone 1\n')
        send(console, owner, marker, command, "loadedDone", "1")
        facts.update(requiredLoaded=value(console, marker, "requiredLoaded"), loadedDone="1")
        require(facts["requiredLoaded"] == "1", "initramfsObservation")
        verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        command = '/bin/busybox sync; mvo_fact syncExit "$?"\n'
        send(console, owner, marker, command, "syncExit", "0")
        facts["syncExit"] = "0"
        verify_guest_rows(console.lines(time.monotonic() + 3), marker, facts)
        result.update(serialMarker=marker, guestFacts=facts, cursorReports=console.queries,
                      pairedEarlyBootVerified=True, kernelRelease=RELEASE,
                      kernelSHA256=IMAGE_SHA, archiveSHA256=ARCHIVE_SHA, sourceSHA256=candidate["sourceSHA256"])
        phase = "initramfs-poweroff"
        result.update(initramfsKernelPoweroffRequested=True, initramfsSyncObserved=True,
                      ordinaryFilesystemShutdownVerified=False)
        owner.write(b"/bin/busybox poweroff -f\n", deadline=time.monotonic() + 3)
        observed = owner.wait(deadline=time.monotonic() + 45)
        require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
                and observed.executable_unchanged, "guestExit")
        history = read_json(directory / "runtime.json", 4096)
        require(history["snapshot"]["state"] == "stopped" and history["snapshot"]["backendActive"] is False
                and history["snapshot"]["outcome"] == "guestStopped" and history["snapshot"].get("operation") is None,
                "guestHistory")
        writer_available(directory)
        require(inspect_blank_disk(directory) == disk, "blankTargetChanged")
        require({n: stable_file(directory / n, limit=1 << 20)[:2] for n in registration} == registration,
                "registrationChanged")
        require(inputs(options)[1] == protected_inputs, "inputsChanged")
        result.update(status="passed", guestShutdownVerified=True, blankTargetPreserved=True,
                      registrationPreserved=True, inputsPreserved=True, writerAvailable=True, historyOutcome="guestStopped")
    except BaseException as error:
        result.update(status="failed", failurePhase=phase, failureKind=type(error).__name__)
        if isinstance(error, (DeliveryFailure, PreflightFailure)):
            result["failureCode"] = error.code
    finally:
        if owner is not None:
            final, requested = cleanup_actual(owner, artifacts, "early", observed)
            result.update(runner=status(final), forcedCleanupUsed=requested and final.started)
            if requested:
                result.update(status="failed", guestShutdownVerified=False)
        save(artifacts / "early-boot-result.json", result)
    print("Paired55 early boot: " + result["status"] + "; private evidence retained.")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
