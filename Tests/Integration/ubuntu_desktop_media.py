#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Acquire the official Ubuntu ARM64 desktop ISO into a new private directory.

Authenticate SHA256SUMS with Ubuntu's documented full CD-image key fingerprint,
then verify the whole image. Never mount, execute or redistribute downloaded data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

BASE = "https://cdimage.ubuntu.com/ubuntu/releases/26.04.1/release/"
NAME = "ubuntu-26.04.1-desktop-arm64.iso"
FINGERPRINT = "843938DF228D22F7B3742BC0D94AA3F0EFE21092"
KEY_URL = "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x" + FINGERPRINT
ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, target, maximum, seconds):
    with target.open("xb") as output, target.with_suffix(target.suffix + ".curl.log").open("xb") as errors:
        child = subprocess.Popen(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                                  "--proto", "=https", "--proto-redir", "=https", "--max-filesize", str(maximum),
                                  "--connect-timeout", "30", "--max-time", str(seconds), url],
                                 stdin=subprocess.DEVNULL, stdout=output, stderr=errors)
        code = child.wait()
        output.flush()
        os.fsync(output.fileno())
    if code or not 0 < target.stat().st_size <= maximum:
        raise ValueError("Download failed; preserve partial artifact: " + target.name)
    print("Downloaded " + target.name, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        raise SystemExit("SKIP: explicit local acquisition required")
    directory = args.directory
    if (directory != directory.resolve() or directory.parent != ROOT / ".lab"
            or not re.fullmatch(r"ubuntu-desktop-media-[0-9a-f]{32}", directory.name)
            or directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o777 != 0o700):
        raise ValueError("Select a fresh private media directory")
    os.umask(0o077)
    # GnuPG probes an agent socket even with autostart disabled. Keep its path
    # below the Unix socket limit; preserve this isolated public-key home.
    verification = Path(tempfile.mkdtemp(prefix="movm-gpg-", dir="/private/tmp"))
    (directory / "verification-home.txt").write_text(str(verification) + "\n")
    gpg = "/opt/homebrew/bin/gpg"
    sums, signature, key = [directory / n for n in ("SHA256SUMS", "SHA256SUMS.gpg", "ubuntu-cdimage-key.asc")]
    download(BASE + sums.name, sums, 262144, 60)
    download(BASE + signature.name, signature, 262144, 60)
    download(KEY_URL, key, 262144, 60)
    common = [gpg, "--no-options", "--homedir", str(verification), "--batch", "--no-auto-key-retrieve", "--no-autostart"]
    with (directory / "key-import.log").open("xb") as log:
        subprocess.run(common + ["--import", str(key)], stdout=log, stderr=log, check=True)
    keys = subprocess.check_output(common + ["--with-colons", "--fingerprint", FINGERPRINT], stderr=subprocess.DEVNULL)
    fingerprints = [line.split(b":")[9].decode("ascii") for line in keys.splitlines() if line.startswith(b"fpr:")]
    if not fingerprints or fingerprints[0] != FINGERPRINT:
        raise ValueError("Ubuntu signing fingerprint differs")
    with (directory / "signature.log").open("xb") as errors:
        verified = subprocess.run(common + ["--status-fd", "1", "--verify", str(signature), str(sums)],
                                  stdout=subprocess.PIPE, stderr=errors, check=True)
    status = verified.stdout.decode("ascii")
    (directory / "signature-status.txt").write_text(status)
    valid = [line.split() for line in status.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
    if len(valid) != 1 or valid[0][2] != FINGERPRINT:
        raise ValueError("Expected Ubuntu signature was not verified")
    rows = [line for line in sums.read_text(encoding="ascii").splitlines()
            if re.fullmatch(r"[0-9a-f]{64} [ *]" + re.escape(NAME), line)]
    if len(rows) != 1:
        raise ValueError("Expected one signed desktop ARM64 checksum")
    expected = rows[0][:64]
    print("Authenticated Ubuntu checksum " + expected, flush=True)
    partial = directory / (NAME + ".partial")
    download(BASE + NAME, partial, 6 * 2**30, 1800)
    actual = digest(partial)
    if actual != expected:
        raise ValueError("Whole ISO checksum differs; preserve without use")
    image = directory / NAME
    if image.exists():
        raise ValueError("Never replace existing media")
    partial.rename(image)
    image.chmod(0o400)
    record = {"scope": "official-ubuntu-desktop-test-media", "url": BASE + NAME,
              "signingFingerprint": FINGERPRINT, "keyReference": "https://ubuntu.com/tutorials/how-to-verify-ubuntu",
              "signatureVerified": True, "sha256": actual, "bytes": image.stat().st_size,
              "checksumsSHA256": digest(sums), "signatureSHA256": digest(signature),
              "gpgVersion": subprocess.check_output([gpg, "--version"]).decode().splitlines()[0],
              "gpgSHA256": digest(Path(gpg).resolve()), "mounted": False, "booted": False, "redistributed": False}
    with (directory / "verification-result.json").open("x") as output:
        json.dump(record, output, indent=2); output.write("\n")
    print(json.dumps(record), flush=True)


if __name__ == "__main__":
    main()
