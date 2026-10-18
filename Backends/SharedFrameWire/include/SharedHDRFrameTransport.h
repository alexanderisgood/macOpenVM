// SPDX-License-Identifier: Apache-2.0
#ifndef MVO_SHARED_HDR_FRAME_TRANSPORT_H
#define MVO_SHARED_HDR_FRAME_TRANSPORT_H
#include "SharedHDRFrameWire.h"
#ifdef __cplusplus
extern "C" {
#endif
enum { MVO_HDR_CONTROL_BYTES=96, MVO_HDR_OFFER=1, MVO_HDR_ACCEPT=2, MVO_HDR_READY=3 };
typedef struct {
    uint32_t kind;
    uint8_t negotiation_id[16];
    MVOHDRLimits limits;
} MVOHDRControl;
/* Closed host-only profile: FP16 LE, linear709/D65 absolute80, opaque;
 * dedicated read-only slots, exact ACK, frozen borrow and typed generations.
 * No source authority, guest display capability, FD custody or GPU fence proof. */
MVOHDRResult mvo_hdr_control_encode(const MVOHDRControl *,void *,size_t);
MVOHDRResult mvo_hdr_control_decode(const void *,size_t,MVOHDRControl *);
MVOHDRResult mvo_hdr_control_select(const MVOHDRControl *offer,uint32_t actual_page_bytes,
                                  uint32_t actual_minimum_alignment,uint64_t actual_buffer_limit,
                                  MVOHDRControl *accept);
MVOHDRResult mvo_hdr_control_validate_selection(const MVOHDRControl *offer,const MVOHDRControl *accept);
MVOHDRResult mvo_hdr_control_validate_ready(const MVOHDRControl *accept,const MVOHDRControl *ready);

/* New receiver; the v1 80-byte receive structure is untouched. The adapter
 * sets96/control or128/data only BETWEEN records. Rights are accepted only
 * on the first fragment and then only when allow_rights is true. Packet kind
 * and exactly-two-ATTACH-vs-zero-other FDs are checked by the protocol owner. */
typedef struct {
    uint8_t bytes[MVO_HDR_PACKET_BYTES];
    size_t used, expected_bytes, descriptor_count;
    int descriptors[2];
    bool allow_rights;
} MVOHDRReceive;
int mvo_hdr_receive_init(MVOHDRReceive *,size_t expected_bytes,bool allow_rights);
void mvo_hdr_receive_clear(MVOHDRReceive *);
int mvo_hdr_receive_take_descriptor(MVOHDRReceive *,size_t);
/*1 complete,0 partial/would-block, negative errno. Error closes all received FDs. */
int mvo_hdr_receive(int socket,MVOHDRReceive *);
/* Darwin kernel-retained POSIX-shm names distinguish backing objects; dup() of
 * one object has the same immutable name. Reject missing/equal names. A pair
 * of fresh synthetic UUIDs or fstat's zero shm inode is NOT this proof.
 * Also requires shm_open(retainedName) to fail ENOENT: Darwin's zero nlink
 * does not establish unlink. This cannot prove no writable aliases exist. */
int mvo_hdr_readonly_slots_distinct(int first,int second,uint64_t bytes);
#ifdef __cplusplus
}
#endif
#endif
