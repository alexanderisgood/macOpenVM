#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit private A/B development build/signing; never execute an agent or guest."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import uuid

import agent_package_lab as publisher

ROOT = Path(__file__).resolve().parents[2]
QUALIFIED = ROOT / '.lab/linux-agent-generation-build-4de17efd9fa9448bbf91982ed0e4481c'
SYSROOT = ROOT / '.lab/linux-tls-sysroot-6056594b16a1422c80ca4540a6d3603f/sysroot'
CLANG = Path('/opt/homebrew/Cellar/llvm/22.1.8/bin/clang-22')
LLD = ROOT / '.lab/windows-platform-a77101301bb14ba085a3a6e4b4f070ab/tools/lld22/lld@22/22.1.8/bin/lld'
OPENSSL = Path('/opt/homebrew/Cellar/openssl@3/3.6.4/bin/openssl')
CLI = ROOT / '.lab/linux-desktop-artifacts-4c950210214848099c7d3826374c80d7/macopenvm'
PINS = {
    CLANG: '305697d3868243dca6e4aabf4f628df7de135d701eb4fd78f6a5d7528fef4395',
    LLD: '7f629593760ab23657f57ad6b996b6d38c1ea922a5bcd02b4b27c3b5364d1f8c',
    CLI: 'aaed63139b17eb5ceb2cf5acac9204b5712116ba0fdf96bd02fe5c2b036f5f13',
    ROOT / 'GuestAgent/Linux/setup.sh': '60c3a86f097e547faf73fed0466444d63eba3657eabc6390fa038545c89524d8',
    ROOT / 'GuestAgent/Linux/macopenvm-agent.initd': '53f4bf75e886e3a7741a91e5c6397a8538f267dfcbf40ec934f12e3d360713fb',
    ROOT / 'GuestAgent/Linux/transport_tls_lab.c': '298fba09cbc48d2a19fe1229c81d58423843d9e098b051ce636c94414c6ef6f4',
    ROOT / 'GuestAgent/Protocol/generated/agent_v1.h': 'ea3d47363e7759693b7043ce609100b372daac749c71018189c7be042207d524',
    ROOT / 'Tests/Integration/agent_package_lab.py': 'a68876eaf40636928f9bdb9cef33a231bdfe608d73c4c9bbb7476356170e656e',
    ROOT / 'GuestAgent/Host/AgentPackageVerifier.swift': 'd31f0a29d39c75248dd3d589a02f5949b9269c07d583b976c6809f32181c29ba',
}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def plain_file(path, maximum=536870912):
    value = path.lstat()
    require(stat.S_ISREG(value.st_mode) and value.st_nlink == 1
            and value.st_uid in (0, os.geteuid()) and not value.st_mode & 0o022
            and 0 <= value.st_size <= maximum
            and (value.st_size > 0 or path.is_relative_to(SYSROOT)), 'Pinned input metadata changed')
    return digest(path)


def save(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def elf_inspect(path):
    data = path.read_bytes()
    require(data[:6] == b'\x7fELF\x02\x01' and len(data) < 16777216, 'ELF encoding differs')
    header = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    require(header[1] == 3 and header[2] == 183 and header[4] != 0
            and header[9] == 56 and 0 < header[10] <= 64, 'ARM64 PIE header differs')
    programs = []
    for index in range(header[10]):
        offset = header[5] + index * header[9]
        require(offset + 56 <= len(data), 'Program header bound')
        row = struct.unpack_from('<IIQQQQQQ', data, offset)
        require(row[2] + row[5] <= len(data), 'Program file bound')
        programs.append(row)
    interpreter = [data[p[2]:p[2] + p[5]] for p in programs if p[0] == 3]
    require(interpreter == [b'/lib/ld-musl-aarch64.so.1\0'], 'Interpreter differs')
    stacks = [p for p in programs if p[0] == 0x6474e551]
    require(len(stacks) == 1 and not stacks[0][1] & 1
            and any(p[0] == 0x6474e552 for p in programs), 'Stack/RELRO differs')
    dynamic = [p for p in programs if p[0] == 2]
    require(len(dynamic) == 1 and dynamic[0][5] <= 65536, 'Dynamic bound')
    tags = []
    for offset in range(dynamic[0][2], dynamic[0][2] + dynamic[0][5], 16):
        tag, value = struct.unpack_from('<QQ', data, offset)
        if tag == 0:
            break
        tags.append((tag, value))
    addresses = [v for t, v in tags if t == 5]
    sizes = [v for t, v in tags if t == 10]
    require(len(addresses) == len(sizes) == 1 and sizes[0] <= 65536, 'String table bound')
    loads = [p for p in programs if p[0] == 1 and p[3] <= addresses[0] < p[3] + p[5]]
    require(len(loads) == 1, 'String table mapping')
    start = loads[0][2] + addresses[0] - loads[0][3]
    strings = data[start:start + sizes[0]]
    require(len(strings) == sizes[0], 'String table truncated')
    needed = []
    for tag, offset in tags:
        if tag == 1:
            require(offset < len(strings) and b'\0' in strings[offset:], 'Import bound')
            needed.append(strings[offset:strings.index(0, offset)].decode('ascii'))
    require(set(needed) == {'libssl.so.3', 'libcrypto.so.3', 'libc.musl-aarch64.so.1'}
            and len(needed) == 3
            and any((t == 30 and v & 8) or (t == 0x6ffffffb and v & 1) for t, v in tags), 'Native imports/bind-now differ')
    return {'elfMachine': 'AArch64', 'type': 'PIE', 'entry': header[4], 'needed': needed,
            'interpreter': interpreter[0][:-1].decode(), 'nonExecutableStack': True,
            'relro': True, 'bindNow': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    if not args.run:
        raise SystemExit('SKIP: explicit private development build/signing required')
    os.umask(0o077)
    qualified = json.loads((QUALIFIED / 'result.json').read_bytes())
    require(qualified['status'] == 'static-passed-not-executed', 'Qualified static recipe differs')
    expected = dict(PINS)
    expected.update({SYSROOT / name: pin for name, pin in qualified['sysrootRegularFiles'].items()})
    expected.update({Path(name): pin for name, pin in qualified['loaderRegularFiles'].items()})
    # Signing uses this exact local tool, never an ambient PATH alternative.
    expected[OPENSSL] = plain_file(OPENSSL)
    expected[QUALIFIED / 'result.json'] = plain_file(QUALIFIED / 'result.json', 262144)
    expected[CLI.parent / 'build-record.json'] = plain_file(CLI.parent / 'build-record.json', 262144)
    expected[Path(__file__).absolute()] = plain_file(Path(__file__).absolute(), 65536)
    build_record = json.loads((CLI.parent / 'build-record.json').read_bytes())
    require(build_record['cliSHA256'] == PINS[CLI]
            and any(row['path'] == 'GuestAgent/Host/AgentPackageVerifier.swift'
                    and row['sha256'] == PINS[ROOT / row['path']] for row in build_record['sources']['files']),
            'Current CLI verifier source association differs')
    for path, pin in expected.items():
        require(plain_file(path) == pin, 'Retained build input bytes changed')
    source_links = {str(p.relative_to(SYSROOT)): os.readlink(p) for p in SYSROOT.rglob('*') if p.is_symlink()}
    for name, target in source_links.items():
        require(not Path(target).is_absolute() and (SYSROOT / name).resolve().is_relative_to(SYSROOT), 'Sysroot alias escapes')
    build = Path('/private/tmp') / ('mvo-linux-retirement-build-' + uuid.uuid4().hex)
    build.mkdir(mode=0o700)
    save(build / 'build-recipe.py', Path(__file__).read_bytes())
    operations = []
    environment = qualified['environment']
    for operation in qualified['operations']:
        if operation['label'] == 'unsupported-patch2-refused':
            continue
        argv = [value.replace(str(QUALIFIED), str(build)) for value in operation['argv']]
        require(argv[0] in (str(CLANG), str(LLD)), 'Recipe tool differs')
        result = subprocess.run(argv, cwd=build, env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=60, close_fds=True)
        save(build / (operation['label'] + '.stdout'), result.stdout)
        save(build / (operation['label'] + '.stderr'), result.stderr)
        operations.append({'label': operation['label'], 'argv': argv, 'exit': result.returncode,
                           'stdoutBytes': len(result.stdout), 'stderrBytes': len(result.stderr)})
        require(result.returncode == 0 and not result.stderr, 'Strict build failed; diagnostics retained')
    versions = []
    for patch in (0, 1):
        binaries = [build / f'patch{patch}-trial{trial}.elf' for trial in (1, 2)]
        require(binaries[0].read_bytes() == binaries[1].read_bytes(), 'Repeat build differs')
        inspections = [elf_inspect(binary) for binary in binaries]
        for binary in binaries:
            binary.chmod(0o500)
        versions.append({'version': f'0.1.{patch}', 'binary': str(binaries[0]),
                         'bytes': binaries[0].stat().st_size, 'sha256': digest(binaries[0]),
                         'identicalSecondBuild': True, 'elf': inspections[0]})
    package_parent = Path('/private/tmp') / ('mvo-linux-retirement-packages-' + uuid.uuid4().hex)
    package_parent.mkdir(mode=0o700)
    original_path = os.environ.get('PATH')
    os.environ['PATH'] = str(OPENSSL.parent) + ':/usr/bin:/bin'
    try:
        payloads, issuer = publisher.publish_generations(Path(versions[0]['binary']), Path(versions[1]['binary']), package_parent)
    finally:
        if original_path is None:
            os.environ.pop('PATH', None)
        else:
            os.environ['PATH'] = original_path
    require(set(p.name for p in package_parent.iterdir()) == {'payload-a', 'payload-b'}, 'Private signing material remains')
    verifications = []
    for label, payload in zip(('A', 'B'), payloads):
        argv = [str(CLI), 'verify-agent-package-lab', '--directory', str(payload), '--issuer', issuer]
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, close_fds=True)
        save(build / ('verify-' + label + '.stdout'), result.stdout)
        save(build / ('verify-' + label + '.stderr'), result.stderr)
        require(result.returncode == 0 and not result.stderr, 'Native host package verification failed')
        value = json.loads(result.stdout)
        require(value['filesVerified'] == 3 and value['issuerSHA256'] == issuer
                and value['manifestSHA256'] == digest(payload / 'SHA256SUMS')
                and digest(payload / 'setup.sh') == PINS[ROOT / 'GuestAgent/Linux/setup.sh'], 'Verified package differs')
        verifications.append(dict(value, payload=str(payload)))
    altered = build / 'changed-payload'
    shutil.copytree(payloads[0], altered)
    changed = bytearray((altered / 'agent').read_bytes()); changed[0] ^= 1; (altered / 'agent').write_bytes(changed)
    for label, payload, pin in [('wrong-issuer', payloads[0], '0' * 64), ('changed-agent', altered, issuer)]:
        result = subprocess.run([str(CLI), 'verify-agent-package-lab', '--directory', str(payload), '--issuer', pin],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, close_fds=True)
        save(build / (label + '.stdout'), result.stdout); save(build / (label + '.stderr'), result.stderr)
        require(result.returncode == 1 and not result.stdout and len(result.stderr) <= 1024, 'Negative verification did not refuse')
    for path, pin in expected.items():
        require(plain_file(path) == pin, 'Build/signing inputs changed')
    require(source_links == {str(p.relative_to(SYSROOT)): os.readlink(p) for p in SYSROOT.rglob('*') if p.is_symlink()}, 'Sysroot links changed')
    result = {'schemaVersion': 1, 'scope': 'private-development-current-manager-retirement-packages',
              'status': 'built-signed-host-verified-not-executed', 'operations': operations,
              'versions': versions, 'packages': verifications, 'issuerSHA256': issuer,
              'privateIssuerDeleted': True, 'wrongIssuerRejected': True, 'changedAgentRejected': True,
              'managerBytes': (ROOT / 'GuestAgent/Linux/setup.sh').stat().st_size,
              'inputSHA256': {str(p): pin for p, pin in expected.items()}, 'sysrootSymlinks': source_links,
              'inputsPreserved': True, 'agentExecuted': False, 'guestStarted': False,
              'releaseSigningQualified': False, 'nativeRetirementQualified': False}
    save(build / 'result.json', json.dumps(result, indent=2, sort_keys=True).encode() + b'\n')
    print(json.dumps({'build': str(build), 'resultSHA256': digest(build / 'result.json'),
                      'packages': verifications, 'issuerSHA256': issuer, 'privateIssuerDeleted': True}), flush=True)


if __name__ == '__main__':
    main()
