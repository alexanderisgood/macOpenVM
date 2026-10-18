# SPDX-License-Identifier: Apache-2.0
"""Pure prerequisite-log fixtures; no filesystem tools, packages or guests run."""
import hashlib
from pathlib import Path
import subprocess
import unittest

from persistent_linux_install import SERVICE_PATHS, install_commands, parse_cold_boot, parse_prerequisite_log
from support_media_live import DeliveryFailure


CANONICAL = ("/bin/mkdir", "/bin/cpio", "/usr/bin/awk", "/usr/bin/find",
             "/usr/bin/sort", "/usr/bin/install")
BANNERS = {
    "sfdisk": "sfdisk from util-linux 2.42.3",
    "mkfs.ext4": "mke2fs 1.47.4 (6-Mar-2025)\n\tUsing EXT2FS Library version 1.47.4",
    "e2fsck": "e2fsck 1.47.4 (20-January-2026)",
    "mkfs.fat": "mkfs.fat 4.2 (2021-01-31)\nUsage: mkfs.fat [OPTIONS] DEVICE",
    "openrc": "openrc (OpenRC) 0.63.2",
}
ROWS = {path: {"sha256": hashlib.sha256(("original fixture " + path).encode()).hexdigest()}
        for path in SERVICE_PATHS}


def complete_log():
    lines = ["ordinary bounded diagnostic"]
    for name, banner in BANNERS.items():
        lines += [f"TOOL:{name}=/sbin/{name}", f"mvo-persistent.output.{name}.begin=1",
                  banner, f"mvo-persistent.rc.{name}=0"]
    lines += ["mvo-persistent.tools=0"]
    lines += [f"CANONICAL:{path}=symlink:0:/bin/busybox" for path in CANONICAL]
    lines += ["INIT:/sbin/init=symlink:0:/bin/busybox", "mvo-persistent.canonical=0"]
    lines += [ROWS[path]["sha256"] + "  /" + path for path in SERVICE_PATHS]
    lines += ["mvo-persistent.services=0"]
    return ("\n".join(lines) + "\n").encode("ascii")


class PersistentPrerequisiteTests(unittest.TestCase):
    def reject(self, log):
        with self.assertRaisesRegex(DeliveryFailure, "^apkToolsObservation$"):
            parse_prerequisite_log(log, ROWS)

    def test_complete_observations_keep_help_kind_distinct_from_version(self):
        report = parse_prerequisite_log(complete_log(), ROWS)
        self.assertTrue(report["probeQualified"])
        self.assertTrue(report["serviceHashesMatch"])
        self.assertTrue(report["canonicalPersistentBootLinksReady"])
        self.assertEqual(report["tools"]["mkfs.fat"]["queryKind"], "help-banner")
        self.assertEqual(report["tools"]["sfdisk"]["queryKind"], "version")
        self.assertEqual(report["tools"]["mkfs.fat"]["version"], "4.2")

    def test_duplicate_conflicting_unknown_and_malformed_prefixed_rows_reject(self):
        extras = (b"mvo-persistent.tools=0\n", b"mvo-persistent.tools=1\n",
                  b"mvo-persistent.services=1\n", b"mvo-persistent.other=0\n",
                  b"mvo-persistent.rc.sfdisk=0\n", b"mvo-persistent.output.sfdisk.begin=1\n",
                  b"mvo-persistent.rc.unknown=0\n", b"mvo-persistent.tools=00\n")
        for extra in extras:
            with self.subTest(extra=extra):
                self.reject(complete_log() + extra)

    def test_duplicate_unknown_and_foreign_tool_lookup_paths_reject(self):
        valid = complete_log()
        for log in (valid + b"TOOL:sfdisk=/sbin/sfdisk\n",
                    valid + b"TOOL:mount=/bin/mount\n",
                    valid.replace(b"TOOL:sfdisk=/sbin/sfdisk", b"TOOL:sfdisk=/tmp/sfdisk"),
                    valid.replace(b"TOOL:sfdisk=/sbin/sfdisk", b"TOOL:sfdisk=/sbin/other")):
            with self.subTest(log=log[-90:]):
                self.reject(log)

    def test_each_isolated_service_hash_omission_or_substitution_cannot_qualify(self):
        valid = complete_log()
        for path in SERVICE_PATHS:
            row = (ROWS[path]["sha256"] + "  /" + path + "\n").encode()
            with self.subTest(path=path, defect="missing"):
                report = parse_prerequisite_log(valid.replace(row, b""), ROWS)
                self.assertFalse(report["serviceHashesMatch"])
                self.assertFalse(report["probeQualified"])
            with self.subTest(path=path, defect="wrong digest"):
                report = parse_prerequisite_log(
                    valid.replace(row, ("0" * 64 + "  /" + path + "\n").encode()), ROWS)
                self.assertFalse(report["serviceHashesMatch"])
                self.assertFalse(report["probeQualified"])
        row = (ROWS[SERVICE_PATHS[0]]["sha256"] + "  /" + SERVICE_PATHS[0] + "\n").encode()
        self.reject(valid + row)

    def test_missing_canonical_is_honest_but_unsafe_or_unknown_paths_reject(self):
        valid = complete_log()
        missing = valid.replace(b"CANONICAL:/bin/mkdir=symlink:0:/bin/busybox",
                                b"CANONICAL:/bin/mkdir=missing")
        missing = missing.replace(b"mvo-persistent.canonical=0", b"mvo-persistent.canonical=1")
        report = parse_prerequisite_log(missing, ROWS)
        self.assertFalse(report["canonicalPersistentBootLinksReady"])
        self.assertEqual(report["canonical"]["/bin/mkdir"]["kind"], "missing")
        for target in (b"../../../../bin/busybox", b"/tmp/foreign", b"/bin/other"):
            with self.subTest(target=target):
                self.reject(valid.replace(b"CANONICAL:/bin/mkdir=symlink:0:/bin/busybox",
                                          b"CANONICAL:/bin/mkdir=symlink:0:" + target))
        self.reject(valid + b"CANONICAL:/bin/unknown=missing\n")
        self.reject(valid + b"INIT:/sbin/init=symlink:0:/bin/busybox\n")

    def test_nonzero_help_status_and_missing_version_remain_unqualified(self):
        valid = complete_log()
        failed = valid.replace(b"mvo-persistent.rc.mkfs.fat=0", b"mvo-persistent.rc.mkfs.fat=1")
        failed = failed.replace(b"mvo-persistent.tools=0", b"mvo-persistent.tools=1")
        report = parse_prerequisite_log(failed, ROWS)
        self.assertFalse(report["probeQualified"])
        self.assertEqual(report["tools"]["mkfs.fat"]["exitStatus"], 1)
        self.assertEqual(report["tools"]["mkfs.fat"]["queryKind"], "help-banner")
        report = parse_prerequisite_log(valid.replace(BANNERS["sfdisk"].encode(),
                                                       b"Usage: sfdisk [OPTIONS] DEVICE"), ROWS)
        self.assertFalse(report["toolVersionsMatch"])
        self.assertFalse(report["probeQualified"])
        self.assertEqual(report["tools"]["sfdisk"]["exitStatus"], 0)

    def test_control_nonascii_and_oversized_diagnostics_reject(self):
        valid = complete_log()
        for extra in (b"bad\x00\n", b"bad\x1b\n", b"bad\x7f\n", b"bad\xff\n",
                      b"x" * 32768 + b"\n"):
            with self.subTest(length=len(extra), first=extra[:8]):
                self.reject(extra + valid)

    def test_install_transfer_fits_remaining_serial_budget_and_shell_syntax(self):
        script = Path(__file__).with_name("persistent_linux_guest.sh").read_bytes()
        marker, identity = "mvo-support-" + "a" * 32, "01234567-89ab-4cde-8123-456789abcdef"
        commands = install_commands(script, marker, identity)
        self.assertLessEqual(57 + len(commands) + 1, 64)
        for _, command in commands:
            self.assertLessEqual(len(command.encode()), 1024)
            subprocess.run(["/bin/sh", "-n"], input=command.encode(), check=True, capture_output=True)
        subprocess.run(["/bin/sh", "-n"], input=script, check=True, capture_output=True)
        for bad in (marker + "'", "mvo-support-$(id)", marker + "\n"):
            with self.assertRaises(DeliveryFailure):
                install_commands(script, bad, identity)

    def test_cold_boot_requires_every_actual_fact_once(self):
        marker, root, esp = "mvo-support-" + "b" * 32, "01234567-89ab-4cde-8123-456789abcdef", "1234-ABCD"
        facts = dict(services="0", kernel="6.18.55-0-virt", modules="6.18.55-0-virt", network="lo",
                     rootUUID=root, rootRW="1", espUUID=esp, discsAbsent="1", persistentWrite="1",
                     priorWrite="0", complete="1", exit="0")
        rows = [(marker + ".cold." + k + "=" + v).encode() for k, v in facts.items()]
        self.assertEqual(parse_cold_boot(rows, marker, root, esp), facts)
        for i, row in enumerate(rows):
            for invalid in (rows[:i] + rows[i+1:], rows + [row], rows[:i] + [row + b"bad"] + rows[i+1:]):
                with self.assertRaises(DeliveryFailure):
                    parse_cold_boot(invalid, marker, root, esp)
        with self.assertRaises(DeliveryFailure):
            parse_cold_boot(rows, marker, root, esp, "1")
        replay = [row.replace(b".priorWrite=0", b".priorWrite=1") for row in rows]
        self.assertEqual(parse_cold_boot(replay, marker, root, esp, "1")["priorWrite"], "1")


if __name__ == "__main__":
    unittest.main()
