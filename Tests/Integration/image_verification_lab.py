#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Pinned original-EFI boot-services signature and selective hash-revocation test."""

import argparse
from pathlib import Path
import re

import authenticated_variables_lab as runner
import windows_efi_probe as lab

PROBE_PIN = (45056, "d33fd764969a4bd5a3ec4ed80e1a4c35283f9191f826ea4f66956da9ceda41ad")
VECTOR_SET_SHA256 = "fe654b6f300dd07748cd8fcde31e7fc2691da2fdaf756422523f4a2c80721dd1"
CASES = (("setup-unsigned", True, 1), ("setup-altered", True, 1),
         ("trusted-before", True, 0), ("unsigned-user", False, 0),
         ("altered-user", False, 0), ("trusted-after", True, 0),
         ("unrevoked-before", True, 0), ("revoked-signed", False, 0),
         ("unrevoked-after", True, 0))
LOAD = re.compile(rb"mvo.image-verification.load name=([a-z-]+) status=0x([0-9a-fA-F]{16}) handle=([01])")
START = re.compile(rb"mvo.image-verification.start name=([a-z-]+) status=0x([0-9a-fA-F]{16})")
END = re.compile(rb"mvo.image-verification.end-case name=([a-z-]+) mode=([01]) "
                 rb"cleanup=0x([0-9a-fA-F]{16}) passed=([01])")


def child_execution(lines, setup):
    expected = [b"mvo.platform-probe.begin version=1", b"mvo.platform-probe.arch=aarch64",
                f"mvo.platform-probe.setup status=Success value={setup}".encode(),
                f"mvo.platform-probe.secure-boot status=Success value={1 - setup}".encode()]
    banks = (re.fullmatch(rb"mvo.platform-probe.tcg2 status=Success present=1 active-banks=0x([0-9a-fA-F]{8})",
                         lines[4]) if len(lines) == 7 else None)
    if (len(lines) != 7 or lines[:4] != expected or banks is None or int(banks[1], 16) & 2 == 0 or
            re.fullmatch(rb"mvo.platform-probe.tpm-public-manufacturer=0x[0-9a-fA-F]{8}", lines[5]) is None or
            lines[6] != f"mvo.platform-probe.complete setup={setup} secure-boot={1 - setup}".encode()):
        raise lab.ProbeFailure("Missing or inconsistent original child execution witness")


def observe(raw):
    lines = [line for line in lab.ANSI_CSI.sub(b"", raw).replace(b"\r", b"").splitlines()
             if line.startswith((b"mvo.image-verification.", b"mvo.platform-probe."))]
    if any(line.startswith(b"mvo.image-verification.failure") for line in lines):
        raise lab.ProbeFailure("EFI image-test prerequisites failed")
    if not any(line.startswith(b"mvo.image-verification.complete") for line in lines):
        return None
    if not lines or lines.pop(0) != b"mvo.image-verification.begin version=1":
        raise lab.ProbeFailure("Missing unique image-test beginning")
    observations = []
    for index, (name, allow, setup) in enumerate(CASES):
        if index == 2:
            expected = [f"mvo.image-verification.update variable={name} status=Success".encode()
                        for name in ("PK", "KEK", "db")]
            if lines[:3] != expected:
                raise lab.ProbeFailure("Trust enrollment did not succeed in order")
            del lines[:3]
        if index == 6:
            expected = [b"mvo.image-verification.revoke status=0x0000000000000000",
                        b"mvo.image-verification.revocation-readback exact=1 bytes=76 attributes=0x00000027"]
            if lines[:2] != expected:
                raise lab.ProbeFailure("Revocation update/readback missing or reordered")
            del lines[:2]
        if not lines or lines.pop(0) != f"mvo.image-verification.begin-case name={name}".encode():
            raise lab.ProbeFailure("Image cases missing, duplicated or reordered")
        block = []
        while lines and not lines[0].startswith(b"mvo.image-verification.end-case"):
            block.append(lines.pop(0))
        if not lines or not block:
            raise lab.ProbeFailure("Incomplete image-case boundary")
        end = END.fullmatch(lines.pop(0))
        load = LOAD.fullmatch(block.pop(0))
        if load is None or end is None or load[1].decode() != name or end[1].decode() != name:
            raise lab.ProbeFailure("Malformed case result")
        status = int(load[2], 16)
        handle = load[3] == b"1"
        mode, cleanup, passed = end[2] == b"1", int(end[3], 16), end[4] == b"1"
        start_status = None
        if allow and status == 0 and handle:
            if not block:
                raise lab.ProbeFailure("Accepted positive image lacks execution result")
            start = START.fullmatch(block.pop())
            if start is None or start[1].decode() != name:
                raise lab.ProbeFailure("Missing or reordered StartImage result")
            start_status = int(start[2], 16)
            if start_status == 0:
                child_execution(block, setup)
            elif any(line.startswith(b"mvo.image-verification.") for line in block):
                raise lab.ProbeFailure("Unexpected nested image-test marker")
        elif block:
            raise lab.ProbeFailure("Rejected image emitted a start/execution witness")
        expected_pass = (mode and cleanup == 0 and
                         (status == 0 and handle and start_status == 0 if allow else
                          status == 0x800000000000000f and not handle))
        if passed != expected_pass:
            raise lab.ProbeFailure("Guest result contradicts independent image policy")
        observations.append({"name": name, "allow": allow, "setupMode": setup,
                             "loadStatus": hex(status), "hadHandle": handle,
                             "startStatus": hex(start_status) if start_status is not None else None,
                             "childExecuted": allow and start_status == 0,
                             "modeVerified": mode, "cleanupStatus": hex(cleanup), "passed": passed})
    failures = sum(not row["passed"] for row in observations)
    if lines != [f"mvo.image-verification.complete cases=9 failures={failures}".encode()]:
        raise lab.ProbeFailure("Completion or global execution counts differ")
    return {"cases": observations, "failures": failures, "allPassed": failures == 0,
            "executedChildren": sum(row["childExecuted"] for row in observations),
            "selectiveRevocationChecked": True}


def profile():
    return {"probePin": PROBE_PIN, "vectorSetSHA256": VECTOR_SET_SHA256,
            "inputs": {"PK.AUTH", "KEK.AUTH", "DB.AUTH", "PK.ESL", "DBX.AUTH", "DBX.ESL",
                       "SIGNED.EFI", "ALTERED.EFI", "UNSIGNED.EFI", "ALLOWED.EFI"},
            "inputLimit": 65_536, "fixturePrefix": "image-verification-run-",
            "scope": "one fresh boot; original-EFI LoadImage/StartImage and selective dbx hash revocation",
            "observer": observe, "profileSource": str(Path(__file__).resolve())}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--platform-directory", type=Path, required=True)
    parser.add_argument("--qemu-record", type=Path, required=True)
    parser.add_argument("--vectors-directory", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    args = parser.parse_args()
    args.strict_time_candidate = True
    raise SystemExit(runner.run(args, profile()))
