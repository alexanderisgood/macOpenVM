#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Own one explicitly reviewed external-storage Windows continuation.

No account input, frame export, process adoption or automatic cleanup is performed.
The actual child handle remains retained until reaped after client/observation loss.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time

from rfb_observer_lab import private_log, retain_until_reaped
from runtime_worker_lab import Client, read_json, save
from windows_external_storage_lab import open_directory

VM_ID = '11111111-1111-4111-8111-111111111111'
DIRECTORY = Path('/Users/developer/Library/Application Support/macOpenVM/PrivateEvaluation') / VM_ID
ROOT = Path(__file__).resolve().parents[2]


def private_bytes(path, maximum, mode=0o600):
    parent = open_directory(path.parent)
    fd = -1
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                     dir_fd=parent)
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != mode
                or not 0 < before.st_size <= maximum):
            raise ValueError('Select a bounded private plain file')
        chunks = []
        total = 0
        while total <= maximum:
            chunk = os.read(fd, min(65536, maximum - total + 1))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        after = os.fstat(fd)
        named = path.lstat()
        fields = ('st_dev', 'st_ino', 'st_size', 'st_mode', 'st_uid', 'st_nlink', 'st_mtime_ns', 'st_ctime_ns')
        if (total != before.st_size
                or any(getattr(before, key) != getattr(after, key) for key in fields)
                or any(getattr(after, key) != getattr(named, key) for key in fields)):
            raise ValueError('Private file changed while reading')
        return b''.join(chunks)
    finally:
        if fd >= 0:
            os.close(fd)
        os.close(parent)


def unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Duplicate private record field')
        value[key] = item
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--record', type=Path, required=True)
    parser.add_argument('--record-sha256', required=True)
    parser.add_argument('--cli', type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        raise SystemExit('SKIP: explicit reviewed continuation required')
    data = private_bytes(args.record, 32768)
    if hashlib.sha256(data).hexdigest() != args.record_sha256:
        raise ValueError('The independently reviewed record digest changed')
    record = json.loads(data, object_pairs_hook=unique)
    run = Path(record['runDirectory'])
    if (record['scope'] != 'approved-same-vm-windows-external-preparation'
            or record['vmID'] != VM_ID or record['destinationDirectory'] != str(DIRECTORY)
            or run.parent != DIRECTORY / 'continuation-runs'
            or not re.fullmatch(r'run-[0-9a-f]{32}', run.name)
            or args.record != run / 'external-prepared.json'):
        raise ValueError('Select the exact external preparation profile')
    cli = args.cli
    if (cli.parent.parent != ROOT / '.lab' or cli.name != 'macopenvm'
            or not re.fullmatch(r'linux-desktop-artifacts-[0-9a-f]{32}', cli.parent.name)):
        raise ValueError('Select an isolated private signed CLI')
    build = json.loads(private_bytes(cli.parent / 'build-record.json', 131072), object_pairs_hook=unique)
    cli_digest = hashlib.sha256(private_bytes(cli, 128 << 20, mode=0o500)).hexdigest()
    if (build['schemaVersion'] != 1 or build['scope'] != 'private-linux-desktop-build'
            or build['cliSHA256'] != cli_digest
            or build['primaryApplicationChanged'] is not False):
        raise ValueError('Private immutable build does not match')
    os.umask(0o077)
    evidence = DIRECTORY / 'owner-evidence' / run.name
    if not evidence.exists():
        raise ValueError('The new private parent evidence directory was not prepared')
    save(evidence / 'runner-source.json', {'scope': 'actual-external-continuation-runner-source',
                                     'sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                     'recordSHA256': args.record_sha256,
                                     'cliSHA256': build['cliSHA256']})
    worker = None
    route = None
    failure = None
    try:
        with private_log(run / 'parent-stdout.log') as output, private_log(run / 'parent-stderr.log') as errors:
            if hashlib.sha256(private_bytes(cli, 128 << 20, mode=0o500)).hexdigest() != cli_digest:
                raise ValueError('Immutable CLI changed before launch')
            worker = subprocess.Popen([str(cli), 'qemu-windows-external-continuation-worker-lab',
                                       '--directory', str(DIRECTORY), '--record', str(args.record),
                                       '--record-sha256', args.record_sha256,
                                       '--run-directory', str(run)], stdin=subprocess.DEVNULL,
                                      stdout=output, stderr=errors, cwd=run, close_fds=True)
            save(evidence / 'actual-worker-start.json', {'pid': worker.pid,
                                                   'scope': 'actual-parent-owned-worker-handle'})
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if worker.poll() is not None:
                    raise ValueError('External continuation owner exited before readiness')
                if (run / 'swift-display-ready.json').exists():
                    route = read_json(run / 'swift-worker-ready.json')
                    if (route['scope'] != 'approved-windows-external-continuation-worker-route'
                            or route['vmID'] != VM_ID or route['sessionID'] == record['previousSessionID']
                            or route['socket'] != record['socketDirectory'] + '/worker.sock'):
                        raise ValueError('Actual new external owner route differs')
                    client = Client(route)
                    try:
                        observed = client.request()
                    finally:
                        client.close()
                    if (observed['state'] == 2 and observed['ownership'] == 0
                            and observed['backendActive'] and not observed['operationPending']
                            and observed['error'] == 0):
                        display_bytes = private_bytes(run / 'swift-display-ready.json', 4096)
                        display = json.loads(display_bytes, object_pairs_hook=unique)
                        if (set(display) != {'schemaVersion', 'scope', 'vmID', 'sessionID', 'controlSocket',
                                             'displaySocket', 'parentDevice', 'parentInode', 'socketDevice', 'socketInode'}
                                or type(display['schemaVersion']) is not int or display['schemaVersion'] != 1
                                or display['scope'] != 'approved-windows-external-continuation-display-route'
                                or display['vmID'] != VM_ID or display['sessionID'] != route['sessionID']
                                or display['controlSocket'] != record['socketDirectory'] + '/worker.sock'
                                or display['displaySocket'] != record['socketDirectory'] + '/vnc.sock'):
                            raise ValueError('Actual display readiness does not match its worker')
                        display_digest = hashlib.sha256(display_bytes).hexdigest()
                        save(evidence / 'actual-ready-observation.json', {'route': route, 'status': observed,
                              'displayRoute': display, 'displayRouteSHA256': display_digest})
                        print('READY ' + str(run) + ' SESSION ' + route['sessionID']
                              + ' ROUTESHA ' + display_digest, flush=True)
                        break
                time.sleep(0.05)
            else:
                raise TimeoutError('External owner readiness deadline; actual owner retained')
            retain_until_reaped(worker)
    except BaseException as error:
        failure = type(error).__name__
        print('Actual owner retained; no implicit stop, replay or signal requested.', flush=True)
    finally:
        if worker is not None:
            retain_until_reaped(worker)
            terminal = {'scope': 'actual-parent-owned-external-continuation-terminal',
                        'vmID': VM_ID, 'workerExit': worker.returncode,
                        'actualWorkerReaped': True, 'failureKind': failure,
                        'guestCleanShutdownClaimed': False, 'forceStopUsed': False}
            if route is not None:
                terminal['sessionID'] = route['sessionID']
            save(evidence / 'runner-terminal.json', terminal)
            print(json.dumps(terminal), flush=True)
    return 0 if failure is None and worker is not None and worker.returncode == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
