/* SPDX-License-Identifier: Apache-2.0 */
/* Original, portable one-shot public-byte probe. No device, TLS or guest command. */
#ifndef MVO_VIOSER_TRANSFER_CONTRACT_H
#define MVO_VIOSER_TRANSFER_CONTRACT_H
#include "vioser_info_contract.h"

#define MVO_VIOSER_TRANSFER_LIMIT 4096u
static const uint8_t MVO_VIOSER_PROBE_CHALLENGE[] = "macOpenVM/vioser-transfer-lab/v1:challenge\n";
static const uint8_t MVO_VIOSER_PROBE_REPLY[] = "macOpenVM/vioser-transfer-lab/v1:reply\n";
#define MVO_VIOSER_PROBE_CHALLENGE_LENGTH (sizeof(MVO_VIOSER_PROBE_CHALLENGE) - 1u)
#define MVO_VIOSER_PROBE_REPLY_LENGTH (sizeof(MVO_VIOSER_PROBE_REPLY) - 1u)
_Static_assert(MVO_VIOSER_PROBE_CHALLENGE_LENGTH > 0u &&
               MVO_VIOSER_PROBE_CHALLENGE_LENGTH <= MVO_VIOSER_TRANSFER_LIMIT, "bounded public challenge");
_Static_assert(MVO_VIOSER_PROBE_REPLY_LENGTH > 0u &&
               MVO_VIOSER_PROBE_REPLY_LENGTH <= MVO_VIOSER_TRANSFER_LIMIT, "bounded public reply");

enum mvo_vioser_transfer_direction {
    MVO_VIOSER_TRANSFER_NONE = 0, MVO_VIOSER_TRANSFER_READ = 1, MVO_VIOSER_TRANSFER_WRITE = 2
};
enum mvo_vioser_transfer_result {
    MVO_VIOSER_TRANSFER_WAIT = 0, MVO_VIOSER_TRANSFER_ADVANCED = 1, MVO_VIOSER_TRANSFER_REJECTED = 2
};
typedef struct {
    mvo_vioser_operation operation;
    size_t read_offset, write_offset, requested;
    uint64_t token;
    enum mvo_vioser_transfer_direction direction;
    bool failed;
} mvo_vioser_transfer;

/* Single owner, single IRP at a time. Initialize once before the probe, never
 * while native I/O is pending. No helper mutates buffers or issues native I/O.
 * The adapter retains its handle, OVERLAPPED, event and buffer until can_release.
 * A true api_success is itself terminal evidence; a failed API call additionally
 * needs the actual native completion flag, exactly as in the INFO contract. */
static inline void mvo_vioser_transfer_init(mvo_vioser_transfer *state) {
    mvo_vioser_op_init(&state->operation);
    state->read_offset = state->write_offset = state->requested = 0u;
    state->token = 0u;
    state->direction = MVO_VIOSER_TRANSFER_NONE;
    state->failed = false;
}
static inline bool mvo_vioser_transfer_bounds(const mvo_vioser_transfer *state) {
    return state != NULL && state->read_offset <= MVO_VIOSER_PROBE_CHALLENGE_LENGTH &&
        state->write_offset <= MVO_VIOSER_PROBE_REPLY_LENGTH &&
        (state->write_offset == 0u || state->read_offset == MVO_VIOSER_PROBE_CHALLENGE_LENGTH);
}
static inline bool mvo_vioser_transfer_can_release(const mvo_vioser_transfer *state) {
    return state != NULL && mvo_vioser_op_can_release(&state->operation);
}
static inline enum mvo_vioser_transfer_direction mvo_vioser_transfer_next_phase(
    const mvo_vioser_transfer *state) {
    if (!mvo_vioser_transfer_bounds(state) || state->failed || state->operation.deadline_expired ||
        state->operation.user_cancelled) return MVO_VIOSER_TRANSFER_NONE;
    if (state->read_offset < MVO_VIOSER_PROBE_CHALLENGE_LENGTH) return MVO_VIOSER_TRANSFER_READ;
    if (state->write_offset < MVO_VIOSER_PROBE_REPLY_LENGTH) return MVO_VIOSER_TRANSFER_WRITE;
    return MVO_VIOSER_TRANSFER_NONE;
}
static inline size_t mvo_vioser_transfer_remaining(const mvo_vioser_transfer *state) {
    switch (mvo_vioser_transfer_next_phase(state)) {
        case MVO_VIOSER_TRANSFER_READ: return MVO_VIOSER_PROBE_CHALLENGE_LENGTH - state->read_offset;
        case MVO_VIOSER_TRANSFER_WRITE: return MVO_VIOSER_PROBE_REPLY_LENGTH - state->write_offset;
        default: return 0u;
    }
}
static inline bool mvo_vioser_transfer_begin(mvo_vioser_transfer *state,
    enum mvo_vioser_transfer_direction direction, size_t requested, uint64_t *token) {
    if (state == NULL) return false;
    if (!mvo_vioser_transfer_bounds(state) || state->failed || token == NULL ||
        !mvo_vioser_transfer_can_release(state) || direction == MVO_VIOSER_TRANSFER_NONE ||
        direction != mvo_vioser_transfer_next_phase(state) || requested == 0u ||
        requested > mvo_vioser_transfer_remaining(state) || state->token == UINT64_MAX) {
        state->failed = true;
        return false;
    }
    ++state->token;
    state->direction = direction;
    state->requested = requested;
    mvo_vioser_op_init(&state->operation);
    mvo_vioser_op_submit(&state->operation);
    *token = state->token;
    return true;
}
static inline void mvo_vioser_transfer_request_cancel(mvo_vioser_transfer *state, bool deadline, bool user) {
    if (state == NULL) return;
    mvo_vioser_op_request_cancel(&state->operation, deadline, user);
    if (deadline || user) state->failed = true;
}
static inline void mvo_vioser_transfer_cancel_result(mvo_vioser_transfer *state, unsigned result) {
    if (state != NULL) mvo_vioser_op_cancel_result(&state->operation, result);
}
static inline enum mvo_vioser_transfer_result mvo_vioser_transfer_observe(
    mvo_vioser_transfer *state, uint64_t token, bool api_success, uint32_t error,
    bool native_completed, size_t transferred, const uint8_t *read_bytes) {
    if (state == NULL) return MVO_VIOSER_TRANSFER_REJECTED;
    /* Stale evidence cannot settle a different IRP, even after probe failure. */
    if (!state->operation.submitted || state->operation.completed || token == 0u || token != state->token) {
        state->failed = true;
        return MVO_VIOSER_TRANSFER_REJECTED;
    }
    if (!mvo_vioser_transfer_bounds(state) || state->requested == 0u ||
        state->requested > MVO_VIOSER_TRANSFER_LIMIT ||
        (state->direction != MVO_VIOSER_TRANSFER_READ && state->direction != MVO_VIOSER_TRANSFER_WRITE)) {
        state->failed = true;
    }
    if (!mvo_vioser_op_observe(&state->operation, api_success, error, native_completed)) {
        return MVO_VIOSER_TRANSFER_WAIT;
    }
    if (state->failed || !mvo_vioser_op_success(&state->operation) || transferred == 0u ||
        transferred > state->requested) {
        state->failed = true;
        return MVO_VIOSER_TRANSFER_REJECTED;
    }
    if (state->direction == MVO_VIOSER_TRANSFER_READ) {
        if (read_bytes == NULL || transferred > MVO_VIOSER_PROBE_CHALLENGE_LENGTH - state->read_offset) {
            state->failed = true;
            return MVO_VIOSER_TRANSFER_REJECTED;
        }
        for (size_t index = 0u; index < transferred; ++index) {
            if (read_bytes[index] != MVO_VIOSER_PROBE_CHALLENGE[state->read_offset + index]) {
                state->failed = true;
                return MVO_VIOSER_TRANSFER_REJECTED;
            }
        }
        state->read_offset += transferred;
    } else {
        if (state->read_offset != MVO_VIOSER_PROBE_CHALLENGE_LENGTH || read_bytes != NULL ||
            transferred > MVO_VIOSER_PROBE_REPLY_LENGTH - state->write_offset) {
            state->failed = true;
            return MVO_VIOSER_TRANSFER_REJECTED;
        }
        /* The native adapter must write only the fixed reply at write_offset. */
        state->write_offset += transferred;
    }
    return MVO_VIOSER_TRANSFER_ADVANCED;
}
static inline bool mvo_vioser_transfer_success(const mvo_vioser_transfer *state) {
    return mvo_vioser_transfer_bounds(state) && !state->failed &&
        state->read_offset == MVO_VIOSER_PROBE_CHALLENGE_LENGTH &&
        state->write_offset == MVO_VIOSER_PROBE_REPLY_LENGTH &&
        state->direction == MVO_VIOSER_TRANSFER_WRITE && mvo_vioser_op_success(&state->operation);
}
#endif
