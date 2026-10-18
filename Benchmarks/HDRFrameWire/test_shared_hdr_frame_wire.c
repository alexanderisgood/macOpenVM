// SPDX-License-Identifier: Apache-2.0
#include "SharedHDRFrameWire.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long assertions;
#define CHECK(v) do { assertions++; if (!(v)) { \
    fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #v); exit(1); } } while (0)
static const MVOHDRLimits limits = {4096, 256, MVO_HDR_MAX_MAPPING_BYTES};
static const uint8_t epoch[16] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
static MVOHDRDescriptor descriptor(void)
{
    MVOHDRDescriptor d = {0};
    d.resource_id = 10; d.resource_incarnation = 20; d.color_generation = 30;
    d.scanout_generation = 40; d.width = 32; d.height = 2; d.row_bytes = 256;
    d.mapped_bytes = 4096; d.pixel_format = MVO_HDR_RGBA16_FLOAT_LE;
    d.color_encoding = MVO_HDR_LINEAR_709_D65_ABSOLUTE_80;
    d.optical_scale_millinit = MVO_HDR_OPTICAL_SCALE_MILLINIT; return d;
}
static MVOHDRHeader frame(void)
{
    MVOHDRHeader h = {0}; memcpy(h.epoch, epoch, 16); h.kind = MVO_HDR_FRAME;
    h.sequence = 7; h.content_generation = 9; h.sent_ns = 100;
    h.descriptor = descriptor(); return h;
}
static void put(uint8_t *p, uint64_t value, unsigned bytes)
{
    for (unsigned i = 0; i < bytes; i++) p[i] = (uint8_t)(value >> (i * 8));
}
static void test_golden_wire(void)
{
    uint8_t bytes[128], expected[128] = {'M','V','H','2',2,0,3,0}, ack[128];
    memcpy(expected + 8, epoch, 16);
    put(expected+24,7,8); put(expected+32,9,8); put(expected+40,20,8);
    put(expected+48,30,8); put(expected+56,40,8); put(expected+64,10,4);
    put(expected+72,32,4); put(expected+76,2,4); put(expected+80,256,4);
    put(expected+84,4096,4); put(expected+92,2,4); put(expected+96,1,4);
    put(expected+100,80000,4); put(expected+104,100,8);
    MVOHDRHeader h = frame(), decoded;
    CHECK(mvo_hdr_encode(&h,&limits,bytes,sizeof bytes)==MVO_HDR_OK);
    CHECK(!memcmp(bytes,expected,sizeof bytes));
    CHECK(mvo_hdr_decode(bytes,sizeof bytes,&limits,&decoded)==MVO_HDR_OK);
    CHECK(mvo_hdr_encode(&decoded,&limits,ack,sizeof ack)==MVO_HDR_OK);
    CHECK(!memcmp(bytes,ack,sizeof bytes));
    CHECK(mvo_hdr_make_ack(bytes,sizeof bytes,&limits,ack,sizeof ack)==MVO_HDR_OK);
    expected[6]=4; CHECK(!memcmp(ack,expected,sizeof ack));
    CHECK(mvo_hdr_make_ack(bytes,sizeof bytes,&limits,bytes,sizeof bytes)==MVO_HDR_OK);
    CHECK(!memcmp(bytes,expected,sizeof bytes));
    CHECK(mvo_hdr_make_ack(ack,sizeof ack,&limits,bytes,sizeof bytes)==MVO_HDR_STATE);
    MVOHDRHeader request={0};memcpy(request.epoch,epoch,16);request.kind=MVO_HDR_REQUEST;
    CHECK(mvo_hdr_encode(&request,&limits,bytes,sizeof bytes)==MVO_HDR_OK);
    CHECK(mvo_hdr_decode(bytes,sizeof bytes,&limits,&decoded)==MVO_HDR_OK);
    request.descriptor.resource_id=1;
    CHECK(mvo_hdr_encode(&request,&limits,bytes,sizeof bytes)==MVO_HDR_WIRE);
}
static void test_malformed_wire(void)
{
    uint8_t bytes[129], bad[129]; MVOHDRHeader h=frame(), decoded=frame();
    CHECK(mvo_hdr_encode(&h,&limits,bytes,128)==MVO_HDR_OK);
    for(size_t n=0;n<128;n++) CHECK(mvo_hdr_decode(bytes,n,&limits,&decoded)!=MVO_HDR_OK);
    CHECK(mvo_hdr_decode(bytes,129,&limits,&decoded)!=MVO_HDR_OK);
    const unsigned unsupported[]={4,6,92,96,100};
    for(size_t i=0;i<sizeof unsupported/sizeof unsupported[0];i++) {
        memcpy(bad,bytes,128);bad[unsupported[i]]^=0x40;
        MVOHDRHeader before=decoded;
        CHECK(mvo_hdr_decode(bad,128,&limits,&decoded)!=MVO_HDR_OK);
        CHECK(!memcmp(&decoded,&before,sizeof before));
    }
    for(unsigned i=120;i<128;i++) {
        memcpy(bad,bytes,128);bad[i]=1;
        CHECK(mvo_hdr_decode(bad,128,&limits,&decoded)==MVO_HDR_WIRE);
    }
    const unsigned generations[]={24,32,40,48,56,104};
    for(size_t i=0;i<sizeof generations/sizeof generations[0];i++) {
        memcpy(bad,bytes,128);memset(bad+generations[i],0,8);
        CHECK(mvo_hdr_decode(bad,128,&limits,&decoded)!=MVO_HDR_OK);
    }
    memcpy(bad,bytes,128);memset(bad+8,0,16);
    CHECK(mvo_hdr_decode(bad,128,&limits,&decoded)!=MVO_HDR_OK);
    memcpy(bad,bytes,128);bad[88]=1;
    CHECK(mvo_hdr_decode(bad,128,&limits,&decoded)==MVO_HDR_WIRE);
    memset(bad,0,sizeof bad);memcpy(bad,"MVOS",4);bad[4]=1;
    CHECK(mvo_hdr_decode(bad,80,&limits,&decoded)!=MVO_HDR_OK);
    CHECK(mvo_hdr_decode(bad,128,&limits,&decoded)==MVO_HDR_WIRE);
    memset(bad,0xa5,sizeof bad);h.descriptor.pixel_format=1;
    CHECK(mvo_hdr_encode(&h,&limits,bad,128)==MVO_HDR_UNSUPPORTED);
    for(unsigned i=0;i<sizeof bad;i++)CHECK(bad[i]==0xa5);
}
static void test_bounds(void)
{
    MVOHDRDescriptor d=descriptor();CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_OK);
    d.width=3840;d.height=2160;d.row_bytes=30720;d.mapped_bytes=66355200;
    CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_OK);
    d.width=4096;d.row_bytes=32768;d.mapped_bytes=70778880;
    CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_BOUNDS);
    d.width=8192;d.height=1024;d.row_bytes=65536;d.mapped_bytes=67108864;
    CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_OK);
    d.height++;d.mapped_bytes+=65536;
    CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_BOUNDS);
    d=descriptor();d.width=UINT32_MAX;d.height=UINT32_MAX;d.row_bytes=UINT32_MAX;
    CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_BOUNDS);
    d=descriptor();d.row_bytes=255;CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_BOUNDS);
    d=descriptor();d.row_bytes=256+4096+256;CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_BOUNDS);
    d=descriptor();d.mapped_bytes=4095;CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_BOUNDS);
    d=descriptor();d.mapped_bytes=8192;CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_BOUNDS);
    MVOHDRLimits l=limits;l.maximum_mapping_bytes++;
    CHECK(mvo_hdr_validate_descriptor(&d,&l)==MVO_HDR_INVALID);
    l=limits;l.row_alignment=300;CHECK(mvo_hdr_validate_descriptor(&d,&l)==MVO_HDR_INVALID);
    l=limits;l.page_bytes=0;CHECK(mvo_hdr_validate_descriptor(&d,&l)==MVO_HDR_INVALID);
    l=limits;l.page_bytes=65536;d.mapped_bytes=65536;
    CHECK(mvo_hdr_validate_descriptor(&d,&l)==MVO_HDR_OK);
    d=descriptor();d.resource_incarnation=0;CHECK(mvo_hdr_validate_descriptor(&d,&limits)==MVO_HDR_INVALID);
}
static MVOHDRResult request(MVOHDRSlots *s)
{
    MVOHDRHeader h = {0}; uint8_t bytes[128];
    memcpy(h.epoch, s->epoch, 16); h.kind = MVO_HDR_REQUEST;
    CHECK(mvo_hdr_encode(&h, &limits, bytes, sizeof bytes) == MVO_HDR_OK);
    return mvo_hdr_slots_request(s, bytes, sizeof bytes);
}
typedef struct { MVOHDRSlots state; uint8_t a[4096],b[4096],source[512]; } Fixture;
static void start(Fixture *f)
{
    memset(f,0,sizeof *f); MVOHDRDescriptor d=descriptor();uint8_t packet[128],ack[128];
    CHECK(mvo_hdr_slots_init(&f->state,epoch,&d,&limits,f->a,sizeof f->a,f->b,sizeof f->b)==MVO_HDR_OK);
    CHECK(request(&f->state)==MVO_HDR_STATE);
    CHECK(mvo_hdr_slots_attach(&f->state,packet,sizeof packet)==MVO_HDR_OK);
    CHECK(mvo_hdr_make_ack(packet,sizeof packet,&limits,ack,sizeof ack)==MVO_HDR_OK);
    uint8_t bad[128];memcpy(bad,ack,128);bad[8]^=1;
    CHECK(mvo_hdr_slots_ack(&f->state,bad,128)==MVO_HDR_ACK_MISMATCH);
    CHECK(!f->state.attached && f->state.waiting_ack);
    CHECK(mvo_hdr_slots_ack(&f->state,ack,sizeof ack)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_ack(&f->state,ack,sizeof ack)==MVO_HDR_STATE);
    CHECK(mvo_hdr_slots_attach(&f->state,packet,sizeof packet)==MVO_HDR_STATE);
}
static void write_rows(Fixture *f,const MVOHDRDescriptor *d,uint64_t generation,uint8_t value)
{
    memset(f->source,value,sizeof f->source);
    CHECK(mvo_hdr_slots_write_rows(&f->state,d,generation,f->source,sizeof f->source,256)==MVO_HDR_OK);
}
static void test_bits_and_ownership(void)
{
    Fixture f;start(&f);MVOHDRDescriptor d=descriptor();uint8_t packet[128],ack[128],frozen[4096];
    /* Signed zero/subnormal, -1, -0.25,1,2.5,12.5, and a NaN payload. The wire
     * transports bits, so it must not introduce FP conversion or sanitize. */
    const uint16_t bits[]={0x8000,0x0001,0xbc00,0xb400,0x3c00,0x4100,0x4a40,0x7e01};
    for(size_t i=0;i<sizeof f.source;i+=2) {
        uint16_t v=bits[(i/2)%(sizeof bits/sizeof bits[0])];f.source[i]=(uint8_t)v;f.source[i+1]=(uint8_t)(v>>8);
    }
    CHECK(mvo_hdr_slots_write_rows(&f.state,&d,1,f.source,sizeof f.source,256)==MVO_HDR_OK);
    CHECK(!memcmp(f.a,f.source,sizeof f.source));
    for(size_t i=sizeof f.source;i<sizeof f.a;i++)CHECK(f.a[i]==0);
    CHECK(request(&f.state)==MVO_HDR_OK);
    CHECK(request(&f.state)==MVO_HDR_BUSY);
    CHECK(mvo_hdr_slots_publish(&f.state,1,packet,sizeof packet)==MVO_HDR_OK);
    memcpy(frozen,f.a,sizeof frozen);
    CHECK(request(&f.state)==MVO_HDR_BUSY);
    write_rows(&f,&d,2,0x22);write_rows(&f,&d,3,0x33);
    CHECK(!memcmp(f.a,frozen,sizeof frozen));CHECK(f.b[0]==0x33);
    CHECK(mvo_hdr_make_ack(packet,sizeof packet,&limits,ack,sizeof ack)==MVO_HDR_OK);
    for(unsigned i=0;i<128;i++) {
        uint8_t bad[128];memcpy(bad,ack,128);bad[i]^=1;MVOHDRSlots before=f.state;
        CHECK(mvo_hdr_slots_ack(&f.state,bad,sizeof bad)!=MVO_HDR_OK);
        CHECK(!memcmp(&f.state,&before,sizeof before));CHECK(!memcmp(f.a,frozen,sizeof frozen));
    }
    CHECK(mvo_hdr_slots_ack(&f.state,ack,sizeof ack)==MVO_HDR_OK);
    CHECK(request(&f.state)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_publish(&f.state,2,packet,sizeof packet)==MVO_HDR_OK);
    MVOHDRHeader h;CHECK(mvo_hdr_decode(packet,sizeof packet,&limits,&h)==MVO_HDR_OK);
    CHECK(h.slot==1 && h.sequence==2 && h.content_generation==3);
    CHECK(mvo_hdr_slots_ack(&f.state,ack,128)==MVO_HDR_ACK_MISMATCH);
    memcpy(frozen,f.b,sizeof frozen);write_rows(&f,&d,4,0x44);
    CHECK(!memcmp(f.b,frozen,sizeof frozen));CHECK(f.a[0]==0x44);
    CHECK(mvo_hdr_slots_retire(&f.state)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_write_rows(&f.state,&d,5,f.source,sizeof f.source,256)==MVO_HDR_RETIRED);
    CHECK(request(&f.state)==MVO_HDR_RETIRED);
    CHECK(mvo_hdr_slots_ack(&f.state,ack,sizeof ack)==MVO_HDR_RETIRED);
    CHECK(!memcmp(f.b,frozen,sizeof frozen));
    CHECK(mvo_hdr_slots_init(&f.state,epoch,&d,&limits,f.a,sizeof f.a,f.b,sizeof f.b)==MVO_HDR_STATE);
}
static bool partial_failure(void *opaque,uint8_t *target,size_t count,const MVOHDRDescriptor *d)
{
    (void)opaque;(void)d;memset(target,0x5a,count/2);return false;
}
static void test_identity_and_failures(void)
{
    Fixture f;start(&f);MVOHDRDescriptor d=descriptor(),changed=d;uint8_t packet[128];
    MVOHDRHeader wrong_request={0};memcpy(wrong_request.epoch,epoch,16);
    wrong_request.kind=MVO_HDR_REQUEST;wrong_request.epoch[0]^=1;
    CHECK(mvo_hdr_encode(&wrong_request,&limits,packet,128)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_request(&f.state,packet,128)==MVO_HDR_WIRE);
    CHECK(!f.state.requested);
    write_rows(&f,&d,1,1);
    changed.resource_id++;
    CHECK(mvo_hdr_slots_write_rows(&f.state,&changed,2,f.source,sizeof f.source,256)==MVO_HDR_STALE);
    changed.scanout_generation++;
    CHECK(mvo_hdr_slots_write_rows(&f.state,&changed,2,f.source,sizeof f.source,256)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_write_rows(&f.state,&d,3,f.source,sizeof f.source,256)==MVO_HDR_STALE);
    CHECK(mvo_hdr_slots_write_rows(&f.state,&changed,2,f.source,sizeof f.source,256)==MVO_HDR_STALE);
    CHECK(mvo_hdr_slots_write_rows(&f.state,&changed,3,f.source,511,256)==MVO_HDR_BOUNDS);
    CHECK(mvo_hdr_slots_write_rows(&f.state,&changed,3,f.a,sizeof f.a,256)==MVO_HDR_BOUNDS);
    CHECK(request(&f.state)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_write(&f.state,&changed,3,partial_failure,NULL)==MVO_HDR_COPY_FAILED);
    CHECK(mvo_hdr_slots_publish(&f.state,1,packet,sizeof packet)==MVO_HDR_EMPTY);
    write_rows(&f,&changed,3,3);
    CHECK(mvo_hdr_slots_publish(&f.state,1,f.a,128)==MVO_HDR_INVALID);
    CHECK(mvo_hdr_slots_publish(&f.state,1,packet,sizeof packet)==MVO_HDR_OK);
    uint8_t ack[128];CHECK(mvo_hdr_make_ack(packet,128,&limits,ack,128)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_ack(&f.state,ack,128)==MVO_HDR_OK);
    write_rows(&f,&changed,UINT64_MAX,4);
    CHECK(mvo_hdr_slots_write_rows(&f.state,&changed,1,f.source,sizeof f.source,256)==MVO_HDR_OVERFLOW);
    CHECK(request(&f.state)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_publish(&f.state,1,packet,128)==MVO_HDR_STALE);
    f.state.sequence=UINT64_MAX; /* Reach an otherwise2^64-operation boundary. */
    CHECK(mvo_hdr_slots_publish(&f.state,2,packet,128)==MVO_HDR_OVERFLOW);
}
static bool reentrant_writer(void *opaque,uint8_t *target,size_t count,const MVOHDRDescriptor *d)
{
    Fixture *f=opaque;uint8_t packet[128];
    CHECK(request(&f->state)==MVO_HDR_BUSY);
    CHECK(mvo_hdr_slots_publish(&f->state,1,packet,128)==MVO_HDR_BUSY);
    CHECK(mvo_hdr_slots_retire(&f->state)==MVO_HDR_BUSY);
    CHECK(mvo_hdr_slots_write_rows(&f->state,d,2,f->source,sizeof f->source,256)==MVO_HDR_BUSY);
    memset(target,0x7d,count);return true;
}
static void test_pool_and_writer_admission(void)
{
    Fixture f;memset(&f,0,sizeof f);MVOHDRDescriptor d=descriptor();uint8_t zero_epoch[16]={0};
    memset(f.a,0xac,sizeof f.a);
    CHECK(mvo_hdr_slots_init(&f.state,zero_epoch,&d,&limits,f.a,sizeof f.a,f.b,sizeof f.b)==MVO_HDR_INVALID);
    CHECK(mvo_hdr_slots_init(&f.state,epoch,&d,&limits,f.a,sizeof f.a,f.a,sizeof f.a)==MVO_HDR_BOUNDS);
    CHECK(mvo_hdr_slots_init(&f.state,epoch,&d,&limits,f.a,sizeof f.a-1,f.b,sizeof f.b)==MVO_HDR_BOUNDS);
    CHECK(!f.state.initialized && f.a[0]==0xac);
    start(&f);CHECK(request(&f.state)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_publish(&f.state,1,NULL,128)==MVO_HDR_EMPTY);
    CHECK(mvo_hdr_slots_write(&f.state,&d,1,reentrant_writer,&f)==MVO_HDR_OK);
    uint8_t packet[128];CHECK(mvo_hdr_slots_publish(&f.state,1,packet,128)==MVO_HDR_OK);
    for(size_t i=0;i<sizeof f.a;i++)CHECK(f.a[i]==0x7d);
}
static void test_meaning_transitions(void)
{
    Fixture fixtures[5];uint8_t packet[128];
    for(unsigned i=0;i<5;i++) {
        Fixture *f=&fixtures[i];start(f);MVOHDRDescriptor current=descriptor(),next=current;
        write_rows(f,&current,1,0x18);CHECK(request(&f->state)==MVO_HDR_OK);
        switch(i) {
        case 0:next.color_generation++;break;
        case 1:next.target_id++;break;
        case 2:next.width=31;break; /* Same bytes/alignment, different geometry. */
        case 3:next.color_encoding=99;break;
        default:next.optical_scale_millinit=100000;break;
        }
        CHECK(mvo_hdr_slots_write_rows(&f->state,&next,2,f->source,sizeof f->source,256)==MVO_HDR_RETIRED);
        CHECK(f->state.retired && !f->state.latest && !f->state.requested);
        CHECK(mvo_hdr_slots_publish(&f->state,1,packet,128)==MVO_HDR_RETIRED);
        CHECK(mvo_hdr_slots_write_rows(&f->state,&current,2,f->source,sizeof f->source,256)==MVO_HDR_RETIRED);
    }
    Fixture stale;start(&stale);MVOHDRDescriptor d=descriptor(),older=d;
    write_rows(&stale,&d,1,0x24);CHECK(request(&stale.state)==MVO_HDR_OK);older.color_generation--;
    CHECK(mvo_hdr_slots_write_rows(&stale.state,&older,2,stale.source,sizeof stale.source,256)==MVO_HDR_STALE);
    MVOHDRSlots before=stale.state;
    older=d;older.scanout_generation--;older.color_encoding=99;
    CHECK(mvo_hdr_slots_write_rows(&stale.state,&older,2,stale.source,sizeof stale.source,256)==MVO_HDR_STALE);
    CHECK(!memcmp(&before,&stale.state,sizeof before));
    older=d;older.scanout_generation--;older.target_id++;
    CHECK(mvo_hdr_slots_write_rows(&stale.state,&older,2,stale.source,sizeof stale.source,256)==MVO_HDR_STALE);
    CHECK(!memcmp(&before,&stale.state,sizeof before));
    CHECK(mvo_hdr_slots_publish(&stale.state,1,packet,128)==MVO_HDR_OK);
    uint8_t frozen[4096];memcpy(frozen,stale.a,sizeof frozen);before=stale.state;
    CHECK(mvo_hdr_slots_write_rows(&stale.state,&older,2,stale.source,sizeof stale.source,256)==MVO_HDR_STALE);
    CHECK(!memcmp(&before,&stale.state,sizeof before));CHECK(!memcmp(frozen,stale.a,sizeof frozen));
    d.color_generation++;
    CHECK(mvo_hdr_slots_write_rows(&stale.state,&d,2,stale.source,sizeof stale.source,256)==MVO_HDR_RETIRED);
    CHECK(!memcmp(frozen,stale.a,sizeof frozen)); /* Retiring cannot overwrite an old borrow. */
    Fixture missing_writer;start(&missing_writer);d=descriptor();
    write_rows(&missing_writer,&d,1,0x34);CHECK(request(&missing_writer.state)==MVO_HDR_OK);
    CHECK(mvo_hdr_slots_write(&missing_writer.state,&d,2,NULL,NULL)==MVO_HDR_INVALID);
    CHECK(mvo_hdr_slots_publish(&missing_writer.state,1,packet,128)==MVO_HDR_EMPTY);
}
static uint32_t random_next(uint32_t *x) { *x=*x*UINT32_C(1664525)+UINT32_C(1013904223);return *x; }
static void test_randomized_ownership(void)
{
    Fixture f;start(&f);MVOHDRDescriptor d=descriptor();uint8_t frame_bytes[128],ack[128],frozen[4096];
    bool borrowed=false,requested=false,latest=false;unsigned borrowed_slot=0;uint64_t gen=0,seq=0;
    uint32_t random=UINT32_C(0xa16f0080);
    for(unsigned step=0;step<20000;step++) {
        switch(random_next(&random)%6) {
        case 0:
            if(random_next(&random)&1) {d.resource_id=d.resource_id==12?10:d.resource_id+1;d.resource_incarnation=d.resource_id+10;d.scanout_generation++;}
            gen++;write_rows(&f,&d,gen,(uint8_t)gen);latest=true;break;
        case 1: {
            MVOHDRResult result=request(&f.state);
            CHECK(result==((borrowed||requested)?MVO_HDR_BUSY:MVO_HDR_OK));
            if(result==MVO_HDR_OK)requested=true;break;
        }
        case 2: {
            MVOHDRResult result=mvo_hdr_slots_publish(&f.state,(uint64_t)step+1,frame_bytes,128);
            MVOHDRResult expected=!requested?MVO_HDR_STATE:borrowed?MVO_HDR_BUSY:!latest?MVO_HDR_EMPTY:MVO_HDR_OK;
            CHECK(result==expected);
            if(result==MVO_HDR_OK) {
                MVOHDRHeader h;CHECK(mvo_hdr_decode(frame_bytes,128,&limits,&h)==MVO_HDR_OK);
                CHECK(h.sequence==++seq && h.slot==(seq-1)%2 && h.content_generation==gen);
                borrowed=true;requested=latest=false;borrowed_slot=h.slot;
                memcpy(frozen,borrowed_slot?f.b:f.a,sizeof frozen);
                CHECK(mvo_hdr_make_ack(frame_bytes,128,&limits,ack,128)==MVO_HDR_OK);
            }break;
        }
        case 3:
            if(borrowed){CHECK(mvo_hdr_slots_ack(&f.state,ack,128)==MVO_HDR_OK);borrowed=false;}break;
        case 4:
            if(borrowed){uint8_t bad[128];memcpy(bad,ack,128);bad[random_next(&random)%128]^=1;CHECK(mvo_hdr_slots_ack(&f.state,bad,128)!=MVO_HDR_OK);}break;
        default:
            CHECK(mvo_hdr_slots_write(&f.state,&d,gen+1,partial_failure,NULL)==MVO_HDR_COPY_FAILED);latest=false;break;
        }
        if(borrowed)CHECK(!memcmp(frozen,borrowed_slot?f.b:f.a,sizeof frozen));
        CHECK(f.state.waiting_ack==borrowed && f.state.requested==requested && f.state.latest==latest);
    }
}
int main(void)
{
    test_golden_wire();test_malformed_wire();test_bounds();test_bits_and_ownership();
    test_identity_and_failures();test_pool_and_writer_admission();test_meaning_transitions();test_randomized_ownership();
    printf("{\"groups\":8,\"randomized_operations\":20000,\"assertions\":%lu,\"passed\":true}\n",assertions);
    return 0;
}
