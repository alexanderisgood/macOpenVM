# SPDX-License-Identifier: Apache-2.0
"""Private installer transaction fixture. No real credentials, account or service actions."""
import hashlib
import os
from pathlib import Path
import shutil
import stat
from contextlib import contextmanager
import select
import subprocess
import sys

from test_linux_agent_setup import LinuxAgentSetupTests, SETUP, VM_ID

LEGACY = Path(__file__).with_name("fixtures") / "linux-agent-setup-v1.sh"
LEGACY_SHA = "437d2f23cf91a8e484780cb459d17a5be8ca4dae44122d6be7eed2cdf6eb2dfe"


class GenerationFixture:
    def __init__(self):
        self.fixture = LinuxAgentSetupTests(methodName="runTest")
        self.fixture.setUp()
        self.fixture.manager_script = self.fixture.base / "manager.sh"
        self.fixture.manager_script.write_bytes((self.fixture.payload / "setup.sh").read_bytes())
        self.fixture.manager_script.chmod(0o600)
        self.payload_a = self.fixture.payload
        (self.payload_a / "agent").write_bytes(b"fixture-generation-A-not-an-agent\n")
        self.fixture.refresh_manifest()
        self.pin_a = self.fixture.pin
        self.payload_b = self.fixture.base / "payload-b"
        self.payload_b.mkdir(mode=0o700)
        for name in ("initd", "setup.sh"):
            shutil.copyfile(self.payload_a / name, self.payload_b / name)
        (self.payload_b / "agent").write_bytes(b"fixture-generation-B-not-an-agent\n")
        manifest = "".join(hashlib.sha256((self.payload_b / name).read_bytes()).hexdigest()
                           + "  " + name + "\n" for name in ("agent", "initd", "setup.sh"))
        (self.payload_b / "SHA256SUMS").write_text(manifest)
        self.pin_b = hashlib.sha256(manifest.encode()).hexdigest()
        self.vm_id = VM_ID.strip()
        self.kernel_lock = self.fixture.sysroot / "var/lib/macopenvm-agent.kernel-lock"
        self.journal = self.fixture.sysroot / "var/lib/macopenvm-agent.install-lock/transaction"
        sentinel = self.fixture.sysroot / "etc/unrelated-generation-sentinel"
        sentinel.write_bytes(b"preserve-unrelated-generation-policy\n")

    def __getattr__(self, name):
        return getattr(self.fixture, name)

    def close(self):
        self.fixture.doCleanups()

    def install(self):
        return self.fixture.install()

    def upgrade(self, **kwargs):
        return self.fixture.observe("upgrade", "--vm-id", self.vm_id, "--expect-generation", self.pin_a,
                                    "--payload", str(self.payload_b), "--manifest-sha256", self.pin_b, **kwargs)

    def rollback(self, **kwargs):
        return self.fixture.observe("rollback", "--vm-id", self.vm_id, "--expect-generation", self.pin_b,
                                    "--generation-sha256", self.pin_a, **kwargs)

    def recover(self, *, source=None, target=None, **kwargs):
        return self.fixture.observe("recover", "--vm-id", self.vm_id, "--expect-generation", source or self.pin_a,
                                    "--generation-sha256", target or self.pin_b, "--resume", **kwargs)

    @staticmethod
    def path_identity(path):
        info = path.lstat()
        identity = (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid, info.st_gid)
        if path.is_symlink():
            return identity + ("link", os.readlink(path))
        if path.is_dir():
            return identity + ("directory",)
        return identity + ("file", path.read_bytes())

    def full_tree(self):
        return {path.relative_to(self.sysroot).as_posix(): self.path_identity(path)
                for path in self.sysroot.rglob("*")}

    def protected(self):
        paths = list(self.credentials.iterdir()) + [self.credentials, self.reservation,
                self.reservation / "record", self.sysroot / "etc/unrelated-generation-sentinel"]
        paths += [self.sysroot / "etc" / name for name in ("passwd", "shadow", "group")]
        paths += [self.service, self.sysroot / "etc/runlevels/default/macopenvm-agent"]
        return {str(path): self.path_identity(path) for path in paths}

    def slot(self, path, suffix):
        return Path(str(path) + "." + suffix)

    def current_pin(self):
        return (self.owned_state / "generation").read_text().splitlines()[2].removeprefix("current=")

    def process(self, *, number=4001, uid=0, state="S", kernel=False, executable=None,
                cmdline=b"", status=None):
        path = self.sysroot / "proc" / str(number)
        path.mkdir(mode=0o700)
        if status is None:
            status = (f"Name:\tfixture\nState:\t{state} (fixture)\nTgid:\t{number}\nPid:\t{number}\n"
                      f"Uid:\t{uid}\t{uid}\t{uid}\t{uid}\nKthread:\t{1 if kernel else 0}\n").encode()
        (path / "status").write_bytes(status)
        (path / "cmdline").write_bytes(cmdline)
        if executable is not None:
            (path / "exe").symlink_to(executable)
        return path

    def assert_generations_present(self, case):
        found = set()
        for suffix in (None, "next", "previous", "failed"):
            program = self.program if suffix is None else self.slot(self.program, suffix)
            if program.is_dir():
                agent = program / "macopenvm-agent"
                if agent.is_file(): found.add(agent.read_bytes())
        case.assertEqual(found, {(self.payload_a / "agent").read_bytes(), (self.payload_b / "agent").read_bytes()})

    def service_mutations(self):
        return [call for call in self.state()["calls"]
                if call[0] in ("adduser", "addgroup", "rc-update")
                or call[:2] == ["rc-service", "macopenvm-agent"] and call[2] != "status"]

    @contextmanager
    def held_kernel_lock(self):
        script = ("import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDWR|os.O_NOFOLLOW); "
                  "fcntl.flock(fd,fcntl.LOCK_EX); print('held',flush=True); "
                  "sys.stdin.buffer.read(1); os.close(fd)")
        child = subprocess.Popen([sys.executable, "-c", script, str(self.kernel_lock)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            if not select.select([child.stdout], [], [], 5)[0] or child.stdout.readline() != b"held\n":
                raise AssertionError("Actual private lock-holder did not acknowledge its kernel lock.")
            yield child
        finally:
            child.stdin.close()  # EOF releases this actually retained child's FD; no saved PID signal.
            if child.wait(timeout=5) != 0:
                raise AssertionError(child.stderr.read().decode())
            child.stdout.close(); child.stderr.close()

    def legacy(self, *arguments, success=False):
        if hashlib.sha256(LEGACY.read_bytes()).hexdigest() != LEGACY_SHA:
            raise AssertionError("Archived v1 fixture changed.")
        env = os.environ.copy()
        env.update(MACOPENVM_AGENT_TEST_MODE="1", MVO_FAKE_ROOT=str(self.sysroot), MVO_FAKE_STATE=str(self.state_file))
        result = subprocess.run(["/bin/sh", str(LEGACY), "--test-sysroot", str(self.sysroot),
                                 "--test-command-dir", str(self.commands), *arguments],
                                env=env, capture_output=True, timeout=20, check=False)
        if (result.returncode == 0) != success:
            raise AssertionError(result.stderr.decode())
        return result

    def namespace_offsets(self):
        before = self.state()["moves"]
        calls = len(self.state()["calls"])
        self.upgrade()
        paths = {str(self.program), str(self.owned_state), str(self.slot(self.program, "next")), str(self.slot(self.owned_state, "next"))}
        moves = [call for call in self.state()["calls"][calls:] if call[0] == "mv"]
        return [index for index, call in enumerate(moves, 1) if call[1] in paths], self.state()["moves"] - before
