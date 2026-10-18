# SPDX-License-Identifier: Apache-2.0
"""Actual fresh-file export checks; no guests, APKs or existing VM files."""
from contextlib import contextmanager
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from support_media_live import DeliveryFailure, retain_generated_archive


DISK_BYTES = 8 << 30
PAYLOAD = bytes(range(256)) * 513 + b"original export fixture\n"


def identity(st):
    return (st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid, st.st_nlink, st.st_size)


def write_disk(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    try:
        os.ftruncate(fd, DISK_BYTES)
        view, offset = memoryview(PAYLOAD), 0
        while view:
            count = os.pwrite(fd, view, offset)
            if count <= 0:
                raise RuntimeError("fixture write failed")
            offset += count
            view = view[count:]
        os.fsync(fd)
        return identity(os.fstat(fd))
    finally:
        os.close(fd)


def observation():
    return dict(guestArchiveExportComplete=True, generatedArchiveBytes=len(PAYLOAD),
                generatedArchiveSHA256=hashlib.sha256(PAYLOAD).hexdigest())


@contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix="mvo-export-test-") as temporary:
        root = Path(temporary).resolve()
        directory, artifacts = root / "Fresh.macopenvm", root / "evidence"
        directory.mkdir(mode=0o700)
        artifacts.mkdir(mode=0o700)
        lock = os.open(directory / "writer.lock", os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(lock)
        original = write_disk(directory / "disk.raw")
        yield directory, artifacts, original


class ArchiveExportTests(unittest.TestCase):
    def test_exact_prefix_hash_identity_and_exclusive_readonly_output(self):
        with fixture() as (directory, artifacts, original):
            result = observation()
            output = retain_generated_archive(directory, artifacts, original, result)
            self.assertEqual(output, artifacts / "generated-initramfs.gz")
            self.assertEqual(output.read_bytes(), PAYLOAD)
            saved = output.lstat()
            self.assertTrue(stat.S_ISREG(saved.st_mode))
            self.assertEqual(stat.S_IMODE(saved.st_mode), 0o400)
            self.assertEqual((saved.st_uid, saved.st_nlink, saved.st_size),
                             (os.geteuid(), 1, len(PAYLOAD)))
            self.assertEqual(identity((directory / "disk.raw").lstat()), original)
            self.assertTrue(result["hostArchiveRetentionComplete"])
            self.assertTrue(result["exportDiskIdentityPreserved"])
            self.assertEqual(result["retainedArchiveBytes"], len(PAYLOAD))
            self.assertEqual(result["retainedArchiveSHA256"], hashlib.sha256(PAYLOAD).hexdigest())
            self.assertFalse(result["bytesBeyondExportVerified"])
            second = observation()
            with self.assertRaises(FileExistsError):
                retain_generated_archive(directory, artifacts, original, second)
            self.assertEqual(output.lstat().st_ino, saved.st_ino)
            self.assertEqual(output.read_bytes(), PAYLOAD)
            self.assertFalse(second.get("hostArchiveRetentionComplete", False))

    def test_wrong_hash_preserves_failure_output_without_success(self):
        with fixture() as (directory, artifacts, original):
            result = observation()
            result["generatedArchiveSHA256"] = "0" * 64
            with self.assertRaisesRegex(DeliveryFailure, "^initramfsExport$"):
                retain_generated_archive(directory, artifacts, original, result)
            output = artifacts / "generated-initramfs.gz"
            self.assertEqual(output.read_bytes(), PAYLOAD)
            self.assertEqual(stat.S_IMODE(output.lstat().st_mode), 0o600)
            self.assertFalse(result.get("hostArchiveRetentionComplete", False))
            self.assertNotIn("exportDiskIdentityPreserved", result)

    def test_swapped_disk_inode_is_rejected_before_retention(self):
        with fixture() as (directory, artifacts, original):
            disk = directory / "disk.raw"
            disk.rename(directory / "preserved-original.raw")
            replacement = write_disk(disk)
            self.assertNotEqual(replacement[:2], original[:2])
            result = observation()
            with self.assertRaisesRegex(DeliveryFailure, "^initramfsSource$"):
                retain_generated_archive(directory, artifacts, original, result)
            self.assertFalse((artifacts / "generated-initramfs.gz").exists())
            self.assertFalse(result.get("hostArchiveRetentionComplete", False))
            self.assertEqual(identity(disk.lstat()), replacement)

    def test_actual_exclusive_writer_lock_prevents_archive_reads(self):
        with fixture() as (directory, artifacts, original):
            writer = os.open(directory / "writer.lock", os.O_RDWR | os.O_CLOEXEC)
            try:
                fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = observation()
                with patch("support_media_live.os.pread", side_effect=AssertionError("archive read while busy")) as read:
                    with self.assertRaises(BlockingIOError) as failure:
                        retain_generated_archive(directory, artifacts, original, result)
                    self.assertIn(failure.exception.errno, (errno.EAGAIN, errno.EWOULDBLOCK))
                    read.assert_not_called()
                self.assertFalse((artifacts / "generated-initramfs.gz").exists())
                self.assertFalse(result.get("hostArchiveRetentionComplete", False))
            finally:
                os.close(writer)


if __name__ == "__main__":
    unittest.main()
