# SPDX-License-Identifier: Apache-2.0
"""Independent native-C conformance for the generated shared agent wire codec."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "GuestAgent/Protocol/generated/agent_v1.h"
SCHEMA = ROOT / "GuestAgent/Protocol/schema.json"
VECTORS = ROOT / "Tests/AgentProtocolTests/vectors.json"
CONTRACT = {"hello": (1, 64), "helloReply": (2, 68), "healthRequest": (3, 40),
            "healthReply": (4, 52), "rejection": (5, 44)}

DRIVER = r'''
/* SPDX-License-Identifier: Apache-2.0 */
#include <inttypes.h>
#include <stdio.h>
#include "agent_v1.h"
static void hex(const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; ++i) printf("%02x", (unsigned)bytes[i]);
}
int main(void) {
    uint8_t input[MVO_AGENT_MAX_FRAME_BYTES + 1];
    uint8_t output[MVO_AGENT_MAX_FRAME_BYTES];
    mvo_agent_frame frame;
    size_t count = fread(input, 1, sizeof(input), stdin);
    if (ferror(stdin) || getchar() != EOF) return 2;
    size_t length = mvo_agent_frame_length(input, count);
    if (!mvo_agent_decode(input, count, &frame)) {
        printf("{\"decoded\":0,\"length\":%zu}\n", length); return 0;
    }
    /* The encoder must reject every short destination without touching it. */
    for (size_t capacity = 0; capacity < count; ++capacity) {
        memset(output, 0xA5, sizeof(output));
        if (mvo_agent_encode(&frame, output, capacity) != 0) return 3;
        for (size_t i = 0; i < sizeof(output); ++i) if (output[i] != 0xA5) return 4;
    }
    size_t written = mvo_agent_encode(&frame, output, sizeof(output));
    if (written != count) return 5;
    const uint8_t *session, *request;
    uint64_t sequence;
    switch (frame.kind) {
    case 1: session=frame.body.hello.session_id; request=frame.body.hello.request_id; sequence=frame.body.hello.sequence; break;
    case 2: session=frame.body.hello_reply.session_id; request=frame.body.hello_reply.request_id; sequence=frame.body.hello_reply.sequence; break;
    case 3: session=frame.body.health_request.session_id; request=frame.body.health_request.request_id; sequence=frame.body.health_request.sequence; break;
    case 4: session=frame.body.health_reply.session_id; request=frame.body.health_reply.request_id; sequence=frame.body.health_reply.sequence; break;
    case 5: session=frame.body.rejection.session_id; request=frame.body.rejection.request_id; sequence=frame.body.rejection.sequence; break;
    default: return 6;
    }
    printf("{\"decoded\":1,\"length\":%zu,\"minor\":%u,\"kind\":%u,\"frameHex\":\"",
           length, (unsigned)frame.minor, (unsigned)frame.kind);
    hex(output, written);
    printf("\",\"fields\":{\"sessionID\":\""); hex(session,16);
    printf("\",\"sequence\":%" PRIu64 ",\"requestID\":\"", sequence); hex(request,16); printf("\"");
    switch (frame.kind) {
    case 1:
        printf(",\"vmID\":\""); hex(frame.body.hello.vm_id,16);
        printf("\",\"supportedFeatures\":%" PRIu32 ",\"requiredFeatures\":%" PRIu32,
               frame.body.hello.supported_features, frame.body.hello.required_features); break;
    case 2:
        printf(",\"vmID\":\""); hex(frame.body.hello_reply.vm_id,16);
        printf("\",\"selectedFeatures\":%" PRIu32 ",\"agentMajor\":%u,\"agentMinor\":%u,\"agentPatch\":%u,\"architecture\":%u",
               frame.body.hello_reply.selected_features, (unsigned)frame.body.hello_reply.agent_major,
               (unsigned)frame.body.hello_reply.agent_minor, (unsigned)frame.body.hello_reply.agent_patch,
               (unsigned)frame.body.hello_reply.architecture); break;
    case 3: break;
    case 4:
        printf(",\"agentMajor\":%u,\"agentMinor\":%u,\"agentPatch\":%u,\"architecture\":%u,\"status\":%" PRIu32,
               (unsigned)frame.body.health_reply.agent_major, (unsigned)frame.body.health_reply.agent_minor,
               (unsigned)frame.body.health_reply.agent_patch, (unsigned)frame.body.health_reply.architecture,
               frame.body.health_reply.status); break;
    case 5: printf(",\"reason\":%" PRIu32, frame.body.rejection.reason); break;
    default: return 7;
    }
    puts("}}");
    if (mvo_agent_decode(NULL, 0, &frame) || mvo_agent_decode(input, count, NULL) ||
        mvo_agent_encode(NULL, output, sizeof(output)) || mvo_agent_encode(&frame, NULL, sizeof(output)) ||
        mvo_agent_frame_length(NULL, 16)) return 8;
    return 0;
}
'''


class AgentSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("clang")
        if compiler is None:
            raise unittest.SkipTest("Native host clang is required to test the actual C codec")
        cls.temporary = tempfile.TemporaryDirectory(prefix="mvo-agent-c-conformance-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        source = root / "driver.c"
        source.write_text(DRIVER)
        cls.driver = root / "driver"
        compiled = subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                                   "-Wpedantic", "-I", str(HEADER.parent), str(source), "-o", str(cls.driver)],
                                  capture_output=True, timeout=30, check=False)
        if compiled.returncode or compiled.stderr:
            raise AssertionError("C conformance driver failed strict compilation: " + compiled.stderr.decode())
        cls.vectors = json.loads(VECTORS.read_text())

    def observe(self, frame):
        completed = subprocess.run([str(self.driver)], input=frame, capture_output=True,
                                   timeout=3, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
        self.assertEqual(completed.stderr, b"")
        self.assertLess(len(completed.stdout), 2048)
        return json.loads(completed.stdout)

    def test_five_shared_vectors_match_independent_wire_contract_and_C_fields(self):
        self.assertEqual({row["name"] for row in self.vectors}, set(CONTRACT))
        self.assertEqual(len(self.vectors), 5)
        for row in self.vectors:
            with self.subTest(message=row["name"]):
                kind, body_size = CONTRACT[row["name"]]
                frame = bytes.fromhex(row["frameHex"])
                self.assertEqual(frame[:16], struct.pack(">IHHHHI", 0x4D564F41, 1, 0, kind, 0, body_size))
                self.assertEqual(len(frame), 16 + body_size)
                result = self.observe(frame)
                self.assertEqual(result["decoded"], 1)
                self.assertEqual(result["kind"], kind)
                self.assertEqual(result["minor"], 0)
                self.assertEqual(result["length"], len(frame))
                self.assertEqual(result["frameHex"], row["frameHex"])
                self.assertEqual(result["fields"], row["fields"])

    def test_every_short_frame_and_trailing_data_are_rejected(self):
        for row in self.vectors:
            frame = bytes.fromhex(row["frameHex"])
            for length in range(len(frame)):
                with self.subTest(message=row["name"], length=length):
                    self.assertEqual(self.observe(frame[:length])["decoded"], 0)
            for suffix in (b"\0", b"MVOA", frame):
                with self.subTest(message=row["name"], suffix=len(suffix)):
                    self.assertEqual(self.observe(frame + suffix)["decoded"], 0)

    def test_bad_magic_major_reserved_kind_and_declared_length_are_rejected(self):
        mutations = [(0, 4, 0), (4, 2, 0), (4, 2, 2), (8, 2, 0), (8, 2, 6),
                     (8, 2, 65535), (10, 2, 1), (10, 2, 65535),
                     (12, 4, 0), (12, 4, 4096), (12, 4, 0xFFFFFFFF)]
        for row in self.vectors:
            original = bytes.fromhex(row["frameHex"])
            for offset, width, value in mutations:
                frame = bytearray(original)
                frame[offset:offset + width] = value.to_bytes(width, "big")
                with self.subTest(message=row["name"], mutation=(offset, width, value)):
                    result = self.observe(frame)
                    self.assertEqual(result["decoded"], 0)
                    self.assertEqual(result["length"], 0)
            # A known but conflicting message kind cannot reinterpret another body.
            other_kind = 3 if row["name"] != "healthRequest" else 1
            frame = bytearray(original)
            frame[8:10] = other_kind.to_bytes(2, "big")
            self.assertEqual(self.observe(frame)["decoded"], 0)

    def test_full_unsigned_sequence_range_and_known_minor_versions_roundtrip(self):
        for row in self.vectors:
            for sequence in (0, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF):
                for minor in (0, 1, 65535):
                    frame = bytearray.fromhex(row["frameHex"])
                    frame[6:8] = minor.to_bytes(2, "big")
                    frame[32:40] = sequence.to_bytes(8, "big")
                    with self.subTest(message=row["name"], sequence=sequence, minor=minor):
                        result = self.observe(frame)
                        self.assertEqual(result["decoded"], 1)
                        self.assertEqual(result["fields"]["sequence"], sequence)
                        self.assertEqual(result["minor"], minor)
                        self.assertEqual(result["frameHex"], frame.hex())

    def test_frame_size_limit_and_schema_generated_identity(self):
        original = bytes.fromhex(self.vectors[0]["frameHex"])
        for length in (4096, 4097):
            frame = original + bytes(length - len(original))
            self.assertEqual(self.observe(frame)["decoded"], 0)
        schema = json.loads(SCHEMA.read_text())
        self.assertEqual((schema["major"], schema["minor"], schema["maximumFrameBytes"]), (1, 0, 4096))
        self.assertIn(hashlib.sha256(SCHEMA.read_bytes()).hexdigest(), HEADER.read_text())
        checked = subprocess.run([sys.executable, str(SCHEMA.with_name("generate.py")), "--check"],
                                 capture_output=True, timeout=30, check=False)
        self.assertEqual(checked.returncode, 0, checked.stderr.decode(errors="replace"))
        self.assertIn(b"match the schema", checked.stdout)


if __name__ == "__main__":
    unittest.main()
