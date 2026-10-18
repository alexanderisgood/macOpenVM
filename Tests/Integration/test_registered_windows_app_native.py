# SPDX-License-Identifier: Apache-2.0
"""Pure parent control guards; no app, worker, socket, GUI or VM is started."""
import contextlib
import copy
import io
import json
import tempfile
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch
import registered_windows_app_native as native


def status():
    return dict(requestID=1, nonce='A047BB05-21BD-4A08-A109-6B7CD7563B03', vmID=native.VM_ID,
                sessionID='A2998A58-6D0D-4A32-B94D-A935EC5029D3',
                launchGeneration='D3D91EE9-AB9F-434A-8A31-3F7F12909412', replyCode='ok',
                state='running', busy=True, backendActive=True, displayReady=True,
                frameEpochPresent=True, settled=False, qualificationFailed=False)


def retry_prior():
    producer = dict(schemaVersion=1, scope='macopenvm-registered-qemu-runtime-result', vmID=native.VM_ID,
                    sessionID=native.PRIOR_SESSION, qemuExit=0, tpmExit=0, qemuSignalled=False, tpmSignalled=False,
                    drainsFinished=True, platformStateFlushed=True, resourcesRevalidated=True,
                    runtimeIntentSettled=True, outcome='guestStopped')
    history = dict(sessionID=native.PRIOR_SESSION, snapshot=dict(outcome='guestStopped', state='stopped', backendActive=False))
    intent = dict(vmID=native.VM_ID, sessionID=native.PRIOR_SESSION, state='settled')
    witness = dict(VMID=native.VM_ID, sessionID=native.PRIOR_SESSION, scope='actual-normal-shutdown-after-app-startup-race',
                   appWorkflowPassed=False, requestReplyRetained=False, independentWriterAvailable=True,
                   configurationSHA256='c' * 64, platformSHA256='d' * 64,
                   workerResult=copy.deepcopy(producer), history=copy.deepcopy(history), runtimeIntent=copy.deepcopy(intent))
    baseline = dict(configurationSHA256='c' * 64, platformSHA256='d' * 64, priorAppAttempt=dict(
        actualAppParentReaped=True, appExit=None, appExitStatusRetained=False, appWorkflowPassed=False, enclosingHarnessExit=1,
        failedEvidencePath=str(native.ROOT / '.lab/windows-installed-app-startup-race-87bdd75a6ed0459f874f595cac3d2d5b/result.json'),
        failedEvidenceSHA256='4db32e12bf697cc2f7b92d73f61dbe58e3accfdb12b36bee2547e71a263c7c8f',
        finalControl=dict(vmID=native.VM_ID, launchGeneration='AD97D5D0-4EA8-4914-93A3-F4381A6728F9',
                          settled=True, backendActive=False, busy=False, qualificationFailed=True, outcome='guestStopped')))
    return baseline, [witness, producer, history, intent]


class RegisteredAppNativeGuards(unittest.TestCase):
    def test_retry_accepts_real_normal_worker_cohort_while_app_remains_failed(self):
        baseline, prior = retry_prior()
        native.validate_retry_prior(baseline, prior)
        for member, field, value in [(1, 'drainsFinished', False), (1, 'outcome', 'forcedStopped'),
                                     (3, 'state', 'unsettled'), (0, 'sessionID', native.ZERO)]:
            records = copy.deepcopy(prior); records[member][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'installed-prior-normal-stop-invalid'):
                native.validate_retry_prior(baseline, records)

    def test_retry_refuses_fabricated_app_exit_or_passed_attempt(self):
        baseline, prior = retry_prior()
        for field, value in [('appExit', 0), ('appExitStatusRetained', True), ('appWorkflowPassed', True),
                             ('actualAppParentReaped', False), ('enclosingHarnessExit', 0)]:
            changed = copy.deepcopy(baseline); changed['priorAppAttempt'][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'prior-app-failure-must-remain-failed'):
                native.validate_retry_prior(changed, prior)

    def test_skip_before_any_admission_or_process(self):
        with patch.object(native, 'admit', side_effect=AssertionError()), \
                patch.object(native.subprocess, 'Popen', side_effect=AssertionError()), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(native.main([]), 0)
        self.assertIn('SKIP:', output.getvalue())

    def test_strict_response_types_correlation_and_duplicate_fields(self):
        value = status()
        self.assertEqual(native.decode_response(json.dumps(value).encode(), 1), value)
        for key, item in [('requestID', True), ('vmID', value['sessionID']), ('busy', 1),
                          ('nonce', 'not-a-uuid'), ('qualificationFailed', 1), ('state', 'invented'), ('extraPath', '/private/secret')]:
            bad = dict(value); bad[key] = item
            with self.subTest(key=key), self.assertRaises(ValueError):
                native.decode_response(json.dumps(bad).encode(), 1)
        duplicate = json.dumps(value)[:-1] + ',"requestID":1}'
        with self.assertRaisesRegex(ValueError, 'duplicate-response'):
            native.decode_response(duplicate.encode(), 1)
        with self.assertRaisesRegex(ValueError, 'response-bound'):
            native.decode_response(b'x' * 2049, 1)

    def test_mutations_require_same_memory_owner_and_actual_settlement(self):
        known = status(); native.mutation_gate('stop', known, dict(known))
        with self.assertRaisesRegex(ValueError, 'installed-normal-stop-or-quit-only'):
            native.mutation_gate('force-stop', known, known)
        with self.assertRaisesRegex(ValueError, 'prior-session-not-this-app-owner'):
            native.decode_response(json.dumps(dict(known, sessionID=native.PRIOR_SESSION)).encode(), 1)
        for field in ('nonce', 'sessionID', 'launchGeneration'):
            changed = dict(known); changed[field] = native.ZERO
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'current-memory-owner-required'):
                native.mutation_gate('stop', known, changed)
        with self.assertRaisesRegex(ValueError, 'quit-before-settlement-refused'):
            native.mutation_gate('quit', known, known)
        settled = dict(known, state='stopped', busy=False, backendActive=False, settled=True)
        native.mutation_gate('quit', known, settled)
        with self.assertRaisesRegex(ValueError, 'normal-owner-not-active'):
            native.mutation_gate('stop', known, settled)
        idle = dict(settled, sessionID=None, launchGeneration=None, settled=False)
        native.mutation_gate('quit', idle, dict(idle))
        with self.assertRaisesRegex(ValueError, 'quit-before-settlement-refused'):
            native.mutation_gate('quit', dict(idle, settled=True), dict(idle, settled=True))
        with self.assertRaisesRegex(ValueError, 'quit-before-settlement-refused'):
            native.mutation_gate('quit', dict(idle, busy=True), dict(idle, busy=True))
        with self.assertRaisesRegex(ValueError, 'normal-owner-not-active'):
            native.mutation_gate('stop', idle, idle)
        not_drawn = dict(known, displayReady=False, frameEpochPresent=False)
        native.mutation_gate('stop', known, not_drawn)
        native.mutation_gate('stop', known, dict(not_drawn, qualificationFailed=True))
        native.mutation_gate('quit', known, dict(settled, qualificationFailed=True))

    def test_installed_run_gate_and_fixed_baseline_precede_io(self):
        with patch.object(native, 'admit', side_effect=AssertionError('read app')), \
                patch.object(native, 'read_installed_baseline', side_effect=AssertionError('read baseline')), \
                patch.object(native.subprocess, 'Popen', side_effect=AssertionError('spawned')):
            with self.assertRaisesRegex(ValueError, 'explicit-installed-app-baseline-required'):
                native.main(['--run', '--installed-app-network-evaluation'])
        with self.assertRaisesRegex(ValueError, 'fixed-installed-app-baseline-required'):
            native.read_installed_baseline(Path('/absent'), native.INSTALLED_BASELINE_SHA)

    def test_installed_noop_stopped_assets_backups_and_disc_drift(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary); root.chmod(0o700)
            def put(path, value):
                path.write_bytes(json.dumps(value).encode() if isinstance(value, dict) else value); path.chmod(0o600)
            c = dict(id=native.VM_ID, network='shared', macAddress='02:7d:5c:2c:d4:e2')
            put(root / 'configuration.json', c); put(root / 'qemu-platform.json', b'original platform')
            put(root / 'writer.lock', b''); put(root / 'uefi-vars.json', b'original EFI')
            (root / 'tpm-state').mkdir(mode=0o700)
            put(root / 'tpm-state/.lock', b''); put(root / 'tpm-state/tpm2-00.permall', b'original TPM')
            put(root / 'disk.raw', b'installed sector')
            with (root / 'disk.raw').open('r+b') as stream: stream.truncate(64 * 2**30)
            put(root / 'runtime.json', b'prior history'); put(root / 'runtime-intent.json', b'prior intent')
            names = ['disk.raw', 'qemu-platform.json', 'uefi-vars.json', 'writer.lock', 'tpm-state/.lock', 'tpm-state/tpm2-00.permall']
            baseline = dict(MAC=c['macAddress'], configurationSHA256=native.sha(root / 'configuration.json'),
                platformSHA256=native.sha(root / 'qemu-platform.json'), networkBackupNames=[],
                assets={name: native.installed_asset(root / name, disk=name == 'disk.raw') for name in names},
                priorRecords=[{}, {}, dict(path=str(root / 'runtime.json'), SHA256=native.sha(root / 'runtime.json')),
                              dict(path=str(root / 'runtime-intent.json'), SHA256=native.sha(root / 'runtime-intent.json'))])
            native.installed_admission(root, baseline)
            put(root / 'configuration-network-backup-extra.json', b'extra')
            with self.assertRaisesRegex(ValueError, 'network-noop-created-backup'): native.installed_admission(root, baseline)
            (root / 'configuration-network-backup-extra.json').unlink()
            put(root / 'uefi-vars.json', b'changed EFI')
            with self.assertRaisesRegex(ValueError, 'installed-stopped-asset-drift'): native.installed_admission(root, baseline)
            c['installationMedia'] = '/unexpected.iso'; put(root / 'configuration.json', c)
            with self.assertRaisesRegex(ValueError, 'installed-configuration-drift'): native.installed_admission(root, baseline)

    def test_installed_sdk_stages_need_actual_current_paint_and_normal_stop(self):
        current = status()
        stages = ['installed-baseline-under-exclusive-writer', 'ordinary-network-settings-permission-ready',
                  'ordinary-shared-network-noop-saved', 'ordinary-worker-running', 'native-view-attached', 'native-view-drawn',
                  'actual-parent-and-producer-settled', 'explicit-root-normal-stop-request', 'explicit-root-quit-request']
        rows = [dict(stage=stage, vmID=native.VM_ID, failed=False, attached=True, drawn=True,
                     sessionID=current['sessionID'], launchGeneration=current['launchGeneration'],
                     frameEpoch=current['launchGeneration'], sequence=1) for stage in stages]
        encode = lambda value: b''.join(json.dumps(row).encode() + b'\n' for row in value)
        native.sdk_admission(encode(rows), current['sessionID'], current['launchGeneration'])
        with self.assertRaisesRegex(ValueError, 'installed-sdk-stages-incomplete'):
            native.sdk_admission(encode(rows[1:]), current['sessionID'], current['launchGeneration'])
        rows[0]['failed'] = True
        with self.assertRaisesRegex(ValueError, 'sdk-failed-or-ambiguous'):
            native.sdk_admission(encode(rows), current['sessionID'], current['launchGeneration'])
        rows[0]['failed'] = False
        with self.assertRaisesRegex(ValueError, 'current-sdk-paint-unqualified'):
            native.sdk_admission(encode(rows), native.PRIOR_SESSION, current['launchGeneration'])

    def test_evidence_never_persists_the_memory_challenge(self):
        value = status(); visible = native.public_reply(value)
        self.assertNotIn('nonce', visible)
        self.assertIn('nonce', value)
        self.assertEqual(visible['sessionID'], value['sessionID'])
        self.assertNotIn(value['nonce'], json.dumps(visible))
        self.assertFalse(native.latch_failure(False, value))
        late = dict(value, qualificationFailed=True)
        self.assertTrue(native.latch_failure(False, late))
        self.assertTrue(native.latch_failure(True, value))


if __name__ == '__main__':
    unittest.main()
