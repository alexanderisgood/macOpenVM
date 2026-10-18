/* SPDX-License-Identifier: Apache-2.0 */
/* Original portable bounds and ownership logic; no Windows/device/TLS operation. */
#ifndef MVO_VIOSER_INFO_CONTRACT_H
#define MVO_VIOSER_INFO_CONTRACT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum mvo_vioser_parse_result { MVO_VIOSER_INVALID = 0, MVO_VIOSER_OTHER = 1, MVO_VIOSER_MATCH = 2 };
typedef struct {
    uint32_t id;
    bool out_full, host_connected, guest_connected;
} mvo_vioser_info;

static inline enum mvo_vioser_parse_result mvo_vioser_parse_info(
    const uint8_t *bytes, size_t count, const char *expected, size_t expected_length,
    bool canonical_flags, mvo_vioser_info *info) {
    if (bytes == NULL || expected == NULL || info == NULL || count < 8u || count > 1024u ||
        expected_length == 0u || expected_length > 255u) return MVO_VIOSER_INVALID;
    if (canonical_flags && (bytes[4] > 1u || bytes[5] > 1u || bytes[6] > 1u)) return MVO_VIOSER_INVALID;
    size_t length = 0;
    while (7u + length < count && bytes[7u + length] != 0u) {
        if (length == 255u) return MVO_VIOSER_INVALID;
        ++length;
    }
    if (7u + length == count) return MVO_VIOSER_INVALID;
    info->id = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
               ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
    info->out_full = bytes[4] != 0u;
    info->host_connected = bytes[5] != 0u;
    info->guest_connected = bytes[6] != 0u;
    /* The producer may return trailing padding; it is not part of the port name. */
    if (length != expected_length) return MVO_VIOSER_OTHER;
    for (size_t index = 0; index < length; ++index) {
        if (bytes[7u + index] != (uint8_t)expected[index]) return MVO_VIOSER_OTHER;
    }
    return MVO_VIOSER_MATCH;
}

typedef struct { unsigned examined, matches; bool failed; } mvo_vioser_scan;
static inline bool mvo_vioser_scan_admit(mvo_vioser_scan *scan) {
    if (scan->failed || scan->examined >= 32u) { scan->failed = true; return false; }
    ++scan->examined;
    return true;
}
static inline bool mvo_vioser_scan_record(mvo_vioser_scan *scan, enum mvo_vioser_parse_result result) {
    if (result == MVO_VIOSER_INVALID) scan->failed = true;
    if (result == MVO_VIOSER_MATCH && ++scan->matches > 1u) scan->failed = true;
    return !scan->failed;
}
static inline bool mvo_vioser_scan_unique(const mvo_vioser_scan *scan) {
    return !scan->failed && scan->matches == 1u;
}

typedef struct {
    bool submitted, completed, deadline_expired, user_cancelled, completion_succeeded;
    unsigned cancel_result;
} mvo_vioser_operation;
/* Private single-owner contract: initialize once per IRP; submit once; complete
 * once from actual terminal evidence. Double submission/completion is not an API
 * for reusing an IRP. The adapter never mutates this state from its control thread. */
static inline void mvo_vioser_op_init(mvo_vioser_operation *op) {
    op->submitted = op->completed = op->deadline_expired = op->user_cancelled = op->completion_succeeded = false;
    op->cancel_result = 0u;
}
static inline void mvo_vioser_op_submit(mvo_vioser_operation *op) { op->submitted = true; }
static inline void mvo_vioser_op_request_cancel(mvo_vioser_operation *op, bool deadline, bool user) {
    op->deadline_expired = op->deadline_expired || deadline;
    op->user_cancelled = op->user_cancelled || user;
}
static inline void mvo_vioser_op_cancel_result(mvo_vioser_operation *op, unsigned result) {
    op->cancel_result = result; /* Requested/not-found/error never completes the IRP. */
}
static inline void mvo_vioser_op_complete(mvo_vioser_operation *op, bool succeeded) {
    op->completed = true;
    op->completion_succeeded = succeeded;
}
static inline bool mvo_vioser_op_observe(mvo_vioser_operation *op, bool api_success,
                                        uint32_t error, bool native_completed) {
    /* Win32 INCOMPLETE/PENDING/timeout/APC-wait results are not completion. */
    if (!api_success && (error == 996u || error == 997u || error == 258u || error == 192u)) return false;
    if (!api_success && !native_completed) return false;
    mvo_vioser_op_complete(op, api_success);
    return true;
}
static inline bool mvo_vioser_op_can_release(const mvo_vioser_operation *op) {
    return !op->submitted || op->completed;
}
static inline bool mvo_vioser_op_success(const mvo_vioser_operation *op) {
    return op->submitted && op->completed && op->completion_succeeded && !op->deadline_expired && !op->user_cancelled;
}
#endif
