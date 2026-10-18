// SPDX-License-Identifier: Apache-2.0
/* ROOT-OWNED generated CPU fixture, no guest memory/VM/display data. */
#include "SharedHDRFrameTransport.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
static int64_t end_ns;
static char retained_names[2][32];
static bool retained_named[2];
static void cleanup_names(void){for(unsigned i=0;i<2;i++)if(retained_named[i])shm_unlink(retained_names[i]);}
static int64_t now_ns(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))abort();return(int64_t)t.tv_sec*1000000000+t.tv_nsec;}
static void require(int yes,const char *why){if(!yes){fprintf(stderr,"FAIL %s errno=%d\n",why,errno);exit(1);}}
static void waitfd(int fd,short events){
    require(now_ns()<end_ns,"absolute fixture deadline");struct pollfd p={fd,events,0};
    int n=poll(&p,1,100);require(n>=0 || errno==EINTR,"poll");
}
static void send_record(int fd,const void *bytes,size_t count,const int *rights){
    size_t used=0;bool delivered=false;
    while(used<count){
      require(now_ns()<end_ns,"send deadline");
      struct iovec io={(void *)((const unsigned char *)bytes+used),count-used};struct msghdr m={0};m.msg_iov=&io;m.msg_iovlen=1;
      union{struct cmsghdr align;char bytes[CMSG_SPACE(2*sizeof(int))];} control;
      if(rights && !delivered){memset(&control,0,sizeof control);m.msg_control=control.bytes;m.msg_controllen=sizeof control;
        struct cmsghdr *c=CMSG_FIRSTHDR(&m);c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;c->cmsg_len=CMSG_LEN(2*sizeof(int));
        memcpy(CMSG_DATA(c),rights,2*sizeof(int));}
      ssize_t n=sendmsg(fd,&m,0);
      if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR)){waitfd(fd,POLLOUT);continue;}
      require(n>0,"sendmsg");delivered=true;used+=(size_t)n;
    }
}
static void receive_record(int fd,MVOHDRReceive *r){
    for(;;){require(now_ns()<end_ns,"receive deadline");int n=mvo_hdr_receive(fd,r);
      require(n>=0,"receive");if(n==1)return;waitfd(fd,POLLIN);}
}
static void encode_control(const MVOHDRControl *c,unsigned char b[MVO_HDR_CONTROL_BYTES]){
    require(mvo_hdr_control_encode(c,b,MVO_HDR_CONTROL_BYTES)==MVO_HDR_OK,"encode control");
}
static bool pattern(void *unused,uint8_t *target,size_t bytes,const MVOHDRDescriptor *d){
    const bool latest=*(const bool *)unused;require(bytes==d->mapped_bytes,"snapshot length");
    /* Non-palindromic half sequences identify every column, row and corner.
     * Frame1 starts R=-0.5,G=2.5,B=12.5 (=1000nits at absolute80), alpha=-0.
     * These are bit constants in a known generated surface, never SDR gain. */
    for(uint32_t y=0;y<d->height;y++)for(uint32_t x=0;x<d->width;x++)for(unsigned c=0;c<4;c++){
      const uint16_t p[4]={(uint16_t)(latest?0x3400+x*11:0xb800+x*17),
        (uint16_t)(latest?0x3d00+y*0x80:0x4100+y*0x80),
        (uint16_t)(latest?0x4400+x*5+y*0x40:0x4a40+x*3+y*0x20),0x8000};
      size_t off=(size_t)y*d->row_bytes+x*8+c*2;target[off]=(uint8_t)p[c];target[off+1]=(uint8_t)(p[c]>>8);}
    return true;
}
int main(int argc,char **argv){
    require(argc==2 || (argc==3 && (!strcmp(argv[2],"--duplicate-slots") || !strcmp(argv[2],"--linked-slots"))),"private endpoint and optional negative case");
    bool duplicate=argc==3 && !strcmp(argv[2],"--duplicate-slots");
    bool linked=argc==3 && !strcmp(argv[2],"--linked-slots");const char *path=argv[1];
    require(atexit(cleanup_names)==0,"register generated namespace cleanup");
    require(path[0]=='/' && strlen(path)<sizeof(((struct sockaddr_un *)0)->sun_path),"socket path");
    end_ns=now_ns()+INT64_C(30000000000);
    int server=socket(AF_UNIX,SOCK_STREAM,0);require(server>=0,"socket");
    struct sockaddr_un address={0};address.sun_len=sizeof address;address.sun_family=AF_UNIX;strcpy(address.sun_path,path);
    mode_t old=umask(0077);int bound=bind(server,(struct sockaddr *)&address,sizeof address);umask(old);
    require(bound==0 && chmod(path,0600)==0 && listen(server,1)==0,"bind private socket");
    require(fcntl(server,F_SETFL,O_NONBLOCK)==0 && fcntl(server,F_SETFD,FD_CLOEXEC)==0,"listener flags");
    printf("READY generated-hdr-socket %s\n",path);fflush(stdout);
    int peer=-1;while(peer<0){waitfd(server,POLLIN);peer=accept(server,NULL,NULL);require(peer>=0 || errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR,"accept");}
    uid_t uid;gid_t gid;int no_signal=1;
    require(getpeereid(peer,&uid,&gid)==0 && uid==geteuid(),"same uid");
    require(fcntl(peer,F_SETFL,O_NONBLOCK)==0 && fcntl(peer,F_SETFD,FD_CLOEXEC)==0 &&
      setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&no_signal,sizeof no_signal)==0,"peer flags");
    MVOHDRControl offer={0};offer.kind=MVO_HDR_OFFER;arc4random_buf(offer.negotiation_id,16);
    offer.negotiation_id[0]|=1;offer.limits.page_bytes=(uint32_t)getpagesize();offer.limits.row_alignment=256;
    offer.limits.maximum_mapping_bytes=MVO_HDR_MAX_MAPPING_BYTES;
    unsigned char control[MVO_HDR_CONTROL_BYTES];encode_control(&offer,control);send_record(peer,control,sizeof control,NULL);
    MVOHDRReceive rx;require(mvo_hdr_receive_init(&rx,MVO_HDR_CONTROL_BYTES,false)==0,"control receiver init");
    receive_record(peer,&rx);MVOHDRControl accept={0};
    require(mvo_hdr_control_decode(rx.bytes,rx.used,&accept)==MVO_HDR_OK &&
      mvo_hdr_control_validate_selection(&offer,&accept)==MVO_HDR_OK,"closed accept");mvo_hdr_receive_clear(&rx);
    MVOHDRControl ready=accept;ready.kind=MVO_HDR_READY;encode_control(&ready,control);send_record(peer,control,sizeof control,NULL);
    MVOHDRDescriptor d={0};d.resource_id=10;d.resource_incarnation=20;d.color_generation=30;d.scanout_generation=40;
    d.width=31;d.height=3;d.row_bytes=accept.limits.row_alignment;
    d.mapped_bytes=(d.row_bytes*d.height+accept.limits.page_bytes-1)&~(accept.limits.page_bytes-1);
    d.pixel_format=MVO_HDR_RGBA16_FLOAT_LE;d.color_encoding=MVO_HDR_LINEAR_709_D65_ABSOLUTE_80;d.optical_scale_millinit=80000;
    require(mvo_hdr_validate_descriptor(&d,&accept.limits)==MVO_HDR_OK,"descriptor");
    int rw[2]={-1,-1},ro[2]={-1,-1};void *maps[2]={0};
    for(unsigned i=0;i<2;i++){
      char candidate[32];
      for(unsigned attempt=0;attempt<16;attempt++){
        snprintf(candidate,sizeof candidate,"/mvh2-%08x-%u",arc4random(),i);
        rw[i]=shm_open(candidate,O_RDWR|O_CREAT|O_EXCL,0600);
        if(rw[i]>=0)break;require(errno==EEXIST,"fresh shm creation");
      }
      require(rw[i]>=0,"fresh shm bounded collision retry");
      memcpy(retained_names[i],candidate,strlen(candidate)+1);retained_named[i]=true;char *name=retained_names[i];
      ro[i]=shm_open(name,O_RDONLY,0);require(ro[i]>=0,"readonly open");
      if(!linked){require(shm_unlink(name)==0,"unlink");retained_named[i]=false;}
      printf("GENERATED_SHM %s\n",name);fflush(stdout);
      struct stat st;require(fstat(rw[i],&st)==0 && (st.st_mode&0777)==0600 && st.st_uid==geteuid() && st.st_nlink==0,"shm metadata");
      require(ftruncate(rw[i],d.mapped_bytes)==0 && fcntl(rw[i],F_SETFD,FD_CLOEXEC)==0 && fcntl(ro[i],F_SETFD,FD_CLOEXEC)==0,"shm size/flags");
      maps[i]=mmap(NULL,d.mapped_bytes,PROT_READ|PROT_WRITE,MAP_SHARED,rw[i],0);require(maps[i]!=MAP_FAILED,"mmap");
    }
    uint8_t epoch[16];arc4random_buf(epoch,16);epoch[0]|=1;MVOHDRSlots slots={0};
    require(mvo_hdr_slots_init(&slots,epoch,&d,&accept.limits,maps[0],d.mapped_bytes,maps[1],d.mapped_bytes)==MVO_HDR_OK,"slot init");
    const bool first=false,latest=true;
    require(mvo_hdr_slots_write(&slots,&d,1,pattern,(void *)&first)==MVO_HDR_OK,"ordered complete generated snapshot");
    require(mvo_hdr_readonly_slots_distinct(ro[0],ro[1],d.mapped_bytes)==(linked?0:1),"actual kernel distinct/unlinked slot proof");
    require(mvo_hdr_readonly_slots_distinct(ro[0],ro[0],d.mapped_bytes)==0,"duplicate backing rejected");
    uint8_t packet[128];require(mvo_hdr_slots_attach(&slots,packet,sizeof packet)==MVO_HDR_OK,"attach");
    int rights[2]={ro[0],duplicate?ro[0]:ro[1]};send_record(peer,packet,sizeof packet,rights);
    if(duplicate || linked){
      for(;;){unsigned char b;ssize_t n=recv(peer,&b,1,0);
        if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR)){waitfd(peer,POLLIN);continue;}
        require(n==0,"unsafe slots must close with NO attach ACK");break;}
      require(mvo_hdr_slots_retire(&slots)==MVO_HDR_OK,"unsafe pool retire");
      for(unsigned i=0;i<2;i++){munmap(maps[i],d.mapped_bytes);close(rw[i]);close(ro[i]);}
      close(peer);close(server);unlink(path);puts("PASS unsafe underlying slot rights rejected before ACK");return 0;
    }
    require(mvo_hdr_receive_init(&rx,128,false)==0,"data receiver init");receive_record(peer,&rx);
    require(mvo_hdr_slots_ack(&slots,rx.bytes,rx.used)==MVO_HDR_OK,"exact attach ack");mvo_hdr_receive_clear(&rx);
    receive_record(peer,&rx);require(mvo_hdr_slots_request(&slots,rx.bytes,rx.used)==MVO_HDR_OK,"canonical request");mvo_hdr_receive_clear(&rx);
    require(mvo_hdr_slots_publish(&slots,(uint64_t)now_ns(),packet,sizeof packet)==MVO_HDR_OK,"publish frozen snapshot");
    send_record(peer,packet,sizeof packet,NULL);
    uint8_t *frozen=malloc(d.mapped_bytes);require(frozen!=NULL,"frozen oracle allocation");memcpy(frozen,maps[0],d.mapped_bytes);
    require(mvo_hdr_slots_write(&slots,&d,2,pattern,(void *)&latest)==MVO_HDR_OK,"mutable latest separate while borrowed");
    require(memcmp(frozen,maps[0],d.mapped_bytes)==0,"borrow unchanged");
    require(memcmp(frozen,maps[1],d.mapped_bytes)!=0,"latest really differs from borrowed");free(frozen);
    receive_record(peer,&rx);require(mvo_hdr_slots_ack(&slots,rx.bytes,rx.used)==MVO_HDR_OK,"exact frame ack after actual Mac GPU copy");mvo_hdr_receive_clear(&rx);
    receive_record(peer,&rx);require(mvo_hdr_slots_request(&slots,rx.bytes,rx.used)==MVO_HDR_OK,"second canonical request");mvo_hdr_receive_clear(&rx);
    require(mvo_hdr_slots_publish(&slots,(uint64_t)now_ns(),packet,sizeof packet)==MVO_HDR_OK,"publish second content generation");send_record(peer,packet,sizeof packet,NULL);
    receive_record(peer,&rx);require(mvo_hdr_slots_ack(&slots,rx.bytes,rx.used)==MVO_HDR_OK,"second exact GPU completion ACK");mvo_hdr_receive_clear(&rx);
    require(mvo_hdr_slots_retire(&slots)==MVO_HDR_OK,"retire");
    for(unsigned i=0;i<2;i++){munmap(maps[i],d.mapped_bytes);close(rw[i]);close(ro[i]);}
    close(peer);close(server);unlink(path);
    puts("PASS actual readonly FD transport, canonical ACK and separate borrowed/latest slots; generated FP16 only");return 0;
}
