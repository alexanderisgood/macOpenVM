#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Real pinned payload/staging and optional root-built ISO readback, never a builder.

No subprocess, mount, Windows command, VM, signing or device-health assertion.
The actual new-ISO roundtrip is explicitly skipped until root supplies its built
private output plus independently recorded image SHA256 and length.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("driver_support_preparer", ROOT / "scripts/prepare-windows-driver-support.py")
SUPPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUPPORT)
OLD_IMAGE = ROOT / ".lab/windows-display-support-3ff9bac089d546578527603a56909818/macopenvm-display-evaluation.iso"
OLD_SHA = "55897e3e181068a5e5e4ea52a1e2aed7ec2bbc296ae0afc549d0c139e2dbef3d"
HELPER = "drivers/netkvm/netkvmp.exe"
HELPER_SHA = "6abd66a785e0edd00ce91c09b207d3e67f5567d32cadd44c7d3363a9b1381a37"


def independent_joliet(image):
    """Separate tiny metadata/extent oracle for actual hdiutil carriers, not an ISO emitter."""
    data = image.read_bytes()
    if not 19 * 2048 <= len(data) <= 8 << 20:
        raise ValueError("oracle-image-bound")
    volumes = [data[i * 2048:(i + 1) * 2048] for i in range(16, min(32, len(data) // 2048))]
    volume = next(v for v in volumes if v[:7] == b"\2CD001\1" and v[88:91] in (b"%/@", b"%/C", b"%/E"))
    result, visited = {}, set()
    pending = [(volume[156:156 + volume[156]], "", 0)]
    while pending:
        record, prefix, depth = pending.pop()
        block, size = struct.unpack_from("<I", record, 2)[0], struct.unpack_from("<I", record, 10)[0]
        if depth > 3 or size > 65536 or (block, size) in visited or len(visited) > 8:
            raise ValueError("oracle-directory-bound")
        visited.add((block, size))
        directory, offset = data[block * 2048:block * 2048 + size], 0
        while offset < len(directory):
            length = directory[offset]
            if not length:
                offset = (offset // 2048 + 1) * 2048
                continue
            entry = directory[offset:offset + length]
            if length < 34 or len(entry) != length:
                raise ValueError("oracle-entry-bound")
            offset += length
            encoded = entry[33:33 + entry[32]]
            if encoded in (b"\0", b"\1"):
                continue
            name = encoded.decode("utf-16-be")
            if name in (".", "..") or "/" in name or "\\" in name:
                raise ValueError("oracle-name")
            member = prefix + name
            if entry[25] & 2:
                pending.append((entry, member + "/", depth + 1))
            else:
                start = struct.unpack_from("<I", entry, 2)[0] * 2048
                count = struct.unpack_from("<I", entry, 10)[0]
                if start + count > len(data) or count > 1 << 20 or member in result or len(result) >= 32:
                    raise ValueError("oracle-member-bound")
                result[member] = data[start:start + count]
    return result


def metadata_locations(data):
    """Read offsets from an already accepted actual image; never emit or repair one."""
    result = []
    for sector in range(16, min(32, len(data) // 2048)):
        base = sector * 2048
        kind = data[base]
        if kind == 255: break
        if kind not in (1, 2): continue
        tables = []
        size = struct.unpack_from("<I", data, base + 132)[0]
        for field, order in ((140, "<"), (148, ">")):
            cursor = struct.unpack_from(order + "I", data, base + field)[0] * 2048
            stop, rows = cursor + size, []
            while cursor < stop:
                rows.append(cursor)
                count = data[cursor]
                if not count or len(rows) > 8: raise ValueError("offset-locator-table-bound")
                cursor += 8 + count + count % 2
            if cursor != stop: raise ValueError("offset-locator-table-size")
            tables.append({"field": base + field, "order": order, "rows": rows, "stop": stop})
        directories, pending = {}, [(base + 156, "", 0)]
        while pending:
            record, path, depth = pending.pop()
            start = struct.unpack_from("<I", data, record + 2)[0] * 2048
            length = struct.unpack_from("<I", data, record + 10)[0]
            if depth > 3 or length > 65536 or path in directories or len(directories) > 8:
                raise ValueError("offset-locator-directory-bound")
            cursor, special = start, []
            while cursor < start + length:
                size = data[cursor]
                if not size:
                    cursor = (cursor // 2048 + 1) * 2048
                    continue
                encoded = data[cursor + 33:cursor + 33 + data[cursor + 32]]
                if encoded in (b"\0", b"\1"):
                    special.append(cursor)
                elif data[cursor + 25] == 2:
                    name = encoded.decode("utf-16-be" if kind == 2 else "ascii")
                    pending.append((cursor, path + ("/" if path else "") + name, depth + 1))
                cursor += size
            if len(special) != 2: raise ValueError("offset-locator-dot-bound")
            directories[path] = special
        result.append({"kind": kind, "descriptor": base, "tables": tables, "directories": directories})
    return result


class WindowsDriverSupportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        required_iso = os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_REQUIRE_ISO") == "1"
        if required_iso and not all(os.environ.get(key) for key in ("MACOPENVM_WINDOWS_DRIVER_SUPPORT_PREPARED",
                                                                  "MACOPENVM_WINDOWS_DRIVER_SUPPORT_SHA256",
                                                                  "MACOPENVM_WINDOWS_DRIVER_SUPPORT_BYTES")):
            raise AssertionError("required actual carrier directory and independent image pins are unavailable")
        if not all((ROOT / source).is_dir() for source in (SUPPORT.DISPLAY, SUPPORT.NETWORK)):
            if required_iso or os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_REQUIRE_PAYLOAD") == "1":
                raise AssertionError("required independently pinned private payload is unavailable")
            raise unittest.SkipTest("requires independently pinned local private driver payload; no download or fabricated replacement")

    def setUp(self):
        self.manifest = SUPPORT.load_manifest(ROOT)
        self.payload = SUPPORT.collect_payload(ROOT, self.manifest)

    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix="mvo-driver-support-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / ".lab").mkdir(mode=0o700)
        for row in self.manifest["files"]:
            target = root / row["source"]
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            target.write_bytes(self.payload[row["path"]])
            target.chmod(0o600)
        target = root / SUPPORT.MANIFEST
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes((ROOT / SUPPORT.MANIFEST).read_bytes())
        target.chmod(0o600)
        output = root / ".lab" / ("windows-driver-support-" + uuid.uuid4().hex)
        return root, output

    def helper(self, root):
        return root / next(row["source"] for row in self.manifest["files"] if row["path"] == HELPER)

    def test_actual_pinned_inf_requires_the_missing_legacy_disc_helper(self):
        self.assertEqual(len(self.payload[HELPER]), 266904)
        self.assertEqual(hashlib.sha256(self.payload[HELPER]).hexdigest(), HELPER_SHA)
        self.assertIn(b"netkvmp.exe", self.payload["drivers/netkvm/netkvm.inf"])
        incomplete = dict(self.payload)
        del incomplete[HELPER]
        with self.assertRaisesRegex(ValueError, "missing-inf-payload"):
            SUPPORT.verify_inf(SUPPORT.PROFILES[1], incomplete)
        old = OLD_IMAGE.read_bytes()
        self.assertEqual(hashlib.sha256(old).hexdigest(), OLD_SHA)
        old_members = independent_joliet(OLD_IMAGE)
        self.assertNotIn(HELPER, old_members)
        self.assertEqual(len(old_members["macOpenVM Setup.cmd"]), 1045)
        self.assertNotEqual(old_members["macOpenVM Setup.cmd"], self.payload["macOpenVM Setup.cmd"])

    def test_actual_prepare_preserves_every_source_and_emits_only_exact_staging_and_recipe(self):
        root, output = self.fixture()
        before = {row["source"]: (root / row["source"]).read_bytes() for row in self.manifest["files"]}
        prepared = SUPPORT.prepare(root, output)
        self.assertIsNone(prepared["imageBytes"])
        self.assertIsNone(prepared["imageSHA256"])
        self.assertFalse(prepared["catalogAdmitted"] or prepared["guestAction"])
        self.assertEqual(SUPPORT.verify_staging(output, self.manifest), self.payload)
        self.assertEqual(SUPPORT.verify_prepared(root, output), self.manifest)
        self.assertFalse((output / SUPPORT.ISO_NAME).exists())
        self.assertEqual(prepared["recipe"]["executable"], "/usr/bin/hdiutil")
        self.assertNotIn("-eltorito-boot", prepared["recipe"]["arguments"])
        for row in self.manifest["files"]:
            self.assertEqual((root / row["source"]).read_bytes(), before[row["source"]])
            self.assertEqual(int((output / "staging" / row["path"]).stat().st_mtime), SUPPORT.EPOCH)
        with self.assertRaises(FileExistsError):
            SUPPORT.prepare(root, output)
        second = root / ".lab" / ("windows-driver-support-" + uuid.uuid4().hex)
        self.assertEqual(SUPPORT.prepare(root, second)["inventory"], prepared["inventory"])
        self.assertEqual(SUPPORT.verify_staging(second, self.manifest), self.payload)

    def test_destination_file_substitution_before_timestamp_never_timestamps_preserved_source(self):
        for replacement in ("hardlink", "symlink"):
            with self.subTest(replacement=replacement):
                root, output = self.fixture()
                source = self.helper(root)
                target = output / "staging" / HELPER
                before, source_bytes = source.stat(), source.read_bytes()
                real_utime, injected = os.utime, []

                def substitute(fd, *args, **kwargs):
                    if not injected and target.exists() and isinstance(fd, int) and os.fstat(fd).st_ino == target.stat().st_ino:
                        injected.append(fd)
                        target.unlink()
                        if replacement == "hardlink": os.link(source, target)
                        else: target.symlink_to(source)
                    return real_utime(fd, *args, **kwargs)

                with mock.patch.object(SUPPORT.os, "utime", side_effect=substitute):
                    with self.assertRaisesRegex(ValueError, "output-replaced"):
                        SUPPORT.prepare(root, output)
                self.assertEqual(len(injected), 1, "fault must reach the actual exclusive-file timestamp boundary")
                after = source.stat()
                self.assertEqual((after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns),
                                 (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns))
                self.assertEqual(source.read_bytes(), source_bytes)
                self.assertFalse((output / "prepared.json").exists())
                target.unlink()
                self.assertEqual(source.stat().st_nlink, 1)
                # The injecting actor's link/unlink necessarily changes ctime/nlink;
                # neither is claimed unchanged by the preparer. Mode/mtime/bytes are.

    def test_destination_ancestor_substitution_never_redirects_new_files_or_directories(self):
        for boundary in ("file-create", "directory-create", "file-timestamp"):
            with self.subTest(boundary=boundary):
                root, output = self.fixture()
                external = root / "external"
                external.mkdir(mode=0o700)
                sentinel = external / "sentinel"
                sentinel.write_bytes(b"external namespace must remain untouched")
                sentinel.chmod(0o600)
                before = sentinel.stat()
                staging, detached = output / "staging", output / "detached-staging"
                real_open, real_mkdir, real_utime = os.open, os.mkdir, os.utime
                injected = []

                def substitute():
                    injected.append(boundary)
                    staging.rename(detached)
                    staging.symlink_to(external, target_is_directory=True)

                def open_fault(name, flags, *args, **kwargs):
                    if boundary == "file-create" and not injected and name == "README.txt" and flags & os.O_CREAT:
                        self.assertIsInstance(kwargs.get("dir_fd"), int)
                        substitute()
                    return real_open(name, flags, *args, **kwargs)

                def mkdir_fault(name, *args, **kwargs):
                    if boundary == "directory-create" and not injected and name == "drivers":
                        self.assertIsInstance(kwargs.get("dir_fd"), int)
                        substitute()
                    return real_mkdir(name, *args, **kwargs)

                def utime_fault(fd, *args, **kwargs):
                    if boundary == "file-timestamp" and not injected:
                        self.assertIsInstance(fd, int)
                        substitute()
                    return real_utime(fd, *args, **kwargs)

                with mock.patch.object(SUPPORT.os, "open", side_effect=open_fault), \
                     mock.patch.object(SUPPORT.os, "mkdir", side_effect=mkdir_fault), \
                     mock.patch.object(SUPPORT.os, "utime", side_effect=utime_fault):
                    with self.assertRaises((ValueError, OSError)):
                        SUPPORT.prepare(root, output)
                self.assertEqual(injected, [boundary])
                self.assertEqual(sorted(p.name for p in external.iterdir()), ["sentinel"])
                after = sentinel.stat()
                self.assertEqual(SUPPORT.fact(after), SUPPORT.fact(before))
                self.assertEqual(sentinel.read_bytes(), b"external namespace must remain untouched")
                self.assertFalse((output / "prepared.json").exists())
                self.assertTrue(detached.is_dir())
                if boundary == "directory-create": self.assertTrue((detached / "drivers").is_dir())
                else: self.assertEqual((detached / "README.txt").read_bytes(), self.payload["README.txt"])

    def test_missing_altered_indirect_or_unsafe_helper_refuses_before_any_output(self):
        for condition in ("missing", "altered", "symlink", "hardlink", "writable"):
            with self.subTest(condition=condition):
                root, output = self.fixture()
                helper = self.helper(root)
                if condition == "missing":
                    helper.unlink()
                elif condition == "altered":
                    data = bytearray(helper.read_bytes()); data[0] ^= 1; helper.write_bytes(data)
                elif condition == "writable":
                    helper.chmod(0o666)
                else:
                    retained = root / "retained-helper.exe"
                    helper.rename(retained)
                    if condition == "symlink": helper.symlink_to(retained)
                    else: os.link(retained, helper)
                with self.assertRaises((ValueError, OSError)):
                    SUPPORT.prepare(root, output)
                self.assertFalse(output.exists())

    def test_case_colliding_actual_source_names_refuse_when_filesystem_can_represent_them(self):
        root, output = self.fixture()
        helper = self.helper(root)
        collision = helper.with_name("NETKVMP.EXE")
        try:
            with collision.open("xb") as target: target.write(helper.read_bytes())
        except FileExistsError:
            self.skipTest("case-insensitive filesystem; manifest case-collision rejection is tested separately")
        with self.assertRaisesRegex(ValueError, "case-colliding-input"):
            SUPPORT.prepare(root, output)
        self.assertFalse(output.exists())

    def test_manifest_case_collision_missing_helper_and_unknown_members_are_rejected(self):
        mutations = []
        missing = copy.deepcopy(self.manifest); missing["files"] = [r for r in missing["files"] if r["path"] != HELPER]; mutations.append(missing)
        collision = copy.deepcopy(self.manifest); collision["files"][-1]["path"] = "drivers/netkvm/NETKVMP.EXE"; mutations.append(collision)
        unknown = copy.deepcopy(self.manifest); unknown["files"][-1]["path"] = "autorun.inf"; mutations.append(unknown)
        for value in mutations:
            with self.subTest(value=value["files"][-1]["path"]), self.assertRaises(ValueError):
                SUPPORT.parse_manifest(json.dumps(value).encode())

    def test_manifest_escape_indirection_and_decorated_paths_are_rejected(self):
        for name in ("../escape", "/absolute", "drivers/netkvm/../netkvmp.exe", "drivers\\netkvm\\netkvmp.exe", "C:/netkvmp.exe", "drivers/%helper%.exe"):
            with self.subTest(name=name):
                value = copy.deepcopy(self.manifest); value["files"][0]["source"] = name
                with self.assertRaises(ValueError): SUPPORT.parse_manifest(json.dumps(value).encode())
                root, output = self.fixture()
                (root / SUPPORT.MANIFEST).write_bytes(json.dumps(value).encode())
                with self.assertRaises(ValueError): SUPPORT.prepare(root, output)
                self.assertFalse(output.exists())

    def test_manifest_duplicate_keys_unknown_fields_and_boolean_sizes_refuse(self):
        raw = (ROOT / SUPPORT.MANIFEST).read_bytes()
        with self.assertRaisesRegex(ValueError, "duplicate-json-key"):
            SUPPORT.parse_manifest(raw.replace(b'"schemaVersion": 1,', b'"schemaVersion": 1, "schemaVersion": 1,'))
        for field in ("extra", "schema", "size"):
            value = copy.deepcopy(self.manifest)
            if field == "extra": value["unexpected"] = True
            elif field == "schema": value["schemaVersion"] = True
            else: value["files"][0]["bytes"] = True
            with self.subTest(field=field), self.assertRaises(ValueError):
                SUPPORT.parse_manifest(json.dumps(value).encode())

    def test_known_inf_subset_rejects_indirect_sources_copy_renames_and_external_dependencies(self):
        original = self.payload["drivers/netkvm/netkvm.inf"]
        replacements = [
            (b"netkvmp.exe = 1,,", b"netkvmp.exe = 1,../outside,"),
            (b"netkvmp.exe = 1,,", b"%helper% = 1,,"),
            (b"netkvmp.exe,,,2", b"renamed.exe,netkvmp.exe,,2"),
            (b"[netkvmp.CopyFiles]", b"[netkvmp.CopyFiles]\r\nNeeds=ForeignSection"),
            (b"[netkvmp.CopyFiles]", b"[netkvmp.CopyFiles]\r\nInclude=foreign.inf"),
            (b'1 = %DiskId1%,,,""', b'1 = %DiskId1%,,,"outside"'),
        ]
        for old, new in replacements:
            with self.subTest(new=new):
                self.assertIn(old, original)
                payload = dict(self.payload); payload["drivers/netkvm/netkvm.inf"] = original.replace(old, new)
                with self.assertRaises(ValueError): SUPPORT.verify_inf(SUPPORT.PROFILES[1], payload)
        root, output = self.fixture()
        row = next(r for r in self.manifest["files"] if r["path"] == "drivers/netkvm/netkvm.inf")
        (root / row["source"]).write_bytes(original + b"\r\n; changed pinned INF\r\n")
        with self.assertRaises(ValueError): SUPPORT.prepare(root, output)
        self.assertFalse(output.exists())

    def test_changed_extra_or_indirect_staging_never_passes_fresh_prepared_validation(self):
        for condition in ("missing", "altered", "extra-file", "extra-directory", "symlink"):
            with self.subTest(condition=condition):
                root, output = self.fixture(); SUPPORT.prepare(root, output)
                target = output / "staging" / HELPER
                if condition in ("missing", "symlink"):
                    target.unlink()
                    if condition == "symlink": target.symlink_to(self.helper(root))
                elif condition == "altered":
                    target.chmod(0o600); target.write_bytes(bytes(len(self.payload[HELPER])))
                elif condition == "extra-file": (output / "staging" / "extra.txt").write_bytes(b"unexpected")
                else: (output / "staging" / "extra").mkdir()
                with self.assertRaises((ValueError, OSError)): SUPPORT.verify_prepared(root, output)

    def test_actual_legacy_iso_is_rejected_without_changing_the_admitted_original(self):
        root, output = self.fixture(); SUPPORT.prepare(root, output)
        original = OLD_IMAGE.read_bytes()
        self.assertEqual(hashlib.sha256(original).hexdigest(), OLD_SHA)
        (output / SUPPORT.ISO_NAME).write_bytes(original)
        with self.assertRaises(ValueError): SUPPORT.readback(root, output, output / SUPPORT.ISO_NAME)
        self.assertEqual(hashlib.sha256(OLD_IMAGE.read_bytes()).hexdigest(), OLD_SHA)

    def test_malformed_iso_metadata_is_bounded_before_payload_publication(self):
        actual = OLD_IMAGE.read_bytes()
        for body in (actual[:100], actual + b"x", bytes(len(actual)), actual[:16 * 2048] + b"\0" * 2048 + actual[17 * 2048:]):
            with self.subTest(bytes=len(body)), self.assertRaises(ValueError):
                SUPPORT.iso_members(body)

    def require_actual_built_image(self):
        directory = os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_PREPARED")
        expected_sha = os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_SHA256")
        expected_bytes = os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_BYTES")
        if not all((directory, expected_sha, expected_bytes)):
            self.skipTest("requires actual root-built positive carrier and independent pins; no synthetic ISO or emitter")
        output = Path(directory)
        result = SUPPORT.readback(ROOT, output, output / SUPPORT.ISO_NAME)
        data = (output / SUPPORT.ISO_NAME).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), expected_sha)
        self.assertEqual(len(data), int(expected_bytes))
        self.assertEqual((result["imageSHA256"], result["imageBytes"]), (expected_sha, len(data)))
        self.assertEqual(independent_joliet(output / SUPPORT.ISO_NAME), self.payload)
        self.assertEqual(SUPPORT.iso_members(data), self.payload, "unmodified control must pass deep metadata validation")
        self.assertFalse(result["catalogAdmitted"] or result["guestAction"])
        logical_end = struct.unpack_from("<I", data, 16 * 2048 + 80)[0] * 2048
        self.assertFalse(any(data[logical_end:]), "known hdiutil zero physical padding remains accepted")
        return output / SUPPORT.ISO_NAME, data

    def test_actual_positive_iso_rejects_path_table_omissions_and_tree_disagreements(self):
        image, actual = self.require_actual_built_image()
        for namespace in metadata_locations(actual):
            descriptor = namespace["descriptor"]
            mutations = []

            def changed(label, offset, replacement):
                body = bytearray(actual)
                body[offset:offset + len(replacement)] = replacement
                mutations.append((label, body))

            changed("size-mirror", descriptor + 132, struct.pack("<I", 1))
            body = bytearray(actual); body[descriptor + 132:descriptor + 140] = bytes(8)
            mutations.append(("missing-required-tables", body))
            for optional in (144, 152):
                changed("unsupported-optional-" + str(optional), descriptor + optional, struct.pack("<I" if optional == 144 else ">I", 19))
            for table in namespace["tables"]:
                field, order, rows = table["field"], table["order"], table["rows"]
                self.assertEqual(len(rows), 5, "actual bounded tree includes root and four known directories")
                for value in (0, len(actual) // 2048):
                    changed("location-" + str(field) + "-" + str(value), field, struct.pack(order + "I", value))
                for row in rows[:2]:
                    block = struct.unpack_from(order + "I", actual, row + 2)[0]
                    changed("extent-" + str(row), row + 2, struct.pack(order + "I", block + 1))
                changed("root-parent-" + str(field), rows[0] + 6, struct.pack(order + "H", 2))
                changed("missing-parent-" + str(field), rows[1] + 6, bytes(2))
                changed("wrong-parent-" + str(field), rows[2] + 6, struct.pack(order + "H", 1))
                changed("extended-attributes-" + str(field), rows[1] + 1, b"\1")
                changed("empty-name-" + str(field), rows[1], b"\0")
                name_offset = rows[1] + 8 + (1 if namespace["kind"] == 2 else 0)
                changed("name-tree-drift-" + str(field), name_offset, bytes([actual[name_offset] ^ 1]))
                changed("root-entry-padding-" + str(field), rows[0] + 9, b"\1")
                changed("table-allocation-padding-" + str(field), table["stop"], b"\1")
            for label, body in mutations:
                with self.subTest(namespace=namespace["kind"], mutation=label):
                    with self.assertRaisesRegex(ValueError, "iso-(path-table|optional-path-table)"):
                        SUPPORT.iso_members(body)
        self.assertEqual(image.read_bytes(), actual, "mutations exist only in memory; original carrier is untouched")

    def test_actual_positive_iso_rejects_dot_and_parent_record_disagreements(self):
        image, actual = self.require_actual_built_image()
        for namespace in metadata_locations(actual):
            directories = namespace["directories"]
            self.assertEqual(len(directories), 5)
            for path, records in directories.items():
                for special, record in enumerate(records):
                    mutations = []

                    def changed(label, offset, replacement):
                        body = bytearray(actual)
                        body[offset:offset + len(replacement)] = replacement
                        mutations.append((label, body))

                    for flags in (0, 128): changed("flags-" + str(flags), record + 25, bytes([flags]))
                    changed("extent-mirror", record + 2, struct.pack("<I", struct.unpack_from("<I", actual, record + 2)[0] ^ 1))
                    # Both endian copies agree, but this record identifies the
                    # other directory rather than its actual self/parent.
                    wrong = next(pair[0] for key, pair in directories.items()
                                 if struct.unpack_from("<I", actual, pair[0] + 2)[0]
                                 != struct.unpack_from("<I", actual, record + 2)[0])
                    block = struct.unpack_from("<I", actual, wrong + 2)[0]
                    changed("wrong-self-or-parent", record + 2, struct.pack("<I", block) + struct.pack(">I", block))
                    changed("length-mirror", record + 10, struct.pack("<I", 1))
                    changed("wrong-length", record + 10, struct.pack("<I", 1) + struct.pack(">I", 1))
                    changed("volume-sequence", record + 28, b"\2")
                    changed("extended-attributes", record + 1, b"\1")
                    changed("missing-or-reordered-dot", record + 33, bytes([1 - special]))
                    for label, body in mutations:
                        with self.subTest(namespace=namespace["kind"], directory=path, special=special, mutation=label):
                            with self.assertRaisesRegex(ValueError, "iso-(indirect-record|extent|dot-identity)"):
                                SUPPORT.iso_members(body)
        self.assertEqual(image.read_bytes(), actual)

    def test_root_built_actual_iso_roundtrip_matches_every_current_source_member(self):
        directory = os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_PREPARED")
        expected_sha = os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_SHA256")
        expected_bytes = os.environ.get("MACOPENVM_WINDOWS_DRIVER_SUPPORT_BYTES")
        if not all((directory, expected_sha, expected_bytes)):
            self.skipTest("requires root-built/readback-audited new carrier and independent image pins; no image is built by this test")
        output = Path(directory)
        result = SUPPORT.readback(ROOT, output, output / SUPPORT.ISO_NAME)
        independent = independent_joliet(output / SUPPORT.ISO_NAME)
        self.assertEqual(independent, self.payload)
        self.assertEqual(result["imageSHA256"], expected_sha)
        self.assertEqual(result["imageBytes"], int(expected_bytes))
        self.assertFalse(result["catalogAdmitted"] or result["guestAction"])
        self.assertEqual(independent[HELPER], self.payload[HELPER])
        self.assertEqual(independent["macOpenVM Setup.cmd"], (ROOT / "packaging/windows-driver-evaluation-setup.cmd").read_bytes())


if __name__ == "__main__":
    unittest.main()
