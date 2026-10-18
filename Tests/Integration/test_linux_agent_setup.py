# SPDX-License-Identifier: Apache-2.0
"""Private filesystem fixtures; fake Alpine account/service boundaries, no real enrollment."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / "GuestAgent/Linux/setup.sh"
INITD = ROOT / "GuestAgent/Linux/macopenvm-agent.initd"
VM_ID = "01234567-89ab-cdef-0123-456789abcdef\n"
# Generation validation launches hundreds of isolated Python boundary shims.
# Observed successful preparation exceeded the former 20s fixture limit under
# parallel load. This bound affects private fake actions only, no native deadline.
FIXTURE_ACTION_TIMEOUT = 60

FAKE_RUNNER = r'''
import fcntl, fnmatch, hashlib, json, os, pathlib, stat, subprocess, sys
root = pathlib.Path(os.environ["MVO_FAKE_ROOT"])
state_path = pathlib.Path(os.environ["MVO_FAKE_STATE"])
state = json.loads(state_path.read_text())
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def save(): state_path.write_text(json.dumps(state))
def record():
    state["calls"].append([command] + args)
    save()
def fail(): sys.exit(1)
if command == "stat":
    follow = "-L" in args
    filesystem = "-f" in args
    selected = [value for value in args if value not in ("-L", "-f")]
    if len(selected) != 3 or selected[0] != "-c": fail()
    spec, name = selected[1:]
    if filesystem:
        if spec != "%T" or pathlib.Path(name) != root / "proc" or not pathlib.Path(name).is_dir(): fail()
        print("proc")
        sys.exit(0)
    # Darwin's fdescfs stat path need not expose the target inode; model Linux
    # stat -L /dev/fd/9 using that actually inherited descriptor's fstat.
    info = os.fstat(9) if follow and name == "/dev/fd/9" else os.stat(name) if follow else os.lstat(name)
    enrolled = pathlib.Path(name).is_relative_to(root / "etc/macopenvm-agent") or pathlib.Path(name) == root / "run/macopenvm-agent.log"
    values = {"%u": 444 if enrolled else 0, "%g": 445 if enrolled else 0,
              "%a": format(stat.S_IMODE(info.st_mode), "o"), "%h": info.st_nlink,
              "%s": info.st_size, "%d": info.st_dev, "%i": info.st_ino,
              "%d:%i": str(info.st_dev) + ":" + str(info.st_ino)}
    if spec == "%d" and (name == os.environ.get("MVO_OTHER_DEVICE_PATH")
                         or fnmatch.fnmatchcase(name, os.environ.get("MVO_OTHER_DEVICE_PATTERN", ""))):
        values[spec] = info.st_dev + 1
    print(values[spec])
elif command == "flock":
    if args != ["-n", "9"]: fail()
    try:
        # This is the installer's actual inherited descriptor/open-file description.
        # Closing only this child copy does not release the parent's shared OFD lock.
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, OSError): fail()
elif command == "sha256sum":
    if not args:
        print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + "  -")
    elif args[0] == "-c":
        for line in pathlib.Path(args[1]).read_text().splitlines():
            expected, name = line.split("  ", 1)
            if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() != expected: fail()
    else:
        for name in args:
            print(hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() + "  " + name)
elif command == "id":
    if args == ["-u"]: print(0)
    elif not state["user"]: fail()
    elif args == ["-u", "macopenvm-agent"]: print(state.get("uid", 444))
    elif args == ["-g", "macopenvm-agent"]: print(state.get("gid", 445))
    elif args != ["macopenvm-agent"]: fail()
elif command == "addgroup":
    record()
    if state["group"]: fail()
    state["group"] = True; save()
    with (root / "etc/group").open("a") as output: output.write("macopenvm-agent:x:445:\n")
elif command == "adduser":
    record()
    if os.environ.get("MVO_FAIL_ADDUSER") == "1": fail()
    if state["user"] or not state["group"]: fail()
    state["user"] = True; save()
    with (root / "etc/passwd").open("a") as output:
        output.write("macopenvm-agent:x:444:445:agent:/nonexistent:/sbin/nologin\n")
    with (root / "etc/shadow").open("a") as output: output.write("macopenvm-agent:!:0:0:99999:7:::\n")
elif command == "chown": record()
elif command == "sync":
    record()
    state["syncs"] = state.get("syncs", 0) + 1; save()
    if state["syncs"] == int(os.environ.get("MVO_FAIL_SYNC", "0")): fail()
    # Sync is deliberately an acknowledgement stub, never power-loss evidence.
    if state["syncs"] == int(os.environ.get("MVO_FAIL_AFTER_SYNC", "0")): fail()
elif command == "rc-update":
    record()
    try: os.fstat(9); inherited = True
    except OSError: inherited = False
    state.setdefault("service_lock_inherited", []).append(inherited); save()
    link = root / "etc/runlevels/default/macopenvm-agent"
    if args == ["add", "macopenvm-agent", "default"]:
        link.symlink_to(root / "etc/init.d/macopenvm-agent")
    elif args == ["del", "macopenvm-agent", "default"]: link.unlink()
    else: fail()
elif command == "rc-service":
    record()
    try: os.fstat(9); inherited = True
    except OSError: inherited = False
    state.setdefault("service_lock_inherited", []).append(inherited); save()
    if args == ["macopenvm-agent", "stop"] and os.environ.get("MVO_SERVICE_GATE_FD"):
        # Test-only rendezvous: the real manager remains alive holding FD9 while
        # this normal-service child, with FD9 closed, waits on a separate pipe.
        ready = pathlib.Path(os.environ["MVO_SERVICE_GATE_READY"])
        ready.write_bytes(b"waiting\n"); ready.chmod(0o600)
        if os.read(int(os.environ["MVO_SERVICE_GATE_FD"]), 1) != b"R": fail()
    if args == ["macopenvm-agent", "start"]:
        if os.environ.get("MVO_FAIL_START") == "1": fail()
        state["running"] = True
        binary = root / "usr/local/libexec/macopenvm-agent/macopenvm-agent"
        if binary.is_file(): state["running_generation"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        save()
        if os.environ.get("MVO_FAIL_START_AFTER_SUCCESS") == "1": fail()
    elif args == ["macopenvm-agent", "stop"]:
        if os.environ.get("MVO_FAIL_STOP") == "1": fail()
        if os.environ.get("MVO_FALSE_STOP_ACK") != "1": state["running"] = False
    elif args == ["macopenvm-agent", "status"]:
        sys.exit(0 if state["running"] else 3)
    else: fail()
    save()
elif command == "supervise-daemon": fail()
elif command == "mv":
    record()
    state["moves"] += 1; save()
    if state["moves"] == int(os.environ.get("MVO_FAIL_MOVE", "0")): fail()
    result = subprocess.run(["/bin/mv"] + args, check=False).returncode
    if result == 0 and state["moves"] == int(os.environ.get("MVO_FAIL_AFTER_MOVE", "0")): fail()
    sys.exit(result)
elif command == "dd":
    selected = next((value[3:] for value in args if value.startswith("if=")), None)
    if selected == os.environ.get("MVO_FAIL_DD_INPUT"): fail()
    sys.exit(subprocess.run(["/bin/dd"] + args, check=False).returncode)
elif command == "cp":
    record()
    state["copies"] = state.get("copies", 0) + 1; save()
    if state["copies"] == int(os.environ.get("MVO_FAIL_COPY", "0")): fail()
    result = subprocess.run(["/bin/cp"] + args, check=False).returncode
    if result == 0 and state["copies"] == int(os.environ.get("MVO_FAIL_AFTER_COPY", "0")): fail()
    sys.exit(result)
else: fail()
'''


class LinuxAgentSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mvo-agent-setup-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.sysroot = self.base / "root"
        self.commands = self.base / "commands"
        self.payload = self.base / "payload"
        self.enrollment = self.base / "enrollment"
        for path in (self.sysroot, self.commands, self.payload, self.enrollment):
            path.mkdir(mode=0o700)
        (self.sysroot / ".macopenvm-agent-test-root").write_text("macopenvm-agent-test-root-v1\n")
        (self.commands / ".macopenvm-agent-test-commands").write_text("macopenvm-agent-test-commands-v1\n")
        for name in ("etc/init.d", "etc/conf.d", "etc/runlevels/default", "usr/local/libexec", "var/lib", "run", "proc"):
            (self.sysroot / name).mkdir(parents=True, exist_ok=True, mode=0o755)
        (self.sysroot / "etc/alpine-release").write_text("3.23.0\n")
        for name, value in (("passwd", "root:x:0:0:root:/root:/bin/ash\n"),
                            ("shadow", "root:!:0:0:99999:7:::\n"), ("group", "root:x:0:\n")):
            (self.sysroot / "etc" / name).write_text(value)
        self.state_file = self.base / "fake-state.json"
        self.state_file.write_text(json.dumps({"user": False, "group": False, "running": False,
                                              "calls": [], "moves": 0}))
        runner = "#!" + sys.executable + "\n" + FAKE_RUNNER
        for name in ("id", "addgroup", "adduser", "chown", "rc-update", "rc-service", "supervise-daemon", "sha256sum", "stat", "mv", "sync", "flock", "dd", "cp"):
            path = self.commands / name
            path.write_text(runner)
            path.chmod(0o700)
        (self.payload / "agent").write_bytes(b"fixture-only-not-an-agent\n")
        shutil.copyfile(INITD, self.payload / "initd")
        shutil.copyfile(SETUP, self.payload / "setup.sh")
        self.refresh_manifest()
        for name, contents in (("cert.pem", b"fixture-cert\n"), ("key.pem", b"fixture-private-key\n"),
                               ("ca.pem", b"fixture-ca\n"), ("vm-id", VM_ID.encode())):
            (self.enrollment / name).write_bytes(contents)
            (self.enrollment / name).chmod(0o600)
        self.program = self.sysroot / "usr/local/libexec/macopenvm-agent"
        self.credentials = self.sysroot / "etc/macopenvm-agent"
        self.service = self.sysroot / "etc/init.d/macopenvm-agent"
        self.owned_state = self.sysroot / "var/lib/macopenvm-agent"
        self.reservation = self.sysroot / "var/lib/macopenvm-agent-account"

    def refresh_manifest(self):
        manifest = "".join(hashlib.sha256((self.payload / name).read_bytes()).hexdigest() + "  " + name + "\n"
                           for name in ("agent", "initd", "setup.sh"))
        (self.payload / "SHA256SUMS").write_text(manifest)
        self.pin = hashlib.sha256(manifest.encode()).hexdigest()

    def observe(self, *args, success=True, extra_env=None, test_mode=True):
        env = os.environ.copy()
        env.update({"MVO_FAKE_ROOT": str(self.sysroot), "MVO_FAKE_STATE": str(self.state_file)})
        if test_mode:
            env["MACOPENVM_AGENT_TEST_MODE"] = "1"
        else:
            env.pop("MACOPENVM_AGENT_TEST_MODE", None)
        env.update(extra_env or {})
        result = subprocess.run(["/bin/sh", str(getattr(self, "manager_script", SETUP)), "--test-sysroot", str(self.sysroot),
                                 "--test-command-dir", str(self.commands), *args], env=env,
                                capture_output=True, timeout=FIXTURE_ACTION_TIMEOUT, check=False)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        self.assertNotIn(b"fixture-private-key", result.stdout + result.stderr)
        self.assertLessEqual(len(result.stdout + result.stderr), 128)
        return result

    def install(self, **kwargs):
        return self.observe("install", "--payload", str(self.payload), "--manifest-sha256", self.pin,
                            "--enrollment", str(self.enrollment), **kwargs)

    def reinstall(self, *, reuse=True, vm_id=VM_ID.strip(), **kwargs):
        mode = ["--reuse-credentials"] if reuse else ["--enrollment", str(self.enrollment)]
        return self.observe("reinstall", "--payload", str(self.payload), "--manifest-sha256", self.pin,
                            "--vm-id", vm_id, *mode, **kwargs)

    def tree(self):
        values = {}
        for path in self.sysroot.rglob("*"):
            if path.is_symlink():
                values[str(path.relative_to(self.sysroot))] = ("link", os.readlink(path))
            elif path.is_dir():
                values[str(path.relative_to(self.sysroot))] = ("directory", stat.S_IMODE(path.stat().st_mode))
            else:
                values[str(path.relative_to(self.sysroot))] = ("file", stat.S_IMODE(path.stat().st_mode), path.read_bytes())
        return values

    def reservation_status(self):
        return (self.reservation / "record").read_text().splitlines()[7]

    def state(self):
        return json.loads(self.state_file.read_text())

    def service_prestart(self, success=True):
        env = os.environ.copy()
        env.update({"MVO_FAKE_ROOT": str(self.sysroot), "MVO_FAKE_STATE": str(self.state_file),
                    "PATH": str(self.commands) + ":/usr/bin:/bin"})
        snippet = '. "$1"; directory="$2"; logfile="$3"; log_owner="$4"; start_pre'
        result = subprocess.run(["/bin/sh", "-c", snippet, "fixture-service", str(INITD),
                                 str(self.credentials), str(self.sysroot / "run/macopenvm-agent.log"),
                                 str(self.sysroot / "run/macopenvm-agent.log.owner")], env=env,
                                capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        self.assertEqual(result.stdout, b"")
        return result

    def assert_no_mutation(self):
        self.assertFalse(self.program.exists())
        self.assertFalse(self.credentials.exists())
        self.assertFalse(self.service.exists())
        self.assertEqual(self.state()["calls"], [])

    def test_verified_install_is_explicit_scoped_private_and_unprivileged(self):
        self.install()
        self.assertEqual((self.program / "macopenvm-agent").read_bytes(), (self.payload / "agent").read_bytes())
        self.assertEqual((self.program / "setup.sh").read_bytes(), SETUP.read_bytes())
        self.assertEqual(self.service.read_bytes(), INITD.read_bytes())
        self.assertEqual(stat.S_IMODE(self.program.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(self.credentials.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.owned_state.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.reservation.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.reservation / "record").stat().st_mode), 0o600)
        self.assertLessEqual((self.reservation / "record").stat().st_size, 1024)
        self.assertEqual(self.reservation_status(), "credentials=installed")
        for path in self.credentials.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o400 if path.name in ("cert.pem", "ca.pem") else 0o600)
        self.assertEqual(sorted(path.name for path in self.payload.iterdir()), ["SHA256SUMS", "agent", "initd", "setup.sh"])
        calls = self.state()["calls"]
        self.assertIn(["addgroup", "-S", "macopenvm-agent"], calls)
        self.assertIn(["adduser", "-S", "-D", "-H", "-h", "/nonexistent", "-s", "/sbin/nologin", "-G", "macopenvm-agent", "macopenvm-agent"], calls)
        self.assertTrue(any(call[:3] == ["chown", "-R", "444:445"] for call in calls))
        self.assertEqual(calls[-2:], [["rc-update", "add", "macopenvm-agent", "default"], ["rc-service", "macopenvm-agent", "start"]])
        self.assertTrue(self.state()["running"])
        self.assertFalse(list((self.sysroot / "var/lib").glob(".macopenvm-agent-stage.*")))
        self.assertIn('command_user="macopenvm-agent:macopenvm-agent"', INITD.read_text())
        self.assertIn('supervisor="supervise-daemon"', INITD.read_text())
        self.assertIn('pidfile="/run/macopenvm-agent.pid"', INITD.read_text())
        self.assertIn('logfile="/run/macopenvm-agent.log"', INITD.read_text())
        self.assertIn('no_new_privs="yes"', INITD.read_text())
        self.assertIn('respawn_max=3', INITD.read_text())
        self.assertIn('respawn_period=0', INITD.read_text())
        self.assertNotIn('capabilities=', INITD.read_text())
        self.assertIn('$vm_id --service', INITD.read_text())

    def test_wrong_pin_or_changed_payload_rejects_before_account_boundary(self):
        self.pin = "0" * 64
        self.install(success=False)
        self.assert_no_mutation()
        self.refresh_manifest()
        (self.payload / "agent").write_bytes(b"changed\n")
        self.install(success=False)
        self.assert_no_mutation()
        stages = list((self.sysroot / "var/lib").glob(".macopenvm-agent-stage.*"))
        self.assertEqual(len(stages), 1)
        self.assertEqual(stat.S_IMODE(stages[0].stat().st_mode), 0o700)

    def test_optional_publisher_metadata_is_not_treated_as_an_issuer_trust_pin(self):
        (self.payload / "manifest.sig").write_bytes(b"s" * 64)
        (self.payload / "issuer.raw").write_bytes(b"p" * 32)
        approved = self.pin
        self.pin = "0" * 64
        self.install(success=False)
        self.assert_no_mutation()
        self.pin = approved
        self.install()
        self.assertEqual((self.owned_state / "payload.sha256").read_bytes(), (self.payload / "SHA256SUMS").read_bytes())

    def test_missing_standard_parents_are_created_with_traversable_permissions(self):
        (self.sysroot / "usr/local/libexec").rmdir()
        (self.sysroot / "usr/local").rmdir()
        self.install()
        for relative in ("usr/local", "usr/local/libexec"):
            self.assertEqual(stat.S_IMODE((self.sysroot / relative).stat().st_mode), 0o755)
        self.assertTrue((self.program / "macopenvm-agent").exists())

    def test_existing_private_executable_parent_rejects_before_mutation_and_preserves_policy(self):
        for relative in ("usr", "usr/local", "usr/local/libexec"):
            with self.subTest(parent=relative):
                parent = self.sysroot / relative
                parent.chmod(0o700)
                sentinel = parent / "unrelated-policy"
                sentinel.write_text("preserve-existing-policy\n")
                before = parent.stat()
                result = self.install(success=False)
                self.assertEqual(result.stderr, b"Experimental agent setup: The program path is not traversable by its service user.\n")
                after = parent.stat()
                self.assertEqual((before.st_dev, before.st_ino, before.st_mode),
                                 (after.st_dev, after.st_ino, after.st_mode))
                self.assertEqual(sentinel.read_text(), "preserve-existing-policy\n")
                self.assert_no_mutation()
                self.assertFalse(list((self.sysroot / "var/lib").glob(".macopenvm-agent-stage.*")))
                self.assertFalse((self.sysroot / "var/lib/macopenvm-agent.install-lock").exists())
                parent.chmod(0o755)
                sentinel.unlink()

    def test_existing_711_executable_ancestry_is_admitted_without_chmod(self):
        parents = [self.sysroot / relative for relative in ("usr", "usr/local", "usr/local/libexec")]
        for parent in parents:
            parent.chmod(0o711)
        self.install()
        for parent in parents:
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o711)
        self.assertTrue((self.program / "macopenvm-agent").exists())

    def test_manifest_order_extra_record_and_unexpected_payload_entry_reject(self):
        original = (self.payload / "SHA256SUMS").read_text()
        for changed in ("".join(reversed(original.splitlines(keepends=True))), original + "0" * 64 + "  key.pem\n"):
            (self.payload / "SHA256SUMS").write_text(changed)
            self.pin = hashlib.sha256(changed.encode()).hexdigest()
            self.install(success=False)
            self.assert_no_mutation()
        self.refresh_manifest()
        (self.payload / "extra").write_text("preserve\n")
        self.install(success=False)
        self.assert_no_mutation()
        self.assertEqual((self.payload / "extra").read_text(), "preserve\n")

    def test_unsafe_enrollment_mode_uuid_and_symlink_are_rejected(self):
        self.enrollment.chmod(0o755)
        self.install(success=False)
        self.enrollment.chmod(0o700)
        (self.enrollment / "key.pem").chmod(0o644)
        self.install(success=False)
        (self.enrollment / "key.pem").chmod(0o600)
        (self.enrollment / "vm-id").write_text("not-a-uuid\n")
        self.install(success=False)
        (self.enrollment / "vm-id").write_text(VM_ID)
        (self.enrollment / "key.pem").unlink()
        (self.enrollment / "key.pem").symlink_to(self.enrollment / "cert.pem")
        self.install(success=False)
        self.assert_no_mutation()

    def test_existing_account_or_owned_path_is_never_adopted(self):
        self.program.mkdir()
        (self.program / "unrelated").write_text("preserve\n")
        self.install(success=False)
        self.assertEqual((self.program / "unrelated").read_text(), "preserve\n")
        shutil.rmtree(self.program)
        account = self.state()
        account["user"] = True
        self.state_file.write_text(json.dumps(account))
        self.install(success=False)
        self.assert_no_mutation()

    def test_symlink_ancestor_and_test_flags_without_mode_never_mutate(self):
        self.observe("uninstall", test_mode=False, success=False)
        actual = self.base / "outside"
        actual.mkdir()
        (self.sysroot / "usr/local/libexec").rmdir()
        (self.sysroot / "usr/local/libexec").symlink_to(actual)
        self.install(success=False)
        self.assertEqual(list(actual.iterdir()), [])
        self.assert_no_mutation()

    def test_real_test_prefix_and_missing_fixture_sentinel_reject_before_account_commands(self):
        sentinel = self.sysroot / ".macopenvm-agent-test-root"
        sentinel.unlink()
        self.install(success=False)
        self.assert_no_mutation()
        env = os.environ.copy()
        env.update({"MACOPENVM_AGENT_TEST_MODE": "1", "MVO_FAKE_ROOT": str(self.sysroot),
                    "MVO_FAKE_STATE": str(self.state_file)})
        result = subprocess.run(["/bin/sh", str(SETUP), "--test-sysroot", "/",
                                 "--test-command-dir", str(self.commands), "uninstall"], env=env,
                                capture_output=True, timeout=5, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertLessEqual(len(result.stdout + result.stderr), 128)
        self.assert_no_mutation()

    def test_uninstall_stops_disables_preserves_credentials_then_explicitly_removes(self):
        self.install()
        enrolled = {path.name: path.read_bytes() for path in self.credentials.iterdir()}
        first = len(self.state()["calls"])
        self.observe("uninstall")
        self.assertFalse(self.program.exists())
        self.assertFalse(self.service.exists())
        self.assertTrue(self.owned_state.exists())
        self.assertEqual({path.name: path.read_bytes() for path in self.credentials.iterdir()}, enrolled)
        service_calls = [call for call in self.state()["calls"][first:] if call[0] in ("rc-service", "rc-update")]
        self.assertEqual(service_calls, [["rc-service", "macopenvm-agent", "stop"],
                                        ["rc-service", "macopenvm-agent", "status"],
                                        ["rc-service", "macopenvm-agent", "status"],
                                        ["rc-update", "del", "macopenvm-agent", "default"]])
        self.assertEqual(self.reservation_status(), "credentials=retained")
        self.observe("uninstall", "--remove-credentials")
        self.assertFalse(self.credentials.exists())
        self.assertFalse(self.owned_state.exists())
        self.assertTrue(self.state()["user"])
        self.assertEqual(self.reservation_status(), "credentials=removed")
        self.assertIn("macopenvm-agent:!:", (self.sysroot / "etc/shadow").read_text())
        self.assertFalse(any(call[0] in ("deluser", "delgroup") for call in self.state()["calls"]))

    def test_changed_program_or_marker_or_unrelated_entry_blocks_uninstall(self):
        self.install()
        binary = self.program / "macopenvm-agent"
        original = binary.read_bytes()
        binary.write_bytes(b"changed\n")
        before = self.state()["calls"][:]
        self.observe("uninstall", "--remove-credentials", success=False)
        self.assertEqual(self.state()["calls"], before)
        self.assertTrue(self.credentials.exists())
        binary.write_bytes(original)
        marker = self.owned_state / "owner"
        saved = marker.read_text()
        marker.write_text(saved + "extra\n")
        self.observe("uninstall", "--remove-credentials", success=False)
        marker.write_text(saved)
        (self.credentials / "unrelated").write_text("preserve\n")
        self.observe("uninstall", "--remove-credentials", success=False)
        self.assertEqual((self.credentials / "unrelated").read_text(), "preserve\n")
        self.assertEqual(self.state()["calls"], before)

    def test_failed_normal_stop_preserves_all_files_and_credentials(self):
        self.install()
        before = self.tree()
        self.observe("uninstall", "--remove-credentials", extra_env={"MVO_FAIL_STOP": "1"}, success=False)
        self.assertEqual(self.tree(), before)
        self.assertTrue(self.program.exists())
        self.assertTrue(self.service.exists())
        self.assertTrue(self.credentials.exists())
        self.assertTrue(self.owned_state.exists())
        self.assertTrue((self.sysroot / "etc/runlevels/default/macopenvm-agent").is_symlink())

    def test_runtime_log_is_private_truncated_only_after_matching_inode_and_removed_on_uninstall(self):
        self.install()
        self.service_prestart()
        log = self.sysroot / "run/macopenvm-agent.log"
        marker = self.sysroot / "run/macopenvm-agent.log.owner"
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)
        log.write_text("fixed-event\n")
        self.service_prestart()
        self.assertEqual(log.read_bytes(), b"")
        log.write_text("fixed-event\n")
        self.observe("uninstall", "--remove-credentials")
        self.assertFalse(log.exists())
        self.assertFalse(marker.exists())

    def test_runtime_log_replacement_symlink_and_hardlink_are_preserved(self):
        self.install()
        self.service_prestart()
        log = self.sysroot / "run/macopenvm-agent.log"
        held = self.sysroot / "run/old-log"
        log.rename(held)
        log.write_text("unrelated-file\n")
        log.chmod(0o600)
        self.service_prestart(success=False)
        self.observe("uninstall", "--remove-credentials", success=False)
        self.assertEqual(log.read_text(), "unrelated-file\n")
        log.unlink()
        log.symlink_to(held)
        self.service_prestart(success=False)
        self.assertTrue(log.is_symlink())
        log.unlink()
        os.link(held, log)
        self.service_prestart(success=False)
        self.assertEqual(log.stat().st_nlink, 2)
        self.assertTrue(self.credentials.exists())

    def test_interrupted_commit_preserves_private_staging_and_supports_explicit_owned_recovery(self):
        self.install(extra_env={"MVO_FAIL_MOVE": "3"}, success=False)
        self.assertTrue(self.owned_state.exists())
        self.assertFalse(self.program.exists())
        stages = list((self.sysroot / "var/lib").glob(".macopenvm-agent-stage.*"))
        self.assertEqual(len(stages), 1)
        self.assertEqual(stat.S_IMODE(stages[0].stat().st_mode), 0o700)
        self.assertTrue((stages[0] / "credentials/key.pem").exists())
        before = self.state()["calls"][:]
        self.install(success=False)
        self.assertEqual(self.state()["calls"], before)
        self.observe("uninstall", "--remove-credentials")
        self.assertFalse(self.owned_state.exists())
        self.assertTrue(stages[0].exists())
        self.assertTrue((self.sysroot / "var/lib/macopenvm-agent.install-lock").exists())

    def test_keep_uninstall_and_explicit_reinstall_reuses_exact_bytes_modes_and_account(self):
        self.install()
        self.observe("uninstall")
        enrolled = {path.name: (path.read_bytes(), stat.S_IMODE(path.stat().st_mode), path.stat().st_ino)
                    for path in self.credentials.iterdir()}
        account_calls = [call for call in self.state()["calls"] if call[0] in ("adduser", "addgroup", "chown")]
        self.reinstall()
        self.assertEqual({path.name: (path.read_bytes(), stat.S_IMODE(path.stat().st_mode), path.stat().st_ino)
                          for path in self.credentials.iterdir()}, enrolled)
        self.assertEqual([call for call in self.state()["calls"] if call[0] in ("adduser", "addgroup")],
                         [call for call in account_calls if call[0] in ("adduser", "addgroup")])
        self.assertFalse(any(call[:2] == ["chown", "-R"] and str(self.credentials) in call
                             for call in self.state()["calls"][len(account_calls):]))
        self.assertEqual(self.reservation_status(), "credentials=installed")
        self.assertTrue(self.state()["running"])

    def test_removed_credentials_require_explicit_same_vm_reenrollment(self):
        self.install()
        self.observe("uninstall", "--remove-credentials")
        before = self.tree()
        self.reinstall(reuse=True, success=False)
        self.assertEqual(self.tree(), before)
        (self.enrollment / "key.pem").write_bytes(b"new-fixture-key-not-real\n")
        self.reinstall(reuse=False)
        self.assertEqual((self.credentials / "key.pem").read_bytes(), b"new-fixture-key-not-real\n")
        self.assertEqual(self.reservation_status(), "credentials=installed")
        self.assertEqual(len([call for call in self.state()["calls"] if call[0] == "adduser"]), 1)

    def test_unknown_or_orphan_account_has_no_reservation_authority(self):
        self.install()
        self.observe("uninstall", "--remove-credentials")
        shutil.rmtree(self.reservation)
        before = self.tree()
        self.reinstall(reuse=False, success=False)
        self.assertEqual(self.tree(), before)
        self.install(success=False)
        self.assertEqual(self.tree(), before)

    def test_reinstall_wrong_vm_uid_gid_and_account_drift_reject_unchanged(self):
        self.install()
        self.observe("uninstall")
        before = self.tree()
        self.reinstall(vm_id="11234567-89ab-cdef-0123-456789abcdef", success=False)
        self.assertEqual(self.tree(), before)
        for key, value in (("uid", 446), ("gid", 447)):
            with self.subTest(identity=key):
                state = self.state(); state[key] = value; self.state_file.write_text(json.dumps(state))
                self.reinstall(success=False)
                self.assertEqual(self.tree(), before)
                state.pop(key); self.state_file.write_text(json.dumps(state))
        for name, previous, replacement in (("passwd", "/sbin/nologin", "/bin/sh"),
                                            ("shadow", "macopenvm-agent:!:", "macopenvm-agent::"),
                                            ("group", "macopenvm-agent:x:445:", "macopenvm-agent:x:445:other")):
            with self.subTest(contract=name):
                path = self.sysroot / "etc" / name
                original = path.read_text(); path.write_text(original.replace(previous, replacement))
                changed = self.tree()
                self.reinstall(success=False)
                self.assertEqual(self.tree(), changed)
                path.write_text(original)

    def test_retained_credential_drift_or_silent_rotation_rejects_unchanged(self):
        self.install()
        self.observe("uninstall")
        before = self.tree()
        self.reinstall(reuse=False, success=False)
        self.assertEqual(self.tree(), before)
        key = self.credentials / "key.pem"
        original = key.read_bytes(); key.write_bytes(b"drifted-fixture-key\n")
        changed = self.tree(); self.reinstall(success=False); self.assertEqual(self.tree(), changed)
        key.write_bytes(original); key.chmod(0o644)
        changed = self.tree(); self.reinstall(success=False); self.assertEqual(self.tree(), changed)

    def test_removed_reservation_rejects_other_vm_enrollment_unchanged(self):
        self.install()
        self.observe("uninstall", "--remove-credentials")
        (self.enrollment / "vm-id").write_text("11234567-89ab-cdef-0123-456789abcdef\n")
        before = self.tree(); self.reinstall(reuse=False, success=False); self.assertEqual(self.tree(), before)

    def test_interrupted_account_provisioning_preserves_group_lock_and_staging(self):
        self.install(extra_env={"MVO_FAIL_ADDUSER": "1"}, success=False)
        self.assertTrue(self.state()["group"])
        self.assertFalse(self.state()["user"])
        self.assertFalse(self.reservation.exists())
        self.assertTrue((self.sysroot / "var/lib/macopenvm-agent.install-lock").is_dir())
        stages = list((self.sysroot / "var/lib").glob(".macopenvm-agent-stage.*"))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0] / "credentials/key.pem").is_file())
        before = self.tree(); self.install(success=False); self.assertEqual(self.tree(), before)

    def test_reservation_marker_and_path_drift_rejects_without_adoption(self):
        self.install(); self.observe("uninstall")
        record = self.reservation / "record"
        original = record.read_bytes()
        for replacement in (original + b"extra\n", original.replace(b"account-v2", b"account-v2\x00")):
            record.write_bytes(replacement)
            before = self.tree(); self.reinstall(success=False); self.assertEqual(self.tree(), before)
        record.write_bytes(original); record.chmod(0o644)
        before = self.tree(); self.reinstall(success=False); self.assertEqual(self.tree(), before)

    def test_retained_state_extra_credential_hash_and_supplementary_group_reject_unchanged(self):
        self.install(); self.observe("uninstall")
        manifest = self.owned_state / "enrollment.sha256"
        saved = manifest.read_text()
        manifest.write_text(saved + "0" * 64 + "  unrelated\n")
        before = self.tree(); self.reinstall(success=False); self.assertEqual(self.tree(), before)
        manifest.write_text(saved)
        group = self.sysroot / "etc/group"
        group.write_text(group.read_text() + "unrelated:x:777:macopenvm-agent\n")
        before = self.tree(); self.reinstall(success=False); self.assertEqual(self.tree(), before)

    def test_reinstall_interrupted_reservation_publication_keeps_retained_state_and_credentials(self):
        self.install(); self.observe("uninstall")
        old_record = (self.reservation / "record").read_bytes()
        old_state = {path.name: path.read_bytes() for path in self.owned_state.iterdir()}
        old_credentials = {path.name: path.read_bytes() for path in self.credentials.iterdir()}
        failure_move = self.state()["moves"] + 1
        self.reinstall(extra_env={"MVO_FAIL_MOVE": str(failure_move)}, success=False)
        self.assertEqual((self.reservation / "record").read_bytes(), old_record)
        self.assertEqual({path.name: path.read_bytes() for path in self.owned_state.iterdir()}, old_state)
        self.assertEqual({path.name: path.read_bytes() for path in self.credentials.iterdir()}, old_credentials)
        self.assertTrue((self.reservation / "record.next").is_file())
        self.assertTrue((self.sysroot / "var/lib/macopenvm-agent.install-lock").is_dir())
        stages = list((self.sysroot / "var/lib").glob(".macopenvm-agent-stage.*"))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0] / "state/owner").is_file())

    def test_reinstall_failed_start_preserves_complete_staging_and_retained_credentials(self):
        self.install(); self.observe("uninstall")
        enrolled = {path.name: (path.read_bytes(), path.stat().st_ino) for path in self.credentials.iterdir()}
        self.reinstall(extra_env={"MVO_FAIL_START": "1"}, success=False)
        self.assertEqual({path.name: (path.read_bytes(), path.stat().st_ino)
                          for path in self.credentials.iterdir()}, enrolled)
        stages = list((self.sysroot / "var/lib").glob(".macopenvm-agent-stage.*"))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0] / "credentials/key.pem").is_file())
        self.assertTrue((stages[0] / "retained-state/owner").is_file())
        self.assertTrue(self.owned_state.is_dir())
        self.assertTrue((self.sysroot / "var/lib/macopenvm-agent.install-lock").is_dir())


if __name__ == "__main__":
    unittest.main()
