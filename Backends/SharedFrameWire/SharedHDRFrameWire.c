// SPDX-License-Identifier: Apache-2.0
#include "SharedHDRFrameWire.h"
#include <string.h>

#define MVO_HDR_MAGIC UINT32_C(0x3248564d) /* MVH2, distinct from MVOS/v1 */

static uint64_t get_le(const uint8_t *p, unsigned n)
{
    uint64_t v = 0;
    for (unsigned i = 0; i < n; i++) v |= (uint64_t)p[i] << (i * 8);
    return v;
}
static void put_le(uint8_t *p, uint64_t v, unsigned n)
{
    for (unsigned i = 0; i < n; i++) p[i] = (uint8_t)(v >> (i * 8));
}
static bool nonzero_epoch(const uint8_t epoch[16])
{
    uint8_t v = 0;
    for (unsigned i = 0; i < 16; i++) v |= epoch[i];
    return v != 0;
}
static bool power_of_two(uint32_t v) { return v && !(v & (v - 1)); }
static bool valid_limits(const MVOHDRLimits *l)
{
    return l && power_of_two(l->page_bytes) && l->page_bytes >= 4096 &&
        l->page_bytes <= 65536 && power_of_two(l->row_alignment) &&
        l->row_alignment >= 256 && l->row_alignment <= 4096 &&
        l->maximum_mapping_bytes >= l->page_bytes &&
        l->maximum_mapping_bytes <= MVO_HDR_MAX_MAPPING_BYTES;
}
MVOHDRResult mvo_hdr_validate_descriptor(const MVOHDRDescriptor *d, const MVOHDRLimits *l)
{
    if (!d || !valid_limits(l)) return MVO_HDR_INVALID;
    if (d->pixel_format != MVO_HDR_RGBA16_FLOAT_LE ||
        d->color_encoding != MVO_HDR_LINEAR_709_D65_ABSOLUTE_80 ||
        d->optical_scale_millinit != MVO_HDR_OPTICAL_SCALE_MILLINIT) return MVO_HDR_UNSUPPORTED;
    if (!d->resource_id || !d->resource_incarnation || !d->color_generation ||
        !d->scanout_generation) return MVO_HDR_INVALID;
    uint64_t row = (uint64_t)d->width * 8;
    uint64_t bytes = (uint64_t)d->row_bytes * d->height;
    uint64_t padded = (bytes + l->page_bytes - 1) & ~((uint64_t)l->page_bytes - 1);
    if (!d->width || !d->height || d->width > MVO_HDR_MAX_DIMENSION ||
        d->height > MVO_HDR_MAX_DIMENSION ||
        (uint64_t)d->width * d->height > MVO_HDR_MAX_PIXELS ||
        d->row_bytes < row || d->row_bytes > row + 4096 ||
        d->row_bytes % l->row_alignment || !padded ||
        padded > l->maximum_mapping_bytes || d->mapped_bytes != padded) return MVO_HDR_BOUNDS;
    return MVO_HDR_OK;
}
static bool empty_descriptor(const MVOHDRDescriptor *d)
{
    return !d->resource_incarnation && !d->color_generation && !d->scanout_generation &&
        !d->resource_id && !d->scanout_id && !d->source_id && !d->target_id &&
        !d->width && !d->height && !d->row_bytes && !d->mapped_bytes &&
        !d->pixel_format && !d->color_encoding && !d->optical_scale_millinit;
}
static MVOHDRResult validate_header(const MVOHDRHeader *h, const MVOHDRLimits *l)
{
    if (!h || !valid_limits(l) || !nonzero_epoch(h->epoch)) return MVO_HDR_INVALID;
    if (h->kind == MVO_HDR_REQUEST) {
        return !h->sequence && !h->content_generation && !h->sent_ns && !h->slot &&
            empty_descriptor(&h->descriptor) ? MVO_HDR_OK : MVO_HDR_WIRE;
    }
    if (h->kind != MVO_HDR_ATTACH && h->kind != MVO_HDR_FRAME && h->kind != MVO_HDR_ACK)
        return MVO_HDR_UNSUPPORTED;
    MVOHDRResult result = mvo_hdr_validate_descriptor(&h->descriptor, l);
    if (result != MVO_HDR_OK) return result;
    if (h->kind == MVO_HDR_ATTACH || (h->kind == MVO_HDR_ACK && !h->sequence)) {
        return !h->sequence && !h->content_generation && !h->sent_ns && h->slot == 2
            ? MVO_HDR_OK : MVO_HDR_WIRE;
    }
    return h->sequence && h->content_generation && h->sent_ns &&
        h->slot == (uint32_t)((h->sequence - 1) % 2) ? MVO_HDR_OK : MVO_HDR_WIRE;
}
MVOHDRResult mvo_hdr_encode(const MVOHDRHeader *h, const MVOHDRLimits *l, void *output, size_t count)
{
    if (!output || count != MVO_HDR_PACKET_BYTES) return MVO_HDR_INVALID;
    MVOHDRResult result = validate_header(h, l);
    if (result != MVO_HDR_OK) return result;
    uint8_t b[MVO_HDR_PACKET_BYTES] = {0};
    const MVOHDRDescriptor *d = &h->descriptor;
    put_le(b, MVO_HDR_MAGIC, 4); put_le(b + 4, MVO_HDR_VERSION, 2); put_le(b + 6, h->kind, 2);
    memcpy(b + 8, h->epoch, 16); put_le(b + 24, h->sequence, 8);
    put_le(b + 32, h->content_generation, 8); put_le(b + 40, d->resource_incarnation, 8);
    put_le(b + 48, d->color_generation, 8); put_le(b + 56, d->scanout_generation, 8);
    put_le(b + 64, d->resource_id, 4); put_le(b + 68, d->scanout_id, 4);
    put_le(b + 72, d->width, 4); put_le(b + 76, d->height, 4);
    put_le(b + 80, d->row_bytes, 4); put_le(b + 84, d->mapped_bytes, 4);
    put_le(b + 88, h->slot, 4); put_le(b + 92, d->pixel_format, 4);
    put_le(b + 96, d->color_encoding, 4); put_le(b + 100, d->optical_scale_millinit, 4);
    put_le(b + 104, h->sent_ns, 8); put_le(b + 112, d->source_id, 4);
    put_le(b + 116, d->target_id, 4); memcpy(output, b, sizeof b);
    return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_decode(const void *input, size_t count, const MVOHDRLimits *l, MVOHDRHeader *out)
{
    if (!input || !out || count != MVO_HDR_PACKET_BYTES) return MVO_HDR_INVALID;
    const uint8_t *b = input;
    if (get_le(b, 4) != MVO_HDR_MAGIC || get_le(b + 120, 8)) return MVO_HDR_WIRE;
    if (get_le(b + 4, 2) != MVO_HDR_VERSION) return MVO_HDR_UNSUPPORTED;
    MVOHDRHeader h = {0}; MVOHDRDescriptor *d = &h.descriptor;
    h.kind = (uint32_t)get_le(b + 6, 2); memcpy(h.epoch, b + 8, 16);
    h.sequence = get_le(b + 24, 8); h.content_generation = get_le(b + 32, 8);
    d->resource_incarnation = get_le(b + 40, 8); d->color_generation = get_le(b + 48, 8);
    d->scanout_generation = get_le(b + 56, 8); d->resource_id = (uint32_t)get_le(b + 64, 4);
    d->scanout_id = (uint32_t)get_le(b + 68, 4); d->width = (uint32_t)get_le(b + 72, 4);
    d->height = (uint32_t)get_le(b + 76, 4); d->row_bytes = (uint32_t)get_le(b + 80, 4);
    d->mapped_bytes = (uint32_t)get_le(b + 84, 4); h.slot = (uint32_t)get_le(b + 88, 4);
    d->pixel_format = (uint32_t)get_le(b + 92, 4); d->color_encoding = (uint32_t)get_le(b + 96, 4);
    d->optical_scale_millinit = (uint32_t)get_le(b + 100, 4); h.sent_ns = get_le(b + 104, 8);
    d->source_id = (uint32_t)get_le(b + 112, 4); d->target_id = (uint32_t)get_le(b + 116, 4);
    MVOHDRResult result = validate_header(&h, l);
    if (result == MVO_HDR_OK) *out = h;
    return result;
}
MVOHDRResult mvo_hdr_make_ack(const void *input, size_t count, const MVOHDRLimits *l,
                             void *output, size_t output_count)
{
    if (!output || output_count != MVO_HDR_PACKET_BYTES) return MVO_HDR_INVALID;
    MVOHDRHeader h; MVOHDRResult result = mvo_hdr_decode(input, count, l, &h);
    if (result != MVO_HDR_OK) return result;
    if (h.kind != MVO_HDR_ATTACH && h.kind != MVO_HDR_FRAME) return MVO_HDR_STATE;
    h.kind = MVO_HDR_ACK;
    return mvo_hdr_encode(&h, l, output, output_count);
}
static bool compatible(const MVOHDRDescriptor *a, const MVOHDRDescriptor *b)
{
    return a->color_generation == b->color_generation && a->scanout_id == b->scanout_id &&
        a->source_id == b->source_id && a->target_id == b->target_id &&
        a->width == b->width && a->height == b->height && a->row_bytes == b->row_bytes &&
        a->mapped_bytes == b->mapped_bytes && a->pixel_format == b->pixel_format &&
        a->color_encoding == b->color_encoding && a->optical_scale_millinit == b->optical_scale_millinit;
}
static bool overlaps(const void *a, size_t an, const void *b, size_t bn)
{
    uintptr_t av = (uintptr_t)a, bv = (uintptr_t)b;
    if (an > UINTPTR_MAX - av || bn > UINTPTR_MAX - bv) return true;
    return av < bv + bn && bv < av + an;
}
static MVOHDRResult live(const MVOHDRSlots *s)
{
    if (!s || !s->initialized) return MVO_HDR_STATE;
    return s->retired ? MVO_HDR_RETIRED : MVO_HDR_OK;
}
static void invalidate_latest(MVOHDRSlots *s)
{
    s->latest = false; s->latest_slot = -1;
}
static void retire_pool(MVOHDRSlots *s)
{
    s->retired = true; s->attached = s->requested = false; invalidate_latest(s);
}
static MVOHDRResult admit_snapshot(MVOHDRSlots *s, const MVOHDRDescriptor *d)
{
    /* An old asynchronous observation cannot undo the current pool's meaning. */
    if (d && ((d->color_generation && d->color_generation < s->pool.color_generation) ||
        (d->scanout_generation && d->scanout_generation < s->observed.scanout_generation)))
        return MVO_HDR_STALE;
    MVOHDRResult result = mvo_hdr_validate_descriptor(d, &s->limits);
    if (result == MVO_HDR_UNSUPPORTED) { retire_pool(s); return MVO_HDR_RETIRED; }
    if (result != MVO_HDR_OK) { invalidate_latest(s); return result; }
    if (!compatible(&s->pool, d)) { retire_pool(s); return MVO_HDR_RETIRED; }
    return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_slots_init(MVOHDRSlots *s, const uint8_t epoch[16], const MVOHDRDescriptor *d,
                               const MVOHDRLimits *l, void *a, size_t an, void *b, size_t bn)
{
    if (!s || !epoch || !a || !b || !nonzero_epoch(epoch)) return MVO_HDR_INVALID;
    if (s->initialized) return MVO_HDR_STATE;
    MVOHDRResult result = mvo_hdr_validate_descriptor(d, l);
    if (result != MVO_HDR_OK) return result;
    if (an != d->mapped_bytes || bn != d->mapped_bytes || overlaps(a, an, b, bn) ||
        overlaps(a, an, s, sizeof *s) || overlaps(b, bn, s, sizeof *s)) return MVO_HDR_BOUNDS;
    MVOHDRSlots value = {0}; value.initialized = true; value.borrowed_slot = value.latest_slot = -1;
    value.maps[0] = a; value.maps[1] = b; value.pool = value.observed = *d; value.limits = *l;
    memcpy(value.epoch, epoch, 16);
    memset(a, 0, an); memset(b, 0, bn); *s = value;
    return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_slots_attach(MVOHDRSlots *s, void *output, size_t count)
{
    MVOHDRResult result = live(s); if (result != MVO_HDR_OK) return result;
    if (s->attach_sent || s->writing) return MVO_HDR_STATE;
    if (!output || count != MVO_HDR_PACKET_BYTES ||
        overlaps(output, count, s, sizeof *s) ||
        overlaps(output, count, s->maps[0], s->pool.mapped_bytes) ||
        overlaps(output, count, s->maps[1], s->pool.mapped_bytes)) return MVO_HDR_INVALID;
    MVOHDRHeader h = {0}; h.kind = MVO_HDR_ATTACH; h.slot = 2; h.descriptor = s->pool;
    memcpy(h.epoch, s->epoch, 16);
    result = mvo_hdr_encode(&h, &s->limits, output, count);
    if (result != MVO_HDR_OK) return result;
    result = mvo_hdr_make_ack(output, count, &s->limits, s->expected_ack, sizeof s->expected_ack);
    if (result != MVO_HDR_OK) return result;
    s->attach_sent = s->waiting_ack = true; return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_slots_request(MVOHDRSlots *s, const void *packet, size_t count)
{
    MVOHDRResult result = live(s); if (result != MVO_HDR_OK) return result;
    MVOHDRHeader h; result = mvo_hdr_decode(packet, count, &s->limits, &h);
    if (result != MVO_HDR_OK) return result;
    if (h.kind != MVO_HDR_REQUEST || memcmp(h.epoch, s->epoch, 16)) return MVO_HDR_WIRE;
    if (!s->attached) return MVO_HDR_STATE;
    if (s->waiting_ack || s->requested || s->writing) return MVO_HDR_BUSY;
    s->requested = true; return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_slots_write(MVOHDRSlots *s, const MVOHDRDescriptor *d, uint64_t generation,
                                MVOHDRSnapshotWriter writer, void *opaque)
{
    MVOHDRResult result = live(s); if (result != MVO_HDR_OK) return result;
    if (s->writing) return MVO_HDR_BUSY;
    result = admit_snapshot(s, d); if (result != MVO_HDR_OK) return result;
    if (!writer) { invalidate_latest(s); return MVO_HDR_INVALID; }
    if (s->completed_generation == UINT64_MAX) return MVO_HDR_OVERFLOW;
    if (!generation || generation <= s->completed_generation ||
        d->scanout_generation < s->observed.scanout_generation) return MVO_HDR_STALE;
    bool changed = d->resource_id != s->observed.resource_id ||
        d->resource_incarnation != s->observed.resource_incarnation;
    if (changed && d->scanout_generation == s->observed.scanout_generation) return MVO_HDR_STALE;
    unsigned slot = (unsigned)(s->sequence % 2);
    if ((int32_t)slot == s->borrowed_slot) return MVO_HDR_BUSY;
    /* Invalidate the mutable latest BEFORE invoking code that may fail after a
     * partial write. No obsolete frame can publish under a completed stamp. */
    invalidate_latest(s); s->writing = true; s->observed = *d;
    MVOHDRDescriptor snapshot = *d;
    bool copied = writer(opaque, s->maps[slot], snapshot.mapped_bytes, &snapshot);
    s->writing = false;
    if (!copied) return MVO_HDR_COPY_FAILED;
    s->snapshots[slot] = snapshot; s->generations[slot] = generation;
    s->completed_generation = generation; s->latest_slot = (int32_t)slot; s->latest = true;
    return MVO_HDR_OK;
}
typedef struct { const uint8_t *bytes; uint32_t stride; } Rows;
static bool copy_rows(void *opaque, uint8_t *target, size_t count, const MVOHDRDescriptor *d)
{
    const Rows *rows = opaque; (void)count;
    for (uint32_t y = 0; y < d->height; y++)
        memcpy(target + (size_t)y * d->row_bytes, rows->bytes + (size_t)y * rows->stride, (size_t)d->width * 8);
    return true;
}
MVOHDRResult mvo_hdr_slots_write_rows(MVOHDRSlots *s, const MVOHDRDescriptor *d, uint64_t generation,
                                     const void *source, size_t count, uint32_t stride)
{
    MVOHDRResult result = live(s); if (result != MVO_HDR_OK) return result;
    if (s->writing) return MVO_HDR_BUSY;
    result = admit_snapshot(s, d); if (result != MVO_HDR_OK) return result;
    uint64_t row = (uint64_t)d->width * 8;
    uint64_t needed = (uint64_t)stride * (d->height - 1) + row;
    if (!source || stride < row || stride > row + 4096 || needed > count ||
        overlaps(source, count, s->maps[0], s->pool.mapped_bytes) ||
        overlaps(source, count, s->maps[1], s->pool.mapped_bytes)) {
        invalidate_latest(s); return MVO_HDR_BOUNDS;
    }
    Rows rows = {source, stride};
    return mvo_hdr_slots_write(s, d, generation, copy_rows, &rows);
}
MVOHDRResult mvo_hdr_slots_publish(MVOHDRSlots *s, uint64_t sent, void *output, size_t count)
{
    MVOHDRResult result = live(s); if (result != MVO_HDR_OK) return result;
    if (!s->attached || !s->requested) return MVO_HDR_STATE;
    if (s->waiting_ack || s->writing || s->borrowed_slot >= 0) return MVO_HDR_BUSY;
    if (!s->latest || s->latest_slot < 0) return MVO_HDR_EMPTY;
    if (s->sequence == UINT64_MAX) return MVO_HDR_OVERFLOW;
    if (!sent || sent <= s->last_sent_ns) return MVO_HDR_STALE;
    if (!output || count != MVO_HDR_PACKET_BYTES ||
        overlaps(output, count, s, sizeof *s) ||
        overlaps(output, count, s->maps[0], s->pool.mapped_bytes) ||
        overlaps(output, count, s->maps[1], s->pool.mapped_bytes)) return MVO_HDR_INVALID;
    unsigned slot = (unsigned)s->latest_slot;
    if (slot != s->sequence % 2) return MVO_HDR_STATE;
    MVOHDRHeader h = {0}; memcpy(h.epoch, s->epoch, 16); h.kind = MVO_HDR_FRAME;
    h.sequence = s->sequence + 1; h.content_generation = s->generations[slot];
    h.sent_ns = sent; h.slot = slot; h.descriptor = s->snapshots[slot];
    result = mvo_hdr_encode(&h, &s->limits, output, count); if (result != MVO_HDR_OK) return result;
    result = mvo_hdr_make_ack(output, count, &s->limits, s->expected_ack, sizeof s->expected_ack);
    if (result != MVO_HDR_OK) return result;
    s->sequence = h.sequence; s->last_sent_ns = sent; s->borrowed_slot = (int32_t)slot;
    s->waiting_ack = true; s->requested = s->latest = false; s->latest_slot = -1;
    return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_slots_ack(MVOHDRSlots *s, const void *packet, size_t count)
{
    MVOHDRResult result = live(s); if (result != MVO_HDR_OK) return result;
    if (!s->waiting_ack) return MVO_HDR_STATE;
    MVOHDRHeader h; result = mvo_hdr_decode(packet, count, &s->limits, &h);
    if (result != MVO_HDR_OK) return result;
    if (h.kind != MVO_HDR_ACK || memcmp(packet, s->expected_ack, MVO_HDR_PACKET_BYTES))
        return MVO_HDR_ACK_MISMATCH;
    if (!h.sequence) s->attached = true;
    s->waiting_ack = false; s->borrowed_slot = -1; return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_slots_retire(MVOHDRSlots *s)
{
    MVOHDRResult result = live(s); if (result != MVO_HDR_OK) return result;
    if (s->writing) return MVO_HDR_BUSY;
    retire_pool(s);
    return MVO_HDR_OK;
}
