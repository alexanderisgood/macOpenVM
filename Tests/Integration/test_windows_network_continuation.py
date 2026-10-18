# SPDX-License-Identifier: Apache-2.0
"""Pure record checks only; never connects to or controls a VM."""
import copy
import hashlib
import json
import unittest
from unittest import mock
from pathlib import Path

import windows_network_continuation_lab as gate
import windows_network_continuation_worker_lab as launcher


class WindowsNetworkContinuationTests(unittest.TestCase):
    def setUp(self):
        self.plan = {"directory": "/private/fixture", "vmID": "11111111-1111-4111-8111-111111111111",
                     "previousSessionID": "33333333-3333-4333-8333-333333333333",
                     "macAddress": "02:11:22:33:44:55", "candidateSHA256": gate.CANDIDATE_SHA,
                     "driverISOSHA256": gate.DRIVER_SHA}
        self.plan_data = json.dumps(self.plan, sort_keys=True).encode()
        self.approval = dict(self.plan, schemaVersion=1, scope="approved-same-vm-windows-network-lab",
                             planSHA256=hashlib.sha256(self.plan_data).hexdigest(),
                             networkAuthorized=True, driverInstallationAuthorized=True,
                             normalShutdownAuthorized=True, resumeAuthorized=True,
                             credentialsAuthorized=False, consoleReviewedSHA256="a" * 64)
        self.terminal = dict(scope="actual-parent-owned-windows-continuation-terminal",
                             vmID=self.plan["vmID"], sessionID=self.plan["previousSessionID"],
                             actualOwnerReaped=True, allChildrenTerminal=True, drainsFinished=True,
                             pipesClosed=True, leasesClosed=True, runtimeIntentSettled=True,
                             opaqueExitAdvisoryReviewed=True, qemuExit=0, tpmExit=0, workerExit=1,
                             forceStopUsed=False, guestCleanShutdownClaimed=False)
        self.provenance = dict(scope="approved-fixed-windows-network-shutdown-input", action="normal-shutdown",
                               vmID=self.plan["vmID"], sessionID=self.plan["previousSessionID"],
                               fixedCommand="shutdown /s /t 0", inputSequenceCompleted=True,
                               guestShutdownVerified=False, forceStopUsed=False)

    def test_review_and_all_explicit_authorizations_are_required(self):
        gate.validated_approval(self.plan_data, self.plan, self.approval)
        for key, value in (("consoleReviewedSHA256", None), ("consoleReviewedSHA256", "A" * 64),
                           ("schemaVersion", True), ("planSHA256", "b" * 64),
                           ("networkAuthorized", False), ("driverInstallationAuthorized", False),
                           ("normalShutdownAuthorized", False), ("resumeAuthorized", False),
                           ("credentialsAuthorized", True)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                gate.validated_approval(self.plan_data, self.plan, dict(self.approval, **{key: value}))

    def test_terminal_and_fixed_provenance_preserve_opaque_exit(self):
        gate.require_terminal(self.terminal, self.plan, self.provenance)
        for key, value in (("actualOwnerReaped", False), ("allChildrenTerminal", False),
                           ("drainsFinished", False), ("pipesClosed", False), ("leasesClosed", False),
                           ("runtimeIntentSettled", False), ("opaqueExitAdvisoryReviewed", False),
                           ("qemuExit", False), ("tpmExit", False), ("workerExit", True),
                           ("qemuExit", 1), ("workerExit", 2), ("forceStopUsed", True),
                           ("guestCleanShutdownClaimed", True)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                gate.require_terminal(dict(self.terminal, **{key: value}), self.plan, self.provenance)
        for key, value in (("fixedCommand", "shutdown /s /f /t 0"), ("inputSequenceCompleted", False),
                           ("action", "open-console"), ("sessionID", "another-session"),
                           ("guestShutdownVerified", True), ("forceStopUsed", True)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                gate.require_terminal(self.terminal, self.plan, dict(self.provenance, **{key: value}))

    def test_recipe_only_replaces_offline_nic_and_readonly_carrier(self):
        original = {"scope": "fresh-approved-installer", "vmID": self.plan["vmID"],
                    "qemuArgv": ["old-qemu", "-L", "old-bios", "-k", "old-keymap", "-nic", "none",
                                 "-drive", "file=/private/disk,format=raw", "-drive", "file=/private/vars",
                                 "-chardev", "socket,path=/private/tpm"]}
        before = copy.deepcopy(original)
        proposed = gate.expected_input(original, self.plan["macAddress"])
        self.assertEqual(original, before)
        for immutable in ("file=/private/disk,format=raw", "file=/private/vars", "socket,path=/private/tpm"):
            self.assertIn(immutable, proposed["qemuArgv"])
        self.assertIn("readonly=on,file=" + str(gate.DRIVER), proposed["qemuArgv"][-3])
        self.assertEqual(proposed["vmID"], original["vmID"])
        for value in ("user", "none,model=virtio-net-pci"):
            changed = copy.deepcopy(original)
            changed["qemuArgv"][6] = value
            with self.assertRaises(ValueError):
                gate.expected_input(changed, self.plan["macAddress"])

    def test_new_session_rebinds_only_transient_endpoints_preserving_vm_state(self):
        old = "/private/tmp/mvo-win-0123456789abcdef"
        original = {"scope": "approved-same-vm-windows-network-fixture",
                    "qmpSocket": old + "/qmp.sock", "tpmSocket": old + "/tpm.sock",
                    "environment": {"LC_ALL": "C", "PATH": "/usr/bin:/bin/opt/homebrew/bin", "TMPDIR": old},
                    "qemuArgv": ["candidate", "-qmp", "unix:" + old + "/qmp.sock,server=on,wait=off",
                                 "-drive", "file=/private/VM/disk", "-device", "jsonfile=/private/VM/uefi",
                                 "-device", "virtio-net-pci,mac=" + self.plan["macAddress"],
                                 "-vnc", "unix:" + old + "/vnc.sock,share=force-shared"],
                    "swtpmArgv": ["swtpm", "dir=/private/VM/tpm,mode=0600,lock",
                                  "type=unixio,path=" + old + "/tpm.sock,mode=0600,terminate"]}
        before = copy.deepcopy(original)
        short = Path("/private/tmp/mvo-win-net-1111222233334444")
        rebound = launcher.rebound_input(original, short)
        self.assertEqual(original, before)
        self.assertEqual(rebound["qemuArgv"][3:9], original["qemuArgv"][3:9])
        self.assertEqual(rebound["swtpmArgv"][1], original["swtpmArgv"][1])
        self.assertEqual(rebound["qmpSocket"], str(short / "qmp.sock"))
        self.assertEqual(rebound["tpmSocket"], str(short / "tpm.sock"))
        self.assertEqual(rebound["environment"], dict(original["environment"], TMPDIR=str(short)))
        self.assertNotIn(old, json.dumps(rebound))
        for bad in (Path("/tmp/mvo-win-net-1111222233334444"), Path("/private/tmp/../tmp/mvo-win-net-1111222233334444")):
            with self.assertRaises(ValueError):
                launcher.rebound_input(original, bad)

    def test_failed_gate_never_creates_or_launches_a_continuation(self):
        argv = ["launcher", "--run", "--plan", "/private/plan.json", "--approval", "/private/approval.json",
                "--terminal", "/private/terminal.json", "--shutdown-record", "/private/shutdown.json",
                "--cli", "/private/macopenvm"]
        def pending(_):
            gate.validated_approval(self.plan_data, self.plan, dict(self.approval, networkAuthorized=False))

        with mock.patch("sys.argv", argv), mock.patch.object(gate, "check", side_effect=pending), \
                mock.patch.object(Path, "mkdir") as mkdir, mock.patch.object(launcher.subprocess, "Popen") as launch:
            with self.assertRaises(ValueError):
                launcher.main()
            mkdir.assert_not_called()
            launch.assert_not_called()

    def test_missing_run_flag_never_inspects_or_mutates_any_runtime(self):
        argv = ["launcher", "--plan", "/private/plan.json", "--approval", "/private/approval.json",
                "--terminal", "/private/terminal.json", "--shutdown-record", "/private/shutdown.json",
                "--cli", "/private/macopenvm"]
        with mock.patch("sys.argv", argv), mock.patch.object(gate, "check") as check, \
                mock.patch.object(Path, "mkdir") as mkdir, mock.patch.object(launcher.subprocess, "Popen") as launch:
            with self.assertRaises(SystemExit):
                launcher.main()
            check.assert_not_called()
            mkdir.assert_not_called()
            launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
