# SPDX-License-Identifier: Apache-2.0
"""Independent synthetic wire frames only; no initramfs/media or code execution."""
import gzip
import hashlib
import os
from pathlib import Path
import random
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch

import initramfs_inspection as inspector


def record(name, body=b"", mode=stat.S_IFREG | 0o644, ino=1, links=1, device=(0, 0)):
    encoded = name.encode() + b"\x00"
    values = (ino, mode, 0, 0, links, 0, len(body), 0, 0, *device, len(encoded), 0)
    header = b"070701" + b"".join(f"{value:08x}".encode() for value in values)
    return header + encoded + bytes((-(110 + len(encoded))) % 4) + body + bytes((-len(body)) % 4)


def archive(*records):
    plain = b"".join(records) + record("TRAILER!!!", mode=0)
    return gzip.compress(plain + bytes((-len(plain)) % 512), mtime=0)


def elf(needed=None, interpreter=None):
    """Minimal ELF metadata, with no executable machine instructions."""
    if needed is None and interpreter is None:
        size = 120
        ident = b"\x7fELF\x02\x01\x01" + bytes(9)
        header = struct.pack("<HHIQQQIHHHHHH", 2, 183, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
        return ident + header + struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0, size, size, 1)
    needed = needed or []
    strings = b"\x00" + b"\x00".join(name.encode() for name in needed) + b"\x00"
    offsets, offset = [], 1
    for name in needed:
        offsets.append(offset); offset += len(name) + 1
    count = 2 + bool(interpreter)
    dynamic_at = 64 + count * 56
    dynamic_size = (len(offsets) + 3) * 16
    strings_at = dynamic_at + dynamic_size
    interp = interpreter.encode() + b"\x00" if interpreter else b""
    interp_at = strings_at + len(strings)
    size = interp_at + len(interp)
    ident = b"\x7fELF\x02\x01\x01" + bytes(9)
    header = struct.pack("<HHIQQQIHHHHHH", 3, 183, 1, 0, 64, 0, 0, 64, 56, count, 0, 0, 0)
    program = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0, size, size, 1)
    program += struct.pack("<IIQQQQQQ", 2, 4, dynamic_at, 0x400000 + dynamic_at, 0, dynamic_size, dynamic_size, 8)
    if interpreter:
        program += struct.pack("<IIQQQQQQ", 3, 4, interp_at, 0x400000 + interp_at, 0, len(interp), len(interp), 1)
    dynamic = b"".join(struct.pack("<qQ", 1, value) for value in offsets)
    dynamic += struct.pack("<qQ", 5, 0x400000 + strings_at) + struct.pack("<qQ", 10, len(strings)) + bytes(16)
    return ident + header + program + dynamic + strings + interp


def fixture(needed=None, interpreter=None):
    init = b"#!/bin/sh\n# synthetic, never executed\n"
    nodes = [record(".", mode=stat.S_IFDIR | 0o700)]
    directories = ("usr", "usr/bin", "usr/sbin", "usr/lib", "usr/lib/mdev", "etc", "dev",
                   "usr/lib/modules", "usr/lib/modules/" + inspector.KERNEL_RELEASE,
                   "usr/lib/modules/" + inspector.KERNEL_RELEASE + "/kernel")
    nodes += [record(name, mode=stat.S_IFDIR | 0o755) for name in directories]
    nodes += [record(name, target.encode(), stat.S_IFLNK | 0o777)
              for name, target in (("bin", "usr/bin"), ("sbin", "usr/sbin"), ("lib", "usr/lib"),
                                   ("usr/bin/sh", "/bin/busybox"), ("usr/sbin/modprobe", "../bin/kmod"))]
    for path in ("usr/bin/busybox", "usr/bin/kmod", "usr/sbin/apk", "usr/sbin/nlplug-findfs"):
        nodes.append(record(path, elf(needed=needed, interpreter=interpreter), stat.S_IFREG | 0o755))
    nodes.append(record("init", init, stat.S_IFREG | 0o755))
    nodes += [record(name, b"synthetic\n") for name in inspector.DATA_FILES]
    nodes.append(record("usr/lib/mdev/synthetic.rules", b"# metadata fixture only\n"))
    prefix = "usr/lib/modules/" + inspector.KERNEL_RELEASE + "/"
    rows = "".join("kernel/" + name + ".ko:\n" for name in inspector.DRIVERS).encode()
    nodes += [record(prefix + "kernel/" + name + ".ko", b"synthetic module metadata") for name in inspector.DRIVERS]
    nodes += [record(prefix + name, rows if name == "modules.dep" else b"fixture\n") for name in inspector.INDEX_FILES]
    return nodes, init


class InitramfsInspectionTests(unittest.TestCase):
    def inspect(self, compressed, **kwargs):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            path = directory / "synthetic.gz"
            path.write_bytes(compressed); path.chmod(0o400)
            return inspector.inspect_initramfs(path, len(compressed), hashlib.sha256(compressed).hexdigest(), **kwargs)

    def test_valid_framing_is_separate_from_semantic_completeness(self):
        result = self.inspect(archive(record(".", mode=stat.S_IFDIR | 0o755)))
        self.assertTrue(result["gzipCRCAndEOF"])
        self.assertTrue(result["newcFramingValid"])
        self.assertFalse(result["closureComplete"])
        self.assertFalse(result["bootabilityVerified"])
        self.assertFalse(result["executionPerformed"])

    def test_complete_synthetic_alias_tool_module_metadata_closure(self):
        nodes, init = fixture()
        with patch.object(inspector, "INIT_SIZE", len(init)), patch.object(inspector, "INIT_SHA", hashlib.sha256(init).hexdigest()):
            result = self.inspect(archive(*nodes))
        self.assertTrue(result["closureComplete"], result["closureIssues"])
        self.assertEqual(set(result["requiredDriverPaths"]), set(inspector.DRIVERS))
        self.assertFalse(result["moduleABIVerified"])
        self.assertFalse(result["toolContentAuthenticated"])

    def test_dynamic_library_and_interpreter_are_resolved_in_virtual_archive(self):
        nodes, init = fixture(["libfixture.so.1"], "/lib/ld-musl-aarch64.so.1")
        nodes += [record("usr/lib/libfixture.so.1", elf(), stat.S_IFREG | 0o644)]
        nodes += [record("usr/lib/ld-musl-aarch64.so.1", elf(), stat.S_IFREG | 0o755)]
        with patch.object(inspector, "INIT_SIZE", len(init)), patch.object(inspector, "INIT_SHA", hashlib.sha256(init).hexdigest()):
            result = self.inspect(archive(*nodes))
        self.assertTrue(result["closureComplete"], result["closureIssues"])
        self.assertIn("usr/lib/libfixture.so.1", result["elfDependencies"])
        self.assertIn("usr/lib/ld-musl-aarch64.so.1", result["elfDependencies"])
        interpreter, needed = inspector._elf(elf(["libfixture.so.1"], "/lib/ld-musl-aarch64.so.1"))
        self.assertEqual(interpreter, "/lib/ld-musl-aarch64.so.1")
        self.assertEqual(needed, ["libfixture.so.1"])

    def test_interpreter_missing_nonexecutable_and_recursive_are_incomplete(self):
        interpreter = "/lib/ld-musl-aarch64.so.1"
        for loader, mode, expected in ((None, 0, "baseToolOrLibraryMissing"),
                                      (elf(), 0o644, "baseToolOrLibraryMissing"),
                                      (elf(interpreter=interpreter), 0o755, "interpreterRequiresInterpreter")):
            with self.subTest(expected=expected, mode=mode):
                nodes, init = fixture(interpreter=interpreter)
                if loader is not None:
                    nodes.append(record("usr/lib/ld-musl-aarch64.so.1", loader, stat.S_IFREG | mode))
                with patch.object(inspector, "INIT_SIZE", len(init)), patch.object(inspector, "INIT_SHA", hashlib.sha256(init).hexdigest()):
                    result = self.inspect(archive(*nodes))
                self.assertFalse(result["closureComplete"])
                self.assertIn(expected, result["closureIssues"])

    def test_elf_without_load_segment_cannot_qualify_as_program_metadata(self):
        malformed = bytearray(elf()); struct.pack_into("<I", malformed, 64, 0)
        with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^elfLoadSegment$"):
            inspector._elf(bytes(malformed))

    def test_dynamic_table_and_string_offsets_are_bounded_and_terminated(self):
        valid = elf(["libfixture.so.1"])
        dynamic_at = 64 + 2 * 56
        corrupted = []
        raw = bytearray(valid); struct.pack_into("<Q", raw, dynamic_at + 16 + 8, 0x800000); corrupted.append(raw)
        raw = bytearray(valid); struct.pack_into("<Q", raw, dynamic_at + 8, 1 << 30); corrupted.append(raw)
        raw = bytearray(valid); struct.pack_into("<Q", raw, dynamic_at + 32 + 8, (1 << 20) + 1); corrupted.append(raw)
        raw = bytearray(valid); struct.pack_into("<qQ", raw, dynamic_at + 48, 1, 1); corrupted.append(raw)
        for raw in corrupted:
            with self.subTest(sha=hashlib.sha256(raw).hexdigest()), self.assertRaises(inspector.InitramfsInspectionError):
                inspector._elf(bytes(raw))

    def test_missing_library_and_dependency_row_are_incomplete(self):
        nodes, _ = fixture(["absent.so.1"])
        result = self.inspect(archive(*nodes))
        self.assertIn("libraryMissingOrAmbiguous", result["closureIssues"])
        prefix = "usr/lib/modules/" + inspector.KERNEL_RELEASE + "/"
        broken = [node for node in nodes if (prefix + "modules.dep").encode() not in node]
        broken.append(record(prefix + "modules.dep", b"kernel/virtio_blk.ko: kernel/absent.ko\n"))
        self.assertIn("moduleDependenciesIncomplete", self.inspect(archive(*broken))["closureIssues"])

    def test_module_dependency_cycles_are_not_a_complete_closure(self):
        nodes, init = fixture()
        prefix = "usr/lib/modules/" + inspector.KERNEL_RELEASE + "/"
        nodes = [node for node in nodes if (prefix + "modules.dep").encode() not in node]
        rows = []
        for name in inspector.DRIVERS:
            dependency = "kernel/sd_mod.ko" if name == "ext4" else "kernel/ext4.ko" if name == "sd_mod" else ""
            rows.append("kernel/" + name + ".ko: " + dependency + "\n")
        nodes.append(record(prefix + "modules.dep", "".join(rows).encode()))
        with patch.object(inspector, "INIT_SIZE", len(init)), patch.object(inspector, "INIT_SHA", hashlib.sha256(init).hexdigest()):
            result = self.inspect(archive(*nodes))
        self.assertFalse(result["closureComplete"])
        self.assertIn("moduleDependenciesIncomplete", result["closureIssues"])

    def test_isolated_module_driver_namespace_and_index_requirements(self):
        for alteration, expected in (("driver", "requiredDriverMissingOrAmbiguous"),
                                     ("index", "moduleIndexMissing"),
                                     ("namespace", "moduleNamespace"),
                                     ("orphan", "moduleDependenciesIncomplete")):
            with self.subTest(alteration=alteration):
                nodes, init = fixture()
                prefix = "usr/lib/modules/" + inspector.KERNEL_RELEASE + "/"
                if alteration == "driver":
                    nodes = [node for node in nodes if (prefix + "kernel/virtio_mmio.ko").encode() not in node
                             and (prefix + "modules.dep").encode() not in node]
                    rows = "".join("kernel/" + name + ".ko:\n" for name in inspector.DRIVERS if name != "virtio_mmio")
                    nodes.append(record(prefix + "modules.dep", rows.encode()))
                elif alteration == "index":
                    nodes = [node for node in nodes if (prefix + "modules.dep.bin").encode() not in node]
                elif alteration == "namespace":
                    nodes.append(record("usr/lib/modules/6.18.52-0-virt", mode=stat.S_IFDIR | 0o755))
                else:
                    nodes.append(record(prefix + "kernel/orphan.ko", b"unindexed fixture"))
                with patch.object(inspector, "INIT_SIZE", len(init)), patch.object(inspector, "INIT_SHA", hashlib.sha256(init).hexdigest()):
                    result = self.inspect(archive(*nodes))
                self.assertFalse(result["closureComplete"])
                self.assertIn(expected, result["closureIssues"])
                if alteration == "driver":
                    self.assertNotIn("moduleDependenciesIncomplete", result["closureIssues"])

    def test_mdev_directory_requires_actual_regular_content(self):
        nodes, init = fixture()
        nodes = [node for node in nodes if b"usr/lib/mdev/synthetic.rules" not in node]
        with patch.object(inspector, "INIT_SIZE", len(init)), patch.object(inspector, "INIT_SHA", hashlib.sha256(init).hexdigest()):
            result = self.inspect(archive(*nodes))
        self.assertFalse(result["closureComplete"])
        self.assertIn("mdevDataMissing", result["closureIssues"])

    def test_crc_truncation_concatenation_and_source_hash_fail_closed(self):
        valid = archive(record("item", b"fixture"))
        corrupt = bytearray(valid); corrupt[-8] ^= 1
        for value in (bytes(corrupt), valid[:-3], valid + valid, valid + b"\x00"):
            with self.subTest(length=len(value)), self.assertRaises(inspector.InitramfsInspectionError):
                self.inspect(value)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary).resolve() / "fixture.gz"
            path.write_bytes(valid); path.chmod(0o400)
            with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^sourceHash$"):
                inspector.inspect_initramfs(path, len(valid), "0" * 64)

    def test_header_padding_trailer_and_duplicate_alias_paths_reject(self):
        entry = record("item", b"x")
        bad_padding = bytearray(entry); bad_padding[-1] = 1
        bad_hex = bytearray(entry); bad_hex[6] = ord("g")
        values = (archive(bytes(bad_padding)), archive(bytes(bad_hex)), archive(entry, record("./item")),
                  gzip.compress(entry, mtime=0), archive(record("TRAILER!!!", b"x", mode=0)),
                  archive(record("../escape")), archive(record("/absolute")))
        for value in values:
            with self.subTest(sha=hashlib.sha256(value).hexdigest()), self.assertRaises(inspector.InitramfsInspectionError):
                self.inspect(value)

    def test_hardlink_data_last_is_resolved_without_copying_or_execution(self):
        result = self.inspect(archive(record("first", ino=7, links=2), record("last", b"payload", ino=7, links=2)))
        rows = {row["path"]: row for row in result["inventory"]}
        self.assertEqual(rows["first"]["storedBytes"], 0)
        self.assertEqual(rows["first"]["logicalBytes"], 7)
        self.assertEqual(rows["first"]["sha256"], rows["last"]["sha256"])
        self.assertEqual(rows["first"]["hardlinkGroup"], "last")
        first_data = self.inspect(archive(record("first", b"payload", ino=7, links=3), record("last", ino=7, links=3)))
        self.assertEqual(first_data["inventory"][1]["logicalBytes"], 7)
        with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^newcHardlinkContent$"):
            self.inspect(archive(record("first", b"a", ino=7, links=2), record("last", b"b", ino=7, links=2)))

    def test_symlink_escape_cycle_and_ancestor_overwrite_reject(self):
        for nodes in ((record("link", b"../escape", stat.S_IFLNK | 0o777),),
                      (record("link", b"absent/../../escape", stat.S_IFLNK | 0o777),),
                      (record("link", b"link", stat.S_IFLNK | 0o777),),
                      (record("alias", b"target", stat.S_IFLNK | 0o777), record("alias/item"))):
            with self.subTest(count=len(nodes)), self.assertRaises(inspector.InitramfsInspectionError):
                self.inspect(archive(*nodes))

    def test_safe_optional_nodes_and_other_device_types(self):
        result = self.inspect(archive(record("dev", mode=stat.S_IFDIR | 0o755),
                             record("dev/null", mode=stat.S_IFCHR | 0o666, device=(1, 3))))
        self.assertEqual(result["inventory"][1]["device"], [1, 3])
        for node in (record("dev/null", mode=stat.S_IFCHR | 0o666, device=(1, 5)),
                     record("dev/disk", mode=stat.S_IFBLK | 0o600, device=(8, 0)),
                     record("pipe", mode=stat.S_IFIFO | 0o600)):
            with self.subTest(length=len(node)), self.assertRaises(inspector.InitramfsInspectionError):
                self.inspect(archive(node))

    def test_entry_body_and_decoded_limits_precede_unbounded_work(self):
        value = archive(record("item", b"x" * 4096))
        with patch.object(inspector, "MAX_FILE", 100):
            with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^newcHeaderBound$"):
                self.inspect(value)
        with patch.object(inspector, "MAX_DECODED", 100):
            with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^decodedLimit$"):
                self.inspect(value)
        with patch.object(inspector, "MAX_ENTRIES", 1):
            with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^newcDuplicateOrCount$"):
                self.inspect(archive(record("first"), record("second")))

    def test_large_incompressible_body_crosses_compressed_and_decoded_pump_boundaries(self):
        body = random.Random(1847).randbytes(200123)
        compressed = archive(record("large-fixture", body))
        self.assertGreater(len(compressed), 3 * 65536)
        result = self.inspect(compressed)
        row = result["inventory"][0]
        self.assertEqual(row["logicalBytes"], len(body))
        self.assertEqual(row["sha256"], hashlib.sha256(body).hexdigest())
        self.assertTrue(result["gzipCRCAndEOF"])
        self.assertGreater(result["decodedBytes"], len(body))

    def test_input_symlink_hardlink_and_public_parent_refuse(self):
        data = archive(record("item"))
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary).resolve(); path = folder / "source.gz"
            path.write_bytes(data); path.chmod(0o400)
            alias = folder / "alias.gz"; alias.symlink_to(path)
            with self.assertRaises(inspector.InitramfsInspectionError):
                inspector.inspect_initramfs(alias, len(data), hashlib.sha256(data).hexdigest())
            alias.unlink(); os.link(path, alias)
            with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^sourceIdentity$"):
                inspector.inspect_initramfs(path, len(data), hashlib.sha256(data).hexdigest())
            alias.unlink(); folder.chmod(0o755)
            with self.assertRaisesRegex(inspector.InitramfsInspectionError, "^inputPrivateDirectory$"):
                inspector.inspect_initramfs(path, len(data), hashlib.sha256(data).hexdigest())
