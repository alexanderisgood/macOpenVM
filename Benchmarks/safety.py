# SPDX-License-Identifier: Apache-2.0
"""Non-overwriting evidence and bounded build/media prerequisite checks."""
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import stat
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build_manifest import actual_entitlements, bounded_json, sha256_file, verify_current_cli, write_json

PINNED_MEDIA = {
    "installationMedia": "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6",
    "kernel": "e698a107e4d04117db1a7b0daee99bdae5f0647fba2af50f3cd020a666950ab9",
    "initialRamdisk": "5b9de8ff7b4f3055f6cf940e1ff869790415cf81b7ea1e399ee60448bc1a2c4d",
}


def verified_build(root):
    manifest = bounded_json(root / "build/build-manifest.json")
    verify_current_cli(root, manifest)
    actual_entitlements(root / "build/bin/macopenvm")
    return manifest


def verify_media(configuration):
    if not isinstance(configuration, dict):
        raise ValueError("Benchmark fixture configuration must be an object")
    if (configuration.get("guest"), configuration.get("boot"), configuration.get("network"), configuration.get("backend")) != (
            "linux", "linuxKernel", "disconnected", "appleVz"):
        raise ValueError("Only the disposable offline direct-kernel AppleVz Linux fixture is permitted")
    for role, expected in PINNED_MEDIA.items():
        if not isinstance(configuration.get(role), str) or not Path(configuration[role]).is_absolute():
            raise ValueError("Benchmark media needs local absolute paths")
        path = Path(configuration[role])
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= 134_217_728:
                raise ValueError("Benchmark media must be bounded regular files")
            digest = hashlib.sha256()
            received = 0
            while chunk := source.read(1_048_576):
                received += len(chunk)
                if received > 134_217_728:
                    raise ValueError("Benchmark media grew beyond its bound")
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError("Benchmark fixture media differs from the pinned official preparation")
    return dict(PINNED_MEDIA)


def new_session(root):
    identifier = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex
    private = root / ".lab" / ("native-benchmark-" + identifier)
    private.mkdir(mode=0o700, parents=True, exist_ok=False)
    results = root / "Benchmarks/results"
    results.mkdir(parents=True, exist_ok=True)
    destination = results / ("apple-vz-alpine-console-" + identifier + ".json")
    if destination.exists() or destination.is_symlink():
        raise FileExistsError("Unique benchmark result already exists; no evidence overwritten")
    return private, destination


def publish_result(destination, result):
    write_json(destination, result, exclusive=True)
