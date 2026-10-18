// SPDX-License-Identifier: Apache-2.0
#ifndef MVO_SHARED_HDR_FRAME_WIRE_H
#define MVO_SHARED_HDR_FRAME_WIRE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* New, opt-in protocol. Does not change or decode the existing MVOS/v1 wire.
 * No capability negotiation, socket/FD admission, resource retention or GPU
 * fence is implemented here. Callers must establish those before using it. */
enum {
    MVO_HDR_PACKET_BYTES = 128,
    MVO_HDR_VERSION = 2,
    MVO_HDR_ATTACH = 2, MVO_HDR_FRAME = 3, MVO_HDR_ACK = 4, MVO_HDR_REQUEST = 5,
    MVO_HDR_RGBA16_FLOAT_LE = 2,
    MVO_HDR_LINEAR_709_D65_ABSOLUTE_80 = 1,
    MVO_HDR_OPTICAL_SCALE_MILLINIT = 80000,
    MVO_HDR_MAX_MAPPING_BYTES = 67108864,
    MVO_HDR_MAX_PIXELS = 16777216,
    MVO_HDR_MAX_DIMENSION = 8192
};
typedef enum {
    MVO_HDR_OK = 0,
    MVO_HDR_INVALID = -1, MVO_HDR_WIRE = -2, MVO_HDR_UNSUPPORTED = -3,
    MVO_HDR_BOUNDS = -4, MVO_HDR_STATE = -5, MVO_HDR_STALE = -6,
    MVO_HDR_BUSY = -7, MVO_HDR_EMPTY = -8, MVO_HDR_RETIRED = -9,
    MVO_HDR_ACK_MISMATCH = -10, MVO_HDR_OVERFLOW = -11, MVO_HDR_COPY_FAILED = -12
} MVOHDRResult;

typedef struct {
    uint32_t page_bytes, row_alignment, maximum_mapping_bytes;
} MVOHDRLimits;

/* Immutable snapshot facts, not pointers or an assertion of ownership.
 * FP16 payload is IEEE754 binary16 LE, R,G,B,A. RGB is linear709/D65 with
 * (1,1,1)=80 cd/m2; negative and above-one values are never normalized/clamped.
 * Display is opaque; alpha bits are transported unchanged and ignored.
 * resource_id is the actual nonzero32-bit virtio resource ID. Its nonzero
 * incarnation prevents reuse ambiguity. Other IDs may legitimately be zero.
 * All three64-bit identity generations must be nonzero. */
typedef struct {
    uint64_t resource_incarnation, color_generation, scanout_generation;
    uint32_t resource_id, scanout_id, source_id, target_id;
    uint32_t width, height, row_bytes, mapped_bytes, pixel_format;
    uint32_t color_encoding, optical_scale_millinit;
} MVOHDRDescriptor;

typedef struct {
    uint8_t epoch[16];
    uint64_t sequence, content_generation, sent_ns;
    uint32_t kind, slot;
    MVOHDRDescriptor descriptor;
} MVOHDRHeader;

MVOHDRResult mvo_hdr_validate_descriptor(const MVOHDRDescriptor *, const MVOHDRLimits *);
MVOHDRResult mvo_hdr_encode(const MVOHDRHeader *, const MVOHDRLimits *, void *, size_t);
MVOHDRResult mvo_hdr_decode(const void *, size_t, const MVOHDRLimits *, MVOHDRHeader *);
/* Only ATTACH/FRAME can be acknowledged. Changes exactly the kind field;
 * every identity/layout/timestamp byte remains part of canonical ACK. */
MVOHDRResult mvo_hdr_make_ack(const void *, size_t, const MVOHDRLimits *, void *, size_t);

/* A synchronous full-snapshot writer. It may not retain the pointer or return
 * success before all writes complete. Caller supplies a real producer fence;
 * returning true does not itself prove GPU completion. Serialized caller only.
 * The callback may not mutate/reinitialize the state. */
typedef bool (*MVOHDRSnapshotWriter)(void *, uint8_t *, size_t, const MVOHDRDescriptor *);

/* Implementation state is visible for allocation/diagnostics, not mutation.
 * Zero initialize once. Each instance describes TWO NEW dedicated host-owned
 * mappings. Init zeroes both mappings. Never reuse the instance or its retired
 * mappings for a new pool. Mapping allocation/FD custody/lifetime are external. */
typedef struct {
    bool initialized, retired, attached, attach_sent, waiting_ack, requested, writing, latest;
    int32_t borrowed_slot, latest_slot;
    uint8_t epoch[16], expected_ack[MVO_HDR_PACKET_BYTES];
    uint8_t *maps[2];
    MVOHDRLimits limits;
    MVOHDRDescriptor pool, observed, snapshots[2];
    uint64_t sequence, completed_generation, last_sent_ns, generations[2];
} MVOHDRSlots;

MVOHDRResult mvo_hdr_slots_init(MVOHDRSlots *, const uint8_t epoch[16],
                               const MVOHDRDescriptor *, const MVOHDRLimits *,
                               void *first, size_t first_bytes, void *second, size_t second_bytes);
MVOHDRResult mvo_hdr_slots_attach(MVOHDRSlots *, void *, size_t);
MVOHDRResult mvo_hdr_slots_request(MVOHDRSlots *, const void *, size_t);
/* A current/new incompatible color/layout/target or unsupported interpretation
 * automatically retires the pool, so a pending request cannot publish an old
 * meaning. A malformed attempted snapshot invalidates latest. Older color or
 * selection generations are ignored as stale. Retire requires new mappings. */
MVOHDRResult mvo_hdr_slots_write(MVOHDRSlots *, const MVOHDRDescriptor *, uint64_t content_generation,
                                MVOHDRSnapshotWriter, void *);
/* CPU adapter for generated fixtures or a bounded existing CPU snapshot.
 * Copies RGB/alpha bits unchanged, no interpretation or floating point math.
 * Source must be disjoint from BOTH host slots. */
MVOHDRResult mvo_hdr_slots_write_rows(MVOHDRSlots *, const MVOHDRDescriptor *, uint64_t,
                                     const void *source, size_t source_bytes, uint32_t source_stride);
MVOHDRResult mvo_hdr_slots_publish(MVOHDRSlots *, uint64_t sent_ns, void *, size_t);
MVOHDRResult mvo_hdr_slots_ack(MVOHDRSlots *, const void *, size_t);
/* Disconnect/timeout abandons this pool. Borrowed pages must remain alive via
 * the consumer's independent mapping custody; no subsequent write is allowed. */
MVOHDRResult mvo_hdr_slots_retire(MVOHDRSlots *);

#ifdef __cplusplus
}
#endif
#endif
