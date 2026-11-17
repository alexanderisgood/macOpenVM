// SPDX-License-Identifier: LicenseRef-macOpenVM-Source-1.0
#include "ScanoutLeasePool.h"

static MVOScanoutSlot *matching_slot(MVOScanoutLeasePool *pool, MVOScanoutLease lease,
                                    MVOScanoutSlotState state)
{
    if (!lease.epoch || lease.epoch != pool->epoch || !lease.sequence ||
        lease.slot >= MVO_SCANOUT_SLOT_COUNT) {
        return 0;
    }
    MVOScanoutSlot *slot = &pool->slots[lease.slot];
    return slot->state == state && slot->sequence == lease.sequence ? slot : 0;
}

static void drop_ready(MVOScanoutLeasePool *pool)
{
    for (uint32_t i = 0; i < MVO_SCANOUT_SLOT_COUNT; ++i) {
        if (pool->slots[i].state == MVO_SCANOUT_READY) {
            pool->slots[i] = (MVOScanoutSlot){0};
        }
    }
}

bool mvo_scanout_lease_init(MVOScanoutLeasePool *pool, uint64_t epoch)
{
    *pool = (MVOScanoutLeasePool){.epoch = epoch};
    return epoch != 0;
}

bool mvo_scanout_lease_begin_write(MVOScanoutLeasePool *pool, MVOScanoutLease *lease)
{
    if (!pool->epoch || pool->retired || pool->lastWrite == UINT64_MAX) {
        return false;
    }
    uint32_t selected = MVO_SCANOUT_SLOT_COUNT;
    for (uint32_t i = 0; i < MVO_SCANOUT_SLOT_COUNT; ++i) {
        MVOScanoutSlotState state = pool->slots[i].state;
        if (state == MVO_SCANOUT_FREE) {
            selected = i;
            break;
        }
        if (state == MVO_SCANOUT_READY) {
            selected = i;
        }
    }
    if (selected == MVO_SCANOUT_SLOT_COUNT) {
        return false;
    }
    // Prefer free storage. Under pressure discard a frame still waiting for
    // presentation so the writer can offer something newer.
    uint64_t sequence = ++pool->lastWrite;
    pool->slots[selected] = (MVOScanoutSlot){MVO_SCANOUT_WRITING, sequence};
    *lease = (MVOScanoutLease){pool->epoch, sequence, selected};
    return true;
}

bool mvo_scanout_lease_finish_write(MVOScanoutLeasePool *pool, MVOScanoutLease lease, bool ready)
{
    MVOScanoutSlot *slot = matching_slot(pool, lease, MVO_SCANOUT_WRITING);
    if (!slot) {
        return false;
    }
    if (ready && !pool->retired && lease.sequence > pool->latestCompletedFrame) {
        drop_ready(pool);
        pool->latestCompletedFrame = lease.sequence;
        slot->state = MVO_SCANOUT_READY;
    } else {
        *slot = (MVOScanoutSlot){0};
    }
    return true;
}

bool mvo_scanout_lease_take_latest(MVOScanoutLeasePool *pool, MVOScanoutLease *lease)
{
    if (pool->retired) {
        return false;
    }
    uint32_t readers = 0;
    uint32_t latest = MVO_SCANOUT_SLOT_COUNT;
    for (uint32_t i = 0; i < MVO_SCANOUT_SLOT_COUNT; ++i) {
        const MVOScanoutSlot *slot = &pool->slots[i];
        readers += slot->state == MVO_SCANOUT_BORROWED;
        if (slot->state == MVO_SCANOUT_READY) {
            latest = i;
        }
    }
    // Leave one slot for the producer. With two live reads, keep the completed
    // newest frame pending until one of those reads retires.
    if (readers >= MVO_SCANOUT_SLOT_COUNT - 1 || latest == MVO_SCANOUT_SLOT_COUNT) {
        return false;
    }
    MVOScanoutSlot *slot = &pool->slots[latest];
    slot->state = MVO_SCANOUT_BORROWED;
    *lease = (MVOScanoutLease){pool->epoch, slot->sequence, latest};
    return true;
}

bool mvo_scanout_lease_release_read(MVOScanoutLeasePool *pool, MVOScanoutLease lease)
{
    MVOScanoutSlot *slot = matching_slot(pool, lease, MVO_SCANOUT_BORROWED);
    if (!slot) {
        return false;
    }
    *slot = (MVOScanoutSlot){0};
    return true;
}

void mvo_scanout_lease_retire(MVOScanoutLeasePool *pool)
{
    pool->retired = true;
    drop_ready(pool);
}

bool mvo_scanout_lease_is_drained(const MVOScanoutLeasePool *pool)
{
    for (uint32_t i = 0; i < MVO_SCANOUT_SLOT_COUNT; ++i) {
        if (pool->slots[i].state != MVO_SCANOUT_FREE) {
            return false;
        }
    }
    return true;
}
