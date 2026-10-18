#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit real-guest serial/NAT contract, not a mock or performance benchmark.
Uses only the prepared disposable Alpine NAT fixture. Failure retains live ownership.
"""
import argparse
import errno
import json
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import sys
import termios
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--run", action="store_true")
args = parser.parse_args()
if not args.run:
    raise SystemExit("SKIP: requires --run, a signed build and the disposable Alpine NAT fixture.")
directory = ROOT / ".lab/Alpine-nat.macopenvm"
if not (directory / "configuration.json").is_file():
    raise SystemExit("SKIP: prepare the disposable Alpine NAT fixture and its lawfully obtained media first.")
config = json.loads((directory / "configuration.json").read_text())
if config["guest"] != "linux" or config["network"] != "shared" or config["boot"] != "linuxKernel":
    raise SystemExit("SKIP: the prepared disposable direct-kernel shared-network fixture is required.")
cli = ROOT / "build/bin/macopenvm"
probe = json.loads(subprocess.check_output([str(cli), "probe"]))
if not probe["virtualizationSupported"] or not probe["virtualizationEntitled"]:
    raise SystemExit("SKIP: signed native virtualization unavailable in this execution environment.")

session = ROOT / (".lab/serial-contract-" + uuid.uuid4().hex)
session.mkdir(mode=0o700)
master, slave = pty.openpty()
original = termios.tcgetattr(slave)
process = subprocess.Popen(
    [str(cli), "run", "--directory", str(directory), "--seconds", "300"],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True)
(session / "ownership.json").write_text(json.dumps({"pid": process.pid, "active": True}) + "\n")
output = bytearray()
transcript = (session / "console.log").open("xb")
query_tail = b""
phase = "boot"

def terminal_configuration(attributes):
    values = attributes.copy()
    # Darwin marks retyping pending input when restoring canonical input. PENDIN is
    # kernel state, not a mode setting; compare every other flag, speed and control byte.
    values[3] &= ~termios.PENDIN
    return values

def receive(timeout):
    global query_tail
    if select.select([master], [], [], timeout)[0]:
        try:
            chunk = os.read(master, 65_536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            chunk = b""
        transcript.write(chunk)
        transcript.flush()
        output.extend(chunk)
        # A PTY has no terminal emulator. Answer the fixture shell's VT cursor query
        # with a fixed test cursor; this does not test screen geometry or rendering.
        query = query_tail + chunk
        for _ in range(query.count(b"\x1b[6n")):
            os.write(master, b"\x1b[1;1R")
        query_tail = query[-3:]
        if len(output) > 2_097_152:
            raise RuntimeError("Console response exceeded its bound")

def wait_for(pattern, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if re.search(pattern, bytes(output)):
            return
        if process.poll() is not None:
            raise RuntimeError("Runner exited before the expected guest response")
        receive(0.25)
    raise RuntimeError("Expected guest response timed out")

def command(text):
    global phase
    phase = text.split(" ", 1)[0]
    output.clear()
    os.write(master, text.encode() + b"\n")

try:
    wait_for(rb"localhost login: ", 45)
    command("root")
    wait_for(rb"localhost:~# ")
    command("sleep 30")
    wait_for(rb"sleep 30")
    # Let the guest establish its foreground job before generating the interrupt.
    time.sleep(0.2)
    phase = "guest-interrupt"
    os.write(master, b"\x03")
    wait_for(rb"localhost:~# ")
    nonce = "mvo" + uuid.uuid4().hex
    command(f"printf '\\n{nonce}ctrl:%s\\n' \"$(uname -m)\"")
    wait_for(rb"[\r\n]" + nonce.encode() + rb"ctrl:aarch64[\r\n]")
    assert process.poll() is None, "Ctrl-C must not terminate the host runner"
    command(f"printf '\\n{nonce}mac:%s\\n' \"$(cat /sys/class/net/eth0/address)\"")
    wait_for(rb"[\r\n]" + nonce.encode() + rb"mac:" + config["macAddress"].encode() + rb"[\r\n]")
    command(f"ip link set eth0 up; udhcpc -i eth0 -n -q -t 3; printf '\\n{nonce}dhcp:%s\\n' \"$?\"")
    wait_for(rb"[\r\n]" + nonce.encode() + rb"dhcp:0[\r\n]")
    command("ip route; nslookup example.com")
    wait_for(rb"Name:\s+example.com")
    assert b"default via" in output, "DHCP must supply a default route"
    command("printf 'GET / HTTP/1.1\\r\\nHost: example.com\\r\\nConnection: close\\r\\n\\r\\n' | "
            "timeout 15 openssl s_client -connect example.com:443 -servername example.com "
            "-verify_hostname example.com -verify_return_error -CAfile /etc/ssl/cert.pem "
            f"-quiet > /tmp/macopenvm-net-test.txt; printf '\\n{nonce}tls:%s\\n' \"$?\"; "
            "head -n 1 /tmp/macopenvm-net-test.txt")
    wait_for(rb"[\r\n]" + nonce.encode() + rb"tls:0[\r\n]")
    wait_for(rb"[\r\n]HTTP/1.1 200 OK[\r\n]")
    command("poweroff")
    deadline = time.monotonic() + 45
    while process.poll() is None and time.monotonic() < deadline:
        receive(0.25)
    assert process.poll() == 0, "Clean guest shutdown must complete with runner exit 0"
    restored = termios.tcgetattr(slave)
    def numeric(attributes):
        return attributes[:6] + [[int.from_bytes(value, "little") if isinstance(value, bytes) else value
                                 for value in attributes[6]]]
    (session / "terminal-state.json").write_text(json.dumps({"before": numeric(original),
                                                            "after": numeric(restored)}, indent=2) + "\n")
    assert terminal_configuration(restored) == terminal_configuration(original), \
        "The CLI must restore the original terminal mode"
    subprocess.check_call([str(cli), "validate", "--directory", str(directory)], stdout=subprocess.DEVNULL)
    report = {"status": "passed", "controlKeyReachedGuest": True, "terminalRestored": True,
              "savedMacMatched": True, "dhcpRouteDns": True, "verifiedHTTPS": True,
              "cleanExit": True, "ownershipReleased": True}
    (session / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    (session / "ownership.json").write_text(json.dumps({"pid": process.pid, "active": False}) + "\n")
    print(json.dumps(report), flush=True)
except Exception as error:
    (session / "failure.json").write_text(json.dumps({"error": str(error), "phase": phase, "pid": process.pid,
                                                    "active": process.poll() is None}) + "\n")
    print(f"Contract failed: {error}. Evidence: {session.name}.", flush=True)
    if process.poll() is None:
        print("Live guest retained. This session now forwards console input; inspect before sending commands.", flush=True)
        inputs = [master, sys.stdin]
        while process.poll() is None:
            ready = select.select(inputs, [], [], 1)[0]
            if master in ready:
                chunk = os.read(master, 65_536)
                transcript.write(chunk)
                sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
            if sys.stdin in ready:
                chunk = os.read(sys.stdin.fileno(), 4096)
                if chunk:
                    os.write(master, chunk)
                else:
                    inputs.remove(sys.stdin)
    (session / "ownership.json").write_text(json.dumps({"pid": process.pid, "active": False}) + "\n")
    (session / "recovery.json").write_text(json.dumps({"terminalRestored": terminal_configuration(termios.tcgetattr(slave)) == terminal_configuration(original),
                                                     "runnerExit": process.returncode}) + "\n")
    raise
finally:
    transcript.close()
    os.close(master); os.close(slave)
