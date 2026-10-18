#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Acquire three pinned Alpine development packages into a new private C sysroot."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
import re
from pathlib import Path, PurePosixPath
import ssl
import stat
import tarfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / ".lab/alpine-offline-kit-2f2f6cbe25f54565a22e45e9dd9a9bf5"
INDEX = ROOT / ".lab/alpine-repository-a90d8e4746584f1e89a9a86a425ed680/APKINDEX"
VERIFY_SHA = "819a1f21a291de28cd75eb6cf2781227685679e5e73dadd87ba24cdbd35c3934"
INDEX_SHA = "6a529208284ca734c006f5a61fae7b6019fb1f7923beff693566ac9b801409f6"
SELECT = {"openssl-dev": "3.5.9-r0", "musl-dev": "1.2.6-r2", "linux-headers": "7.0.0-r1"}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def exclusive(path, data, mode=0o400):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
        os.fchmod(stream.fileno(), mode)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError("Unexpected package redirect")


def extract_payload(blob, verifier, sysroot, seen, linux_subset=False):
    first, _, _, _ = verifier.inflate_member(blob, 0, 16384, True, time.monotonic() + 30)
    second, _, _, _ = verifier.inflate_member(blob, first, 1048576, True, time.monotonic() + 30)
    third, data, _, _ = verifier.inflate_member(blob, second, 64 * 1048576, True, time.monotonic() + 30)
    require(third == len(blob), "Extra package data")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        members = archive.getmembers()
        require(len(members) < 10000, "Package entry count")
        selected = None
        if linux_subset:
            # Linux has valid case-distinct netfilter headers that collide on the
            # host volume. Extract only the stock vsock header's kernel closure.
            by_name = {member.name: member for member in members}
            selected = set()
            pending = ["usr/include/linux/vm_sockets.h"]
            while pending:
                name = pending.pop()
                if name in selected:
                    continue
                require(name in by_name and by_name[name].isfile(), "Missing kernel header")
                selected.add(name)
                data = archive.extractfile(by_name[name]).read().decode()
                for include in re.findall(r'^#\s*include\s*[<\"]([^>\"]+)', data, re.MULTILINE):
                    target = "usr/include/" + include
                    if target in by_name:
                        pending.append(target)
        for member in members:
            if selected is not None and member.name not in selected:
                continue
            name = PurePosixPath(member.name)
            require(not name.is_absolute() and ".." not in name.parts and len(str(name)) < 4096,
                    "Unsafe package member")
            target = sysroot.joinpath(*name.parts)
            require(target.parent.resolve().is_relative_to(sysroot), "Member parent escapes sysroot")
            if member.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
                require(target.is_dir() and not target.is_symlink(), "Unsafe directory overlay")
                continue
            require(member.name not in seen and not target.exists() and not target.is_symlink(),
                    "Package file overlay")
            seen.add(member.name)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if member.issym():
                link = PurePosixPath(member.linkname)
                require(not link.is_absolute() and
                        target.parent.joinpath(*link.parts).resolve().is_relative_to(sysroot),
                        "Unsafe package symlink")
                os.symlink(member.linkname, target)
            else:
                require(member.isfile() and member.size <= 16 * 1048576, "Unsupported member type")
                exclusive(target, archive.extractfile(member).read(member.size + 1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--acquire", action="store_true", required=True)
    parser.parse_args()
    source = (KIT / "verify.py").read_bytes()
    index = INDEX.read_bytes()
    require(hashlib.sha256(source).hexdigest() == VERIFY_SHA and
            hashlib.sha256(index).hexdigest() == INDEX_SHA, "Retained method/index pin changed")
    spec = importlib.util.spec_from_file_location("mvo_retained_apk_verifier", KIT / "verify.py")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    fixture = ROOT / ".lab" / ("linux-tls-sysroot-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    for folder in ("keys", "evidence", "apks", "apks/aarch64", "sysroot"):
        (fixture / folder).mkdir(mode=0o700)
    for name, digest in verifier.SIGNERS.items():
        key = (KIT / "keys" / name).read_bytes()
        require(hashlib.sha256(key).hexdigest() == digest, "Published key differs")
        exclusive(fixture / "keys" / name, key)
    verifier.ROOT = fixture
    verifier.OPENSSL = "/opt/homebrew/Cellar/openssl@3/3.6.4/bin/openssl"
    selected = []
    for block in index.decode().split("\n\n"):
        row = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if row.get("P") not in SELECT:
            continue
        require(row["V"] == SELECT[row["P"]] and row["A"] == "aarch64", "Wrong index selection")
        selected.append({"name": row["P"], "version": row["V"], "arch": row["A"],
                         "filename": row["P"] + "-" + row["V"] + ".apk",
                         "expectedArchiveBytes": int(row["S"]), "declaredLicense": row["L"],
                         "signedIndexPackageIdentity": row["C"], "sourceOrigin": row["o"],
                         "sourceCommit": row["c"]})
    require(len(selected) == 3 and sum(row["expectedArchiveBytes"] for row in selected) == 4869575,
            "Development package selection differs")
    opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    records = []
    seen = set()
    for ordinal, row in enumerate(selected, 1):
        url = "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/" + row["filename"]
        row["officialURL"] = url
        with opener.open(urllib.request.Request(url, headers={"Accept-Encoding": "identity"}), timeout=15) as response:
            require(response.status == 200 and response.geturl() == url and
                    int(response.headers["Content-Length"]) == row["expectedArchiveBytes"], "Download framing")
            blob = response.read(row["expectedArchiveBytes"] + 1)
        require(len(blob) == row["expectedArchiveBytes"], "Package archive length")
        whole = hashlib.sha256(blob).hexdigest()
        private = row["filename"] + ".unaccepted"
        exclusive(fixture / "apks/aarch64" / private, blob)
        downloaded = dict(row, ordinal=ordinal, privateFile=private, downloadedBytes=len(blob),
                          wholeSHA256=whole, status="downloaded-unaccepted", accepted=False)
        verified = verifier.verify_one(row, downloaded, time.monotonic() + 60, 64 * 1048576)
        records.append(verified)
        extract_payload(blob, verifier, fixture / "sysroot", seen, row["name"] == "linux-headers")
        print(json.dumps({"package": row["name"], "verified": True, "sha256": whole}), flush=True)
    manifest = json.loads((KIT / "kit-manifest.json").read_text())
    for row in manifest["packages"]:
        if row["P"] not in {"musl", "libssl3", "libcrypto3"}:
            continue
        blob = (KIT / "apks/aarch64" / row["filename"]).read_bytes()
        require(hashlib.sha256(blob).hexdigest() == row["wholeSHA256"], "Existing runtime archive differs")
        extract_payload(blob, verifier, fixture / "sysroot", seen)
    record = {"schemaVersion": 1, "status": "sysroot-prepared", "packages": records,
              "signedIndexSHA256": INDEX_SHA, "retainedVerifierSHA256": VERIFY_SHA,
              "existingRuntimeSet": "musl1.2.6-r2/OpenSSL3.5.9-r0",
              "scriptsExecuted": False, "guestStarted": False, "hostInstalled": False}
    exclusive(fixture / "result.json", json.dumps(record, indent=2, sort_keys=True).encode() + b"\n", 0o600)
    print(fixture, flush=True)


if __name__ == "__main__":
    main()
