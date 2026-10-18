#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Real native Swift TLS/typed protocol interoperability with an independent TLS server.

Credentials live only in a private temporary directory. This test does not boot a
VM, change Keychain, or establish installed-agent/driver health.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import struct
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
MAGIC = 0x4D564F41
MODES = ("positive", "wrong-ca", "wrong-pin", "wrong-eku", "expired-leaf", "tls12",
         "wrong-vm", "wrong-session", "wrong-sequence")
TRUST_MODES = frozenset(("wrong-ca", "wrong-pin", "wrong-eku", "expired-leaf", "tls12"))
REPLY_MODES = frozenset(("wrong-vm", "wrong-session", "wrong-sequence"))


def issue(directory, mode="positive"):
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError("OpenSSL issuance tool unavailable")
    def run(*arguments, output=False):
        process = subprocess.run([openssl, *arguments], cwd=directory,
                                 stdout=subprocess.PIPE if output else subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, timeout=30)
        if process.returncode:
            raise RuntimeError("Temporary certificate issuance failed")
        return process.stdout
    run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca-key.pem",
        "-out", "ca.pem", "-days", "1", "-subj", "/CN=macOpenVM temporary lab CA",
        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    for name, dns, purpose in [("guest", "macopenvm-agent.invalid", "serverAuth"),
                               ("client", "macopenvm-host.invalid", "clientAuth")]:
        if name == "guest" and mode == "wrong-eku":
            purpose = "clientAuth"
        run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", name + "-key.pem",
            "-out", name + ".csr", "-subj", "/CN=" + dns)
        extensions = directory / (name + ".ext")
        extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                              "extendedKeyUsage=" + purpose + "\nsubjectAltName=DNS:" + dns + "\n")
        run("x509", "-req", "-in", name + ".csr", "-CA", "ca.pem", "-CAkey", "ca-key.pem",
            "-CAcreateserial", "-out", name + ".pem", "-days",
            "0" if name == "guest" and mode == "expired-leaf" else "1",
            "-extfile", name + ".ext")
        run("x509", "-in", name + ".pem", "-outform", "DER", "-out", name + ".der")
    run("x509", "-in", "ca.pem", "-outform", "DER", "-out", "ca.der")
    run("rsa", "-in", "client-key.pem", "-traditional", "-outform", "DER", "-out", "client-key.der")
    witness = {}
    if mode == "wrong-ca":
        run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "other-ca-key.pem",
            "-out", "other-ca.pem", "-days", "1", "-subj", "/CN=macOpenVM unrelated lab CA",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        run("x509", "-in", "other-ca.pem", "-outform", "DER", "-out", "ca.der")
    if mode == "wrong-pin":
        shutil.copyfile(directory / "client.der", directory / "guest.der")
    if mode == "expired-leaf":
        end = run("x509", "-in", "guest.pem", "-enddate", "-noout", output=True)
        end = datetime.datetime.strptime(end.decode("ascii").strip().removeprefix("notAfter="),
                                         "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
        threshold = end + datetime.timedelta(seconds=1)
        if threshold - datetime.datetime.now(datetime.timezone.utc) > datetime.timedelta(seconds=5):
            raise RuntimeError("Expired-leaf issuance witness is inconsistent")
        expiry_deadline = time.monotonic() + 5
        while datetime.datetime.now(datetime.timezone.utc) <= threshold:
            if time.monotonic() >= expiry_deadline:
                raise RuntimeError("Expired-leaf witness deadline expired")
            time.sleep(0.05)
        witness = {"expiredLeafNotAfterUTC": end.isoformat(),
                   "expiryObservedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   "expiryWitnessed": True}
    for path in directory.iterdir():
        if path.is_file():
            path.chmod(0o600)
    return witness


def exact(stream, count, result):
    data = bytearray()
    while len(data) < count:
        chunk = stream.recv(count - len(data))
        if not chunk:
            raise RuntimeError("TLS application frame truncated")
        result["receivedApplicationBytes"] += len(chunk)
        data.extend(chunk)
    return bytes(data)


def receive(stream, expected_kind, expected_size, result):
    header = exact(stream, 16, result)
    magic, major, minor, kind, reserved, size = struct.unpack(">IHHHHI", header)
    if (magic, major, kind, reserved, size) != (MAGIC, 1, expected_kind, 0, expected_size):
        raise RuntimeError("Unexpected generated protocol header")
    return exact(stream, size, result)


def frame(kind, body):
    return struct.pack(">IHHHHI", MAGIC, 1, 0, kind, 0, len(body)) + body


def tls_rejection(error):
    reason = getattr(error, "reason", None)
    if reason in ("SSLV3_ALERT_BAD_CERTIFICATE", "TLSV1_ALERT_UNKNOWN_CA",
                  "SSLV3_ALERT_CERTIFICATE_UNKNOWN", "SSLV3_ALERT_CERTIFICATE_EXPIRED",
                  "TLSV1_ALERT_CERTIFICATE_EXPIRED"):
        return "certificate_alert"
    if reason in ("TLSV1_ALERT_PROTOCOL_VERSION", "UNSUPPORTED_PROTOCOL"):
        return "protocol_alert"
    if isinstance(error, (ssl.SSLEOFError, ConnectionResetError)):
        return "peer_ended_handshake"
    return None


def another_identifier(previous):
    value = uuid.uuid4().bytes
    while value == previous:
        value = uuid.uuid4().bytes
    return value


def serve(listener, directory, identity, result, mode="positive", client_done=None):
    connection = None
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        version = ssl.TLSVersion.TLSv1_2 if mode == "tls12" else ssl.TLSVersion.TLSv1_3
        context.minimum_version = context.maximum_version = version
        context.options |= ssl.OP_NO_TICKET
        context.verify_mode = ssl.CERT_REQUIRED
        context.load_cert_chain(directory / "guest.pem", directory / "guest-key.pem")
        context.load_verify_locations(directory / "ca.pem")
        connection, _ = listener.accept()
        result["unixAccepted"] = True
        connection.settimeout(10)
        with context.wrap_socket(connection, server_side=True) as stream:
            assert stream.version() == "TLSv1.3"
            assert ("DNS", "macopenvm-host.invalid") in stream.getpeercert()["subjectAltName"]
            result.update(tls13=True, mutualPeerVerified=True, serverTLSAuthenticated=True)
            if mode in TRUST_MODES:
                try:
                    unexpected = stream.recv(1)
                    result["endedBeforeHello"] = not unexpected
                    result["unexpectedApplicationData"] = bool(unexpected)
                except (ssl.SSLEOFError, ConnectionResetError):
                    result["endedBeforeHello"] = True
                return
            hello = receive(stream, 1, 64, result)
            session, sequence, request, vm_id, supported, required = struct.unpack(">16sQ16s16sII", hello)
            assert sequence == 0 and any(session) and any(request) and vm_id == identity.bytes
            assert supported == required == 1
            result["helloReceived"] = True
            reply_vm = another_identifier(vm_id) if mode == "wrong-vm" else vm_id
            reply = struct.pack(">16sQ16s16sIHHHH", session, 0, request, reply_vm, 1, 0, 1, 0, 1)
            stream.sendall(frame(2, reply))
            if mode == "wrong-vm":
                result.update(invalidReplySent=True, injectedFault="hello.vmID")
                assert client_done is not None and client_done.wait(20)
                return
            health = receive(stream, 3, 40, result)
            health_session, health_sequence, health_id = struct.unpack(">16sQ16s", health)
            assert health_session == session and health_sequence == 1 and any(health_id) and health_id != request
            result["healthRequestReceived"] = True
            reply_session = another_identifier(session) if mode == "wrong-session" else session
            reply_sequence = 2 if mode == "wrong-sequence" else 1
            reply = struct.pack(">16sQ16sHHHHI", reply_session, reply_sequence, health_id, 0, 1, 0, 1, 1)
            stream.sendall(frame(4, reply))
            result["healthReplySent"] = True
            if mode in REPLY_MODES:
                result.update(invalidReplySent=True,
                              injectedFault="health.sessionID" if mode == "wrong-session" else "health.sequence")
                assert client_done is not None and client_done.wait(20)
                return
            result["typedHealthExchange"] = True
            # Let the client consume its complete reply before ending this channel.
            # A TCP reset immediately after write may discard pending delivery.
            try:
                assert not stream.recv(1)
            except (ssl.SSLEOFError, BrokenPipeError, ConnectionResetError):
                result["clientEndedAfterHealth"] = True
    except Exception as error:
        rejection = tls_rejection(error)
        if mode in TRUST_MODES and result["unixAccepted"] and not result["serverTLSAuthenticated"] and rejection:
            result["serverHandshakeRejection"] = rejection
        else:
            result["serverFailure"] = type(error).__name__
    finally:
        if connection is not None:
            connection.close()
        listener.close()


def cli_failure(stderr):
    message = stderr.decode("utf8", "replace").strip()
    known = {
        "macOpenVM: The authenticated agent handshake failed.": "handshake_failed",
        "macOpenVM: The agent transport deadline expired.": "deadline_expired",
        "macOpenVM: The agent transport failed.": "transport_failed",
        "macOpenVM: The agent transport ended before the bounded frame was complete.": "truncated_frame",
        "macOpenVM: The agent transport settings are invalid.": "invalid_transport_configuration",
        "macOpenVM: The lab agent credential is unavailable or invalid.": "invalid_lab_credential",
        "macOpenVM: The approved agent trust settings are invalid.": "invalid_trust_configuration",
        "macOpenVM: Operation failed. Inspect prerequisites and preserved local VM files.": "operation_failed",
    }
    return known.get(message, "unclassified_cli_failure")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def accepted_outcome(result):
    if result.get("runnerFailure") or result.get("serverFailure") or not result["serverTerminal"]:
        return False
    mode = result["mode"]
    if mode == "positive":
        return (result["cliExitCode"] == 0 and result["nativeValidatedHealth"]
                and result["serverTLSAuthenticated"] and result["typedHealthExchange"])
    if result["cliExitCode"] != 1 or result["nativeValidatedHealth"] or result["cliHealthOutput"]:
        return False
    if mode in TRUST_MODES:
        rejection = result.get("serverHandshakeRejection")
        if mode == "tls12" and rejection != "protocol_alert":
            return False
        if mode != "tls12" and rejection not in ("certificate_alert", "peer_ended_handshake", None):
            return False
        return (result.get("cliFailure") == "handshake_failed" and result["unixAccepted"]
                and result["receivedApplicationBytes"] == 0 and not result["helloReceived"]
                and (rejection is not None or result.get("endedBeforeHello", False)))
    return (result.get("cliFailure") == "operation_failed" and result["serverTLSAuthenticated"]
            and result["helloReceived"] and result.get("invalidReplySent", False)
            and (mode == "wrong-vm" or result["healthRequestReceived"]))


def run_case(cli, mode, expected_cli_digest):
    identity = uuid.uuid4()
    directory = Path("/private/tmp") / ("mvo-agent-tls-" + uuid.uuid4().hex)
    directory.mkdir(mode=0o700)
    result = {"mode": mode, "expectedOutcome": "accepted_health" if mode == "positive" else "rejected",
              "unixAccepted": False, "serverTLSAuthenticated": False, "helloReceived": False,
              "healthRequestReceived": False, "healthReplySent": False, "typedHealthExchange": False,
              "nativeValidatedHealth": False, "receivedApplicationBytes": 0,
              "cliHealthOutput": False, "cliExitCode": None, "serverTerminal": False}
    listener = None
    thread = None
    client_done = threading.Event()
    try:
        result.update(issue(directory, mode))
        if digest(cli) != expected_cli_digest:
            raise RuntimeError("The evaluated CLI changed")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.settimeout(15)
        endpoint = directory / "s.sock"
        listener.bind(str(endpoint))
        endpoint.chmod(0o600)
        listener.listen(1)
        thread = threading.Thread(target=serve, args=(listener, directory, identity, result, mode, client_done))
        thread.start()
        process = subprocess.run([str(cli), "agent-tls-lab", "--socket", str(endpoint),
                                  "--credentials", str(directory), "--vm-id", str(identity)],
                                 capture_output=True, timeout=20)
        client_done.set()
        thread.join(16)
        result.update(cliExitCode=process.returncode, serverTerminal=not thread.is_alive())
        if process.returncode == 0:
            output = json.loads(process.stdout)
            result["cliHealthOutput"] = bool(output.get("health"))
            assert output["health"]["healthConfirmed"] and output["nativePeerTrustVerified"]
            result["nativeValidatedHealth"] = True
        else:
            result["cliHealthOutput"] = bool(process.stdout.strip())
            result["cliFailure"] = cli_failure(process.stderr)
        if digest(cli) != expected_cli_digest:
            raise RuntimeError("The evaluated CLI changed")
    except Exception as error:
        result["runnerFailure"] = type(error).__name__
    finally:
        client_done.set()
        if listener is not None:
            listener.close()
        if thread is not None and thread.is_alive():
            thread.join(16)
        if thread is None or not thread.is_alive():
            shutil.rmtree(directory)
        result["serverTerminal"] = thread is None or not thread.is_alive()
        result["credentialContentsRetained"] = directory.exists()
        result["credentialsOutsideProject"] = True
    result["passed"] = accepted_outcome(result) and not result["credentialContentsRetained"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--campaign", action="store_true", help="Run the positive and eight bounded rejection cases.")
    group.add_argument("--mode", choices=MODES, default="positive")
    args = parser.parse_args()
    cli = args.cli.resolve()
    os.umask(0o077)
    cli_digest = digest(cli)
    runner_digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    root = ROOT / ".lab" / ("agent-tls-native-" + uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    cases = []
    modes = MODES if args.campaign else (args.mode,)
    for mode in modes:
        result = run_case(cli, mode, cli_digest)
        cases.append(result)
        (root / (mode + ".json")).write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(dict(evidence=str(root), **result)), flush=True)
    if args.campaign:
        outcome = {"campaign": True, "cases": cases, "passed": all(case["passed"] for case in cases)}
    else:
        outcome = cases[0].copy()
    outcome.update(scope="native Unix TLS/schema interoperability; no guest/Keychain/install proof",
                   cliSHA256=cli_digest, runnerSHA256=runner_digest,
                   credentialContentsRetained=any(case["credentialContentsRetained"] for case in cases),
                   credentialsOutsideProject=True)
    (root / "result.json").write_text(json.dumps(outcome, indent=2) + "\n")
    print(json.dumps(dict(evidence=str(root), **outcome)), flush=True)
    if not outcome["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
