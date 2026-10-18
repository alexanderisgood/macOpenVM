#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded SHA-256 event-log consistency for the pinned, fresh SRTM EFI lab.

This decoder cannot establish firmware authenticity, Windows health or enforcement.
It handles the TCG2 main log, never concatenated final-event-table records.
"""

import hashlib
import re
import struct

MAX_LOG = 65_536
MAX_EVENTS = 1024
ALGORITHM_SIZES = {0x0004: 20, 0x000B: 32, 0x000C: 48, 0x000D: 64, 0x0012: 32}
SELECTED_PCRS = (0, 2, 4, 7)
EV_NO_ACTION = 3
EV_EFI_HCRTM_EVENT = 0x80000010


class EventLogFailure(ValueError):
    pass


class Reader:
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def take(self, length):
        if length < 0 or length > len(self.data) - self.offset:
            raise EventLogFailure("Truncated event-log field")
        value = self.data[self.offset:self.offset + length]
        self.offset += length
        return value

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]


def reconstruct_sha256(data, last_offset):
    """Return the actual parsed span/count/locality and accumulated selected PCRs."""
    if not isinstance(data, bytes) or not 32 <= len(data) <= MAX_LOG:
        raise EventLogFailure("Event log exceeds its pinned allocation bounds")
    if type(last_offset) is not int or not 0 <= last_offset < len(data):
        raise EventLogFailure("Last entry is outside the supplied used span")
    reader = Reader(data)
    if reader.u32() != 0 or reader.u32() != EV_NO_ACTION or reader.take(20) != bytes(20):
        raise EventLogFailure("Missing legacy SpecID header")
    spec = Reader(reader.take(reader.u32()))
    if spec.take(16) != b"Spec ID Event03\0":
        raise EventLogFailure("Unsupported SpecID signature")
    platform_class = spec.u32()
    minor, major, errata, uintn_size = spec.take(4)
    if platform_class != 0 or (minor, major, uintn_size) != (0, 2, 2):
        raise EventLogFailure("Unsupported SpecID platform/version/word size")
    count = spec.u32()
    if not 1 <= count <= len(ALGORITHM_SIZES):
        raise EventLogFailure("Algorithm count exceeds the supported subset")
    algorithms = {}
    for _ in range(count):
        algorithm, size = spec.u16(), spec.u16()
        if algorithm in algorithms or ALGORITHM_SIZES.get(algorithm) != size:
            raise EventLogFailure("Unknown, duplicate or incorrectly sized digest algorithm")
        algorithms[algorithm] = size
    if 0x000B not in algorithms:
        raise EventLogFailure("SHA-256 is absent from the event-log algorithm list")
    vendor_length = spec.take(1)[0]
    spec.take(vendor_length)
    if spec.offset != len(spec.data):
        raise EventLogFailure("Trailing bytes in the SpecID payload")

    pcrs = {index: bytes(32) for index in SELECTED_PCRS}
    events = 1
    last_start = 0
    locality = 0
    locality_seen = False
    pcr0_extended = False
    while reader.offset < len(data):
        last_start = reader.offset
        if last_start > last_offset or events >= MAX_EVENTS:
            raise EventLogFailure("Last entry or event count is inconsistent")
        index, event_type, digest_count = reader.u32(), reader.u32(), reader.u32()
        if index >= 24 or digest_count != len(algorithms):
            raise EventLogFailure("Unsupported PCR index or incomplete digest set")
        digests = {}
        for _ in range(digest_count):
            algorithm = reader.u16()
            if algorithm not in algorithms or algorithm in digests:
                raise EventLogFailure("Unknown or duplicate event digest")
            digests[algorithm] = reader.take(algorithms[algorithm])
        event_data = reader.take(reader.u32())
        if event_type == EV_EFI_HCRTM_EVENT:
            raise EventLogFailure("HCRTM is outside the fresh SRTM fixture subset")
        if event_type == EV_NO_ACTION:
            if any(any(digest) for digest in digests.values()):
                raise EventLogFailure("No-action event contains a nonzero digest")
            if event_data.startswith(b"StartupLocality"):
                if (index != 0 or len(event_data) != 17 or event_data[:16] != b"StartupLocality\0" or
                        locality_seen or pcr0_extended or event_data[16] not in (0, 3)):
                    raise EventLogFailure("Unsupported or misplaced StartupLocality event")
                locality = event_data[16]
                pcrs[0] = bytes(31) + bytes([locality])
                locality_seen = True
        elif index in pcrs:
            pcrs[index] = hashlib.sha256(pcrs[index] + digests[0x000B]).digest()
            if index == 0:
                pcr0_extended = True
        events += 1
    if last_start != last_offset:
        raise EventLogFailure("Last-entry pointer is not the start of the final parsed entry")
    return {"bytes": len(data), "lastOffset": last_start, "events": events,
            "locality": locality, "specErrata": errata,
            "pcrs": {index: value.hex() for index, value in pcrs.items()}}


def parse_probe_output(clean):
    """Parse unique canonical capture markers and independently check both PCR sets."""
    if not isinstance(clean, bytes) or len(clean) > 2_097_152:
        raise EventLogFailure("Capture output exceeds its bound")
    lines = [line for line in clean.splitlines() if line.startswith(b"mvo.tpm-eventlog.")]
    if len(lines) > 2061 or any(len(line) > 160 for line in lines):
        raise EventLogFailure("Excessive event-log markers")
    if any(line.startswith(b"mvo.tpm-eventlog.failure") for line in lines):
        raise EventLogFailure("The read-only capture application reported a failure")
    if not any(line.startswith(b"mvo.tpm-eventlog.complete") for line in lines):
        return None
    if len(lines) < 14 or lines[0] != b"mvo.tpm-eventlog.begin version=1":
        raise EventLogFailure("Incomplete capture framing")
    snapshot = re.fullmatch(rb"mvo\.tpm-eventlog\.snapshot bytes=([0-9]{1,5}) last-offset=([0-9]{1,5}) "
                            rb"events=([0-9]{1,4}) locality=([03])", lines[1])
    completion = re.fullmatch(rb"mvo\.tpm-eventlog\.complete bytes=([0-9]{1,5}) chunks=([0-9]{1,4}) "
                              rb"events=([0-9]{1,4}) locality=([03])", lines[-1])
    if snapshot is None or completion is None:
        raise EventLogFailure("Invalid capture metadata")
    size, last_offset, events, locality = map(int, snapshot.groups())
    final_size, chunks, final_events, final_locality = map(int, completion.groups())
    if (not 32 <= size <= MAX_LOG or not 1 <= events <= MAX_EVENTS or
            (size, events, locality) != (final_size, final_events, final_locality) or
            chunks != (size + 31) // 32 or len(lines) != 13 + chunks):
        raise EventLogFailure("Capture metadata/count disagreement")
    position = 2
    counters = []
    snapshots = []
    for phase in (b"a", b"b"):
        counter = re.fullmatch(rb"mvo\.tpm-eventlog\.counter-" + phase + rb" value=([0-9]{1,10})", lines[position])
        if counter is None or int(counter[1]) > 0xFFFFFFFF:
            raise EventLogFailure("Invalid PCR update counter")
        counters.append(int(counter[1]))
        position += 1
        values = {}
        for index in SELECTED_PCRS:
            item = re.fullmatch(rb"mvo\.tpm-eventlog\.pcr-" + phase + rb" index=" + str(index).encode() +
                                rb" hex=([0-9a-f]{64})", lines[position])
            if item is None:
                raise EventLogFailure("Invalid or reordered PCR observation")
            values[index] = item[1].decode("ascii")
            position += 1
        snapshots.append(values)
    if counters[0] != counters[1] or snapshots[0] != snapshots[1]:
        raise EventLogFailure("PCR counter or values changed during capture")
    data = bytearray()
    for chunk_index in range(chunks):
        item = re.fullmatch(rb"mvo\.tpm-eventlog\.data offset=([0-9]{1,5}) hex=([0-9a-f]{2,64})", lines[position])
        if item is None or int(item[1]) != len(data) or len(item[2]) % 2:
            raise EventLogFailure("Invalid event-log chunk offset or encoding")
        value = bytes.fromhex(item[2].decode("ascii"))
        expected = min(32, size - len(data))
        if len(value) != expected or (chunk_index + 1 < chunks and len(value) != 32):
            raise EventLogFailure("Invalid event-log chunk length")
        data.extend(value)
        position += 1
    if len(data) != size or position != len(lines) - 1:
        raise EventLogFailure("Incomplete or extra event-log bytes")
    used = bytes(data)
    reconstructed = reconstruct_sha256(used, last_offset)
    if ((reconstructed["events"], reconstructed["locality"]) != (events, locality) or
            reconstructed["pcrs"] != snapshots[0]):
        raise EventLogFailure("Logged SHA-256 accumulation differs from actual TPM values or metadata")
    observation = {key: value for key, value in reconstructed.items() if key != "pcrs"}
    observation.update({"pcrs": {str(key): value for key, value in snapshots[0].items()},
                        "pcrUpdateCounter": counters[0], "eventLogSHA256": hashlib.sha256(used).hexdigest(),
                        "eventLogPcrConsistencyVerified": True, "windowsTpmHealthVerified": False,
                        "platformMeasurementAuthenticityVerified": False})
    return observation, used
