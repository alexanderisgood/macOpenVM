# SPDX-License-Identifier: Apache-2.0
"""Private files/socket nodes and mocked peers only; never --run, connect or a VM."""
import contextlib
import fcntl
import io
import json
import hashlib
import os
from pathlib import Path
import struct
import stat
import socket
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

import registered_windows_worker_native as native


class Stream:
    def __init__(self, data):
        self.data = data
        self.sent = []

    def settimeout(self, value):
        assert value > 0

    def recv(self, size):
        # Fragmented reads exercise the real bounded reader.
        result, self.data = self.data[:min(size, 3)], self.data[min(size, 3):]
        return result

    def sendall(self, data):
        self.sent.append(data)


def frame_bytes(width=2, encoding=0):
    header = struct.pack('>HH', width, 1) + bytes(16) + struct.pack('>I', 4)
    return (b'RFB 003.008\n\x01\x01' + bytes(4) + header + b'name'
            + b'\x00\x00\x00\x01' + struct.pack('>HHHHi', 0, 0, width, 1, encoding)
            + b'\x03\x02\x01\x00\x06\x05\x04\x00')


def private_write(path, data):
    path.write_bytes(data)
    path.chmod(0o600)


class RegisteredWindowsNativeGuards(unittest.TestCase):
    def test_no_run_skips_before_inputs_or_mutation(self):
        with patch.object(native, 'admit', side_effect=AssertionError('input inspected')), \
                patch.object(native.subprocess, 'Popen', side_effect=AssertionError('child launched')), \
                patch.object(Path, 'mkdir', side_effect=AssertionError('file mutation')), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(native.main(['--cli', '/absent', '--directory', '/absent']), 0)
        self.assertIn('SKIP:', output.getvalue())

    def test_run_without_new_shared_authorization_skips_before_any_io(self):
        with patch.object(native, 'admit', side_effect=AssertionError('input inspected')), \
                patch.object(native.subprocess, 'Popen', side_effect=AssertionError('child launched')), \
                patch.object(Path, 'mkdir', side_effect=AssertionError('file mutation')), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(native.main(['--run', '--cli', '/absent', '--directory', '/absent',
                                          '--disposable-force-authorized']), 0)
        self.assertIn('--shared-network-authorized required', output.getvalue())

    def test_private_records_reject_real_links_modes_bounds_and_duplicates(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            parent = Path(temporary); parent.chmod(0o700)
            path = parent / 'record.json'; private_write(path, b'{"a":1}')
            self.assertEqual(native.read_record(path), {'a': 1})
            private_write(path, b'{"a":1,"a":2}')
            with self.assertRaisesRegex(ValueError, 'duplicate-record-field'): native.read_record(path)
            private_write(path, b'{"a":1}'); path.chmod(0o644)
            with self.assertRaisesRegex(ValueError, 'private-file-invalid'): native.read_record(path)
            path.chmod(0o600)
            with self.assertRaisesRegex(ValueError, 'private-file-invalid'): native.read_record(path, 2)
            os.link(path, parent / 'hard-link')
            with self.assertRaisesRegex(ValueError, 'private-file-invalid'): native.read_record(path)
            (parent / 'hard-link').unlink()
            (parent / 'indirect').symlink_to(parent, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'path-indirect'): native.read_record(parent / 'indirect/record.json')
            alias = parent / 'alias'; alias.symlink_to(path)
            with self.assertRaisesRegex(ValueError, 'path-indirect'): native.read_record(alias)

    def test_exact_carrier_path_and_owned_readonly_bytes_are_required(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary); root.chmod(0o700)
            image = root / 'public-driver-data.iso'; data = b'P' * 921600
            private_write(image, data); image.chmod(0o400)
            digest = hashlib.sha256(data).hexdigest()
            native.verify_carrier(image, digest)
            image.chmod(0o600)
            with self.assertRaisesRegex(ValueError, 'carrier-file-invalid'): native.verify_carrier(image, digest)
            private_write(image, b'Q' + data[1:]); image.chmod(0o400)
            with self.assertRaisesRegex(ValueError, 'carrier-bytes-changed'): native.verify_carrier(image, digest)
            configuration = dict(id=native.VM_ID, guest='windows11', backend='qemuHVF', architecture='arm64',
                                 boot='efi', network='shared', diskBytes=64 * 2**30, supportMedia=str(image))
            private_write(root / 'configuration.json', json.dumps(configuration).encode())
            with self.assertRaisesRegex(ValueError, 'registration-invalid'):
                native.fresh_blank_state(root)
            configuration['supportMedia'] = str(native.CARRIER); configuration['network'] = 'disconnected'
            private_write(root / 'configuration.json', json.dumps(configuration).encode())
            with self.assertRaisesRegex(ValueError, 'registration-invalid'):
                native.fresh_blank_state(root)

    def test_fragmented_raw_frame_has_no_input_and_rejects_unbounded_or_unknown(self):
        stream = Stream(frame_bytes())
        width, height, ppm = native.raw_frame(stream, time.monotonic() + 10)
        self.assertEqual((width, height), (2, 1))
        self.assertEqual(ppm, b'P6\n2 1\n255\n\x01\x02\x03\x04\x05\x06')
        self.assertEqual([len(item) for item in stream.sent], [12, 1, 1, 20, 8, 10])
        self.assertEqual(stream.sent[3][0], 0)  # Pixel format only.
        self.assertEqual(stream.sent[4], b'\x02\x00\x00\x01' + bytes(4))
        self.assertEqual(stream.sent[5], struct.pack('>BBHHHH', 3, 0, 0, 0, 2, 1))
        for data, code in ((frame_bytes().replace(b'003.008', b'003.003'), 'rfb-version'),
                           (frame_bytes(width=8193), 'rfb-dimensions'),
                           (frame_bytes(encoding=5), 'rfb-raw-full-frame-required'),
                           (frame_bytes()[:-1], 'rfb-eof')):
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, code):
                native.raw_frame(Stream(data), time.monotonic() + 10)
        with self.assertRaisesRegex(ValueError, 'rfb-deadline'):
            native.raw_frame(Stream(frame_bytes()), time.monotonic() - 1)
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            run = Path(temporary); run.chmod(0o700)
            endpoints = run / 'endpoints'; endpoints.mkdir(mode=0o700)
            node = endpoints / 'vnc.sock'
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as bound:
                bound.bind(str(node))  # An unlistened private node; no traffic.
                parent_info = endpoints.lstat(); socket_info = node.lstat()
                route = dict(schemaVersion=1, scope='macopenvm-registered-qemu-display-route',
                             vmID=native.VM_ID, sessionID='session',
                             controlSocket=str(endpoints / 'worker.sock'), displaySocket=str(node),
                             parentDevice=parent_info.st_dev, parentInode=parent_info.st_ino,
                             socketDevice=socket_info.st_dev, socketInode=socket_info.st_ino)
                private_write(run / 'display.json', json.dumps(route).encode())
                for mode in (0o600, 0o700):
                    node.chmod(mode)
                    self.assertEqual(native.display_route(run, endpoints, 'session'), route)
                for mode in (0o660, 0o606, 0o400, 0o200, 0o1600, 0o4600):
                    node.chmod(mode); self.assertEqual(stat.S_IMODE(node.lstat().st_mode), mode)
                    with self.subTest(mode=oct(mode)), self.assertRaisesRegex(ValueError, 'display-endpoint-changed'):
                        native.display_route(run, endpoints, 'session')
                    with self.assertRaisesRegex(ValueError, 'rfb-route-node-changed'):
                        native.observe_frame(route)
                    self.assertEqual(stat.S_IMODE(node.lstat().st_mode), mode)
        parent = SimpleNamespace(st_dev=7, st_ino=11)
        replacement = SimpleNamespace(st_dev=7, st_ino=13, st_mode=stat.S_IFSOCK | 0o600,
                                      st_uid=os.geteuid(), st_nlink=1)
        selected = dict(displaySocket='/private/tmp/mock-parent/vnc.sock',
                        parentDevice=7, parentInode=11, socketDevice=7, socketInode=12)
        with patch.object(native, 'private_directory'), patch.object(native, 'plain_path'), \
                patch.object(Path, 'lstat', side_effect=[parent, replacement]), \
                patch.object(native.socket, 'socket') as connection:
            with self.assertRaisesRegex(ValueError, 'rfb-route-node-changed'):
                native.observe_frame(selected)
            connection.assert_not_called()
        # macOS strips setgid on native socket chmod; this is controlled metadata,
        # not evidence that the host kernel preserves the special bit.
        setgid = SimpleNamespace(st_dev=7, st_ino=12, st_mode=stat.S_IFSOCK | 0o2600,
                                 st_uid=os.geteuid(), st_nlink=1)
        with patch.object(native, 'private_directory'), patch.object(native, 'plain_path'), \
                patch.object(Path, 'lstat', side_effect=[parent, setgid]), \
                patch.object(native.socket, 'socket') as connection:
            with self.assertRaisesRegex(ValueError, 'rfb-route-node-changed'):
                native.observe_frame(selected)
            connection.assert_not_called()

    def test_installer_navigation_refuses_no_grant_unknown_identity_and_stale_frames(self):
        session = '3BC573F0-973D-4B88-9D97-A06CEE47BDCB'
        route = dict(vmID=native.VM_ID, sessionID=session, socket='/private/unused.sock')
        state = dict(state=2, ownership=0, backendActive=True, operationPending=False, error=0)
        frame = b'P6\n2 1\n255\n\x01\x02\x03\x04\x05\x06'
        digest = hashlib.sha256(frame).hexdigest()
        arguments = (Mock(), Path('/private/unused'), Path('/private/run'), Path('/private/endpoints'), session)
        with patch.object(native, 'current_route') as owner, patch.object(native, 'observe_frame') as observe:
            with self.assertRaisesRegex(ValueError, 'installer-navigation-not-authorized'):
                native.navigate(*arguments, 'key', digest, False, key='space')
            owner.assert_not_called(); observe.assert_not_called()
            with self.assertRaisesRegex(ValueError, 'unknown-installer-key'):
                native.navigate(*arguments, 'key', digest, True, key='arbitrary-text')
            owner.assert_not_called(); observe.assert_not_called()
        with patch.object(native, 'current_route', return_value=(dict(route, vmID='foreign'), state)), \
                patch.object(native, 'observe_frame') as observe:
            with self.assertRaisesRegex(ValueError, 'input-owner-not-current'):
                native.navigate(*arguments, 'key', digest, True, key='space')
            observe.assert_not_called()
        stream = Stream(b'')
        def observer(value, before_input=None):
            before_input(stream, 2, 1, frame)
            return 2, 1, frame
        with patch.object(native, 'current_route', return_value=(route, state)), \
                patch.object(native, 'display_route', return_value={'selected': True}), \
                patch.object(native, 'observe_frame', side_effect=observer):
            with self.assertRaisesRegex(ValueError, 'reviewed-frame-stale'):
                native.navigate(*arguments, 'key', '0' * 64, True, key='space')
            with self.assertRaisesRegex(ValueError, 'click-outside-reviewed-frame'):
                native.navigate(*arguments, 'click', digest, True, x=2, y=0)
        self.assertEqual(stream.sent, [])

    def test_installer_packets_use_one_observed_connection_and_release_without_replay(self):
        session = '3BC573F0-973D-4B88-9D97-A06CEE47BDCB'
        route = dict(vmID=native.VM_ID, sessionID=session, socket='/private/unused.sock')
        state = dict(state=2, ownership=0, backendActive=True, operationPending=False, error=0)
        frame = b'P6\n2 1\n255\n\x01\x02\x03\x04\x05\x06'; digest = hashlib.sha256(frame).hexdigest()
        arguments = (Mock(), Path('/private/unused'), Path('/private/run'), Path('/private/endpoints'), session)
        stream = Stream(b'')
        def observer(value, before_input=None):
            before_input(stream, 2, 1, frame)
            return 2, 1, frame
        with patch.object(native, 'current_route', return_value=(route, state)), \
                patch.object(native, 'display_route', return_value={'selected': True}), \
                patch.object(native, 'observe_frame', side_effect=observer) as observe:
            result = native.navigate(*arguments, 'key', digest, True, key='space')
            self.assertEqual(stream.sent, [b'\x04\x01\0\0\0\0\0 ', b'\x04\0\0\0\0\0\0 '])
            self.assertTrue(result['inputPacketsWritten']); self.assertFalse(result['guestNavigationVerified'])
            observe.assert_called_once()
            stream.sent.clear()
            native.navigate(*arguments, 'click', digest, True, x=1, y=0)
            self.assertEqual(stream.sent, [struct.pack('>BBHH', 5, 1, 1, 0), struct.pack('>BBHH', 5, 0, 1, 0)])
        class FailedPress(Stream):
            def sendall(self, packet):
                self.sent.append(packet)
                if len(self.sent) == 1: raise OSError('Controlled same-FD write failure')
        stream = FailedPress(b'')
        with patch.object(native, 'current_route', return_value=(route, state)), \
                patch.object(native, 'display_route', return_value={'selected': True}), \
                patch.object(native, 'observe_frame', side_effect=observer) as observe:
            with self.assertRaises(OSError): native.navigate(*arguments, 'key', digest, True, key='space')
            observe.assert_called_once()
        self.assertEqual(stream.sent, [b'\x04\x01\0\0\0\0\0 ', b'\x04\0\0\0\0\0\0 '])
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            evidence = Path(temporary); evidence.chmod(0o700)
            first = native.save_review_frame(evidence, 2, 1, frame)
            second = native.save_review_frame(evidence, 2, 1, frame)
            self.assertNotEqual(first['framePath'], second['framePath'])
            self.assertEqual(Path(first['framePath']).read_bytes(), frame)
            self.assertEqual(stat.S_IMODE(Path(first['framePath']).stat().st_mode), 0o600)
            self.assertEqual(first['frameSHA256'], digest)

    def test_recovery_uses_actual_owner_fresh_revision_and_honest_terminal(self):
        session = 'F1518E57-8D05-4904-AB85-43FC6FF4BD59'
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            directory = Path(temporary); directory.chmod(0o700)
            run = directory / 'run'; run.mkdir(mode=0o700)
            endpoints = directory / 'endpoints'; endpoints.mkdir(mode=0o700)
            private_write(directory / 'writer.lock', b'lock')
            held = os.open(directory / 'writer.lock', os.O_RDWR)
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            private_write(directory / 'runtime-intent.json', json.dumps(dict(
                schemaVersion=1, vmID=native.VM_ID, sessionID=session, state='unsettled')).encode())
            private_write(run / 'worker.json', b'{broken publication')
            worker = Mock(); worker.poll.return_value = None
            peers = []

            class Peer:
                def __init__(self, route):
                    self.route = route; self.calls = []; self.closed = False; peers.append(self)
                def request(self, command=0, revision=0):
                    self.calls.append((command, revision))
                    return dict(revision=17, ownership=0, backendActive=True,
                                operationPending=False, state=2, error=0)
                def close(self): self.closed = True

            with patch.object(native, 'Client', Peer):
                with self.assertRaises(json.JSONDecodeError):
                    native.current_route(worker, directory, run, endpoints, session)
                route, status = native.current_route(worker, directory, run, endpoints, session, recovery=True)
                self.assertEqual(route['sessionID'], session)
                with self.assertRaisesRegex(ValueError, 'explicit-disposable-force-required'):
                    native.control(worker, directory, run, endpoints, session, 'force-stop', False)
                native.control(worker, directory, run, endpoints, session, 'normal-stop', False)
                self.assertEqual(peers[-1].calls, [(0, 0), (4, 17)])
                native.control(worker, directory, run, endpoints, session, 'force-stop', True)
                self.assertEqual(peers[-1].calls, [(0, 0), (3, 17)])
                before = len(peers)
                with self.assertRaisesRegex(ValueError, 'session-changed'):
                    native.control(worker, directory, run, endpoints, 'foreign', 'force-stop', True)
                self.assertEqual(len(peers), before)
                self.assertTrue(all(peer.closed for peer in peers))
            self.assertEqual((run / 'worker.json').read_bytes(), b'{broken publication')
            private_write(directory / 'runtime-intent.json', json.dumps(dict(
                schemaVersion=1, vmID=native.VM_ID, sessionID=session, state='settled')).encode())
            private_write(directory / 'runtime.json', json.dumps(dict(sessionID=session,
                          snapshot=dict(backendActive=False, outcome='failed'))).encode())
            # Until the genuine object's completion, the real independent EX probe remains busy.
            with self.assertRaises(ValueError): native.writer_probe(directory, False)
            worker.wait.side_effect = lambda: (os.close(held), 1)[1]
            receipt = native.terminal(worker, directory, run, session)
            self.assertTrue(receipt['actualParentReaped']); self.assertTrue(receipt['kernelWriterAvailable'])
            self.assertTrue(receipt['failedAdvisory']); self.assertFalse(receipt['producerResultQualified'])
            self.assertIsNone(receipt['drainsFinished']); self.assertEqual(receipt['outcome'], 'failed')
            # Even an exit-zero process lacks a qualified drain receipt when result is absent.
            worker.wait.side_effect = None; worker.wait.return_value = 0
            self.assertTrue(native.terminal(worker, directory, run, session)['failedAdvisory'])
            private_write(run / 'result.json', json.dumps(dict(schemaVersion=1,
                scope='macopenvm-registered-qemu-runtime-result', vmID=native.VM_ID, sessionID=session,
                outcome='failed', drainsFinished=True, runtimeIntentSettled=True,
                platformStateFlushed=True, resourcesRevalidated=True)).encode())
            qualified_failure = native.terminal(worker, directory, run, session)
            self.assertTrue(qualified_failure['producerResultQualified'])
            self.assertTrue(qualified_failure['drainsFinished'])
            self.assertEqual(qualified_failure['workerExit'], 0)
            self.assertTrue(qualified_failure['failedAdvisory'])
            for path in (run / 'result.json', directory / 'runtime.json', directory / 'runtime-intent.json'):
                path.unlink()
            private_write(directory / 'configuration.json', json.dumps(dict(id=native.VM_ID,
                guest='windows11', backend='qemuHVF', architecture='arm64', boot='efi',
                network='shared', diskBytes=64 * 2**30, diskFile='disk.raw',
                supportMedia=str(native.CARRIER))).encode())
            private_write(directory / 'qemu-platform.json', json.dumps(dict(vmID=native.VM_ID,
                profile='experimental-windows-arm64-offline-v1')).encode())
            private_write(directory / 'uefi-vars.json', b'')
            (directory / 'tpm-state').mkdir(mode=0o700)
            disk = directory / 'disk.raw'; private_write(disk, b'')
            with disk.open('r+b') as output: output.truncate(64 * 2**30)
            with self.assertRaisesRegex(ValueError, 'previously-observed-owner-missing'):
                native.terminal(worker, directory, run, session)
            with self.assertRaisesRegex(ValueError, 'pre-owner-runtime-evidence-present'):
                native.terminal(worker, directory, run, None)
            (run / 'worker.json').unlink()
            with patch.object(native, 'verify_carrier'):
                pre_owner = native.terminal(worker, directory, run, None)
            self.assertTrue(pre_owner['actualParentReaped']); self.assertTrue(pre_owner['kernelWriterAvailable'])
            self.assertTrue(pre_owner['failedAdvisory']); self.assertFalse(pre_owner['guestStarted'])
            self.assertTrue(pre_owner['blankStatePreserved']); self.assertFalse(pre_owner['runtimeIntentSettled'])
            self.assertFalse(pre_owner['producerResultQualified']); self.assertIsNone(pre_owner['drainsFinished'])
            retained = Mock(); retained.wait.side_effect = [InterruptedError(), KeyboardInterrupt(), 1]
            with patch.object(native.time, 'sleep'):
                self.assertEqual(native.retain_until_reaped(retained), 1)
            self.assertEqual(retained.wait.call_count, 3)
            retained.terminate.assert_not_called(); retained.kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
