# SPDX-License-Identifier: Apache-2.0
"""Pure independent swtpm wire fixtures; no real sockets/processes/guests."""
from pathlib import Path
import unittest
from unittest.mock import patch

from runtime_worker_survivor_loss_lab import PrivateTPM


class WireStream:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.sent = []
        self.timeouts = []

    def settimeout(self, value):
        self.timeouts.append(value)

    def sendall(self, value):
        self.sent.append(value)

    def recv(self, maximum):
        if not self.chunks:
            return b""
        chunk = self.chunks.pop(0)
        if len(chunk) > maximum:
            self.chunks.insert(0, chunk[maximum:])
        return chunk[:maximum]


def peer(stream):
    # Constructor/real peer checks belong to the explicit native trial. This
    # fixture exercises the command exchange against independent literal bytes.
    value = PrivateTPM.__new__(PrivateTPM)
    value.path = Path("/private/tmp/unused-test.sock")
    value.identity = (1, 2, 3, 4)
    value.connection = stream
    return value


class SurvivorPublicTPMWireTests(unittest.TestCase):
    def test_fragmented_capability_and_shutdown_wire(self):
        stream = WireStream([bytes([byte]) for byte in (0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0)])
        with patch("runtime_worker_survivor_loss_lab.socket_identity", return_value=(1, 2, 3, 4)):
            value = peer(stream)
            self.assertEqual(value.command(1), 2)
            self.assertEqual(value.command(3), 0)
        self.assertEqual(stream.sent, [b"\x00\x00\x00\x01", b"\x00\x00\x00\x03"])
        self.assertTrue(all(0 < timeout <= 3 for timeout in stream.timeouts))

    def test_unsuccessful_or_truncated_shutdown_does_not_succeed(self):
        for chunks in ([b"\x00\x00\x00\x01"], [b"\x00\x00"]):
            with self.subTest(chunks=chunks), patch(
                    "runtime_worker_survivor_loss_lab.socket_identity", return_value=(1, 2, 3, 4)):
                with self.assertRaises(ValueError):
                    peer(WireStream(chunks)).command(3)

    def test_shutdown_capability_is_required(self):
        with patch("runtime_worker_survivor_loss_lab.socket_identity", return_value=(1, 2, 3, 4)):
            with self.assertRaises(ValueError):
                peer(WireStream([bytes(8)])).command(1)

    def test_other_commands_or_changed_endpoint_never_send(self):
        stream = WireStream([])
        with self.assertRaises(ValueError):
            peer(stream).command(14)
        with patch("runtime_worker_survivor_loss_lab.socket_identity", return_value=(1, 2, 3, 5)):
            with self.assertRaises(ValueError):
                peer(stream).command(3)
        self.assertEqual(stream.sent, [])


if __name__ == "__main__":
    unittest.main()
