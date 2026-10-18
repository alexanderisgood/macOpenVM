// SPDX-License-Identifier: Apache-2.0
#include "Fixture.h"
int main(int argc, const char *argv[])
{
    if (argc != 2 || strcmp(argv[1], "--run")) { return 64; }
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> producer = [device newCommandQueue];
        id<MTLCommandQueue> consumer = [device newCommandQueue];
        if (!device || !producer || !consumer) { return 1; }
        NSString *code = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 fullscreen(uint v [[vertex_id]]) {\n"
            " float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[v],0,1);}\n"
            "fragment half4 pattern(float4 p [[position]],constant uint4 &i [[buffer(0)]]) {\n"
            " uint q=uint(p.x>=i.x/2)+2*uint(p.y>=i.y/2);\n"
            " half4 c[4]={half4(1,0,0,0.25),half4(0,0,1,0.25),half4(0,1,0,0.25),half4(1,1,0,0.25)};\n"
            " return c[(q+i.z)%4];}\n"
            "fragment half4 transfer(float4 p [[position]],texture2d<half,access::read> t [[texture(0)]]) {\n"
            " half4 c=t.read(uint2(p.xy));c.a=1;return c;}\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:code options:nil error:&error];
        if (!library) { return 2; }
        const uint32_t sizes[2][2] = {{3456,2168},{3840,2160}};
        const MTLPixelFormat formats[4] = {MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB,
            MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB};
        NSMutableArray *cases = [NSMutableArray array];
        for (unsigned geometry = 0; geometry < 2; geometry++) {
            for (unsigned kind = 0; kind < 4; kind++) {
                @autoreleasepool {
                    uint32_t width = sizes[geometry][0], height = sizes[geometry][1];
                    MTLPixelFormat outputFormat = (kind % 2) ? MTLPixelFormatBGRA8Unorm_sRGB
                                                            : MTLPixelFormatBGRA8Unorm;
                    id<MTLRenderPipelineState> pattern = pipeline(device, library, @"pattern", formats[kind]);
                    id<MTLRenderPipelineState> copy = pipeline(device, library, @"transfer", outputFormat);
                    if (!pattern || !copy) { return 3; }
                    MTLTextureDescriptor *desc = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:formats[kind] width:width height:height mipmapped:NO];
                    desc.storageMode = MTLStorageModePrivate;
                    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                    id<MTLTexture> source = [device newTextureWithDescriptor:desc];
                    desc.pixelFormat = outputFormat;
                    desc.storageMode = MTLStorageModeShared;
                    id<MTLTexture> verifiedOutput = [device newTextureWithDescriptor:desc];
                    IOSurfaceRef surfaces[2] = {NULL,NULL}, imported[2] = {NULL,NULL};
                    id<MTLTexture> writable[2] = {nil,nil}, readable[2] = {nil,nil};
                    bool inFlight[2] = {false,false};
                    uint32_t rowBytes = (width * 4 + 255) & ~255u;
                    NSDictionary *properties = @{(id)kIOSurfaceWidth:@(width),
                        (id)kIOSurfaceHeight:@(height), (id)kIOSurfaceBytesPerElement:@4,
                        (id)kIOSurfaceBytesPerRow:@(rowBytes),
                        (id)kIOSurfaceAllocSize:@((size_t)rowBytes * height),
                        (id)kIOSurfacePixelFormat:@(0x42475241)};
                    for (unsigned slot = 0; slot < 2; slot++) {
                        surfaces[slot] = IOSurfaceCreate((CFDictionaryRef)properties);
                        if (!surfaces[slot]) { return 4; }
                        mach_port_t port = IOSurfaceCreateMachPort(surfaces[slot]);
                        if (port == MACH_PORT_NULL) { return 5; }
                        imported[slot] = IOSurfaceLookupFromMachPort(port);
                        kern_return_t released = mach_port_deallocate(mach_task_self(), port);
                        if (!imported[slot] || released != KERN_SUCCESS ||
                            IOSurfaceGetWidth(imported[slot]) != width ||
                            IOSurfaceGetHeight(imported[slot]) != height ||
                            IOSurfaceGetPixelFormat(imported[slot]) != 0x42475241 ||
                            IOSurfaceGetBytesPerRow(imported[slot]) < (size_t)width * 4 ||
                            IOSurfaceGetAllocSize(imported[slot]) > (size_t)rowBytes * height + 1048576) { return 6; }
                        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                        writable[slot] = [device newTextureWithDescriptor:desc iosurface:surfaces[slot] plane:0];
                        desc.usage = MTLTextureUsageShaderRead;
                        readable[slot] = [device newTextureWithDescriptor:desc iosurface:imported[slot] plane:0];
                    }
                    uint8_t *pixels = malloc((size_t)width * height * 4);
                    if (!source || !verifiedOutput || !writable[0] || !writable[1] ||
                        !readable[0] || !readable[1] || !pixels) { return 7; }
                    NSMutableArray *samples = [NSMutableArray array];
                    // Original GPU rendering and every-pixel CPU checks are outside timing.
                    // Sequential completion models one in-flight frame, not real IPC.
                    for (uint32_t sequence = 0; sequence < 7; sequence++) {
                        unsigned slot = sequence % 2;
                        if (inFlight[slot]) { return 8; }
                        if (!render(producer, pattern, source, nil, width, height, sequence)) { return 9; }
                        inFlight[slot] = true;
                        double begin = now_ms();
                        if (!render(producer, copy, writable[slot], source, width, height, sequence)) { return 10; }
                        double exportEnd = now_ms();
                        if (!render(consumer, copy, verifiedOutput, readable[slot], width, height, sequence)) { return 11; }
                        double consumerEnd = now_ms();
                        if (!check_all(verifiedOutput, width, height, sequence, pixels)) { return 12; }
                        inFlight[slot] = false;
                        if (sequence >= 2) {
                            [samples addObject:@{@"exportSubmitAndWaitMS":@(exportEnd - begin),
                                @"consumerDrawAndWaitMS":@(consumerEnd - exportEnd),
                                @"combinedMS":@(consumerEnd - begin)}];
                        }
                    }
                    [cases addObject:@{@"width":@(width),@"height":@(height),
                        @"sourceFormat":@(formats[kind]),@"surfaceFormat":@(outputFormat),
                        @"slots":@2,@"trials":@5,@"warmups":@2,@"samples":samples,
                        @"allPixelsCorrect":@YES,@"alphaForcedOpaque":@YES,
                        @"machPortsDeallocatedAfterImport":@YES}];
                    free(pixels);
                    for (unsigned slot = 0; slot < 2; slot++) {
                        [readable[slot] release]; [writable[slot] release];
                        CFRelease(imported[slot]); CFRelease(surfaces[slot]);
                    }
                    [source release]; [verifiedOutput release]; [pattern release]; [copy release];
                }
            }
        }
        NSDictionary *result = @{@"scope":@"single-process-generated-IOSurface-GPU-delivery-component",
            @"device":device.name,@"cases":cases,@"sameProcessMachPortRoundTrip":@YES,
            @"crossProcessIPCQualified":@NO,@"physicalPresentationQualified":@NO,
            @"guestPerformanceQualified":@NO,@"guestPixelsOrScreenFiles":@NO,
            @"consumerShaderReadUsageIsAccessControl":@NO,
            @"timingScope":@"GPU export draw then GPU consumer draw; each CPU submit-to-command-completion; generated source and all-pixel oracle excluded",
            @"synchronization":@"two independent command queues, sequential completion; two slots, one in flight; no IPC/failure-recovery claim"};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        if (!json) { return 13; }
        fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout);
        [library release]; [producer release]; [consumer release]; [device release];
        return 0;
    }
}
