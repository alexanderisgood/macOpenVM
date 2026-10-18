#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare only the pinned official local Alpine fixture; never bundle OS binaries.

Linux EFI zboot fields and ARM64 Image magic are public format facts:
https://github.com/torvalds/linux/blob/master/drivers/firmware/efi/libstub/zboot-header.S
https://github.com/torvalds/linux/blob/master/Documentation/arch/arm64/booting.rst
"""
import gzip
import hashlib
import io
from pathlib import Path
import struct
import subprocess

root = Path(__file__).resolve().parents[1]
iso = root / ".lab/media/alpine-virt-3.24.2-aarch64.iso"
expected = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"
if hashlib.sha256(iso.read_bytes()).hexdigest() != expected:
    raise SystemExit("Pinned Linux media checksum mismatch")
directory = root / ".lab/linux"
directory.mkdir(parents=True, exist_ok=True)
kernel = subprocess.run(["/usr/bin/tar", "-xOf", str(iso), "boot/vmlinuz-virt"], check=True, capture_output=True).stdout
if len(kernel) > 128 * 1024 * 1024:
    raise SystemExit("Kernel exceeds local fixture limit")
if kernel[4:8] == b"zimg":
    offset, length = struct.unpack_from("<II", kernel, 8)
    compression = kernel[24:32].split(b"\0", 1)[0]
    if compression != b"gzip" or offset < 64 or offset + length > len(kernel):
        raise SystemExit("Unsupported or invalid Linux EFI zboot payload")
    with gzip.GzipFile(fileobj=io.BytesIO(kernel[offset:offset + length])) as stream:
        kernel = stream.read(128 * 1024 * 1024 + 1)
if len(kernel) > 128 * 1024 * 1024 or kernel[56:60] != b"ARM\x64":
    raise SystemExit("Not a bounded uncompressed ARM64 Linux Image")
initrd = subprocess.run(["/usr/bin/tar", "-xOf", str(iso), "boot/initramfs-virt"], check=True, capture_output=True).stdout
for name, data in [("Image", kernel), ("initramfs-virt", initrd)]:
    path = directory / name
    if path.exists():
        if path.read_bytes() != data:
            raise SystemExit("Existing test fixture differs; preserve it for diagnosis")
    else:
        with path.open("xb") as output:
            output.write(data)
        path.chmod(0o600)
    print(name, "bytes", len(data), "sha256", hashlib.sha256(data).hexdigest())
