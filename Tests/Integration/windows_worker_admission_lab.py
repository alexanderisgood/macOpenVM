#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reject altered installer recipes before any native VM/TPM child is launched.

Each case creates a private disposable fixture. The supplied CLI is retained
through exit. Existing VM stores, media, firmware and runtime fixtures are read-only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

from runtime_worker_lab import ROOT, read_json, save
from rfb_observer_lab import private_log
from windows_efi_probe import checked_directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        raise SystemExit("SKIP: explicit local admission trial required")
    checked_directory(args.reference, ROOT, private=True)
    checked_directory(args.cli.parent, ROOT, private=True)
    if args.cli != args.cli.resolve() or not args.cli.is_relative_to(ROOT / ".lab"):
        raise ValueError("Select a private signed CLI")
    original = read_json(args.reference / "swift-runtime-input.json", 65536)
    recipe = read_json(args.reference / "recipe.json", 32768)
    if original["scope"] != "approved-offline-windows-installer-fixture":
        raise ValueError("Select an approved installer reference")
    os.umask(0o077)
    campaign = ROOT / ".lab" / ("windows-admission-" + uuid.uuid4().hex)
    campaign.mkdir(mode=0o700)
    results = []
    expected_errors = {
        "wrong-scope": "The approved installer inputs differ from their fixed scope.",
        "added-network": "The approved offline installer recipe or assets differ.",
        "changed-media": "The approved offline installer recipe or assets differ.",
        "nonempty-target": "This experiment accepts only a newly empty sparse disk.",
    }
    for case, expected_error in expected_errors.items():
        fixture = ROOT / ".lab" / ("windows-installer-boot-" + uuid.uuid4().hex)
        fixture.mkdir(mode=0o700)
        short = Path("/private/tmp") / ("mvo-win-" + uuid.uuid4().hex[:16])
        short.mkdir(mode=0o700)
        old_short = str(Path(original["qmpSocket"]).parent)
        encoded = json.dumps(original).replace(str(args.reference), str(fixture)).replace(old_short, str(short))
        inputs = json.loads(encoded)
        shutil.copyfile(args.reference / "firmware-code.fd", fixture / "firmware-code.fd")
        (fixture / "firmware-code.fd").chmod(0o400)
        (fixture / "uefi-vars.json").write_bytes(b"")
        (fixture / "tpm-state").mkdir(mode=0o700)
        with (fixture / "blank-nvme.raw").open("xb") as disk:
            disk.truncate(64 * 2**30)
            if case == "nonempty-target":
                disk.write(b"test-only-admission-marker")
            disk.flush()
            os.fsync(disk.fileno())
        if case == "wrong-scope":
            inputs["scope"] = "windows-production-fixture"
        elif case == "added-network":
            inputs["qemuArgv"] += ["-nic", "user"]
        elif case == "changed-media":
            inputs["qemuArgv"] = [v.replace("Windows11_Client_arm64_en-us_26300_9457.iso.partial", "unapproved.iso")
                                  for v in inputs["qemuArgv"]]
        save(fixture / "swift-runtime-input.json", inputs)
        save(fixture / "recipe.json", recipe)
        save(fixture / "result.json", {"status": "prepared", "preparedOnly": True, "nativeChildrenLaunched": False})
        with private_log(fixture / "admission-stdout.log") as out, private_log(fixture / "admission-stderr.log") as err:
            worker = subprocess.Popen([str(args.cli), "qemu-windows-installer-worker-lab", "--directory", str(fixture)],
                                      stdin=subprocess.DEVNULL, stdout=out, stderr=err, cwd=fixture, close_fds=True)
            # Retain the actual worker. A timeout would not authorize an unrelated
            # process signal or imply VM quiescence; intended cases fail admission.
            exit_code = worker.wait()
        absent = all(not (fixture / name).exists() for name in (
            "swift-runtime.claim", "runtime-intent.json", "swift-worker-ready.json", "swift-display-ready.json",
            "swift-qemu-stdout.log", "swift-tpm-stdout.log"))
        diagnostic = (fixture / "admission-stderr.log").read_text()
        expected_diagnostic = ("macOpenVM: " + expected_error
                               + " Prepare a new pinned no-OS fixture; preserve existing files.\n")
        diagnostic_matched = diagnostic == expected_diagnostic
        passed = (exit_code == 1 and diagnostic_matched and absent
                  and not list(short.iterdir()) and not list((fixture / "tpm-state").iterdir()))
        results.append({"case": case, "fixture": fixture.name, "workerExit": exit_code,
                        "prelaunchArtifactsAbsent": absent, "diagnosticMatched": diagnostic_matched,
                        "diagnosticSHA256": hashlib.sha256(diagnostic.encode()).hexdigest(), "passed": passed})
        if not passed:
            raise ValueError("Admission did not fail before runtime creation: " + case)
    save(campaign / "result.json", {"scope": "negative-installer-admission-only", "cases": results,
                                   "cliSHA256": hashlib.sha256(args.cli.read_bytes()).hexdigest(),
                                   "nativeGuestExecutionAttempted": False})
    print(campaign, flush=True)


if __name__ == "__main__":
    main()
