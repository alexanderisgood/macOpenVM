/* SPDX-License-Identifier: Apache-2.0 */
/* Original portable token/custody contract. Does not call SSPI or verify TLS. */
#ifndef MVO_SCHANNEL_TOKEN_CONTRACT_H
#define MVO_SCHANNEL_TOKEN_CONTRACT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MVO_SCHANNEL_TOKEN_LIMIT 65536u
/* Evaluation budget, not a TLS wire limit. Fragment reads do not consume a
 * step until submitted to SSPI; 128 legs bound provider/output-only loops. */
#define MVO_SCHANNEL_STEP_LIMIT 128u

/* The native adapter maps only its explicitly handled SSPI statuses. It must
 * feed actual observations, not infer success from a token or an open port. */
enum mvo_schannel_status {
    MVO_SCHANNEL_INCOMPLETE = 1, MVO_SCHANNEL_CONTINUE = 2,
    MVO_SCHANNEL_COMPLETE = 3, MVO_SCHANNEL_FAILURE = 4
};
enum mvo_schannel_write_result {
    MVO_SCHANNEL_WRITE_WAIT = 0, MVO_SCHANNEL_WRITE_ADVANCED = 1,
    MVO_SCHANNEL_WRITE_REJECTED = 2
};
typedef struct {
    uint8_t input[MVO_SCHANNEL_TOKEN_LIMIT];
    size_t input_count, submitted_count;
    uint64_t step_token, write_token;
    unsigned steps;
    const uint8_t *output;
    size_t output_count, output_offset, write_requested;
    bool step_pending, need_input, context_complete, context_verified;
    bool peer_verified, output_owned, write_pending, failed, cancelled;
} mvo_schannel_tokens;

/* One owner initializes once, before any native work. It retains the SSPI
 * context/credential and provider output until the corresponding gates allow
 * release. Synchronous SSPI calls and pending transport I/O are distinct. */
static inline void mvo_schannel_init(mvo_schannel_tokens *state) {
    state->input_count = state->submitted_count = 0u;
    state->step_token = state->write_token = 0u;
    state->steps = 0u;
    state->output = NULL;
    state->output_count = state->output_offset = state->write_requested = 0u;
    state->step_pending = state->context_complete = state->context_verified = false;
    state->peer_verified = state->output_owned = state->write_pending = false;
    state->failed = state->cancelled = false;
    state->need_input = true;
}
static inline bool mvo_schannel_bounds(const mvo_schannel_tokens *state) {
    return state != NULL && state->input_count <= MVO_SCHANNEL_TOKEN_LIMIT &&
        state->submitted_count <= MVO_SCHANNEL_TOKEN_LIMIT &&
        state->output_count <= MVO_SCHANNEL_TOKEN_LIMIT &&
        state->output_offset <= state->output_count &&
        state->write_requested <= state->output_count - state->output_offset &&
        state->steps <= MVO_SCHANNEL_STEP_LIMIT &&
        (!state->write_pending || state->output_owned);
}
static inline bool mvo_schannel_fail(mvo_schannel_tokens *state) {
    if (state != NULL) state->failed = true;
    return false;
}
static inline bool mvo_schannel_append(mvo_schannel_tokens *state,
    const uint8_t *bytes, size_t count) {
    if (!mvo_schannel_bounds(state) || state->failed || state->cancelled ||
        state->step_pending || state->output_owned || state->context_complete ||
        bytes == NULL || count == 0u || count > MVO_SCHANNEL_TOKEN_LIMIT - state->input_count)
        return mvo_schannel_fail(state);
    /* The adapter must supply its valid completed read buffer. No caller pointer
     * is retained; the buffer extent must itself have been bounded by the read. */
    for (size_t i = 0u; i < count; ++i) state->input[state->input_count + i] = bytes[i];
    state->input_count += count;
    state->need_input = false;
    return true;
}
static inline bool mvo_schannel_begin(mvo_schannel_tokens *state, uint64_t *token) {
    if (!mvo_schannel_bounds(state) || state->failed || state->cancelled || token == NULL ||
        state->step_pending || state->output_owned || state->context_complete ||
        state->need_input || state->input_count == 0u ||
        state->step_token == UINT64_MAX || state->steps == MVO_SCHANNEL_STEP_LIMIT)
        return mvo_schannel_fail(state);
    ++state->step_token;
    ++state->steps;
    state->submitted_count = state->input_count;
    state->step_pending = true;
    *token = state->step_token;
    return true;
}
/* Compare integer addresses without undefined subtraction/order comparisons
 * between unrelated pointers. A Schannel EXTRA span must describe the exact
 * unprocessed tail of the original submitted accumulator, not a new copy. */
static inline bool mvo_schannel_extra_valid(const mvo_schannel_tokens *state,
    const uint8_t *extra, size_t count) {
    if (count == 0u) return extra == NULL;
    if (state == NULL || extra == NULL || count > state->submitted_count) return false;
    uintptr_t base = (uintptr_t)state->input;
    if (state->submitted_count > UINTPTR_MAX - base) return false;
    return (uintptr_t)extra == base + state->submitted_count - count;
}
/* actual_return means the reserved synchronous SSPI call has returned. A stale
 * observation cannot settle another call or replace provider-output custody.
 * The adapter must own any nonempty output span and check its real allocation
 * extent before reporting it. Even rejected output remains retained for cleanup. */
static inline bool mvo_schannel_observe(mvo_schannel_tokens *state, uint64_t token,
    bool actual_return, enum mvo_schannel_status status, const uint8_t *extra,
    size_t extra_count, const uint8_t *output, size_t output_count) {
    if (state == NULL || !state->step_pending || token == 0u || token != state->step_token)
        return mvo_schannel_fail(state);
    if (!actual_return) return mvo_schannel_fail(state);
    state->step_pending = false;
    if (output != NULL) {
        state->output = output;
        state->output_count = output_count;
        state->output_offset = 0u;
        state->output_owned = true;
    }
    bool output_valid = (output == NULL && output_count == 0u) ||
        (output != NULL && output_count > 0u && output_count <= MVO_SCHANNEL_TOKEN_LIMIT &&
         output_count <= UINTPTR_MAX - (uintptr_t)output);
    if (!output_valid || !mvo_schannel_bounds(state) || state->failed || state->cancelled ||
        !mvo_schannel_extra_valid(state, extra, extra_count) ||
        (status != MVO_SCHANNEL_INCOMPLETE && status != MVO_SCHANNEL_CONTINUE &&
         status != MVO_SCHANNEL_COMPLETE)) return mvo_schannel_fail(state);
    if (status == MVO_SCHANNEL_INCOMPLETE) {
        /* MISSING is a hint, never authority to discard bytes or allocate beyond
         * this accumulator. No output/EXTRA is accepted on an incomplete call. */
        if (extra_count != 0u || output_count != 0u) return mvo_schannel_fail(state);
        state->need_input = true;
        return true;
    }
    size_t consumed = state->submitted_count - extra_count;
    if (status == MVO_SCHANNEL_CONTINUE && consumed == 0u && output_count == 0u)
        return mvo_schannel_fail(state);
    for (size_t i = 0u; i < extra_count; ++i) state->input[i] = extra[i];
    state->input_count = extra_count;
    /* Output progress does not authorize replaying an unchanged input token. */
    state->need_input = extra_count == 0u || consumed == 0u;
    state->context_complete = status == MVO_SCHANNEL_COMPLETE;
    return true;
}
static inline void mvo_schannel_cancel(mvo_schannel_tokens *state) {
    if (state != NULL) { state->cancelled = true; state->failed = true; }
}
static inline bool mvo_schannel_begin_write(mvo_schannel_tokens *state,
    size_t requested, uint64_t *token) {
    if (!mvo_schannel_bounds(state) || state->failed || state->cancelled || token == NULL ||
        state->step_pending || !state->output_owned || state->write_pending ||
        requested == 0u || requested > state->output_count - state->output_offset ||
        state->write_token == UINT64_MAX) return mvo_schannel_fail(state);
    ++state->write_token;
    state->write_requested = requested;
    state->write_pending = true;
    *token = state->write_token;
    return true;
}
/* Cancellation ACK/timeout are not terminal. api_success or actual native
 * completion settles only this write. Late success releases custody but cannot
 * advance/replay a cancelled or failed exchange. A write may already have sent. */
static inline enum mvo_schannel_write_result mvo_schannel_observe_write(
    mvo_schannel_tokens *state, uint64_t token, bool api_success,
    bool native_completed, size_t transferred) {
    if (state == NULL || !state->write_pending || token == 0u || token != state->write_token) {
        (void)mvo_schannel_fail(state); return MVO_SCHANNEL_WRITE_REJECTED;
    }
    if (!api_success && !native_completed) return MVO_SCHANNEL_WRITE_WAIT;
    state->write_pending = false;
    if (!mvo_schannel_bounds(state) || !api_success || state->failed || state->cancelled ||
        transferred == 0u || transferred > state->write_requested) {
        (void)mvo_schannel_fail(state); return MVO_SCHANNEL_WRITE_REJECTED;
    }
    state->output_offset += transferred;
    state->write_requested = 0u;
    return MVO_SCHANNEL_WRITE_ADVANCED;
}
static inline bool mvo_schannel_can_release_output(const mvo_schannel_tokens *state) {
    return state != NULL && state->output_owned && !state->step_pending && !state->write_pending &&
        (state->failed || state->cancelled || state->output_offset == state->output_count);
}
/* Call only AFTER the native adapter actually frees the provider allocation.
 * Premature release fails without losing the retained span. */
static inline bool mvo_schannel_output_released(mvo_schannel_tokens *state) {
    if (!mvo_schannel_can_release_output(state)) return mvo_schannel_fail(state);
    state->output = NULL;
    state->output_count = state->output_offset = state->write_requested = 0u;
    state->output_owned = false;
    return true;
}
/* Actual QueryContextAttributes observations, not requested flags. The adapter
 * maps dwProtocol == SP_PROT_TLS1_3_SERVER (or CLIENT for a separate client lab)
 * to tls13; absence of a peer certificate or required security attributes fails. */
static inline bool mvo_schannel_verify_context(mvo_schannel_tokens *state,
    bool tls13, bool confidentiality, bool integrity, bool mutual_peer_certificate) {
    if (!mvo_schannel_bounds(state) || state->failed || state->cancelled ||
        !state->context_complete || state->step_pending || state->output_owned ||
        state->context_verified || !tls13 || !confidentiality || !integrity || !mutual_peer_certificate)
        return mvo_schannel_fail(state);
    state->context_verified = true;
    return true;
}
/* Only after scoped chain/EKU/validity/identity/exact-leaf validation. This
 * contract cannot establish those checks; a false observation is sticky. */
static inline bool mvo_schannel_verify_peer(mvo_schannel_tokens *state, bool scoped_peer_verified) {
    if (!mvo_schannel_bounds(state) || state->failed || state->cancelled ||
        !state->context_verified || state->peer_verified || !scoped_peer_verified)
        return mvo_schannel_fail(state);
    state->peer_verified = true;
    return true;
}
static inline bool mvo_schannel_plaintext_allowed(const mvo_schannel_tokens *state) {
    return mvo_schannel_bounds(state) && !state->failed && !state->cancelled &&
        state->context_complete && state->context_verified && state->peer_verified &&
        !state->step_pending && !state->output_owned && !state->write_pending;
}
#endif
