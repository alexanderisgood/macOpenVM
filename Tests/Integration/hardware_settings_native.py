#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Observe stopped hardware edits in two boots of a NEW offline initramfs VM."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid

from alpine_live_preflight import (
    ROOT, ASSETS, GuestConsole, cleanup_actual, inspect_blank_disk, read_json,
    run_tool, safe_directory, save, stable_file, status, writer_available,
)
from generated_initramfs_boot import IMAGE, IMAGE_SHA, GENERATION, ARCHIVE_SHA, ARCHIVE_BYTES, ARGUMENTS, RELEASE, EARLY_MARKER
from managed_serial import ManagedSerial

sys.path.insert(0, str(ROOT / "Scripts"))
from build_manifest import actual_entitlements, source_snapshot


def require(condition, code):
    if not condition:
        raise ValueError(code)


def boot(cli, directory, artifacts, label, cpus, memory_mib):
    owner = ManagedSerial(cli, ["run", "--directory", str(directory), "--seconds", "240"],
                          cwd=artifacts, artifacts=artifacts, label=label)
    observed = None
    record = {"status": "failed", "expectedCPUs": cpus, "configuredMemoryMiB": memory_mib}
    try:
        owner.launch()
        console = GuestConsole(owner)
        console.expect(EARLY_MARKER, 120)
        console.expect(b"~ # ", 20)
        marker = "mvo-hardware-" + uuid.uuid4().hex
        command = (
            f"mvo_hw='{marker}'; "
            "mvo_fact() { printf '\\n%s.%s=%s\\n' \"$mvo_hw\" \"$1\" \"$2\"; }; "
            "mvo_fact arch \"$(uname -m)\"; mvo_fact release \"$(uname -r)\"; "
            "mvo_fact online \"$(cat /sys/devices/system/cpu/online)\"; "
            "mvo_fact processors \"$(grep -c '^processor' /proc/cpuinfo)\"; "
            "mvo_fact memoryKiB \"$(awk '/^MemTotal:/{print $2}' /proc/meminfo)\"; "
            "mvo_fact root \"$(awk '$2==\"/\"{print $1\":\"$3}' /proc/mounts)\"; "
            "mvo_fact network \"$(ls /sys/class/net)\"; "
            "mvo_fact mountedTarget \"$(grep -c '^/dev/vda' /proc/mounts)\"; "
            "mvo_fact done 1\n"
        )
        require(len(command.encode()) <= 1024, "commandLimit")
        owner.write(command.encode(), deadline=time.monotonic() + 3)
        console.line((marker + ".done=1").encode(), 30)
        prefix = (marker + ".").encode()
        facts = {}
        for row in console.lines(time.monotonic() + 3):
            if row.startswith(prefix):
                key, separator, value = row[len(prefix):].partition(b"=")
                require(separator and key not in facts and 0 < len(value) <= 256, "malformedFact")
                facts[key] = value
        require(set(facts) == {b"arch", b"release", b"online", b"processors", b"memoryKiB",
                               b"root", b"network", b"mountedTarget", b"done"}, "missingFact")
        require(facts[b"arch"] == b"aarch64" and facts[b"release"] == RELEASE.encode()
                and facts[b"network"] == b"lo" and facts[b"mountedTarget"] == b"0"
                and facts[b"done"] == b"1"
                and re.fullmatch(rb"[^:\x00-\x20]{1,128}:(rootfs|ramfs|tmpfs)", facts[b"root"]), "bootScope")
        require(facts[b"processors"] == str(cpus).encode()
                and facts[b"online"] == f"0-{cpus - 1}".encode(), "cpuMismatch")
        require(re.fullmatch(rb"[1-9][0-9]{1,9}", facts[b"memoryKiB"]), "memorySyntax")
        memory_kib = int(facts[b"memoryKiB"])
        # Linux reserves part of RAM for its kernel; record the measured value,
        # and require it within 10% of the selected allocation, never above it.
        require(memory_mib * 1024 * 9 // 10 <= memory_kib <= memory_mib * 1024, "memoryMismatch")
        record.update(marker=marker, facts={key.decode(): value.decode() for key, value in facts.items()},
                      memoryKiB=memory_kib, cursorReports=console.queries)
        # This is an unmounted, RAM-root fixture: kernel poweroff is intentional.
        owner.write(b"/bin/busybox sync; /bin/busybox poweroff -f\n", deadline=time.monotonic() + 3)
        observed = owner.wait(deadline=time.monotonic() + 45)
        require(observed.returncode == 0 and not observed.is_active and observed.first_error is None
                and observed.executable_unchanged, "runnerExit")
        history = read_json(directory / "runtime.json")["snapshot"]
        require(history["state"] == "stopped" and history["backendActive"] is False
                and history["outcome"] == "guestStopped" and history.get("operation") is None, "guestHistory")
        writer_available(directory)
        record.update(status="passed", guestKernelPoweroff=True, writerAvailable=True,
                      ordinaryFilesystemShutdownVerified=False)
        return record
    finally:
        final, requested = cleanup_actual(owner, artifacts, label, observed)
        record.update(runner=status(final), forcedHostCleanupUsed=requested and final.started)
        if requested:
            record["status"] = "failed"
        save(artifacts / (label + "-result.json"), record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--build", required=True, type=Path)
    args = parser.parse_args()
    if not args.run:
        print("SKIP: --run is required for two new offline native guest boots.")
        return 0
    build = args.build
    require(build.is_absolute() and build.parent == ROOT / ".lab", "privateBuildRequired")
    safe_directory(build, private=True)
    manifest = read_json(build / "build-record.json")
    snapshot = source_snapshot(ROOT)
    require(manifest["sources"] == snapshot, "sourceChanged")
    cli = build / "macopenvm"
    cli_identity = stable_file(cli, limit=64 << 20, expected_sha=manifest["cliSHA256"])[:2]
    actual_entitlements(cli)
    assets = [(ROOT / ASSETS[0][0], ASSETS[0][1], ASSETS[0][2]),
              (IMAGE, 36306944, IMAGE_SHA), (GENERATION / "generated-initramfs.gz", ARCHIVE_BYTES, ARCHIVE_SHA)]

    def asset_snapshot():
        return [stable_file(path, limit=size, expected_bytes=size, expected_sha=digest)[:2]
                for path, size, digest in assets]

    protected_assets = asset_snapshot()
    os.umask(0o077)
    artifacts = ROOT / (".lab/hardware-native-" + uuid.uuid4().hex)
    artifacts.mkdir(mode=0o700)
    directory = artifacts / "Resources.macopenvm"
    result = dict(schemaVersion=1, scope="two-offline-initramfs-boots-with-stopped-hardware-edit",
                  status="failed", sourceSHA256=snapshot["sha256"], cliSHA256=manifest["cliSHA256"],
                  runnerSHA256=stable_file(Path(__file__), limit=32768)[1],
                  windowsGuestVerified=False, nativeSettingsUIVerified=False,
                  installationPerformed=False, networkEnabled=False)
    phase = "create"
    try:
        run_tool(cli, ["create", "--directory", str(directory), "--name", "Hardware resource trial",
            "--media", str(assets[0][0]), "--kernel", str(IMAGE), "--initrd", str(assets[2][0]),
            "--kernel-arguments", ARGUMENTS, "--cpus", "2", "--memory-mib", "2048",
            "--disk-gib", "8", "--network", "disconnected"], artifacts, "create")
        original = stable_file(directory / "configuration.json", limit=65536, content=True)[2]
        config = read_json(directory / "configuration.json")
        require(config["cpuCount"] == 2 and config["memoryBytes"] == 2 << 30
                and config["network"] == "disconnected" and config["guest"] == "linux"
                and config["backend"] == "appleVz" and config["boot"] == "linuxKernel"
                and config.get("supportMedia") is None, "createdScope")
        identity = stable_file(directory / "machine-identity.bin", limit=65536)[:2]
        disk = inspect_blank_disk(directory)
        phase = "baseline-boot"
        result["baseline"] = boot(cli, directory, artifacts, "baseline", 2, 2048)
        require(stable_file(directory / "configuration.json", limit=65536, content=True)[2] == original,
                "baselineRegistrationChanged")
        phase = "save-hardware"
        saved = json.loads(run_tool(cli, ["set-hardware", "--directory", str(directory),
                            "--cpus", "3", "--memory-mib", "5120"], artifacts, "save-hardware")[0])
        expected = dict(config, cpuCount=3, memoryBytes=5 << 30)
        require(saved["changed"] and saved["configuration"] == expected
                and read_json(directory / "configuration.json") == expected, "saveMismatch")
        backup = saved["backupFile"]
        require(re.fullmatch(r"configuration-hardware-backup-[A-F0-9-]{36}\.json", backup)
                and stable_file(directory / backup, limit=65536, content=True)[2] == original, "backupMismatch")
        changed = stable_file(directory / "configuration.json", limit=65536)[:2]
        phase = "changed-boot"
        result["changed"] = boot(cli, directory, artifacts, "changed", 3, 5120)
        delta = result["changed"]["memoryKiB"] - result["baseline"]["memoryKiB"]
        require(2800 * 1024 <= delta <= 3072 * 1024, "memoryDeltaMismatch")
        require(inspect_blank_disk(directory) == disk
                and stable_file(directory / "machine-identity.bin", limit=65536)[:2] == identity
                and stable_file(directory / "configuration.json", limit=65536)[:2] == changed
                and stable_file(directory / backup, limit=65536, content=True)[2] == original, "vmChanged")
        require(asset_snapshot() == protected_assets and source_snapshot(ROOT) == snapshot
                and stable_file(cli, limit=64 << 20)[:2] == cli_identity, "inputsChanged")
        result.update(status="passed", memoryDeltaKiB=delta, blankDiskPreserved=True,
                      identityPreserved=True, inputsPreserved=True, exactBackupPreserved=True)
    except BaseException as error:
        result.update(failurePhase=phase, failureKind=type(error).__name__)
    finally:
        save(artifacts / "result.json", result)
    print(json.dumps({"status": result["status"], "artifacts": str(artifacts)}), flush=True)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
