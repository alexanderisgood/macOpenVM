#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit CLI upgrade on a NEW synthetic sparse fixture; no guest or remount claim.

Requires a canonical absolute CLI path and its independently reviewed SHA256.
Creates one new private evidence directory and retains every fixture/transcript.
Never reads an existing VM, invokes a runtime, sends signals, or removes files.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import stat
import subprocess
import time
import uuid

GIB = 1 << 30
LIMIT = 65536
SEED = b"fresh explicit identity upgrade CLI seed\n"


def write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def fact(info):
    return [info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def cli_identity(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and before.st_nlink == 1
        assert before.st_uid == os.geteuid() and not before.st_mode & 0o022
        assert 0 < before.st_size <= 256 << 20 and before.st_mode & 0o100
        digest = hashlib.sha256()
        while data := os.read(fd, 1 << 20):
            digest.update(data)
        assert fact(before) == fact(os.fstat(fd)) == fact(path.lstat())
        return fact(before), digest.hexdigest()
    finally:
        os.close(fd)


def inventory(directory):
    rows = {}
    for path in sorted(directory.iterdir()):
        info = path.lstat()
        assert stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
        assert info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600
        if path.name == "disk.raw":
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                payload = os.pread(fd, len(SEED), 0)
                assert payload == SEED
            finally:
                os.close(fd)
        else:
            assert info.st_size <= LIMIT
            payload = path.read_bytes()
        assert fact(info) == fact(path.lstat())
        rows[path.name] = dict(fact=fact(info), sha256=hashlib.sha256(payload).hexdigest())
    return rows


# Standalone block for the public integration script: no private lab dependency.
MAX_OUTPUT = 65536
COMMAND_SECONDS = 20.0
DRAIN_SECONDS = 2.0


class CommandStopped(RuntimeError):
    """Qualification stopped after preserving the actual owned parent result."""


class Evidence:
    """Retained private directory anchor; own entry creation may change nlink."""
    def __init__(self, root):
        self.root = root
        self.fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                          | os.O_CLOEXEC | os.O_NONBLOCK)
        self.identity = self.key(os.fstat(self.fd))
        try:
            self.check_anchor()
        except BaseException:
            os.close(self.fd)
            raise

    @staticmethod
    def key(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)

    def check_anchor(self):
        held, named = os.fstat(self.fd), self.root.lstat()
        if not (self.key(held) == self.identity == self.key(named)
                and stat.S_ISDIR(held.st_mode) and held.st_uid == os.geteuid()
                and stat.S_IMODE(held.st_mode) == 0o700):
            raise CommandStopped("Evidence directory binding changed.")

    def write(self, name, value):
        self.check_anchor()
        if not (type(name) is str and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,150}", name)):
            raise CommandStopped("Unsafe evidence basename.")
        data = value if isinstance(value, bytes) else (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        if len(data) > 4 << 20:
            raise CommandStopped("Evidence item exceeds bound.")
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                     | os.O_CLOEXEC, 0o600, dir_fd=self.fd)
        try:
            os.fchmod(fd, 0o600)
            offset = 0
            while offset < len(data):
                count = os.write(fd, data[offset:])
                if count <= 0:
                    raise CommandStopped("Evidence write failed.")
                offset += count
            os.fsync(fd)
            held = os.fstat(fd)
            named = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            if not (stat.S_ISREG(held.st_mode) and held.st_uid == os.geteuid()
                    and held.st_nlink == 1 and stat.S_IMODE(held.st_mode) == 0o600
                    and fact(held) == fact(named) and held.st_size == len(data)):
                raise CommandStopped("Evidence file binding changed.")
        finally:
            os.close(fd)
        os.fsync(self.fd)
        self.check_anchor()

    def best_effort(self, name, value):
        try:
            self.write(name, value)
            return True
        except BaseException:
            try:
                print("Evidence write failed; retaining the actual child until reaped.", flush=True)
            except BaseException:
                pass
            return False

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class OwnedCommandRunner:
    """Single actual child, bounded drain, no signals, and unconditional custody.

    Reuses the qualified campaign design: prepare intent before spawn, retain the
    Popen, stop dependent actions on uncertainty, and record actual reap/EOF facts.
    All post-spawn setup and controls are inside the outer custody finally.
    """
    def __init__(self, evidence, *, command_seconds=COMMAND_SECONDS,
                 drain_seconds=DRAIN_SECONDS, max_output=MAX_OUTPUT):
        if not (0 < command_seconds <= 60 and 0 < drain_seconds <= 5
                and 128 <= max_output <= 131072):
            raise ValueError("Invalid bounded runner limits.")
        self.evidence = evidence
        self.command_seconds = command_seconds
        self.drain_seconds = drain_seconds
        self.max_output = max_output
        self.sequence = 0
        self.active = None
        self.outcomes = []

    def _after_spawn(self, _process):
        """No-op product hook; inert probes inject a control error here."""

    def run(self, argv, label, expected=0):
        if self.active is not None:
            raise CommandStopped("An actual child still requires custody.")
        self.evidence.check_anchor()
        if not (type(argv) is list and argv and all(type(arg) is str and "\0" not in arg for arg in argv)
                and re.fullmatch(r"[a-z][a-z0-9-]{0,80}", label)
                and type(expected) is int and 0 <= expected <= 255):
            raise CommandStopped("Unsafe command plan.")
        self.sequence += 1
        key = f"command-{self.sequence:03d}-{label}"
        self.evidence.write(key + "-intent.json", dict(
            argv=argv, expectedExit=expected, shell=False, startNewSession=True,
            timeoutSeconds=self.command_seconds, outputLimitPerStream=self.max_output,
            signalsSent=False))
        # Every mutable custody datum exists before spawning. Evidence failures after
        # spawn only mark a problem; best-effort writes never prevent pipe draining.
        process = None
        output = {"stdout": bytearray(), "stderr": bytearray()}
        eof = set()
        problems = []
        began = time.monotonic()
        exited_at = None
        custody_attempted = False

        def problem(message):
            if message not in problems:
                problems.append(message)

        try:
            process = subprocess.Popen(argv, cwd=str(self.evidence.root),
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, close_fds=True,
                                       start_new_session=True, shell=False)
            self.active = process
            self._after_spawn(process)
            if not self.evidence.best_effort(key + "-started.json", dict(
                    actualPID=process.pid, actualParentStarted=True, custodyRetained=True)):
                problem("started evidence write failed")
        except BaseException as error:
            problem("post-spawn control error" if process is not None else "spawn failed")
            self.evidence.best_effort(key + "-control-error.json", dict(
                errorType=type(error).__name__, actualParentStarted=process is not None,
                actualParentRetained=process is not None))
        finally:
            # Nothing may leave this block while this actual parent is running.
            # A natural timeout/control failure remains visible in the retained
            # script/session. No PID reconstruction, signal, retry, or restart exists.
            if process is not None:
                self.active = process
                while True:
                    try:
                        now = time.monotonic()
                        # Fair draining precedes fallible process controls. In
                        # particular repeated poll failures cannot skip reads
                        # or the independent actual wait/reap attempt below.
                        received = False
                        for name in output:
                            if name in eof:
                                continue
                            pipe = getattr(process, name)
                            try:
                                os.set_blocking(pipe.fileno(), False)
                                data = os.read(pipe.fileno(), 8192)
                            except (BlockingIOError, InterruptedError):
                                continue
                            except BaseException:
                                problem("pipe control error; actual parent retained")
                                continue
                            if not data:
                                eof.add(name)
                                continue
                            received = True
                            room = self.max_output - len(output[name])
                            output[name].extend(data[:max(0, room)])
                            if len(data) > room:
                                problem("output overflow")
                        poll_failed = False
                        try:
                            returncode = process.poll()
                        except BaseException:
                            problem("poll control error; actual parent retained")
                            poll_failed = True
                            returncode = process.returncode
                        if returncode is None and now - began > self.command_seconds:
                            problem("timeout; actual parent retained")
                        if problems and not custody_attempted:
                            custody_attempted = True
                            if not self.evidence.best_effort(key + "-custody.json", dict(
                                    argv=argv, actualPID=process.pid, problems=list(problems),
                                    actualParentRetained=True,
                                    actualParentReaped=returncode is not None,
                                    dependentActionsStopped=True, signalsSent=False)):
                                problem("custody evidence write failed")
                        if returncode is not None:
                            if exited_at is None:
                                exited_at = now
                            if len(eof) == 2:
                                break
                            if now - exited_at > self.drain_seconds:
                                problem("actual parent reaped; output EOF unconfirmed")
                                break
                        if not received or poll_failed:
                            if returncode is None:
                                try:
                                    process.wait(timeout=0.005 if poll_failed else 0.05)
                                except subprocess.TimeoutExpired:
                                    pass
                                except BaseException:
                                    problem("wait control error; actual parent retained")
                            else:
                                time.sleep(0.01)
                    except BaseException:
                        problem("custody control error; actual parent retained")
                        # The same actual handle is still retained. A subsequent
                        # iteration independently drains both pipes and reaps it.
                        continue
                # poll/wait above already reaped the direct parent. The exact owned
                # handle is checked again; no child state is inferred from a PID.
                while process.returncode is None:
                    try:
                        process.wait(timeout=0.05)
                    except BaseException:
                        continue
                for name in output:
                    try:
                        getattr(process, name).close()
                    except BaseException:
                        problem("pipe close failed after actual parent reap")
                self.active = None

        outcome = dict(label=label, argv=argv, expectedExit=expected,
                       actualPID=None if process is None else process.pid,
                       returncode=None if process is None else process.returncode,
                       actualParentStarted=process is not None,
                       actualParentReaped=process is not None and process.returncode is not None,
                       bothOutputEOF=len(eof) == 2, problems=problems, signalsSent=False,
                       elapsedSeconds=time.monotonic() - began,
                       retainedBytes={name: len(data) for name, data in output.items()})
        self.outcomes.append(outcome)
        for name, data in output.items():
            if not self.evidence.best_effort(key + "." + name, bytes(data)):
                problem("transcript evidence write failed")
        if not self.evidence.best_effort(key + "-terminal.json", outcome):
            problem("terminal evidence write failed")
        if (problems or process is None or process.returncode != expected or len(eof) != 2):
            raise CommandStopped("Command failed or became uncertain: " + label)
        return bytes(output["stdout"])


class Runner:
    """Pinned CLI adapter; custody is implemented only by OwnedCommandRunner."""
    def __init__(self, cli, identity, root):
        self.cli, self.identity, self.root = cli, identity, root
        self.evidence = Evidence(root)
        self.owned = OwnedCommandRunner(self.evidence)

    @property
    def rows(self):
        return self.owned.outcomes

    def run(self, label, arguments, expected=0):
        if cli_identity(self.cli) != self.identity:
            raise CommandStopped("CLI pin changed before command.")
        data = self.owned.run([str(self.cli), *arguments], label, expected)
        if cli_identity(self.cli) != self.identity:
            raise CommandStopped("CLI pin changed during command.")
        return json.loads(data) if data.strip() else {}

    def close(self):
        if self.owned.active is not None:
            raise CommandStopped("Cannot close evidence while an actual child remains retained.")
        self.evidence.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--expected-cli-sha256", required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    options = parser.parse_args()
    cli = options.cli
    root = options.artifacts
    assert cli.is_absolute() and cli.resolve(strict=True) == cli
    assert root.is_absolute() and root.parent.resolve(strict=True) == root.parent
    assert len(options.expected_cli_sha256) == 64 and all(c in "0123456789abcdef" for c in options.expected_cli_sha256)
    identity = cli_identity(cli)
    assert identity[1] == options.expected_cli_sha256
    assert not root.exists() and shutil.disk_usage(root.parent).free >= 2 * GIB
    root.mkdir(mode=0o700)
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    runner = Runner(cli, identity, root)
    directory = root / "fresh-synthetic-legacy.macopenvm"
    directory.mkdir(mode=0o700)
    vm_id = str(uuid.uuid4()).upper()
    configuration = dict(schemaVersion=1, id=vm_id, name="fresh explicit upgrade fixture",
                         guest="linux", architecture="arm64", backend="qemuHVF",
                         cpuCount=2, memoryBytes=2 * GIB, diskBytes=GIB,
                         diskFile="disk.raw", boot="efi", kernelArguments="console=hvc0",
                         network="disconnected", macAddress="02:01:02:03:04:05")
    write_new(directory / "configuration.json", (json.dumps(configuration, indent=2) + "\n \n").encode())
    write_new(directory / "writer.lock", b"")
    fd = os.open(directory / "disk.raw", os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.ftruncate(fd, GIB)
        assert os.pwrite(fd, SEED, 0) == len(SEED)
        os.fsync(fd)
    finally:
        os.close(fd)
    runner.run("initial-growth", ["grow-disk", "--directory", str(directory), "--disk-gib", "2"])
    journal = directory / "disk-growth-intent.json"
    completed_v2 = json.loads(journal.read_bytes())
    assert completed_v2["schemaVersion"] == 2 and completed_v2["state"] == "completed"
    transaction = completed_v2["transactionID"]
    legacy_object = dict(completed_v2)
    legacy_object["schemaVersion"] = 1
    del legacy_object["directoryVolumeUUID"], legacy_object["diskVolumeUUID"]
    legacy = (json.dumps(legacy_object, indent=2) + "\n \n").encode()
    # Explicit synthetic rewrite of this fresh fixture ONLY, not power-loss proof.
    def rewrite(data):
        fd = os.open(journal, os.O_WRONLY | os.O_NOFOLLOW)
        try:
            assert os.pwrite(fd, data, 0) == len(data)
            os.ftruncate(fd, len(data))
            os.fsync(fd)
        finally:
            os.close(fd)
    rewrite(legacy)
    check_args = ["check-disk-growth-identity-upgrade", "--directory", str(directory)]
    upgrade_args = ["upgrade-disk-growth-identity", "--directory", str(directory),
                    "--vm-id", vm_id, "--growth-transaction", transaction]
    before = inventory(directory)
    check = runner.run("eligible-read-only", check_args)
    assert inventory(directory) == before and check["eligibleAtCheck"] is True and check["readOnly"] is True
    assert check["vmID"] == vm_id and check["transactionID"] == transaction
    assert "App79" in check["compatibilityNotice"]
    assert str(directory) not in json.dumps(check) and "directoryVolumeUUID" not in check
    for label, args in [
        ("missing-ack", upgrade_args),
        ("wrong-ack", upgrade_args + ["--acknowledge-schema2-incompatibility", "true"]),
        ("wrong-transaction", upgrade_args[:-1] + [str(uuid.uuid4()).upper(), "--acknowledge-schema2-incompatibility", "yes"]),
        ("unsupported-force", upgrade_args + ["--acknowledge-schema2-incompatibility", "yes", "--force-legacy-device", "yes"]),
    ]:
        runner.run(label, args, expected=1)
        assert inventory(directory) == before
    changed_device = dict(legacy_object, directoryDevice=legacy_object["directoryDevice"] + 1)
    rewrite(json.dumps(changed_device, sort_keys=True).encode())
    unprovable = inventory(directory)
    refusal = runner.run("synthetic-unprovable-read-only", check_args, expected=2)
    assert refusal["status"] == "legacyProofUnavailable" and inventory(directory) == unprovable
    runner.run("synthetic-unprovable-mutation", upgrade_args + ["--acknowledge-schema2-incompatibility", "yes"], expected=1)
    assert inventory(directory) == unprovable
    rewrite(legacy)
    before = inventory(directory)
    result = runner.run("explicit-upgrade", upgrade_args + ["--acknowledge-schema2-incompatibility", "yes"])
    assert result["changed"] is True and result["sourceSchemaVersion"] == 1 and result["targetSchemaVersion"] == 2
    archive = directory / result["archiveFile"]
    assert archive.read_bytes() == legacy
    after = inventory(directory)
    for name in before:
        if name != journal.name:
            assert after[name] == before[name], name
    assert set(after) == set(before) | {archive.name}
    upgraded = json.loads(journal.read_bytes())
    assert upgraded["schemaVersion"] == 2 and upgraded["transactionID"] == transaction
    assert upgraded["directoryVolumeUUID"] == upgraded["diskVolumeUUID"]
    stable = runner.run("already-stable-read-only", check_args)
    assert stable["status"] == "alreadyStable" and stable["eligibleAtCheck"] is False
    assert "vmID" not in stable and "transactionID" not in stable
    assert inventory(directory) == after
    runner.run("repeated-upgrade-refusal", upgrade_args + ["--acknowledge-schema2-incompatibility", "yes"], expected=1)
    assert inventory(directory) == after
    runner.run("ordinary-next-growth", ["grow-disk", "--directory", str(directory), "--disk-gib", "3"])
    assert archive.read_bytes() == legacy
    next_record = json.loads(journal.read_bytes())
    assert next_record["schemaVersion"] == 2 and next_record["transactionID"] != transaction
    assert next_record["diskInode"] == upgraded["diskInode"]
    fd = os.open(directory / "disk.raw", os.O_RDONLY | os.O_NOFOLLOW)
    try:
        assert os.pread(fd, len(SEED), 0) == SEED
        for offset in range(2 * GIB, 3 * GIB, 1 << 20):
            assert os.pread(fd, 1 << 20, offset) == bytes(1 << 20)
    finally:
        os.close(fd)
    write_new(root / "result.json", json.dumps(dict(
        passed=True, syntheticLegacyFixtureOnly=True, realRemountClaim=False,
        guestBootClaim=False, priorLegacyArchiveExact=True, nextRealGrowthPassed=True,
        addedZeroBytesScanned=GIB, allActualCommandParentsReaped=True,
        cliSHA256=identity[1], commands=runner.rows), indent=2).encode())
    runner.close()


if __name__ == "__main__":
    main()
