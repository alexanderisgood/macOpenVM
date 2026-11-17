// SPDX-License-Identifier: Apache-2.0
#ifndef MVO_SCANOUT_DXMT_H
#define MVO_SCANOUT_DXMT_H

#include "ScanoutLeasePool.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MVOScanoutDxmt MVOScanoutDxmt;

MVOScanoutDxmt *mvo_scanout_dxmt_create(uint32_t width, uint32_t height, uint32_t stride,
                                       const int fds[MVO_SCANOUT_SLOT_COUNT]);
void mvo_scanout_dxmt_destroy(MVOScanoutDxmt *source);
// Success means the DXMT queue completed the clear into the supplied backing.
// Failure leaves ownership uncertain and the caller must stop using this pool.
bool mvo_scanout_dxmt_render(MVOScanoutDxmt *source, MVOScanoutLease lease);

#ifdef __cplusplus
}
#endif
#endif
