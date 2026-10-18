#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare only original EFI image variants and a published-test signed revocation."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import uuid

import prepare_pk_vectors as pk
import windows_efi_probe as lab

SIGNTOOL = "tools/osslsigncode-2.14-20261006T213404Z-5e89ca66939e4be992d70e33fd8eb767/build/osslsigncode"
SIGNTOOL_SHA = "a31b3bbd167c6721d0c480d28f0f51d3569c40dfdad75584f51a70d9f4b201d9"


def prepare(source, positive_fixture):
    lab.checked_directory(source, lab.ROOT / ".lab", private=True)
    lab.checked_directory(positive_fixture, lab.ROOT / ".lab", private=True)
    fixture = lab.ROOT / ".lab" / ("image-verification-inputs-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    signed, record = lab.asset(source / lab.SIGNED_CHILD, source, 65_536)
    if (record["bytes"], record["sha256"]) != lab.SIGNED_CHILD_PIN:
        raise lab.ProbeFailure("Signed original child pin differs")
    unsigned, record = lab.asset(source / lab.PROBE, source, 65_536)
    if (record["bytes"], record["sha256"]) != lab.PINS[lab.PROBE]:
        raise lab.ProbeFailure("Unsigned original child pin differs")
    marker = "mvo.platform-probe.failure=security-variable-read".encode("utf-16-le")
    if signed.count(marker) != 1:
        raise lab.ProbeFailure("Original nonexecuted error-string fixture changed")
    offset = signed.index(marker) + len(marker) - 2
    altered = bytearray(signed)
    altered[offset] = ord("D")  # Changes only 'read' to 'reaD' in an error string.
    if sum(left != right for left, right in zip(signed, altered)) != 1:
        raise lab.ProbeFailure("Expected exactly one original image-data change")
    inputs = {"SIGNED.EFI": signed, "UNSIGNED.EFI": unsigned, "ALTERED.EFI": altered}
    for target, (_, size, digest) in lab.CHAIN_INPUT_PINS.items():
        data, record = lab.asset(positive_fixture / "efi-media" / target, lab.ROOT / ".lab", 8192)
        if record != {"bytes": size, "sha256": digest}:
            raise lab.ProbeFailure("Previously verified positive chain vector differs")
        inputs[target] = data
    for name, data in inputs.items():
        lab.exclusive_file(fixture / name, data)
    for name, digest in (("TestKey.pem", pk.KEY_SHA), ("TestCert.pem", pk.CERT_SHA)):
        data, record = lab.asset(source / pk.MATERIAL / name, source, 8192)
        if record["sha256"] != digest:
            raise lab.ProbeFailure("Published fixture identity differs")
        lab.exclusive_file(fixture / name, data)
        os.chmod(fixture / name, 0o400)
    tool = source / SIGNTOOL
    if lab.asset(tool, source, 1_048_576)[1]["sha256"] != SIGNTOOL_SHA:
        raise lab.ProbeFailure("Reviewed signing tool differs")
    openssl = Path("/opt/homebrew/Cellar/openssl@3/3.6.4/bin/openssl")
    lab.regular_bytes(openssl, 134_217_728, owner={0, os.getuid()})
    operations = []

    def command(label, argv, success=True):
        completed = subprocess.run([str(item) for item in argv], cwd=fixture,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
                                   close_fds=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C",
                                                       "OPENSSL_CONF": "/dev/null"})
        if len(completed.stdout) > 65_536 or len(completed.stderr) > 65_536:
            raise lab.ProbeFailure("Tool output exceeded fixture bound")
        lab.exclusive_file(fixture / (label + ".log"), completed.stdout)
        lab.exclusive_file(fixture / (label + ".stderr"), completed.stderr)
        operations.append({"label": label, "argv": [str(item) for item in argv], "exit": completed.returncode})
        if (completed.returncode == 0) != success:
            raise lab.ProbeFailure("Independent image verification differed: " + label)
        return completed.stdout

    def verify(name, success):
        return command(name, [tool, "verify", "-in", name + ".EFI", "-CAfile", "TestCert.pem",
                              "-require-leaf-hash", "sha256:" + pk.DER_SHA,
                              "-ignore-crl", "-ignore-cdp", "-ignore-timestamp"], success)

    valid_log = verify("SIGNED", True)
    bad_log = verify("ALTERED", False)
    command("ALLOWED-sign", [tool, "sign", "-certs", "TestCert.pem", "-key", "TestKey.pem",
                             "-h", "sha256", "-in", "ALTERED.EFI", "-out", "ALLOWED.EFI"])
    allowed_log = verify("ALLOWED", True)
    current = re.findall(rb"^Current message digest\s*:\s*([0-9A-F]{64})\s*$", valid_log, re.MULTILINE)
    calculated = re.findall(rb"^Calculated message digest\s*:\s*([0-9A-F]{64})\s*$", valid_log, re.MULTILINE)
    bad_calculated = re.findall(rb"^Calculated message digest\s*:\s*([0-9A-F]{64})[ \t]+MISMATCH!!![ \t]*$",
                               bad_log, re.MULTILINE)
    allowed_digest = re.findall(rb"^Current message digest\s*:\s*([0-9A-F]{64})\s*$",
                                allowed_log, re.MULTILINE)
    if (len(current) != 1 or current != calculated or len(bad_calculated) != 1 or
            current == bad_calculated or allowed_digest != bad_calculated):
        raise lab.ProbeFailure("Expected verified Authenticode digest and changed-image mismatch")
    inputs["ALLOWED.EFI"] = lab.regular_bytes(fixture / "ALLOWED.EFI", 65_536)
    digest = bytes.fromhex(current[0].decode())
    sha256_guid = uuid.UUID("c1c41626-504c-4092-aca9-41f936934328").bytes_le
    esl = sha256_guid + struct.pack("<III", 76, 0, 48) + pk.OWNER + digest
    timestamp = struct.pack("<HBBBBBBIhBB", 2026, 10, 7, 13, 0, 0, 0, 0, 0, 0, 0)
    data = "dbx".encode("utf-16-le") + pk.IMAGE_DB + struct.pack("<I", 0x27) + timestamp + esl
    lab.exclusive_file(fixture / "DBX.DATA", data)
    signature = command("DBX-sign", [openssl, "cms", "-sign", "-binary", "-noattr", "-nosmimecap",
                                    "-md", "sha256", "-in", "DBX.DATA", "-signer", "TestCert.pem",
                                    "-inkey", "TestKey.pem", "-outform", "DER"])
    pk.bare_signed_data(signature)
    lab.exclusive_file(fixture / "DBX.SIG", signature)
    recovered = command("DBX-verify", [openssl, "cms", "-verify", "-binary", "-noverify", "-inform",
                                      "DER", "-in", "DBX.SIG", "-content", "DBX.DATA"])
    if recovered != data:
        raise lab.ProbeFailure("Revocation signature did not recover the bound data")
    auth = timestamp + struct.pack("<IHH", 24 + len(signature), 0x0200, 0x0ef1) + pk.PKCS7 + signature + esl
    for name, payload in (("DBX.AUTH", auth), ("DBX.ESL", esl)):
        lab.exclusive_file(fixture / name, payload)
        inputs[name] = payload
    records = {}
    for name in inputs:
        os.chmod(fixture / name, 0o400)
        records[name] = lab.asset(fixture / name, fixture, 65_536)[1]
    lab.exclusive_json(fixture / "record.json", {
        "schemaVersion": 1, "artifacts": records, "operations": operations,
        "revokedAuthenticodeSHA256": digest.hex(), "alteredByteOffset": offset,
        "alteration": "one UTF16LE error-string character in own original payload; PE structure unchanged",
        "publishedTestKeySHA256": pk.KEY_SHA, "newKeyGenerated": False, "hostTrustChanged": False,
        "guestExecuted": False, "scope": "fresh offline original-EFI verification fixture only"})
    print(fixture, flush=True)
    print("vectorSetSHA256=" + hashlib.sha256(json.dumps(records, sort_keys=True,
                                                           separators=(",", ":")).encode()).hexdigest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-directory", type=Path, required=True)
    parser.add_argument("--positive-fixture", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.platform_directory, args.positive_fixture)
