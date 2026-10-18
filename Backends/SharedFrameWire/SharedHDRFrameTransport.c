// SPDX-License-Identifier: Apache-2.0
#include "SharedHDRFrameTransport.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#endif
static uint64_t rd(const uint8_t *p,unsigned n) { uint64_t v=0;for(unsigned i=0;i<n;i++)v|=(uint64_t)p[i]<<(8*i);return v; }
static void wr(uint8_t *p,uint64_t v,unsigned n) { for(unsigned i=0;i<n;i++)p[i]=(uint8_t)(v>>(8*i)); }
static bool nz(const uint8_t p[16]) { uint8_t v=0;for(unsigned i=0;i<16;i++)v|=p[i];return v!=0; }
static bool pow2(uint32_t v) { return v && !(v&(v-1)); }
static MVOHDRResult valid(const MVOHDRControl *c) {
    if(!c || !nz(c->negotiation_id) || c->kind<MVO_HDR_OFFER || c->kind>MVO_HDR_READY) return MVO_HDR_INVALID;
    MVOHDRDescriptor d={0};d.resource_id=1;d.resource_incarnation=1;d.color_generation=1;d.scanout_generation=1;
    d.width=d.height=1;d.row_bytes=c->limits.row_alignment;d.mapped_bytes=c->limits.page_bytes;
    d.pixel_format=MVO_HDR_RGBA16_FLOAT_LE;d.color_encoding=MVO_HDR_LINEAR_709_D65_ABSOLUTE_80;
    d.optical_scale_millinit=MVO_HDR_OPTICAL_SCALE_MILLINIT;
    MVOHDRResult r=mvo_hdr_validate_descriptor(&d,&c->limits);
    if(r!=MVO_HDR_OK) return r;
    return c->kind==MVO_HDR_OFFER && c->limits.row_alignment!=256?MVO_HDR_UNSUPPORTED:MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_control_encode(const MVOHDRControl *c,void *out,size_t count) {
    if(!out || count!=MVO_HDR_CONTROL_BYTES) return MVO_HDR_INVALID;
    MVOHDRResult r=valid(c);if(r!=MVO_HDR_OK)return r;
    uint8_t b[MVO_HDR_CONTROL_BYTES]={0};wr(b,UINT32_C(0x324e564d),4);wr(b+4,1,2);wr(b+6,c->kind,2);
    memcpy(b+8,c->negotiation_id,16);wr(b+24,2,4);wr(b+28,128,4);wr(b+32,1,4);
    wr(b+36,c->limits.page_bytes,4);wr(b+40,c->limits.row_alignment,4);wr(b+44,c->limits.maximum_mapping_bytes,4);
    wr(b+48,15,8);wr(b+64,8192,4);wr(b+72,16777216,8);memcpy(out,b,sizeof b);return MVO_HDR_OK;
}
MVOHDRResult mvo_hdr_control_decode(const void *in,size_t count,MVOHDRControl *out) {
    if(!in || !out || count!=MVO_HDR_CONTROL_BYTES)return MVO_HDR_INVALID;
    const uint8_t *b=in;
    if(rd(b,4)!=UINT32_C(0x324e564d) || rd(b+68,4) || rd(b+80,8) || rd(b+88,8))return MVO_HDR_WIRE;
    if(rd(b+4,2)!=1 || rd(b+24,4)!=2 || rd(b+28,4)!=128 || rd(b+32,4)!=1 || rd(b+48,8)!=15 ||
       rd(b+56,8) || rd(b+64,4)!=8192 || rd(b+72,8)!=16777216)return MVO_HDR_UNSUPPORTED;
    MVOHDRControl c={0};c.kind=(uint32_t)rd(b+6,2);memcpy(c.negotiation_id,b+8,16);
    c.limits.page_bytes=(uint32_t)rd(b+36,4);c.limits.row_alignment=(uint32_t)rd(b+40,4);
    c.limits.maximum_mapping_bytes=(uint32_t)rd(b+44,4);
    MVOHDRResult r=valid(&c);if(r==MVO_HDR_OK)*out=c;return r;
}
MVOHDRResult mvo_hdr_control_validate_selection(const MVOHDRControl *offer,const MVOHDRControl *accept) {
    if(valid(offer)!=MVO_HDR_OK || valid(accept)!=MVO_HDR_OK)return MVO_HDR_INVALID;
    return offer->kind==MVO_HDR_OFFER && accept->kind==MVO_HDR_ACCEPT &&
      !memcmp(offer->negotiation_id,accept->negotiation_id,16) &&
      offer->limits.page_bytes==accept->limits.page_bytes && accept->limits.row_alignment>=offer->limits.row_alignment &&
      !(accept->limits.row_alignment%offer->limits.row_alignment) &&
      accept->limits.maximum_mapping_bytes<=offer->limits.maximum_mapping_bytes?MVO_HDR_OK:MVO_HDR_STATE;
}
MVOHDRResult mvo_hdr_control_select(const MVOHDRControl *offer,uint32_t page,uint32_t alignment,uint64_t cap,MVOHDRControl *out) {
    if(!out || valid(offer)!=MVO_HDR_OK || offer->kind!=MVO_HDR_OFFER || page!=offer->limits.page_bytes ||
       !pow2(alignment) || alignment>4096)return MVO_HDR_INVALID;
    MVOHDRControl c=*offer;c.kind=MVO_HDR_ACCEPT;c.limits.row_alignment=alignment<256?256:alignment;
    if(cap<c.limits.maximum_mapping_bytes)c.limits.maximum_mapping_bytes=(uint32_t)cap;
    MVOHDRResult r=mvo_hdr_control_validate_selection(offer,&c);if(r==MVO_HDR_OK)*out=c;return r;
}
MVOHDRResult mvo_hdr_control_validate_ready(const MVOHDRControl *accept,const MVOHDRControl *ready) {
    if(valid(accept)!=MVO_HDR_OK || valid(ready)!=MVO_HDR_OK)return MVO_HDR_INVALID;
    return accept->kind==MVO_HDR_ACCEPT && ready->kind==MVO_HDR_READY &&
      !memcmp(accept->negotiation_id,ready->negotiation_id,16) &&
      accept->limits.page_bytes==ready->limits.page_bytes && accept->limits.row_alignment==ready->limits.row_alignment &&
      accept->limits.maximum_mapping_bytes==ready->limits.maximum_mapping_bytes?MVO_HDR_OK:MVO_HDR_STATE;
}
int mvo_hdr_receive_init(MVOHDRReceive *s,size_t count,bool rights) {
    if(!s || (count!=MVO_HDR_CONTROL_BYTES && count!=MVO_HDR_PACKET_BYTES))return -EINVAL;
    memset(s,0,sizeof *s);s->descriptors[0]=s->descriptors[1]=-1;s->expected_bytes=count;s->allow_rights=rights;return 0;
}
void mvo_hdr_receive_clear(MVOHDRReceive *s) {
    if(!s)return;size_t count=s->expected_bytes;bool rights=s->allow_rights;
    for(unsigned i=0;i<2;i++)if(s->descriptors[i]>=0)close(s->descriptors[i]);
    (void)mvo_hdr_receive_init(s,count,rights);
}
int mvo_hdr_receive_take_descriptor(MVOHDRReceive *s,size_t i) {
    if(!s || i>=s->descriptor_count || i>=2)return -1;int fd=s->descriptors[i];s->descriptors[i]=-1;return fd;
}
int mvo_hdr_receive(int fd,MVOHDRReceive *s) {
    if(!s || (s->expected_bytes!=96 && s->expected_bytes!=128) || s->used>=s->expected_bytes)return -EINVAL;
    union {struct cmsghdr align;uint8_t bytes[CMSG_SPACE(16*sizeof(int))];} control;
    struct iovec io={s->bytes+s->used,s->expected_bytes-s->used};struct msghdr msg={0};memset(&control,0,sizeof control);
    msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control.bytes;msg.msg_controllen=sizeof control;
    ssize_t n=recvmsg(fd,&msg,MSG_DONTWAIT);
    if(n<0) { if(errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)return 0;int e=errno;mvo_hdr_receive_clear(s);return -e; }
    if(!n){mvo_hdr_receive_clear(s);return -ECONNRESET;}
    int fds[16];size_t number=0;bool bad=(msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC))!=0;
    for(struct cmsghdr *c=CMSG_FIRSTHDR(&msg);c;c=CMSG_NXTHDR(&msg,c)) {
      if((uint8_t *)c<control.bytes || (uint8_t *)c>control.bytes+msg.msg_controllen ||
         (size_t)(control.bytes+msg.msg_controllen-(uint8_t *)c)<sizeof *c ||
         c->cmsg_len>(size_t)(control.bytes+msg.msg_controllen-(uint8_t *)c)){bad=true;break;}
      if(c->cmsg_len<CMSG_LEN(0) || c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS){bad=true;continue;}
      size_t bytes=c->cmsg_len-CMSG_LEN(0);if(bytes%sizeof(int))bad=true;
      for(size_t i=0;i<bytes/sizeof(int);i++){int value;memcpy(&value,(uint8_t *)CMSG_DATA(c)+i*sizeof(int),sizeof value);
        if(number<16)fds[number++]=value;else{close(value);bad=true;}}
    }
    if(number && (!s->allow_rights || s->used || s->descriptor_count || number>2))bad=true;
    for(size_t i=0;!bad && i<number;i++)if(fcntl(fds[i],F_SETFD,FD_CLOEXEC)<0)bad=true;
    if(bad){for(size_t i=0;i<number;i++)close(fds[i]);mvo_hdr_receive_clear(s);return -EPROTO;}
    for(size_t i=0;i<number;i++)s->descriptors[s->descriptor_count++]=fds[i];s->used+=(size_t)n;
    return s->used==s->expected_bytes?1:0;
}
int mvo_hdr_readonly_slots_distinct(int first,int second,uint64_t bytes) {
#ifdef __APPLE__
    struct pshm_fdinfo info[2];memset(info,0,sizeof info);int fds[2]={first,second};size_t lengths[2];
    for(unsigned i=0;i<2;i++) {
      int flags=fcntl(fds[i],F_GETFL);
      if(flags<0 || (flags&O_ACCMODE)!=O_RDONLY ||
         proc_pidfdinfo(getpid(),fds[i],PROC_PIDFDPSHMINFO,&info[i],sizeof info[i])!=(int)sizeof info[i] ||
          info[i].pshminfo.pshm_stat.vst_size<=0 || (uint64_t)info[i].pshminfo.pshm_stat.vst_size!=bytes ||
          info[i].pshminfo.pshm_stat.vst_uid!=geteuid() ||
         info[i].pshminfo.pshm_stat.vst_nlink!=0 || (info[i].pshminfo.pshm_stat.vst_mode&0777)!=0600)return 0;
      lengths[i]=strnlen(info[i].pshminfo.pshm_name,sizeof info[i].pshminfo.pshm_name);
      if(!lengths[i] || lengths[i]==sizeof info[i].pshminfo.pshm_name)return 0;
      /* Darwin's reported shm nlink is zero even while named. Verify namespace
       * absence with the kernel-retained immutable object name instead. An
       * existing historical-name replacement is conservatively rejected. */
      int named=shm_open(info[i].pshminfo.pshm_name,O_RDONLY,0);
      if(named>=0){close(named);return 0;}
      if(errno!=ENOENT)return 0;
    }
    /* XNU fill_pshminfo copies pinfo->pshm_hdr.pshm_name for this actual object
     * under its lock; shm_unlink removes lookup membership, not this name.
     * Equal retained names conservatively reject even different objects that
     * were created under a reused historical name. No object-address inference. */
    return lengths[0]!=lengths[1] || memcmp(info[0].pshminfo.pshm_name,info[1].pshminfo.pshm_name,lengths[0])!=0;
#else
    (void)first;(void)second;(void)bytes;return 0;
#endif
}
