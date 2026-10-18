// SPDX-License-Identifier: Apache-2.0
#ifndef MVO_SHARED_FRAME_FIXTURE_H
#define MVO_SHARED_FRAME_FIXTURE_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    int descriptors[2];
    uint8_t *maps[2];
    size_t size;
} MVOFrameFixturePool;
int mvo_fixture_pool(MVOFrameFixturePool *pool, size_t size, int readonly);
void mvo_fixture_clear(MVOFrameFixturePool *pool);
int mvo_fixture_send(int socket, const uint8_t *bytes, size_t size,
                     const int *descriptors, size_t count);
int mvo_fixture_check(const uint8_t *bytes, size_t count, unsigned slot,
                      size_t width, size_t height, size_t stride);
#endif
