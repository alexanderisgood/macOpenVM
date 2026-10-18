// SPDX-License-Identifier: Apache-2.0
// DXMT native shared backing -> completed GPU export -> independent IOSurface.
#include "Fixture.h"
#include "DxmtSource.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static id<MTLTexture> import_source(id<MTLDevice> device, MvoDxmtLayout layout,
                                   MTLPixelFormat format)
{
    struct stat info;
    uint64_t alignment=[device minimumLinearTextureAlignmentForPixelFormat:format];
    uint64_t page=(uint64_t)getpagesize();
    if (!alignment || !layout.stride || layout.stride % alignment ||
        layout.stride < (uint64_t)layout.width*4 || layout.stride > 65536 ||
        layout.size != layout.stride*layout.height || layout.offset % alignment ||
        layout.size > 64*1024*1024 || layout.offset > 64*1024*1024 ||
        fstat(layout.fd,&info) || info.st_size <= 0) return nil;
    uint64_t end=layout.offset+layout.size, length=(end+page-1)&~(page-1);
    if(length > (uint64_t)info.st_size) return nil;
    void *memory=mmap(NULL,length,PROT_READ|PROT_WRITE,MAP_SHARED,layout.fd,0);
    if(memory==MAP_FAILED) return nil;
    id<MTLBuffer> buffer=[device newBufferWithBytesNoCopy:memory length:length
        options:MTLResourceStorageModeShared deallocator:^(void *pointer,NSUInteger bytes){munmap(pointer,bytes);}];
    if(!buffer) { munmap(memory,length); return nil; }
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:layout.width height:layout.height mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[buffer newTextureWithDescriptor:d offset:layout.offset bytesPerRow:layout.stride];
    [buffer release];return texture;
}
int main(int argc,const char *argv[])
{
    if(argc!=2 || strcmp(argv[1],"--run")) return 64;
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue=[device newCommandQueue];
        NSString *code=@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 fullscreen(uint v [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[v],0,1);}\n"
            "fragment half4 transfer(float4 p [[position]],texture2d<half,access::read> t [[texture(0)]]){half4 c=t.read(uint2(p.xy));c.a=1;return c;}\n";
        NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithSource:code options:nil error:&error];
        if(!device || !queue || !library) return 1;
        const MTLPixelFormat formats[4]={80,81,70,71};
        const uint32_t dxgi[4]={87,91,28,29};
        NSMutableArray *cases=[NSMutableArray array];
        for(unsigned index=0;index<8;index++) {
            @autoreleasepool {
                uint32_t width=index<4?3456:3840,height=index<4?2168:2160;
                MvoDxmtLayout layout={0};
                MvoDxmtSource *producer=mvo_dxmt_create(width,height,dxgi[index%4],&layout);
                if(!producer) return 2;
                id<MTLTexture> source=import_source(device,layout,formats[index%4]);
                MTLPixelFormat outFormat=index%2?81:80;
                id<MTLRenderPipelineState> copy=pipeline(device,library,@"transfer",outFormat);
                uint32_t row=(width*4+255)&~255u;
                NSDictionary *properties=@{(id)kIOSurfaceWidth:@(width),(id)kIOSurfaceHeight:@(height),
                    (id)kIOSurfaceBytesPerRow:@(row),(id)kIOSurfaceBytesPerElement:@4,
                    (id)kIOSurfaceAllocSize:@((size_t)row*height),(id)kIOSurfacePixelFormat:@(0x42475241)};
                IOSurfaceRef surface=IOSurfaceCreate((CFDictionaryRef)properties);
                mach_port_t port=surface?IOSurfaceCreateMachPort(surface):MACH_PORT_NULL;
                IOSurfaceRef imported=port?IOSurfaceLookupFromMachPort(port):NULL;
                if(port) mach_port_deallocate(mach_task_self(),port);
                MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:outFormat
                    width:width height:height mipmapped:NO];
                d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
                id<MTLTexture> writable=surface?[device newTextureWithDescriptor:d iosurface:surface plane:0]:nil;
                id<MTLTexture> output=[device newTextureWithDescriptor:d];
                d.usage=MTLTextureUsageShaderRead;
                id<MTLTexture> readable=imported?[device newTextureWithDescriptor:d iosurface:imported plane:0]:nil;
                uint8_t *pixels=malloc((size_t)width*height*4);
                if(!source || !copy || !writable || !output || !readable || !pixels) return 3;
                NSMutableArray *samples=[NSMutableArray array];
                for(uint32_t seq=0;seq<7;seq++) {
                    double sourceWait=0,overwriteWait=0;
                    // Export only after the actual DXMT D3D11 fence and its pollable event agree.
                    if(!mvo_dxmt_prepare(producer,seq,&sourceWait,seq%2)) return 4;
                    double begin=now_ms();
                    if(!render(queue,copy,writable,source,width,height,seq)) return 5;
                    double exportMS=now_ms()-begin;
                    // Reuse the original shared source before consuming the dedicated snapshot.
                    if(!mvo_dxmt_prepare(producer,seq+1,&overwriteWait,(seq+1)%2)) return 6;
                    if(!render(queue,copy,output,source,width,height,seq+1) ||
                        !check_all(output,width,height,seq+1,pixels)) return 7;
                    begin=now_ms();
                    if(!render(queue,copy,output,readable,width,height,seq)) return 8;
                    double drawMS=now_ms()-begin;
                    if(!check_all(output,width,height,seq,pixels)) return 9;
                    if(seq>=2) [samples addObject:@{@"producerFenceWaitMS":@(sourceWait),
                        @"exportSubmitAndWaitMS":@(exportMS),@"consumerDrawAndWaitMS":@(drawMS),
                        @"sourceOverwriteFenceWaitMS":@(overwriteWait)}];
                }
                [cases addObject:@{@"width":@(width),@"height":@(height),@"dxgiFormat":@(dxgi[index%4]),
                    @"sourceFormat":@(formats[index%4]),@"surfaceFormat":@(outFormat),
                    @"allPixelsCorrectAfterSourceOverwrite":@YES,@"warmups":@2,@"samples":samples}];
                free(pixels);[readable release];[output release];[writable release];
                CFRelease(imported);CFRelease(surface);[copy release];[source release];
                mvo_dxmt_destroy(producer);
            }
        }
        NSDictionary *result=@{@"scope":@"native-DXMT-completed-shared-source-IOSurface-component",
            @"passed":@YES,@"sourceExclusiveOwnershipIsFixtureOnly":@YES,
            @"windowsPresentOrPhysicalPresentationQualified":@NO,
            @"pollableEventAndFenceValueBothChecked":@YES,
            @"earlyEventHandleCloseExercised":@YES,@"noPixelFiles":@YES,@"cases":cases};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        if(!json) return 10;fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
        [library release];[queue release];[device release];return 0;
    }
}
