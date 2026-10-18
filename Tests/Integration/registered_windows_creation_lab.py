#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Actual normal CLI Windows creation/validation, without launching a guest.

New sparse VM files stay outside the source project. No key, network, OS licence,
account, runtime permit, endpoint or child VM is created by this proof.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import uuid

from runtime_worker_lab import read_json, save

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / '.lab/windows-media-48f5f2b7600e4010b813985fcea79ef8/Windows11_Client_arm64_en-us_26300_9457.iso.partial'


def run(cli, evidence, label, arguments, expected=0):
    result = subprocess.run([str(cli), *arguments], capture_output=True, timeout=120)
    for suffix, data in [('stdout', result.stdout), ('stderr', result.stderr)]:
        descriptor = os.open(evidence / (label + '.' + suffix), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    if result.returncode != expected:
        raise ValueError(label + '-unexpected-exit')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--cli', type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        raise SystemExit('SKIP: explicit file-only creation proof required')
    cli = args.cli
    if (cli.parent.parent != ROOT / '.lab' or cli.name != 'macopenvm'
            or not re.fullmatch(r'linux-desktop-artifacts-[0-9a-f]{32}', cli.parent.name)):
        raise ValueError('Select an isolated signed CLI build')
    build = read_json(cli.parent / 'build-record.json', 262144)
    cli_info = cli.lstat()
    if (not stat.S_ISREG(cli_info.st_mode) or cli_info.st_uid != os.geteuid()
            or cli_info.st_nlink != 1 or stat.S_IMODE(cli_info.st_mode) != 0o500
            or cli_info.st_size > 128 << 20
            or hashlib.sha256(cli.read_bytes()).hexdigest() != build['cliSHA256']
            or build['primaryApplicationChanged'] is not False):
        raise ValueError('Immutable private CLI build changed')
    os.umask(0o077)
    token = uuid.uuid4().hex
    parent = Path('/private/tmp') / ('mvo-registered-create-' + token)
    parent.mkdir(mode=0o700)
    evidence = ROOT / '.lab' / ('registered-windows-creation-' + token)
    evidence.mkdir(mode=0o700)
    vm = parent / 'Windows ARM Evaluation.macopenvm'
    base = ['create', '--guest', 'windows11-arm64', '--media', str(MEDIA)]
    failures = [('unknown-guest', ['create', '--guest', 'unknown']),
                ('shared-network', base + ['--network', 'shared']),
                ('linux-kernel-mix', base + ['--kernel', '/private/tmp/not-a-kernel']),
                ('comma-directory', base)]
    for label, arguments in failures:
        destination = parent / (label + (',unsupported' if label == 'comma-directory' else ''))
        run(cli, evidence, label, arguments + ['--directory', str(destination)], expected=1)
        if destination.exists() or destination.is_symlink():
            raise ValueError('Rejected creation mutated its destination')
    output = run(cli, evidence, 'create', base + ['--directory', str(vm)])
    configuration = json.loads(output)
    saved = read_json(vm / 'configuration.json', 16384)
    if saved != configuration:
        raise ValueError('CLI creation differs from actual registration')
    if (configuration['guest'] != 'windows11' or configuration['backend'] != 'qemuHVF'
            or configuration['architecture'] != 'arm64' or configuration['boot'] != 'efi'
            or configuration['network'] != 'disconnected'
            or configuration['cpuCount'] != 2 or configuration['memoryBytes'] != 4 << 30
            or configuration['diskBytes'] != 64 << 30):
        raise ValueError('Registered Windows defaults changed')
    disk = vm / configuration['diskFile']
    info = disk.lstat()
    if info.st_size != 64 << 30 or info.st_blocks != 0:
        raise ValueError('Initial disk is not an empty sparse disk')
    if (vm / 'uefi-vars.json').stat().st_size != 0 or list((vm / 'tpm-state').iterdir()):
        raise ValueError('File-only creation initialized guest state')
    before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
              [vm / 'configuration.json', vm / 'qemu-platform.json', vm / 'uefi-vars.json']}
    run(cli, evidence, 'validate', ['validate', '--directory', str(vm)])
    run(cli, evidence, 'inspect', ['inspect', '--directory', str(vm)])
    after = {name: hashlib.sha256((vm / name).read_bytes()).hexdigest() for name in before}
    if before != after or (vm / 'runtime-intent.json').exists() or (vm / '.runtime').exists():
        raise ValueError('File-only validation changed registration or started runtime')
    descriptor = os.open(vm / 'writer.lock', os.O_RDWR | os.O_NOFOLLOW)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = {'scope': 'actual-normal-cli-windows-creation-and-validation', 'status': 'passed',
                  'vmDirectory': str(vm), 'vmID': configuration['id'], 'cliSHA256': build['cliSHA256'],
                  'sparseDiskBytes': info.st_size, 'sparseAllocatedBlocks': info.st_blocks,
                  'configurationPreserved': True, 'platformRecordPreserved': True,
                  'independentWriterAvailable': True, 'rejectedInputsBeforeCreation': 4,
                  'keysGenerated': False, 'guestStarted': False, 'networkExposed': False,
                  'windowsInstallationVerified': False}
        save(evidence / 'result.json', result)
        print(json.dumps({'evidence': str(evidence), 'result': result}), flush=True)
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    main()
