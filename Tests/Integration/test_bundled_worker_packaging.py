#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Actual private filesystem fixtures with mocked signature checks; never build or launch code."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import build_manifest as packaging


class BundledWorkerPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mvo-worker-package-', dir='/private/tmp')
        self.root = Path(self.temporary.name)
        self.app = self.root / 'build/macOpenVM.app'
        self.worker = self.app / 'Contents/MacOS/macopenvm-worker'
        self.descriptor = self.app / 'Contents/Resources/macopenvm-worker.json'
        self.worker.parent.mkdir(parents=True, mode=0o700)
        self.descriptor.parent.mkdir(mode=0o700)
        self.worker.write_bytes(b'controlled packaging fixture, never executed')
        self.worker.chmod(0o500)
        self.identifier = 'local.macOpenVM.worker'

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self):
        return packaging.write_worker_descriptor(self.worker, self.descriptor, self.identifier)

    def replace_descriptor(self, value):
        self.descriptor.write_text(json.dumps(value))
        self.descriptor.chmod(0o600)

    def test_descriptor_binds_actual_helper_bytes_and_has_no_paths_or_controls(self):
        value = self.prepare()
        self.assertEqual(set(value), {'schemaVersion', 'scope', 'identifier', 'sha256', 'bytes'})
        self.assertEqual(value['scope'], 'macopenvm-bundled-worker')
        self.assertEqual(value['sha256'], hashlib.sha256(self.worker.read_bytes()).hexdigest())
        self.assertEqual(value['bytes'], self.worker.stat().st_size)
        self.assertEqual(packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier), value)
        self.assertEqual(self.worker.stat().st_mode & 0o7777, 0o500)
        self.assertEqual(self.descriptor.stat().st_mode & 0o7777, 0o600)

    def test_helper_symlink_hardlink_mode_and_bytes_replacement_refuse(self):
        value = self.prepare()
        self.worker.chmod(0o700)
        with self.assertRaises(ValueError):
            packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)
        self.worker.chmod(0o500)
        alias = self.worker.with_name('alias')
        os.link(self.worker, alias)
        with self.assertRaises(ValueError):
            packaging.worker_artifact(self.worker)
        alias.unlink()
        self.worker.rename(alias)
        self.worker.symlink_to(alias)
        with self.assertRaises(OSError):
            packaging.worker_artifact(self.worker)
        self.worker.unlink()
        alias.rename(self.worker)
        self.worker.chmod(0o700)
        self.worker.write_bytes(b'a distinct controlled helper fixture')
        self.worker.chmod(0o500)
        with self.assertRaises(ValueError):
            packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)
        self.assertEqual(json.loads(self.descriptor.read_bytes()), value)

    def test_descriptor_unknown_fields_wrong_identity_hash_types_or_duplicate_refuse(self):
        value = self.prepare()
        for mutation in ({'argv': ['unapproved']}, {'scope': 'different'}, {'identifier': 'other.worker'},
                         {'sha256': '0' * 64}, {'bytes': value['bytes'] + 1}, {'schemaVersion': True}):
            with self.subTest(mutation=mutation):
                self.replace_descriptor({**value, **mutation})
                with self.assertRaises(ValueError):
                    packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)
        self.descriptor.write_text('{"schemaVersion":1,' + json.dumps(value)[1:])
        with self.assertRaises(ValueError):
            packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)

    def test_descriptor_symlink_hardlink_permissions_and_size_refuse(self):
        self.prepare()
        self.descriptor.chmod(0o644)
        with self.assertRaises(ValueError):
            packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)
        self.descriptor.chmod(0o600)
        alias = self.descriptor.with_name('alias.json')
        os.link(self.descriptor, alias)
        with self.assertRaises(ValueError):
            packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)
        alias.unlink()
        self.descriptor.rename(alias)
        self.descriptor.symlink_to(alias)
        with self.assertRaises(OSError):
            packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)
        self.descriptor.unlink()
        alias.rename(self.descriptor)
        self.descriptor.write_bytes(b' ' * 1025)
        with self.assertRaises(ValueError):
            packaging.verify_worker_descriptor(self.worker, self.descriptor, self.identifier)

    def test_actual_bundled_row_and_outer_signature_are_checked(self):
        descriptor = self.prepare()
        artifact = {'sha256': descriptor['sha256'], 'bytes': descriptor['bytes'],
                    'identifier': self.identifier, 'entitlements': packaging.ENTITLEMENTS}
        with patch.object(packaging.subprocess, 'run') as strict, \
                patch.object(packaging, 'actual_worker_entitlements', return_value=packaging.ENTITLEMENTS):
            self.assertEqual(packaging.verify_bundled_worker(self.root, {'artifacts': {'appWorker': artifact}}), artifact)
            strict.assert_called_once()
            self.assertEqual(strict.call_args.args[0], ['/usr/bin/codesign', '--verify', '--strict', str(self.app)])
            for bad in ({}, {**artifact, 'sha256': '0' * 64}, {**artifact, 'identifier': 'other.worker'}):
                with self.assertRaises(ValueError):
                    packaging.verify_bundled_worker(self.root, {'artifacts': {'appWorker': bad}})

    def test_signature_failure_and_exact_code_identifier_requirement_are_not_ignored(self):
        with patch.object(packaging, 'actual_entitlements', return_value=packaging.ENTITLEMENTS), \
                patch.object(packaging.subprocess, 'run') as strict:
            self.assertEqual(packaging.actual_worker_entitlements(self.worker, self.identifier), packaging.ENTITLEMENTS)
            self.assertEqual(strict.call_args.args[0], ['/usr/bin/codesign', '--verify', '--strict', '-R',
                                                      '=identifier "local.macOpenVM.worker"', str(self.worker)])
        with patch.object(packaging, 'actual_entitlements', side_effect=ValueError('controlled rejection')):
            with self.assertRaises(ValueError):
                packaging.actual_worker_entitlements(self.worker, self.identifier)
        with self.assertRaises(ValueError):
            packaging.worker_descriptor(self.worker, 'identifier "unsafe"')

    def test_parent_symlink_is_refused_before_helper_read_or_descriptor_write(self):
        self.prepare()
        original = self.descriptor.read_bytes()
        parent = self.descriptor.parent
        retained = parent.with_name('RetainedResources')
        parent.rename(retained)
        parent.symlink_to(retained, target_is_directory=True)
        with self.assertRaises(ValueError):
            packaging.write_worker_descriptor(self.worker, self.descriptor, self.identifier)
        self.assertEqual((retained / self.descriptor.name).read_bytes(), original)
        binary_parent = self.worker.parent
        binary_retained = binary_parent.with_name('RetainedMacOS')
        binary_parent.rename(binary_retained)
        binary_parent.symlink_to(binary_retained, target_is_directory=True)
        with self.assertRaises(ValueError):
            packaging.worker_artifact(self.worker)


if __name__ == '__main__':
    unittest.main()
