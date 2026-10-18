/* SPDX-License-Identifier: Apache-2.0 */
/* Original fixed-public-record span/custody checks; no TLS or crypto calls. */
#ifndef MVO_SCHANNEL_RECORD_CONTRACT_H
#define MVO_SCHANNEL_RECORD_CONTRACT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define MVO_SCHANNEL_RECORD_LIMIT 65536u
#define MVO_SCHANNEL_RECORD_STEPS 128u
static const uint8_t MVO_SCHANNEL_CLIENT_RECORD[] = "macOpenVM/tls-record-lab/v1:client\n";
static const uint8_t MVO_SCHANNEL_SERVER_RECORD[] = "macOpenVM/tls-record-lab/v1:server\n";
enum mvo_schannel_record_status { MVO_RECORD_OK = 1, MVO_RECORD_INCOMPLETE = 2,
    MVO_RECORD_RENEGOTIATE = 3, MVO_RECORD_EXPIRED = 4, MVO_RECORD_FAILURE = 5 };
enum mvo_schannel_record_outcome { MVO_RECORD_REJECTED = 0, MVO_RECORD_CIPHERTEXT = 1,
    MVO_RECORD_PLAINTEXT = 2, MVO_RECORD_NEED_INPUT = 3, MVO_RECORD_CONTROL = 4,
    MVO_RECORD_REHANDSHAKE = 5, MVO_RECORD_CLOSED = 6 };
typedef struct { const uint8_t *bytes; size_t count; } mvo_schannel_record_span;
typedef struct {
    uint8_t *allocation;
    size_t capacity, header, trailer, maximum_message, input_count, retry_count;
    size_t serialized_count, extra_count;
    const uint8_t *fixed;
    size_t fixed_count;
    mvo_schannel_record_span spans[3];
    uint64_t token;
    unsigned steps, mode; /* mode 0 unused, 1 encrypt, 2 decrypt; never switches. */
    bool pending, encrypting, failed, cancelled, ciphertext_ready, copied, plaintext_done;
} mvo_schannel_record;
/* Adapter supplies HEADER/DATA/TRAILER/EMPTY to EncryptMessage in that order,
 * after actual QueryContextAttributes(STREAM_SIZES); sequence number is zero.
 * DecryptMessage also uses sequence zero and pfQOP NULL. Closed status mapping
 * is explicit: OK, INCOMPLETE, RENEGOTIATE, EXPIRED, otherwise FAILURE. */
static inline bool mvo_record_fail(mvo_schannel_record *state) {
    if (state != NULL) state->failed = true;
    return false;
}
/* scope_admitted is an actual native context/peer gate supplied internally by
 * the adapter, never a serialized user override. QueryStreamSizes supplies the
 * three sizes. No key, arbitrary payload, socket or protocol message is accepted. */
static inline bool mvo_record_init(mvo_schannel_record *state, uint8_t *allocation,
    size_t capacity, size_t header, size_t trailer, size_t maximum_message,
    bool from_client, bool scope_admitted) {
    if (state == NULL) return false;
    state->allocation = allocation; state->capacity = capacity;
    state->header = header; state->trailer = trailer; state->maximum_message = maximum_message;
    state->fixed = from_client ? MVO_SCHANNEL_CLIENT_RECORD : MVO_SCHANNEL_SERVER_RECORD;
    state->fixed_count = from_client ? sizeof(MVO_SCHANNEL_CLIENT_RECORD) - 1u : sizeof(MVO_SCHANNEL_SERVER_RECORD) - 1u;
    state->input_count = state->retry_count = state->serialized_count = state->extra_count = 0u;
    state->token = 0u; state->steps = state->mode = 0u; state->pending = state->encrypting = state->cancelled = false;
    state->ciphertext_ready = state->copied = state->plaintext_done = false; state->failed = false;
    if (!scope_admitted || allocation == NULL || capacity == 0u || capacity > MVO_SCHANNEL_RECORD_LIMIT ||
        capacity > UINTPTR_MAX - (uintptr_t)allocation || header == 0u || trailer == 0u ||
        maximum_message == 0u || maximum_message > MVO_SCHANNEL_RECORD_LIMIT || state->fixed_count > maximum_message ||
        header > capacity || state->fixed_count > capacity - header || trailer > capacity - header - state->fixed_count)
        return mvo_record_fail(state);
    return true;
}
static inline bool mvo_record_bounds(const mvo_schannel_record *state) {
    return state != NULL && state->allocation != NULL && state->capacity > 0u &&
        state->capacity <= MVO_SCHANNEL_RECORD_LIMIT && state->input_count <= state->capacity &&
        state->capacity <= UINTPTR_MAX - (uintptr_t)state->allocation && state->header > 0u &&
        state->header <= state->capacity && state->fixed_count == sizeof(MVO_SCHANNEL_CLIENT_RECORD) - 1u &&
        (state->fixed == MVO_SCHANNEL_CLIENT_RECORD || state->fixed == MVO_SCHANNEL_SERVER_RECORD) &&
        state->fixed_count <= state->maximum_message && state->maximum_message <= MVO_SCHANNEL_RECORD_LIMIT &&
        state->fixed_count <= state->capacity - state->header && state->trailer > 0u &&
        state->trailer <= state->capacity - state->header - state->fixed_count &&
        state->serialized_count <= state->capacity && state->extra_count <= state->input_count &&
        state->steps <= MVO_SCHANNEL_RECORD_STEPS && state->mode <= 2u;
}
static inline bool mvo_record_span(const mvo_schannel_record *state, mvo_schannel_record_span span,
    size_t *offset) {
    if (!mvo_record_bounds(state) || span.bytes == NULL || offset == NULL) return false;
    uintptr_t base = (uintptr_t)state->allocation, address = (uintptr_t)span.bytes;
    if (address < base || address - base > state->capacity || span.count > state->capacity - (address - base)) return false;
    *offset = (size_t)(address - base); return true;
}
static inline bool mvo_record_encrypt_begin(mvo_schannel_record *state, uint64_t *token) {
    if (!mvo_record_bounds(state) || state->failed || state->cancelled || state->pending ||
        state->ciphertext_ready || state->copied || state->mode == 2u || state->input_count != 0u ||
        state->plaintext_done || token == NULL || state->token == UINT64_MAX)
        return mvo_record_fail(state);
    for (size_t i = 0u; i < state->fixed_count; ++i) state->allocation[state->header + i] = state->fixed[i];
    state->mode = 1u; state->pending = state->encrypting = true; *token = ++state->token; return true;
}
static inline enum mvo_schannel_record_outcome mvo_record_encrypt_return(mvo_schannel_record *state,
    uint64_t token, bool actual_return, enum mvo_schannel_record_status status,
    mvo_schannel_record_span header, mvo_schannel_record_span data, mvo_schannel_record_span trailer) {
    if (state == NULL || !state->pending || !state->encrypting || token == 0u || token != state->token || !actual_return) {
        (void)mvo_record_fail(state); return MVO_RECORD_REJECTED;
    }
    state->pending = false;
    size_t h = 0u, d = 0u, t = 0u;
    if (state->failed || state->cancelled || status != MVO_RECORD_OK ||
        !mvo_record_span(state, header, &h) || !mvo_record_span(state, data, &d) || !mvo_record_span(state, trailer, &t) ||
        h != 0u || header.count == 0u || header.count > state->header || d != state->header ||
        data.count != state->fixed_count || t != state->header + state->fixed_count ||
        trailer.count == 0u || trailer.count > state->trailer) {
        (void)mvo_record_fail(state); return MVO_RECORD_REJECTED;
    }
    state->spans[0] = header; state->spans[1] = data; state->spans[2] = trailer;
    state->serialized_count = header.count + data.count + trailer.count;
    state->ciphertext_ready = true; return MVO_RECORD_CIPHERTEXT;
}
/* Destination must be a distinct caller-owned allocation; exact produced spans
 * are packed in wire order, so unused reserved header/trailer bytes never leak. */
static inline bool mvo_record_copy_ciphertext(mvo_schannel_record *state, uint8_t *destination,
    size_t capacity, size_t *actual) {
    if (!mvo_record_bounds(state) || state->failed || state->cancelled || state->pending ||
        !state->ciphertext_ready || state->copied || destination == NULL || actual == NULL ||
        capacity > MVO_SCHANNEL_RECORD_LIMIT || capacity < state->serialized_count ||
        capacity > UINTPTR_MAX - (uintptr_t)destination) return mvo_record_fail(state);
    uintptr_t source = (uintptr_t)state->allocation, dest = (uintptr_t)destination;
    if (dest < source + state->capacity && source < dest + capacity) return mvo_record_fail(state);
    size_t count = 0u;
    for (unsigned span = 0u; span < 3u; ++span)
        for (size_t i = 0u; i < state->spans[span].count; ++i) destination[count++] = state->spans[span].bytes[i];
    *actual = count; state->copied = true; return true;
}
/* Appends only an actual completed ciphertext read. On INCOMPLETE the native
 * adapter retains this whole allocation; new bytes are required before retry. */
static inline bool mvo_record_append(mvo_schannel_record *state, const uint8_t *bytes, size_t count) {
    if (!mvo_record_bounds(state) || state->failed || state->cancelled || state->pending ||
        state->plaintext_done || state->ciphertext_ready || state->mode == 1u ||
        bytes == NULL || count == 0u || count > state->capacity - state->input_count)
        return mvo_record_fail(state);
    for (size_t i = 0u; i < count; ++i) state->allocation[state->input_count + i] = bytes[i];
    state->mode = 2u; state->input_count += count; return true;
}
static inline bool mvo_record_decrypt_begin(mvo_schannel_record *state, uint64_t *token) {
    if (!mvo_record_bounds(state) || state->failed || state->cancelled || state->pending ||
        state->plaintext_done || state->mode != 2u || state->input_count == 0u || state->input_count == state->retry_count ||
        state->steps == MVO_SCHANNEL_RECORD_STEPS ||
        token == NULL || state->token == UINT64_MAX) return mvo_record_fail(state);
    ++state->steps; state->pending = true; state->encrypting = false; *token = ++state->token; return true;
}
static inline enum mvo_schannel_record_outcome mvo_record_decrypt_return(mvo_schannel_record *state,
    uint64_t token, bool actual_return, enum mvo_schannel_record_status status,
    mvo_schannel_record_span data, size_t extra_count, size_t missing_count) {
    if (state == NULL || !state->pending || state->encrypting || token == 0u || token != state->token || !actual_return) {
        (void)mvo_record_fail(state); return MVO_RECORD_REJECTED;
    }
    state->pending = false;
    if (!mvo_record_bounds(state) || state->failed || state->cancelled || extra_count > state->input_count ||
        missing_count > state->capacity - state->input_count) { (void)mvo_record_fail(state); return MVO_RECORD_REJECTED; }
    if (status == MVO_RECORD_INCOMPLETE && data.bytes == NULL && data.count == 0u && extra_count == 0u) {
        state->retry_count = state->input_count; return MVO_RECORD_NEED_INPUT;
    }
    if (status == MVO_RECORD_RENEGOTIATE && data.bytes == NULL && data.count == 0u && missing_count == 0u) {
        /* Keep the entire native-modified buffer even without EXTRA. This
         * evaluator stops record calls; it does not implement rehandshake. */
        state->failed = true; return MVO_RECORD_REHANDSHAKE;
    }
    if (status == MVO_RECORD_EXPIRED && data.bytes == NULL && data.count == 0u && missing_count == 0u) {
        state->failed = true; return MVO_RECORD_CLOSED;
    }
    if (status != MVO_RECORD_OK || missing_count != 0u || extra_count == state->input_count) {
        (void)mvo_record_fail(state); return MVO_RECORD_REJECTED;
    }
    size_t consumed = state->input_count - extra_count, offset = 0u;
    if (data.bytes == NULL && data.count == 0u) {
        for (size_t i = 0u; i < extra_count; ++i) state->allocation[i] = state->allocation[consumed + i];
        state->input_count = extra_count; state->retry_count = 0u; return MVO_RECORD_CONTROL;
    }
    if (!mvo_record_span(state, data, &offset) || data.count != state->fixed_count ||
        offset > consumed || data.count > consumed - offset) { (void)mvo_record_fail(state); return MVO_RECORD_REJECTED; }
    for (size_t i = 0u; i < data.count; ++i)
        if (data.bytes[i] != state->fixed[i]) { (void)mvo_record_fail(state); return MVO_RECORD_REJECTED; }
    state->plaintext_done = true; state->extra_count = extra_count; return MVO_RECORD_PLAINTEXT;
}
/* One fixed DATA span only; application data fragmented across TLS records is
 * conservatively refused. MISSING is a hint, not allocation authority. */
static inline void mvo_record_cancel(mvo_schannel_record *state) {
    if (state != NULL) { state->cancelled = true; state->failed = true; }
}
static inline bool mvo_record_can_release(const mvo_schannel_record *state) { return state != NULL && !state->pending; }
#endif
