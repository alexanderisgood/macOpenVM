// SPDX-License-Identifier: Apache-2.0
// Original generated-frame adapter for the reviewed native DXMT embedder API.
#ifndef MVO_DXMT_SOURCE_H
#define MVO_DXMT_SOURCE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MvoDxmtSource MvoDxmtSource;
typedef struct MvoDxmtLayout {
    int fd;
    uint32_t width, height, dxgiFormat;
    uint64_t stride, size, offset;
} MvoDxmtLayout;
// The fixture exclusively owns the source until destroy; this is not guest locking.
MvoDxmtSource *mvo_dxmt_create(uint32_t width, uint32_t height, uint32_t format,
                              MvoDxmtLayout *layout);
int mvo_dxmt_prepare(MvoDxmtSource *source, uint32_t sequence, double *waitMS,
                     int closeHandleBeforeWait);
void mvo_dxmt_destroy(MvoDxmtSource *source);
#ifdef __cplusplus
}
#endif
#endif
