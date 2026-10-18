#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Pure malformed-input and hash-semantics checks; never a native guest claim."""

import hashlib
import struct
import unittest

from tcg_eventlog import EventLogFailure, parse_probe_output, reconstruct_sha256


def spec(algorithms=((0x000B, 32),)):
    payload = (b"Spec ID Event03\0" + struct.pack("<I", 0) + bytes((0, 2, 2, 2)) +
               struct.pack("<I", len(algorithms)) +
               b"".join(struct.pack("<HH", *item) for item in algorithms) + b"\0")
    return struct.pack("<II", 0, 3) + bytes(20) + struct.pack("<I", len(payload)) + payload


def event(index, kind, digest, payload=b""):
    return (struct.pack("<IIIH", index, kind, 1, 0x000B) + digest +
            struct.pack("<I", len(payload)) + payload)


class EventLogTests(unittest.TestCase):
    def test_mixed_bank_order_and_missing_or_duplicate_event_algorithms(self):
        first = spec(((0x0004, 20), (0x000B, 32)))
        digest = bytes(range(32))
        header = struct.pack('<III', 4, 1, 2)
        entries = struct.pack('<H', 0x000B) + digest + struct.pack('<H', 0x0004) + bytes(20)
        valid = header + entries + struct.pack('<I', 0)
        result = reconstruct_sha256(first + valid, len(first))
        self.assertEqual(result['pcrs'][4], hashlib.sha256(bytes(32) + digest).hexdigest())
        missing = event(4, 1, digest)
        duplicate = header + (struct.pack('<H', 0x0004) + bytes(20)) * 2 + struct.pack('<I', 0)
        for value in (missing, duplicate):
            with self.assertRaises(EventLogFailure):
                reconstruct_sha256(first + value, len(first))

    def test_digest_accumulation_uses_logged_digest_not_event_data(self):
        first = spec()
        digest = bytes(range(32))
        result = reconstruct_sha256(first + event(2, 1, digest, b"unrelated event data"), len(first))
        self.assertEqual(result["pcrs"][2], hashlib.sha256(bytes(32) + digest).hexdigest())
        self.assertEqual(result["pcrs"][0], bytes(32).hex())
        self.assertEqual(result["events"], 2)

    def test_locality_three_seed_and_no_action_not_extended(self):
        first = spec()
        locality = event(0, 3, bytes(32), b"StartupLocality\0\3")
        digest = bytes((7,)) * 32
        result = reconstruct_sha256(first + locality + event(0, 1, digest), len(first + locality))
        self.assertEqual(result["locality"], 3)
        self.assertEqual(result["pcrs"][0], hashlib.sha256(bytes(31) + b"\3" + digest).hexdigest())
        self.assertEqual(result["events"], 3)

    def test_every_truncation_and_wrong_last_boundary_fails(self):
        first = spec()
        data = first + event(4, 1, bytes(range(32)), b"payload")
        for length in range(len(data)):
            with self.subTest(length=length), self.assertRaises(EventLogFailure):
                reconstruct_sha256(data[:length], len(first))
        for offset in (-1, True, 1, len(first) - 1, len(first) + 1, len(data)):
            with self.subTest(offset=offset), self.assertRaises(EventLogFailure):
                reconstruct_sha256(data, offset)

    def test_invalid_algorithm_spec_pcr_and_no_action_fail(self):
        cases = [
            spec(((0x000B, 32), (0x000B, 32))),
            spec(((0xFFFF, 32),)), spec(((0x000B, 31),)), spec(((0x0004, 20),)),
            spec() + event(24, 1, bytes(32)),
            spec() + event(0, 3, bytes((1,)) * 32),
            spec() + event(0, 0x80000010, bytes(32)),
            spec() + event(0, 3, bytes(32), b"StartupLocality\0\4"),
        ]
        for data in cases:
            with self.subTest(size=len(data)), self.assertRaises(EventLogFailure):
                reconstruct_sha256(data, len(spec()) if len(data) > len(spec()) else 0)
        poisoned = bytearray(spec())
        poisoned[28:32] = struct.pack("<I", 0xFFFFFFFF)
        with self.assertRaises(EventLogFailure):
            reconstruct_sha256(bytes(poisoned), 0)
        first = spec()
        locality = event(0, 3, bytes(32), b"StartupLocality\0\0")
        measured = event(0, 1, bytes(32))
        for before in (locality, measured):
            with self.assertRaises(EventLogFailure):
                reconstruct_sha256(first + before + locality, len(first + before))

    def test_exact_event_limit_and_size_limit(self):
        first, item = spec(), event(2, 1, bytes(32))
        valid = first + item * 1023
        result = reconstruct_sha256(valid, len(first) + len(item) * 1022)
        self.assertEqual(result["events"], 1024)
        excessive = first + item * 1024
        with self.assertRaises(EventLogFailure):
            reconstruct_sha256(excessive, len(first) + len(item) * 1023)
        with self.assertRaises(EventLogFailure):
            reconstruct_sha256(bytes(65_537), 0)

    def test_capture_framing_counter_hash_and_chunk_fail_closed(self):
        data = spec() + event(2, 1, bytes(range(32)), b"payload")
        result = reconstruct_sha256(data, len(spec()))
        lines = [b"mvo.tpm-eventlog.begin version=1",
                 f"mvo.tpm-eventlog.snapshot bytes={len(data)} last-offset={len(spec())} events=2 locality=0".encode()]
        for phase in ('a', 'b'):
            lines.append(f"mvo.tpm-eventlog.counter-{phase} value=8".encode())
            for index in (0, 2, 4, 7):
                lines.append(f"mvo.tpm-eventlog.pcr-{phase} index={index} hex={result['pcrs'][index]}".encode())
        for offset in range(0, len(data), 32):
            lines.append(f"mvo.tpm-eventlog.data offset={offset} hex={data[offset:offset+32].hex()}".encode())
        lines.append(f"mvo.tpm-eventlog.complete bytes={len(data)} chunks={(len(data)+31)//32} events=2 locality=0".encode())
        output = b"\n".join(lines) + b"\n"
        observed, captured = parse_probe_output(output)
        self.assertEqual(captured, data)
        self.assertTrue(observed['eventLogPcrConsistencyVerified'])
        self.assertFalse(observed['windowsTpmHealthVerified'])
        self.assertIsNone(parse_probe_output(b"\n".join(lines[:-1])))
        damaged = [output.replace(b"counter-b value=8", b"counter-b value=9"),
                   output.replace(b"data offset=32", b"data offset=31"),
                   output.replace(b"pcr-b index=0 hex=0", b"pcr-b index=0 hex=1"),
                   output.replace(b"events=2 locality=0", b"events=3 locality=0"),
                   output + b"mvo.tpm-eventlog.begin version=1\n",
                   output + b"mvo.tpm-eventlog.failure stage=test status=error\n"]
        for value in damaged:
            with self.subTest(size=len(value)), self.assertRaises(EventLogFailure):
                parse_probe_output(value)


if __name__ == "__main__":
    unittest.main()
