# SPDX-License-Identifier: Apache-2.0
"""Bounded metadata inspection of one gzip/070701 initramfs; never extract/execute.

Format: https://www.kernel.org/doc/html/latest/driver-api/early-userspace/buffer-format.html
ELF metadata: https://gabi.xinuos.com/elf/07-pheader.html and /08-dynamic.html
This deliberately supports one gzip member and one terminated newc archive.
"""
import hashlib
import os
from pathlib import Path
import re
import stat
import struct
import time
import zlib

KERNEL_RELEASE = "6.18.55-0-virt"
INIT_SIZE = 30369
INIT_SHA = "c82ca6234998699e10920b2b4270743a3a8333f0cfe34386e74da4892f30424b"
MAX_SOURCE = 64 << 20
MAX_DECODED = 128 << 20
MAX_FILE = 32 << 20
MAX_ENTRIES = 4096
MAX_NAMES = 1 << 20
CHUNK = 65536
TOOLS = ("bin/busybox", "bin/sh", "sbin/modprobe", "sbin/apk", "sbin/nlplug-findfs")
DATA_FILES = ("etc/fstab", "etc/passwd", "etc/group", "etc/mdev.conf")
DRIVERS = ("virtio_blk", "virtio_mmio", "ext4", "jbd2", "sd_mod", "scsi_mod", "scsi_common", "xhci_hcd",
           "xhci_pci", "usb_storage", "isofs", "loop", "squashfs")
INDEX_FILES = ("modules.dep", "modules.dep.bin", "modules.alias", "modules.alias.bin",
               "modules.builtin", "modules.builtin.modinfo", "modules.order")


class InitramfsInspectionError(RuntimeError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _require(condition, code):
    if not condition:
        raise InitramfsInspectionError(code)


def _stamp(s):
    return (s.st_dev, s.st_ino, s.st_uid, s.st_nlink, s.st_mode, s.st_size,
            s.st_mtime_ns, s.st_ctime_ns)


def _ancestry(path):
    _require(path.is_absolute() and str(path) == os.path.abspath(path), "inputPath")
    for parent in [*reversed(path.parent.parents), path.parent]:
        s = parent.lstat()
        sticky_tmp = str(parent) == "/private/tmp" and s.st_uid == 0 and s.st_mode & stat.S_ISVTX
        _require(stat.S_ISDIR(s.st_mode) and s.st_uid in (0, os.geteuid())
                 and (s.st_mode & 0o022 == 0 or sticky_tmp), "inputAncestry")
    _require(path.parent.lstat().st_uid == os.geteuid()
             and stat.S_IMODE(path.parent.lstat().st_mode) == 0o700, "inputPrivateDirectory")


class _GzipReader:
    def __init__(self, fd, size, deadline):
        self.fd, self.remaining, self.deadline = fd, size, deadline
        self.decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        self.pending, self.buffer, self.done, self.decoded = b"", bytearray(), False, 0

    def _pump(self):
        _require(time.monotonic() < self.deadline, "deadline")
        if self.pending:
            compressed, self.pending = self.pending, b""
        else:
            _require(self.remaining > 0, "gzipTruncated")
            compressed = os.read(self.fd, min(CHUNK, self.remaining))
            _require(bool(compressed), "sourceTruncated")
            self.remaining -= len(compressed)
        try:
            output = self.decoder.decompress(compressed, CHUNK)
        except zlib.error:
            raise InitramfsInspectionError("gzipIntegrity") from None
        self.pending = self.decoder.unconsumed_tail
        self.decoded += len(output)
        _require(self.decoded <= MAX_DECODED, "decodedLimit")
        self.buffer.extend(output)
        if self.decoder.eof:
            _require(not self.decoder.unused_data and not self.pending and self.remaining == 0,
                     "gzipTrailingOrConcatenated")
            self.done = True

    def read(self, size):
        _require(0 <= size <= CHUNK, "readBound")
        while len(self.buffer) < size and not self.done:
            self._pump()
        output = bytes(self.buffer[:size])
        del self.buffer[:size]
        return output

    def exact(self, size):
        value = self.read(size)
        _require(len(value) == size, "newcTruncated")
        return value


def _path(raw):
    _require(0 < len(raw) <= 4096 and b"\x00" not in raw, "newcPath")
    try:
        name = raw.decode("utf-8", "strict")
    except UnicodeError:
        raise InitramfsInspectionError("newcPath") from None
    _require(not any(ord(c) < 32 or ord(c) == 127 for c in name), "newcPath")
    if name in (".", "./"):
        return "."
    if name.startswith("./"):
        name = name[2:]
    _require(not name.startswith("/") and all(part not in ("", ".", "..") for part in name.split("/")),
             "newcPath")
    return name


def _newc(reader):
    entries, groups, name_bytes = {}, {}, 0
    while True:
        header = reader.exact(110)
        _require(header[:6] == b"070701" and re.fullmatch(rb"[0-9a-fA-F]{104}", header[6:]), "newcHeader")
        fields = [int(header[offset:offset + 8], 16) for offset in range(6, 110, 8)]
        ino, mode, uid, gid, links, mtime, size, major, minor, rmajor, rminor, namesize, check = fields
        _require(check == 0 and 1 <= namesize <= 4096 and size <= MAX_FILE, "newcHeaderBound")
        raw_name = reader.exact(namesize)
        cut = raw_name.find(b"\x00")
        _require(cut >= 0 and not any(raw_name[cut:]), "newcNameTermination")
        _require(not any(reader.exact((-(110 + namesize)) % 4)), "newcPadding")
        if raw_name[:cut] == b"TRAILER!!!":
            _require(size == 0, "newcTrailer")
            while tail := reader.read(CHUNK):
                _require(not any(tail), "newcTrailingData")
            _require(reader.done and reader.decoded % 4 == 0, "newcEnd")
            break
        name = _path(raw_name[:cut])
        name_bytes += len(raw_name)
        _require(name not in entries and len(entries) < MAX_ENTRIES and name_bytes <= MAX_NAMES
                 and 1 <= links <= MAX_ENTRIES, "newcDuplicateOrCount")
        kind = stat.S_IFMT(mode)
        _require(kind in (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK, stat.S_IFCHR), "newcType")
        _require(kind in (stat.S_IFREG, stat.S_IFLNK) or size == 0, "newcNonRegularBody")
        _require(name != "." or kind == stat.S_IFDIR, "newcRootType")
        if kind == stat.S_IFLNK:
            _require(0 < size <= 4096 and links == 1, "newcSymlink")
        if kind == stat.S_IFCHR:
            permitted = {"dev/null": (1, 3, 0o666), "dev/console": (5, 1, 0o600)}
            _require(name in permitted and (rmajor, rminor, stat.S_IMODE(mode)) == permitted[name]
                     and links == 1, "newcDevice")
        if name.endswith("/modules.dep"):
            _require(size <= 2 << 20, "moduleIndexBound")
        retain = kind == stat.S_IFLNK or name == "init" or name.endswith("/modules.dep") or links > 1
        retain = retain or (kind == stat.S_IFREG and not re.search(r"(?:^|/)modules/", name))
        body, digest, remaining = bytearray(), hashlib.sha256(), size
        while remaining:
            block = reader.exact(min(CHUNK, remaining))
            digest.update(block)
            if retain:
                body.extend(block)
            remaining -= len(block)
        _require(not any(reader.exact((-size) % 4)), "newcPadding")
        entry = dict(path=name, type={stat.S_IFREG: "regular", stat.S_IFDIR: "directory",
                                     stat.S_IFLNK: "symlink", stat.S_IFCHR: "character"}[kind],
                     storedBytes=size, logicalBytes=size, sha256=digest.hexdigest(), mode=mode,
                     inode=ino, links=links, body=bytes(body))
        if kind == stat.S_IFLNK:
            try:
                target = body.decode("utf-8", "strict")
            except UnicodeError:
                raise InitramfsInspectionError("newcSymlink") from None
            _require(target and not any(ord(c) < 32 or ord(c) == 127 for c in target), "newcSymlink")
            lexical = [] if target.startswith("/") else name.split("/")[:-1]
            for part in target.split("/"):
                if part == "..":
                    _require(bool(lexical), "symlinkEscape")
                    lexical.pop()
                elif part not in ("", "."):
                    lexical.append(part)
            entry["linkTarget"] = target
        if kind == stat.S_IFCHR:
            entry["device"] = [rmajor, rminor]
        entries[name] = entry
        if kind == stat.S_IFREG and links > 1:
            groups.setdefault((major, minor, ino), []).append((entry, (mode, uid, gid, links, mtime)))
    for group in groups.values():
        _require(len({metadata for _, metadata in group}) == 1 and len(group) <= group[0][1][3], "newcHardlink")
        with_data = [entry for entry, _ in group if entry["storedBytes"]]
        _require(len({entry["sha256"] for entry in with_data}) <= 1, "newcHardlinkContent")
        original = with_data[-1] if with_data else group[0][0]
        for entry, _ in group:
            entry.update(logicalBytes=original["logicalBytes"], sha256=original["sha256"], body=original["body"],
                         hardlinkGroup=original["path"])
    return entries


def _resolve(entries, path):
    parts, resolved, visited = path.lstrip("/").split("/"), [], set()
    for _ in range(128):
        if not parts:
            name = "/".join(resolved) or "."
            return entries.get(name)
        component = parts.pop(0)
        if component in ("", "."):
            continue
        if component == "..":
            _require(bool(resolved), "symlinkEscape")
            resolved.pop()
            continue
        name = "/".join(resolved + [component])
        entry = entries.get(name)
        if entry is None:
            return None
        if entry["type"] == "symlink":
            state = (name, tuple(parts))
            _require(state not in visited, "symlinkCycle")
            visited.add(state)
            target = entry["linkTarget"]
            if target.startswith("/"):
                resolved = []
            parts = target.split("/") + parts
        else:
            _require(not parts or entry["type"] == "directory", "pathAncestorType")
            resolved.append(component)
    raise InitramfsInspectionError("symlinkDepth")


def _elf(body):
    _require(len(body) >= 64 and body[:7] == b"\x7fELF\x02\x01\x01", "elfHeader")
    header = struct.unpack_from("<HHIQQQIHHHHHH", body, 16)
    kind, machine, version, _, phoff, _, _, ehsize, phsize, phcount, _, _, _ = header
    _require(kind in (2, 3) and machine == 183 and version == 1 and ehsize == 64
             and phsize == 56 and 0 < phcount <= 128 and phoff + phsize * phcount <= len(body), "elfHeader")
    loads, dynamic, interpreter = [], None, None
    for index in range(phcount):
        ptype, _, offset, vaddr, _, filesz, memsz, _ = struct.unpack_from("<IIQQQQQQ", body, phoff + index * phsize)
        _require(filesz <= memsz and offset + filesz <= len(body), "elfSegment")
        if ptype == 1:
            loads.append((vaddr, offset, filesz))
        elif ptype == 2:
            _require(dynamic is None and filesz <= 65536 and filesz % 16 == 0, "elfDynamic")
            dynamic = (offset, filesz)
        elif ptype == 3:
            _require(interpreter is None and 1 < filesz <= 4096, "elfInterpreter")
            raw = body[offset:offset + filesz]
            _require(raw.endswith(b"\x00") and b"\x00" not in raw[:-1], "elfInterpreter")
            interpreter = raw[:-1].decode("ascii", "strict")
            _require(interpreter.startswith("/"), "elfInterpreter")
    _require(bool(loads), "elfLoadSegment")
    if dynamic is None:
        return interpreter, []
    strings, size, needed, terminated = None, None, [], False
    offset, length = dynamic
    for position in range(offset, offset + length, 16):
        tag, value = struct.unpack_from("<qQ", body, position)
        if tag == 0:
            terminated = True
            break
        if tag == 1:
            needed.append(value)
        elif tag == 5:
            _require(strings is None, "elfDynamic")
            strings = value
        elif tag == 10:
            _require(size is None and value <= 1 << 20, "elfDynamic")
            size = value
    _require(terminated and len(needed) <= 64, "elfDynamic")
    if not needed:
        return interpreter, []
    _require(strings is not None and size is not None, "elfStrings")
    locations = [file + strings - virtual for virtual, file, stored in loads
                 if virtual <= strings and strings + size <= virtual + stored]
    _require(len(locations) == 1, "elfStrings")
    start = locations[0]
    names = []
    for position in needed:
        _require(position < size, "elfStrings")
        end = body.find(b"\x00", start + position, start + size)
        _require(end > start + position and end - start - position <= 255, "elfStrings")
        name = body[start + position:end].decode("ascii", "strict")
        _require(re.fullmatch(r"[A-Za-z0-9_+.@-]+", name), "elfLibraryName")
        names.append(name)
    _require(len(names) == len(set(names)), "elfLibraryName")
    return interpreter, names


def _closure(entries, deadline):
    issues, binaries, driver_paths = [], {}, {}
    def issue(code):
        if code not in issues:
            issues.append(code)
    for entry in entries.values():
        _require(time.monotonic() < deadline, "deadline")
        for depth in range(1, len(entry["path"].split("/"))):
            parent = entries.get("/".join(entry["path"].split("/")[:depth]))
            _require(parent is None or parent["type"] == "directory", "archiveAncestorType")
        if entry["type"] == "symlink" and _resolve(entries, entry["path"]) is None:
            issue("danglingSymlink")
    init = _resolve(entries, "init")
    if not init or init["type"] != "regular" or not init["mode"] & 0o111 or init["logicalBytes"] != INIT_SIZE or init["sha256"] != INIT_SHA:
        issue("initMismatch")
    for path in DATA_FILES:
        entry = _resolve(entries, path)
        if not entry or entry["type"] != "regular" or entry["logicalBytes"] == 0:
            issue("baseDataMissing")
    mdev = _resolve(entries, "lib/mdev")
    if not mdev or mdev["type"] != "directory" or not any(
            name.startswith(mdev["path"] + "/") and entry["type"] == "regular" and entry["logicalBytes"]
            for name, entry in entries.items()):
        issue("mdevDataMissing")
    pending = [(path, True, False) for path in TOOLS]
    while pending:
        _require(time.monotonic() < deadline, "deadline")
        path, executable, loader = pending.pop()
        if len(binaries) >= 128 or len(pending) > 4096:
            issue("elfClosureBound")
            break
        entry = _resolve(entries, path)
        if not entry or entry["type"] != "regular" or (executable and not entry["mode"] & 0o111):
            issue("baseToolOrLibraryMissing")
            continue
        if entry["path"] in binaries:
            if loader and binaries[entry["path"]]["interpreter"]:
                issue("interpreterRequiresInterpreter")
            continue
        try:
            interpreter, needed = _elf(entry["body"])
        except (InitramfsInspectionError, UnicodeError, struct.error):
            issue("elfMetadataUnsupported")
            continue
        binaries[entry["path"]] = dict(interpreter=interpreter, needed=needed)
        if loader and interpreter:
            issue("interpreterRequiresInterpreter")
        elif interpreter:
            pending.append((interpreter, True, True))
        for name in needed:
            choices = [_resolve(entries, prefix + name) for prefix in ("lib/", "usr/lib/")]
            choices = {choice["path"] for choice in choices if choice and choice["type"] == "regular"}
            if len(choices) != 1:
                issue("libraryMissingOrAmbiguous")
            else:
                pending.extend((choice, False, False) for choice in choices)
    namespaces = {match[1] for name in entries if (match := re.search(r"(?:^|/)modules/([^/]+)", name))}
    if namespaces != {KERNEL_RELEASE}:
        issue("moduleNamespace")
    prefix = "lib/modules/" + KERNEL_RELEASE + "/"
    for name in INDEX_FILES:
        entry = _resolve(entries, prefix + name)
        if not entry or entry["type"] != "regular" or (name.endswith(".bin") and not entry["logicalBytes"]):
            issue("moduleIndexMissing")
    dep = _resolve(entries, prefix + "modules.dep")
    module_rows = {}
    if dep and dep["type"] == "regular":
        try:
            _require(dep["logicalBytes"] <= 2 << 20, "moduleDependency")
            text = dep["body"].decode("ascii", "strict")
            _require(len(text) <= 2 << 20 and text.endswith("\n"), "moduleDependency")
            for row in text.splitlines():
                _require(time.monotonic() < deadline, "deadline")
                _require(len(row) <= 8192 and row.count(":") == 1, "moduleDependency")
                name, values = row.split(":", 1)
                paths = [name, *values.split()]
                for path in paths:
                    _require(re.fullmatch(r"[A-Za-z0-9_+./-]+\.ko(?:\.(?:gz|xz|zst))?", path)
                             and ".." not in path.split("/") and not path.startswith("/"), "moduleDependency")
                    entry = _resolve(entries, prefix + path)
                    _require(entry is not None and entry["type"] == "regular", "moduleDependency")
                _require(name not in module_rows, "moduleDependency")
                module_rows[name] = values.split()
            directory = _resolve(entries, prefix.rstrip("/"))
            _require(directory is not None and directory["type"] == "directory", "moduleDependency")
            real_prefix = directory["path"] + "/"
            present = {name[len(real_prefix):] for name, entry in entries.items()
                       if name.startswith(real_prefix) and entry["type"] == "regular"
                       and re.search(r"\.ko(?:\.(?:gz|xz|zst))?$", name)}
            _require(set(module_rows) == present
                     and all(dependency in module_rows for values in module_rows.values() for dependency in values),
                     "moduleDependency")
            finished, visiting = set(), set()
            for name in module_rows:
                stack = [(name, False)]
                while stack:
                    node, leaving = stack.pop()
                    if leaving:
                        visiting.remove(node); finished.add(node)
                    elif node not in finished:
                        _require(node not in visiting, "moduleDependency")
                        visiting.add(node); stack.append((node, True))
                        stack.extend((dependency, False) for dependency in module_rows[node])
        except (InitramfsInspectionError, UnicodeError):
            issue("moduleDependenciesIncomplete")
    else:
        issue("moduleDependenciesIncomplete")
    for name in module_rows:
        basename = name.rsplit("/", 1)[-1].split(".ko", 1)[0].replace("-", "_")
        if basename in DRIVERS:
            driver_paths.setdefault(basename, []).append(_resolve(entries, prefix + name)["path"])
    if any(len(driver_paths.get(name, [])) != 1 for name in DRIVERS):
        issue("requiredDriverMissingOrAmbiguous")
    return issues, binaries, driver_paths, sorted(namespaces)


def inspect_initramfs(path, expected_size, expected_sha):
    """Return safe inventory and separate semantic closure; no boot/ABI acceptance."""
    _require(type(expected_size) is int and 0 < expected_size <= MAX_SOURCE
             and isinstance(expected_sha, str) and re.fullmatch(r"[0-9a-f]{64}", expected_sha), "expectedIdentity")
    path, deadline, fd = Path(path), time.monotonic() + 30, None
    try:
        _ancestry(path)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                 and stat.S_IMODE(before.st_mode) in (0o400, 0o600) and before.st_size == expected_size
                 and _stamp(before) == _stamp(path.lstat()), "sourceIdentity")
        digest, remaining = hashlib.sha256(), expected_size
        while remaining:
            _require(time.monotonic() < deadline, "deadline")
            block = os.read(fd, min(CHUNK, remaining))
            _require(bool(block), "sourceTruncated")
            digest.update(block); remaining -= len(block)
        _require(digest.hexdigest() == expected_sha and not os.read(fd, 1), "sourceHash")
        os.lseek(fd, 0, os.SEEK_SET)
        reader = _GzipReader(fd, expected_size, deadline)
        entries = _newc(reader)
        issues, binaries, drivers, namespaces = _closure(entries, deadline)
        after = os.fstat(fd)
        _require(_stamp(before) == _stamp(after) == _stamp(path.lstat()), "sourceChanged")
        inventory = [{key: value for key, value in entry.items() if key != "body"}
                     for _, entry in sorted(entries.items())]
        return dict(schemaVersion=1, sourceBytes=expected_size, sourceSHA256=expected_sha,
                    decodedBytes=reader.decoded, gzipCRCAndEOF=True, newcFramingValid=True,
                    inventory=inventory, expectedKernelRelease=KERNEL_RELEASE, moduleNamespaces=namespaces,
                    kernelRelease=KERNEL_RELEASE if namespaces == [KERNEL_RELEASE] else None, closureComplete=not issues,
                    closureIssues=issues, requiredDriverPaths=drivers, elfDependencies=binaries,
                    closureDefinition="declared-base-inputs-ELF-and-module-index-metadata",
                    sourceIdentityUnchanged=True, sourceAtimeUnchanged=before.st_atime_ns == after.st_atime_ns,
                    toolContentAuthenticated=False, moduleABIVerified=False, bootabilityVerified=False,
                    binaryModuleIndexSemanticsVerified=False,
                    extractionPerformed=False, executionPerformed=False)
    except (OSError, zlib.error):
        raise InitramfsInspectionError("sourceRead") from None
    finally:
        if fd is not None:
            os.close(fd)
