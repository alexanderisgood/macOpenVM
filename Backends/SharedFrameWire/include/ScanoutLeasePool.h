// SPDX-License-Identifier: LicenseRef-macOpenVM-Source-1.0
#ifndef MVO_SCANOUT_LEASE_POOL_H
#define MVO_SCANOUT_LEASE_POOL_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { MVO_SCANOUT_SLOT_COUNT = 3 };

typedef struct {
    uint64_t epoch;
    uint64_t sequence;
    uint32_t slot;
} MVOScanoutLease;

typedef enum {
    MVO_SCANOUT_FREE,
    MVO_SCANOUT_WRITING,
    MVO_SCANOUT_READY,
    MVO_SCANOUT_BORROWED
} MVOScanoutSlotState;

typedef struct {
    MVOScanoutSlotState state;
    uint64_t sequence;
} MVOScanoutSlot;

typedef struct {
    uint64_t epoch;
    uint64_t lastWrite;
    uint64_t latestCompletedFrame;
    bool retired;
    MVOScanoutSlot slots[MVO_SCANOUT_SLOT_COUNT];
} MVOScanoutLeasePool;

// Serialize transitions on the producer side. Each nonzero epoch owns
// distinct backing storage. All writers must obtain a lease before accessing
// a slot. A slot cannot also serve as a standing desktop/guest primary.
bool mvo_scanout_lease_init(MVOScanoutLeasePool *pool, uint64_t epoch);
bool mvo_scanout_lease_begin_write(MVOScanoutLeasePool *pool, MVOScanoutLease *lease);
// Call after all writes for this lease have stopped, including on failure.
// Set ready only after the producer's GPU completion confirms valid pixels.
bool mvo_scanout_lease_finish_write(MVOScanoutLeasePool *pool, MVOScanoutLease lease, bool ready);
bool mvo_scanout_lease_take_latest(MVOScanoutLeasePool *pool, MVOScanoutLease *lease);
// Accept an exact release only after the consumer has cleared it as a redraw
// source and retired every GPU command buffer that may still read it.
bool mvo_scanout_lease_release_read(MVOScanoutLeasePool *pool, MVOScanoutLease lease);
// A disconnect/mode switch drops unpublished frames. Outstanding writes and
// reads may drain, but this pool can never issue a lease again.
void mvo_scanout_lease_retire(MVOScanoutLeasePool *pool);
bool mvo_scanout_lease_is_drained(const MVOScanoutLeasePool *pool);

#ifdef __cplusplus
}
#endif
#endif
