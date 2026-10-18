// SPDX-License-Identifier: Apache-2.0
#ifndef MVO_SHARED_FRAME_WIRE_H
#define MVO_SHARED_FRAME_WIRE_H
#include <stddef.h>
#include <stdint.h>

enum { MVO_SF_BYTES=80, MVO_SF_READY=1, MVO_SF_ATTACH=2,
       MVO_SF_FRAME=3, MVO_SF_ACK=4, MVO_SF_REQUEST=5 };
typedef struct {
    uint32_t kind;
    uint8_t epoch[16];
    uint64_t sequence, generation;
    uint32_t width, height, row_bytes, mapped_bytes, slot, format;
    uint64_t sent_ns;
} MVOSharedFrameHeader;
typedef struct {
    uint8_t bytes[MVO_SF_BYTES];
    size_t used;
    int descriptors[2];
    size_t descriptor_count;
} MVOSharedFrameReceive;

// All functions are synchronous; no pointer to a caller allocation escapes.
void mvo_sf_encode(const MVOSharedFrameHeader *header, uint8_t bytes[MVO_SF_BYTES]);
int mvo_sf_decode(const uint8_t bytes[MVO_SF_BYTES], MVOSharedFrameHeader *header);
void mvo_sf_receive_init(MVOSharedFrameReceive *state);
//1 complete,0 would-block/partial, negative errno. Errors close received FDs.
int mvo_sf_receive(int socket, MVOSharedFrameReceive *state);
int mvo_sf_take_descriptor(MVOSharedFrameReceive *state, size_t index);
void mvo_sf_receive_clear(MVOSharedFrameReceive *state);
// Kernel classification of this exact owned FD, not PID-based process control.
int mvo_sf_is_readonly_shared_memory(int descriptor, uint64_t bytes);
#endif
