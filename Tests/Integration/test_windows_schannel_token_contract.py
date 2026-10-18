# SPDX-License-Identifier: Apache-2.0
"""C-backed token/custody checks. No SSPI, TLS, device, credential or VM action."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "GuestAgent/Windows/schannel_token_contract.h"
CLANG = Path("/usr/bin/clang")

C_FIXTURE = r'''
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "schannel_token_contract.h"

static const uint8_t bytes[] = {1, 2, 3, 4, 5, 6, 7, 8};
static uint64_t begin(mvo_schannel_tokens *state) {
    uint64_t token = 0u;
    assert(mvo_schannel_begin(state, &token) && token != 0u);
    assert(state->step_pending && !mvo_schannel_plaintext_allowed(state));
    return token;
}
static void append(mvo_schannel_tokens *state, size_t count) {
    assert(count <= sizeof(bytes) && mvo_schannel_append(state, bytes, count));
}
static void final(mvo_schannel_tokens *state, const uint8_t *out, size_t count) {
    mvo_schannel_init(state); append(state, 1u);
    uint64_t token = begin(state);
    assert(mvo_schannel_observe(state, token, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, out, count));
    assert(state->context_complete && !mvo_schannel_plaintext_allowed(state));
}
static void drain(mvo_schannel_tokens *state, size_t chunk) {
    while (state->output_offset < state->output_count) {
        size_t remaining = state->output_count - state->output_offset;
        size_t requested = remaining < chunk ? remaining : chunk;
        uint64_t token = 0u;
        assert(mvo_schannel_begin_write(state, requested, &token));
        assert(!mvo_schannel_can_release_output(state));
        size_t offset = state->output_offset;
        /* An observation of a pending write never consumes a reported count. */
        assert(mvo_schannel_observe_write(state, token, false, false, SIZE_MAX) == MVO_SCHANNEL_WRITE_WAIT);
        assert(state->output_offset == offset);
        assert(mvo_schannel_observe_write(state, token, true, false, requested) == MVO_SCHANNEL_WRITE_ADVANCED);
    }
    assert(mvo_schannel_can_release_output(state));
    assert(mvo_schannel_output_released(state));
    assert(!state->output_owned && state->output == NULL);
}
static void segmented_incomplete_preserves_bytes(void) {
    for (size_t split = 1u; split < sizeof(bytes); ++split) {
        mvo_schannel_tokens state;
        mvo_schannel_init(&state);
        assert(mvo_schannel_append(&state, bytes, split));
        uint64_t token = begin(&state);
        assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_INCOMPLETE, NULL, 0u, NULL, 0u));
        assert(state.input_count == split && state.need_input);
        assert(memcmp(state.input, bytes, split) == 0);
        assert(mvo_schannel_append(&state, bytes + split, sizeof(bytes) - split));
        assert(state.input_count == sizeof(bytes) && memcmp(state.input, bytes, sizeof(bytes)) == 0);
        token = begin(&state);
        assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_CONTINUE,
            state.input + 5u, 3u, bytes, 2u));
        assert(state.input_count == 3u && memcmp(state.input, bytes + 5u, 3u) == 0);
        drain(&state, 1u);
        token = begin(&state);
        assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, NULL, 0u));
        assert(state.input_count == 0u);
    }
}
static void incomplete_without_new_bytes_rejected(void) {
    mvo_schannel_tokens state;
    mvo_schannel_init(&state); append(&state, 1u);
    uint64_t token = begin(&state);
    assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_INCOMPLETE, NULL, 0u, NULL, 0u));
    uint64_t unchanged = 123u;
    assert(!mvo_schannel_begin(&state, &unchanged));
    assert(unchanged == 123u && state.failed && state.input_count == 1u);
}
static void coalesced_extra_and_final_output(void) {
    for (size_t tail = 1u; tail < sizeof(bytes); ++tail) {
        mvo_schannel_tokens state;
        mvo_schannel_init(&state); append(&state, sizeof(bytes));
        uint64_t token = begin(&state);
        assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_CONTINUE,
            state.input + sizeof(bytes) - tail, tail, NULL, 0u));
        assert(state.input_count == tail && memcmp(state.input, bytes + sizeof(bytes) - tail, tail) == 0);
        token = begin(&state);
        assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_COMPLETE,
            state.input + tail - 1u, 1u, bytes, sizeof(bytes)));
        assert(state.input_count == 1u && state.input[0] == bytes[sizeof(bytes) - 1u]);
        assert(!mvo_schannel_can_release_output(&state));
        drain(&state, tail);
        assert(mvo_schannel_verify_context(&state, true, true, true, true));
        assert(!mvo_schannel_plaintext_allowed(&state));
        assert(mvo_schannel_verify_peer(&state, true));
        assert(mvo_schannel_plaintext_allowed(&state));
        /* Retained EXTRA is ciphertext for the native record adapter, not a
         * generated plaintext frame or evidence of authenticated content. */
        assert(state.input_count == 1u);
    }
}
static void extra_pointer_and_length_bounds(void) {
    for (unsigned kind = 0u; kind < 8u; ++kind) {
        mvo_schannel_tokens state;
        mvo_schannel_init(&state); append(&state, sizeof(bytes));
        uint64_t token = begin(&state);
        const uint8_t *extra = state.input + 4u;
        size_t count = 4u;
        switch (kind) {
            case 0: extra = bytes + 4u; break; /* Correct bytes, unrelated allocation. */
            case 1: extra = NULL; break;
            case 2: extra = state.input; break;
            case 3: extra = state.input + 5u; break;
            case 4: count = sizeof(bytes) + 1u; break;
            case 5: count = SIZE_MAX; break;
            case 6: extra = (const uint8_t *)(uintptr_t)UINTPTR_MAX; break;
            case 7: count = 0u; break; /* Non-null zero span is not canonical. */
        }
        assert(!mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_CONTINUE,
            extra, count, NULL, 0u));
        assert(state.failed && state.input_count == sizeof(bytes) && memcmp(state.input, bytes, sizeof(bytes)) == 0);
    }
}
static void accumulator_bounds_and_pending_append(void) {
    static uint8_t full[MVO_SCHANNEL_TOKEN_LIMIT];
    for (size_t i = 0u; i < sizeof(full); ++i) full[i] = (uint8_t)i;
    mvo_schannel_tokens state;
    mvo_schannel_init(&state);
    assert(mvo_schannel_append(&state, full, sizeof(full)));
    assert(memcmp(state.input, full, sizeof(full)) == 0);
    assert(!mvo_schannel_append(&state, bytes, 1u));
    assert(state.input_count == sizeof(full));
    const size_t invalid[] = {0u, MVO_SCHANNEL_TOKEN_LIMIT + 1u, SIZE_MAX};
    for (size_t i = 0u; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        mvo_schannel_init(&state);
        assert(!mvo_schannel_append(&state, bytes, invalid[i]));
        assert(state.input_count == 0u && state.failed);
    }
    mvo_schannel_init(&state); assert(!mvo_schannel_append(&state, NULL, 1u));
    mvo_schannel_init(&state); append(&state, 1u); (void)begin(&state);
    assert(!mvo_schannel_append(&state, bytes, 1u));
    assert(state.input_count == 1u && state.step_pending);
}
static void no_progress_and_step_budget(void) {
    mvo_schannel_tokens state;
    mvo_schannel_init(&state); append(&state, sizeof(bytes));
    uint64_t token = begin(&state);
    assert(!mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_CONTINUE,
        state.input, sizeof(bytes), NULL, 0u));
    assert(state.failed);
    mvo_schannel_init(&state); append(&state, 1u);
    /* Even fresh input and actual token delivery cannot extend the fixed budget. */
    for (unsigned i = 0u; i < MVO_SCHANNEL_STEP_LIMIT; ++i) {
        token = begin(&state);
        assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_CONTINUE,
            NULL, 0u, bytes, 1u));
        drain(&state, 1u);
        append(&state, 1u);
    }
    token = 0u;
    assert(!mvo_schannel_begin(&state, &token));
    assert(state.steps == MVO_SCHANNEL_STEP_LIMIT && token == 0u);
    mvo_schannel_init(&state); append(&state, 1u); state.step_token = UINT64_MAX;
    assert(!mvo_schannel_begin(&state, &token));
}
static void output_does_not_authorize_input_replay(void) {
    mvo_schannel_tokens state;
    mvo_schannel_init(&state); append(&state, 1u);
    uint64_t token = begin(&state);
    assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_CONTINUE,
        state.input, 1u, bytes, 1u));
    drain(&state, 1u);
    assert(state.need_input && state.input_count == 1u);
    assert(!mvo_schannel_begin(&state, &token));
    mvo_schannel_init(&state); append(&state, 1u); token = begin(&state);
    assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_CONTINUE,
        state.input, 1u, bytes, 1u));
    drain(&state, 1u);
    append(&state, 1u); token = begin(&state);
    assert(mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_COMPLETE,
        NULL, 0u, NULL, 0u));
}
static void stale_steps_and_closed_statuses(void) {
    mvo_schannel_tokens state;
    mvo_schannel_init(&state); append(&state, 1u);
    uint64_t token = begin(&state);
    assert(!mvo_schannel_observe(&state, token + 1u, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, NULL, 0u));
    assert(state.step_pending); /* Stale return cannot release actual call custody. */
    assert(!mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, bytes, 1u));
    assert(!state.step_pending && state.output_owned && mvo_schannel_can_release_output(&state));
    assert(mvo_schannel_output_released(&state));
    const enum mvo_schannel_status statuses[] = {MVO_SCHANNEL_FAILURE, (enum mvo_schannel_status)0, (enum mvo_schannel_status)99};
    for (size_t i = 0u; i < sizeof(statuses) / sizeof(statuses[0]); ++i) {
        mvo_schannel_init(&state); append(&state, 1u); token = begin(&state);
        assert(!mvo_schannel_observe(&state, token, true, statuses[i], NULL, 0u, bytes, 1u));
        assert(mvo_schannel_can_release_output(&state));
        assert(mvo_schannel_output_released(&state));
    }
    mvo_schannel_init(&state); append(&state, 1u); token = begin(&state);
    assert(!mvo_schannel_observe(&state, token, false, MVO_SCHANNEL_COMPLETE, NULL, 0u, NULL, 0u));
    assert(state.step_pending);
}
static void invalid_output_retains_cleanup(void) {
    for (unsigned kind = 0u; kind < 4u; ++kind) {
        mvo_schannel_tokens state;
        mvo_schannel_init(&state); append(&state, 1u);
        uint64_t token = begin(&state);
        const uint8_t *output = bytes;
        size_t count = 1u;
        if (kind == 0u) count = 0u;
        if (kind == 1u) count = MVO_SCHANNEL_TOKEN_LIMIT + 1u;
        if (kind == 2u) count = SIZE_MAX;
        if (kind == 3u) output = (const uint8_t *)(uintptr_t)UINTPTR_MAX;
        assert(!mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, output, count));
        assert(state.output_owned && state.output == output && mvo_schannel_can_release_output(&state));
        assert(mvo_schannel_output_released(&state));
    }
    mvo_schannel_tokens state;
    mvo_schannel_init(&state); append(&state, 1u);
    uint64_t token = begin(&state);
    assert(!mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, NULL, 1u));
    assert(!state.output_owned);
    mvo_schannel_init(&state); append(&state, 1u); token = begin(&state);
    assert(!mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_INCOMPLETE, NULL, 0u, bytes, 1u));
    assert(mvo_schannel_can_release_output(&state));
}
static void final_token_custody_and_partial_writes(void) {
    for (size_t actual = 1u; actual <= sizeof(bytes); ++actual) {
        mvo_schannel_tokens state;
        final(&state, bytes, sizeof(bytes));
        uint64_t token = 0u;
        assert(mvo_schannel_begin_write(&state, sizeof(bytes), &token));
        assert(mvo_schannel_observe_write(&state, token, true, false, actual) == MVO_SCHANNEL_WRITE_ADVANCED);
        assert(state.output_offset == actual && !mvo_schannel_plaintext_allowed(&state));
        if (actual < sizeof(bytes)) { assert(!mvo_schannel_can_release_output(&state)); drain(&state, 1u); }
        else { assert(mvo_schannel_can_release_output(&state)); assert(mvo_schannel_output_released(&state)); }
        assert(mvo_schannel_verify_context(&state, true, true, true, true));
        assert(mvo_schannel_verify_peer(&state, true));
        assert(mvo_schannel_plaintext_allowed(&state));
    }
    mvo_schannel_tokens state;
    final(&state, bytes, 1u);
    assert(!mvo_schannel_output_released(&state));
    assert(state.failed && state.output_owned && state.output == bytes);
}
static void cancellation_and_stale_write_custody(void) {
    for (unsigned kind = 0u; kind < 4u; ++kind) {
        mvo_schannel_tokens state;
        final(&state, bytes, sizeof(bytes));
        uint64_t token = 0u;
        assert(mvo_schannel_begin_write(&state, sizeof(bytes), &token));
        if (kind == 0u) mvo_schannel_cancel(&state);
        if (kind == 1u) assert(mvo_schannel_observe_write(&state, token + 1u, true, true, sizeof(bytes)) == MVO_SCHANNEL_WRITE_REJECTED);
        if (kind == 2u) assert(!mvo_schannel_output_released(&state));
        if (kind == 3u) assert(!mvo_schannel_begin_write(&state, 1u, &(uint64_t){0u}));
        assert(state.write_pending && !mvo_schannel_can_release_output(&state));
        assert(mvo_schannel_observe_write(&state, token, false, false, 0u) == MVO_SCHANNEL_WRITE_WAIT);
        assert(mvo_schannel_observe_write(&state, token, true, true, sizeof(bytes)) == MVO_SCHANNEL_WRITE_REJECTED);
        assert(!state.write_pending && state.output_offset == 0u && mvo_schannel_can_release_output(&state));
        assert(mvo_schannel_output_released(&state));
        assert(!mvo_schannel_plaintext_allowed(&state));
    }
    mvo_schannel_tokens state;
    final(&state, bytes, 1u); mvo_schannel_cancel(&state);
    assert(mvo_schannel_can_release_output(&state));
    assert(!mvo_schannel_begin_write(&state, 1u, &(uint64_t){0u}));
    assert(mvo_schannel_output_released(&state));
    final(&state, NULL, 0u); mvo_schannel_cancel(&state);
    assert(!mvo_schannel_verify_context(&state, true, true, true, true));
}
static void zero_oversize_and_failed_terminal_writes(void) {
    const size_t counts[] = {0u, sizeof(bytes) + 1u, MVO_SCHANNEL_TOKEN_LIMIT + 1u, SIZE_MAX};
    for (size_t i = 0u; i < sizeof(counts) / sizeof(counts[0]); ++i) {
        mvo_schannel_tokens state;
        final(&state, bytes, sizeof(bytes));
        uint64_t token = 0u;
        assert(mvo_schannel_begin_write(&state, sizeof(bytes), &token));
        assert(mvo_schannel_observe_write(&state, token, true, false, counts[i]) == MVO_SCHANNEL_WRITE_REJECTED);
        assert(state.output_offset == 0u && mvo_schannel_can_release_output(&state));
    }
    mvo_schannel_tokens state;
    final(&state, bytes, sizeof(bytes));
    uint64_t token = 0u;
    assert(mvo_schannel_begin_write(&state, sizeof(bytes), &token));
    assert(mvo_schannel_observe_write(&state, token, false, true, 3u) == MVO_SCHANNEL_WRITE_REJECTED);
    assert(state.output_offset == 0u && mvo_schannel_can_release_output(&state));
    const size_t invalid[] = {0u, sizeof(bytes) + 1u, SIZE_MAX};
    for (size_t i = 0u; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        final(&state, bytes, sizeof(bytes));
        assert(!mvo_schannel_begin_write(&state, invalid[i], &token));
        assert(!state.write_pending && mvo_schannel_can_release_output(&state));
    }
}
static void context_and_peer_gates(void) {
    for (unsigned absent = 0u; absent < 4u; ++absent) {
        mvo_schannel_tokens state;
        final(&state, NULL, 0u);
        assert(!mvo_schannel_verify_context(&state, absent != 0u, absent != 1u, absent != 2u, absent != 3u));
        assert(state.failed && !mvo_schannel_plaintext_allowed(&state));
    }
    mvo_schannel_tokens state;
    mvo_schannel_init(&state);
    assert(!mvo_schannel_verify_context(&state, true, true, true, true));
    final(&state, bytes, 1u);
    assert(!mvo_schannel_verify_context(&state, true, true, true, true));
    assert(state.output_owned); /* Failed verification must not discard provider output. */
    final(&state, NULL, 0u);
    assert(!mvo_schannel_verify_peer(&state, true));
    final(&state, NULL, 0u);
    assert(mvo_schannel_verify_context(&state, true, true, true, true));
    assert(!mvo_schannel_verify_peer(&state, false));
    assert(!mvo_schannel_verify_peer(&state, true));
    final(&state, NULL, 0u);
    assert(mvo_schannel_verify_context(&state, true, true, true, true));
    assert(mvo_schannel_verify_peer(&state, true));
    assert(mvo_schannel_plaintext_allowed(&state));
    mvo_schannel_cancel(&state);
    assert(!mvo_schannel_plaintext_allowed(&state));
}
static void null_and_illegal_ordering(void) {
    assert(!mvo_schannel_append(NULL, bytes, 1u));
    assert(!mvo_schannel_begin(NULL, &(uint64_t){0u}));
    assert(!mvo_schannel_observe(NULL, 1u, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, NULL, 0u));
    assert(!mvo_schannel_begin_write(NULL, 1u, &(uint64_t){0u}));
    assert(mvo_schannel_observe_write(NULL, 1u, true, true, 1u) == MVO_SCHANNEL_WRITE_REJECTED);
    assert(!mvo_schannel_can_release_output(NULL) && !mvo_schannel_output_released(NULL));
    assert(!mvo_schannel_verify_context(NULL, true, true, true, true));
    assert(!mvo_schannel_verify_peer(NULL, true) && !mvo_schannel_plaintext_allowed(NULL));
    mvo_schannel_cancel(NULL);
    mvo_schannel_tokens state;
    mvo_schannel_init(&state); append(&state, 1u);
    assert(!mvo_schannel_begin(&state, NULL));
    final(&state, bytes, 1u);
    assert(!mvo_schannel_append(&state, bytes, 1u));
    assert(state.output_owned);
    final(&state, NULL, 0u);
    assert(!mvo_schannel_begin(&state, &(uint64_t){0u}));
}
static void cancel_during_call_preserves_output(void) {
    mvo_schannel_tokens state;
    mvo_schannel_init(&state); append(&state, 1u);
    uint64_t token = begin(&state);
    mvo_schannel_cancel(&state);
    assert(state.step_pending);
    assert(!mvo_schannel_observe(&state, token, true, MVO_SCHANNEL_COMPLETE, NULL, 0u, bytes, 1u));
    assert(!state.step_pending && !state.context_complete && state.output_owned);
    assert(mvo_schannel_can_release_output(&state));
    assert(mvo_schannel_output_released(&state));
    assert(!mvo_schannel_plaintext_allowed(&state));
}
int main(int argc, char **argv) {
    assert(argc == 2);
    unsigned selected = (unsigned)strtoul(argv[1], NULL, 10);
    switch (selected) {
        case 0: segmented_incomplete_preserves_bytes(); break;
        case 1: incomplete_without_new_bytes_rejected(); break;
        case 2: coalesced_extra_and_final_output(); break;
        case 3: extra_pointer_and_length_bounds(); break;
        case 4: accumulator_bounds_and_pending_append(); break;
        case 5: no_progress_and_step_budget(); break;
        case 6: stale_steps_and_closed_statuses(); break;
        case 7: invalid_output_retains_cleanup(); break;
        case 8: final_token_custody_and_partial_writes(); break;
        case 9: cancellation_and_stale_write_custody(); break;
        case 10: zero_oversize_and_failed_terminal_writes(); break;
        case 11: context_and_peer_gates(); break;
        case 12: null_and_illegal_ordering(); break;
        case 13: cancel_during_call_preserves_output(); break;
        case 14: output_does_not_authorize_input_replay(); break;
        default: return 99;
    }
    return 0;
}
'''


class SchannelTokenContractTests(unittest.TestCase):
    """Observations are fixtures; passing tests never proves native TLS behavior."""

    @classmethod
    def setUpClass(cls):
        if not CLANG.is_file():
            raise unittest.SkipTest("portable contract needs the system C compiler")
        cls.before_hash = hashlib.sha256(HEADER.read_bytes()).hexdigest()
        cls.temp = tempfile.TemporaryDirectory(prefix="mvo-schannel-contract-")
        cls.directory = Path(cls.temp.name)
        source = cls.directory / "fixture.c"
        source.write_text(C_FIXTURE)
        cls.binaries = []
        for suffix, extra in [("strict", []), ("sanitized", ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"])]:
            binary = cls.directory / suffix
            command = [str(CLANG), "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic", "-O1",
                       *extra, "-I", str(HEADER.parent), str(source), "-o", str(binary)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if compiled.returncode != 0 or compiled.stderr:
                raise AssertionError(f"{suffix} compile failed: {compiled.returncode}\n{compiled.stderr}")
            cls.binaries.append(binary)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
        if hashlib.sha256(HEADER.read_bytes()).hexdigest() != cls.before_hash:
            raise AssertionError("header changed during portable contract checks")

    def check_case(self, case):
        for binary in self.binaries:
            with self.subTest(build=binary.name):
                result = subprocess.run([str(binary), str(case)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")

    def test_segmented_incomplete(self): self.check_case(0)
    def test_incomplete_replay(self): self.check_case(1)
    def test_coalesced_extra_final_output(self): self.check_case(2)
    def test_extra_pointer_lengths(self): self.check_case(3)
    def test_accumulator_bounds(self): self.check_case(4)
    def test_no_progress_step_budget(self): self.check_case(5)
    def test_stale_step_statuses(self): self.check_case(6)
    def test_invalid_output_cleanup(self): self.check_case(7)
    def test_final_token_partial_writes(self): self.check_case(8)
    def test_cancel_stale_write_custody(self): self.check_case(9)
    def test_bad_terminal_write_counts(self): self.check_case(10)
    def test_context_peer_gates(self): self.check_case(11)
    def test_null_illegal_ordering(self): self.check_case(12)
    def test_cancel_during_call(self): self.check_case(13)
    def test_output_not_input_replay(self): self.check_case(14)


if __name__ == "__main__":
    unittest.main(verbosity=2)
