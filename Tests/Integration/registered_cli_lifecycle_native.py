#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit original no-OS, offline CLI lifecycle qualification; never an installed-guest controller."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import time
import uuid
from registered_windows_worker_native import plain_path, private_directory, read_private, read_record, sha, retain_until_reaped, COMPILED as WORKER_SOURCES
from runtime_worker_lab import ROOT, Client, save, writer_probe

VM_ID = 'D4132058-CBD9-4022-894C-A83CE13F0A74'
DIRECTORY = Path('/private/tmp/mvo-cli-noos-1bec57a0fa8b45aaa615f5d7e7aca513/Original No OS.macopenvm')
CLI = ROOT / '.lab/linux-desktop-artifacts-c7a6e80cc403442ca286b72c51639d1b/macopenvm'
CLI_SHA = '0e099195ec469bb1123c84a2f360162370f39a17d50ebb29bd3e727259a6bee6'
CONFIG_SHA = 'e0471457387fb2fa6a15baca1bd5d7eef7303dca04cae3b23ba69b1bddeab1a1'
PLATFORM_SHA = 'b94bb4c2984e437521a228f58c174aeae509757c7fdd31801dc4af36388da3d2'
COMPILED = WORKER_SOURCES + ('CLI/RegisteredWindowsControl.swift',)
ACTIONS = ('status', 'pause', 'stop', 'resume', 'force-denied', 'force')

def require(value, code):
    if not value: raise ValueError(code)

def verify_cli():
    plain_path(CLI); info = CLI.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
            and stat.S_IMODE(info.st_mode) == 0o500 and sha(CLI) == CLI_SHA, 'fixed-cli-pin-invalid')
    build = read_record(CLI.parent / 'build-record.json', 262144)
    rows = {row['path']: row['sha256'] for row in build['sources']['files']}
    require(build['cliSHA256'] == CLI_SHA and all(rows.get(name) == sha(ROOT / name) for name in COMPILED), 'compiled-source-drift')
    return rows

def fresh(directory):
    require(directory == DIRECTORY, 'fixed-original-no-os-fixture-only'); private_directory(directory)
    config = read_record(directory / 'configuration.json', 65536)
    require(config['id'] == VM_ID and config['guest'] == 'windows11' and config['backend'] == 'qemuHVF'
            and config['architecture'] == 'arm64' and config['boot'] == 'efi' and config['network'] == 'disconnected'
            and config['diskFile'] == 'disk.raw' and config['diskBytes'] == 64 * 2**30
            and config.get('installationMedia') is None and config.get('supportMedia') is None
            and hashlib.sha256(read_private(directory / 'configuration.json', 65536)).hexdigest() == CONFIG_SHA
            and hashlib.sha256(read_private(directory / 'qemu-platform.json', 8192)).hexdigest() == PLATFORM_SHA, 'fresh-profile-drift')
    for name, size in [('disk.raw', 64 * 2**30), ('uefi-vars.json', 0)]:
        path = directory / name; plain_path(path); info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size == size
                and (name != 'disk.raw' or info.st_blocks == 0), 'not-original-empty-state')
    private_directory(directory / 'tpm-state'); require(not list((directory / 'tpm-state').iterdir()), 'tpm-not-fresh')
    for name in ('runtime.json', 'runtime-intent.json', '.runtime', '.parent-evidence'):
        require(not (directory / name).exists() and not (directory / name).is_symlink(), 'prior-attempt-refused')
    writer_probe(directory, False)

def launch(arguments, output, error):
    descriptors = []
    try:
        for path in (output, error): descriptors.append(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            return subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=descriptors[0], stderr=descriptors[1],
                close_fds=True, cwd=ROOT, env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'LC_ALL': 'C'})
        finally: signal.signal(signal.SIGINT, previous)
    finally:
        for fd in descriptors: os.close(fd)

def locate(worker, run, endpoints, expected=None):
    require(worker.poll() is None, 'actual-worker-terminal')
    intent = read_record(DIRECTORY / 'runtime-intent.json')
    require(intent['vmID'] == VM_ID and intent['state'] == 'unsettled', 'current-intent-required')
    session = intent['sessionID']; require(str(uuid.UUID(session)).upper() == session, 'session-invalid')
    require(expected is None or expected == session, 'session-changed')
    route = read_record(run / 'worker.json')
    require(set(route) == {'schemaVersion', 'scope', 'vmID', 'sessionID', 'socket'}
            and type(route['schemaVersion']) is int and route['schemaVersion'] == 1
            and route['scope'] == 'macopenvm-registered-qemu-worker-route' and route['vmID'] == VM_ID
            and route['sessionID'] == session and route['socket'] == str(endpoints / 'worker.sock'), 'current-route-required')
    peer = Client(route)
    try: status = peer.request()
    finally: peer.close()
    writer_probe(DIRECTORY, True)
    return session, status

def control_arguments(action, run, session):
    require(action in ACTIONS and str(uuid.UUID(session)).upper() == session, 'explicit-control-invalid')
    require(run.parent == DIRECTORY / '.runtime' and run.name.startswith('run-')
            and len(run.name) == 36 and all(c in '0123456789abcdef' for c in run.name[4:]), 'selected-run-required')
    command = 'force-stop' if action in ('force', 'force-denied') else action
    args = [str(CLI), command, '--directory', str(DIRECTORY), '--run-directory', str(run), '--expected-session', session]
    return args + (['--confirm-data-loss', 'yes'] if action == 'force' else [])

def control(action, run, session, evidence):
    verify_cli(); token = uuid.uuid4().hex
    output, error = evidence / ('control-' + token + '.stdout'), evidence / ('control-' + token + '.stderr')
    child = launch(control_arguments(action, run, session), output, error)
    # A deadline or interrupted wait never signals/kills a submitted control process.
    try: exit_code = child.wait(timeout=30)
    finally: retain_until_reaped(child)
    reply = read_record(output, 4096) if output.lstat().st_size else None
    if reply is not None:
        require(reply['vmID'] == VM_ID and reply['sessionID'] == session and type(reply['schemaVersion']) is int
                and reply['schemaVersion'] == 1 and type(reply['requestAcknowledged']) is bool, 'cli-response-unqualified')
    result = dict(action=action, actualControlReaped=True, exit=exit_code, reply=reply)
    save(evidence / ('control-' + token + '.json'), result)
    return result

def validate_trace(trace):
    actions = [row['action'] for row in trace]; mutations = [row for row in trace if row['action'] != 'status']
    require([row['action'] for row in mutations] == ['pause', 'stop', 'resume', 'force-denied', 'force'], 'explicit-sequence-incomplete')
    for row in mutations:
        require(row['actualControlReaped'] is True and (row['exit'] != 0 if row['action'] in ('stop', 'force-denied')
                else row['exit'] == 0 and row['reply']['requestAcknowledged'] is True), 'cli-ack-or-refusal-unqualified')
    for left, right, state in [('pause', 'stop', 4), ('resume', 'force-denied', 2)]:
        require(any(row['action'] == 'status' and row['exit'] == 0 and row['reply']['state'] == state
                    and row['reply']['backendActive'] is True and row['reply']['operationPending'] is False
                    and row['reply']['ownership'] == 0 and row['reply']['error'] == 0
                    for row in trace[actions.index(left) + 1:actions.index(right)]), 'explicit-status-observation-required')

def producer_qualified(producer, session):
    return (type(producer['schemaVersion']) is int and producer['schemaVersion'] == 1
        and producer['scope'] == 'macopenvm-registered-qemu-runtime-result' and producer['vmID'] == VM_ID and producer['sessionID'] == session
        and type(producer['qemuExit']) is int and producer['qemuExit'] == 0 and type(producer['tpmExit']) is int and producer['tpmExit'] == 0
        and producer['qemuSignalled'] is False and producer['tpmSignalled'] is False
        and all(producer[k] is True for k in ('drainsFinished', 'platformStateFlushed', 'resourcesRevalidated', 'runtimeIntentSettled')))

def terminal(worker, session, run, sources, trace):
    require(worker.poll() is not None and worker.wait() == 0, 'actual-worker-not-successfully-reaped')
    validate_trace(trace); verify_cli()
    require(all(sha(ROOT / name) == sources[name] for name in COMPILED)
            and sha(DIRECTORY / 'configuration.json') == CONFIG_SHA and sha(DIRECTORY / 'qemu-platform.json') == PLATFORM_SHA, 'source-or-registration-drift')
    intent, history, producer = read_record(DIRECTORY / 'runtime-intent.json'), read_record(DIRECTORY / 'runtime.json'), read_record(run / 'result.json')
    require(intent['vmID'] == producer['vmID'] == VM_ID and intent['sessionID'] == history['sessionID'] == producer['sessionID'] == session
            and intent['state'] == 'settled' and history['snapshot']['state'] == 'stopped' and history['snapshot']['backendActive'] is False
            and history['snapshot']['outcome'] == producer['outcome'] == 'forcedStopped'
            and producer_qualified(producer, session), 'forced-settlement-unqualified')
    writer_probe(DIRECTORY, False)
    return dict(status='passed', scope='original-offline-no-os-cli-lifecycle', vmID=VM_ID, sessionID=session,
                actualWorkerReaped=True, workerExit=0, forcedStopped=True, childDrainsFinished=True, kernelWriterAvailable=True,
                runtimeIntentSettled=True, normalGuestShutdownVerified=False, guestFilesystemVerified=False, windowsCompatibilityVerified=False)

def failed_terminal(worker, session, run, error):
    qualified = False; available = None
    try: qualified = session is not None and producer_qualified(read_record(run / 'result.json'), session)
    except (OSError, ValueError, KeyError, TypeError): pass
    try: writer_probe(DIRECTORY, False); available = True
    except (OSError, ValueError): pass
    return dict(status='failed', scope='original-offline-no-os-cli-lifecycle', vmID=VM_ID, sessionID=session,
        actualWorkerReaped=True, workerExit=worker.wait(), failureType=type(error).__name__, producerResultQualified=qualified,
        childDrainsFinished=True if qualified else None, kernelWriterAvailable=available,
        normalGuestShutdownVerified=False, guestFilesystemVerified=False, windowsCompatibilityVerified=False)

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--run', action='store_true')
    parser.add_argument('--disposable-no-os-force-authorized', action='store_true'); args = parser.parse_args(argv)
    if not args.run or not args.disposable_no_os_force_authorized:
        print('SKIP: explicit run and original no-OS disposable-force authorization required before any I/O.'); return 0
    sources = verify_cli(); fresh(DIRECTORY); os.umask(0o077); token = uuid.uuid4().hex
    runtime, parent = DIRECTORY / '.runtime', DIRECTORY / '.parent-evidence'
    runtime.mkdir(mode=0o700); parent.mkdir(mode=0o700)
    run = runtime / ('run-' + token); run.mkdir(mode=0o700)
    evidence = parent / ('run-' + token); evidence.mkdir(mode=0o700)
    endpoints = Path('/private/tmp/mvo-qemu-' + token[:16]); endpoints.mkdir(mode=0o700)
    save(evidence / 'prepared.json', dict(scope='original-offline-no-os-cli-lifecycle', vmID=VM_ID, cliSHA256=CLI_SHA,
        disposableNoOSForceAuthorized=True, networkAuthorized=False, guestInputAuthorized=False, runDirectory=str(run), endpointDirectory=str(endpoints)))
    worker = None; session = None; trace = []; failed = False; ready = False
    try:
        worker = launch([str(CLI), 'windows-worker', '--directory', str(DIRECTORY), '--run-directory', str(run), '--endpoint-directory', str(endpoints)],
                        run / 'parent-stdout.log', run / 'parent-stderr.log')
        save(evidence / 'actual-worker-start.json', dict(actualPopenRetained=True, diagnosticPID=worker.pid))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and worker.poll() is None:
            try:
                session, observed = locate(worker, run, endpoints)
                require(observed['state'] == 2 and observed['ownership'] == 0 and observed['backendActive']
                        and not observed['operationPending'] and observed['error'] == 0, 'worker-not-ready')
                ready = worker.poll() is None
                break
            except (FileNotFoundError, ConnectionRefusedError): time.sleep(.1)
        require(ready and session is not None, 'readiness-not-qualified')
        print('READY ' + str(evidence) + '\nExplicit commands: status | pause | stop | resume | force-denied | force', flush=True)
    except BaseException:
        failed = True
    if worker is None: return 1
    if not ready: print('FAILED-RETAINED ' + str(evidence) + '\nExplicit commands remain available for this original blank fixture.', flush=True)
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN); input_open = True
    try:
        while worker.poll() is None:
            try:
                readable, _, _ = select.select([sys.stdin] if input_open else [], [], [], 1)
                if not readable: continue
                line = sys.stdin.readline()
                if not line: input_open = False; continue
                action = line.strip(); require(action in ACTIONS, 'unknown-explicit-command')
                session, _ = locate(worker, run, endpoints, session)
                reply = control(action, run, session, evidence); trace.append(reply)
                print(json.dumps(reply), flush=True)
            except BaseException:
                failed = True
                try: print('Request failed; actual worker remains retained.', flush=True)
                except BaseException: pass
        try: result = terminal(worker, session, run, sources, trace)
        except BaseException as error: result = failed_terminal(worker, session, run, error); failed = True
        if failed: result['status'] = 'failed'
        save(evidence / 'terminal.json', result); return 1 if failed else 0
    finally:
        retain_until_reaped(worker); signal.signal(signal.SIGINT, previous)

if __name__ == '__main__': raise SystemExit(main())
