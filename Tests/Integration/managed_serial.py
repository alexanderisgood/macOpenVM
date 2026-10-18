# SPDX-License-Identifier: Apache-2.0
"""Small owned-child serial supervisor for explicitly prepared disposable labs.

No shell, restart, PID reconstruction, context-manager signals or implicit timeout
termination. Callers retain this actual owner and explicitly request cleanup.
The install protocol and selection of lawful fresh media belong to the caller.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import threading
import time

_CUSTODY = set()
_CUSTODY_LOCK = threading.Lock()


class ManagedSerialError(RuntimeError):
    def __init__(self, code, owner):
        super().__init__("Managed serial operation failed: " + code)
        self.code = code
        self.owner = owner


@dataclass(frozen=True)
class SerialSnapshot:
    started: bool
    returncode: int | None
    stdout: bytes
    stderr: bytes
    stdout_bytes: int
    stderr_bytes: int
    stdout_eof: bool
    stderr_eof: bool
    drains_finished: bool
    pipes_closed: bool
    transcripts_closed: bool
    transcript_truncated: bool
    first_error: str | None
    executable_unchanged: bool | None

    @property
    def is_active(self):
        return self.started and not (self.returncode is not None and self.stdout_eof
            and self.stderr_eof and self.drains_finished and self.pipes_closed and self.transcripts_closed)


def retained_supervisors():
    """Actual in-memory owners only, for exceptional recovery; never saved PID authority."""
    with _CUSTODY_LOCK:
        return tuple(_CUSTODY)


def _stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def executable_identity(path):
    """Stable no-follow bounded regular executable identity plus SHA256."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in (0, os.geteuid())
                or before.st_nlink != 1 or before.st_mode & 0o022
                or not 0 < before.st_size <= 128 << 20 or not before.st_mode & 0o111):
            raise ValueError("unsafe executable")
        digest = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            chunk = os.read(fd, min(1 << 20, remaining))
            if not chunk:
                raise ValueError("short executable")
            digest.update(chunk)
            remaining -= len(chunk)
        if os.read(fd, 1) or _stamp(before) != _stamp(os.fstat(fd)) or _stamp(before) != _stamp(path.lstat()):
            raise ValueError("changed executable")
        return _stamp(before), digest.hexdigest()
    finally:
        os.close(fd)


class ManagedSerial:
    def __init__(self, executable, arguments, *, cwd, artifacts, label,
                 environment=None, memory_limit=2 << 20, transcript_limit=8 << 20):
        self.executable = Path(executable)
        self.cwd = Path(cwd)
        self.artifacts = Path(artifacts)
        if (not all(path.is_absolute() and path == Path(os.path.abspath(path))
                    for path in (self.executable, self.cwd, self.artifacts))
                or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", label)
                or not isinstance(arguments, (list, tuple)) or len(arguments) > 128
                or any(not isinstance(arg, str) or "\0" in arg or len(arg.encode()) > 4096 for arg in arguments)
                or sum(len(arg.encode()) for arg in arguments) > 65536
                or not isinstance(memory_limit, int) or not 1 <= memory_limit <= 8 << 20
                or not isinstance(transcript_limit, int) or not 1 <= transcript_limit <= 32 << 20):
            raise ManagedSerialError("invalidConfiguration", self)
        for directory in (self.cwd, self.artifacts):
            info = directory.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise ManagedSerialError("unsafeDirectory", self)
        self._directory_stamp = _stamp(self.artifacts.lstat())[:4]
        self.identity = executable_identity(self.executable)
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"}
        if environment is not None:
            if (not isinstance(environment, dict) or len(environment) > 32
                    or any(not isinstance(key, str) or not re.fullmatch(r"[A-Z_][A-Z0-9_]{0,63}", key)
                        or key.startswith(("DYLD_", "LD_", "PYTHON")) or not isinstance(value, str)
                        or "\0" in value or len(value.encode()) > 4096 for key, value in environment.items())):
                raise ManagedSerialError("invalidEnvironment", self)
            env.update(environment)
        self._argv = [str(self.executable), *arguments]
        self._environment = env
        self._memory_limit = memory_limit
        self._transcript_limit = transcript_limit
        self._label = label
        self._condition = threading.Condition()
        self._process_lock = threading.RLock()
        self._input_lock = threading.Lock()
        self._process = None
        self._launch_resolved = False
        self._launch_attempted = False
        self._ready = False
        self._returncode = None
        self._first_error = None
        self._identity_unchanged = None
        self._streams = {name: dict(data=bytearray(), total=0, start=0, cursor=0,
            written=0, truncated=False, eof=False, finished=False, closed=False, pipe_closed=False,
            pipe=None, log=None, stamp=None, thread=None,
            path=self.artifacts / (label + "." + name)) for name in ("stdout", "stderr")}

    def _error(self, code):
        with self._condition:
            if self._first_error is None:
                self._first_error = code
            self._condition.notify_all()

    def launch(self):
        with self._process_lock:
            return self._launch_owned()

    def _launch_owned(self):
        if self._launch_attempted:
            raise ManagedSerialError("alreadyAttempted", self)
        self._launch_attempted = True
        try:
            if executable_identity(self.executable) != self.identity:
                raise ManagedSerialError("executableChanged", self)
            # Fallible transcript/thread preparation happens before creating a child.
            for name, stream in self._streams.items():
                stream["log"] = os.open(self.artifacts / (self._label + "." + name),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                os.fchmod(stream["log"], 0o600)
                stream["stamp"] = _stamp(os.fstat(stream["log"]))[:5]
            for name, stream in self._streams.items():
                stream["thread"] = threading.Thread(target=self._drain, args=(name,),
                    name="managed-serial-" + name, daemon=True)
                stream["thread"].start()
            with _CUSTODY_LOCK:
                _CUSTODY.add(self)
            self._process = subprocess.Popen(self._argv, executable=str(self.executable),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                cwd=self.cwd, env=self._environment, bufsize=0, close_fds=True, shell=False)
            # Publish both actual pipes before any subsequent fallible setup. The
            # already-running workers drain even if setup/identity checks fail.
            with self._condition:
                for name, stream in self._streams.items():
                    stream["pipe"] = getattr(self._process, name)
                self._launch_resolved = True
                self._condition.notify_all()
            self._post_spawn_setup()
            self._ready = True
            return self
        except BaseException:
            self._error("setupFailed")
            with self._condition:
                self._launch_resolved = True
                self._condition.notify_all()
            if self._process is None:
                self._close_unstarted_logs()
                self._release_if_settled()
            raise ManagedSerialError("setupFailed", self) from None

    def _post_spawn_setup(self):
        os.set_blocking(self._process.stdin.fileno(), False)
        if executable_identity(self.executable) != self.identity:
            raise ManagedSerialError("executableChanged", self)

    def _close_unstarted_logs(self):
        for stream in self._streams.values():
            thread = stream["thread"]
            if thread is None or thread.ident is None:
                self._finish_stream(stream)

    def _drain(self, name):
        stream = self._streams[name]
        with self._condition:
            while not self._launch_resolved:
                self._condition.wait()
            pipe = stream["pipe"]
        try:
            if pipe is None:
                return
            while True:
                try:
                    chunk = os.read(pipe.fileno(), 65536)
                except InterruptedError:
                    continue
                except OSError:
                    self._error("drainReadFailed")
                    break
                if not chunk:
                    with self._condition:
                        stream["eof"] = True
                    break
                with self._condition:
                    stream["total"] += len(chunk)
                    stream["data"].extend(chunk)
                    if len(stream["data"]) > self._memory_limit:
                        del stream["data"][:-self._memory_limit]
                    stream["start"] = stream["total"] - len(stream["data"])
                    self._condition.notify_all()
                room = self._transcript_limit - stream["written"]
                if len(chunk) > room:
                    stream["truncated"] = True
                    self._error("transcriptLimit")
                if room > 0 and stream["log"] is not None:
                    try:
                        self._write_transcript(stream, chunk[:room])
                    except OSError:
                        self._error("transcriptWriteFailed")
                        # Keep reading/discarding; a failed transcript cannot block the child.
                        stream["written"] = self._transcript_limit
        finally:
            if pipe is not None:
                try:
                    pipe.close()
                    stream["pipe_closed"] = True
                except OSError:
                    self._error("pipeCloseFailed")
            else:
                stream["pipe_closed"] = True
            self._finish_stream(stream)
            self._release_if_settled()

    def _write_transcript(self, stream, data):
        offset = 0
        while offset < len(data):
            try:
                count = os.write(stream["log"], data[offset:])
            except InterruptedError:
                continue
            if count <= 0:
                raise OSError("short transcript")
            offset += count
            stream["written"] += count

    def _finish_stream(self, stream):
        fd = stream["log"]
        if fd is not None:
            try:
                if (_stamp(os.fstat(fd))[:5] != stream["stamp"]
                        or _stamp(stream["path"].lstat())[:5] != stream["stamp"]
                        or _stamp(self.artifacts.lstat())[:4] != self._directory_stamp):
                    self._error("transcriptIdentityChanged")
                os.fsync(fd)
            except OSError:
                self._error("transcriptFlushFailed")
            try:
                os.close(fd)
                stream["closed"] = True
            except OSError:
                self._error("transcriptCloseFailed")
            stream["log"] = None
        else:
            stream["closed"] = True
        with self._condition:
            stream["finished"] = True
            self._condition.notify_all()

    def _observe_exit(self, deadline=None):
        self._acquire(self._process_lock, deadline)
        try:
            if self._process is not None:
                try:
                    value = self._process.poll()
                except OSError:
                    self._error("exitUnconfirmed")
                    return
                if value is not None:
                    with self._condition:
                        self._returncode = value
                        self._condition.notify_all()
        finally:
            self._process_lock.release()

    def snapshot(self, *, deadline=None):
        self._observe_exit(deadline)
        with self._condition:
            out, err = self._streams["stdout"], self._streams["stderr"]
            return SerialSnapshot(self._process is not None, self._returncode,
                bytes(out["data"]), bytes(err["data"]), out["total"], err["total"],
                out["eof"], err["eof"], out["finished"] and err["finished"],
                out["pipe_closed"] and err["pipe_closed"],
                out["closed"] and err["closed"], out["truncated"] or err["truncated"],
                self._first_error, self._identity_unchanged)

    def _release_if_settled(self):
        with self._condition:
            settled = self._launch_resolved and (self._process is None or (
                self._returncode is not None and all(stream["eof"] and stream["finished"]
                    and stream["closed"] and stream["pipe_closed"] for stream in self._streams.values())))
        if settled:
            with _CUSTODY_LOCK:
                _CUSTODY.discard(self)

    def _deadline(self, deadline):
        now = time.monotonic()
        if (type(deadline) not in (float, int)
                or type(deadline) is float and not math.isfinite(deadline)
                or deadline > now + 3600):
            raise ManagedSerialError("invalidDeadline", self)
        return 0 if deadline <= now else deadline - now

    def _remaining(self, deadline):
        remaining = self._deadline(deadline)
        if remaining <= 0:
            raise ManagedSerialError("deadlineExceeded", self)
        return remaining

    def _acquire(self, lock, deadline):
        if deadline is None:
            lock.acquire()
        elif not lock.acquire(timeout=self._remaining(deadline)):
            raise ManagedSerialError("deadlineExceeded", self)

    def mark(self, stream="stdout"):
        if stream not in self._streams:
            raise ManagedSerialError("invalidStream", self)
        with self._condition:
            return self._streams[stream]["total"]

    def expect(self, needle, *, deadline, after=None, stream="stdout"):
        self._remaining(deadline)
        if (not self._ready or stream not in self._streams or not isinstance(needle, bytes)
                or not 1 <= len(needle) <= 4096 or after is not None and (not isinstance(after, int) or after < 0)):
            raise ManagedSerialError("invalidExpectation", self)
        while True:
            self._observe_exit(deadline)
            with self._condition:
                state = self._streams[stream]
                cursor = state["cursor"] if after is None else after
                if self._first_error is not None:
                    raise ManagedSerialError(self._first_error, self)
                if cursor < state["start"]:
                    raise ManagedSerialError("responseWindowLost", self)
                index = state["data"].find(needle, cursor - state["start"])
                if index >= 0:
                    self._remaining(deadline)
                    end = state["start"] + index + len(needle)
                    state["cursor"] = end
                    return end
                if state["eof"]:
                    raise ManagedSerialError("responseMissing", self)
                remaining = self._deadline(deadline)
                if remaining <= 0:
                    raise ManagedSerialError("deadlineExceeded", self)
                self._condition.wait(min(remaining, 0.1))

    def write(self, payload, *, deadline):
        self._remaining(deadline)
        if not self._ready or not isinstance(payload, bytes) or not 1 <= len(payload) <= 4096:
            raise ManagedSerialError("invalidWrite", self)
        self._acquire(self._input_lock, deadline)
        try:
            try:
                fd = self._process.stdin.fileno()
                offset = 0
                while offset < len(payload):
                    remaining = self._deadline(deadline)
                    if remaining <= 0:
                        raise ManagedSerialError("deadlineExceeded", self)
                    if not select.select([], [fd], [], remaining)[1]:
                        raise ManagedSerialError("deadlineExceeded", self)
                    try:
                        count = os.write(fd, payload[offset:])
                    except (BlockingIOError, InterruptedError):
                        continue
                    if count <= 0:
                        raise OSError("short input")
                    offset += count
                self._remaining(deadline)
            except (OSError, ValueError):
                raise ManagedSerialError("inputFailed", self) from None
        finally:
            self._input_lock.release()

    def close_input(self, *, deadline):
        self._remaining(deadline)
        self._acquire(self._input_lock, deadline)
        try:
            self._remaining(deadline)
            if self._process is not None:
                try:
                    self._process.stdin.close()
                except OSError:
                    self._error("inputCloseFailed")
            self._remaining(deadline)
        finally:
            self._input_lock.release()

    def wait(self, *, deadline):
        self._remaining(deadline)
        if not self._launch_attempted:
            raise ManagedSerialError("notLaunched", self)
        while True:
            state = self.snapshot(deadline=deadline)
            if not state.is_active and state.drains_finished:
                self.close_input(deadline=deadline)
                if state.started and self._identity_unchanged is None:
                    try:
                        self._identity_unchanged = executable_identity(self.executable) == self.identity
                    except (OSError, ValueError):
                        self._identity_unchanged = False
                    if not self._identity_unchanged:
                        self._error("executableChanged")
                self._release_if_settled()
                result = self.snapshot(deadline=deadline)
                self._remaining(deadline)
                return result
            remaining = self._deadline(deadline)
            if remaining <= 0:
                raise ManagedSerialError("deadlineExceeded", self)
            with self._condition:
                self._condition.wait(min(remaining, 0.1))

    def _signal(self, kill, deadline=None):
        # All our reap/signal operations share this mutex, and the actual Popen is
        # private. Once observed terminal, no later request can signal a reused PID.
        self._acquire(self._process_lock, deadline)
        try:
            self._observe_exit(deadline)
            if self._process is not None and self._returncode is None:
                (self._process.kill if kill else self._process.terminate)()
        finally:
            self._process_lock.release()

    def terminate(self, *, deadline=None):
        self._signal(False, deadline)

    def kill(self, *, deadline=None):
        self._signal(True, deadline)

    def cleanup(self, *, deadline, kill_after=1.0):
        """Explicitly authorize ending this owned disposable child; no groups or restarts."""
        self._remaining(deadline)
        if type(kill_after) not in (float, int) or not 0 <= kill_after <= 30:
            raise ManagedSerialError("invalidCleanup", self)
        # Signal the actual child before acquiring a possibly busy input lock.
        # Closing its read end wakes an in-flight pipe writer; input close is bounded.
        self.terminate(deadline=deadline)
        escalate = time.monotonic() + kill_after
        killed = False
        while True:
            if not killed and time.monotonic() >= escalate:
                self.kill(deadline=deadline)
                killed = True
            try:
                return self.wait(deadline=min(deadline, time.monotonic() + 0.1))
            except ManagedSerialError as error:
                if error.code != "deadlineExceeded" or self._deadline(deadline) <= 0:
                    # A deadline/read failure never fabricates terminal/EOF evidence.
                    # The global set retains this actual owner for explicit recovery.
                    raise
