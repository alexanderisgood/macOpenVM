#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Copy only the reviewed, optional tools images into the development app."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]


def verified(root, pins):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Tools directory must be a local directory")
    for profile, pin in pins.items():
        path = root / (profile + ".iso")
        if path.is_symlink() or not path.is_file() or path.stat().st_size != pin["bytes"]:
            raise ValueError("Missing or invalid Guest Tools image: " + profile)
        if hashlib.sha256(path.read_bytes()).hexdigest() != pin["sha256"]:
            raise ValueError("Guest Tools checksum mismatch: " + profile)


def main():
    source = ROOT / "build/guest-tools"
    destination = ROOT / "build/macOpenVM.app/Contents/Resources/GuestTools"
    pins = json.loads((ROOT / "packaging/guest-tools-pins.json").read_text())
    if sys.argv[1:] == ["--verify"]:
        if destination.exists():
            verified(destination, pins)
        return
    if sys.argv[1:]:
        raise ValueError("Only --verify is supported")
    if not source.exists():
        if destination.exists():
            raise ValueError("Stale bundled Guest Tools: restore their source images before building")
        print("Guest Tools not packaged: optional reviewed images are not available.")
        return
    verified(source, pins)
    if destination.is_symlink():
        raise ValueError("Unsafe Guest Tools destination")
    destination.mkdir(parents=True, exist_ok=True)
    for profile in pins:
        target = destination / (profile + ".iso")
        if target.is_symlink():
            raise ValueError("Unsafe Guest Tools image destination")
        if target.exists():
            target.chmod(0o600)
        shutil.copyfile(source / (profile + ".iso"), target)
        target.chmod(0o444)
    verified(destination, pins)
    print("Packaged all three reviewed Windows Guest Tools profiles.")


if __name__ == "__main__":
    main()
