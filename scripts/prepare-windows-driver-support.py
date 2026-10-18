#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline pinned 2D driver staging and ISO/Joliet readback; never launches a tool.

A separate retained root-owned builder may execute the emitted hdiutil recipe.
Payload bytes/order are deterministic; hdiutil volume timestamps need not be.
No image is admitted by this script, and no guest driver/service is executed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat

MANIFEST = "packaging/windows-driver-evaluation-manifest.json"
MANIFEST_SHA256 = "b79ac7b296062a72bd7818ef8672ecbc76bf07e4759db5947b381a03eb37fab5"
EPOCH = 946684800
MAX_IMAGE = 8 << 20
LABEL = "MVO_DRIVERS"
ISO_NAME = "macopenvm-driver-evaluation-complete.iso"
DISPLAY = ".lab/windows-display-support-3ff9bac089d546578527603a56909818/staging/"
NETWORK = ".lab/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/staging/"
PROFILES = [
    {"id": "display", "inf": "drivers/display/viogpudo.inf", "catalog": "viogpudo.cat",
     "sourceFiles": ["viogpudo.sys"], "copySections": {"VioGpuDod_Files_Driver": ["viogpudo.sys"]},
     "inboxIncludes": ["msdv.inf"]},
    {"id": "netkvm", "inf": "drivers/netkvm/netkvm.inf", "catalog": "netkvm.cat",
     "sourceFiles": ["netkvm.sys", "netkvmp.exe"],
     "copySections": {"kvmnet6.CopyFiles": ["netkvm.sys"], "netkvmp.CopyFiles": ["netkvmp.exe"]},
     "inboxIncludes": []},
    {"id": "vioser", "inf": "drivers/vioser/vioser.inf", "catalog": "vioser.cat",
     "sourceFiles": ["vioser.sys"], "copySections": {"Drivers_Dir": ["vioser.sys"]},
     "inboxIncludes": []},
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def relative(value):
    require(isinstance(value, str) and 0 < len(value) <= 512
            and all(re.fullmatch(r"[A-Za-z0-9_. -]{1,128}", p) and p not in (".", "..")
                    for p in value.split("/")) and not value.startswith("/"), "unsafe-relative-path")
    return value


def fact(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def safe_read(root, name, size=None, sha=None, limit=2 << 20):
    """Retain directory descriptors; reject indirect/case-ambiguous files and changed reads."""
    root = Path(root)
    require(root.is_absolute() and root.resolve() == root, "unsafe-root")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        return read_at(fd, name, size, sha, limit)
    finally:
        os.close(fd)


def read_at(root_fd, name, size=None, sha=None, limit=2 << 20):
    """The root descriptor is borrowed; all descendant descriptors are retained."""
    parts = relative(name).split("/")
    descriptors = [os.dup(root_fd)]
    try:
        for index, part in enumerate(parts):
            parent = descriptors[-1]
            info = os.fstat(parent)
            require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
                    and not info.st_mode & 0o022, "unsafe-input-directory")
            matches = [entry for entry in os.listdir(parent) if entry.casefold() == part.casefold()]
            require(matches == [part], "missing-or-case-colliding-input")
            if index < len(parts) - 1:
                descriptors.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent))
            else:
                fd = os.open(part, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
                try:
                    before = os.fstat(fd)
                    require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                            and before.st_nlink == 1 and not before.st_mode & 0o022
                            and 0 < before.st_size <= limit and (size is None or before.st_size == size),
                            "unsafe-or-wrong-size-input")
                    data = bytearray()
                    while chunk := os.read(fd, min(65536, limit - len(data) + 1)):
                        data.extend(chunk)
                        require(len(data) <= limit, "input-allocation-bound")
                    named = os.stat(part, dir_fd=parent, follow_symlinks=False)
                    require(len(data) == before.st_size and fact(before) == fact(os.fstat(fd)) == fact(named), "input-changed")
                    require(sha is None or digest(data) == sha, "input-checksum-mismatch")
                    return bytes(data)
                finally:
                    os.close(fd)
    finally:
        for fd in reversed(descriptors):
            os.close(fd)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-json-key")
        result[key] = value
    return result


def parse_manifest(raw):
    require(0 < len(raw) <= 32768, "manifest-bound")
    value = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(value, dict) and set(value) == {"schemaVersion", "scope", "volumeLabel", "isoBasename", "entryPoint", "packages", "files"}, "manifest-fields")
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
            and value["scope"] == "private-combined-2d-driver-evaluation-only"
            and value["volumeLabel"] == LABEL and value["isoBasename"] == ISO_NAME
            and value["entryPoint"] == "macOpenVM Setup.cmd" and value["packages"] == PROFILES,
            "manifest-profile-changed")
    expected = {"README.txt", "macOpenVM Setup.cmd"}
    for profile in PROFILES:
        directory = str(PurePosixPath(profile["inf"]).parent)
        expected.update(directory + "/" + name for name in [PurePosixPath(profile["inf"]).name,
                        profile["catalog"], "virtio-win_license.txt", *profile["sourceFiles"]])
    require(isinstance(value["files"], list) and len(value["files"]) == 15, "manifest-file-count")
    found = set()
    for row in value["files"]:
        require(isinstance(row, dict) and set(row) == {"path", "source", "bytes", "sha256"}, "manifest-file-fields")
        member = relative(row["path"])
        require(member.casefold() not in found, "manifest-case-collision")
        found.add(member.casefold())
        require(member in expected and type(row["bytes"]) is int and 0 < row["bytes"] <= 1 << 20
                and isinstance(row["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]), "manifest-file-pin")
        source = ("packaging/windows-driver-evaluation-setup.cmd" if member == "macOpenVM Setup.cmd"
                  else (NETWORK if member == "drivers/netkvm/netkvmp.exe" else DISPLAY) + member)
        require(relative(row["source"]) == source, "manifest-source-changed")
    require(found == {name.casefold() for name in expected}, "incomplete-payload-closure")
    require([row["path"] for row in value["files"]] == sorted(expected), "manifest-order")
    return value


def load_manifest(root):
    return parse_manifest(safe_read(root, MANIFEST, sha=MANIFEST_SHA256, limit=32768))


def uncomment(line):
    quoted = False
    for index, char in enumerate(line):
        if char == '"':
            quoted = not quoted
        if char == ";" and not quoted:
            return line[:index].strip()
    require(not quoted, "inf-unclosed-quote")
    return line.strip()


def verify_inf(profile, payload):
    """Known, pinned INF subset only; not a general INF installer or Windows resolver."""
    raw = payload[profile["inf"]]
    require(len(raw) <= 65536, "inf-bound")
    sections, current = {}, None
    for raw_line in raw.decode("ascii").splitlines():
        require(len(raw_line) <= 1024, "inf-line-bound")
        line = uncomment(raw_line)
        if not line:
            continue
        if line.startswith("["):
            require(re.fullmatch(r"\[[A-Za-z0-9_.-]{1,128}\]", line), "inf-section")
            current = line[1:-1].casefold()
            require(current not in sections and len(sections) < 128, "inf-duplicate-section")
            sections[current] = []
        else:
            require(current is not None, "inf-outside-section")
            sections[current].append(line)
    copies, includes, catalogs, services = [], [], [], []
    for section, lines in sections.items():
        require(not section.startswith("sourcedisksfiles.") and not section.startswith("sourcedisksnames."), "indirect-inf-source")
        for line in lines:
            if "=" not in line:
                continue
            key, val = [item.strip() for item in line.split("=", 1)]
            key = key.casefold()
            require(key not in {"needs", "copyinf", "layoutfile", "registerdlls", "unregisterdlls"}, "indirect-inf-directive")
            if key == "copyfiles": copies.extend(x.strip().casefold() for x in val.split(","))
            if key == "include": includes.extend(x.strip().casefold() for x in val.split(","))
            if key.startswith("catalogfile"):
                require(key == "catalogfile", "indirect-inf-catalog")
                catalogs.append(val)
            if key == "servicebinary": services.append(val)
    expected_sections = {name.casefold(): names for name, names in profile["copySections"].items()}
    require(len(copies) == len(set(copies)) and set(copies) == set(expected_sections), "inf-copy-sections")
    require(includes == profile["inboxIncludes"] and catalogs == [profile["catalog"]], "inf-external-dependency")
    require(services == ["%13%\\" + profile["sourceFiles"][0]], "inf-service-source")
    require(len(sections.get("sourcedisksnames", [])) == 1
            and re.fullmatch(r'1\s*=\s*%DiskId1%,,,""', sections["sourcedisksnames"][0], re.IGNORECASE), "indirect-inf-disk")
    source_files = []
    for line in sections.get("sourcedisksfiles", []):
        require("=" in line, "inf-source-row")
        name, fields = [value.strip() for value in line.split("=", 1)]
        require(re.fullmatch(r"[a-z0-9_.-]+", name) and fields.replace(" ", "") == "1,,", "indirect-inf-source")
        source_files.append(name)
    require(len(source_files) == len(set(source_files)) and sorted(source_files) == sorted(profile["sourceFiles"]), "inf-source-closure")
    copied = []
    for name, expected in expected_sections.items():
        members = []
        for line in sections.get(name, []):
            fields = [item.strip() for item in line.split(",")]
            require(len(fields) in (1, 4) and (len(fields) == 1 or fields[1:] == ["", "", "2"])
                    and re.fullmatch(r"[a-z0-9_.-]+", fields[0]), "indirect-inf-copy")
            members.append(fields[0])
        require(members == expected, "inf-copy-closure")
        copied.extend(members)
    require(sorted(copied) == sorted(source_files), "inf-copy-source-mismatch")
    directory = str(PurePosixPath(profile["inf"]).parent)
    require(all(directory + "/" + name in payload for name in [*source_files, profile["catalog"], "virtio-win_license.txt"]), "missing-inf-payload")


def collect_payload(root, manifest):
    payload = {row["path"]: safe_read(root, row["source"], row["bytes"], row["sha256"]) for row in manifest["files"]}
    require(sum(map(len, payload.values())) <= 2 << 20, "payload-bound")
    for profile in PROFILES:
        verify_inf(profile, payload)
    return payload


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("ascii")


def directory_identity(info):
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
            and not info.st_mode & 0o022, "unsafe-output-directory")
    return info.st_dev, info.st_ino


def save_new(parent, name, data, mode=0o600, timestamp=None):
    """Only mutate the exclusive new inode while its descriptor is still open."""
    require(relative(name) == name and "/" not in name, "output-basename-required")
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 mode, dir_fd=parent)
    try:
        created = os.fstat(fd)
        require(stat.S_ISREG(created.st_mode) and created.st_uid == os.geteuid()
                and created.st_nlink == 1, "unsafe-new-output")
        view = memoryview(data)
        while view:
            count = os.write(fd, view)
            require(count > 0, "short-output")
            view = view[count:]
        os.fchmod(fd, mode)
        if timestamp is not None:
            os.utime(fd, ns=(timestamp * 1000000000, timestamp * 1000000000))
        os.fsync(fd)
        final = os.fstat(fd)
        named = os.stat(name, dir_fd=parent, follow_symlinks=False)
        require(final.st_nlink == 1 and final.st_size == len(data)
                and final.st_mode & 0o777 == mode and fact(final) == fact(named)
                and (final.st_dev, final.st_ino) == (created.st_dev, created.st_ino), "output-replaced")
    finally:
        os.close(fd)


def output_location(root, output):
    require(root.is_absolute() and root.resolve() == root and output.is_absolute()
            and output.parent == root / ".lab" and output.resolve() == output
            and re.fullmatch(r"windows-driver-support-[0-9a-f]{32}", output.name), "new-private-output-required")


class OutputTree:
    """Retain nofollow directory identities through this one operation.

    Same-UID code must not concurrently mutate this workspace. Descriptor-relative
    writes limit substitution effects; checks detect named replacement, not every
    possible hostile change after a check or during the separate builder handoff.
    The mkdir/open pair is not an atomic directory-creation API.
    """
    def __init__(self, root, output, create=False):
        output_location(root, output)
        self.root, self.output = root, output
        self.opened, self.directories = [], {}
        try:
            self.root_fd = self.open_directory(root)
            self.lab_fd = self.open_directory(".lab", self.root_fd)
            if create:
                os.mkdir(output.name, mode=0o700, dir_fd=self.lab_fd)
            self.output_fd = self.open_directory(output.name, self.lab_fd)
            require(os.fstat(self.output_fd).st_mode & 0o777 == 0o700, "unsafe-prepared-directory")
            self.directories[""] = self.output_fd
            self.verify()
        except BaseException:
            self.close()
            raise

    def open_directory(self, name, parent=None):
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
        self.opened.append(fd)
        require(directory_identity(os.fstat(fd)) == directory_identity(os.stat(name, dir_fd=parent, follow_symlinks=False)),
                "output-directory-replaced")
        return fd

    def directory(self, name, create=False):
        relative(name)
        current = ""
        for part in name.split("/"):
            parent, current = current, current + ("/" if current else "") + part
            if current not in self.directories:
                if create:
                    os.mkdir(part, mode=0o700, dir_fd=self.directories[parent])
                self.directories[current] = self.open_directory(part, self.directories[parent])
            self.verify()
        return self.directories[current]

    def verify(self):
        require(directory_identity(os.fstat(self.root_fd)) == directory_identity(os.stat(self.root, follow_symlinks=False)),
                "output-root-replaced")
        for parent, name, fd in [(self.root_fd, ".lab", self.lab_fd),
                                 (self.lab_fd, self.output.name, self.output_fd)]:
            require(directory_identity(os.fstat(fd)) == directory_identity(os.stat(name, dir_fd=parent, follow_symlinks=False)),
                    "output-directory-replaced")
        for name, fd in self.directories.items():
            if name:
                parent, _, basename = name.rpartition("/")
                require(directory_identity(os.fstat(fd)) == directory_identity(os.stat(basename, dir_fd=self.directories[parent], follow_symlinks=False)),
                        "output-directory-replaced")

    def write(self, name, data, mode=0o600, timestamp=None):
        parent, _, basename = relative(name).rpartition("/")
        fd = self.directory(parent, create=True) if parent else self.output_fd
        self.verify()
        save_new(fd, basename, data, mode, timestamp)
        self.verify()

    def finish_staging(self):
        for name in sorted(self.directories, reverse=True):
            if name:
                self.verify()
                fd = self.directories[name]
                os.utime(fd, ns=(EPOCH * 1000000000, EPOCH * 1000000000))
                os.fchmod(fd, 0o700)
                os.fsync(fd)
                self.verify()

    def close(self):
        for fd in reversed(self.opened):
            os.close(fd)
        self.opened.clear()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

def recipe(output):
    return {"executable": "/usr/bin/hdiutil", "arguments": ["makehybrid", "-iso", "-joliet",
            "-default-volume-name", LABEL, "-iso-volume-name", LABEL, "-joliet-volume-name", LABEL,
            "-application", "macOpenVM", "-preparer", "macOpenVM", "-publisher", "macOpenVM",
            "-system-id", "macOpenVM", "-o", str(output / ISO_NAME), str(output / "staging")]}


def prepared_value(manifest, output):
    return {"schemaVersion": 1, "status": "prepared-not-built", "manifestSHA256": MANIFEST_SHA256,
            "inventory": [{key: row[key] for key in ("path", "bytes", "sha256")} for row in manifest["files"]],
            "volumeLabel": LABEL, "recipe": recipe(output), "imageBytes": None, "imageSHA256": None,
            "catalogAdmitted": False, "guestAction": False, "releaseCleared": False}


def verify_staging_at(tree, manifest):
    expected = {row["path"] for row in manifest["files"]}
    directories = {str(parent) for name in expected for parent in PurePosixPath(name).parents if str(parent) != "."}
    found, found_directories = set(), set()
    staging_fd = tree.directory("staging")

    def visit(fd, prefix="", depth=0):
        require(depth <= 3, "staging-directory-bound")
        names = os.listdir(fd)
        require(len(names) <= 32 and len({name.casefold() for name in names}) == len(names), "staging-namespace-changed")
        for name in names:
            relative(name)
            require("/" not in name, "staging-basename-required")
            member = prefix + name
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                require(member in directories, "staging-namespace-changed")
                found_directories.add(member)
                visit(tree.directory("staging/" + member), member + "/", depth + 1)
            else:
                require(stat.S_ISREG(info.st_mode) and member in expected, "staging-namespace-changed")
                found.add(member)
    visit(staging_fd)
    require(found == expected and found_directories == directories, "staging-namespace-changed")
    payload = {row["path"]: read_at(staging_fd, row["path"], row["bytes"], row["sha256"]) for row in manifest["files"]}
    tree.verify()
    return payload


def verify_staging(output, manifest):
    with OutputTree(output.parent.parent, output) as tree:
        return verify_staging_at(tree, manifest)


def prepare(root, output):
    manifest = load_manifest(root)
    payload = collect_payload(root, manifest)  # Entire closure before any new output.
    with OutputTree(root, output, create=True) as tree:
        tree.directory("staging", create=True)
        for name in sorted(payload):
            tree.write("staging/" + name, payload[name], 0o400, EPOCH)
        tree.finish_staging()
        verify_staging_at(tree, manifest)
        value = prepared_value(manifest, output)
        tree.write("prepared.json", json_bytes(value))
        os.fsync(tree.output_fd)
        tree.verify()
        return value


def verify_prepared_at(root, tree):
    manifest = load_manifest(root)
    expected = prepared_value(manifest, tree.output)
    require(read_at(tree.output_fd, "prepared.json", limit=32768) == json_bytes(expected), "prepared-record-changed")
    verify_staging_at(tree, manifest)
    return manifest


def verify_prepared(root, output):
    with OutputTree(root, output) as tree:
        return verify_prepared_at(root, tree)

def iso_members(data):
    """Bounded ISO9660/Joliet trees and required L/M tables, not a filesystem mount.

    Optional tables, extended attributes, interleaving and multi-extent records
    are unsupported. System-use bytes do not supply names or locations here;
    Rock Ridge/POSIX semantics and permissions are not interpreted or certified.
    """
    require(19 * 2048 <= len(data) <= MAX_IMAGE and len(data) % 2048 == 0, "iso-size")
    primary, joliet, terminated = None, None, False
    volume_bytes = None
    for sector in range(16, min(32, len(data) // 2048)):
        volume = data[sector * 2048:(sector + 1) * 2048]
        require(volume[1:6] == b"CD001" and volume[6] == 1, "iso-descriptor")
        if volume[0] == 255:
            terminated = True
            break
        require(volume[0] in (1, 2), "iso-unexpected-descriptor")
        require(int.from_bytes(volume[128:130], "little") == int.from_bytes(volume[130:132], "big") == 2048, "iso-sector-size")
        sectors = int.from_bytes(volume[80:84], "little")
        require(sectors == int.from_bytes(volume[84:88], "big") and 19 * 2048 <= sectors * 2048 <= len(data), "iso-volume-bound")
        require(volume_bytes in (None, sectors * 2048), "iso-namespace-volume-size")
        volume_bytes = sectors * 2048
        if volume[0] == 1:
            require(primary is None and volume[40:72].decode("ascii").rstrip(" \0") == LABEL, "iso-primary-label")
            primary = volume
        else:
            require(joliet is None and volume[88:91] in (b"%/@", b"%/C", b"%/E")
                    and volume[40:72].decode("utf-16-be").rstrip(" \0") == LABEL, "iso-joliet-label")
            joliet = volume
    require(terminated and primary is not None and joliet is not None, "iso-namespace-missing")
    require(not any(data[volume_bytes:]), "iso-nonzero-trailing-data")
    members, visited = {}, set()
    ranges = [(16 * 2048, (sector + 1) * 2048, "descriptors")]
    actual_directories, tree = set(), {}

    def location(record):
        require(len(record) >= 34 and record[1] == 0 and record[26:28] == b"\0\0"
                and record[25] in (0, 2) and record[28:32] == b"\x01\x00\x00\x01", "iso-indirect-record")
        extent = int.from_bytes(record[2:6], "little")
        length = int.from_bytes(record[10:14], "little")
        require(extent == int.from_bytes(record[6:10], "big") and length == int.from_bytes(record[14:18], "big")
                and extent >= 19 and 0 < length <= 1 << 20 and extent * 2048 + length <= volume_bytes, "iso-extent")
        return extent * 2048, length

    def component(encoded, joliet_names, file_version=False):
        require(encoded and (not joliet_names or len(encoded) % 2 == 0), "iso-joliet-name")
        name = encoded.decode("utf-16-be" if joliet_names else "ascii")
        if not joliet_names and file_version and name.endswith(";1"):
            name = name[:-2]
        relative(name)
        require("/" not in name, "iso-basename-required")
        return name

    def walk(record, prefix="", depth=0, joliet_names=True, parent=None):
        require(depth <= 3 and record[25] == 2, "iso-directory-depth")
        offset, length = location(record)
        require(length <= 65536 and (offset, length) not in visited, "iso-directory-cycle")
        visited.add((offset, length))
        ranges.append((offset, offset + length, "directory"))
        tree[prefix.rstrip("/")] = (offset, length)
        parent = (offset, length) if parent is None else parent
        content, cursor, names, special = data[offset:offset + length], 0, set(), 0
        while cursor < length:
            size = content[cursor]
            if size == 0:
                next_sector = min((cursor // 2048 + 1) * 2048, length)
                require(not any(content[cursor:next_sector]), "iso-directory-padding")
                cursor = next_sector
                continue
            require(size >= 34 and cursor + size <= length and cursor % 2048 + size <= 2048, "iso-directory-record")
            entry = content[cursor:cursor + size]
            cursor += size
            count = entry[32]
            require(33 + count <= size, "iso-name-bound")
            encoded = entry[33:33 + count]
            entry_location = location(entry)  # Includes dot/dotdot flags, mirrors and layout.
            if encoded in (b"\0", b"\1"):
                require(special < 2 and encoded == bytes([special]) and entry[25] == 2
                        and entry_location == ((offset, length) if special == 0 else parent), "iso-dot-identity")
                special += 1
                continue
            require(special == 2, "iso-dot-order")
            name = component(encoded, joliet_names, entry[25] == 0)
            require(name.casefold() not in names and len(names) < 32, "iso-case-collision")
            names.add(name.casefold())
            member = prefix + name
            if entry[25] == 2:
                allowed = {"drivers", "drivers/display", "drivers/netkvm", "drivers/vioser"}
                require(member in (allowed if joliet_names else {name.upper() for name in allowed}), "iso-directory-namespace")
                actual_directories.add(member)
                walk(entry, member + "/", depth + 1, joliet_names, (offset, length))
            else:
                start, count = entry_location
                require(len(members) < 32, "iso-member-bound")
                members[member] = data[start:start + count]
                ranges.append((start, start + count, "file"))
        require(special == 2, "iso-dot-missing")

    def path_tables(volume, joliet_names):
        size = int.from_bytes(volume[132:136], "little")
        require(size == int.from_bytes(volume[136:140], "big") and 10 <= size <= 4096, "iso-path-table-size")
        require(volume[144:148] == volume[152:156] == b"\0\0\0\0", "iso-optional-path-table-unsupported")
        copies = []
        for field, byteorder in ((140, "little"), (148, "big")):
            block = int.from_bytes(volume[field:field + 4], byteorder)
            start, allocated = block * 2048, ((size + 2047) // 2048) * 2048
            require(block >= 19 and start + allocated <= volume_bytes, "iso-path-table-location")
            ranges.append((start, start + allocated, "path-table"))
            content, cursor, rows, paths = data[start:start + size], 0, [], set()
            require(not any(data[start + size:start + allocated]), "iso-path-table-padding")
            while cursor < size:
                require(cursor + 8 <= size and len(rows) < 8, "iso-path-table-entry")
                count = content[cursor]
                end = cursor + 8 + count
                require(count > 0 and content[cursor + 1] == 0 and end + count % 2 <= size,
                        "iso-path-table-entry")
                block = int.from_bytes(content[cursor + 2:cursor + 6], byteorder)
                parent = int.from_bytes(content[cursor + 6:cursor + 8], byteorder)
                encoded = content[cursor + 8:end]
                require(count % 2 == 0 or content[end] == 0, "iso-path-table-entry-padding")
                if not rows:
                    require(encoded == b"\0" and parent == 1, "iso-path-table-root")
                    member = ""
                else:
                    require(1 <= parent <= len(rows), "iso-path-table-parent")
                    name = component(encoded, joliet_names)
                    prefix = rows[parent - 1][0]
                    member = prefix + ("/" if prefix else "") + name
                require(member in tree and member not in paths and block * 2048 == tree[member][0],
                        "iso-path-table-tree-drift")
                paths.add(member)
                rows.append((member, block, parent))
                cursor = end + count % 2
            require(cursor == size and paths == set(tree), "iso-path-table-tree-drift")
            copies.append(rows)
        require(copies[0] == copies[1], "iso-path-table-copy-drift")

    for volume, joliet_names in ((joliet, True), (primary, False)):
        root = volume[156:156 + volume[156]]
        require(len(root) >= 34 and root[32:34] == b"\1\0", "iso-root-record")
        walk(root, joliet_names=joliet_names)
        expected = {"drivers", "drivers/display", "drivers/netkvm", "drivers/vioser"}
        require(actual_directories == (expected if joliet_names else {name.upper() for name in expected}), "iso-directory-namespace")
        path_tables(volume, joliet_names)
        if joliet_names:
            joliet_members = members
            members, actual_directories, tree = {}, set(), {}
        else:
            require(members == {name.upper(): value for name, value in joliet_members.items()}, "iso-primary-payload-drift")
    for index, a in enumerate(ranges):
        for b in ranges[index + 1:]:
            if max(a[0], b[0]) < min(a[1], b[1]):
                require(a == b and a[2] == "file", "iso-overlapping-extents")
    return joliet_members

def readback(root, output, image, record=False):
    with OutputTree(root, output) as tree:
        manifest = verify_prepared_at(root, tree)
        require(image == output / ISO_NAME, "unexpected-image-location")
        image_bytes = read_at(tree.output_fd, ISO_NAME, limit=MAX_IMAGE)
        members = iso_members(image_bytes)
        require(set(members) == {row["path"] for row in manifest["files"]}, "iso-payload-namespace")
        for row in manifest["files"]:
            require(len(members[row["path"]]) == row["bytes"] and digest(members[row["path"]]) == row["sha256"], "iso-payload-pin")
        # Also bind the entry point to today's exact pinned source, not the old admitted disc.
        expected = collect_payload(root, manifest)
        require(members == expected, "iso-source-readback-drift")
        value = {"schemaVersion": 1, "status": "readback-verified-not-admitted", "manifestSHA256": MANIFEST_SHA256,
                 "imageBytes": len(image_bytes), "imageSHA256": digest(image_bytes), "inventory": prepared_value(manifest, output)["inventory"],
                 "catalogAdmitted": False, "guestAction": False, "releaseCleared": False}
        tree.verify()
        if record:
            tree.write("readback.json", json_bytes(value))
            os.fsync(tree.output_fd)
            tree.verify()
        return value

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "verify", "readback"))
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "prepare":
        value = prepare(args.project_root, args.output)
    elif args.action == "verify":
        manifest = verify_prepared(args.project_root, args.output)
        value = prepared_value(manifest, args.output)
    else:
        value = readback(args.project_root, args.output, args.output / ISO_NAME, record=True)
    print(json.dumps(value, sort_keys=True))


if __name__ == "__main__":
    main()
