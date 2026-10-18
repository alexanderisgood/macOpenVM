#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Stopped same-filesystem relocation primitive for the reviewed Windows experiment.

Terminal provenance is reviewed separately by the actual parent. This primitive
requires settled identity and an actual exclusive writer lease, rejects aliases
and replacement, and never copies, launches, signals, repairs or rolls back a move.
"""
import ctypes
import fcntl
import os
from pathlib import Path
import stat

from runtime_worker_lab import read_json


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink, value.st_size, value.st_mtime_ns)


def open_directory(path):
    """Anchor every component through no-follow descriptors, including parents."""
    if not path.is_absolute() or any(p in ('', '.', '..') for p in path.parts[1:]):
        raise ValueError('Absolute lexical directory required')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        current = Path('/')
        for component in path.parts[1:]:
            current = current / component
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=fd)
            value = os.fstat(child)
            sticky_tmp = (value.st_uid == 0 and value.st_mode & stat.S_ISVTX
                          and current == Path('/private/tmp'))
            if value.st_uid not in (0, os.geteuid()) or (value.st_mode & 0o022 and not sticky_tmp):
                os.close(child)
                raise ValueError('Unsafe directory ancestry')
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def inventory(directory):
    result = {'.': identity(directory.lstat())}
    for index, path in enumerate(directory.rglob('*')):
        if index >= 512:
            raise ValueError('Relocation namespace exceeds its review bound')
        value = path.lstat()
        if (not (stat.S_ISREG(value.st_mode) or stat.S_ISDIR(value.st_mode))
                or value.st_uid != os.geteuid() or value.st_mode & 0o022
                or (stat.S_ISREG(value.st_mode) and value.st_nlink != 1)):
            raise ValueError('Relocation contains unsafe or aliased entries')
        result[str(path.relative_to(directory))] = identity(value)
    return result


def exclusive_rename(source_parent, source_name, destination_parent, destination_name):
    """Public macOS renameatx_np RENAME_EXCL: never overwrite a raced destination."""
    function = ctypes.CDLL(None, use_errno=True).renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(source_parent, os.fsencode(source_name), destination_parent,
                os.fsencode(destination_name), 0x00000004) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def relocate_stopped(source, destination, vm_id, session_id, *, rename=exclusive_rename,
                     flush=os.fsync):
    """Move only one actual stopped directory; failure leaves evidence at its location.

    After rename, a flush failure deliberately does not roll files back or declare
    success. Inspect both names and retain the same state before any later launch.
    """
    parent_fds = []
    writer = -1
    vm_fd = -1
    try:
        for parent in (source.parent, destination.parent):
            parent_fds.append(open_directory(parent))
        source_parent, destination_parent = parent_fds
        vm_fd = os.open(source.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=source_parent)
        vm_info = os.fstat(vm_fd)
        if vm_info.st_uid != os.geteuid() or stat.S_IMODE(vm_info.st_mode) != 0o700:
            raise ValueError('Source VM must be private and owned')
        if vm_info.st_dev != os.fstat(destination_parent).st_dev:
            raise ValueError('Cross-filesystem moves are not admitted')
        try:
            os.stat(destination.name, dir_fd=destination_parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ValueError('Destination must not already exist')
        writer = os.open('writer.lock', os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=vm_fd)
        writer_info = os.fstat(writer)
        if (not stat.S_ISREG(writer_info.st_mode) or writer_info.st_uid != os.geteuid()
                or writer_info.st_nlink != 1 or writer_info.st_size != 0
                or stat.S_IMODE(writer_info.st_mode) != 0o600):
            raise ValueError('Unsafe writer inode')
        fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        intent = read_json(source / 'runtime-intent.json')
        history = read_json(source / 'runtime.json')
        if (type(intent.get('schemaVersion')) is not int or intent.get('schemaVersion') != 1
                or intent.get('vmID') != vm_id
                or intent.get('sessionID') != session_id or intent.get('state') != 'settled'
                or history.get('sessionID') != session_id
                or type(history.get('schemaVersion')) is not int or history['schemaVersion'] != 1
                or history.get('snapshot', {}).get('backendActive') is not False
                or history.get('snapshot') != {'state': 'stopped', 'outcome': 'guestStopped',
                                                'backendActive': False}):
            raise ValueError('Exact settled normal-stop history required')
        before = inventory(source)
        if identity(source.lstat()) != identity(vm_info):
            raise ValueError('Source name changed')
        if identity((source / 'writer.lock').lstat()) != identity(writer_info):
            raise ValueError('Writer name changed')
        for parent, fd in zip((source.parent, destination.parent), parent_fds):
            if identity(parent.lstat()) != identity(os.fstat(fd)):
                raise ValueError('Parent name changed')
        flush(vm_fd)
        if identity(source.lstat()) != identity(os.fstat(vm_fd)):
            raise ValueError('Source name changed before rename')
        if identity((source / 'writer.lock').lstat()) != identity(os.fstat(writer)):
            raise ValueError('Writer name changed before rename')
        for parent, fd in zip((source.parent, destination.parent), parent_fds):
            if identity(parent.lstat()) != identity(os.fstat(fd)):
                raise ValueError('Parent name changed before rename')
        if inventory(source) != before:
            raise ValueError('Source namespace changed before rename')
        rename(source_parent, source.name, destination_parent, destination.name)
        after = inventory(destination)
        # The moved directory itself changes mtime only if its namespace changes;
        # ctime is intentionally excluded because rename updates it normally.
        if before != after or identity(destination.lstat()) != identity(os.fstat(vm_fd)):
            raise ValueError('Moved namespace identity changed; preserve it for inspection')
        flush(vm_fd)
        flush(source_parent)
        flush(destination_parent)
        for parent, fd in zip((source.parent, destination.parent), parent_fds):
            if identity(parent.lstat()) != identity(os.fstat(fd)):
                raise ValueError('Parent name changed after rename; preserve both locations')
        return {'scope': 'stopped-same-filesystem-directory-relocation',
                'vmID': vm_id, 'previousSessionID': session_id,
                'source': str(source), 'destination': str(destination),
                'entryCount': len(before), 'identitiesPreserved': True,
                'sourceDevice': vm_info.st_dev, 'sourceInode': vm_info.st_ino,
                'writerDevice': writer_info.st_dev, 'writerInode': writer_info.st_ino,
                'exclusiveWriterObserved': True, 'directoryFlushesCompleted': True,
                'credentialsEntered': False, 'copyPerformed': False, 'launchPerformed': False}
    finally:
        if writer >= 0:
            os.close(writer)
        if vm_fd >= 0:
            os.close(vm_fd)
        for fd in parent_fds:
            os.close(fd)
