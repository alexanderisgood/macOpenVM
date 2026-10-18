# SPDX-License-Identifier: Apache-2.0
"""Fixed public-record span/custody checks; no native TLS or crypto execution."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "GuestAgent/Windows/schannel_record_contract.h"
CLANG = Path("/usr/bin/clang")
C_FIXTURE = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "schannel_record_contract.h"
static uint8_t storage[MVO_SCHANNEL_RECORD_LIMIT], packed[MVO_SCHANNEL_RECORD_LIMIT];
static uint8_t incoming[MVO_SCHANNEL_RECORD_LIMIT];
static mvo_schannel_record state;
static void init(bool client) {
    memset(storage, 0xa5, sizeof(storage)); memset(packed, 0xa5, sizeof(packed));
    assert(mvo_record_init(&state, storage, sizeof(storage), 5u, 16u, 16384u, client, true));
}
static uint64_t encrypt(void) {
    uint64_t token = 0u; assert(mvo_record_encrypt_begin(&state, &token));
    assert(!mvo_record_can_release(&state));
    assert(memcmp(storage + state.header, state.fixed, state.fixed_count) == 0);
    return token;
}
static uint64_t decrypt(size_t count) {
    assert(mvo_record_append(&state, incoming, count));
    uint64_t token = 0u; assert(mvo_record_decrypt_begin(&state, &token));
    return token;
}
static enum mvo_schannel_record_outcome accepted_cipher(uint64_t token) {
    return mvo_record_encrypt_return(&state, token, true, MVO_RECORD_OK,
        (mvo_schannel_record_span){storage, 4u},
        (mvo_schannel_record_span){storage + 5u, state.fixed_count},
        (mvo_schannel_record_span){storage + 5u + state.fixed_count, 15u});
}
static void stream_size_overflow_and_scope(void) {
    const size_t bad[] = {MVO_SCHANNEL_RECORD_LIMIT + 1u, SIZE_MAX};
    for (size_t i = 0u; i < sizeof(bad) / sizeof(bad[0]); ++i) {
        assert(!mvo_record_init(&state, storage, bad[i], 5u, 16u, 16384u, true, true));
        assert(!mvo_record_init(&state, storage, sizeof(storage), bad[i], 16u, 16384u, true, true));
        assert(!mvo_record_init(&state, storage, sizeof(storage), 5u, bad[i], 16384u, true, true));
        assert(!mvo_record_init(&state, storage, sizeof(storage), 5u, 16u, bad[i], true, true));
    }
    assert(!mvo_record_init(&state, storage, 1u, 5u, 16u, 16384u, true, true));
    assert(!mvo_record_init(&state, storage, sizeof(storage), 0u, 16u, 16384u, true, true));
    assert(!mvo_record_init(&state, storage, sizeof(storage), 5u, 0u, 16384u, true, true));
    assert(!mvo_record_init(&state, storage, sizeof(storage), 5u, 16u, 1u, true, true));
    assert(!mvo_record_init(&state, storage, sizeof(storage), 5u, 16u, 16384u, true, false));
    assert(!mvo_record_init(&state, (uint8_t *)(uintptr_t)UINTPTR_MAX, 2u, 1u, 1u, 16384u, true, true));
}
static void actual_return_before_ciphertext(void) {
    init(true); uint64_t token = encrypt(); size_t actual = 777u;
    assert(!mvo_record_copy_ciphertext(&state, packed, sizeof(packed), &actual));
    assert(actual == 777u && packed[0] == 0xa5u && !mvo_record_can_release(&state));
    assert(accepted_cipher(token) == MVO_RECORD_REJECTED);
    assert(mvo_record_can_release(&state) && !state.ciphertext_ready);
    init(true); token = encrypt();
    assert(mvo_record_encrypt_return(&state, token, false, MVO_RECORD_OK,
        (mvo_schannel_record_span){storage, 5u}, (mvo_schannel_record_span){storage + 5u, state.fixed_count},
        (mvo_schannel_record_span){storage + 5u + state.fixed_count, 16u}) == MVO_RECORD_REJECTED);
    assert(state.pending && !mvo_record_can_release(&state));
    assert(accepted_cipher(token) == MVO_RECORD_REJECTED && !state.pending);
}
static void exact_order_packs_only_produced_bytes(void) {
    for (unsigned direction = 0u; direction < 2u; ++direction) {
        init(direction == 0u); uint64_t token = encrypt();
        for (size_t i = 0u; i < 5u; ++i) storage[i] = (uint8_t)(10u + i);
        /* Independent byte fixture, explicitly not encryption. */
        for (size_t i = 0u; i < state.fixed_count; ++i) storage[5u + i] = (uint8_t)(i ^ 0xf0u);
        for (size_t i = 0u; i < 16u; ++i) storage[5u + state.fixed_count + i] = (uint8_t)(30u + i);
        assert(accepted_cipher(token) == MVO_RECORD_CIPHERTEXT);
        size_t actual = 0u; assert(mvo_record_copy_ciphertext(&state, packed, sizeof(packed), &actual));
        assert(actual == 4u + state.fixed_count + 15u);
        assert(memcmp(packed, storage, 4u) == 0);
        assert(memcmp(packed + 4u, storage + 5u, state.fixed_count) == 0);
        assert(memcmp(packed + 4u + state.fixed_count, storage + 5u + state.fixed_count, 15u) == 0);
        assert(packed[actual] == 0xa5u);
        assert(!mvo_record_copy_ciphertext(&state, packed, sizeof(packed), &actual));
    }
}
static void malicious_encrypt_spans(void) {
    for (unsigned kind = 0u; kind < 10u; ++kind) {
        init(true); uint64_t token = encrypt();
        mvo_schannel_record_span h = {storage, 5u}, d = {storage + 5u, state.fixed_count},
            t = {storage + 5u + state.fixed_count, 16u};
        switch (kind) {
            case 0: h.bytes = storage + 1u; break;
            case 1: h.count = 6u; break;
            case 2: d.bytes = storage; break;
            case 3: d.count = state.fixed_count + 1u; break;
            case 4: t.bytes = storage + 5u; break;
            case 5: t.count = 17u; break;
            case 6: d.bytes = packed; break;
            case 7: d.bytes = (const uint8_t *)(uintptr_t)UINTPTR_MAX; break;
            case 8: h.count = SIZE_MAX; break;
            case 9: h.bytes = NULL; break;
        }
        assert(mvo_record_encrypt_return(&state, token, true, MVO_RECORD_OK, h, d, t) == MVO_RECORD_REJECTED);
        assert(state.failed && !state.ciphertext_ready && mvo_record_can_release(&state));
    }
}
static void copy_bounds_and_overlap(void) {
    for (unsigned kind = 0u; kind < 5u; ++kind) {
        init(true); uint64_t token = encrypt(); assert(accepted_cipher(token) == MVO_RECORD_CIPHERTEXT);
        uint8_t *destination = packed; size_t capacity = sizeof(packed), actual = 123u;
        if (kind == 0u) destination = storage + 100u;
        if (kind == 1u) capacity = state.serialized_count - 1u;
        if (kind == 2u) capacity = SIZE_MAX;
        if (kind == 3u) destination = (uint8_t *)(uintptr_t)UINTPTR_MAX;
        if (kind == 4u) destination = NULL;
        assert(!mvo_record_copy_ciphertext(&state, destination, capacity, &actual));
        assert(actual == 123u && packed[0] == 0xa5u);
    }
}
static void incomplete_preserves_and_requires_new_fragment(void) {
    memset(incoming, 0x62, sizeof(incoming));
    for (size_t split = 1u; split < 40u; ++split) {
        init(true); uint64_t token = decrypt(split);
        assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_INCOMPLETE,
            (mvo_schannel_record_span){NULL, 0u}, 0u, 1u) == MVO_RECORD_NEED_INPUT);
        assert(state.input_count == split && memcmp(storage, incoming, split) == 0);
        assert(!mvo_record_decrypt_begin(&state, &token));
        init(true); token = decrypt(split);
        assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_INCOMPLETE,
            (mvo_schannel_record_span){NULL, 0u}, 0u, 1u) == MVO_RECORD_NEED_INPUT);
        assert(mvo_record_append(&state, incoming, 50u));
        assert(mvo_record_decrypt_begin(&state, &token));
        memcpy(storage + 3u, state.fixed, state.fixed_count);
        assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
            (mvo_schannel_record_span){storage + 3u, state.fixed_count}, 2u, 0u) == MVO_RECORD_PLAINTEXT);
    }
}
static void empty_data_consumes_control_and_preserves_extra(void) {
    for (size_t i = 0u; i < sizeof(incoming); ++i) incoming[i] = (uint8_t)i;
    init(true); uint64_t token = decrypt(80u);
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
        (mvo_schannel_record_span){NULL, 0u}, 20u, 0u) == MVO_RECORD_CONTROL);
    assert(state.input_count == 20u && memcmp(storage, incoming + 60u, 20u) == 0 && !state.plaintext_done);
    assert(mvo_record_decrypt_begin(&state, &token));
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
        (mvo_schannel_record_span){NULL, 0u}, 20u, 0u) == MVO_RECORD_REJECTED);
}
static void exact_public_payload_both_directions(void) {
    for (unsigned direction = 0u; direction < 2u; ++direction) {
        init(direction == 0u); uint64_t token = decrypt(100u);
        memcpy(storage + 5u, state.fixed, state.fixed_count);
        assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
            (mvo_schannel_record_span){storage + 5u, state.fixed_count}, 9u, 0u) == MVO_RECORD_PLAINTEXT);
        assert(state.plaintext_done && state.extra_count == 9u);
        assert(!mvo_record_decrypt_begin(&state, &token));
        assert(!mvo_record_append(&state, incoming, 1u));
    }
}
static void corrupted_or_unbounded_plaintext_rejected(void) {
    init(true); size_t count = state.fixed_count;
    for (size_t corrupt = 0u; corrupt < count; ++corrupt) {
        init(true); uint64_t token = decrypt(100u);
        memcpy(storage + 5u, state.fixed, count); storage[5u + corrupt] ^= 0xffu;
        assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
            (mvo_schannel_record_span){storage + 5u, count}, 0u, 0u) == MVO_RECORD_REJECTED);
        assert(!state.plaintext_done);
    }
    for (unsigned kind = 0u; kind < 7u; ++kind) {
        init(true); uint64_t token = decrypt(100u);
        memcpy(storage + 5u, state.fixed, count);
        mvo_schannel_record_span data = {storage + 5u, count};
        size_t extra = 0u;
        if (kind == 0u) data.count = count + 1u;
        if (kind == 1u) data.count = SIZE_MAX;
        if (kind == 2u) data.bytes = incoming;
        if (kind == 3u) data.bytes = (const uint8_t *)(uintptr_t)UINTPTR_MAX;
        if (kind == 4u) data.bytes = NULL;
        if (kind == 5u) extra = 99u;
        if (kind == 6u) extra = SIZE_MAX;
        assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK, data, extra, 0u) == MVO_RECORD_REJECTED);
        assert(!state.plaintext_done);
    }
}
static void closed_nonplaintext_statuses(void) {
    const enum mvo_schannel_record_status statuses[] = {MVO_RECORD_RENEGOTIATE, MVO_RECORD_EXPIRED,
        MVO_RECORD_FAILURE, (enum mvo_schannel_record_status)0, (enum mvo_schannel_record_status)99};
    for (size_t i = 0u; i < sizeof(statuses) / sizeof(statuses[0]); ++i) {
        init(true); uint64_t token = decrypt(100u);
        enum mvo_schannel_record_outcome expected = i == 0u ? MVO_RECORD_REHANDSHAKE : i == 1u ? MVO_RECORD_CLOSED : MVO_RECORD_REJECTED;
        assert(mvo_record_decrypt_return(&state, token, true, statuses[i],
            (mvo_schannel_record_span){NULL, 0u}, 0u, 0u) == expected);
        assert(state.input_count == 100u && !state.plaintext_done && state.failed);
        assert(!mvo_record_decrypt_begin(&state, &token));
        assert(!mvo_record_encrypt_begin(&state, &token));
    }
    init(true); uint64_t token = decrypt(100u);
    memcpy(storage + 5u, state.fixed, state.fixed_count);
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_RENEGOTIATE,
        (mvo_schannel_record_span){storage + 5u, state.fixed_count}, 0u, 0u) == MVO_RECORD_REJECTED);
    assert(!state.plaintext_done);
}
static void missing_and_extra_counts(void) {
    init(true); uint64_t token = decrypt(10u);
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_INCOMPLETE,
        (mvo_schannel_record_span){NULL, 0u}, 0u, SIZE_MAX) == MVO_RECORD_REJECTED);
    init(true); token = decrypt(sizeof(storage));
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_INCOMPLETE,
        (mvo_schannel_record_span){NULL, 0u}, 0u, 1u) == MVO_RECORD_REJECTED);
    init(true); token = decrypt(10u);
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_INCOMPLETE,
        (mvo_schannel_record_span){NULL, 0u}, 1u, 0u) == MVO_RECORD_REJECTED);
    init(true); token = decrypt(10u);
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
        (mvo_schannel_record_span){NULL, 0u}, 10u, 0u) == MVO_RECORD_REJECTED);
}
static void cancellation_and_stale_return_custody(void) {
    for (unsigned direction = 0u; direction < 2u; ++direction) {
        init(true); uint64_t token = direction == 0u ? encrypt() : decrypt(100u);
        mvo_record_cancel(&state); assert(!mvo_record_can_release(&state));
        if (direction == 0u) assert(accepted_cipher(token) == MVO_RECORD_REJECTED);
        else assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
            (mvo_schannel_record_span){NULL, 0u}, 0u, 0u) == MVO_RECORD_REJECTED);
        assert(mvo_record_can_release(&state) && !state.ciphertext_ready && !state.plaintext_done);
    }
    init(true); uint64_t token = decrypt(100u);
    assert(mvo_record_decrypt_return(&state, token + 1u, true, MVO_RECORD_OK,
        (mvo_schannel_record_span){NULL, 0u}, 0u, 0u) == MVO_RECORD_REJECTED);
    assert(state.pending && !mvo_record_can_release(&state));
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_FAILURE,
        (mvo_schannel_record_span){NULL, 0u}, 0u, 0u) == MVO_RECORD_REJECTED);
    assert(mvo_record_can_release(&state));
}
static void null_bounds_and_overflow_tokens(void) {
    assert(!mvo_record_init(NULL, storage, sizeof(storage), 5u, 16u, 16384u, true, true));
    assert(!mvo_record_encrypt_begin(NULL, &(uint64_t){0u}));
    assert(!mvo_record_decrypt_begin(NULL, &(uint64_t){0u}));
    assert(!mvo_record_append(NULL, incoming, 1u));
    assert(!mvo_record_copy_ciphertext(NULL, packed, sizeof(packed), &(size_t){0u}));
    assert(!mvo_record_can_release(NULL)); mvo_record_cancel(NULL);
    init(true); state.token = UINT64_MAX;
    assert(!mvo_record_encrypt_begin(&state, &(uint64_t){0u}));
    init(true); assert(!mvo_record_append(&state, incoming, SIZE_MAX));
    init(true); assert(!mvo_record_append(&state, NULL, 1u));
    init(true); assert(!mvo_record_append(&state, incoming, 0u));
    init(true); state.input_count = SIZE_MAX;
    assert(!mvo_record_decrypt_begin(&state, &(uint64_t){0u}));
    init(true); assert(!mvo_record_span(&state, (mvo_schannel_record_span){storage, 1u}, NULL));
    init(true); state.header = SIZE_MAX; assert(!mvo_record_encrypt_begin(&state, &(uint64_t){0u}));
    init(true); state.fixed_count = SIZE_MAX; assert(!mvo_record_encrypt_begin(&state, &(uint64_t){0u}));
    init(true); state.fixed = NULL; assert(!mvo_record_encrypt_begin(&state, &(uint64_t){0u}));
}
static void opposite_mode_is_never_admitted(void) {
    init(true); uint64_t token = decrypt(10u);
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_INCOMPLETE,
        (mvo_schannel_record_span){NULL, 0u}, 0u, 1u) == MVO_RECORD_NEED_INPUT);
    uint8_t preserved[10]; memcpy(preserved, storage, sizeof(preserved));
    assert(!mvo_record_encrypt_begin(&state, &token));
    assert(memcmp(storage, preserved, sizeof(preserved)) == 0);
    init(true); token = encrypt(); assert(accepted_cipher(token) == MVO_RECORD_CIPHERTEXT);
    assert(!mvo_record_append(&state, incoming, 1u));
    assert(!mvo_record_decrypt_begin(&state, &token));
    init(true); token = encrypt(); assert(accepted_cipher(token) == MVO_RECORD_CIPHERTEXT);
    size_t actual = 0u; assert(mvo_record_copy_ciphertext(&state, packed, sizeof(packed), &actual));
    assert(!mvo_record_decrypt_begin(&state, &token));
    init(true); token = decrypt(100u);
    memcpy(storage + 5u, state.fixed, state.fixed_count);
    assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
        (mvo_schannel_record_span){storage + 5u, state.fixed_count}, 0u, 0u) == MVO_RECORD_PLAINTEXT);
    assert(!mvo_record_encrypt_begin(&state, &token));
}
static void control_steps_are_bounded(void) {
    init(true);
    for (unsigned i = 0u; i < MVO_SCHANNEL_RECORD_STEPS; ++i) {
        uint64_t token = decrypt(1u);
        assert(mvo_record_decrypt_return(&state, token, true, MVO_RECORD_OK,
            (mvo_schannel_record_span){NULL, 0u}, 0u, 0u) == MVO_RECORD_CONTROL);
    }
    assert(state.steps == MVO_SCHANNEL_RECORD_STEPS);
    assert(mvo_record_append(&state, incoming, 1u));
    uint64_t token = 123u;
    assert(!mvo_record_decrypt_begin(&state, &token));
    assert(token == 123u && state.failed && !state.pending);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    switch (strtoul(argv[1], NULL, 10)) {
        case 0: stream_size_overflow_and_scope(); break;
        case 1: actual_return_before_ciphertext(); break;
        case 2: exact_order_packs_only_produced_bytes(); break;
        case 3: malicious_encrypt_spans(); break;
        case 4: copy_bounds_and_overlap(); break;
        case 5: incomplete_preserves_and_requires_new_fragment(); break;
        case 6: empty_data_consumes_control_and_preserves_extra(); break;
        case 7: exact_public_payload_both_directions(); break;
        case 8: corrupted_or_unbounded_plaintext_rejected(); break;
        case 9: closed_nonplaintext_statuses(); break;
        case 10: missing_and_extra_counts(); break;
        case 11: cancellation_and_stale_return_custody(); break;
        case 12: null_bounds_and_overflow_tokens(); break;
        case 13: opposite_mode_is_never_admitted(); break;
        case 14: control_steps_are_bounded(); break;
        default: return 99;
    }
    return 0;
}
'''


class SchannelRecordContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CLANG.is_file():
            raise unittest.SkipTest("portable contract needs the system C compiler")
        cls.before_hash = hashlib.sha256(HEADER.read_bytes()).hexdigest()
        cls.temp = tempfile.TemporaryDirectory(prefix="mvo-schannel-record-")
        directory = Path(cls.temp.name)
        source = directory / "fixture.c"
        source.write_text(C_FIXTURE)
        cls.binaries = []
        for name, extra in [("strict", []), ("sanitized", ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"])]:
            binary = directory / name
            command = [str(CLANG), "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic", "-Wconversion",
                       "-Wsign-conversion", "-O1", *extra, "-I", str(HEADER.parent), str(source), "-o", str(binary)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if compiled.returncode != 0 or compiled.stderr:
                raise AssertionError(f"{name} compile failed: {compiled.returncode}\n{compiled.stderr}")
            cls.binaries.append(binary)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
        if hashlib.sha256(HEADER.read_bytes()).hexdigest() != cls.before_hash:
            raise AssertionError("header changed during portable checks")

    def check_case(self, case):
        for binary in self.binaries:
            with self.subTest(build=binary.name):
                result = subprocess.run([str(binary), str(case)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")

    def test_stream_bounds_scope(self): self.check_case(0)
    def test_actual_return_gate(self): self.check_case(1)
    def test_exact_produced_order(self): self.check_case(2)
    def test_malicious_encrypt_spans(self): self.check_case(3)
    def test_copy_bounds_overlap(self): self.check_case(4)
    def test_fragmented_incomplete(self): self.check_case(5)
    def test_empty_control_extra(self): self.check_case(6)
    def test_exact_fixed_records(self): self.check_case(7)
    def test_malicious_data(self): self.check_case(8)
    def test_closed_statuses(self): self.check_case(9)
    def test_missing_extra_bounds(self): self.check_case(10)
    def test_cancel_stale_custody(self): self.check_case(11)
    def test_null_overflow(self): self.check_case(12)
    def test_opposite_mode(self): self.check_case(13)
    def test_control_step_limit(self): self.check_case(14)


if __name__ == "__main__":
    unittest.main(verbosity=2)
