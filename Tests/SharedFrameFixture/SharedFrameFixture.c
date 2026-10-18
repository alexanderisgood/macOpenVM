// SPDX-License-Identifier: Apache-2.0
// Generated data only. No VM, screen, stored pixels, or process control.
#include "SharedFrameFixture.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>
void mvo_fixture_clear(MVOFrameFixturePool *p) {
    for(unsigned i=0;i<2;i++) {
        if(p->maps[i]) munmap(p->maps[i],p->size);
        if(p->descriptors[i]>=0) close(p->descriptors[i]);
    }
    memset(p,0,sizeof *p);p->descriptors[0]=p->descriptors[1]=-1;
}
int mvo_fixture_pool(MVOFrameFixturePool *p,size_t size,int readonly) {
    memset(p,0,sizeof *p);p->descriptors[0]=p->descriptors[1]=-1;p->size=size;
    for(unsigned i=0;i<2;i++) {
        char name[32];snprintf(name,sizeof name,"/mvo-test-%08x%08x",arc4random(),arc4random());
        int write=shm_open(name,O_CREAT|O_EXCL|O_RDWR,0600);
        if(write<0) goto fail;
        int read=shm_open(name,readonly?O_RDONLY:O_RDWR,0);
        int unlinked=shm_unlink(name);
        if(read<0 || unlinked || ftruncate(write,(off_t)size)) {
            if(read>=0) close(read);close(write);goto fail;
        }
        p->descriptors[i]=read;
        void *map=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_SHARED,write,0);
        close(write);
        if(map==MAP_FAILED) goto fail;
        p->maps[i]=map;
        for(size_t j=0;j<size;j++) p->maps[i][j]=(uint8_t)(j*13+(j/1024)*7+i*31);
    }
    return 0;
fail: mvo_fixture_clear(p);return -1;
}
int mvo_fixture_send(int fd,const uint8_t *bytes,size_t size,const int *fds,size_t count) {
    if(count>32) { errno=EINVAL;return -1; }
    union { struct cmsghdr align; char bytes[CMSG_SPACE(32*sizeof(int))]; } control;
    struct iovec io={(void *)bytes,size};struct msghdr msg={0};
    msg.msg_iov=&io;msg.msg_iovlen=1;
    if(count) {
        memset(&control,0,sizeof control);msg.msg_control=control.bytes;
        msg.msg_controllen=CMSG_SPACE(count*sizeof(int));
        struct cmsghdr *c=CMSG_FIRSTHDR(&msg);c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;
        c->cmsg_len=CMSG_LEN(count*sizeof(int));memcpy(CMSG_DATA(c),fds,count*sizeof(int));
    }
    return (int)sendmsg(fd,&msg,0);
}

int mvo_fixture_check(const uint8_t *bytes,size_t count,unsigned slot,
                      size_t width,size_t height,size_t stride) {
    if(!width) {
        for(size_t j=0;j<count;j++) if(bytes[j]!=(uint8_t)(j*13+(j/1024)*7+slot*31)) return 0;
    } else {
        if(width*height*4!=count) return 0;
        for(size_t y=0;y<height;y++) for(size_t x=0;x<width;x++) {
            size_t dest=(y*width+x)*4,source=y*stride+x*4;
            for(size_t c=0;c<3;c++) {
                size_t j=source+c;
                if(bytes[dest+c]!=(uint8_t)(j*13+(j/1024)*7+slot*31)) return 0;
            }
            if(bytes[dest+3]!=255) return 0;
        }
    }
    return 1;
}
