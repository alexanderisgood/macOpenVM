// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        require(device != nil, "Metal unavailable");
        id<MTLCommandQueue> queue = [device newCommandQueue];
        require(queue != nil, "Command queue unavailable");
        const NSUInteger sizes[][2] = {{321,241}, {1920,1080}, {2560,1600}, {3456,2168}, {3840,2160}};
        puts("width,height,block,variant,trial,gpu_us");
        for (NSUInteger geometry = 0; geometry < 5; geometry++) {
            NSUInteger width = sizes[geometry][0], height = sizes[geometry][1];
            NSUInteger stride = (width * 4 + 255) & ~255UL;
            id<MTLBuffer> buffer = [device newBufferWithLength:stride * height options:MTLResourceStorageModeShared];
            require(buffer != nil, "Shared buffer allocation failed");
            uint8_t *bytes = buffer.contents;
            for (NSUInteger i = 0; i < buffer.length; i++) bytes[i] = (uint8_t)(i * 13 + i / 1024);
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            desc.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> linear = [buffer newTextureWithDescriptor:desc offset:0 bytesPerRow:stride];
            desc.storageMode = MTLStorageModePrivate;
            id<MTLTexture> cache = [device newTextureWithDescriptor:desc];
            id<MTLBuffer> readback = [device newBufferWithLength:stride * height options:MTLResourceStorageModeShared];
            require(buffer && linear && cache && readback, "Allocation failed");
            for (NSUInteger block = 0; block < 6; block++) {
                for (NSUInteger order = 0; order < 2; order++) {
                    NSUInteger variant = (block + order) % 2;
                    for (NSUInteger trial = 0; trial < 44; trial++) {
                        @autoreleasepool {
                            id<MTLCommandBuffer> command = [queue commandBuffer];
                            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                            require(command && blit, "Encoder unavailable");
                            if (variant == 0) {
                                [blit copyFromTexture:linear sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toTexture:cache destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
                            } else {
                                [blit copyFromBuffer:buffer sourceOffset:0 sourceBytesPerRow:stride sourceBytesPerImage:stride * height sourceSize:MTLSizeMake(width,height,1) toTexture:cache destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
                            }
                            [blit endEncoding];
                            [command commit];
                            [command waitUntilCompleted];
                            require(command.status == MTLCommandBufferStatusCompleted, "GPU failed");
                            require(command.GPUEndTime >= command.GPUStartTime && command.GPUStartTime > 0, "GPU timestamps unavailable");
                            if (trial >= 4) printf("%lu,%lu,%lu,%lu,%lu,%.6f\n", width,height,block,variant,trial-4,(command.GPUEndTime-command.GPUStartTime)*1e6);
                        }
                    }
                    id<MTLCommandBuffer> verify = [queue commandBuffer];
                    id<MTLBlitCommandEncoder> blit = [verify blitCommandEncoder];
                    require(verify && blit, "Readback encoder unavailable");
                    [blit copyFromTexture:cache sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:stride * height];
                    [blit endEncoding]; [verify commit]; [verify waitUntilCompleted];
                    require(verify.status == MTLCommandBufferStatusCompleted, "Readback failed");
                    for (NSUInteger row = 0; row < height; row++) require(memcmp(bytes + row * stride, (uint8_t *)readback.contents + row * stride, width * 4) == 0, "Pixel mismatch");
                }
            }
        }
    }
}
