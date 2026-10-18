#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare positive AUTH2 fixtures with published test material; never enroll trust."""

import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import re
import struct
import subprocess
import uuid

import windows_efi_probe as lab

MATERIAL = "source/edk2/SecurityPkg/Library/DxeImageVerificationLib/GoogleTest/binfiles/"
KEY_SHA = "7b92c5e4f44a339d2838db490d7c9480e0aa8fcee741b6c6f1139305a21a7894"
CERT_SHA = "ba7ef98f96f8a04107be258f01aecc838b68adbd7438dac7cb8d9e4f57ff7fc3"
DER_SHA = "07cb27304ef1a779e25644b3e0fe5078cd3ef3b072468f68b3a8eea5ce8f3907"
GLOBAL = uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c").bytes_le
IMAGE_DB = uuid.UUID("d719b2cb-3d3a-4596-a3bc-dad00e67656f").bytes_le
X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072").bytes_le
PKCS7 = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7").bytes_le
OWNER = uuid.UUID("48336928-cfd5-486e-8a38-9735a3bb7d44").bytes_le
SIGNED_DATA_OID = bytes.fromhex("2a864886f70d010702")


def der_tlv(data, offset):
    if offset + 2 > len(data):
        raise lab.ProbeFailure("Truncated DER header")
    tag, length = data[offset:offset + 2]
    begin = offset + 2
    if length & 0x80:
        count = length & 0x7f
        if not 1 <= count <= 3 or begin + count > len(data) or data[begin] == 0:
            raise lab.ProbeFailure("Invalid bounded DER length")
        length = int.from_bytes(data[begin:begin + count], "big")
        if length < 128 or (count > 1 and length < 1 << (8 * (count - 1))):
            raise lab.ProbeFailure("Nonminimal DER length")
        begin += count
    end = begin + length
    if end > len(data):
        raise lab.ProbeFailure("DER object exceeds its buffer")
    return tag, begin, end


def bare_signed_data(content):
    if not 1 <= len(content) <= 8192:
        raise lab.ProbeFailure("Signature object exceeds its bound")
    tag, begin, end = der_tlv(content, 0)
    if tag != 0x30 or end != len(content):
        raise lab.ProbeFailure("Expected exact ContentInfo sequence")
    tag, oid_begin, oid_end = der_tlv(content, begin)
    if tag != 6 or content[oid_begin:oid_end] != SIGNED_DATA_OID:
        raise lab.ProbeFailure("Expected signedData OID")
    tag, wrapper_begin, wrapper_end = der_tlv(content, oid_end)
    if tag != 0xa0 or wrapper_end != end:
        raise lab.ProbeFailure("Expected exact explicit SignedData wrapper")
    tag, _, signed_end = der_tlv(content, wrapper_begin)
    if tag != 0x30 or signed_end != wrapper_end:
        raise lab.ProbeFailure("Expected one complete SignedData sequence")
    return content[wrapper_begin:signed_end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--platform-directory", type=Path)
    parser.add_argument("--include-positive-chain", action="store_true",
                        help="Also prepare legitimate KEK/db updates with the same published test signer")
    args = parser.parse_args()
    if not args.prepare or args.platform_directory is None:
        raise SystemExit("SKIP: requires --prepare and an explicit reviewed platform directory")
    source = args.platform_directory
    if source.parent != lab.ROOT / ".lab" or not re.fullmatch(r"windows-platform-[0-9a-f]{32}", source.name):
        raise lab.ProbeFailure("Select only the reviewed private platform source")
    lab.checked_directory(source, lab.ROOT, private=True)
    fixture = lab.ROOT / ".lab" / ("pk-positive-vectors-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    old_umask = os.umask(0o077)
    records = []
    openssl = Path("/opt/homebrew/bin/openssl").resolve(strict=True)
    if openssl != Path("/opt/homebrew/Cellar/openssl@3/3.6.4/bin/openssl"):
        raise lab.ProbeFailure("Requires the reviewed installed OpenSSL path/version")
    openssl_hash = hashlib.sha256(lab.regular_bytes(openssl, 134_217_728, owner={0, os.getuid()})).hexdigest()
    try:
        for filename, expected in (("TestKey.pem", KEY_SHA), ("TestCert.pem", CERT_SHA)):
            content, record = lab.asset(source / (MATERIAL + filename), source, 8192)
            if record["sha256"] != expected:
                raise lab.ProbeFailure("Published fixture material differs from its reviewed pin")
            lab.exclusive_file(fixture / filename, content)
            os.chmod(fixture / filename, 0o400)

        def command(arguments):
            completed = subprocess.run([str(openssl), *arguments], cwd=fixture,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       timeout=15, close_fds=True,
                                       env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
            records.append({"arguments": arguments, "exit": completed.returncode,
                            "stdoutBytes": len(completed.stdout), "stderrBytes": len(completed.stderr)})
            if completed.returncode or len(completed.stdout) > 65_536 or len(completed.stderr) > 65_536:
                raise lab.ProbeFailure("Bounded OpenSSL fixture operation failed")
            return completed.stdout

        version = command(["version"])
        if not version.startswith(b"OpenSSL 3.6.4 "):
            raise lab.ProbeFailure("Requires the reviewed OpenSSL version")
        der = command(["x509", "-in", "TestCert.pem", "-outform", "DER"])
        if len(der) != 779 or hashlib.sha256(der).hexdigest() != DER_SHA:
            raise lab.ProbeFailure("Certificate DER differs from its reviewed pin")
        esl = X509 + struct.pack("<III", 28 + 16 + len(der), 0, 16 + len(der)) + OWNER + der
        now = datetime.now(timezone.utc)
        timestamp = struct.pack("<HBBBBBBIhBB", now.year, now.month, now.day,
                                now.hour, now.minute, now.second, 0, 0, 0, 0, 0)
        signed = "PK".encode("utf-16-le") + GLOBAL + struct.pack("<I", 0x27) + timestamp + esl
        lab.exclusive_file(fixture / "PK.ESL", esl)
        lab.exclusive_file(fixture / "signed-data.bin", signed)
        envelope = command(["cms", "-sign", "-binary", "-noattr", "-nosmimecap",
                            "-md", "sha256", "-in", "signed-data.bin", "-signer", "TestCert.pem",
                            "-inkey", "TestKey.pem", "-outform", "DER"])
        lab.exclusive_file(fixture / "signature-envelope.der", envelope)
        recovered = command(["cms", "-verify", "-binary", "-noverify", "-inform", "DER",
                             "-in", "signature-envelope.der", "-content", "signed-data.bin"])
        if recovered != signed:
            raise lab.ProbeFailure("Detached signature verification returned different data")
        bare = bare_signed_data(envelope)
        for variant, signature in (("full", envelope), ("bare", bare)):
            auth = timestamp + struct.pack("<IHH", 24 + len(signature), 0x0200, 0x0ef1) + PKCS7 + signature + esl
            lab.exclusive_file(fixture / ("PK-" + variant + ".AUTH"), auth)
        if args.include_positive_chain:
            for name, namespace, prefix in (("KEK", GLOBAL, "KEK"), ("db", IMAGE_DB, "DB")):
                chain_data = name.encode("utf-16-le") + namespace + struct.pack("<I", 0x27) + timestamp + esl
                input_name = prefix + "-signed-data.bin"
                signature_name = prefix + "-signature-envelope.der"
                lab.exclusive_file(fixture / input_name, chain_data)
                signature = command(["cms", "-sign", "-binary", "-noattr", "-nosmimecap", "-md", "sha256",
                                     "-in", input_name, "-signer", "TestCert.pem", "-inkey", "TestKey.pem",
                                     "-outform", "DER"])
                lab.exclusive_file(fixture / signature_name, signature)
                recovered = command(["cms", "-verify", "-binary", "-noverify", "-inform", "DER",
                                     "-in", signature_name, "-content", input_name])
                if recovered != chain_data:
                    raise lab.ProbeFailure("Positive chain signature recovered different bound bytes")
                for variant, representation in (("full", signature), ("bare", bare_signed_data(signature))):
                    auth = (timestamp + struct.pack("<IHH", 24 + len(representation), 0x0200, 0x0ef1) +
                            PKCS7 + representation + esl)
                    lab.exclusive_file(fixture / (prefix + "-" + variant + ".AUTH"), auth)
        artifacts = {path.name: lab.asset(path, fixture, 65_536)[1]
                     for path in fixture.iterdir() if path.name != "TestKey.pem"}
        lab.exclusive_json(fixture / "record.json", {
            "schemaVersion": 1, "purpose": "positive-disposable-PK-mechanism-vectors",
            "testKeyAlreadyPublic": True, "keyGenerated": False, "trustEnrolled": False,
            "guestExecuted": False, "windowsCompatibilityVerified": False,
            "positiveChainInputsPrepared": args.include_positive_chain,
            "signatureVerifiedAgainstEmbeddedTestSigner": True,
            "opensslVersion": version.decode().strip(), "operations": records,
            "opensslBinarySHA256": openssl_hash,
            "artifacts": artifacts, "publishedKeySHA256": KEY_SHA,
            "timestampUTC": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "signingInputLayout": "UTF16LE(PK) || GUID.bytes_le || LE32(0x27) || EFI_TIME16 || ESL",
            "safetyScope": "No OS disk, guest enrollment, host trust or real user credential operation"})
        print("Positive PK vectors prepared: " + fixture.name, flush=True)
    finally:
        lab.exclusive_json(fixture / "openssl-operations.json", records)
        os.umask(old_umask)


if __name__ == "__main__":
    try:
        main()
    except lab.ProbeFailure as error:
        raise SystemExit("FAIL: " + str(error)) from error
