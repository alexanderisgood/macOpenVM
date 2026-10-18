// SPDX-License-Identifier: Apache-2.0
// Generated surfaces only. Actual owned child; no service names or VM access.
#include "Fixture.h"
#include <bsm/libbsm.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
enum { Hello=1, Attach, Frame, Release, Quit, Ack };
enum { Healthy=0, ReplayACK, StaleEpochACK, EarlyExit, StalledConsumer, MalformedAttach };
static unsigned faultMode=Healthy;
typedef struct Envelope {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t rights[2];
    uint32_t version, kind, replyTo, caseID, sequence, slot, width, height, format, correct;
    uint64_t epoch[2];
    double sentMS, drawMS, noticeMS;
} Envelope;

static bool make_inbox(mach_port_t *port)
{
    return mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, port)==KERN_SUCCESS &&
        mach_port_insert_right(mach_task_self(),*port,*port,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS;
}
static void drop_inbox(mach_port_t port)
{
    if (port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(),port);
        mach_port_mod_refs(mach_task_self(),port,MACH_PORT_RIGHT_RECEIVE,-1);
    }
}
static bool send_packet(mach_port_t destination, Envelope *message, unsigned rights)
{
    message->head.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0) |
        (rights ? MACH_MSGH_BITS_COMPLEX : 0);
    message->head.msgh_remote_port=destination;
    message->head.msgh_local_port=MACH_PORT_NULL;
    message->head.msgh_size=sizeof(*message);
    message->head.msgh_id=0x4d564f;
    message->body.msgh_descriptor_count=rights;
    message->version=1;
    return mach_msg(&message->head,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof(*message),0,
                    MACH_PORT_NULL,2000,MACH_PORT_NULL)==KERN_SUCCESS;
}
static bool receive_packet(mach_port_t inbox, pid_t peer, Envelope *message)
{
    struct { Envelope message; mach_msg_max_trailer_t trailer; } buffer={0};
    mach_msg_option_t options=MACH_RCV_MSG|MACH_RCV_TIMEOUT|
        MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|
        MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    kern_return_t received=mach_msg(&buffer.message.head,options,0,sizeof(buffer),
                                    inbox,3000,MACH_PORT_NULL);
    if (received != KERN_SUCCESS) { return false; }
    unsigned trailerOffset=(buffer.message.head.msgh_size+3u)&~3u;
    if (buffer.message.head.msgh_size != sizeof(Envelope) || trailerOffset != sizeof(Envelope)) {
        mach_msg_destroy(&buffer.message.head); return false;
    }
    mach_msg_audit_trailer_t *trailer=(void *)((uint8_t *)&buffer+trailerOffset);
    bool complex=(buffer.message.head.msgh_bits&MACH_MSGH_BITS_COMPLEX)!=0;
    unsigned count=buffer.message.body.msgh_descriptor_count;
    bool valid=trailer->msgh_trailer_type==MACH_MSG_TRAILER_FORMAT_0 &&
        trailer->msgh_trailer_size>=sizeof(*trailer) &&
        audit_token_to_pid(trailer->msgh_audit)==peer &&
        audit_token_to_euid(trailer->msgh_audit)==geteuid() &&
        buffer.message.head.msgh_id==0x4d564f && buffer.message.version==1 &&
        count<=2 && complex==(count>0);
    for (unsigned i=0; valid && i<count; i++) {
        valid=buffer.message.rights[i].type==MACH_MSG_PORT_DESCRIPTOR &&
            buffer.message.rights[i].disposition==MACH_MSG_TYPE_PORT_SEND &&
            buffer.message.rights[i].name!=MACH_PORT_NULL;
    }
    if (!valid) { mach_msg_destroy(&buffer.message.head); return false; }
    *message=buffer.message;
    return true;
}
static bool same_epoch(const Envelope *a,const uint64_t epoch[2])
{ return a->epoch[0]==epoch[0] && a->epoch[1]==epoch[1]; }
static id<MTLLibrary> common_library(id<MTLDevice> device)
{
    NSString *code=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 fullscreen(uint v [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[v],0,1);}\n"
        "fragment half4 pattern(float4 p [[position]],constant uint4 &i [[buffer(0)]]){uint q=uint(p.x>=i.x/2)+2*uint(p.y>=i.y/2);half4 c[4]={half4(1,0,0,0.25),half4(0,0,1,0.25),half4(0,1,0,0.25),half4(1,1,0,0.25)};return c[(q+i.z)%4];}\n"
        "fragment half4 transfer(float4 p [[position]],texture2d<half,access::read> t [[texture(0)]]){half4 c=t.read(uint2(p.xy));c.a=1;return c;}\n";
    NSError *error=nil;
    return [device newLibraryWithSource:code options:nil error:&error];
}
static mach_port_t inherited_channel(void)
{
    mach_port_array_t ports=NULL;mach_msg_type_number_t count=0;
    if (mach_ports_lookup(mach_task_self(),&ports,&count)!=KERN_SUCCESS || count!=3) { return MACH_PORT_NULL; }
    mach_port_t result=ports[2];
    /* Keep the private capability locally; do not pass it to later helpers. */
    mach_port_t cleared[3]={ports[0],ports[1],MACH_PORT_NULL};
    if(mach_ports_register(mach_task_self(),cleared,3)!=KERN_SUCCESS) {
        if(result!=MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(),result); }
        result=MACH_PORT_NULL;
    }
    for(unsigned i=0;i<count;i++) {
        if(i!=2 && ports[i]!=MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(),ports[i]); }
    }
    vm_deallocate(mach_task_self(),(vm_address_t)ports,count*sizeof(mach_port_t));
    return result;
}
static bool send_ack(mach_port_t parent,const Envelope *request,double draw,double notice)
{
    Envelope ack={0};ack.kind=Ack;ack.replyTo=request->kind;ack.caseID=request->caseID;
    ack.sequence=request->sequence;ack.slot=request->slot;ack.correct=1;
    ack.epoch[0]=request->epoch[0];ack.epoch[1]=request->epoch[1];ack.drawMS=draw;ack.noticeMS=notice;
    return send_packet(parent,&ack,0);
}

static int consume_frames(void)
{
    pid_t parentPID=getppid();mach_port_t parent=inherited_channel(),inbox=MACH_PORT_NULL;
    if(parent==MACH_PORT_NULL || !make_inbox(&inbox)) { return 21; }
    Envelope hello={0};hello.kind=Hello;
    hello.rights[0].name=inbox;hello.rights[0].disposition=MACH_MSG_TYPE_MAKE_SEND;
    hello.rights[0].type=MACH_MSG_PORT_DESCRIPTOR;
    if(!send_packet(parent,&hello,1)) { return 22; }
    if(faultMode==EarlyExit) { return 7; }
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue=[device newCommandQueue];
        id<MTLLibrary> library=common_library(device);
        if(!device || !queue || !library) { return 23; }
        for(uint32_t caseID=0;caseID<8;caseID++) {
            @autoreleasepool {
                Envelope attach={0};
                if(!receive_packet(inbox,parentPID,&attach) || attach.kind!=Attach ||
                    attach.caseID!=caseID || attach.body.msgh_descriptor_count!=2 ||
                    attach.width!=(caseID<4?3456u:3840u) || attach.height!=(caseID<4?2168u:2160u) ||
                    attach.format!=((caseID%2)?MTLPixelFormatBGRA8Unorm_sRGB:MTLPixelFormatBGRA8Unorm)) { return 24; }
                uint32_t width=attach.width,height=attach.height;
                IOSurfaceRef surfaces[2]={NULL,NULL};id<MTLTexture> readable[2]={nil,nil};
                MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:attach.format
                    width:width height:height mipmapped:NO];d.storageMode=MTLStorageModeShared;
                d.usage=MTLTextureUsageShaderRead;
                for(unsigned slot=0;slot<2;slot++) {
                    surfaces[slot]=IOSurfaceLookupFromMachPort(attach.rights[slot].name);
                    mach_port_deallocate(mach_task_self(),attach.rights[slot].name);
                    if(!surfaces[slot] || IOSurfaceGetWidth(surfaces[slot])!=width ||
                        IOSurfaceGetHeight(surfaces[slot])!=height ||
                        IOSurfaceGetPixelFormat(surfaces[slot])!=0x42475241 ||
                        IOSurfaceGetBytesPerRow(surfaces[slot])<(size_t)width*4 ||
                        IOSurfaceGetBytesPerRow(surfaces[slot])>(size_t)width*4+4096 ||
                        IOSurfaceGetAllocSize(surfaces[slot])>(size_t)(width*4+4096)*height) { return 25; }
                    readable[slot]=[device newTextureWithDescriptor:d iosurface:surfaces[slot] plane:0];
                }
                d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
                id<MTLTexture> output=[device newTextureWithDescriptor:d];
                id<MTLRenderPipelineState> copy=pipeline(device,library,@"transfer",attach.format);
                uint8_t *pixels=malloc((size_t)width*height*4);
                if(!readable[0] || !readable[1] || !output || !copy || !pixels ||
                    !send_ack(parent,&attach,0,0)) { return 26; }
                for(uint32_t seq=0;seq<7;seq++) {
                    Envelope frame={0};
                    if(!receive_packet(inbox,parentPID,&frame) || frame.kind!=Frame ||
                        frame.body.msgh_descriptor_count!=0 || frame.caseID!=caseID ||
                        frame.sequence!=seq || frame.slot!=seq%2 || !same_epoch(&frame,attach.epoch) ||
                        !isfinite(frame.sentMS) || frame.sentMS<0 || frame.sentMS>now_ms()) { return 27; }
                    double notice=now_ms()-frame.sentMS;
                    if(caseID==0 && seq==0 && (faultMode==ReplayACK || faultMode==StaleEpochACK)) {
                        Envelope poisoned=frame;
                        if(faultMode==ReplayACK) { poisoned.sequence=UINT32_MAX; }
                        else { poisoned.epoch[0]^=1; }
                        return send_ack(parent,&poisoned,0,notice)?0:40;
                    }
                    if(caseID==0 && seq==0 && faultMode==StalledConsumer) {
                        struct timespec delay={3,500000000};nanosleep(&delay,NULL);
                        bool intact=render(queue,copy,output,readable[frame.slot],width,height,seq) &&
                            check_all(output,width,height,seq,pixels);
                        return intact?0:41;
                    }
                    // A deliberate consumer pause exercises one-in-flight backpressure.
                    if(seq==2) { struct timespec pause={0,32000000};nanosleep(&pause,NULL); }
                    double begin=now_ms();
                    if(!render(queue,copy,output,readable[frame.slot],width,height,seq)) { return 28; }
                    double drawn=now_ms()-begin;
                    if(!check_all(output,width,height,seq,pixels) ||
                        !send_ack(parent,&frame,drawn,notice)) { return 29; }
                }
                Envelope release={0};
                if(!receive_packet(inbox,parentPID,&release) || release.kind!=Release ||
                    release.caseID!=caseID || release.sequence!=7 ||
                    release.body.msgh_descriptor_count!=0 || !same_epoch(&release,attach.epoch)) { return 30; }
                free(pixels);[output release];[copy release];
                for(unsigned slot=0;slot<2;slot++) { [readable[slot] release];CFRelease(surfaces[slot]); }
                if(!send_ack(parent,&release,0,0)) { return 31; }
            }
        }
        Envelope quit={0};
        if(!receive_packet(inbox,parentPID,&quit) || quit.kind!=Quit ||
            quit.body.msgh_descriptor_count!=0 || !send_ack(parent,&quit,0,0)) { return 32; }
        [library release];[queue release];[device release];
    }
    drop_inbox(inbox);mach_port_deallocate(mach_task_self(),parent);
    return 0;
}

static bool expect_ack(mach_port_t inbox,pid_t child,const Envelope *request,Envelope *answer)
{
    return receive_packet(inbox,child,answer) && answer->kind==Ack &&
        answer->body.msgh_descriptor_count==0 && answer->replyTo==request->kind &&
        answer->caseID==request->caseID && answer->sequence==request->sequence &&
        answer->slot==request->slot && same_epoch(answer,request->epoch) && answer->correct==1 &&
        isfinite(answer->drawMS) && answer->drawMS>=0 && isfinite(answer->noticeMS) && answer->noticeMS>=0;
}

static bool produce_frames(mach_port_t inbox,mach_port_t childPort,pid_t child,NSMutableArray *results)
{
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLLibrary> library=common_library(device);if(!device || !queue || !library) { return false; }
    MTLPixelFormat formats[4]={MTLPixelFormatBGRA8Unorm,MTLPixelFormatBGRA8Unorm_sRGB,
        MTLPixelFormatRGBA8Unorm,MTLPixelFormatRGBA8Unorm_sRGB};
    for(uint32_t caseID=0;caseID<8;caseID++) {
        @autoreleasepool {
            uint32_t width=caseID<4?3456:3840,height=caseID<4?2168:2160;
            MTLPixelFormat outFormat=(caseID%2)?MTLPixelFormatBGRA8Unorm_sRGB:MTLPixelFormatBGRA8Unorm;
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[caseID%4]
                width:width height:height mipmapped:NO];d.storageMode=MTLStorageModePrivate;
            d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
            id<MTLTexture> source=[device newTextureWithDescriptor:d];d.pixelFormat=outFormat;d.storageMode=MTLStorageModeShared;
            IOSurfaceRef surfaces[2]={NULL,NULL};id<MTLTexture> writable[2]={nil,nil};
            uint32_t rowBytes=(width*4+255)&~255u;
            NSDictionary *properties=@{(id)kIOSurfaceWidth:@(width),(id)kIOSurfaceHeight:@(height),
                (id)kIOSurfaceBytesPerRow:@(rowBytes),(id)kIOSurfaceBytesPerElement:@4,
                (id)kIOSurfaceAllocSize:@((size_t)rowBytes*height),(id)kIOSurfacePixelFormat:@(0x42475241)};
            Envelope attach={0};attach.kind=Attach;attach.caseID=caseID;attach.width=width;
            attach.height=height;attach.format=outFormat;arc4random_buf(attach.epoch,sizeof(attach.epoch));
            for(unsigned slot=0;slot<2;slot++) {
                surfaces[slot]=IOSurfaceCreate((CFDictionaryRef)properties);if(!surfaces[slot]) { return false; }
                writable[slot]=[device newTextureWithDescriptor:d iosurface:surfaces[slot] plane:0];
                attach.rights[slot].name=IOSurfaceCreateMachPort(surfaces[slot]);
                attach.rights[slot].disposition=MACH_MSG_TYPE_COPY_SEND;
                attach.rights[slot].type=MACH_MSG_PORT_DESCRIPTOR;
                if(!writable[slot] || attach.rights[slot].name==MACH_PORT_NULL) { return false; }
            }
            if(caseID==0 && faultMode==MalformedAttach) { attach.width=UINT32_MAX; }
            Envelope answer={0};bool attached=send_packet(childPort,&attach,2) && expect_ack(inbox,child,&attach,&answer);
            for(unsigned slot=0;slot<2;slot++) { mach_port_deallocate(mach_task_self(),attach.rights[slot].name); }
            if(!attached) { return false; }
            id<MTLRenderPipelineState> pattern=pipeline(device,library,@"pattern",formats[caseID%4]);
            id<MTLRenderPipelineState> copy=pipeline(device,library,@"transfer",outFormat);
            if(!pattern || !copy || !source) { return false; }
            bool inFlight[2]={false,false};NSMutableArray *samples=[NSMutableArray array];
            for(uint32_t seq=0;seq<7;seq++) {
                unsigned slot=seq%2;if(inFlight[slot]) { return false; }
                if(!render(queue,pattern,source,nil,width,height,seq)) { return false; }
                inFlight[slot]=true;double begin=now_ms();
                if(!render(queue,copy,writable[slot],source,width,height,seq)) { return false; }
                double exported=now_ms()-begin;
                Envelope frame={0};frame.kind=Frame;frame.caseID=caseID;frame.sequence=seq;frame.slot=slot;
                frame.epoch[0]=attach.epoch[0];frame.epoch[1]=attach.epoch[1];frame.sentMS=now_ms();
                if(!send_packet(childPort,&frame,0) || !expect_ack(inbox,child,&frame,&answer)) { return false; }
                double acknowledged=now_ms()-frame.sentMS;inFlight[slot]=false;
                if(seq>=2) { [samples addObject:@{@"exportSubmitAndWaitMS":@(exported),
                    @"consumerNoticeMS":@(answer.noticeMS),@"consumerDrawAndWaitMS":@(answer.drawMS),
                    @"validatedACKRoundTripMS":@(acknowledged),@"deliberateConsumerPauseMS":@(seq==2?32:0)}]; }
            }
            Envelope release={0};release.kind=Release;release.caseID=caseID;release.sequence=7;
            release.epoch[0]=attach.epoch[0];release.epoch[1]=attach.epoch[1];
            if(!send_packet(childPort,&release,0) || !expect_ack(inbox,child,&release,&answer)) { return false; }
            [results addObject:@{@"width":@(width),@"height":@(height),@"sourceFormat":@(formats[caseID%4]),
                @"surfaceFormat":@(outFormat),@"trials":@5,@"warmups":@2,@"samples":samples,
                @"allConsumerPixelsCorrect":@YES,@"maximumInFlight":@1,@"slots":@2}];
            for(unsigned slot=0;slot<2;slot++) { [writable[slot] release];CFRelease(surfaces[slot]); }
            [source release];[pattern release];[copy release];
        }
    }
    Envelope quit={0},answer={0};quit.kind=Quit;
    bool completed=send_packet(childPort,&quit,0) && expect_ack(inbox,child,&quit,&answer);
    [library release];[queue release];[device release];return completed;
}

int main(int argc,char *argv[])
{
    if(argc!=2) { return 64; }
    if(strncmp(argv[1],"--",2)) { return 64; }
    const char *names[]={"healthy","replay-ack","stale-epoch","early-exit","stalled-consumer","malformed-attach"};
    bool childMode=!strncmp(argv[1],"--consumer-",11);
    const char *requested=childMode?argv[1]+11:argv[1]+2;
    bool recognized=false;
    for(unsigned mode=0;mode<6;mode++) { if(!strcmp(requested,names[mode])) { faultMode=mode;recognized=true;break; } }
    if(!strcmp(argv[1],"--run")) { faultMode=Healthy;recognized=true; }
    if(!recognized) { return 64; }
    if(childMode) { return consume_frames(); }
    mach_port_t inbox=MACH_PORT_NULL;if(!make_inbox(&inbox)) { return 1; }
    mach_port_array_t old=NULL;mach_msg_type_number_t count=0;
    if(mach_ports_lookup(mach_task_self(),&old,&count)!=KERN_SUCCESS || count!=3) { return 2; }
    mach_port_t inherited[3]={old[0],old[1],inbox};
    if(mach_ports_register(mach_task_self(),inherited,3)!=KERN_SUCCESS) { return 3; }
    char childArgument[64];snprintf(childArgument,sizeof(childArgument),"--consumer-%s",names[faultMode]);
    pid_t ownedChild=-1;char *args[]={argv[0],childArgument,NULL};
    int spawned=posix_spawn(&ownedChild,argv[0],NULL,NULL,args,environ);
    kern_return_t restored=mach_ports_register(mach_task_self(),old,count);
    for(unsigned i=0;i<count;i++) { if(old[i]!=MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(),old[i]); } }
    vm_deallocate(mach_task_self(),(vm_address_t)old,count*sizeof(mach_port_t));
    if(spawned) { drop_inbox(inbox);return 4; }
    bool passed=false;mach_port_t childPort=MACH_PORT_NULL;
    @autoreleasepool {
        Envelope hello={0};NSMutableArray *results=[NSMutableArray array];
        if(restored==KERN_SUCCESS && receive_packet(inbox,ownedChild,&hello) && hello.kind==Hello &&
            hello.body.msgh_descriptor_count==1) {
            childPort=hello.rights[0].name;
            passed=produce_frames(inbox,childPort,ownedChild,results);
        }
        int status=0;pid_t waited=0;
        for(unsigned attempt=0;attempt<200 && waited==0;attempt++) {
            waited=waitpid(ownedChild,&status,WNOHANG);
            if(waited<0 && errno==EINTR) { waited=0; }
            if(waited==0) { struct timespec pause={0,10000000};nanosleep(&pause,NULL); }
        }
        bool forced=waited==0;
        if(forced) { kill(ownedChild,SIGTERM);do { waited=waitpid(ownedChild,&status,0); } while(waited<0 && errno==EINTR); }
        int exitCode=WIFEXITED(status)?WEXITSTATUS(status):-1;
        bool healthy=passed && !forced && waited==ownedChild && exitCode==0;
        int expectedChildExit=faultMode==EarlyExit?7:faultMode==MalformedAttach?24:0;
        bool rejection=faultMode!=Healthy && !passed && !forced && restored==KERN_SUCCESS &&
            waited==ownedChild && exitCode==expectedChildExit;
        passed=faultMode==Healthy?healthy:rejection;
        NSDictionary *result=@{@"scope":@"cross-process-generated-IOSurface-GPU-delivery-component",
            @"passed":@(passed),@"mode":[NSString stringWithUTF8String:names[faultMode]],
            @"expectedProtocolRejectionObserved":@(rejection),
            @"actualChildExit":@(exitCode),@"actualParentReaped":@((bool)(waited==ownedChild)),
            @"forcedOwnedCleanup":@(forced),@"registeredPortsRestored":@((bool)(restored==KERN_SUCCESS)),
            @"namedServiceOrGlobalSurfaceIDUsed":@NO,@"kernelPeerAuditUIDAndOwnedChildPIDChecked":@YES,
            @"productionAuthenticationQualified":@NO,@"guestOrPhysicalPresentationQualified":@NO,
            @"noGuestPixelsOrScreenFiles":@YES,@"consumerShaderReadUsageIsAccessControl":@NO,
            @"timingScope":@"completed source excluded; GPU export, private Mach notice and consumer GPU draw separate; ACK includes independent all-pixel CPU oracle and declared pause",
            @"cases":results};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        if(json) { fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout); }
    }
    if(childPort!=MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(),childPort); }
    drop_inbox(inbox);return passed?0:5;
}
