#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Original wire and metadata checks; no App, guest, credentials or display opened."""
import copy
from pathlib import Path
import socket
import threading
import unittest
from unittest.mock import patch

import generated_rfb_app_native as lab

NONCE = "785129E9-CF0A-4657-A1A6-5EDE37C4C99D"
EPOCH = "546F3641-1B62-4E02-9A77-BF8F14B6C22D"


def observation():
    received = []
    for marker in range(1, 19):
        width, height = lab.GEOMETRIES[(marker - 1) // 6]
        received.append(dict(marker=marker, sequence=marker, width=width, height=height,
                             requestMS=marker * 100, receiveMS=marker * 100 + 10,
                             publishMS=marker * 100 + 20, allPixelsMatched=True))
    drawn = [dict(marker=marker, sequence=marker, drawMS=marker * 100 + 25, publishToDrawMS=5)
             for marker in (6, 12, 18)]
    return dict(schemaVersion=1, scope="generated-public-RFB-client-AppKit-presentation", nonce=NONCE,
                phase="complete", passed=True, received=received, drawn=drawn, coalescedFrames=15,
                bounds=[0, 0, 800, 600], backingScale=2, fittedRect=[0, 75, 800, 450],
                sameOwner=True, connectionEpoch=EPOCH, connectionAttempted=True, closeAwaitCompleted=True,
                physicalScanoutVerified=False, guestPerformanceVerified=False, inputSent=False,
                guestStarted=False, pixelsPersisted=False, idleQuitRequested=True,
                guestPixelsRead=False, generatedPixelsValidated=True)


def read_exact(peer, count):
    result = bytearray()
    while len(result) < count:
        part = peer.recv(count - len(result))
        if not part:
            raise EOFError("test peer closed")
        result.extend(part)
    return bytes(result)


class GeneratedRfbNativeTests(unittest.TestCase):
    def test_wire_headers_match_independent_big_endian_golden_bytes(self):
        self.assertEqual(lab.request(800, 600, incremental=False), b"\x03\x00\x00\x00\x00\x00\x03\x20\x02\x58")
        self.assertEqual(lab.request(3840, 2160, incremental=True), b"\x03\x01\x00\x00\x00\x00\x0f\x00\x08\x70")
        self.assertEqual(lab.rectangle(1920, 1080, -223),
                         b"\x00\x00\x00\x01\x00\x00\x00\x00\x07\x80\x04\x38\xff\xff\xff\x21")
        self.assertEqual(lab.CLIENT_FORMAT,
                         b"\x00\x00\x00\x00\x20\x18\x00\x01\x00\xff\x00\xff\x00\xff\x10\x08\x00\x00\x00\x00")
        self.assertEqual(lab.CLIENT_ENCODINGS, b"\x02\x00\x00\x02\x00\x00\x00\x00\xff\xff\xff\x21")

    def test_fixed_public_pixels_and_bounds(self):
        for marker in (1, 6, 7, 12, 13, 18):
            chunk = lab.frame_chunk(marker)
            self.assertEqual(len(chunk), 65536)
            self.assertEqual(chunk, bytes((marker, 64, 128, 0)) * 16384)
        for marker in (0, 19, True, "1"):
            with self.assertRaises(ValueError):
                lab.frame_chunk(marker)
        with self.assertRaises(ValueError):
            lab.request(640, 480, incremental=False)

    def test_closed_route_arguments_refuse_foreign_or_missing_correlation(self):
        parent = Path("/private/tmp/mvo-rfb-present-" + "a" * 32)
        app = Path("/original-test-App")
        args = lab.app_arguments(app, parent / "display.sock", NONCE, parent / "evidence")
        self.assertEqual(args, [str(app), "--generated-rfb-app-qualification", "--run", "--display-socket",
                               str(parent / "display.sock"), "--nonce", NONCE, "--output-directory", str(parent / "evidence")])
        for endpoint, nonce, evidence in (
            (Path("/tmp/display.sock"), NONCE, parent / "evidence"),
            (parent / "display.sock", "00000000-0000-0000-0000-000000000000", parent / "evidence"),
            (parent / "display.sock", NONCE, parent / "foreign"),
        ):
            with self.assertRaises(ValueError):
                lab.app_arguments(app, endpoint, nonce, evidence)

    def test_unrequested_run_creates_no_socket_or_process(self):
        with patch.object(lab, "GeneratedPeer", side_effect=AssertionError("socket opened")), \
                patch.object(lab.subprocess, "Popen", side_effect=AssertionError("App launched")):
            self.assertEqual(lab.main([]), 0)

    def test_coalesced_draw_subset_is_valid_without_fabricated_all_frame_draws(self):
        value = observation()
        self.assertIs(lab.sdk_observation(value, NONCE), value)
        self.assertEqual(len(value["received"]), 18)
        self.assertEqual(len(value["drawn"]), 3)
        self.assertTrue(lab.sdk_passed(value))

    def test_pass_requires_all_geometries_final_draw_pixels_and_cleanup(self):
        for change in (
            lambda v: v.update(drawn=v["drawn"][:-1], coalescedFrames=16),
            lambda v: v.update(drawn=v["drawn"][1:], coalescedFrames=16),
            lambda v: v.update(closeAwaitCompleted=False),
            lambda v: v.update(guestPixelsRead=True),
            lambda v: v["received"][0].update(allPixelsMatched=False),
            lambda v: v.update(fittedRect=[0, 0, 900, 700]),
        ):
            value = observation()
            change(value)
            lab.sdk_observation(value, NONCE)
            self.assertFalse(lab.sdk_passed(value))

    def test_metadata_refuses_stale_nonce_wrong_geometry_duplicate_and_fabricated_draw(self):
        changes = (
            lambda v: v.update(nonce=EPOCH),
            lambda v: v.update(unexpected="guest text"),
            lambda v: v["received"][6].update(width=800),
            lambda v: v["received"][6].update(sequence=6),
            lambda v: v["drawn"][0].update(sequence=1),
            lambda v: v["drawn"].append(copy.deepcopy(v["drawn"][0])),
            lambda v: v.update(coalescedFrames=0),
            lambda v: v["received"][0].update(sequence=True),
        )
        for change in changes:
            value = observation()
            change(value)
            with self.assertRaises(ValueError):
                lab.sdk_observation(value, NONCE)

    def test_nonfinite_and_reversed_timestamps_refused(self):
        for change in (
            lambda v: v.update(backingScale=float("nan")),
            lambda v: v["received"][0].update(receiveMS=float("inf")),
            lambda v: v["received"][0].update(publishMS=0),
            lambda v: v["drawn"][0].update(drawMS=0),
            lambda v: v["drawn"][0].update(publishToDrawMS=99),
            lambda v: v["received"][1].update(requestMS=0),
        ):
            value = observation()
            change(value)
            with self.assertRaises(ValueError):
                lab.sdk_observation(value, NONCE)

    def test_admission_failure_can_report_no_connection_without_claiming_success(self):
        value = observation()
        value.update(phase="admission", passed=False, received=[], drawn=[], coalescedFrames=0,
                     connectionEpoch=None, sameOwner=False, connectionAttempted=False,
                     closeAwaitCompleted=False, generatedPixelsValidated=False, backingScale=0,
                     bounds=[0, 0, 0, 0], fittedRect=[0, 0, 0, 0])
        self.assertIs(lab.sdk_observation(value, NONCE), value)
        self.assertFalse(lab.sdk_passed(value))
        del value["connectionEpoch"]  # Synthesized Swift Encodable omits nil optionals.
        self.assertIs(lab.sdk_observation(value, NONCE), value)
        self.assertFalse(lab.sdk_passed(value))
        value["passed"] = True
        with self.assertRaises(ValueError):
            lab.sdk_observation(value, NONCE)

    def test_fragmented_real_unix_peer_handshake_and_full_public_frame_then_refuses_input(self):
        server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        server.settimeout(2)
        client.settimeout(2)
        stop, rows, errors = threading.Event(), [], []
        def run_server():
            with server:
                try:
                    lab.serve(server, stop, rows)
                except Exception as error:
                    errors.append(error)
        thread = threading.Thread(target=run_server)
        thread.start()
        try:
            self.assertEqual(read_exact(client, 12), b"RFB 003.008\n")
            for byte in b"RFB 003.008\n":
                client.sendall(bytes((byte,)))
            self.assertEqual(read_exact(client, 2), b"\x01\x01")
            client.sendall(b"\x01")
            self.assertEqual(read_exact(client, 4), b"\0" * 4)
            client.sendall(b"\x01")
            header = read_exact(client, 24)
            self.assertEqual(header[:4], b"\x03\x20\x02\x58")
            self.assertEqual(header[4:20], lab.PIXEL_FORMAT)
            self.assertEqual(header[20:], b"\0" * 4)
            client.sendall(lab.CLIENT_FORMAT + lab.CLIENT_ENCODINGS)
            client.sendall(b"\x03\x00\x00\x00\x00\x00\x03\x20\x02\x58")
            self.assertEqual(read_exact(client, 16),
                             b"\x00\x00\x00\x01\x00\x00\x00\x00\x03\x20\x02\x58\x00\x00\x00\x00")
            remaining = 800 * 600 * 4
            while remaining:
                count = min(remaining, 65536)
                self.assertEqual(read_exact(client, count), bytes((1, 64, 128, 0)) * (count // 4))
                remaining -= count
            client.sendall(b"\x05" + b"\0" * 9)  # Pointer/input is outside this fixture's grammar.
            self.assertEqual(client.recv(1), b"")
        finally:
            stop.set()
            client.close()
            thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(rows), 1)
        self.assertIsInstance(errors[0], ValueError)


if __name__ == "__main__":
    unittest.main()
