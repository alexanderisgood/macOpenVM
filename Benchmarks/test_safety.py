# SPDX-License-Identifier: Apache-2.0
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

from safety import bounded_json, new_session, publish_result, sha256_file, verify_current_cli
from build_manifest import ENTITLEMENTS, RECIPE_FILES, source_snapshot


class BenchmarkPreservation(unittest.TestCase):
    def test_unique_sessions_preserve_old_evidence_and_reject_existing_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            historical = root / "Benchmarks/results/apple-vz-alpine-console-2026-10-06.json"
            historical.parent.mkdir(parents=True)
            historical.write_bytes(b"historical measurement sentinel")
            metadata = historical.stat()
            first, result = new_session(root)
            second, other = new_session(root)
            self.assertNotEqual(first, second)
            self.assertNotEqual(result, other)
            self.assertEqual(first.stat().st_mode & 0o777, 0o700)
            publish_result(result, {"sentinel": "first"})
            committed = result.read_bytes(), result.stat().st_mtime_ns
            with self.assertRaises(FileExistsError):
                publish_result(result, {"sentinel": "overwritten"})
            self.assertEqual((result.read_bytes(), result.stat().st_mtime_ns), committed)
            self.assertEqual(historical.read_bytes(), b"historical measurement sentinel")
            self.assertEqual(historical.stat().st_mtime_ns, metadata.st_mtime_ns)

    def test_result_symlink_does_not_modify_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "existing.json"; target.write_bytes(b"untouched")
            alias = root / "alias.json"; alias.symlink_to(target)
            with self.assertRaises(FileExistsError):
                publish_result(alias, {"changed": True})
            self.assertEqual(target.read_bytes(), b"untouched")
            self.assertTrue(alias.is_symlink())

    def test_provenance_fifo_and_oversized_json_fail_without_blocking(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fifo = root / "fifo.json"; os.mkfifo(fifo)
            before = time.monotonic()
            with self.assertRaises(ValueError):
                bounded_json(fifo)
            self.assertLess(time.monotonic() - before, 1)
            oversized = root / "oversized.json"; oversized.write_bytes(b" " * 262_145)
            with self.assertRaises(ValueError):
                bounded_json(oversized)
            invalid = root / "nan.json"; invalid.write_text('{"value": NaN}')
            with self.assertRaises(ValueError):
                bounded_json(invalid)


class BuildProvenance(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in RECIPE_FILES:
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("fixture-" + name).encode())
        source = self.root / "CLI/Main.swift"; source.parent.mkdir()
        source.write_bytes(b"original test source")
        self.cli = self.root / "build/bin/macopenvm"; self.cli.parent.mkdir(parents=True)
        self.cli.write_bytes(b"fixture binary; no guest execution")
        self.manifest = {"schemaVersion": 1, "configuration": "release", "signing": "adHoc",
                         "version": "test", "revision": None,
                         "toolchain": {"swift": "fixture", "sdk": "fixture", "hostArchitecture": "fixture"},
                         "sources": source_snapshot(self.root),
                         "artifacts": {"cli": {"sha256": sha256_file(self.cli), "bytes": self.cli.stat().st_size,
                                               "entitlements": dict(ENTITLEMENTS)}}}

    def test_recorded_profile_retained_and_runner_replacement_rejected(self):
        artifact = verify_current_cli(self.root, self.manifest)
        self.assertEqual(artifact["sha256"], sha256_file(self.cli))
        self.assertEqual(self.manifest["configuration"], "release")
        self.cli.write_bytes(b"replaced binary with a different build")
        with self.assertRaisesRegex(ValueError, "runner differs"):
            verify_current_cli(self.root, self.manifest)

    def test_source_and_recipe_edits_require_rebuild(self):
        for relative in ("CLI/Main.swift", "scripts/build.sh", "packaging/virtualization.entitlements"):
            path = self.root / relative; original = path.read_bytes()
            path.write_bytes(original + b" edited")
            with self.assertRaisesRegex(ValueError, "changed; rebuild"):
                verify_current_cli(self.root, self.manifest)
            path.write_bytes(original)
        self.assertEqual(verify_current_cli(self.root, self.manifest)["bytes"], self.cli.stat().st_size)

    def test_missing_future_and_malformed_records_cannot_prove_a_build(self):
        for alteration in ({"schemaVersion": 2}, {"configuration": None}, {"artifacts": []},
                           {"toolchain": {}}, {"signing": "unknown"}):
            manifest = dict(self.manifest); manifest.update(alteration)
            with self.assertRaises(ValueError):
                verify_current_cli(self.root, manifest)
        self.manifest["artifacts"]["cli"]["entitlements"] = {"unexpected": True}
        with self.assertRaisesRegex(ValueError, "signing profile"):
            verify_current_cli(self.root, self.manifest)


class RetainedChildRecovery(unittest.TestCase):
    def test_metadata_and_log_failure_retains_child_for_manual_input_and_reaps_it(self):
        # This is a real local pipe/process failure test with a synthetic console,
        # not a VM/guest proof. No backend or native entitlement is used.
        import subprocess
        from unittest.mock import patch
        import native_boot
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_source = root / "child.py"
            child_source.write_text("import select, sys\nprint('synthetic console', flush=True)\n"
                                    "ready=select.select([sys.stdin], [], [], 5)[0]\n"
                                    "raise SystemExit(0 if ready and sys.stdin.readline().strip()=='poweroff' else 7)\n")
            input_path = root / "input"; input_path.write_bytes(b"poweroff\n")
            original_popen = subprocess.Popen
            children = []
            def spawn(*args, **kwargs):
                import sys
                child = original_popen([sys.executable, str(child_source)], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
                children.append(child)
                return child
            original_write = native_boot.write_json
            def fail_ownership(path, value, **kwargs):
                if path.name == "ownership.json":
                    raise OSError("injected metadata-write failure")
                return original_write(path, value, **kwargs)
            original_open = Path.open
            class UnwritableLog:
                def write(self, chunk):
                    raise OSError("injected transcript-write failure")
                def flush(self):
                    pass
                def close(self):
                    pass
            def open_log(path, *args, **kwargs):
                if path.name == "trial-1.log":
                    return UnwritableLog()
                return original_open(path, *args, **kwargs)
            with input_path.open("rb") as manual_input, (root / "recovery-output").open("w") as console:
                with patch.object(native_boot, "verify_current_cli"), patch.object(native_boot.subprocess, "Popen", spawn), \
                     patch.object(native_boot, "write_json", fail_ownership), patch.object(Path, "open", open_log), \
                     patch.object(native_boot.sys, "stdin", manual_input), patch.object(native_boot.sys, "stdout", console):
                    with self.assertRaisesRegex(OSError, "metadata-write failure"):
                        native_boot.run_trial(root / "unused", root / "unusedVM", root, 1, root, {})
            self.assertEqual(len(children), 1)
            self.assertEqual(children[0].returncode, 0)
            self.assertTrue(children[0].stdin.closed)
            failure = json.loads((root / "failure-1.json").read_text())
            self.assertTrue(failure["active"])
            self.assertEqual(failure["phase"], "spawn")
            self.assertIn("Live guest retained", (root / "recovery-output").read_text())
