# SPDX-License-Identifier: Apache-2.0
"""Real private filesystem/proc fixtures, fake ownership/OpenRC; no native guest claim."""
from contextlib import contextmanager
from pathlib import Path
import unittest

from linux_agent_transaction_fixture import GenerationFixture


def status_bytes(number=4001, *, ids=(0, 0, 0, 0), state="S", kernel=0):
    return (f"Name:\tfixture\nState:\t{state} (fixture)\nTgid:\t{number}\nPid:\t{number}\n"
            + "Uid:\t" + "\t".join(str(value) for value in ids)
            + f"\nKthread:\t{kernel}\n").encode()


class LinuxAgentQuiescenceTests(unittest.TestCase):
    @contextmanager
    def installed(self):
        fixture = GenerationFixture()
        try:
            # Every invocation and both approved payloads use the same captured manager.
            manager = fixture.manager_script.read_bytes()
            self.assertEqual(manager, (fixture.payload_a / "setup.sh").read_bytes())
            self.assertEqual(manager, (fixture.payload_b / "setup.sh").read_bytes())
            fixture.install()
            yield fixture
        finally:
            fixture.close()

    def assert_refused_without_replacement(self, fixture, *, message, environment=None):
        protected = fixture.protected()
        kernel = fixture.path_identity(fixture.kernel_lock)
        current = {str(path): fixture.path_identity(path)
                   for directory in (fixture.program, fixture.owned_state)
                   for path in (directory, *directory.iterdir())}
        call_offset = len(fixture.state()["calls"])
        result = fixture.upgrade(success=False, extra_env=environment)
        self.assertIn(message, result.stderr)
        self.assertEqual(fixture.current_pin(), fixture.pin_a)
        self.assertEqual({name: fixture.path_identity(Path(name))
                          for name in current}, current)
        self.assertEqual(fixture.protected(), protected)
        self.assertEqual(fixture.path_identity(fixture.kernel_lock), kernel)
        fixture.assert_generations_present(self)
        self.assertEqual((fixture.slot(fixture.owned_state, "next") / "payload.sha256").read_bytes(),
                         (fixture.payload_b / "SHA256SUMS").read_bytes())
        self.assertIn(b"phase=stop\n", fixture.journal.read_bytes())
        self.assertFalse(fixture.slot(fixture.program, "previous").exists())
        self.assertFalse(fixture.slot(fixture.owned_state, "previous").exists())
        calls = fixture.state()["calls"][call_offset:]
        self.assertEqual([call for call in calls if call[0] == "rc-service" and call[2] != "status"],
                         [["rc-service", "macopenvm-agent", "stop"]])
        self.assertFalse(any(call[0] in ("rc-update", "addgroup", "adduser") for call in calls))
        # Journal publications may move. Current/retained generation names may not.
        forbidden = {str(fixture.program), str(fixture.owned_state)}
        for call in calls:
            if call[0] == "mv":
                self.assertTrue(forbidden.isdisjoint(call[1:]))
        self.assertFalse(fixture.state()["running"])
        self.assertFalse(list((fixture.sysroot / "var/lib").glob(".macopenvm-agent-proc.*")))

    def transition_at_exe_failure(self, fixture, process, *, status, cmdline=b"", read_error=None):
        """Mutate only private proc files at one failed follow-stat rendezvous.

        The immutable manager still reads actual private files through its own
        bounded operations. No PID, signal, process-name or command result is
        accepted as authority by this fixture. Shared helpers are untouched.
        """
        executable = process / "exe"
        self.assertTrue(executable.is_symlink())
        self.assertFalse(executable.exists())
        environment = {"MVO_PROC_TRANSITION_EXE": str(executable)}
        for name, data in (("status", status), ("cmdline", cmdline)):
            key = "MVO_PROC_TRANSITION_" + name.upper()
            if data is None:
                environment[key] = "remove"
            else:
                source = fixture.base / ("proc-after-" + name)
                source.write_bytes(data)
                source.chmod(0o600)
                environment[key] = str(source)
        if read_error:
            environment["MVO_FAIL_DD_AFTER_PROC_TRANSITION"] = str(process / read_error)
        # Inject into these individual fixture command copies after initial A
        # installation, never into shared FAKE_RUNNER or either payload manager.
        command = fixture.commands / "stat"
        source = command.read_text()
        anchor = "    info = os.fstat(9) if follow and name == \"/dev/fd/9\" else os.stat(name) if follow else os.lstat(name)\n"
        self.assertEqual(source.count(anchor), 1)
        hook = '''    if follow and spec == "%d:%i" and name == os.environ.get("MVO_PROC_TRANSITION_EXE") and not state.get("proc_exe_transitions"):
        try: os.stat(name)
        except FileNotFoundError: pass
        else: fail()
        process = pathlib.Path(name).parent
        for entry in ("status", "cmdline"):
            replacement = os.environ["MVO_PROC_TRANSITION_" + entry.upper()]
            if replacement == "remove": (process / entry).unlink()
            else: (process / entry).write_bytes(pathlib.Path(replacement).read_bytes())
        state["proc_exe_transitions"] = 1
        save()
'''
        command.write_text(source.replace(anchor, hook + anchor))
        command = fixture.commands / "dd"
        source = command.read_text()
        anchor = "    if selected == os.environ.get(\"MVO_FAIL_DD_INPUT\"): fail()\n"
        self.assertEqual(source.count(anchor), 1)
        hook = '''    if state.get("proc_exe_transitions") and selected == os.environ.get("MVO_FAIL_DD_AFTER_PROC_TRANSITION"): fail()
'''
        command.write_text(source.replace(anchor, anchor + hook))
        return environment

    def test_each_dedicated_uid_field_blocks_even_with_unrelated_executable(self):
        for position in range(4):
            with self.subTest(uid_field=position), self.installed() as fixture:
                ids = [0, 0, 0, 0]
                ids[position] = 444
                fixture.process(status=status_bytes(ids=ids), executable=fixture.commands / "id",
                                cmdline=b"id\0")
                self.assert_refused_without_replacement(fixture, message=b"service process is still present")

    def test_root_process_with_current_or_staged_agent_inode_blocks(self):
        for slot in ("current", "next"):
            with self.subTest(slot=slot), self.installed() as fixture:
                directory = fixture.program if slot == "current" else fixture.slot(fixture.program, "next")
                fixture.process(executable=directory / "macopenvm-agent", cmdline=b"agent\0")
                self.assert_refused_without_replacement(fixture, message=b"agent process is still present")

    def test_actual_supervisor_inode_and_standalone_service_argument_block(self):
        for action in (b"--start", b"--reexec"):
            with self.subTest(action=action), self.installed() as fixture:
                fixture.process(executable=fixture.commands / "supervise-daemon",
                                cmdline=b"/sbin/supervise-daemon\0macopenvm-agent\0" + action + b"\0")
                self.assert_refused_without_replacement(fixture, message=b"supervisor is still present")

    def test_missing_malformed_and_oversized_status_preserve_generations(self):
        valid = status_bytes()
        cases = {
            "missing_uid": valid.replace(b"Uid:\t0\t0\t0\t0\n", b""),
            "duplicate_uid": valid + b"Uid:\t0\t0\t0\t0\n",
            "wrong_pid": valid.replace(b"Pid:\t4001\n", b"Pid:\t4002\n"),
            "wrong_tgid": valid.replace(b"Tgid:\t4001\n", b"Tgid:\t4002\n"),
            "invalid_state": status_bytes(state="?"),
            "bad_kernel_flag": status_bytes(kernel=2),
            "oversized": valid + b"x" * 65537,
            "missing_file": valid,
        }
        for case, data in cases.items():
            with self.subTest(case=case), self.installed() as fixture:
                process = fixture.process(status=data, executable=fixture.commands / "id", cmdline=b"id\0")
                if case == "missing_file":
                    (process / "status").unlink()
                message = b"read completely" if case in ("oversized", "missing_file") else b"identity is malformed"
                self.assert_refused_without_replacement(fixture, message=message)

    def test_supervisor_argument_bounds_grammar_and_missing_file_refuse(self):
        cases = {
            "empty": b"",
            "unterminated": b"supervise-daemon\0other-service",
            "wrong_executable_name": b"different-program\0other-service\0",
            "empty_service": b"supervise-daemon\0\0",
            "control_byte": b"supervise-daemon\0other\nservice\0",
            "oversized": b"supervise-daemon\0other-service\0" + b"x" * 4097,
            "missing_file": b"supervise-daemon\0other-service\0",
        }
        for case, data in cases.items():
            with self.subTest(case=case), self.installed() as fixture:
                process = fixture.process(executable=fixture.commands / "supervise-daemon", cmdline=data)
                if case == "missing_file":
                    (process / "cmdline").unlink()
                message = b"read completely" if case in ("oversized", "missing_file") else b"argument"
                self.assert_refused_without_replacement(fixture, message=message)

    def test_status_and_cmdline_read_failures_cannot_mean_no_process(self):
        for file in ("status", "cmdline"):
            with self.subTest(file=file), self.installed() as fixture:
                process = fixture.process(executable=fixture.commands / "supervise-daemon",
                                          cmdline=b"supervise-daemon\0other-service\0")
                self.assert_refused_without_replacement(
                    fixture, message=b"read completely",
                    environment={"MVO_FAIL_DD_INPUT": str(process / file)})

    def test_hidden_live_executable_and_unproven_empty_process_refuse(self):
        for case in ("arguments_without_exe", "empty_user_process", "dangling_exe"):
            with self.subTest(case=case), self.installed() as fixture:
                fixture.process(executable=fixture.base / "absent-executable" if case == "dangling_exe" else None,
                                cmdline=b"live-program\0" if case == "arguments_without_exe" else b"")
                self.assert_refused_without_replacement(
                    fixture, message=b"executable cannot be inspected")

    def test_nonservice_supervisor_kernel_thread_and_root_zombie_are_admitted(self):
        with self.installed() as fixture:
            fixture.process(number=4001, executable=fixture.commands / "supervise-daemon",
                            cmdline=b"/sbin/supervise-daemon\0unrelated-service\0--start\0")
            fixture.process(number=4002, kernel=True)
            fixture.process(number=4003, state="Z")
            protected = fixture.protected()
            fixture.upgrade()
            self.assertEqual(fixture.current_pin(), fixture.pin_b)
            self.assertEqual(fixture.protected(), protected)
            self.assertTrue(fixture.state()["running"])

    def test_kernel_thread_and_terminal_process_dangling_exe_links_are_admitted(self):
        # Linux procfs exposes an exe symlink inode whose resolution returns
        # ENOENT for PF_KTHREAD or a task that has released its mm. These are
        # real private dangling links, not an absent-exe shortcut in the shim.
        with self.installed() as fixture:
            for number, state, kernel in ((4001, "S", True), (4002, "Z", False),
                                          (4003, "X", False)):
                process = fixture.process(number=number, state=state, kernel=kernel,
                                          executable=fixture.base / "no-executable")
                self.assertTrue((process / "exe").is_symlink())
                self.assertFalse((process / "exe").exists())
            protected = fixture.protected()
            fixture.upgrade()
            self.assertEqual(fixture.current_pin(), fixture.pin_b)
            self.assertEqual(fixture.protected(), protected)
            self.assertTrue(fixture.state()["running"])

    def test_terminal_or_kernel_status_cannot_hide_any_dedicated_uid(self):
        for state, kernel in (("Z", 0), ("S", 1)):
            for position in range(4):
                with self.subTest(state=state, uid_field=position), self.installed() as fixture:
                    ids = [0, 0, 0, 0]
                    ids[position] = 444
                    fixture.process(status=status_bytes(ids=ids, state=state, kernel=kernel),
                                    executable=fixture.base / "no-executable")
                    self.assert_refused_without_replacement(
                        fixture, message=b"service process is still present")

    def test_dangling_terminal_or_kernel_exe_requires_valid_empty_readable_arguments(self):
        cases = {
            "terminal_arguments": (status_bytes(state="Z"), b"live-program\0", None),
            "kernel_arguments": (status_bytes(kernel=1), b"live-program\0", None),
            "nonroot_kernel": (status_bytes(ids=(1000, 1000, 1000, 1000), kernel=1), b"", None),
            "missing_terminal_arguments": (status_bytes(state="Z"), b"", "missing"),
            "oversized_kernel_arguments": (status_bytes(kernel=1), b"x" * 4097, None),
            "unreadable_terminal_arguments": (status_bytes(state="Z"), b"", "read_error"),
        }
        for case, (status, cmdline, failure) in cases.items():
            with self.subTest(case=case), self.installed() as fixture:
                process = fixture.process(status=status, cmdline=cmdline,
                                          executable=fixture.base / "no-executable")
                environment = None
                if failure == "missing":
                    (process / "cmdline").unlink()
                elif failure == "read_error":
                    environment = {"MVO_FAIL_DD_INPUT": str(process / "cmdline")}
                self.assert_refused_without_replacement(
                    fixture, message=b"Experimental agent setup:", environment=environment)

    def test_failed_exe_resolution_rechecks_fresh_terminal_status_before_admission(self):
        for state in ("Z", "X"):
            with self.subTest(state=state), self.installed() as fixture:
                process = fixture.process(executable=fixture.base / "no-executable",
                                          cmdline=b"exiting-program\0")
                environment = self.transition_at_exe_failure(
                    fixture, process, status=status_bytes(state=state))
                protected = fixture.protected()
                fixture.upgrade(extra_env=environment)
                self.assertEqual(fixture.state().get("proc_exe_transitions"), 1)
                self.assertEqual(fixture.current_pin(), fixture.pin_b)
                self.assertEqual(fixture.protected(), protected)
                self.assertTrue(fixture.state()["running"])

    def test_failed_exe_resolution_cannot_hide_refreshed_identity_or_read_failures(self):
        valid = status_bytes(state="Z")
        cases = {
            "still_active": (status_bytes(), b"", None),
            "terminal_arguments": (valid, b"still-live\0", None),
            "missing_uid": (valid.replace(b"Uid:\t0\t0\t0\t0\n", b""), b"", None),
            "wrong_pid": (valid.replace(b"Pid:\t4001\n", b"Pid:\t4002\n"), b"", None),
            "wrong_tgid": (valid.replace(b"Tgid:\t4001\n", b"Tgid:\t4002\n"), b"", None),
            "oversized_status": (valid + b"x" * 65537, b"", None),
            "missing_status": (None, b"", None),
            "missing_arguments": (valid, None, None),
            "status_read_error": (valid, b"", "status"),
            "arguments_read_error": (valid, b"", "cmdline"),
            "oversized_arguments": (valid, b"x" * 4097, None),
        }
        for position in range(4):
            ids = [0, 0, 0, 0]
            ids[position] = 444
            cases["refreshed_uid_" + str(position)] = (status_bytes(ids=ids, state="Z"), b"", None)
        for case, (status, cmdline, read_error) in cases.items():
            with self.subTest(case=case), self.installed() as fixture:
                process = fixture.process(executable=fixture.base / "no-executable",
                                          cmdline=b"exiting-program\0")
                environment = self.transition_at_exe_failure(
                    fixture, process, status=status, cmdline=cmdline, read_error=read_error)
                self.assert_refused_without_replacement(
                    fixture, message=b"Experimental agent setup:", environment=environment)
                self.assertEqual(fixture.state().get("proc_exe_transitions"), 1)


if __name__ == "__main__":
    unittest.main()
