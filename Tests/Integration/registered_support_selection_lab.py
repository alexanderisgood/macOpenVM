#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Opt-in actual normal CLI support selection; no guest, app, driver or network starts.

All fresh VMs/candidates/backups survive success or failure. Sparse zero-block
disk contents are proved by unchanged identity/size/zero allocation, not a 64GiB read.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import uuid

from registered_windows_creation_lab import ROOT, MEDIA, run
from runtime_worker_lab import read_json, save

ISO = ROOT / '.lab/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso'
ISO_SHA = '7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394'


def require(value, code):
    if not value:
        raise ValueError(code)


def protected(vm, configuration):
    result = {}
    for name in (configuration['diskFile'], 'qemu-platform.json', 'uefi-vars.json', 'tpm-state', 'writer.lock'):
        path = vm / name
        info = path.lstat()
        directory = name == 'tpm-state'
        require((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
                and info.st_uid == os.geteuid() and (directory or info.st_nlink == 1)
                and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600), 'protected-type-mode-owner')
        row = {key: getattr(info, key) for key in ('st_dev', 'st_ino', 'st_size', 'st_mode', 'st_uid', 'st_gid', 'st_nlink', 'st_blocks')}
        if directory:
            row['members'] = sorted(p.name for p in path.iterdir())
            require(not row['members'], 'tpm-must-stay-empty')
        elif name == configuration['diskFile']:
            require(info.st_size == configuration['diskBytes'] and info.st_blocks == 0, 'disk-must-stay-sparse-zero')
        else:
            require(info.st_size <= 8192, 'protected-file-bound')
            row['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        result[name] = row
    return result


def selection(cli, evidence, vm, before, label, image):
    original = (vm / 'configuration.json').read_bytes()
    names = set(p.name for p in vm.iterdir())
    argv = ['attach-support-media', '--directory', str(vm), '--support-media', str(image)] if image else ['detach-support-media', '--directory', str(vm)]
    output = json.loads(run(cli, evidence, label, argv))
    saved = read_json(vm / 'configuration.json', 16384)
    require(output['changed'] is True and output['configuration'] == saved, 'selection-registration-result')
    backup = output['backupFile']
    require(isinstance(backup, str) and re.fullmatch(r'configuration-support-media-backup-[0-9a-f-]{36}\.json', backup), 'exact-private-backup-name')
    require((vm / backup).read_bytes() == original and stat.S_IMODE((vm / backup).lstat().st_mode) == 0o600, 'original-byte-backup')
    require(set(p.name for p in vm.iterdir()) == names | {backup}, 'only-support-backup-added')
    without = lambda c: {k: v for k, v in c.items() if k != 'supportMedia'}
    require(without(saved) == without(before) and saved.get('supportMedia') == (str(image) if image else None), 'only-support-field-changed')
    require(not any((vm / name).exists() or (vm / name).is_symlink() for name in ('runtime.json', 'runtime-intent.json', '.runtime')), 'no-runtime-state')
    return saved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--cli', type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        raise SystemExit('SKIP: explicit file-only support selection proof required')
    cli = args.cli
    require(cli.parent.parent == ROOT / '.lab' and cli.name == 'macopenvm'
            and re.fullmatch(r'linux-desktop-artifacts-[0-9a-f]{32}', cli.parent.name)
            and cli == cli.resolve(), 'immutable-private-cli-scope')
    build = read_json(cli.parent / 'build-record.json', 262144)
    info = cli.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
            and stat.S_IMODE(info.st_mode) == 0o500 and 0 < info.st_size <= 128 << 20
            and hashlib.sha256(cli.read_bytes()).hexdigest() == build['cliSHA256']
            and build['primaryApplicationChanged'] is False, 'immutable-cli-provenance')
    image = ISO.lstat()
    require(stat.S_ISREG(image.st_mode) and image.st_nlink == 1 and stat.S_IMODE(image.st_mode) == 0o400
            and image.st_size == 921600 and hashlib.sha256(ISO.read_bytes()).hexdigest() == ISO_SHA, 'reviewed-carrier-pin')
    os.umask(0o077)
    token = uuid.uuid4().hex
    parent = Path('/private/tmp') / ('mvo-support-selection-' + token)
    parent.mkdir(mode=0o700)
    evidence = ROOT / '.lab' / ('registered-support-selection-' + token)
    evidence.mkdir(mode=0o700)
    save(evidence / 'inputs.json', {'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                 'cliSHA256': build['cliSHA256'], 'carrierSHA256': ISO_SHA})
    base = ['create', '--guest', 'windows11-arm64', '--media', str(MEDIA)]
    vm = parent / 'Approved.macopenvm'
    original = json.loads(run(cli, evidence, 'create-approved', base + ['--directory', str(vm)]))
    original_bytes = (vm / 'configuration.json').read_bytes()
    immutable = protected(vm, original)
    attached = selection(cli, evidence, vm, original, 'attach-approved', ISO)
    run(cli, evidence, 'validate-attached', ['validate', '--directory', str(vm)])
    require(protected(vm, attached) == immutable, 'attach-protected-state-changed')
    detached = selection(cli, evidence, vm, attached, 'detach-approved', None)
    run(cli, evidence, 'validate-detached', ['validate', '--directory', str(vm)])
    require(protected(vm, detached) == immutable and (vm / 'configuration.json').read_bytes() == original_bytes, 'detach-original-state-changed')
    candidate = parent / 'unreviewed.iso'
    candidate.write_bytes(bytes(2048)); candidate.chmod(0o400)
    negative = parent / 'Unreviewed.macopenvm'
    rejected = json.loads(run(cli, evidence, 'create-unreviewed', base + ['--directory', str(negative)]))
    negative_protected = protected(negative, rejected)
    retained = selection(cli, evidence, negative, rejected, 'attach-unreviewed', candidate)
    candidate_config = (negative / 'configuration.json').read_bytes()
    candidate_names = set(p.name for p in negative.iterdir())
    run(cli, evidence, 'validate-unreviewed', ['validate', '--directory', str(negative)], expected=1)
    require(protected(negative, retained) == negative_protected and (negative / 'configuration.json').read_bytes() == candidate_config
            and set(p.name for p in negative.iterdir()) == candidate_names, 'rejection-did-not-preserve-candidate')
    descriptor = os.open(vm / 'writer.lock', os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = {'scope': 'actual-normal-cli-reviewed-support-selection-file-only', 'status': 'passed',
                  'approvedVM': str(vm), 'unreviewedVM': str(negative), 'protectedFileBytesAndInodesPreserved': True,
                  'originalConfigurationBytesRecovered': True, 'unreviewedValidationRejectedAndCandidateRetained': True,
                  'independentWriterAvailable': True, 'guestStarted': False, 'appStarted': False,
                  'networkExposed': False, 'driverExecuted': False, 'endpointsCreated': False}
        save(evidence / 'result.json', result)
        print(json.dumps({'evidence': str(evidence), 'result': result}), flush=True)
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    main()
