#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Actual fresh offline native Linux live guest with TLS/typed health over virtio sockets.

Original VMs and verified media are preserved. Temporary identity material never enters project
files. A live owner is retained on failure; observation expiry never restarts it.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import time
import uuid

from agent_tls_native import issue
from alpine_live_preflight import ASSETS
from managed_serial import ManagedSerial

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / ".lab/native-copy-4d8150866b9f432b831de06e64597ab7/Copy.macopenvm"
GUEST = ROOT / ".lab/linux-tls-sysroot-6056594b16a1422c80ca4540a6d3603f/build-a1022f5f122f4e17a3927561da76af7e/macopenvm-agent-tls-lab"
GUEST_SHA = "9e495e24faf885e9058c7b13212a17497733b82568d2cd322c93a92936f7463b"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def command(cli, arguments):
    result = subprocess.run([str(cli), *arguments], capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError("Protected local fixture preparation failed")
    return result.stdout


def save(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--cli", type=Path, required=True)
    options = parser.parse_args()
    cli = options.cli.resolve()
    if cli.parent.parent != ROOT / ".lab" or cli.name != "macopenvm" or digest(GUEST) != GUEST_SHA:
        raise RuntimeError("Select immutable checked lab executables")
    os.umask(0o077)
    root = ROOT / ".lab" / ("agent-guest-" + uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    vm = root / "Agent.macopenvm"
    credentials = Path("/private/tmp") / ("mvo-agent-tls-" + uuid.uuid4().hex)
    wrong = Path("/private/tmp") / ("mvo-agent-tls-" + uuid.uuid4().hex)
    owner = None
    phase = "prepare"
    try:
        source_files = {name: checksum for name, _, checksum in ASSETS}
        assert all(digest(ROOT / name) == checksum for name, checksum in source_files.items())
        save(root / "source-before.json", source_files)
        command(cli, ["create", "--directory", str(vm), "--name", "Agent Transport Test",
                      "--media", str(ROOT / ASSETS[0][0]), "--kernel", str(ROOT / ASSETS[1][0]),
                      "--initrd", str(ROOT / ASSETS[2][0]), "--kernel-arguments",
                      "console=hvc0 modules=loop,squashfs,sd-mod,usb-storage",
                      "--memory-mib", "2048", "--disk-gib", "1", "--network", "disconnected"])
        configuration = json.loads((vm / "configuration.json").read_text())
        assert configuration["network"] == "disconnected"
        credentials.mkdir(mode=0o700)
        wrong.mkdir(mode=0o700)
        issue(credentials)
        issue(wrong)
        # The negative client trusts the real guest, but presents an unrelated host credential.
        for name in ["guest.der", "ca.der"]:
            shutil.copyfile(credentials / name, wrong / name)
        staging = credentials / "staging"
        staging.mkdir(mode=0o700)
        for name in ["guest.pem", "guest-key.pem", "ca.pem"]:
            shutil.copyfile(credentials / name, staging / name)
            (staging / name).chmod(0o600)
        shutil.copyfile(GUEST, staging / "agent")
        (staging / "agent").chmod(0o500)
        image = credentials / "support.iso"
        result = subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name",
                                 "MVO_AGENT_LAB", "-o", str(image), str(staging)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if result.returncode:
            raise RuntimeError("Temporary per-VM carrier preparation failed")
        image.chmod(0o600)
        image_before = digest(image)
        command(cli, ["attach-support-media", "--directory", str(vm), "--support-media", str(image)])
        command(cli, ["validate", "--directory", str(vm)])
        owner = ManagedSerial(cli, ["run-agent-transport-lab", "--directory", str(vm),
                                   "--socket", str(credentials / "relay.sock"), "--seconds", "300"],
                              cwd=root, artifacts=root, label="guest").launch()
        save(root / "ownership.json", {"scope": "actual retained supervisor; PID is advisory", "active": True})

        def expect(needle, seconds=30, stream="stdout", after=None):
            return owner.expect(needle, deadline=time.monotonic() + seconds, stream=stream, after=after)

        def send(text):
            owner.write(text.encode() + b"\n", deadline=time.monotonic() + 3)

        phase = "boot"
        expect(b"localhost login: ", 60)
        send("root")
        expect(b"localhost:~# ")
        phase = "agent-start"
        marker = "mvo" + uuid.uuid4().hex
        start = owner.mark()
        send("modprobe vmw_vsock_virtio_transport; mkdir -m 700 -p /mnt/mvo-agent; "
             "mount -t iso9660 -o ro /dev/sdb /mnt/mvo-agent; "
             "cp /mnt/mvo-agent/agent /tmp/mvo-agent; chmod 700 /tmp/mvo-agent; "
             "/tmp/mvo-agent /mnt/mvo-agent/guest.pem /mnt/mvo-agent/guest-key.pem "
             "/mnt/mvo-agent/ca.pem " + configuration["id"] + " 2 >/tmp/mvo-agent.log 2>&1 &")
        expect(b"localhost:~# ", after=start)
        start = owner.mark()
        send("sleep 1; cat /tmp/mvo-agent.log; printf '\\n" + marker + ".started=1\\n'")
        expect(b"mvo.agent-tls.ready port=4050 version=1", after=start)
        expect((marker + ".started=1").encode(), after=start)
        expect(b"localhost:~# ", after=start)
        phase = "tls"
        client_results = []
        for attempt, selected, expected_code in [(1, wrong, 1), (2, credentials, 0)]:
            control = vm / ("agent-connect-" + str(attempt) + ".request")
            control.write_bytes(b"connect\n")
            control.chmod(0o600)
            expect(("mvo.host-agent.relay-ready attempt=" + str(attempt)).encode(), stream="stderr")
            response = subprocess.run([str(cli), "agent-tls-lab", "--socket", str(credentials / "relay.sock"),
                                       "--credentials", str(selected), "--vm-id", configuration["id"]],
                                      capture_output=True, timeout=20)
            assert response.returncode == expected_code
            (root / ("client-" + str(attempt) + ".stdout")).write_bytes(response.stdout)
            (root / ("client-" + str(attempt) + ".stderr")).write_bytes(response.stderr)
            if attempt == 2:
                health = json.loads(response.stdout)
                assert health["nativePeerTrustVerified"] and health["health"]["healthConfirmed"]
                assert health["health"]["architecture"] == 1 and health["health"]["agentMinor"] == 1
            client_results.append({"attempt": attempt, "exitCode": response.returncode,
                                   "healthValidated": attempt == 2})
            expect(("mvo.host-agent.connection-finished attempt=" + str(attempt)).encode(), stream="stderr")
        start = owner.mark()
        send("cat /tmp/mvo-agent.log; printf '\\n" + marker + ".observed=1\\n'")
        expect(b"mvo.agent-tls.rejected category=tls", after=start)
        expect(b"mvo.agent-tls.health-complete version=0.1.0 architecture=arm64", after=start)
        expect(b"mvo.agent-tls.complete health=1", after=start)
        expect((marker + ".observed=1").encode(), after=start)
        expect(b"localhost:~# ", after=start)
        phase = "shutdown"
        send("umount /mnt/mvo-agent; sync; poweroff")
        terminal = owner.wait(deadline=time.monotonic() + 60)
        assert terminal.returncode == 0 and not terminal.is_active
        history = json.loads((vm / "runtime.json").read_text())
        assert history["snapshot"]["state"] == "stopped" and history["snapshot"]["outcome"] == "guestStopped"
        assert digest(image) == image_before
        assert all(digest(ROOT / name) == checksum for name, checksum in source_files.items())
        command(cli, ["detach-support-media", "--directory", str(vm)])
        save(root / "result.json", {"scope": "native Linux TLS/schema health over virtio socket; not installed agent or Windows support",
                                   "status": "passed", "clients": client_results, "mediaUnchanged": True,
                                   "guestRejectedUnknownHost": True, "nativeTLS13HealthValidated": True,
                                   "guestNormalShutdown": True, "runtimeOwnerTerminal": True,
                                   "guestNICAbsent": True, "temporaryCarrierUnchanged": True,
                                   "credentialContentsRetained": False, "guestBinarySHA256": GUEST_SHA,
                                   "cliSHA256": digest(cli), "runnerSHA256": digest(Path(__file__))})
        print(json.dumps({"fixture": str(root), "status": "passed", "resultSHA256": digest(root / "result.json")}), flush=True)
    except Exception as error:
        live = owner is not None and owner.snapshot(deadline=time.monotonic() + 1).is_active
        save(root / "failure.json", {"phase": phase, "failureType": type(error).__name__, "liveOwnerPreserved": live})
        print(json.dumps({"fixture": str(root), "phase": phase, "liveOwnerPreserved": live}), flush=True)
        if live:
            print("Live native owner retained. Commands: status or guest poweroff.", flush=True)
            while owner.snapshot(deadline=time.monotonic() + 1).is_active:
                if select.select([sys.stdin], [], [], 1)[0]:
                    line = sys.stdin.readline().strip()
                    if line == "status":
                        snap = owner.snapshot(deadline=time.monotonic() + 1)
                        print(json.dumps({"active": snap.is_active, "returncode": snap.returncode}), flush=True)
                    elif line == "guest poweroff":
                        owner.write(b"poweroff\n", deadline=time.monotonic() + 3)
                    elif not line:
                        time.sleep(1)
        raise SystemExit(1) from None
    finally:
        if owner is None or not owner.snapshot(deadline=time.monotonic() + 1).is_active:
            for directory in [credentials, wrong]:
                if directory.exists():
                    shutil.rmtree(directory)


if __name__ == "__main__":
    main()
