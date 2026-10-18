# SPDX-License-Identifier: Apache-2.0
"""C-backed portable one-shot public-byte probe; no native/device/VM operation."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADERS = [ROOT / "GuestAgent/Windows/vioser_info_contract.h",
           ROOT / "GuestAgent/Windows/vioser_transfer_contract.h"]
CLANG = Path("/usr/bin/clang")

C_FIXTURE = r'''
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "vioser_transfer_contract.h"

static uint64_t begin(mvo_vioser_transfer *state, enum mvo_vioser_transfer_direction direction, size_t length) {
    uint64_t token = 0u;
    assert(mvo_vioser_transfer_begin(state, direction, length, &token));
    assert(token != 0u && !mvo_vioser_transfer_can_release(state));
    return token;
}
static void read_challenge(mvo_vioser_transfer *state) {
    uint64_t token = begin(state, MVO_VIOSER_TRANSFER_READ, MVO_VIOSER_PROBE_CHALLENGE_LENGTH);
    assert(mvo_vioser_transfer_observe(state, token, true, 0u, false,
        MVO_VIOSER_PROBE_CHALLENGE_LENGTH, MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_ADVANCED);
    assert(state->read_offset == MVO_VIOSER_PROBE_CHALLENGE_LENGTH);
    assert(mvo_vioser_transfer_can_release(state) && !mvo_vioser_transfer_success(state));
}
static void exact_challenge_then_reply(void) {
    mvo_vioser_transfer state;
    mvo_vioser_transfer_init(&state);
    assert(mvo_vioser_transfer_can_release(&state) && !mvo_vioser_transfer_success(&state));
    assert(mvo_vioser_transfer_next_phase(&state) == MVO_VIOSER_TRANSFER_READ);
    assert(mvo_vioser_transfer_remaining(&state) == MVO_VIOSER_PROBE_CHALLENGE_LENGTH);
    assert(MVO_VIOSER_PROBE_CHALLENGE_LENGTH <= 4096u && MVO_VIOSER_PROBE_REPLY_LENGTH <= 4096u);
    assert(memcmp(MVO_VIOSER_PROBE_CHALLENGE, "macOpenVM/vioser-transfer-lab/v1:challenge\n",
        MVO_VIOSER_PROBE_CHALLENGE_LENGTH) == 0);
    assert(memcmp(MVO_VIOSER_PROBE_REPLY, "macOpenVM/vioser-transfer-lab/v1:reply\n",
        MVO_VIOSER_PROBE_REPLY_LENGTH) == 0);
    read_challenge(&state);
    assert(mvo_vioser_transfer_next_phase(&state) == MVO_VIOSER_TRANSFER_WRITE);
    uint64_t token = begin(&state, MVO_VIOSER_TRANSFER_WRITE, MVO_VIOSER_PROBE_REPLY_LENGTH);
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, false,
        MVO_VIOSER_PROBE_REPLY_LENGTH, NULL) == MVO_VIOSER_TRANSFER_ADVANCED);
    assert(mvo_vioser_transfer_success(&state) && mvo_vioser_transfer_can_release(&state));
    assert(mvo_vioser_transfer_next_phase(&state) == MVO_VIOSER_TRANSFER_NONE);
    assert(mvo_vioser_transfer_remaining(&state) == 0u);
}
static void fragmented_progress_all_chunk_sizes(void) {
    for (size_t read_chunk = 1u; read_chunk <= MVO_VIOSER_PROBE_CHALLENGE_LENGTH; ++read_chunk) {
        for (size_t write_chunk = 1u; write_chunk <= MVO_VIOSER_PROBE_REPLY_LENGTH; ++write_chunk) {
            mvo_vioser_transfer state;
            mvo_vioser_transfer_init(&state);
            while (mvo_vioser_transfer_next_phase(&state) != MVO_VIOSER_TRANSFER_NONE) {
                enum mvo_vioser_transfer_direction direction = mvo_vioser_transfer_next_phase(&state);
                size_t remaining = mvo_vioser_transfer_remaining(&state);
                size_t chunk = direction == MVO_VIOSER_TRANSFER_READ ? read_chunk : write_chunk;
                size_t actual = chunk < remaining ? chunk : remaining;
                size_t read_before = state.read_offset, write_before = state.write_offset;
                uint64_t token = begin(&state, direction, remaining);
                /* Returned counts before terminal completion are untrusted and ignored. */
                assert(mvo_vioser_transfer_observe(&state, token, false, 997u, false,
                    SIZE_MAX, NULL) == MVO_VIOSER_TRANSFER_WAIT);
                assert(state.read_offset == read_before && state.write_offset == write_before);
                const uint8_t *bytes = direction == MVO_VIOSER_TRANSFER_READ ?
                    MVO_VIOSER_PROBE_CHALLENGE + read_before : NULL;
                assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true,
                    actual, bytes) == MVO_VIOSER_TRANSFER_ADVANCED);
                assert(mvo_vioser_transfer_can_release(&state));
                assert(state.read_offset == read_before + (direction == MVO_VIOSER_TRANSFER_READ ? actual : 0u));
                assert(state.write_offset == write_before + (direction == MVO_VIOSER_TRANSFER_WRITE ? actual : 0u));
            }
            assert(mvo_vioser_transfer_success(&state));
        }
    }
}
static void no_early_write_or_duplicate_begin(void) {
    mvo_vioser_transfer state;
    uint64_t token = 77u;
    mvo_vioser_transfer_init(&state);
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_WRITE, 1u, &token));
    assert(token == 77u && state.failed && state.read_offset == 0u && state.write_offset == 0u);
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
    mvo_vioser_transfer_init(&state);
    token = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u);
    uint64_t second = 0u;
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &second));
    assert(second == 0u && !mvo_vioser_transfer_can_release(&state));
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true, 1u,
        MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(state.read_offset == 0u && mvo_vioser_transfer_can_release(&state));
}
static void request_bounds_and_null_arguments(void) {
    const size_t requests[] = {0u, MVO_VIOSER_PROBE_CHALLENGE_LENGTH + 1u, 4097u, SIZE_MAX};
    for (size_t index = 0u; index < sizeof(requests) / sizeof(requests[0]); ++index) {
        mvo_vioser_transfer state;
        mvo_vioser_transfer_init(&state);
        uint64_t token = 0u;
        assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, requests[index], &token));
        assert(state.failed && token == 0u && mvo_vioser_transfer_can_release(&state));
    }
    mvo_vioser_transfer state;
    mvo_vioser_transfer_init(&state);
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, NULL));
    assert(state.failed);
    mvo_vioser_transfer_init(&state);
    assert(!mvo_vioser_transfer_begin(&state, (enum mvo_vioser_transfer_direction)UINT_MAX, 1u, &(uint64_t){0u}));
    assert(!mvo_vioser_transfer_begin(NULL, MVO_VIOSER_TRANSFER_READ, 1u, &(uint64_t){0u}));
    assert(!mvo_vioser_transfer_success(NULL) && !mvo_vioser_transfer_can_release(NULL));
    assert(mvo_vioser_transfer_next_phase(NULL) == MVO_VIOSER_TRANSFER_NONE);
    assert(mvo_vioser_transfer_remaining(NULL) == 0u);
    assert(mvo_vioser_transfer_observe(NULL, 1u, true, 0u, true, 1u, NULL) == MVO_VIOSER_TRANSFER_REJECTED);
    mvo_vioser_transfer_request_cancel(NULL, true, true);
    mvo_vioser_transfer_cancel_result(NULL, 1u);
}
static void zero_and_oversize_terminal_counts(void) {
    const size_t counts[] = {0u, 2u, 4097u, SIZE_MAX};
    for (unsigned phase = 0u; phase < 2u; ++phase) {
        for (size_t index = 0u; index < sizeof(counts) / sizeof(counts[0]); ++index) {
            mvo_vioser_transfer state;
            mvo_vioser_transfer_init(&state);
            if (phase != 0u) read_challenge(&state);
            enum mvo_vioser_transfer_direction direction = phase == 0u ? MVO_VIOSER_TRANSFER_READ : MVO_VIOSER_TRANSFER_WRITE;
            size_t read_before = state.read_offset;
            uint64_t token = begin(&state, direction, 1u);
            assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true, counts[index],
                phase == 0u ? MVO_VIOSER_PROBE_CHALLENGE : NULL) == MVO_VIOSER_TRANSFER_REJECTED);
            assert(state.failed && state.read_offset == read_before && state.write_offset == 0u);
            assert(mvo_vioser_transfer_can_release(&state) && !mvo_vioser_transfer_success(&state));
            assert(!mvo_vioser_transfer_begin(&state, direction, 1u, &token));
        }
    }
}
static void unexpected_bytes_and_missing_buffers(void) {
    for (size_t changed = 0u; changed < MVO_VIOSER_PROBE_CHALLENGE_LENGTH; ++changed) {
        uint8_t forged[sizeof(MVO_VIOSER_PROBE_CHALLENGE)];
        memcpy(forged, MVO_VIOSER_PROBE_CHALLENGE, sizeof(forged));
        forged[changed] ^= 0xffu;
        mvo_vioser_transfer state;
        mvo_vioser_transfer_init(&state);
        uint64_t token = begin(&state, MVO_VIOSER_TRANSFER_READ, MVO_VIOSER_PROBE_CHALLENGE_LENGTH);
        assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true,
            MVO_VIOSER_PROBE_CHALLENGE_LENGTH, forged) == MVO_VIOSER_TRANSFER_REJECTED);
        assert(state.read_offset == 0u && state.write_offset == 0u && state.failed);
        assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
    }
    /* A valid prefix is not rolled back or followed by a reply after a later
     * fragment fails. No byte of that malformed fragment advances the offset. */
    for (size_t prefix = 1u; prefix < MVO_VIOSER_PROBE_CHALLENGE_LENGTH; ++prefix) {
        mvo_vioser_transfer partial;
        mvo_vioser_transfer_init(&partial);
        uint64_t current = begin(&partial, MVO_VIOSER_TRANSFER_READ, prefix);
        assert(mvo_vioser_transfer_observe(&partial, current, true, 0u, false,
            prefix, MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_ADVANCED);
        uint8_t wrong = (uint8_t)(MVO_VIOSER_PROBE_CHALLENGE[prefix] ^ 0xffu);
        current = begin(&partial, MVO_VIOSER_TRANSFER_READ, 1u);
        assert(mvo_vioser_transfer_observe(&partial, current, true, 0u, false,
            1u, &wrong) == MVO_VIOSER_TRANSFER_REJECTED);
        assert(partial.read_offset == prefix && partial.write_offset == 0u);
        assert(!mvo_vioser_transfer_begin(&partial, MVO_VIOSER_TRANSFER_READ, 1u, &current));
        assert(!mvo_vioser_transfer_begin(&partial, MVO_VIOSER_TRANSFER_WRITE, 1u, &current));
    }
    mvo_vioser_transfer state;
    mvo_vioser_transfer_init(&state);
    uint64_t token = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u);
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true, 1u, NULL) == MVO_VIOSER_TRANSFER_REJECTED);
    mvo_vioser_transfer_init(&state); read_challenge(&state);
    token = begin(&state, MVO_VIOSER_TRANSFER_WRITE, 1u);
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true, 1u,
        MVO_VIOSER_PROBE_REPLY) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(state.write_offset == 0u);
}
static void nonterminal_observations_never_advance(void) {
    const uint32_t errors[] = {996u, 997u, 258u, 192u, 995u, 6u, 1117u};
    for (size_t index = 0u; index < sizeof(errors) / sizeof(errors[0]); ++index) {
        mvo_vioser_transfer state;
        mvo_vioser_transfer_init(&state);
        uint64_t token = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u);
        assert(mvo_vioser_transfer_observe(&state, token, false, errors[index], false,
            1u, MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_WAIT);
        assert(!mvo_vioser_transfer_can_release(&state) && state.read_offset == 0u);
        if (index < 4u) {
            assert(mvo_vioser_transfer_observe(&state, token, false, errors[index], true,
                1u, MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_WAIT);
            assert(!mvo_vioser_transfer_can_release(&state));
        }
        assert(mvo_vioser_transfer_observe(&state, token, false, 995u, true,
            1u, MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_REJECTED);
        assert(mvo_vioser_transfer_can_release(&state) && state.failed && state.read_offset == 0u);
    }
}
static void cancellation_keeps_custody_until_actual_completion(void) {
    const unsigned cancel_results[] = {1u, 2u, 3u, 1168u, UINT_MAX};
    for (unsigned kind = 0u; kind < 3u; ++kind) {
        for (size_t index = 0u; index < sizeof(cancel_results) / sizeof(cancel_results[0]); ++index) {
            mvo_vioser_transfer state;
            mvo_vioser_transfer_init(&state);
            uint64_t token = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u);
            mvo_vioser_transfer_request_cancel(&state, kind != 1u, kind != 0u);
            mvo_vioser_transfer_cancel_result(&state, cancel_results[index]);
            assert(!mvo_vioser_transfer_can_release(&state) && state.operation.cancel_result == cancel_results[index]);
            mvo_vioser_transfer_request_cancel(&state, false, false);
            assert(mvo_vioser_transfer_next_phase(&state) == MVO_VIOSER_TRANSFER_NONE);
            assert(mvo_vioser_transfer_observe(&state, token, false, 996u, true,
                1u, MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_WAIT);
            assert(!mvo_vioser_transfer_can_release(&state));
            assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true,
                1u, MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_REJECTED);
            assert(state.read_offset == 0u && state.failed && mvo_vioser_transfer_can_release(&state));
            assert(!mvo_vioser_transfer_success(&state));
            assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
        }
    }
}
static void final_reply_cancellation_and_post_completion_race(void) {
    mvo_vioser_transfer state;
    mvo_vioser_transfer_init(&state); read_challenge(&state);
    uint64_t token = begin(&state, MVO_VIOSER_TRANSFER_WRITE, MVO_VIOSER_PROBE_REPLY_LENGTH);
    mvo_vioser_transfer_request_cancel(&state, true, false);
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true,
        MVO_VIOSER_PROBE_REPLY_LENGTH, NULL) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(state.write_offset == 0u && !mvo_vioser_transfer_success(&state));
    mvo_vioser_transfer_init(&state); read_challenge(&state);
    token = begin(&state, MVO_VIOSER_TRANSFER_WRITE, MVO_VIOSER_PROBE_REPLY_LENGTH);
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, false,
        MVO_VIOSER_PROBE_REPLY_LENGTH, NULL) == MVO_VIOSER_TRANSFER_ADVANCED);
    assert(mvo_vioser_transfer_success(&state));
    mvo_vioser_transfer_request_cancel(&state, false, true);
    assert(!mvo_vioser_transfer_success(&state) && mvo_vioser_transfer_can_release(&state));
}
static void cancellation_preserves_previously_accepted_partial_offsets(void) {
    for (unsigned phase = 0u; phase < 2u; ++phase) {
        for (unsigned kind = 0u; kind < 2u; ++kind) {
            mvo_vioser_transfer state;
            mvo_vioser_transfer_init(&state);
            if (phase != 0u) read_challenge(&state);
            enum mvo_vioser_transfer_direction direction = phase == 0u ? MVO_VIOSER_TRANSFER_READ : MVO_VIOSER_TRANSFER_WRITE;
            uint64_t token = begin(&state, direction, 7u);
            assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true, 7u,
                phase == 0u ? MVO_VIOSER_PROBE_CHALLENGE : NULL) == MVO_VIOSER_TRANSFER_ADVANCED);
            size_t read_before = state.read_offset, write_before = state.write_offset;
            token = begin(&state, direction, 1u);
            mvo_vioser_transfer_request_cancel(&state, kind == 0u, kind != 0u);
            mvo_vioser_transfer_cancel_result(&state, 1168u);
            assert(!mvo_vioser_transfer_can_release(&state));
            assert(mvo_vioser_transfer_observe(&state, token, false, 997u, true, 1u,
                phase == 0u ? MVO_VIOSER_PROBE_CHALLENGE + 7u : NULL) == MVO_VIOSER_TRANSFER_WAIT);
            assert(!mvo_vioser_transfer_can_release(&state));
            assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true, 1u,
                phase == 0u ? MVO_VIOSER_PROBE_CHALLENGE + 7u : NULL) == MVO_VIOSER_TRANSFER_REJECTED);
            assert(state.read_offset == read_before && state.write_offset == write_before);
            assert(state.failed && mvo_vioser_transfer_can_release(&state));
            assert(mvo_vioser_transfer_next_phase(&state) == MVO_VIOSER_TRANSFER_NONE);
            assert(!mvo_vioser_transfer_begin(&state, direction, 1u, &token));
        }
    }
}
static void stale_and_duplicate_completion_cannot_settle_new_irp(void) {
    mvo_vioser_transfer state;
    mvo_vioser_transfer_init(&state);
    assert(mvo_vioser_transfer_observe(&state, 1u, true, 0u, true, 1u,
        MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(state.failed && state.read_offset == 0u);
    mvo_vioser_transfer_init(&state);
    uint64_t old = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u);
    assert(mvo_vioser_transfer_observe(&state, old, true, 0u, false, 1u,
        MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_ADVANCED);
    uint64_t current = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u);
    assert(current != old);
    assert(mvo_vioser_transfer_observe(&state, old, true, 0u, true, 1u,
        MVO_VIOSER_PROBE_CHALLENGE + 1u) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(state.read_offset == 1u && !mvo_vioser_transfer_can_release(&state));
    assert(mvo_vioser_transfer_observe(&state, current, false, 995u, true, 0u, NULL) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(mvo_vioser_transfer_can_release(&state) && state.read_offset == 1u);
    mvo_vioser_transfer_init(&state);
    current = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u);
    assert(mvo_vioser_transfer_observe(&state, current, true, 0u, false, 1u,
        MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_ADVANCED);
    assert(mvo_vioser_transfer_observe(&state, current, true, 0u, true, 1u,
        MVO_VIOSER_PROBE_CHALLENGE + 1u) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(state.read_offset == 1u && state.failed);
}
static void offset_and_token_overflow_refuse_before_arithmetic(void) {
    mvo_vioser_transfer state;
    uint64_t token = 0u;
    mvo_vioser_transfer_init(&state); state.read_offset = SIZE_MAX;
    assert(mvo_vioser_transfer_remaining(&state) == 0u);
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
    assert(state.read_offset == SIZE_MAX && state.failed);
    mvo_vioser_transfer_init(&state); state.write_offset = SIZE_MAX;
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
    mvo_vioser_transfer_init(&state); state.write_offset = 1u;
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
    mvo_vioser_transfer_init(&state); state.token = UINT64_MAX;
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
    assert(state.token == UINT64_MAX && token == 0u);
    mvo_vioser_transfer_init(&state);
    token = begin(&state, MVO_VIOSER_TRANSFER_READ, 1u); state.read_offset = SIZE_MAX;
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true, 1u,
        MVO_VIOSER_PROBE_CHALLENGE) == MVO_VIOSER_TRANSFER_REJECTED);
    assert(state.read_offset == SIZE_MAX && mvo_vioser_transfer_can_release(&state));
}
static void no_second_probe_or_trailing_nul(void) {
    mvo_vioser_transfer state;
    uint64_t token = 0u;
    mvo_vioser_transfer_init(&state);
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ,
        sizeof(MVO_VIOSER_PROBE_CHALLENGE), &token));
    mvo_vioser_transfer_init(&state); read_challenge(&state);
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_WRITE,
        sizeof(MVO_VIOSER_PROBE_REPLY), &token));
    mvo_vioser_transfer_init(&state); read_challenge(&state);
    token = begin(&state, MVO_VIOSER_TRANSFER_WRITE, MVO_VIOSER_PROBE_REPLY_LENGTH);
    assert(mvo_vioser_transfer_observe(&state, token, true, 0u, true,
        MVO_VIOSER_PROBE_REPLY_LENGTH, NULL) == MVO_VIOSER_TRANSFER_ADVANCED);
    assert(mvo_vioser_transfer_success(&state));
    assert(!mvo_vioser_transfer_begin(&state, MVO_VIOSER_TRANSFER_READ, 1u, &token));
    assert(state.failed && !mvo_vioser_transfer_success(&state));
}
int main(int argc, char **argv) {
    assert(argc == 2);
    switch (atoi(argv[1])) {
        case 1: exact_challenge_then_reply(); break;
        case 2: fragmented_progress_all_chunk_sizes(); break;
        case 3: no_early_write_or_duplicate_begin(); break;
        case 4: request_bounds_and_null_arguments(); break;
        case 5: zero_and_oversize_terminal_counts(); break;
        case 6: unexpected_bytes_and_missing_buffers(); break;
        case 7: nonterminal_observations_never_advance(); break;
        case 8: cancellation_keeps_custody_until_actual_completion(); break;
        case 9: final_reply_cancellation_and_post_completion_race(); break;
        case 10: stale_and_duplicate_completion_cannot_settle_new_irp(); break;
        case 11: offset_and_token_overflow_refuse_before_arithmetic(); break;
        case 12: no_second_probe_or_trailing_nul(); break;
        case 13: cancellation_preserves_previously_accepted_partial_offsets(); break;
        default: abort();
    }
    return 0;
}
'''


@unittest.skipUnless(CLANG.is_file(), "Requires an existing native Clang for portable C contracts.")
class WindowsVioserTransferContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="mvo-vioser-transfer-contract-", dir="/private/tmp")
        cls.addClassCleanup(cls.temporary.cleanup)
        base = Path(cls.temporary.name)
        cls.source_pins = {}
        for header in HEADERS:
            content = header.read_bytes()
            cls.source_pins[header] = hashlib.sha256(content).hexdigest()
            (base / header.name).write_bytes(content)
        source = base / "fixture.c"
        source.write_text(C_FIXTURE)
        cls.binary = base / "fixture"
        build = subprocess.run([str(CLANG), "-std=c11", "-Wall", "-Wextra", "-Wconversion", "-Werror",
                                "-pedantic", str(source), "-o", str(cls.binary)],
                               capture_output=True, timeout=20, check=False)
        if build.returncode != 0:
            raise AssertionError(build.stderr.decode())
        cls.check_pins()

    @classmethod
    def check_pins(cls):
        for header, expected in cls.source_pins.items():
            if hashlib.sha256(header.read_bytes()).hexdigest() != expected:
                raise AssertionError("Portable transfer source changed during verification.")

    def check_case(self, number):
        self.check_pins()
        result = subprocess.run([str(self.binary), str(number)], capture_output=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b"")
        self.check_pins()

    def test_exact_public_challenge_before_fixed_reply(self): self.check_case(1)
    def test_every_read_and_write_chunk_size_with_pending_progress(self): self.check_case(2)
    def test_early_write_and_double_submission_are_permanent_failure(self): self.check_case(3)
    def test_zero_oversize_null_and_invalid_direction_requests(self): self.check_case(4)
    def test_zero_oversize_and_overflow_terminal_lengths(self): self.check_case(5)
    def test_each_unexpected_challenge_byte_and_wrong_buffer_role(self): self.check_case(6)
    def test_pending_incomplete_timeout_and_failed_result_custody(self): self.check_case(7)
    def test_cancel_results_and_late_success_never_release_or_advance_early(self): self.check_case(8)
    def test_cancellation_before_and_after_final_reply_denies_success(self): self.check_case(9)
    def test_stale_and_duplicate_completion_cannot_settle_new_operation(self): self.check_case(10)
    def test_offset_and_generation_overflow_refuse_without_arithmetic(self): self.check_case(11)
    def test_one_shot_probe_and_nul_exclusion(self): self.check_case(12)
    def test_partial_offsets_survive_cancellation_and_late_completion(self): self.check_case(13)


if __name__ == "__main__":
    unittest.main()
