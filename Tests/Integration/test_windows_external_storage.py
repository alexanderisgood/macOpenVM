# SPDX-License-Identifier: Apache-2.0
"""Real private filesystem/FD relocation tests; no VM/terminal/guest-health proof."""
import errno
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

from windows_external_storage_lab import exclusive_rename, identity, inventory, relocate_stopped

VM_ID = "11111111-1111-4111-8111-111111111111"
SESSION_ID = "22222222-2222-4222-8222-222222222222"


class WindowsExternalStorageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mvo-relocation-fs-", dir="/private/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.root.chmod(0o700)
        self.source_parent = self.root / "source-parent"
        self.destination_parent = self.root / "destination-parent"
        for path in (self.source_parent, self.destination_parent): path.mkdir(mode=0o700)
        self.source = self.source_parent / "synthetic-stopped-vm"
        self.destination = self.destination_parent / "relocated-vm"
        self.source.mkdir(mode=0o700)
        for name, data in (("writer.lock", b""), ("disk.raw", b"Opaque private disk file fixture, not an OS image.\n"),
                           ("uefi-vars.json", b"Opaque mutable variable-file fixture.\n")):
            self.write(self.source / name, data)
        state = self.source / "tpm-state"
        state.mkdir(mode=0o700)
        self.write(state / "opaque-state", b"File preservation only; never a TPM object or guest key.\n")
        # These synthetic records exercise file-only correlation admission. Real
        # terminal provenance is an independent requirement of the actual parent.
        self.intent = {"schemaVersion": 1, "vmID": VM_ID, "sessionID": SESSION_ID, "state": "settled"}
        self.history = {"schemaVersion": 1, "sessionID": SESSION_ID, "sequence": 4, "recordedAt": 1,
                        "snapshot": {"state": "stopped", "outcome": "guestStopped", "backendActive": False}}
        self.json(self.source / "runtime-intent.json", self.intent)
        self.json(self.source / "runtime.json", self.history)
        self.json(self.source / "historical-proof.json", {"source": str(self.source), "scope": "synthetic-old-proof"})

    def write(self, path, data):
        path.write_bytes(data)
        path.chmod(0o600)

    def json(self, path, value): self.write(path, (json.dumps(value) + "\n").encode())

    def snapshot(self, directory):
        return {"inodes": inventory(directory),
                "bytes": {str(path.relative_to(directory)): path.read_bytes()
                          for path in directory.rglob("*") if path.is_file()}}

    def relocate(self, **kwargs):
        return relocate_stopped(self.source, self.destination, VM_ID, SESSION_ID, **kwargs)

    def assert_source_preserved(self, before):
        self.assertTrue(self.source.is_dir())
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.snapshot(self.source), before)

    def test_actual_exclusive_rename_preserves_all_inodes_bytes_and_old_proof_paths(self):
        before = self.snapshot(self.source)
        checks = []
        def observed_rename(*arguments):
            probe = ("import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDWR); "
                     "\ntry: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)"
                     "\nexcept BlockingIOError: sys.exit(7)"
                     "\nsys.exit(0)")
            result = subprocess.run([sys.executable, "-c", probe, str(self.source / "writer.lock")],
                                    capture_output=True, timeout=5, check=False)
            checks.append(result.returncode)
            exclusive_rename(*arguments)
        result = self.relocate(rename=observed_rename)
        self.assertEqual(checks, [7])
        self.assertFalse(self.source.exists())
        self.assertEqual(self.snapshot(self.destination), before)
        self.assertTrue(result["exclusiveWriterObserved"] and result["directoryFlushesCompleted"])
        self.assertFalse(result["copyPerformed"] or result["launchPerformed"] or result["credentialsEntered"])
        old_proof = json.loads((self.destination / "historical-proof.json").read_bytes())
        self.assertEqual(old_proof["source"], str(self.source))
        descriptor = os.open(self.destination / "writer.lock", os.O_RDWR | os.O_NOFOLLOW)
        try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally: os.close(descriptor)

    def test_actual_held_writer_refuses_without_namespace_changes(self):
        before = self.snapshot(self.source)
        descriptor = os.open(self.source / "writer.lock", os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError): self.relocate()
            self.assert_source_preserved(before)
        finally: os.close(descriptor)

    def test_symlink_parent_and_oversized_inventory_refuse_before_any_move(self):
        before = self.snapshot(self.source)
        alias = self.root / "source-parent-alias"
        alias.symlink_to(self.source_parent, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            relocate_stopped(alias / self.source.name, self.destination, VM_ID, SESSION_ID)
        self.assert_source_preserved(before)
        for number in range(513):
            self.write(self.source / f"bounded-entry-{number}", b"private size-bound fixture\n")
        names = sorted(path.name for path in self.source.iterdir())
        with self.assertRaises(ValueError): self.relocate()
        self.assertTrue(self.source.is_dir() and not self.destination.exists())
        self.assertEqual(sorted(path.name for path in self.source.iterdir()), names)

    def test_unsettled_wrong_vm_session_boolean_schema_and_opaque_outcomes_refuse(self):
        changes = (("intent", "state", "unsettled"), ("intent", "vmID", "11234567-89ab-cdef-0123-456789abcdef"),
                   ("intent", "sessionID", "33333333-3333-4333-8333-333333333333"),
                   ("intent", "schemaVersion", True), ("history", "sessionID", "33333333-3333-4333-8333-333333333333"),
                   ("snapshot", "outcome", "failed"), ("snapshot", "outcome", "forcedStopped"),
                   ("snapshot", "backendActive", True), ("snapshot", "backendActive", 0))
        for group, key, value in changes:
            with self.subTest(group=group, field=key, value=value):
                intent = dict(self.intent)
                history = {**self.history, "snapshot": dict(self.history["snapshot"])}
                if group == "intent": intent[key] = value
                elif group == "history": history[key] = value
                else: history["snapshot"][key] = value
                self.json(self.source / "runtime-intent.json", intent)
                self.json(self.source / "runtime.json", history)
                before = self.snapshot(self.source)
                with self.assertRaises(ValueError): self.relocate()
                self.assert_source_preserved(before)

    def test_existing_or_raced_destination_is_not_overwritten(self):
        self.destination.mkdir(mode=0o700)
        sentinel = self.destination / "must-remain"
        self.write(sentinel, b"Existing destination data.\n")
        before = self.snapshot(self.source); target_before = self.snapshot(self.destination)
        with self.assertRaises(ValueError): self.relocate()
        self.assertEqual(self.snapshot(self.source), before)
        self.assertEqual(self.snapshot(self.destination), target_before)
        shutil.rmtree(self.destination)
        def raced_rename(source_parent, source_name, destination_parent, destination_name):
            os.mkdir(destination_name, mode=0o700, dir_fd=destination_parent)
            self.write(self.destination / "must-remain", b"Raced destination data.\n")
            exclusive_rename(source_parent, source_name, destination_parent, destination_name)
        with self.assertRaises(OSError): self.relocate(rename=raced_rename)
        self.assertEqual(self.snapshot(self.source), before)
        self.assertEqual((self.destination / "must-remain").read_bytes(), b"Raced destination data.\n")

    def test_aliases_nonempty_writer_and_unsafe_permissions_refuse(self):
        for kind in ("hardlink", "symlink", "writer-data", "writer-mode", "directory-mode"):
            with self.subTest(kind=kind):
                disk = self.source / "disk.raw"
                saved = self.root / "saved-disk"
                self.write(saved, b"External preserved fixture.\n")
                if kind == "hardlink": os.link(disk, self.root / "disk-alias")
                elif kind == "symlink": disk.unlink(); disk.symlink_to(saved)
                elif kind == "writer-data": self.write(self.source / "writer.lock", b"not-empty")
                elif kind == "writer-mode": (self.source / "writer.lock").chmod(0o660)
                else: self.source.chmod(0o750)
                with self.assertRaises((ValueError, OSError)): self.relocate()
                self.assertTrue(self.source.is_dir() and not self.destination.exists())
                self.assertEqual(saved.read_bytes(), b"External preserved fixture.\n")
                if kind == "hardlink": (self.root / "disk-alias").unlink()
                elif kind == "symlink": disk.unlink(); self.write(disk, b"Restored file fixture.\n")
                elif kind == "writer-data": self.write(self.source / "writer.lock", b"")
                elif kind == "writer-mode": (self.source / "writer.lock").chmod(0o600)
                else: self.source.chmod(0o700)

    def test_source_writer_or_parent_replacement_after_preflush_never_calls_rename(self):
        for kind in ("source", "writer", "destination-parent"):
            with self.subTest(kind=kind):
                original = self.snapshot(self.source)
                renamed = []
                parked = self.root / ("parked-" + kind)
                flushed = []
                def swap_after_flush(descriptor):
                    os.fsync(descriptor)
                    flushed.append(descriptor)
                    if len(flushed) == 1:
                        if kind == "source":
                            self.source.rename(parked)
                            shutil.copytree(parked, self.source)
                        elif kind == "writer":
                            (self.source / "writer.lock").rename(parked)
                            self.write(self.source / "writer.lock", b"")
                        else:
                            self.destination_parent.rename(parked)
                            self.destination_parent.mkdir(mode=0o700)
                def forbidden_rename(*arguments):
                    renamed.append(arguments)
                    exclusive_rename(*arguments)
                with self.assertRaises((ValueError, OSError)):
                    self.relocate(rename=forbidden_rename, flush=swap_after_flush)
                self.assertEqual(renamed, [])
                self.assertFalse(self.destination.exists())
                if kind == "source":
                    self.assertEqual(self.snapshot(parked), original)
                    shutil.rmtree(self.source); parked.rename(self.source)
                elif kind == "writer":
                    self.assertEqual(parked.read_bytes(), b"")
                    (self.source / "writer.lock").unlink(); parked.rename(self.source / "writer.lock")
                else:
                    self.destination_parent.rmdir(); parked.rename(self.destination_parent)

    def test_rename_failure_before_and_after_real_move_keeps_evidence_without_rollback(self):
        before = self.snapshot(self.source)
        def before_move(*arguments): raise OSError(errno.EIO, "Injected before actual rename")
        with self.assertRaises(OSError): self.relocate(rename=before_move)
        self.assert_source_preserved(before)
        def after_move(*arguments):
            exclusive_rename(*arguments)
            raise OSError(errno.EIO, "Injected after actual rename")
        with self.assertRaises(OSError): self.relocate(rename=after_move)
        self.assertFalse(self.source.exists())
        self.assertEqual(self.snapshot(self.destination), before)

    def test_each_real_directory_flush_error_preserves_the_actual_location(self):
        for offset in range(1, 5):
            with self.subTest(flush=offset):
                before = self.snapshot(self.source)
                calls = []
                def failed_flush(descriptor):
                    calls.append(descriptor)
                    if len(calls) == offset: raise OSError(errno.EIO, "Injected directory flush failure")
                    os.fsync(descriptor)
                with self.assertRaises(OSError): self.relocate(flush=failed_flush)
                self.assertEqual(len(calls), offset)
                if offset == 1: self.assert_source_preserved(before)
                else:
                    self.assertFalse(self.source.exists())
                    self.assertEqual(self.snapshot(self.destination), before)
                    # Test teardown restores the fixture, never the production
                    # primitive. Its uncertain move intentionally has no rollback.
                    self.destination.rename(self.source)
