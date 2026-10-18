#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit installed 7D shared-settings App qualification. No guest input, pixels or automatic stop/quit.

The actual App Popen is retained until reaped. Timeout/EOF/exception never signals
it or its worker. Commands use the current memory challenge through the local peer.
"""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid

from registered_windows_worker_native import plain_path, private_directory, read_record, read_private, sha, retain_until_reaped, installed_asset
from runtime_worker_lab import ROOT, save, writer_probe

VM_ID = '7D5C2CD4-E2E4-40DF-8535-7C75E691D728'
DIRECTORY = Path('/private/tmp/mvo-network-preparation-4ba67433cd724be2813e72de72da44dd/Windows Network Evaluation.macopenvm')
PRIOR_SESSION = '01F405D3-853F-4BE0-9F01-AEFAB8C1A167'
INSTALLED_BASELINE = ROOT / '.lab/windows-shared-app-retry-baseline-fe3c31449f8f4b29b432fc9efc5e7b90/baseline.json'
INSTALLED_BASELINE_SHA = '6eb16461f253caa2bdc4e06e7fb89b55fcfccdf5c34cc7e32034d20098df6f47'
CARRIER = ROOT / '.lab/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso'
ZERO = str(uuid.UUID(int=0)).upper()
SOURCES = ('App/MacOpenVMApp.swift', 'App/DesktopWindowsRuntime.swift',
           'App/BundledWindowsWorkerAdmission.swift', 'App/RegisteredAppQualificationControl.swift',
           'App/RegisteredWindowsAppQualification.swift', 'App/RegisteredRfbDisplayContext.swift',
           'App/RfbLabView.swift', 'CLI/RegisteredWindowsWorker.swift', 'CLI/RegisteredWindowsRuntimeStore.swift',
           'Backends/Qemu/LeaseSpawn.swift', 'Backends/Qemu/QemuMachineBackend.swift',
           'Core/RecordedRuntimeOwner.swift', 'Core/RuntimeWorkerCoordinator.swift',
           'Core/InstallationMedia.swift', 'Backends/Qemu/QemuRegisteredCatalog.swift',
           'Backends/Qemu/QemuRegisteredPlan.swift', 'Backends/Qemu/QemuRegisteredResources.swift',
           'Backends/Qemu/QemuRegisteredSupportImage.swift', 'Core/NetworkSettings.swift',
           'Storage/NetworkConfiguration.swift', 'Storage/DiskGrowth.swift',
           'Backends/BackendAPI/SharedNetworkConfigurationPermission.swift')


def require(value, code):
    if not value: raise ValueError(code)


def admit(app, expected_sha, installed):
    require(app is not None and expected_sha is not None and len(expected_sha) == 64
            and all(c in '0123456789abcdef' for c in expected_sha), 'explicit-new-app-pin-required')
    plain_path(app); info = app.lstat()
    require(app.name == 'macOpenVMNative' and app.parent.name == 'MacOS'
            and app.parent.parent.name == 'Contents' and app.parents[2].name == 'macOpenVM.app'
            and app.parents[3].parent == ROOT / '.lab', 'new-private-app-only')
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
            and stat.S_IMODE(info.st_mode) == 0o500 and sha(app) == expected_sha, 'app-pin-invalid')
    build = read_record(app.parents[3] / 'build-record.json', 262144)
    require(build['appExecutableSHA256'] == expected_sha and build['credentialsAuthorized'] is False
            and build['primaryApplicationChanged'] is False, 'build-binding-invalid')
    rows = {row['path']: row['sha256'] for row in build['sources']['files']}
    require(all(rows.get(name) == sha(ROOT / name) for name in SOURCES), 'compiled-source-drift')
    helper = app.parent / 'macopenvm-worker'; plain_path(helper)
    require(sha(helper) == build['appWorkerSHA256'], 'worker-pin-invalid')
    installed_admission(DIRECTORY, installed)
    original = read_private(DIRECTORY / 'configuration.json', 65536)
    backups = {name: installed_asset(DIRECTORY / name) for name in installed['networkBackupNames']}
    return rows, hashlib.sha256(original).hexdigest(), sha(DIRECTORY / 'qemu-platform.json'), original, backups


def installed_arguments(args):
    require(args.installed_app_network_evaluation and args.shared_network_authorized
            and args.stopped_baseline == INSTALLED_BASELINE and args.stopped_baseline_sha256 == INSTALLED_BASELINE_SHA,
            'explicit-installed-app-baseline-required')


def read_installed_baseline(path, expected_sha):
    require(path == INSTALLED_BASELINE and expected_sha == INSTALLED_BASELINE_SHA, 'fixed-installed-app-baseline-required')
    plain_path(path); fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno()); raw = stream.read(32769)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == 0o400 and 0 < len(raw) == before.st_size <= 32768
                and hashlib.sha256(raw).hexdigest() == expected_sha
                and (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (os.fstat(stream.fileno()).st_dev, os.fstat(stream.fileno()).st_ino, os.fstat(stream.fileno()).st_mode,
                    os.fstat(stream.fileno()).st_size, os.fstat(stream.fileno()).st_mtime_ns, os.fstat(stream.fileno()).st_ctime_ns)
                and before.st_ino == path.lstat().st_ino, 'installed-baseline-file-invalid')
    data = parsed_configuration(raw)
    require(set(data) == {'schemaVersion', 'scope', 'vmID', 'vmDirectory', 'priorSessionID', 'MAC', 'configurationSHA256',
                         'platformSHA256', 'diskWholeContentHashVerified', 'networkBackupNames', 'assets', 'priorRecords', 'priorAppAttempt'}
            and type(data['schemaVersion']) is int and data['schemaVersion'] == 1
            and data['scope'] == 'fixed-installed-app-shared-retry-baseline' and data['vmID'] == VM_ID
            and data['vmDirectory'] == str(DIRECTORY) and data['priorSessionID'] == PRIOR_SESSION
            and data['diskWholeContentHashVerified'] is False, 'installed-baseline-context-invalid')
    names = ['normal-worker-settlement.json', 'worker-result.json', 'runtime.json', 'runtime-intent.json']; prior = []
    require(type(data['priorRecords']) is list and len(data['priorRecords']) == 4, 'installed-prior-records-invalid')
    for row, name in zip(data['priorRecords'], names):
        require(set(row) == {'path', 'SHA256'} and row['path'] == str(path.parent / name), 'installed-prior-path-invalid')
        raw = read_private(Path(row['path']), 4096); require(hashlib.sha256(raw).hexdigest() == row['SHA256'], 'installed-prior-hash-invalid')
        prior.append(parsed_configuration(raw))
    validate_retry_prior(data, prior)
    return data


def validate_retry_prior(data, prior):
    witness, producer, history, intent = prior
    require(all(record['sessionID'] == PRIOR_SESSION for record in prior)
            and witness['VMID'] == producer['vmID'] == intent['vmID'] == VM_ID
            and witness['scope'] == 'actual-normal-shutdown-after-app-startup-race'
            and witness['appWorkflowPassed'] is False and witness['requestReplyRetained'] is False
            and witness['independentWriterAvailable'] is True
            and witness['configurationSHA256'] == data['configurationSHA256']
            and witness['platformSHA256'] == data['platformSHA256']
            and witness['workerResult'] == producer and witness['history'] == history and witness['runtimeIntent'] == intent
            and type(producer['schemaVersion']) is int and producer['schemaVersion'] == 1
            and producer['scope'] == 'macopenvm-registered-qemu-runtime-result'
            and type(producer['qemuExit']) is int and type(producer['tpmExit']) is int and producer['qemuExit'] == producer['tpmExit'] == 0
            and producer['qemuSignalled'] is False and producer['tpmSignalled'] is False
            and all(producer[k] is True for k in ('drainsFinished', 'platformStateFlushed', 'resourcesRevalidated', 'runtimeIntentSettled'))
            and producer['outcome'] == history['snapshot']['outcome'] == 'guestStopped'
            and history['snapshot']['state'] == 'stopped' and history['snapshot']['backendActive'] is False
            and intent['state'] == 'settled', 'installed-prior-normal-stop-invalid')
    attempt = data['priorAppAttempt']; final = attempt['finalControl']
    require(set(attempt) == {'actualAppParentReaped', 'appExit', 'appExitStatusRetained', 'appWorkflowPassed',
                            'enclosingHarnessExit', 'failedEvidencePath', 'failedEvidenceSHA256', 'finalControl'}
            and attempt['actualAppParentReaped'] is True and attempt['appExit'] is None
            and attempt['appExitStatusRetained'] is False and attempt['appWorkflowPassed'] is False
            and type(attempt['enclosingHarnessExit']) is int and attempt['enclosingHarnessExit'] == 1
            and attempt['failedEvidencePath'] == str(ROOT / '.lab/windows-installed-app-startup-race-87bdd75a6ed0459f874f595cac3d2d5b/result.json')
            and attempt['failedEvidenceSHA256'] == '4db32e12bf697cc2f7b92d73f61dbe58e3accfdb12b36bee2547e71a263c7c8f'
            and final['vmID'] == VM_ID and final.get('sessionID') is None and 'nonce' not in final
            and final['launchGeneration'] == 'AD97D5D0-4EA8-4914-93A3-F4381A6728F9'
            and final['settled'] is True and final['backendActive'] is False and final['busy'] is False
            and final['qualificationFailed'] is True and final['outcome'] == 'guestStopped', 'prior-app-failure-must-remain-failed')


def installed_admission(directory, baseline, before_start=True):
    private_directory(directory); private_directory(directory / 'tpm-state')
    require(set(p.name for p in (directory / 'tpm-state').iterdir()) == {'.lock', 'tpm2-00.permall'}, 'installed-tpm-members-invalid')
    names = ['disk.raw', 'qemu-platform.json', 'uefi-vars.json', 'writer.lock', 'tpm-state/.lock', 'tpm-state/tpm2-00.permall']
    require(set(baseline['assets']) == set(names), 'installed-assets-invalid')
    fd = os.open(directory / 'writer.lock', os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        config = read_record(directory / 'configuration.json', 65536)
        require(config['id'] == VM_ID and config['network'] == 'shared' and config['macAddress'] == baseline['MAC']
                and config.get('supportMedia') is None and config.get('installationMedia') is None
                and sha(directory / 'configuration.json') == baseline['configurationSHA256']
                and sha(directory / 'qemu-platform.json') == baseline['platformSHA256'], 'installed-configuration-drift')
        require(sorted(p.name for p in directory.glob('configuration-network-backup-*.json')) == baseline['networkBackupNames'], 'network-noop-created-backup')
        for name in names:
            actual = installed_asset(directory / name, disk=name == 'disk.raw'); expected = baseline['assets'][name]
            require(all(type(expected[k]) is int for k in ('device', 'inode', 'bytes', 'mode', 'uid', 'links', 'blocks', 'mtimeNS')), 'installed-asset-schema-invalid')
            if before_start: require(actual == expected, 'installed-stopped-asset-drift')
            else: require(all(actual[k] == expected[k] for k in ('device', 'uid', 'mode', 'links'))
                          and (name == 'tpm-state/tpm2-00.permall' or actual['inode'] == expected['inode']), 'installed-identity-drift')
        if before_start:
            for row in baseline['priorRecords'][2:]:
                require(sha(directory / Path(row['path']).name) == row['SHA256'], 'installed-current-prior-drift')
    finally: os.close(fd)


def parsed_configuration(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'duplicate-configuration-field'); result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def support_change_admission(directory, original, current, *, allow_unchanged_failure=False):
    before = parsed_configuration(original)
    after = parsed_configuration(current)
    require(before.get('supportMedia') is None, 'baseline-already-has-support')
    if current == original and allow_unchanged_failure:
        return dict(otherConfigurationFieldsPreserved=True, supportMediaAdded=False, exactOriginalBackupPreserved=False)
    expected = dict(before); expected['supportMedia'] = str(CARRIER)
    require(after == expected, 'only-reviewed-support-addition-permitted')
    backups = list(directory.glob('configuration-support-media-backup-*.json'))
    require(len(backups) == 1, 'one-exact-support-backup-required')
    name = backups[0].name[len('configuration-support-media-backup-'):-len('.json')]
    require(str(uuid.UUID(name)) == name and read_private(backups[0], 65536) == original, 'exact-support-backup-invalid')
    return dict(otherConfigurationFieldsPreserved=True, supportMediaAdded=True, exactOriginalBackupPreserved=True)


def sdk_admission(data, session, generation):
    require(0 < len(data) <= 16384 and data.endswith(b'\n'), 'sdk-evidence-bound')
    records = [parsed_configuration(line) for line in data.splitlines()]
    stages = [record['stage'] for record in records]
    require(len(records) <= 16 and len(set(stages)) == len(stages)
            and all(record['vmID'] == VM_ID and record['failed'] is False for record in records), 'sdk-failed-or-ambiguous')
    required = {'installed-baseline-under-exclusive-writer', 'ordinary-network-settings-permission-ready',
                'ordinary-shared-network-noop-saved', 'ordinary-worker-running', 'native-view-attached', 'native-view-drawn',
                'actual-parent-and-producer-settled', 'explicit-root-normal-stop-request', 'explicit-root-quit-request'}
    require(required <= set(stages), 'installed-sdk-stages-incomplete')
    drawn = next(record for record in records if record['stage'] == 'native-view-drawn')
    require(drawn.get('sessionID') == session and drawn.get('launchGeneration') == generation
            and drawn['drawn'] is True and drawn['attached'] is True and drawn.get('frameEpoch') is not None
            and type(drawn.get('sequence')) is int and drawn['sequence'] > 0, 'current-sdk-paint-unqualified')
    return dict(ordinarySharedNetworkNoopObserved=True, currentSDKPaintObserved=True, explicitNormalStopAndQuitObserved=True)


def decode_response(data, request_id):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'duplicate-response'); value[key] = item
        return value
    require(0 < len(data) <= 2048, 'response-bound')
    value = json.loads(data, object_pairs_hook=unique)
    required = {'requestID', 'nonce', 'vmID', 'replyCode', 'state', 'busy', 'backendActive',
                'displayReady', 'frameEpochPresent', 'settled', 'qualificationFailed'}
    require(required <= set(value) <= required | {'sessionID', 'launchGeneration', 'outcome'}, 'response-fields')
    require(type(value['requestID']) is int and value['requestID'] == request_id and value['vmID'] == VM_ID, 'response-correlation')
    require(value['replyCode'] in ('ok', 'refused', 'failed') and value['state'] in
            ('stopped', 'starting', 'running', 'pausing', 'paused', 'resuming', 'stopping', 'saving', 'suspended', 'restoring', 'failed'), 'response-enums')
    for name in ('nonce', 'sessionID', 'launchGeneration'):
        if value.get(name) is not None:
            require(str(uuid.UUID(value[name])).upper() == value[name], 'response-uuid')
    for name in ('busy', 'backendActive', 'displayReady', 'frameEpochPresent', 'settled', 'qualificationFailed'):
        require(type(value[name]) is bool, 'response-boolean')
    require(value.get('outcome') in (None, 'pending', 'guestStopped', 'forcedStopped', 'failed'), 'response-outcome')
    require(value.get('sessionID') != PRIOR_SESSION, 'prior-session-not-this-app-owner')
    return value


def exchange(path, request_id, action='status', current=None):
    private_directory(path.parent); plain_path(path); before = path.lstat()
    require(stat.S_ISSOCK(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
            and stat.S_IMODE(before.st_mode) == 0o600, 'control-node-invalid')
    request = dict(requestID=request_id, nonce=current['nonce'] if current else ZERO, vmID=VM_ID,
                   sessionID=current.get('sessionID') if current else None,
                   launchGeneration=current.get('launchGeneration') if current else None, action=action)
    data = json.dumps(request, sort_keys=True, separators=(',', ':')).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(5); stream.connect(str(path))
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        peer = ctypes.CDLL(None, use_errno=True).getpeereid
        peer.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]; peer.restype = ctypes.c_int
        require(peer(stream.fileno(), ctypes.byref(uid), ctypes.byref(gid)) == 0 and uid.value == os.geteuid(), 'control-peer-invalid')
        after = path.lstat(); require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), 'control-node-replaced')
        stream.sendall(struct.pack('>I', len(data)) + data)
        def receive(size):
            result = bytearray()
            while len(result) < size:
                chunk = stream.recv(size - len(result)); require(chunk, 'control-eof'); result.extend(chunk)
            return bytes(result)
        size = struct.unpack('>I', receive(4))[0]; require(0 < size <= 2048, 'response-bound')
        return decode_response(receive(size), request_id)


def latch_failure(failed, response):
    return failed or response['qualificationFailed']


def public_reply(value):
    return {key: item for key, item in value.items() if key != 'nonce'}


def mutation_gate(action, known, fresh):
    require(action in ('stop', 'quit'), 'installed-normal-stop-or-quit-only')
    require(fresh['replyCode'] == 'ok' and fresh['vmID'] == VM_ID
            and fresh['nonce'] == known['nonce'] and fresh.get('sessionID') == known.get('sessionID')
            and fresh.get('launchGeneration') == known.get('launchGeneration'), 'current-memory-owner-required')
    if action == 'stop':
        require(fresh.get('sessionID') is not None and fresh.get('launchGeneration') is not None
                and fresh['busy'] and fresh['backendActive'] and not fresh['settled'] and fresh['state'] == 'running', 'normal-owner-not-active')
    else:
        no_owner = fresh.get('sessionID') is None and fresh.get('launchGeneration') is None and not fresh['settled']
        settled_owner = fresh.get('sessionID') is not None and fresh.get('launchGeneration') is not None and fresh['settled']
        require((no_owner or settled_owner) and not fresh['busy'] and not fresh['backendActive'], 'quit-before-settlement-refused')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true'); parser.add_argument('--app', type=Path)
    parser.add_argument('--app-sha256')
    parser.add_argument('--installed-app-network-evaluation', action='store_true')
    parser.add_argument('--shared-network-authorized', action='store_true')
    parser.add_argument('--stopped-baseline', type=Path)
    parser.add_argument('--stopped-baseline-sha256')
    args = parser.parse_args(argv)
    if not args.run:
        print('SKIP: explicit --run required; no input, files, process or GUI action.'); return 0
    installed_arguments(args)
    installed = read_installed_baseline(args.stopped_baseline, args.stopped_baseline_sha256)
    baseline = admit(args.app, args.app_sha256, installed)
    os.umask(0o077); token = uuid.uuid4().hex
    control_parent = Path('/private/tmp/mvo-appqual-' + token[:16]); control_parent.mkdir(mode=0o700)
    evidence = Path('/private/tmp/mvo-appqual-evidence-' + token); evidence.mkdir(mode=0o700)
    path = control_parent / 'control.sock'
    save(evidence / 'prepared.json', dict(vmID=VM_ID, appSHA256=args.app_sha256,
                                        controlDirectory=str(control_parent), credentialsAuthorized=False))
    process = None; descriptors = []; known = None; next_id = 1; failed = False
    try:
        for name in ('app-stdout.log', 'app-stderr.log'):
            descriptors.append(os.open(control_parent / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            process = subprocess.Popen([str(args.app), '--registered-windows-installed-app-qualification', '--run', '--shared-network-authorized',
                '--directory', str(DIRECTORY), '--control-socket', str(path)], stdin=subprocess.DEVNULL,
                stdout=descriptors[0], stderr=descriptors[1], close_fds=True, start_new_session=True,
                env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'LC_ALL': 'C',
                     'MVO_REGISTERED_APP_QUALIFICATION': '1'}, cwd=evidence)
        finally: signal.signal(signal.SIGINT, previous)
        save(evidence / 'actual-app-start.json', dict(actualPopenRetained=True, diagnosticPID=process.pid))
    except BaseException:
        failed = True
    finally:
        for fd in descriptors: os.close(fd)
    if process is None: return 1
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN); input_open = True; ready = False
    def request(action='status', current=None):
        nonlocal next_id
        identifier = next_id; next_id += 1  # A lost reply never permits replaying an accepted ID.
        return exchange(path, identifier, action, current)
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            try:
                if process.poll() is not None: break
                value = request()
                failed = latch_failure(failed, value)
                if value['qualificationFailed']: break
                if value['replyCode'] == 'ok' and value['displayReady'] and value['frameEpochPresent'] and value['backendActive']:
                    known = value; ready = True
                    save(evidence / 'ready.json', public_reply(value))
                    print('READY ' + str(evidence) + '\nCommands: status | stop | quit', flush=True); break
            except FileNotFoundError: pass
            except ConnectionRefusedError: pass
            except BaseException:
                failed = True; break
            time.sleep(.1)
        if not ready: failed = True
        while True:
            try:
                if process.poll() is not None: break
                readable, _, _ = select.select([sys.stdin] if input_open else [], [], [], 1)
                if not readable: continue
                line = sys.stdin.readline()
                if not line: input_open = False; continue
                action = line.strip(); require(action in ('status', 'stop', 'quit'), 'unknown-command')
                fresh = request()
                failed = latch_failure(failed, fresh)
                if known is None and fresh['replyCode'] == 'ok': known = fresh
                if action != 'status':
                    require(known is not None, 'no-current-owner')
                    mutation_gate(action, known, fresh)
                    fresh = request(action, fresh)
                    failed = latch_failure(failed, fresh)
                if action == 'quit' and fresh['replyCode'] == 'ok': known = fresh
                save(evidence / ('reply-%d.json' % (next_id - 1)), public_reply(fresh))
                print(json.dumps(public_reply(fresh)), flush=True)
            except BaseException:
                failed = True
                try: print('Control refused; actual App remains retained.', flush=True)
                except BaseException: pass
        exit_code = process.wait()
        require(sha(args.app) == args.app_sha256 and sha(DIRECTORY / 'qemu-platform.json') == baseline[2]
                and all(sha(ROOT / name) == baseline[0].get(name) for name in SOURCES), 'source-or-registration-drift')
        require(known is not None, 'no-current-memory-session-observed')
        require(read_private(DIRECTORY / 'configuration.json', 65536) == baseline[3], 'network-noop-configuration-changed')
        installed_admission(DIRECTORY, installed, before_start=False)
        require(all(installed_asset(DIRECTORY / name) == info for name, info in baseline[4].items()), 'existing-network-backup-changed')
        configuration_facts = dict(configurationBytesPreserved=True, platformBytesPreserved=True, networkSaveWasNoop=True,
                                   noNewNetworkBackup=True, persistentAssetIdentitiesPreserved=True, diskWholeContentHashVerified=False)
        writer_probe(DIRECTORY, False)
        intent_path = DIRECTORY / 'runtime-intent.json'
        qualified = False
        if known.get('sessionID') is None:
            require(not known['settled'] and known.get('launchGeneration') is None and not known['busy'] and not known['backendActive']
                    and sha(intent_path) == installed['priorRecords'][3]['SHA256']
                    and sha(DIRECTORY / 'runtime.json') == installed['priorRecords'][2]['SHA256'], 'pre-owner-terminal-unqualified')
            result = dict(actualAppReaped=True, appExit=exit_code, vmID=VM_ID,
                          sessionID=None, launchGeneration=known.get('launchGeneration'),
                          runtimeIntentSettled=False, kernelWriterAvailable=True, outcome='failed',
                          producerQualified=False, childDrainsFinished=None, guestStarted=False,
                          credentialsAuthorized=False, guestFilesystemVerified=False, windowsCompatibilityVerified=False)
            failed = True
        else:
            intent = read_record(intent_path); history = read_record(DIRECTORY / 'runtime.json')
            require(intent['vmID'] == VM_ID and intent['sessionID'] == known['sessionID'] and intent['state'] == 'settled'
                    and known['sessionID'] != PRIOR_SESSION and history['sessionID'] == known['sessionID']
                    and history['snapshot']['backendActive'] is False and history['snapshot']['state'] == 'stopped'
                    and history['snapshot']['outcome'] == 'guestStopped', 'actual-terminal-unqualified')
            token = uuid.UUID(known['launchGeneration']).hex
            qualified = False
            try:
                producer = read_record(DIRECTORY / '.runtime' / ('run-' + token) / 'result.json')
                require(type(producer['schemaVersion']) is int and producer['schemaVersion'] == 1
                        and producer['scope'] == 'macopenvm-registered-qemu-runtime-result'
                        and producer['vmID'] == VM_ID and producer['sessionID'] == known['sessionID']
                        and producer['outcome'] == history['snapshot']['outcome']
                        and all(producer[key] is True for key in ('drainsFinished', 'runtimeIntentSettled', 'resourcesRevalidated', 'platformStateFlushed'))
                        and producer['qemuExit'] == 0 and type(producer['qemuExit']) is int
                        and producer['tpmExit'] == 0 and type(producer['tpmExit']) is int
                        and producer['qemuSignalled'] is False and producer['tpmSignalled'] is False, 'producer-unqualified')
                qualified = True
            except (OSError, ValueError, KeyError, TypeError): pass
            result = dict(actualAppReaped=True, appExit=exit_code, vmID=VM_ID, sessionID=known['sessionID'],
                          launchGeneration=known['launchGeneration'], runtimeIntentSettled=True, kernelWriterAvailable=True,
                          outcome=history['snapshot']['outcome'], producerQualified=qualified,
                          childDrainsFinished=True if qualified else None, credentialsAuthorized=False,
                          guestFilesystemVerified=False, windowsCompatibilityVerified=False)
            failed = failed or not qualified
        if qualified:
            result.update(sdk_admission(read_private(control_parent / 'sdk-events.jsonl', 16384), known['sessionID'], known['launchGeneration']))
        result.update(configuration_facts)
        result['qualificationFailed'] = failed
        result['status'] = 'failed' if failed or exit_code != 0 or result['outcome'] == 'failed' else 'passed'
        save(evidence / 'terminal.json', result)
        return 1 if failed or exit_code != 0 or result['outcome'] == 'failed' else 0
    finally:
        retain_until_reaped(process)
        signal.signal(signal.SIGINT, previous)


if __name__ == '__main__':
    raise SystemExit(main())
