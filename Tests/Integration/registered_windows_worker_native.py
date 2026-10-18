#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicitly authorized parent for ONE fresh shared-network Windows fixture; no guest input.

No implicit stop/force/quit/signal/cleanup on timeout, EOF, observer loss or error.
The actual worker Popen remains retained until reaped. Routes/PIDs never mint owners.
"""
import argparse
import ctypes
import errno
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

from runtime_worker_lab import Client, ROOT, save, writer_probe

VM_ID = '7D5C2CD4-E2E4-40DF-8535-7C75E691D728'
DIRECTORY = Path('/private/tmp/mvo-network-preparation-4ba67433cd724be2813e72de72da44dd/Windows Network Evaluation.macopenvm')
CLI = ROOT / '.lab/linux-desktop-artifacts-568047a449a146889d0bd1407d3c83bd/macopenvm'
CLI_SHA = '7d457ded22ef5b1dc4fdf2196edeccf9debe1ec5ad593e70d50cd44156c99c4f'
CARRIER = ROOT / '.lab/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso'
CARRIER_SHA = '7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394'
COLD_BASELINE = ROOT / '.lab/registered-windows-install-native-evidence-ffff1f5291a04b7895fdee27d53792cc/cold-boot-baseline.json'
COLD_SHA = '60a912273ee51077f423943beca0a11d403e48cedf1d2e21e2463050ba2b0839'
PRIOR_SESSION = 'CD5CC1A6-FF5A-4FEC-8578-B1FF0AF6C495'
COMPILED = ('Backends/BackendAPI/Model.swift', 'Backends/BackendAPI/SharedNetworkConfigurationPermission.swift',
            'Core/NetworkSettings.swift', 'Storage/NetworkConfiguration.swift', 'Storage/DiskGrowth.swift',
            'CLI/Main.swift', 'CLI/RegisteredWindowsWorker.swift', 'CLI/RegisteredWindowsRuntimeStore.swift',
            'CLI/QemuWorkerLab.swift', 'Core/RecordedRuntimeOwner.swift', 'Core/RuntimeWorkerCoordinator.swift',
            'Core/VMController.swift', 'Storage/RuntimeIntent.swift', 'Storage/RuntimeSettlement.swift',
            'Storage/VMFiles.swift', 'Backends/Qemu/QemuRegisteredPlan.swift', 'Backends/Qemu/QemuRegisteredResources.swift',
            'Backends/Qemu/QemuRegisteredCatalog.swift', 'Backends/Qemu/QemuRegisteredIO.swift',
            'Backends/Qemu/QemuRegisteredSupportImage.swift',
            'Backends/Qemu/QemuMachineBackend.swift', 'Backends/Qemu/OwnedProcess.swift', 'Backends/Qemu/LeaseSpawn.swift')


def require(value, code):
    if not value:
        raise ValueError(code)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def plain_path(path):
    require(path.is_absolute() and path == Path(os.path.abspath(path)) and len(str(path)) <= 4096, 'path-invalid')
    current = Path('/')
    for part in path.parts[1:]:
        current /= part
        info = current.lstat()
        require(not stat.S_ISLNK(info.st_mode) and (current == path or stat.S_ISDIR(info.st_mode)), 'path-indirect')
    return path


def private_directory(path):
    plain_path(path); info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
            and stat.S_IMODE(info.st_mode) == 0o700, 'directory-not-private')


def read_private(path, limit):
    plain_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == 0o600 and 0 < before.st_size <= limit, 'private-file-invalid')
        data = stream.read(limit + 1)
        require(len(data) == before.st_size and identity(before) == identity(os.fstat(stream.fileno())) == identity(path.lstat()), 'private-file-changed')
    return data


def read_record(path, limit=4096):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'duplicate-record-field'); value[key] = item
        return value
    return json.loads(read_private(path, limit), object_pairs_hook=unique)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def admit(cli, directory, cold=None):
    require(cli == CLI and directory == DIRECTORY, 'only-reviewed-fresh-fixture')
    plain_path(cli); private_directory(directory); plain_path(cli.parent)
    info = cli.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
            and stat.S_IMODE(info.st_mode) == 0o500 and sha(cli) == CLI_SHA, 'cli-pin-invalid')
    built = read_record(cli.parent / 'build-record.json', 262144)
    require(built.get('cliSHA256') == CLI_SHA, 'build-record-invalid')
    rows = {row['path']: row['sha256'] for row in built['sources']['files']}
    require(all(rows.get(name) == sha(ROOT / name) for name in COMPILED), 'compiled-sources-changed')
    if cold is None: fresh_blank_state(directory)
    else: installed_state(directory, cold)
    writer_probe(directory, False)
    return rows, sha(directory / 'configuration.json'), sha(directory / 'qemu-platform.json')


def verify_carrier(path=CARRIER, expected_sha=CARRIER_SHA):
    plain_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == 0o400 and before.st_size == 921600, 'carrier-file-invalid')
        data = stream.read(921601)
        require(len(data) == 921600 and identity(before) == identity(os.fstat(stream.fileno())) == identity(path.lstat())
                and hashlib.sha256(data).hexdigest() == expected_sha, 'carrier-bytes-changed')


def fresh_blank_state(directory):
    private_directory(directory)
    configuration = read_record(directory / 'configuration.json', 65536)
    require(configuration['id'] == VM_ID and configuration['guest'] == 'windows11'
            and configuration['backend'] == 'qemuHVF' and configuration['architecture'] == 'arm64'
            and configuration['boot'] == 'efi' and configuration['network'] == 'shared'
            and configuration['diskBytes'] == 64 * 2**30
            and configuration.get('supportMedia') == str(CARRIER), 'registration-invalid')
    platform = read_record(directory / 'qemu-platform.json', 8192)
    require(platform['vmID'] == VM_ID and platform['profile'] == 'experimental-windows-arm64-offline-v1', 'platform-invalid')
    require(Path(configuration['diskFile']).name == configuration['diskFile'] and configuration['diskFile'] not in ('.', '..'), 'disk-path-invalid')
    disk = directory / configuration['diskFile']; plain_path(disk); value = disk.lstat()
    require(stat.S_ISREG(value.st_mode) and value.st_uid == os.geteuid() and value.st_nlink == 1
            and stat.S_IMODE(value.st_mode) == 0o600 and value.st_size == 64 * 2**30 and value.st_blocks == 0, 'disk-not-new-blank')
    for name in ('runtime.json', 'runtime-intent.json'):
        require(not (directory / name).exists() and not (directory / name).is_symlink(), 'prior-runtime-refused')
    variables = directory / 'uefi-vars.json'; plain_path(variables); value = variables.lstat()
    require(stat.S_ISREG(value.st_mode) and value.st_uid == os.geteuid() and value.st_nlink == 1
            and stat.S_IMODE(value.st_mode) == 0o600 and value.st_size == 0, 'variables-not-fresh')
    tpm = directory / 'tpm-state'; private_directory(tpm); require(not list(tpm.iterdir()), 'tpm-not-fresh')
    verify_carrier()


def cold_mode_arguments(args):
    require(args.installed_cold_boot_evaluation and args.stopped_baseline == COLD_BASELINE
            and args.stopped_baseline_sha256 == COLD_SHA and not args.disposable_force_authorized, 'installed-mode-explicit-fixed-baseline-required')


def read_cold_baseline(path, expected_sha):
    require(path == COLD_BASELINE and expected_sha == COLD_SHA, 'fixed-cold-baseline-required')
    plain_path(path); fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno()); data = stream.read(32769)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == 0o400 and 0 < before.st_size <= 32768
                and len(data) == before.st_size and identity(before) == identity(os.fstat(stream.fileno())) == identity(path.lstat())
                and hashlib.sha256(data).hexdigest() == expected_sha, 'cold-baseline-file-invalid')
    def unique(pairs):
        value = {}
        for key, item in pairs: require(key not in value, 'duplicate-cold-field'); value[key] = item
        return value
    cold = json.loads(data, object_pairs_hook=unique)
    require(set(cold) == {'schemaVersion', 'scope', 'vmID', 'vmDirectory', 'priorSessionID', 'MAC', 'CLI_SHA256',
                         'configurationSHA256', 'platformSHA256', 'diskWholeContentHashVerified', 'assets', 'priorRecords'}
            and type(cold['schemaVersion']) is int and cold['schemaVersion'] == 1
            and cold['scope'] == 'fixed-installed-disc-free-cold-boot-baseline' and cold['vmID'] == VM_ID
            and cold['vmDirectory'] == str(DIRECTORY) and cold['priorSessionID'] == PRIOR_SESSION
            and cold['CLI_SHA256'] == CLI_SHA and cold['MAC'] == '02:7d:5c:2c:d4:e2'
            and cold['diskWholeContentHashVerified'] is False, 'cold-baseline-context-invalid')
    names = ['parent-terminal.json', 'worker-result.json', 'runtime.json', 'runtime-intent.json']
    require(type(cold['priorRecords']) is list and len(cold['priorRecords']) == 4, 'prior-receipts-invalid')
    prior = []
    for row, name in zip(cold['priorRecords'], names):
        require(set(row) == {'path', 'SHA256'} and row['path'] == str(path.parent / name), 'prior-receipt-path-invalid')
        payload = read_private(Path(row['path']), 4096); require(hashlib.sha256(payload).hexdigest() == row['SHA256'], 'prior-receipt-bytes-invalid')
        prior.append(json.loads(payload, object_pairs_hook=unique))
    validate_prior_normal(prior)
    return cold


def validate_prior_normal(prior):
    parent, producer, history, intent = prior
    require(parent['vmID'] == producer['vmID'] == intent['vmID'] == VM_ID
            and all(record['sessionID'] == PRIOR_SESSION for record in prior)
            and parent['actualParentReaped'] is True and type(parent['workerExit']) is int and parent['workerExit'] == 0
            and parent['failedAdvisory'] is False and parent['forced'] is False and parent['producerResultQualified'] is True
            and producer['schemaVersion'] == 1 and type(producer['schemaVersion']) is int
            and producer['scope'] == 'macopenvm-registered-qemu-runtime-result'
            and producer['qemuExit'] == producer['tpmExit'] == 0 and type(producer['qemuExit']) is int and type(producer['tpmExit']) is int
            and producer['qemuSignalled'] is False and producer['tpmSignalled'] is False
            and all(producer[key] is True for key in ('drainsFinished', 'resourcesRevalidated', 'platformStateFlushed', 'runtimeIntentSettled'))
            and history['snapshot']['state'] == 'stopped' and history['snapshot']['backendActive'] is False
            and parent['outcome'] == producer['outcome'] == history['snapshot']['outcome'] == 'guestStopped'
            and intent['state'] == 'settled', 'prior-normal-settlement-invalid')


def installed_asset(path, disk=False):
    plain_path(path); fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == 0o600 and (before.st_size == 64 * 2**30 if disk else 0 <= before.st_size <= 16777216), 'installed-asset-invalid')
        data = stream.read(65536 if disk else 16777217)
        require(len(data) == (65536 if disk else before.st_size)
                and identity(before) == identity(os.fstat(stream.fileno())) == identity(path.lstat()), 'installed-asset-changed')
    return dict(device=before.st_dev, inode=before.st_ino, bytes=before.st_size, mode=stat.S_IMODE(before.st_mode),
                uid=before.st_uid, links=before.st_nlink, blocks=before.st_blocks, mtimeNS=before.st_mtime_ns,
                **{('prefixSHA256' if disk else 'SHA256'): hashlib.sha256(data).hexdigest()})


def installed_state(directory, cold, *, before_start=True):
    private_directory(directory); private_directory(directory / 'tpm-state')
    require(set(p.name for p in (directory / 'tpm-state').iterdir()) == {'.lock', 'tpm2-00.permall'}, 'installed-tpm-members-invalid')
    require(set(cold['assets']) == {'disk.raw', 'qemu-platform.json', 'uefi-vars.json', 'writer.lock', 'tpm-state/.lock', 'tpm-state/tpm2-00.permall'}, 'installed-assets-invalid')
    fd = os.open(directory / 'writer.lock', os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        c = read_record(directory / 'configuration.json', 65536)
        require(c['id'] == VM_ID and c['network'] == 'shared' and c['macAddress'] == cold['MAC']
                and c['diskFile'] == 'disk.raw' and c.get('installationMedia') is None and c.get('supportMedia') is None
                and sha(directory / 'configuration.json') == cold['configurationSHA256']
                and sha(directory / 'qemu-platform.json') == cold['platformSHA256'], 'disc-free-installed-configuration-invalid')
        for name, expected in cold['assets'].items():
            actual = installed_asset(directory / name, disk=name == 'disk.raw')
            require(all(type(expected[key]) is int for key in ('device', 'inode', 'bytes', 'mode', 'uid', 'links', 'blocks', 'mtimeNS')), 'installed-asset-schema-invalid')
            if before_start: require(actual == expected, 'stopped-installed-asset-drift')
            else: require(all(actual[key] == expected[key] for key in ('device', 'uid', 'mode', 'links'))
                          and (name == 'tpm-state/tpm2-00.permall' or actual['inode'] == expected['inode']), 'persistent-asset-identity-changed')
        if before_start:
            for row in cold['priorRecords'][2:]:
                require(sha(directory / Path(row['path']).name) == row['SHA256'], 'prior-current-record-drift')
    finally: os.close(fd)


def current_route(worker, directory, run, endpoints, expected_session=None, *, recovery=False, cold=None):
    require(worker.poll() is None, 'actual-worker-terminal')
    intent = read_record(directory / 'runtime-intent.json')
    if cold is not None and intent.get('sessionID') == PRIOR_SESSION:
        require(intent.get('vmID') == VM_ID and intent.get('state') == 'settled'
                and sha(directory / 'runtime-intent.json') == cold['priorRecords'][3]['SHA256'], 'prior-intent-changed')
        raise FileNotFoundError('new-owner-not-yet-published')
    require(set(intent) == {'schemaVersion', 'vmID', 'sessionID', 'state'}
            and type(intent['schemaVersion']) is int and intent['schemaVersion'] == 1
            and intent['vmID'] == VM_ID and intent['state'] == 'unsettled', 'current-intent-invalid')
    session = intent['sessionID']; require(str(uuid.UUID(session)).upper() == session.upper(), 'session-invalid')
    require(expected_session is None or session == expected_session, 'session-changed')
    route = {'vmID': VM_ID, 'sessionID': session, 'socket': str(endpoints / 'worker.sock')}
    path = run / 'worker.json'
    if not recovery and (path.exists() or path.is_symlink()):
        value = read_record(path)
        require(set(value) == {'schemaVersion', 'scope', 'vmID', 'sessionID', 'socket'}
                and type(value['schemaVersion']) is int and value['schemaVersion'] == 1
                and value['scope'] == 'macopenvm-registered-qemu-worker-route'
                and all(value[key] == route[key] for key in route), 'published-owner-mismatch')
    # The locator is correlated against this retained actual Popen's chosen
    # endpoint/registration and the real IPC peer; it never reconstructs a permit.
    peer = Client(route)
    try:
        status = peer.request()
    finally:
        peer.close()
    writer_probe(directory, True)
    return route, status


def control(worker, directory, run, endpoints, session, command, force_allowed, cold=None):
    require(command in ('normal-stop', 'force-stop'), 'unknown-control')
    require(command != 'force-stop' or force_allowed, 'explicit-disposable-force-required')
    route, _ = current_route(worker, directory, run, endpoints, session, recovery=True, cold=cold)
    peer = Client(route)
    try:
        before = peer.request()
        require(before['ownership'] == 0 and before['backendActive'] and not before['operationPending'], 'control-owner-not-ready')
        require(command != 'normal-stop' or before['state'] == 2 and before['error'] == 0, 'normal-stop-not-ready')
        return peer.request(4 if command == 'normal-stop' else 3, before['revision'])
    finally:
        peer.close()


def display_route(run, endpoints, session):
    value = read_record(run / 'display.json')
    require(set(value) == {'schemaVersion', 'scope', 'vmID', 'sessionID', 'controlSocket', 'displaySocket',
                          'parentDevice', 'parentInode', 'socketDevice', 'socketInode'}
            and type(value['schemaVersion']) is int and value['schemaVersion'] == 1
            and value['scope'] == 'macopenvm-registered-qemu-display-route' and value['vmID'] == VM_ID
            and value['sessionID'] == session and value['controlSocket'] == str(endpoints / 'worker.sock')
            and value['displaySocket'] == str(endpoints / 'vnc.sock'), 'display-route-invalid')
    private_directory(endpoints)
    parent = endpoints.lstat(); endpoint = (endpoints / 'vnc.sock').lstat()
    require(stat.S_ISSOCK(endpoint.st_mode) and endpoint.st_uid == os.geteuid() and endpoint.st_nlink == 1
            and endpoint.st_mode & 0o077 == 0 and endpoint.st_mode & 0o600 == 0o600
            and endpoint.st_mode & 0o7000 == 0
            and (parent.st_dev, parent.st_ino, endpoint.st_dev, endpoint.st_ino)
            == (value['parentDevice'], value['parentInode'], value['socketDevice'], value['socketInode']), 'display-endpoint-changed')
    return value


def receive(stream, size, deadline):
    require(0 <= size <= 64 * 2**20, 'rfb-read-bound')
    output = bytearray()
    while len(output) < size:
        remaining = deadline - time.monotonic(); require(remaining > 0, 'rfb-deadline')
        stream.settimeout(remaining); chunk = stream.recv(size - len(output)); require(chunk, 'rfb-eof'); output.extend(chunk)
    return bytes(output)


def raw_frame(stream, deadline):
    require(receive(stream, 12, deadline) == b'RFB 003.008\n', 'rfb-version')
    stream.sendall(b'RFB 003.008\n'); count = receive(stream, 1, deadline)[0]
    require(0 < count <= 32 and 1 in receive(stream, count, deadline), 'rfb-security')
    stream.sendall(b'\x01'); require(receive(stream, 4, deadline) == bytes(4), 'rfb-security-result')
    stream.sendall(b'\x01'); header = receive(stream, 24, deadline)
    width, height = struct.unpack('>HH', header[:4]); name_bytes = struct.unpack('>I', header[20:24])[0]
    require(0 < width <= 8192 and 0 < height <= 8192 and width * height <= 16777216 and name_bytes <= 4096, 'rfb-dimensions')
    receive(stream, name_bytes, deadline)  # Server name is never logged/exported.
    pixel = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    stream.sendall(bytes(4) + pixel); stream.sendall(b'\x02\x00\x00\x01' + struct.pack('>i', 0))
    stream.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, width, height))
    require(receive(stream, 4, deadline) == b'\x00\x00\x00\x01', 'rfb-update-shape')
    x, y, w, h, encoding = struct.unpack('>HHHHi', receive(stream, 12, deadline))
    require((x, y, w, h, encoding) == (0, 0, width, height, 0), 'rfb-raw-full-frame-required')
    pixels = receive(stream, width * height * 4, deadline)
    rgb = bytearray(width * height * 3)
    rgb[0::3] = pixels[2::4]; rgb[1::3] = pixels[1::4]; rgb[2::3] = pixels[0::4]
    return width, height, b'P6\n%d %d\n255\n' % (width, height) + rgb


def observe_frame(value, before_input=None):
    path = Path(value['displaySocket'])
    def bound_endpoint():
        private_directory(path.parent); plain_path(path); parent = path.parent.lstat(); node = path.lstat()
        require(stat.S_ISSOCK(node.st_mode) and node.st_uid == os.geteuid() and node.st_nlink == 1
                and node.st_mode & 0o077 == 0 and node.st_mode & 0o600 == 0o600
                and node.st_mode & 0o7000 == 0
                and (parent.st_dev, parent.st_ino, node.st_dev, node.st_ino)
                == (value['parentDevice'], value['parentInode'], value['socketDevice'], value['socketInode']), 'rfb-route-node-changed')
    bound_endpoint()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(20); stream.connect(str(path))
        uid, gid = ctypes.c_uint(), ctypes.c_uint(); function = ctypes.CDLL(None, use_errno=True).getpeereid
        function.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        function.restype = ctypes.c_int
        require(function(stream.fileno(), ctypes.byref(uid), ctypes.byref(gid)) == 0 and uid.value == os.geteuid(), 'rfb-peer-uid')
        bound_endpoint()
        width, height, frame = raw_frame(stream, time.monotonic() + 20)
        bound_endpoint()
        if before_input is not None: before_input(stream, width, height, frame)
        return width, height, frame


KEYS = dict(space=0x20, tab=0xff09, **{'return': 0xff0d}, escape=0xff1b,
            up=0xff52, down=0xff54, left=0xff51, right=0xff53)


def navigation_packets(action, width, height, *, key=None, x=None, y=None):
    if action == 'key':
        require(key in KEYS, 'unknown-installer-key')
        return b'\x04\x01\0\0' + struct.pack('>I', KEYS[key]), b'\x04\0\0\0' + struct.pack('>I', KEYS[key])
    require(action == 'click' and type(x) is int and type(y) is int
            and 0 <= x < width and 0 <= y < height, 'click-outside-reviewed-frame')
    return struct.pack('>BBHH', 5, 1, x, y), struct.pack('>BBHH', 5, 0, x, y)


def navigate(worker, directory, run, endpoints, session, action, expected_sha, granted, *, key=None, x=None, y=None, cold=None):
    require(granted, 'installer-navigation-not-authorized')
    require(len(expected_sha) == 64 and all(c in '0123456789abcdef' for c in expected_sha), 'reviewed-frame-hash-invalid')
    require(action in ('key', 'click') and (action != 'key' or key in KEYS), 'unknown-installer-key')
    if action == 'click': require(type(x) is int and type(y) is int and x >= 0 and y >= 0, 'click-outside-reviewed-frame')
    route, state = current_route(worker, directory, run, endpoints, session, cold=cold)
    def healthy(value):
        return value['state'] == 2 and value['ownership'] == 0 and value['backendActive'] and not value['operationPending'] and value['error'] == 0
    require(route['vmID'] == VM_ID and route['sessionID'] == session and healthy(state), 'input-owner-not-current')
    display = display_route(run, endpoints, session)
    def input_on_observed_connection(stream, width, height, frame):
        require(hashlib.sha256(frame).hexdigest() == expected_sha, 'reviewed-frame-stale')
        press, release = navigation_packets(action, width, height, key=key, x=x, y=y)
        fresh, status = current_route(worker, directory, run, endpoints, session, cold=cold)
        require(fresh == route and healthy(status) and display_route(run, endpoints, session) == display, 'input-owner-not-current')
        try:
            stream.sendall(press); stream.sendall(release)
        except BaseException:
            try: stream.sendall(release)  # Only the same FD; never replay the action.
            except BaseException: pass
            raise
    observe_frame(display, before_input=input_on_observed_connection)
    result = dict(vmID=VM_ID, sessionID=session, action=action, reviewedFrameSHA256=expected_sha,
                  inputPacketsWritten=True, guestNavigationVerified=False)
    if action == 'key': result['key'] = key
    else: result.update(x=x, y=y)
    return result


def save_review_frame(evidence, width, height, frame):
    require(len(list(evidence.glob('frame-*.ppm'))) < 64, 'review-frame-count-bound')
    path = evidence / ('frame-' + uuid.uuid4().hex + '.ppm')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(frame); output.flush(); os.fsync(output.fileno())
    return dict(framePath=str(path), frameSHA256=hashlib.sha256(frame).hexdigest(), width=width, height=height)


def terminal(worker, directory, run, session, cold=None):
    exit_code = worker.wait()  # Only this genuine retained Popen, never a saved PID.
    if cold is not None and session is None and read_record(directory / 'runtime-intent.json').get('sessionID') == PRIOR_SESSION:
        require(not any((run / name).exists() or (run / name).is_symlink() for name in ('worker.json', 'display.json', 'result.json', 'recovery.json', 'qemu-stdout.log', 'tpm-stdout.log')), 'new-runtime-evidence-present')
        installed_state(directory, cold)
        return dict(actualParentReaped=True, workerExit=exit_code, vmID=VM_ID, sessionID=None,
                    producerResultQualified=False, failedAdvisory=True, drainsFinished=None,
                    runtimeIntentSettled=False, kernelWriterAvailable=True, outcome='failed', priorSessionPreserved=True)
    if not (directory / 'runtime-intent.json').exists() and not (directory / 'runtime-intent.json').is_symlink():
        require(session is None, 'previously-observed-owner-missing')
        for name in ('worker.json', 'display.json', 'result.json', 'recovery.json',
                     'qemu-stdout.log', 'qemu-stderr.log', 'tpm-stdout.log', 'tpm-stderr.log'):
            require(not (run / name).exists() and not (run / name).is_symlink(), 'pre-owner-runtime-evidence-present')
        fresh_blank_state(directory); writer_probe(directory, False)
        return {'actualParentReaped': True, 'workerExit': exit_code, 'vmID': VM_ID, 'sessionID': None,
                'guestStarted': False, 'blankStatePreserved': True, 'drainsFinished': None,
                'runtimeIntentSettled': False, 'kernelWriterAvailable': True,
                'producerResultQualified': False, 'failedAdvisory': True,
                'guestFilesystemVerified': False, 'windowsCompatibilityVerified': False}
    history = read_record(directory / 'runtime.json'); intent = read_record(directory / 'runtime-intent.json')
    if cold is not None: require(intent['sessionID'] != PRIOR_SESSION, 'prior-session-is-not-new-owner')
    if session is None: session = intent['sessionID']
    require(set(intent) == {'schemaVersion', 'vmID', 'sessionID', 'state'}
            and type(intent['schemaVersion']) is int and intent['schemaVersion'] == 1
            and intent['vmID'] == VM_ID and intent['sessionID'] == session and intent['state'] == 'settled'
            and history['sessionID'] == session and history['snapshot']['backendActive'] is False, 'terminal-owner-invalid')
    writer_probe(directory, False)
    qualified = False; result = None
    try:
        result = read_record(run / 'result.json')
        require(type(result['schemaVersion']) is int and result['schemaVersion'] == 1
                and result['scope'] == 'macopenvm-registered-qemu-runtime-result'
                and result['vmID'] == VM_ID and result['sessionID'] == session and result['drainsFinished'] is True
                and result['runtimeIntentSettled'] is True and result['platformStateFlushed'] is True
                and result['resourcesRevalidated'] is True and result['outcome'] == history['snapshot']['outcome'], 'terminal-receipt-invalid')
        qualified = True
    except (OSError, ValueError, KeyError, TypeError):
        pass  # Failed-run recovery may settle/reap without publishing a result.
    return {'actualParentReaped': True, 'workerExit': exit_code, 'vmID': VM_ID, 'sessionID': session,
            'outcome': history['snapshot']['outcome'], 'drainsFinished': True if qualified else None,
            'runtimeIntentSettled': True, 'kernelWriterAvailable': True,
            'producerResultQualified': qualified, 'failedAdvisory': exit_code != 0 or not qualified or history['snapshot']['outcome'] == 'failed',
            'forced': history['snapshot']['outcome'] == 'forcedStopped',
            'guestFilesystemVerified': False, 'windowsCompatibilityVerified': False}


def retain_until_reaped(worker):
    while True:
        try:
            return worker.wait(timeout=1)
        except BaseException:
            time.sleep(.1)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true'); parser.add_argument('--cli', type=Path, default=CLI)
    parser.add_argument('--directory', type=Path, default=DIRECTORY)
    parser.add_argument('--disposable-force-authorized', action='store_true')
    parser.add_argument('--shared-network-authorized', action='store_true')
    parser.add_argument('--installer-navigation-authorized', action='store_true')
    parser.add_argument('--installed-cold-boot-evaluation', action='store_true')
    parser.add_argument('--stopped-baseline', type=Path)
    parser.add_argument('--stopped-baseline-sha256')
    args = parser.parse_args(argv)
    if not args.run:
        print('SKIP: explicit --run required; no input inspection, files, process or VM action.'); return 0
    if not args.shared_network_authorized:
        print('SKIP: explicit --shared-network-authorized required for this VM; no input inspection, files, process or VM action.'); return 0
    cold = None
    if args.installed_cold_boot_evaluation:
        cold_mode_arguments(args)
        cold = read_cold_baseline(args.stopped_baseline, args.stopped_baseline_sha256)
    else: require(args.stopped_baseline is None and args.stopped_baseline_sha256 is None, 'no-automatic-installed-admission')
    baseline = admit(args.cli, args.directory, cold=cold)
    os.umask(0o077); token = uuid.uuid4().hex
    runtime = args.directory / '.runtime'; parent = args.directory / '.parent-evidence'
    for path in (runtime, parent):
        if not path.exists(): path.mkdir(mode=0o700)
        private_directory(path)
    run = runtime / ('run-' + token); run.mkdir(mode=0o700)
    evidence = parent / ('run-' + token); evidence.mkdir(mode=0o700)
    endpoints = Path('/private/tmp') / ('mvo-qemu-' + token[:16]); endpoints.mkdir(mode=0o700)
    save(evidence / 'prepared.json', {'scope': 'fixed-installed-disc-free-cold-boot-evaluation' if cold else 'fresh-registered-windows-shared-carrier-evaluation',
                                    'installedColdBootEvaluation': cold is not None, 'priorSessionID': PRIOR_SESSION if cold else None,
                                    'stoppedBaselineSHA256': COLD_SHA if cold else None, 'diskWholeContentHashVerified': False,
                                    'sharedNetworkAuthorized': args.shared_network_authorized, 'network': 'shared',
                                    'installerNavigationAuthorized': args.installer_navigation_authorized,
                                    'selectedCatalogExpectedPins': {'runtimeQemuSHA256': 'e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745',
                                                                   'privateSlirpSHA256': '10d404d8a693f2d37401ce0ff54e71d9ffb4a5fe42335a360dea39e6d083a5ab',
                                                                   'supportImageSHA256': None if cold else CARRIER_SHA},
                                    'vmID': VM_ID, 'cliSHA256': CLI_SHA, 'runDirectory': str(run),
                                    'endpointDirectory': str(endpoints), 'forceExplicitlyAuthorized': args.disposable_force_authorized})
    worker = None; session = None; input_open = True; failed = False
    try:
        descriptors = []; previous = None
        try:
            for name in ('parent-stdout.log', 'parent-stderr.log'):
                descriptors.append(os.open(run / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
            previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
            worker = subprocess.Popen([str(args.cli), 'windows-worker', '--directory', str(args.directory),
                                       '--run-directory', str(run), '--endpoint-directory', str(endpoints)],
                                      stdin=subprocess.DEVNULL, stdout=descriptors[0], stderr=descriptors[1], close_fds=True, cwd=run)
        finally:
            if previous is not None: signal.signal(signal.SIGINT, previous)
            for fd in descriptors: os.close(fd)
        save(evidence / 'actual-parent-start.json', {'actualPopenRetained': True, 'diagnosticPID': worker.pid})
        deadline = time.monotonic() + 120
        display = None
        while time.monotonic() < deadline:
            if worker.poll() is not None: break
            try:
                route, status = current_route(worker, args.directory, run, endpoints, cold=cold)
                session = route['sessionID']
                if status['state'] == 2 and status['ownership'] == 0 and status['backendActive'] and not status['operationPending'] and status['error'] == 0:
                    display = display_route(run, endpoints, session)
                    break
                require(status['error'] == 0 and status['ownership'] in (0, 3), 'worker-start-failed')
            except FileNotFoundError:
                pass  # Only not-yet-published intent/route/socket may wait.
            except OSError as error:
                if error.errno != errno.ECONNREFUSED: raise
            time.sleep(.1)
        if display is not None:
            # Observer/evidence publication is one attempt. Any failure enters
            # actual-owner custody with the original failure, never an O_EXCL retry.
            width, height, frame = observe_frame(display)
            fd = os.open(evidence / 'first-frame.ppm', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as output: output.write(frame); output.flush(); os.fsync(output.fileno())
            _, state = current_route(worker, args.directory, run, endpoints, session, cold=cold)
            require(state['backendActive'] and state['state'] == 2, 'observer-detach-changed-worker')
            save(evidence / 'ready.json', {'vmID': VM_ID, 'sessionID': session, 'displayRouteSHA256': sha(run / 'display.json'),
                                        'width': width, 'height': height, 'frameSHA256': hashlib.sha256(frame).hexdigest(),
                                        'observerDetachedRuntimePreserved': True, 'kernelWriterBusy': True})
            print('READY ' + str(evidence) + '\nCommands: status | frame | normal-stop | force-stop (explicit flag required)', flush=True)
        elif worker.poll() is None:
            raise TimeoutError('worker-readiness-deadline')
    except BaseException as error:
        failed = True
        try: save(evidence / 'failure.json', {'failureType': type(error).__name__, 'failureCode': str(error) if isinstance(error, ValueError) else 'readiness-or-publication-failed', 'actualOwnerRetained': worker is not None})
        except BaseException: pass
    if worker is None: return 1
    # No deadline or EOF cleanup. Keep the actual object and explicit controls;
    # malformed/missing readiness does not prevent correlation through live IPC.
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        while True:
            try:
                if worker.poll() is not None: break
                readable, _, _ = select.select([sys.stdin] if input_open else [], [], [], 1)
                if not readable: continue
                line = sys.stdin.readline()
                if not line: input_open = False; continue
                command = line.strip(); parts = command.split()
                route, status = current_route(worker, args.directory, run, endpoints, session, recovery=True, cold=cold)
                session = route['sessionID']
                if command == 'status': print(json.dumps(status), flush=True)
                elif command in ('normal-stop', 'force-stop'):
                    print(json.dumps(control(worker, args.directory, run, endpoints, session, command, args.disposable_force_authorized, cold=cold)), flush=True)
                elif command == 'frame':
                    value = display_route(run, endpoints, session); width, height, frame = observe_frame(value)
                    print(json.dumps(save_review_frame(evidence, width, height, frame)), flush=True)
                elif parts and parts[0] in ('key', 'click'):
                    if parts[0] == 'key':
                        require(len(parts) == 3, 'installer-key-format')
                        result = navigate(worker, args.directory, run, endpoints, session, 'key', parts[2], args.installer_navigation_authorized, key=parts[1], cold=cold)
                    else:
                        require(len(parts) == 4, 'installer-click-format')
                        result = navigate(worker, args.directory, run, endpoints, session, 'click', parts[3], args.installer_navigation_authorized, x=int(parts[1]), y=int(parts[2]), cold=cold)
                    save(evidence / ('input-' + uuid.uuid4().hex + '.json'), result)
                    print(json.dumps(result), flush=True)
                else: print('Unknown command; actual owner preserved.', flush=True)
            except BaseException as error:
                try: print('Command refused: ' + type(error).__name__ + '; actual owner preserved.', flush=True)
                except BaseException: pass
        receipt = terminal(worker, args.directory, run, session, cold=cold)
        require(sha(args.cli) == CLI_SHA and sha(args.directory / 'configuration.json') == baseline[1]
                and sha(args.directory / 'qemu-platform.json') == baseline[2]
                and all(baseline[0].get(name) == sha(ROOT / name) for name in COMPILED), 'sources-or-registration-changed')
        if cold is not None:
            installed_state(args.directory, cold, before_start=False)
            receipt.update(discsDetached=True, persistentAssetIdentitiesPreserved=True, diskWholeContentHashVerified=False)
            receipt['failedAdvisory'] = receipt['failedAdvisory'] or receipt.get('outcome') != 'guestStopped'
        save(evidence / 'terminal.json', receipt); print(json.dumps(receipt), flush=True)
        return 1 if failed or not receipt['producerResultQualified'] or receipt['failedAdvisory'] else 0
    finally:
        retain_until_reaped(worker)
        signal.signal(signal.SIGINT, previous)


if __name__ == '__main__':
    raise SystemExit(main())
