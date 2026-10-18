# SPDX-License-Identifier: Apache-2.0
"""Actual tiny owned children only; no VM, media, packages or existing fixtures."""
import os
from pathlib import Path
import stat
import sys
import tempfile
import select
import threading
import time
import unittest
from unittest import mock
import weakref

from managed_serial import ManagedSerial, ManagedSerialError, retained_supervisors


class ManagedSerialTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mvo-managed-serial-")
        self.root = Path(self.temporary.name).resolve()
        self.cwd = self.root / "child"
        self.logs = self.root / "logs"
        self.cwd.mkdir(mode=0o700)
        self.logs.mkdir(mode=0o700)
        self.owners = []

    def tearDown(self):
        settled = True
        for owner in self.owners:
            try:
                if owner.snapshot().is_active:
                    owner.cleanup(deadline=time.monotonic() + 5, kill_after=0.05)
                elif owner._launch_attempted:
                    owner.wait(deadline=time.monotonic() + 5)
            except (ManagedSerialError, OSError):
                settled = False
        if settled:
            self.temporary.cleanup()
        else:
            # Preserve the actual owner's private transcripts instead of deleting
            # evidence while exit/EOF/resource closure remains unconfirmed.
            self.temporary._finalizer.detach()
            self.fail("Disposable child settlement is unconfirmed; fixture retained")

    def owner(self, program, **limits):
        value = ManagedSerial(Path(sys.executable).resolve(), ["-I", "-S", "-u", "-c", program],
            cwd=self.cwd, artifacts=self.logs, label="child-" + str(len(self.owners)), **limits)
        self.owners.append(value)
        return value

    def assert_settled(self, snapshot):
        self.assertIsNotNone(snapshot.returncode)
        self.assertTrue(snapshot.stdout_eof and snapshot.stderr_eof)
        self.assertTrue(snapshot.drains_finished and snapshot.pipes_closed and snapshot.transcripts_closed)
        self.assertFalse(snapshot.is_active)
        self.assertTrue(snapshot.executable_unchanged)

    def test_fragmented_prompt_and_bounded_acknowledged_write(self):
        owner = self.owner("import os,sys,time; os.write(1,b'rea'); time.sleep(.03); "
                           "os.write(1,b'dy> '); line=sys.stdin.buffer.readline(); "
                           "os.write(2,b'host-note\\n'); os.write(1,b'ack:'+line)")
        owner.launch()
        owner.expect(b"ready> ", deadline=time.monotonic() + 3)
        cursor = owner.mark()
        owner.write(b"hello\n", deadline=time.monotonic() + 3)
        owner.expect(b"ack:hello\n", after=cursor, deadline=time.monotonic() + 3)
        result = owner.wait(deadline=time.monotonic() + 3)
        self.assert_settled(result)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"ready> ack:hello\n")
        self.assertEqual(result.stderr, b"host-note\n")
        self.assertIsNone(result.first_error)
        self.assertNotIn(owner, retained_supervisors())
        for name in ("stdout", "stderr"):
            path = self.logs / ("child-0." + name)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.read_bytes(), getattr(result, name))

    def test_expect_timeout_preserves_live_child_until_explicit_cleanup(self):
        owner = self.owner("import os,sys; os.write(1,b'waiting\\n'); sys.stdin.buffer.read()")
        owner.launch()
        owner.expect(b"waiting\n", deadline=time.monotonic() + 3)
        with self.assertRaises(ManagedSerialError) as caught:
            owner.expect(b"absent", deadline=time.monotonic() + .05)
        self.assertEqual(caught.exception.code, "deadlineExceeded")
        self.assertIs(caught.exception.owner, owner)
        self.assertIsNone(owner.snapshot().returncode)
        self.assertIn(owner, retained_supervisors())
        result = owner.cleanup(deadline=time.monotonic() + 3, kill_after=.05)
        self.assert_settled(result)

    def test_stdout_stderr_flood_remains_drained_after_both_caps(self):
        program = ("import os,threading; "
                   "t=threading.Thread(target=lambda:[os.write(2,b'B'*4096) for _ in range(128)]); "
                   "t.start(); [os.write(1,b'A'*4096) for _ in range(128)]; t.join()")
        owner = self.owner(program, memory_limit=128, transcript_limit=256)
        result = owner.launch().wait(deadline=time.monotonic() + 5)
        self.assert_settled(result)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout_bytes, 128 * 4096)
        self.assertEqual(result.stderr_bytes, 128 * 4096)
        self.assertEqual(len(result.stdout), 128)
        self.assertEqual(len(result.stderr), 128)
        self.assertTrue(result.transcript_truncated)
        self.assertEqual(result.first_error, "transcriptLimit")
        self.assertEqual((self.logs / "child-0.stdout").stat().st_size, 256)
        self.assertEqual((self.logs / "child-0.stderr").stat().st_size, 256)

    def test_stderr_is_drained_while_stdout_waits_for_input(self):
        program = ("import os,sys; [os.write(2,b'Z'*4096) for _ in range(64)]; "
                   "os.write(1,b'input> '); data=sys.stdin.buffer.readline(); os.write(1,b'ok:'+data)")
        owner = self.owner(program)
        owner.launch()
        owner.expect(b"input> ", deadline=time.monotonic() + 3)
        cursor = owner.mark()
        owner.write(b"yes\n", deadline=time.monotonic() + 3)
        owner.expect(b"ok:yes\n", after=cursor, deadline=time.monotonic() + 3)
        result = owner.wait(deadline=time.monotonic() + 3)
        self.assert_settled(result)
        self.assertEqual(result.stderr_bytes, 64 * 4096)
        self.assertIsNone(result.first_error)

    def test_post_spawn_setup_failure_retains_actual_handle_and_drains(self):
        owner = self.owner("import os,sys; os.write(1,b'alive\\n'); sys.stdin.buffer.read()")
        with mock.patch.object(owner, "_post_spawn_setup", side_effect=OSError("injected setup")):
            with self.assertRaises(ManagedSerialError) as caught:
                owner.launch()
        self.assertEqual(caught.exception.code, "setupFailed")
        self.assertIs(caught.exception.owner, owner)
        self.assertTrue(owner.snapshot().started)
        self.assertIn(owner, retained_supervisors())
        result = owner.cleanup(deadline=time.monotonic() + 3, kill_after=.05)
        self.assert_settled(result)
        self.assertEqual(result.first_error, "setupFailed")

    def test_existing_transcript_setup_failure_never_overwrites_or_starts_child(self):
        owner = self.owner("raise SystemExit(99)")
        path = self.logs / "child-0.stdout"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, b"preserved")
        os.close(fd)
        with self.assertRaises(ManagedSerialError):
            owner.launch()
        result = owner.wait(deadline=time.monotonic() + 3)
        self.assertFalse(result.started)
        self.assertIsNone(result.returncode)
        self.assertEqual(path.read_bytes(), b"preserved")
        self.assertNotIn(owner, retained_supervisors())

    def test_failed_launch_closes_prepared_transcripts_without_fabricating_exit(self):
        owner = self.owner("raise SystemExit(99)")
        self.cwd.rmdir()
        with self.assertRaises(ManagedSerialError):
            owner.launch()
        result = owner.wait(deadline=time.monotonic() + 3)
        self.assertFalse(result.started)
        self.assertIsNone(result.returncode)
        self.assertTrue(result.drains_finished and result.transcripts_closed)
        self.assertEqual(result.first_error, "setupFailed")

    def test_transcript_write_failure_still_drains_both_pipes_to_eof(self):
        owner = self.owner("import os; [os.write(1,b'A'*4096) for _ in range(64)]; "
                           "[os.write(2,b'B'*4096) for _ in range(64)]")
        with mock.patch.object(owner, "_write_transcript", side_effect=OSError("injected transcript")):
            result = owner.launch().wait(deadline=time.monotonic() + 5)
        self.assert_settled(result)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout_bytes, 64 * 4096)
        self.assertEqual(result.stderr_bytes, 64 * 4096)
        self.assertEqual(result.first_error, "transcriptWriteFailed")

    def test_output_eof_and_caller_loss_do_not_drop_live_child_custody(self):
        owner = self.owner("import os,sys; os.close(1); os.close(2); sys.stdin.buffer.read()")
        owner.launch()
        deadline = time.monotonic() + 3
        while not owner.snapshot().drains_finished and time.monotonic() < deadline:
            time.sleep(.01)
        state = owner.snapshot()
        self.assertTrue(state.stdout_eof and state.stderr_eof and state.drains_finished)
        self.assertIsNone(state.returncode)
        witness = weakref.ref(owner)
        self.owners.remove(owner)
        owner = None
        time.sleep(.03)
        recovered = witness()
        self.assertIsNotNone(recovered)
        self.owners.append(recovered)
        self.assertIn(recovered, retained_supervisors())
        self.assert_settled(recovered.cleanup(deadline=time.monotonic() + 3, kill_after=.05))

    def test_terminal_observation_blocks_later_signal_requests(self):
        owner = self.owner("raise SystemExit(0)")
        result = owner.launch().wait(deadline=time.monotonic() + 3)
        self.assert_settled(result)
        with mock.patch.object(owner._process, "terminate") as terminate, mock.patch.object(owner._process, "kill") as kill:
            owner.terminate()
            owner.kill()
            terminate.assert_not_called()
            kill.assert_not_called()

    def test_invalid_or_expired_deadlines_reject_buffered_and_settled_success(self):
        owner = self.owner("import os,sys; os.write(1,b'buffered\\n'); sys.stdin.buffer.read()")
        owner.launch()
        owner.expect(b"buffered\n", deadline=time.monotonic() + 3)
        cursor = owner._streams["stdout"]["cursor"]
        invalid = [(None, "invalidDeadline"), (True, "invalidDeadline"),
                   (float("nan"), "invalidDeadline"), (float("inf"), "invalidDeadline"),
                   (10**1000, "invalidDeadline"), (time.monotonic() + 7200, "invalidDeadline"),
                   (time.monotonic() - 1, "deadlineExceeded")]
        for deadline, reason in invalid:
            with self.subTest(deadline_type=type(deadline).__name__, reason=reason):
                with self.assertRaises(ManagedSerialError) as caught:
                    owner.expect(b"buffered\n", after=0, deadline=deadline)
                self.assertEqual(caught.exception.code, reason)
                self.assertEqual(owner._streams["stdout"]["cursor"], cursor)
                self.assertIsNone(owner.snapshot().returncode)
        self.assert_settled(owner.cleanup(deadline=time.monotonic() + 3, kill_after=.05))
        for deadline, reason in invalid:
            with self.subTest(settled=True, deadline_type=type(deadline).__name__, reason=reason):
                with self.assertRaises(ManagedSerialError) as caught:
                    owner.wait(deadline=deadline)
                self.assertEqual(caught.exception.code, reason)

    def test_expiry_before_buffered_match_return_does_not_advance_cursor(self):
        owner = self.owner("import os,sys; os.write(1,b'buffered\\n'); sys.stdin.buffer.read()")
        owner.launch()
        owner.expect(b"buffered\n", deadline=time.monotonic() + 3)
        cursor = owner._streams["stdout"]["cursor"]
        original = owner._observe_exit
        def delayed(deadline=None):
            original(deadline)
            time.sleep(.2)
        with mock.patch.object(owner, "_observe_exit", side_effect=delayed):
            with self.assertRaises(ManagedSerialError) as caught:
                owner.expect(b"buffered\n", after=0, deadline=time.monotonic() + .1)
        self.assertEqual(caught.exception.code, "deadlineExceeded")
        self.assertEqual(owner._streams["stdout"]["cursor"], cursor)

    def test_expiry_before_settled_return_is_rechecked(self):
        owner = self.owner("raise SystemExit(0)")
        self.assert_settled(owner.launch().wait(deadline=time.monotonic() + 3))
        original = owner.snapshot
        calls = []
        def delayed(*, deadline=None):
            value = original(deadline=deadline)
            calls.append(1)
            if len(calls) == 2:
                time.sleep(.2)
            return value
        with mock.patch.object(owner, "snapshot", side_effect=delayed):
            with self.assertRaises(ManagedSerialError) as caught:
                owner.wait(deadline=time.monotonic() + .1)
        self.assertEqual(caught.exception.code, "deadlineExceeded")
        self.assertEqual(len(calls), 2)

    def test_blocked_input_writer_does_not_hold_short_cleanup_deadline(self):
        owner = self.owner("import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                           "os.write(1,b'ready\\n'); time.sleep(60)")
        owner.launch()
        owner.expect(b"ready\n", deadline=time.monotonic() + 3)
        outcomes = []
        def fill_input():
            try:
                for _ in range(1024):
                    owner.write(b"X" * 4096, deadline=time.monotonic() + 5)
            except ManagedSerialError as error:
                outcomes.append(error.code)
        writer = threading.Thread(target=fill_input, name="managed-serial-test-writer")
        writer.start()
        try:
            until = time.monotonic() + 3
            fd = owner._process.stdin.fileno()
            while time.monotonic() < until:
                if owner._input_lock.locked() and not select.select([], [fd], [], 0)[1]:
                    break
                time.sleep(.005)
            else:
                self.fail("Original child did not establish real stdin backpressure")
            for operation in (lambda: owner.write(b"late", deadline=time.monotonic() + .03),
                              lambda: owner.close_input(deadline=time.monotonic() + .03)):
                began = time.monotonic()
                with self.assertRaises(ManagedSerialError) as caught:
                    operation()
                self.assertEqual(caught.exception.code, "deadlineExceeded")
                self.assertLess(time.monotonic() - began, .5)
            began = time.monotonic()
            result = owner.cleanup(deadline=time.monotonic() + .75, kill_after=.03)
            self.assertLess(time.monotonic() - began, 1.0)
            self.assert_settled(result)
            self.assertEqual(result.returncode, -9)
            writer.join(timeout=1)
            self.assertFalse(writer.is_alive())
            self.assertEqual(outcomes, ["inputFailed"])
        finally:
            if writer.is_alive():
                owner.cleanup(deadline=time.monotonic() + 3, kill_after=0)
                writer.join(timeout=1)
            self.assertFalse(writer.is_alive())


if __name__ == "__main__":
    unittest.main()
