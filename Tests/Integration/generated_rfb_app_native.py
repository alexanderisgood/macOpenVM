#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Explicit original-pixel App presentation test; retains child, never starts a VM."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import build_manifest

GEOMETRIES = ((800, 600), (1920, 1080), (3840, 2160))
FRAME_COUNT = 18
VERSION = b"RFB 003.008\n"
PIXEL_FORMAT = bytes((32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0))
CLIENT_FORMAT = bytes((0, 0, 0, 0)) + PIXEL_FORMAT
CLIENT_ENCODINGS = bytes((2, 0, 0, 2)) + struct.pack("!ii", 0, -223)


def require(condition, code):
    if not condition:
        raise ValueError(code)


def plain(path, *, directory=False, private=False):
    require(path.is_absolute() and str(path) == os.path.abspath(path), "normalized-absolute-path-required")
    for item in (path, *path.parents):
        value = item.lstat()
        require(not stat.S_ISLNK(value.st_mode), "path-alias-refused")
        if item != path:
            require(stat.S_ISDIR(value.st_mode), "directory-ancestry-required")
    value = path.lstat()
    require(stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode), "plain-path-required")
    if private:
        require(value.st_uid == os.geteuid() and stat.S_IMODE(value.st_mode) == (0o700 if directory else 0o600),
                "private-owned-path-required")
    return value


def digest(path):
    plain(path)
    return build_manifest.sha256_file(path)


def save(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def request(width, height, *, incremental):
    require((width, height) in GEOMETRIES and type(incremental) is bool, "fixed-request-geometry-required")
    return bytes((3, int(incremental), 0, 0, 0, 0)) + struct.pack("!HH", width, height)


def rectangle(width, height, encoding):
    require((width, height) in GEOMETRIES and encoding in (0, -223), "fixed-rectangle-required")
    return b"\0\0\0\1" + struct.pack("!HHHHi", 0, 0, width, height, encoding)


def frame_chunk(ordinal):
    require(type(ordinal) is int and 1 <= ordinal <= FRAME_COUNT, "fixed-public-frame-ID-required")
    return bytes((ordinal, 0x40, 0x80, 0)) * 16384


def receive(peer, count, stop):
    require(0 < count <= 24, "bounded-protocol-read-required")
    result = bytearray()
    while len(result) < count:
        if stop.is_set():
            raise EOFError("fixture-owner-finished")
        try:
            part = peer.recv(count - len(result))
        except socket.timeout:
            continue  # An observation timeout is not permission to close/restart.
        if not part:
            raise EOFError("generated-peer-closed")
        result.extend(part)
    return bytes(result)


def serve(peer, stop, rows):
    """One connection, closed wire grammar, public pixels streamed in <=64KiB chunks."""
    peer.settimeout(1)
    peer.sendall(VERSION)
    require(receive(peer, 12, stop) == VERSION, "RFB38-client-version-required")
    peer.sendall(b"\1\1")
    require(receive(peer, 1, stop) == b"\1", "None-security-selection-required")
    peer.sendall(b"\0\0\0\0")
    require(receive(peer, 1, stop) == b"\1", "shared-client-init-required")
    peer.sendall(struct.pack("!HH", *GEOMETRIES[0]) + PIXEL_FORMAT + b"\0\0\0\0")
    require(receive(peer, 20, stop) == CLIENT_FORMAT, "exact-BGRX-format-required")
    require(receive(peer, 12, stop) == CLIENT_ENCODINGS, "Raw-DesktopSize-only-required")
    previous = None
    for ordinal in range(1, FRAME_COUNT + 1):
        group = (ordinal - 1) // 6
        width, height = GEOMETRIES[group]
        if ordinal in (7, 13):
            old_width, old_height = GEOMETRIES[group - 1]
            require(receive(peer, 10, stop) == request(old_width, old_height, incremental=True),
                    "old-size-incremental-request-required")
            peer.sendall(rectangle(width, height, -223))
            require(receive(peer, 10, stop) == request(width, height, incremental=False),
                    "full-request-after-DesktopSize-required")
        else:
            require(receive(peer, 10, stop) == request(width, height, incremental=ordinal != 1),
                    "exact-full-viewport-request-required")
        if previous is not None:
            pause = 0.1 - (time.monotonic_ns() - previous) / 1_000_000_000
            if pause > 0:
                time.sleep(pause)
        began = time.monotonic_ns()
        gap = None if previous is None else began - previous
        peer.sendall(rectangle(width, height, 0))
        chunk = frame_chunk(ordinal)
        remaining = width * height * 4
        while remaining:
            count = min(remaining, len(chunk))
            peer.sendall(chunk[:count])
            remaining -= count
        previous = time.monotonic_ns()
        rows.append({"ordinal": ordinal, "width": width, "height": height,
                     "payloadBytes": width * height * 4, "responseNanoseconds": previous - began,
                     "previousSendCompleteToResponseStartNanoseconds": gap})
    # No key, pointer, clipboard or unsolicited request is accepted after frame18.
    while not stop.is_set():
        try:
            extra = peer.recv(1)
        except socket.timeout:
            continue
        require(extra == b"", "client-input-or-extra-request-refused")
        return True
    return False


class GeneratedPeer:
    def __init__(self, parent):
        plain(parent, directory=True, private=True)
        self.path = parent / "display.sock"
        self.stop = threading.Event()
        self.rows = []
        self.completed = False
        self.failure = None
        self.client_eof = False
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        bound = False
        try:
            self.listener.bind(str(self.path))
            bound = True
            self.identity = self.path.lstat()
            self.path.chmod(0o600)
            named = self.path.lstat()
            require(stat.S_ISSOCK(named.st_mode) and named.st_uid == os.geteuid()
                    and stat.S_IMODE(named.st_mode) == 0o600
                    and (named.st_dev, named.st_ino) == (self.identity.st_dev, self.identity.st_ino),
                    "private-owned-socket-required")
            self.listener.listen(1)
            self.listener.settimeout(1)
            self.thread = threading.Thread(target=self._run, name="macOpenVM-generated-RFB", daemon=False)
            self.thread.start()
        except BaseException:
            self.listener.close()
            if bound:
                named = self.path.lstat()
                if (named.st_dev, named.st_ino) == (self.identity.st_dev, self.identity.st_ino):
                    self.path.unlink()
            raise

    def _run(self):
        try:
            while not self.stop.is_set():
                try:
                    peer, _ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
            else:
                return
            with peer:
                self.client_eof = serve(peer, self.stop, self.rows)
                self.completed = self.client_eof and len(self.rows) == FRAME_COUNT
        except Exception as error:
            self.failure = type(error).__name__  # Closed class only, no peer bytes or path.

    def finish_after_parent_exit(self):
        # Give the closed client's actual EOF a bounded chance to arrive before
        # cancelling the no-peer accept loop. No signal targets the App process.
        self.thread.join(timeout=2)
        self.stop.set()
        self.thread.join()
        self.listener.close()
        named = self.path.lstat()
        require((named.st_dev, named.st_ino) == (self.identity.st_dev, self.identity.st_ino),
                "owned-socket-identity-changed")
        self.path.unlink()


def sdk_observation(value, nonce):
    fields = {"schemaVersion", "scope", "nonce", "phase", "passed", "received", "drawn",
              "coalescedFrames", "bounds", "backingScale", "fittedRect", "idleQuitRequested",
              "connectionAttempted", "closeAwaitCompleted", "guestStarted", "inputSent", "pixelsPersisted",
              "sameOwner", "connectionEpoch", "physicalScanoutVerified", "guestPerformanceVerified",
              "guestPixelsRead", "generatedPixelsValidated"}
    require(isinstance(value, dict) and set(value) in (fields, fields - {"connectionEpoch"})
            and type(value["schemaVersion"]) is int
            and value["schemaVersion"] == 1 and value["scope"] == "generated-public-RFB-client-AppKit-presentation"
            and value["nonce"] == nonce, "closed-correlated-SDK-result-required")
    require(isinstance(value["phase"], str) and value["phase"] in ("admission", "connect", "receive", "draw", "complete"),
            "bounded-SDK-phase-required")
    for name in ("passed", "idleQuitRequested", "connectionAttempted", "closeAwaitCompleted", "guestStarted",
                 "inputSent", "pixelsPersisted", "sameOwner", "physicalScanoutVerified", "guestPerformanceVerified",
                 "guestPixelsRead", "generatedPixelsValidated"):
        require(type(value[name]) is bool, "SDK-booleans-required")
    epoch = value.get("connectionEpoch")
    require((epoch is None and value["passed"] is False and value["received"] == [])
            or (isinstance(epoch, str) and re.fullmatch(r"[0-9A-F]{8}-(?:[0-9A-F]{4}-){3}[0-9A-F]{12}", epoch)
            and uuid.UUID(epoch).int != 0), "SDK-connection-epoch-required")
    for name in ("bounds", "fittedRect"):
        require(isinstance(value[name], list) and len(value[name]) == 4
                and all(type(part) in (int, float) and math.isfinite(part) for part in value[name]),
                "finite-SDK-geometry-required")
    require(type(value["backingScale"]) in (int, float) and math.isfinite(value["backingScale"])
            and value["backingScale"] >= 0, "finite-SDK-backing-scale-required")
    rows = value["received"]
    require(isinstance(rows, list) and len(rows) <= FRAME_COUNT, "bounded-SDK-frame-records-required")
    sequence = 0
    previous_publish = 0
    row_fields = {"marker", "width", "height", "sequence", "requestMS", "receiveMS", "publishMS", "allPixelsMatched"}
    for ordinal, row in enumerate(rows, 1):
        require(isinstance(row, dict) and set(row) == row_fields, "closed-SDK-frame-required")
        width, height = GEOMETRIES[(ordinal - 1) // 6]
        for name in ("marker", "width", "height", "sequence"):
            require(type(row[name]) is int and 0 < row[name] <= (1 << 64) - 1, "SDK-frame-integers-required")
        require((row["marker"], row["width"], row["height"]) == (ordinal, width, height)
                and row["sequence"] == ordinal and row["sequence"] > sequence, "SDK-frame-order-required")
        require(type(row["allPixelsMatched"]) is bool and all(type(row[name]) in (int, float)
                and math.isfinite(row[name]) and row[name] >= 0 for name in ("requestMS", "receiveMS", "publishMS"))
                and previous_publish <= row["requestMS"] <= row["receiveMS"] <= row["publishMS"],
                "SDK-frame-observation-required")
        sequence = row["sequence"]
        previous_publish = row["publishMS"]
    drawn = value["drawn"]
    require(isinstance(drawn, list) and len(drawn) <= len(rows), "bounded-SDK-draw-records-required")
    sequence = 0
    previous_draw = 0
    received = {row["marker"]: row for row in rows}
    for row in drawn:
        require(isinstance(row, dict) and set(row) == {"marker", "sequence", "drawMS", "publishToDrawMS"},
                "closed-SDK-draw-required")
        require(type(row["marker"]) is int and row["marker"] in received and type(row["sequence"]) is int
                and row["sequence"] == received[row["marker"]]["sequence"] and row["sequence"] > sequence,
                "drawn-subset-order-required")
        require(all(type(row[name]) in (int, float) and math.isfinite(row[name]) and row[name] >= 0
                    for name in ("drawMS", "publishToDrawMS")), "finite-SDK-draw-timing-required")
        publish = received[row["marker"]]["publishMS"]
        require(row["drawMS"] >= max(previous_draw, publish)
                and math.isclose(row["publishToDrawMS"], row["drawMS"] - publish, rel_tol=1e-9, abs_tol=1e-7),
                "actual-draw-timing-required")
        sequence = row["sequence"]
        previous_draw = row["drawMS"]
    require(type(value["coalescedFrames"]) is int and value["coalescedFrames"] == len(rows) - len(drawn),
            "actual-coalescing-count-required")
    return value


def sdk_passed(value):
    if not (value["passed"] and value["phase"] == "complete" and value["connectionAttempted"]
            and value["closeAwaitCompleted"] and value["idleQuitRequested"] and value["sameOwner"]
            and value["generatedPixelsValidated"] and value.get("connectionEpoch") is not None
            and len(value["received"]) == FRAME_COUNT):
        return False
    if any(value[name] for name in ("guestStarted", "inputSent", "pixelsPersisted", "physicalScanoutVerified",
                                    "guestPerformanceVerified", "guestPixelsRead")):
        return False
    bounds, fitted = value["bounds"], value["fittedRect"]
    if not (value["backingScale"] > 0 and bounds[2] > 0 and bounds[3] > 0 and fitted[2] > 0 and fitted[3] > 0
            and fitted[0] >= bounds[0] and fitted[1] >= bounds[1]
            and fitted[0] + fitted[2] <= bounds[0] + bounds[2] + 1e-7
            and fitted[1] + fitted[3] <= bounds[1] + bounds[3] + 1e-7):
        return False
    markers = {row["marker"] for row in value["drawn"]}
    return (all(row["allPixelsMatched"] for row in value["received"]) and FRAME_COUNT in markers
            and all(markers.intersection(range(start, start + 6)) for start in (1, 7, 13)))


def admit(artifact):
    require(artifact is not None and artifact.parent == ROOT / ".lab"
            and re.fullmatch(r"linux-desktop-artifacts-[0-9a-f]{32}", artifact.name), "private-App-build-required")
    plain(artifact, directory=True)
    build = build_manifest.bounded_json(artifact / "build-record.json")
    require(build["sources"] == build_manifest.source_snapshot(ROOT)
            and build["primaryApplicationChanged"] is False and build["credentialsAuthorized"] is False,
            "current-source-build-required")
    app = artifact / "macOpenVM.app/Contents/MacOS/macOpenVMNative"
    info = plain(app)
    require(info.st_uid == os.geteuid() and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o500
            and digest(app) == build["appExecutableSHA256"], "immutable-App-pin-required")
    for key, path in (("wrapperSHA256", app.parent / "macOpenVM"),
                      ("appWorkerSHA256", app.parent / "macopenvm-worker"),
                      ("cliSHA256", artifact / "macopenvm"),
                      ("appWorkerDescriptorSHA256", app.parent.parent / "Resources/macopenvm-worker.json")):
        require(digest(path) == build[key], "build-artifact-pin-required")
    return app, build


def app_arguments(app, display_socket, nonce, evidence):
    require(re.fullmatch(r"/private/tmp/mvo-rfb-present-[0-9a-f]{32}/display\.sock", str(display_socket))
            and evidence == display_socket.parent / "evidence", "fixed-private-display-route-required")
    require(isinstance(nonce, str) and re.fullmatch(r"[0-9A-F]{8}-(?:[0-9A-F]{4}-){3}[0-9A-F]{12}", nonce)
            and uuid.UUID(nonce).int != 0, "fresh-correlation-required")
    return [str(app), "--generated-rfb-app-qualification", "--run", "--display-socket", str(display_socket),
            "--nonce", nonce, "--output-directory", str(evidence)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--artifact", type=Path)
    args = parser.parse_args(argv)
    if not args.run:
        print("SKIP: explicit generated-display test required; no socket, App or guest started")
        return 0
    app, build = admit(args.artifact)
    os.umask(0o077)
    parent = Path("/private/tmp/mvo-rfb-present-" + uuid.uuid4().hex)
    parent.mkdir(mode=0o700)
    evidence = parent / "evidence"
    evidence.mkdir(mode=0o700)
    nonce = str(uuid.uuid4()).upper()
    save(evidence / "native-admission.json", {"scope": "original-generated-RFB-display-only", "nonce": nonce,
         "buildConfiguration": build.get("configuration", "debug"),
         "appSHA256": build["appExecutableSHA256"], "sourceSnapshot": build["sources"],
         "buildRecordSHA256": digest(args.artifact / "build-record.json"),
         "runnerSHA256": digest(Path(__file__).resolve()), "helperSHA256": digest(Path(build_manifest.__file__)),
         "guestStarted": False, "pixelsPersisted": False})
    environment = dict(os.environ)
    environment["MVO_GENERATED_RFB_APP_QUALIFICATION"] = "1"
    child = None
    observation_failure = None
    with (evidence / "app.stdout").open("xb") as stdout, (evidence / "app.stderr").open("xb") as stderr:
        peer = GeneratedPeer(parent)
        try:
            child = subprocess.Popen(app_arguments(app, peer.path, nonce, evidence), stdin=subprocess.DEVNULL,
                stdout=stdout, stderr=stderr, env=environment, close_fds=True, start_new_session=True)
            print(json.dumps({"scope": "retained-generated-display-App", "evidence": str(evidence)}), flush=True)
            began = time.monotonic()
            while child.poll() is None:
                if time.monotonic() - began >= 45:
                    print(json.dumps({"observationPending": True, "parentStillRetained": True,
                                      "socketStillOwned": True, "automaticSignalOrRestart": False}), flush=True)
                    began = time.monotonic()
                time.sleep(0.1)
            exit_code = child.wait()
        except BaseException as error:
            observation_failure = type(error).__name__
            if child is not None:
                print(json.dumps({"harnessObservationFailed": type(error).__name__, "parentStillRetained": True,
                                  "automaticSignalOrRestart": False}), flush=True)
                while child.poll() is None:
                    try:
                        time.sleep(0.1)
                    except BaseException:
                        continue
                exit_code = child.wait()
            else:
                peer.finish_after_parent_exit()
                raise
    peer.finish_after_parent_exit()
    result = sdk_observation(build_manifest.bounded_json(evidence / "presentation-result.json", 32768), nonce)
    passed = exit_code == 0 and observation_failure is None and sdk_passed(result)
    passed = passed and peer.completed and peer.client_eof and peer.failure is None
    current_app, current_build = admit(args.artifact)
    require(current_app == app and current_build == build, "native-inputs-changed")
    admission = build_manifest.bounded_json(evidence / "native-admission.json")
    require(digest(Path(__file__).resolve()) == admission["runnerSHA256"]
            and digest(Path(build_manifest.__file__)) == admission["helperSHA256"]
            and digest(args.artifact / "build-record.json") == admission["buildRecordSHA256"], "harness-input-changed")
    save(evidence / "native-result.json", {"scope": "actual-generated-RFB-SDK-presentation", "passed": bool(passed),
         "buildConfiguration": build.get("configuration", "debug"),
         "actualAppExit": exit_code, "actualAppParentReaped": True, "sdkResult": result, "wireFrames": peer.rows,
         "serverCompleted": peer.completed, "clientEOFObserved": peer.client_eof, "serverFailure": peer.failure,
         "harnessObservationFailure": observation_failure,
         "serverJoined": True, "ownedSocketRemovedAfterAppExit": True, "appSHA256": build["appExecutableSHA256"],
         "guestStarted": False, "credentialsCreated": False, "pixelsPersisted": False})
    print(json.dumps({"passed": bool(passed), "actualAppExit": exit_code, "evidence": str(evidence)}), flush=True)
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
