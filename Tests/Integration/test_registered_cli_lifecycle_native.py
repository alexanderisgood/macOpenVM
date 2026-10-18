# SPDX-License-Identifier: Apache-2.0
"""Private files and controlled process observations only; no child, guest or socket is started."""
import contextlib
import copy
import fcntl
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import registered_cli_lifecycle_native as native

def write(path, value):
    path.write_bytes(json.dumps(value).encode() if isinstance(value, dict) else value); path.chmod(0o600)

@contextlib.contextmanager
def fixture():
    with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
        directory = Path(temporary); directory.chmod(0o700)
        config = dict(id=native.VM_ID, guest='windows11', backend='qemuHVF', architecture='arm64', boot='efi',
                      network='disconnected', diskFile='disk.raw', diskBytes=64 * 2**30)
        write(directory / 'configuration.json', config); write(directory / 'qemu-platform.json', b'private original platform')
        write(directory / 'disk.raw', b'')
        with (directory / 'disk.raw').open('r+b') as disk: disk.truncate(64 * 2**30)
        write(directory / 'uefi-vars.json', b''); write(directory / 'writer.lock', b'')
        (directory / 'tpm-state').mkdir(mode=0o700)
        with patch.object(native, 'DIRECTORY', directory), patch.object(native, 'CONFIG_SHA', native.sha(directory / 'configuration.json')), \
                patch.object(native, 'PLATFORM_SHA', native.sha(directory / 'qemu-platform.json')):
            yield directory, config

def trace():
    def reply(state, ack):
        return dict(state=state, backendActive=True, operationPending=False, ownership=0, error=0, requestAcknowledged=ack)
    return [dict(action='pause', actualControlReaped=True, exit=0, reply=reply(4, True)),
            dict(action='status', actualControlReaped=True, exit=0, reply=reply(4, False)),
            dict(action='stop', actualControlReaped=True, exit=1, reply=None),
            dict(action='resume', actualControlReaped=True, exit=0, reply=reply(2, True)),
            dict(action='status', actualControlReaped=True, exit=0, reply=reply(2, False)),
            dict(action='force-denied', actualControlReaped=True, exit=1, reply=None),
            dict(action='force', actualControlReaped=True, exit=0, reply=reply(0, True))]

def producer(session):
    return dict(schemaVersion=1, scope='macopenvm-registered-qemu-runtime-result', vmID=native.VM_ID,
                sessionID=session, outcome='forcedStopped', qemuExit=0, tpmExit=0, qemuSignalled=False, tpmSignalled=False,
                drainsFinished=True, platformStateFlushed=True, resourcesRevalidated=True, runtimeIntentSettled=True)

class RegisteredCLILifecycleGuards(unittest.TestCase):
    def test_both_opt_ins_skip_before_any_inspection_mutation_or_spawn(self):
        with patch.object(native, 'verify_cli', side_effect=AssertionError('inspected')), \
                patch.object(native, 'fresh', side_effect=AssertionError('inspected')), \
                patch.object(native, 'launch', side_effect=AssertionError('spawned')):
            for arguments in ([], ['--run'], ['--disposable-no-os-force-authorized']):
                with self.subTest(arguments=arguments), contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(native.main(arguments), 0)
                self.assertIn('SKIP:', output.getvalue())

    def test_fresh_offline_no_os_state_and_actual_writer_required(self):
        with fixture() as (directory, config):
            native.fresh(directory)
            descriptor = os.open(directory / 'writer.lock', os.O_RDONLY)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(ValueError): native.fresh(directory)
            finally: os.close(descriptor)
            changed = dict(config, network='shared'); write(directory / 'configuration.json', changed)
            with self.assertRaisesRegex(ValueError, 'fresh-profile-drift'): native.fresh(directory)
            write(directory / 'configuration.json', config)
            write(directory / 'runtime-intent.json', b'previous attempt')
            with self.assertRaisesRegex(ValueError, 'prior-attempt-refused'): native.fresh(directory)

    def test_only_explicit_normal_cli_arguments_and_current_session(self):
        run = native.DIRECTORY / '.runtime' / ('run-' + 'a' * 32); session = '9C091ACA-E981-40CA-9803-731B3646C160'
        denied = native.control_arguments('force-denied', run, session)
        allowed = native.control_arguments('force', run, session)
        self.assertEqual(denied[1], 'force-stop'); self.assertNotIn('--confirm-data-loss', denied)
        self.assertEqual(allowed, denied + ['--confirm-data-loss', 'yes'])
        with self.assertRaises(ValueError): native.control_arguments('quit', run, session)
        with self.assertRaises(ValueError): native.control_arguments('force', Path('/foreign/run-' + 'a' * 32), session)
        with fixture() as (directory, _):
            write(directory / 'runtime-intent.json', dict(vmID=native.VM_ID, sessionID=session, state='unsettled'))
            with patch.object(native, 'Client', side_effect=AssertionError('connected')):
                with self.assertRaisesRegex(ValueError, 'session-changed'):
                    native.locate(Mock(poll=lambda: None), run, Path('/private/tmp/endpoint'), 'BAD-PRIOR-SESSION')

    def test_control_timeout_retains_the_actual_child_without_signal(self):
        child = Mock(); child.wait.side_effect = subprocess.TimeoutExpired('control', 30)
        child.terminate.side_effect = AssertionError('terminated'); child.kill.side_effect = AssertionError('killed')
        run = native.DIRECTORY / '.runtime' / ('run-' + 'a' * 32); session = '9C091ACA-E981-40CA-9803-731B3646C160'
        with patch.object(native, 'verify_cli'), patch.object(native, 'launch', return_value=child), \
                patch.object(native, 'retain_until_reaped') as retained:
            with self.assertRaises(subprocess.TimeoutExpired): native.control('status', run, session, Path('/private/tmp/evidence'))
        retained.assert_called_once_with(child); child.terminate.assert_not_called(); child.kill.assert_not_called()

    def test_ack_is_insufficient_without_explicit_paused_and_running_status(self):
        native.validate_trace(trace())
        missing = [row for row in trace() if row['action'] != 'status']
        with self.assertRaisesRegex(ValueError, 'explicit-status-observation-required'): native.validate_trace(missing)
        wrong = trace(); wrong[1]['reply']['state'] = 2
        with self.assertRaisesRegex(ValueError, 'explicit-status-observation-required'): native.validate_trace(wrong)
        wrong = trace(); wrong[2]['exit'] = 0
        with self.assertRaisesRegex(ValueError, 'cli-ack-or-refusal-unqualified'): native.validate_trace(wrong)

    def test_terminal_requires_full_forced_cohort_and_preserves_failed_scope(self):
        session = '9C091ACA-E981-40CA-9803-731B3646C160'
        with fixture() as (directory, _), patch.object(native, 'verify_cli'), patch.object(native, 'COMPILED', ()):
            run = directory / 'run'; run.mkdir(mode=0o700)
            write(directory / 'runtime-intent.json', dict(vmID=native.VM_ID, sessionID=session, state='settled'))
            write(directory / 'runtime.json', dict(sessionID=session, snapshot=dict(state='stopped', backendActive=False, outcome='forcedStopped')))
            original = producer(session); write(run / 'result.json', original)
            worker = Mock(poll=lambda: 0, wait=lambda: 0)
            result = native.terminal(worker, session, run, {}, trace())
            self.assertEqual(result['status'], 'passed'); self.assertFalse(result['normalGuestShutdownVerified'])
            self.assertFalse(result['guestFilesystemVerified']); self.assertFalse(result['windowsCompatibilityVerified'])
            for field, value in [('drainsFinished', False), ('qemuExit', True), ('tpmSignalled', True)]:
                bad = copy.deepcopy(original); bad[field] = value; write(run / 'result.json', bad)
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'forced-settlement-unqualified'):
                    native.terminal(worker, session, run, {}, trace())
            write(run / 'result.json', original)
            failed = native.failed_terminal(worker, session, run, ValueError('trace missing'))
            self.assertEqual(failed['status'], 'failed'); self.assertTrue(failed['actualWorkerReaped'])
            self.assertTrue(failed['producerResultQualified']); self.assertFalse(failed['normalGuestShutdownVerified'])

if __name__ == '__main__': unittest.main()
