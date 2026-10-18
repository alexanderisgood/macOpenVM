#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""One reviewed stopped relocation; never a generic VM mover or launcher."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

from runtime_worker_lab import read_json, save
from windows_external_storage_lab import open_directory, relocate_stopped
from windows_external_continuation_worker_lab import private_bytes, unique

ROOT = Path(__file__).resolve().parents[2]
VM_ID = '11111111-1111-4111-8111-111111111111'
SESSION_ID = '22222222-2222-4222-8222-222222222222'
SOURCE = ROOT / '.lab/windows-installer-boot-6223442a7c544aa8a7f17061aec76f80'
PREVIOUS_RUN = ROOT / '.lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0/run-4805dfc7548144148c98a3ff9870e30e'
PARENT = Path('/Users/developer/Library/Application Support/macOpenVM/PrivateEvaluation')
DESTINATION = PARENT / VM_ID


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resource(path):
    value = path.lstat()
    return {'device': value.st_dev, 'inode': value.st_ino,
            'byteCount': value.st_size, 'mode': stat.S_IMODE(value.st_mode)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--move', action='store_true')
    parser.add_argument('--stopped-review-sha256', required=True)
    args = parser.parse_args()
    if not args.move:
        raise SystemExit('SKIP: explicit reviewed stopped move required')
    review_path = PREVIOUS_RUN / 'stopped-storage-review.json'
    review_bytes = private_bytes(review_path, 32768)
    review = json.loads(review_bytes, object_pairs_hook=unique)
    if hashlib.sha256(review_bytes).hexdigest() != args.stopped_review_sha256:
        raise ValueError('Actual parent stopped review changed')
    terminal = read_json(PREVIOUS_RUN / 'runner-terminal.json')
    result = read_json(PREVIOUS_RUN / 'swift-worker-result.json')
    request = read_json(PREVIOUS_RUN / 'normal-shutdown-request.json')
    exits = [review['actualParentExit'], terminal['workerExit'], result['qemuExit'], result['tpmExit']]
    if (review['vmID'] != VM_ID or review['sessionID'] != SESSION_ID
            or not all(type(value) is int and value == 0 for value in exits)
            or review['actualParentReaped'] is not True
            or review['independentWriterAvailable'] is not True
            or review['stoppedMutableStateFlushed'] is not True
            or review['credentialEntryPerformed'] is not False
            or terminal != review['workerTerminal'] or result != review['workerResult']
            or terminal['actualWorkerReaped'] is not True
            or terminal['forceStopUsed'] is not False or review['forceStopUsed'] is not False
            or terminal['sessionID'] != SESSION_ID or terminal['vmID'] != VM_ID
            or result['status'] != 'passed' or result['readonlyHashesPreserved'] is not True
            or result['drainsFinished'] is not True or result['runtimeIntentSettled'] is not True
            or request['vmID'] != VM_ID or request['sessionID'] != SESSION_ID
            or type(request['opcode']) is not int or request['opcode'] != 4
            or request['command'] != 'stop' or request['forceStopUsed'] is not False
            or digest(PREVIOUS_RUN / 'normal-shutdown-request.json') != review['normalRequestSHA256']
            or digest(SOURCE / 'runtime.json') != review['historySHA256']
            or digest(SOURCE / 'runtime-intent.json') != review['intentSHA256']):
        raise ValueError('Exact actual stopped parent/session review required')
    os.umask(0o077)
    # These new private user-data parents carry no VM state until the checked rename.
    for directory in (PARENT.parent, PARENT):
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            pass
        descriptor = open_directory(directory)
        try:
            value = os.fstat(descriptor)
            if value.st_uid != os.geteuid() or stat.S_IMODE(value.st_mode) != 0o700:
                raise ValueError('External parent must be private and owned')
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    receipt = relocate_stopped(SOURCE, DESTINATION, VM_ID, SESSION_ID)
    # Never roll back or copy on a later preparation failure. The stopped VM stays
    # at its one external location for inspection; no launch happens here.
    runs = DESTINATION / 'continuation-runs'
    runs.mkdir(mode=0o700)
    token = uuid.uuid4().hex
    run = runs / ('run-' + token)
    run.mkdir(mode=0o700)
    owners = DESTINATION / 'owner-evidence'
    owners.mkdir(mode=0o700)
    evidence = owners / run.name
    evidence.mkdir(mode=0o700)
    short = Path('/private/tmp') / ('mvo-win-external-' + token[:16])
    short.mkdir(mode=0o700)
    save(run / 'relocation-receipt.json', receipt)
    pairs = [('previous-runtime.json', DESTINATION / 'runtime.json'),
             ('previous-intent.json', DESTINATION / 'runtime-intent.json'),
             ('previous-worker-result.json', PREVIOUS_RUN / 'swift-worker-result.json'),
             ('normal-stop.json', PREVIOUS_RUN / 'normal-shutdown-request.json')]
    for name, original in pairs:
        data = original.read_bytes()
        if not 0 < len(data) <= 32768:
            raise ValueError('Stopped evidence snapshot exceeds its bound')
        fd = os.open(run / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    tpm = {}
    for path in (DESTINATION / 'tpm-state').iterdir():
        if path.name not in ('.lock', 'tpm2-00.permall'):
            raise ValueError('Unexpected TPM state member; preserve it for inspection')
        tpm[path.name] = {**resource(path), 'sha256': digest(path)}
    moved = DESTINATION.lstat()
    record = {'schemaVersion': 1, 'scope': 'approved-same-vm-windows-external-preparation',
              'vmID': VM_ID, 'previousSessionID': SESSION_ID,
              'sourceDirectory': str(SOURCE), 'destinationDirectory': str(DESTINATION),
              'runDirectory': str(run), 'socketDirectory': str(short),
              'macAddress': '02:11:22:33:44:55',
              'directoryDevice': moved.st_dev, 'directoryInode': moved.st_ino,
              'previousRuntimeSHA256': digest(run / 'previous-runtime.json'),
              'previousIntentSHA256': digest(run / 'previous-intent.json'),
              'previousWorkerResultSHA256': digest(run / 'previous-worker-result.json'),
              'normalStopRecordSHA256': digest(run / 'normal-stop.json'),
              'workerExit': 0, 'qemuExit': 0, 'tpmExit': 0,
              'resources': {name: resource(DESTINATION / name) for name in
                            ('blank-nvme.raw', 'firmware-code.fd', 'uefi-vars.json', 'writer.lock', 'tpm-state')},
              'tpmFiles': tpm}
    reaped = review['actualParentReaped'] and terminal['actualWorkerReaped']
    children_terminal = reaped and all(type(value) is int and value == 0 for value in exits)
    drained = result['drainsFinished']
    record.update({'actualOwnerReaped': reaped, 'allChildrenTerminal': children_terminal,
                   'drainsFinished': drained, 'pipesClosed': children_terminal and drained,
                   'leasesClosed': children_terminal and review['independentWriterAvailable'],
                   'runtimeIntentSettled': result['runtimeIntentSettled'],
                   'normalStopRequested': request['command'] == 'stop' and request['opcode'] == 4,
                   'relocationApproved': receipt['identitiesPreserved'] and receipt['exclusiveWriterObserved'],
                   'continuationApproved': bool(request['humanAuthorization'])})
    record.update({name: False for name in ('forceStopUsed', 'qemuSignalled', 'tpmSignalled')})
    # The admission decoder requires its exact compact sorted-key representation.
    prepared_bytes = json.dumps(record, sort_keys=True, separators=(',', ':')).encode()
    if len(prepared_bytes) > 32768:
        raise ValueError('External preparation exceeds its bound')
    fd = os.open(run / 'external-prepared.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(prepared_bytes)
        output.flush()
        os.fsync(output.fileno())
    for directory in (run, runs, evidence, owners, DESTINATION, PARENT):
        descriptor = open_directory(directory)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    print(json.dumps({'externalDirectory': str(DESTINATION), 'run': str(run),
                      'record': str(run / 'external-prepared.json'),
                      'recordSHA256': digest(run / 'external-prepared.json'),
                      'receipt': receipt}), flush=True)


if __name__ == '__main__':
    main()
