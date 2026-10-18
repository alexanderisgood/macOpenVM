#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Deterministic AUTH2 replacement fixtures using only published EDK2 test trust."""

import argparse
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import uuid

import prepare_pk_vectors as pk
import windows_efi_probe as lab


def prepare(platform):
    lab.checked_directory(platform, lab.ROOT / ".lab", private=True)
    fixture = lab.ROOT / ".lab" / ("auth-variable-vectors-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    openssl = Path("/opt/homebrew/Cellar/openssl@3/3.6.4/bin/openssl")
    binary = lab.regular_bytes(openssl, 134_217_728, owner={0, os.getuid()})
    records = []

    def command(arguments, expected_success=True):
        completed = subprocess.run([str(openssl), *arguments], cwd=fixture,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
                                   close_fds=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        records.append({"arguments": arguments, "exit": completed.returncode})
        if (len(completed.stdout) > 65_536 or len(completed.stderr) > 65_536 or
                (completed.returncode == 0) != expected_success):
            raise lab.ProbeFailure("Fixture cryptographic verification failed")
        return completed.stdout

    for name, digest in (("TestKey.pem", pk.KEY_SHA), ("TestCert.pem", pk.CERT_SHA)):
        data, record = lab.asset(platform / pk.MATERIAL / name, platform, 8192)
        if record["sha256"] != digest:
            raise lab.ProbeFailure("Published test material pin differs")
        lab.exclusive_file(fixture / name, data)
        os.chmod(fixture / name, 0o400)
    if not command(["version"]).startswith(b"OpenSSL 3.6.4 "):
        raise lab.ProbeFailure("Unexpected fixture signing tool")
    der = command(["x509", "-in", "TestCert.pem", "-outform", "DER"])
    if len(der) != 779 or hashlib.sha256(der).hexdigest() != pk.DER_SHA:
        raise lab.ProbeFailure("Published test certificate pin differs")
    for prefix, name, second, owner_index in (("PK", "PK", 0, 0), ("KEK0", "KEK", 0, 1),
                                               ("KEK1", "KEK", 1, 2), ("KEK2", "KEK", 2, 3),
                                               ("EQUAL", "KEK", 1, 4)):
        owner = bytearray(pk.OWNER)
        owner[0] ^= owner_index
        esl = pk.X509 + struct.pack("<III", 823, 0, 795) + bytes(owner) + der
        timestamp = struct.pack("<HBBBBBBIhBB", 2026, 10, 7, 12, 0, second, 0, 0, 0, 0, 0)
        data = name.encode("utf-16-le") + pk.GLOBAL + struct.pack("<I", 0x27) + timestamp + esl
        lab.exclusive_file(fixture / (prefix + ".ESL"), esl)
        lab.exclusive_file(fixture / (prefix + ".DATA"), data)
        signature = command(["cms", "-sign", "-binary", "-noattr", "-nosmimecap", "-md", "sha256",
                             "-in", prefix + ".DATA", "-signer", "TestCert.pem", "-inkey", "TestKey.pem",
                             "-outform", "DER"])
        pk.bare_signed_data(signature)  # Require the bounded, exact ContentInfo shape.
        lab.exclusive_file(fixture / (prefix + ".SIG"), signature)
        verify = ["cms", "-verify", "-binary", "-noverify", "-inform", "DER",
                  "-in", prefix + ".SIG", "-content", prefix + ".DATA"]
        if command(verify) != data:
            raise lab.ProbeFailure("Detached signature recovered different data")
        auth = timestamp + struct.pack("<IHH", 24 + len(signature), 0x0200, 0x0ef1) + pk.PKCS7 + signature + esl
        lab.exclusive_file(fixture / (prefix + ".AUTH"), auth)
        if prefix == "KEK2":
            # Independently establish both mutations invalidate the signature before guest execution.
            bad_signature = signature[:-1] + bytes([signature[-1] ^ 1])
            lab.exclusive_file(fixture / "BAD.SIG", bad_signature)
            command([*verify[:7], "BAD.SIG", *verify[8:]], expected_success=False)
            bad_data = bytearray(data)
            bad_data[len(data) - 823 + 28] ^= 1
            lab.exclusive_file(fixture / "BAD.DATA", bad_data)
            command([*verify[:-1], "BAD.DATA"], expected_success=False)
    artifacts = {}
    for path in fixture.iterdir():
        os.chmod(path, 0o400)
        if path.suffix in {".AUTH", ".ESL"}:
            artifacts[path.name] = lab.asset(path, fixture, 8192)[1]
    lab.exclusive_json(fixture / "record.json", {
        "schemaVersion": 1, "publicTestKeySHA256": pk.KEY_SHA, "newKeyGenerated": False,
        "hostTrustChanged": False, "guestExecuted": False, "attributes": 0x27,
        "opensslSHA256": hashlib.sha256(binary).hexdigest(), "operations": records,
        "artifacts": artifacts, "tamperedSignatureRejectedByOpenSSL": True,
        "tamperedPayloadRejectedByOpenSSL": True,
        "scope": "fresh offline EFI fixture only; timestamps intentionally fixed"})
    return fixture


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-directory", type=Path, required=True)
    args = parser.parse_args()
    print(prepare(args.platform_directory))
