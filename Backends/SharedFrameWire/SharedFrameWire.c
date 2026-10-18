// SPDX-License-Identifier: Apache-2.0
#include "SharedFrameWire.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static uint64_t get_le(const uint8_t *p, unsigned n) {
    uint64_t value=0;
    for(unsigned i=0;i<n;i++) value|=(uint64_t)p[i]<<(i*8);
    return value;
}
static void put_le(uint8_t *p,uint64_t value,unsigned n) {
    for(unsigned i=0;i<n;i++) p[i]=(uint8_t)(value>>(i*8));
}
void mvo_sf_encode(const MVOSharedFrameHeader *h,uint8_t b[MVO_SF_BYTES]) {
    memset(b,0,MVO_SF_BYTES);put_le(b,0x534f564d,4);put_le(b+4,1,2);put_le(b+6,h->kind,2);
    memcpy(b+8,h->epoch,16);put_le(b+24,h->sequence,8);put_le(b+32,h->generation,8);
    put_le(b+40,h->width,4);put_le(b+44,h->height,4);put_le(b+48,h->row_bytes,4);
    put_le(b+52,h->mapped_bytes,4);put_le(b+56,h->slot,4);put_le(b+60,h->format,4);
    put_le(b+64,h->sent_ns,8);
}
int mvo_sf_decode(const uint8_t b[MVO_SF_BYTES],MVOSharedFrameHeader *h) {
    if(get_le(b,4)!=0x534f564d || get_le(b+4,2)!=1 || get_le(b+72,8)!=0) return 0;
    unsigned kind=(unsigned)get_le(b+6,2);
    if(kind<MVO_SF_READY || kind>MVO_SF_REQUEST) return 0;
    memset(h,0,sizeof *h);h->kind=kind;memcpy(h->epoch,b+8,16);
    h->sequence=get_le(b+24,8);h->generation=get_le(b+32,8);
    h->width=(uint32_t)get_le(b+40,4);h->height=(uint32_t)get_le(b+44,4);
    h->row_bytes=(uint32_t)get_le(b+48,4);h->mapped_bytes=(uint32_t)get_le(b+52,4);
    h->slot=(uint32_t)get_le(b+56,4);h->format=(uint32_t)get_le(b+60,4);
    h->sent_ns=get_le(b+64,8);return 1;
}
void mvo_sf_receive_init(MVOSharedFrameReceive *s) {
    memset(s,0,sizeof *s);s->descriptors[0]=s->descriptors[1]=-1;
}
void mvo_sf_receive_clear(MVOSharedFrameReceive *s) {
    for(size_t i=0;i<2;i++) if(s->descriptors[i]>=0) close(s->descriptors[i]);
    mvo_sf_receive_init(s);
}
int mvo_sf_take_descriptor(MVOSharedFrameReceive *s,size_t index) {
    if(index>=s->descriptor_count || index>=2) return -1;
    int result=s->descriptors[index];s->descriptors[index]=-1;return result;
}
int mvo_sf_receive(int fd,MVOSharedFrameReceive *s) {
    if(s->used>=MVO_SF_BYTES) return -EINVAL;
    union { struct cmsghdr align; uint8_t bytes[CMSG_SPACE(16*sizeof(int))]; } control;
    struct iovec io={s->bytes+s->used,MVO_SF_BYTES-s->used};
    struct msghdr message={0};memset(&control,0,sizeof control);
    message.msg_iov=&io;message.msg_iovlen=1;
    message.msg_control=control.bytes;message.msg_controllen=sizeof control;
    ssize_t count=recvmsg(fd,&message,MSG_DONTWAIT);
    if(count<0) {
        if(errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK) return 0;
        int error=errno;mvo_sf_receive_clear(s);return -error;
    }
    if(!count) { mvo_sf_receive_clear(s);return -ECONNRESET; }
    int received[16];size_t number=0;int invalid=0;
    for(struct cmsghdr *c=CMSG_FIRSTHDR(&message);c;c=CMSG_NXTHDR(&message,c)) {
        if((uint8_t *)c<control.bytes || (uint8_t *)c>control.bytes+message.msg_controllen ||
            (size_t)(control.bytes+message.msg_controllen-(uint8_t *)c)<sizeof *c ||
            c->cmsg_len>(size_t)(control.bytes+message.msg_controllen-(uint8_t *)c)) {
            invalid=1;break;
        }
        if(c->cmsg_len<CMSG_LEN(0) || c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS) {
            invalid=1;continue;
        }
        size_t bytes=c->cmsg_len-CMSG_LEN(0);
        if(bytes%sizeof(int)) invalid=1;
        size_t n=bytes/sizeof(int);
        for(size_t i=0;i<n;i++) {
            int value;memcpy(&value,(uint8_t *)CMSG_DATA(c)+i*sizeof(int),sizeof value);
            if(number<16) received[number++]=value;else { close(value);invalid=1; }
        }
    }
    if(message.msg_flags&(MSG_TRUNC|MSG_CTRUNC)) invalid=1;
    if(number && (s->used || s->descriptor_count || number>2)) invalid=1;
    for(size_t i=0;!invalid && i<number;i++) {
        if(fcntl(received[i],F_SETFD,FD_CLOEXEC)<0) invalid=1;
    }
    if(invalid) {
        for(size_t i=0;i<number;i++) close(received[i]);
        mvo_sf_receive_clear(s);return -EPROTO;
    }
    for(size_t i=0;i<number;i++) s->descriptors[s->descriptor_count++]=received[i];
    s->used+=(size_t)count;
    return s->used==MVO_SF_BYTES?1:0;
}
int mvo_sf_is_readonly_shared_memory(int fd,uint64_t bytes) {
    struct pshm_fdinfo info;
    memset(&info,0,sizeof info);
    int flags=fcntl(fd,F_GETFL);
    if(flags<0 || (flags&O_ACCMODE)!=O_RDONLY) return 0;
    int count=proc_pidfdinfo(getpid(),fd,PROC_PIDFDPSHMINFO,&info,sizeof info);
    return count==(int)sizeof info && info.pshminfo.pshm_stat.vst_size==bytes &&
        info.pshminfo.pshm_stat.vst_uid==geteuid() &&
        info.pshminfo.pshm_stat.vst_nlink==0;
}
