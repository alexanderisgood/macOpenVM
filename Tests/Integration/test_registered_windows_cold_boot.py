# SPDX-License-Identifier: Apache-2.0
"""Cold-mode guards: private files/leases and controlled receipts, never a VM."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import registered_windows_worker_native as native


def write(path, value):
    path.write_bytes(json.dumps(value, sort_keys=True).encode() if isinstance(value, dict) else value)
    path.chmod(0o600)


def fixture(root):
    c = dict(id=native.VM_ID, network='shared', macAddress='02:7d:5c:2c:d4:e2', diskFile='disk.raw',
             guest='windows11', backend='qemuHVF', architecture='arm64', boot='efi', diskBytes=64 * 2**30)
    write(root / 'configuration.json', c); write(root / 'qemu-platform.json', b'public platform bytes')
    write(root / 'uefi-vars.json', b'public EFI bytes'); write(root / 'writer.lock', b'')
    tpm = root / 'tpm-state'; tpm.mkdir(mode=0o700)
    write(tpm / '.lock', b''); write(tpm / 'tpm2-00.permall', b'public TPM bytes')
    disk = root / 'disk.raw'; write(disk, b'public installed sector')
    with disk.open('r+b') as stream: stream.truncate(64 * 2**30)
    write(root / 'runtime.json', dict(schemaVersion=1, sessionID=native.PRIOR_SESSION,
          snapshot=dict(state='stopped', outcome='guestStopped', backendActive=False)))
    write(root / 'runtime-intent.json', dict(schemaVersion=1, vmID=native.VM_ID,
          sessionID=native.PRIOR_SESSION, state='settled'))
    names = ['disk.raw', 'qemu-platform.json', 'uefi-vars.json', 'writer.lock', 'tpm-state/.lock', 'tpm-state/tpm2-00.permall']
    cold = dict(MAC=c['macAddress'], configurationSHA256=native.sha(root / 'configuration.json'),
                platformSHA256=native.sha(root / 'qemu-platform.json'),
                assets={name: native.installed_asset(root / name, disk=name == 'disk.raw') for name in names},
                priorRecords=[{}, {}, dict(path=str(root / 'runtime.json'), SHA256=native.sha(root / 'runtime.json')),
                              dict(path=str(root / 'runtime-intent.json'), SHA256=native.sha(root / 'runtime-intent.json'))])
    return cold


class InstalledColdBootGuards(unittest.TestCase):
    def test_explicit_cold_gate_precedes_any_file_or_process_admission(self):
        args = SimpleNamespace(installed_cold_boot_evaluation=True, stopped_baseline=native.COLD_BASELINE,
                               stopped_baseline_sha256=native.COLD_SHA, disposable_force_authorized=False)
        native.cold_mode_arguments(args)
        args.disposable_force_authorized = True
        with self.assertRaises(ValueError): native.cold_mode_arguments(args)
        with patch.object(native, 'admit', side_effect=AssertionError('input inspected')), \
                patch.object(native, 'read_cold_baseline', side_effect=AssertionError('baseline read')), \
                patch.object(native.subprocess, 'Popen', side_effect=AssertionError('spawned')):
            with self.assertRaisesRegex(ValueError, 'installed-mode-explicit-fixed-baseline-required'):
                native.main(['--run', '--shared-network-authorized', '--installed-cold-boot-evaluation'])
        with self.assertRaisesRegex(ValueError, 'fixed-cold-baseline-required'):
            native.read_cold_baseline(Path('/absent'), native.COLD_SHA)

    def test_prior_normal_receipts_refuse_failed_forced_or_boolean_exit(self):
        parent = dict(vmID=native.VM_ID, sessionID=native.PRIOR_SESSION, actualParentReaped=True,
                      workerExit=0, failedAdvisory=False, forced=False, producerResultQualified=True, outcome='guestStopped')
        producer = dict(vmID=native.VM_ID, sessionID=native.PRIOR_SESSION, schemaVersion=1,
                        scope='macopenvm-registered-qemu-runtime-result', qemuExit=0, tpmExit=0,
                        qemuSignalled=False, tpmSignalled=False, drainsFinished=True, resourcesRevalidated=True,
                        platformStateFlushed=True, runtimeIntentSettled=True, outcome='guestStopped')
        history = dict(sessionID=native.PRIOR_SESSION, snapshot=dict(state='stopped', backendActive=False, outcome='guestStopped'))
        intent = dict(vmID=native.VM_ID, sessionID=native.PRIOR_SESSION, state='settled')
        prior = [parent, producer, history, intent]; native.validate_prior_normal(prior)
        for index, key, value in [(0, 'forced', True), (0, 'workerExit', False), (0, 'failedAdvisory', True),
                                  (1, 'qemuSignalled', True), (1, 'drainsFinished', False), (1, 'qemuExit', False),
                                  (3, 'sessionID', 'foreign')]:
            changed = copy.deepcopy(prior); changed[index][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): native.validate_prior_normal(changed)

    def test_installed_asset_and_disc_drift_refuse_before_new_owner(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            root = Path(directory); root.chmod(0o700); cold = fixture(root)
            native.installed_state(root, cold)
            with self.assertRaises(ValueError): native.fresh_blank_state(root)
            write(root / 'tpm-state/tpm2-00.permall', b'changed TPM bytes')
            with self.assertRaisesRegex(ValueError, 'stopped-installed-asset-drift'):
                native.installed_state(root, cold)
            c = json.loads((root / 'configuration.json').read_bytes()); c['supportMedia'] = str(native.CARRIER)
            write(root / 'configuration.json', c)
            with self.assertRaisesRegex(ValueError, 'disc-free-installed-configuration-invalid'):
                native.installed_state(root, cold)

    def test_prior_settled_intent_waits_without_ipc_and_preowner_terminal_is_failed(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            root = Path(directory); root.chmod(0o700); cold = fixture(root)
            run = root / 'new-run'; run.mkdir(mode=0o700)
            worker = Mock(); worker.poll.return_value = None; worker.wait.return_value = 1
            before = (root / 'runtime.json').read_bytes(), (root / 'runtime-intent.json').read_bytes()
            with patch.object(native, 'Client', side_effect=AssertionError('old owner adopted')):
                with self.assertRaisesRegex(FileNotFoundError, 'new-owner-not-yet-published'):
                    native.current_route(worker, root, run, root / 'sockets', cold=cold)
            receipt = native.terminal(worker, root, run, None, cold=cold)
            self.assertTrue(receipt['failedAdvisory']); self.assertFalse(receipt['producerResultQualified'])
            self.assertFalse(receipt['runtimeIntentSettled']); self.assertIsNone(receipt['sessionID'])
            self.assertEqual(before, ((root / 'runtime.json').read_bytes(), (root / 'runtime-intent.json').read_bytes()))
            with self.assertRaisesRegex(ValueError, 'prior-session-is-not-new-owner'):
                native.terminal(worker, root, run, native.PRIOR_SESSION, cold=cold)


if __name__ == '__main__':
    unittest.main()
