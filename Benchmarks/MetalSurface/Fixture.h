#ifndef MVO_GENERATED_METAL_FIXTURE_H
#define MVO_GENERATED_METAL_FIXTURE_H
// SPDX-License-Identifier: Apache-2.0
// Generated GPU quadrants only; no VM, window, screen capture or pixel file.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static id<MTLRenderPipelineState> pipeline(id<MTLDevice> device, id<MTLLibrary> library,
                                           NSString *fragment, MTLPixelFormat format)
{
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = [library newFunctionWithName:@"fullscreen"];
    d.fragmentFunction = [library newFunctionWithName:fragment];
    d.colorAttachments[0].pixelFormat = format;
    NSError *error = nil;
    id<MTLRenderPipelineState> result = [device newRenderPipelineStateWithDescriptor:d error:&error];
    [d.vertexFunction release]; [d.fragmentFunction release]; [d release];
    return result;
}

static bool render(id<MTLCommandQueue> queue, id<MTLRenderPipelineState> state,
                    id<MTLTexture> target, id<MTLTexture> source,
                    uint32_t width, uint32_t height, uint32_t sequence)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!command || !encoder) { return false; }
    [encoder setRenderPipelineState:state];
    if (source) { [encoder setFragmentTexture:source atIndex:0]; }
    uint32_t info[4] = {width, height, sequence, 0};
    [encoder setFragmentBytes:info length:sizeof(info) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    return command.status == MTLCommandBufferStatusCompleted;
}

static bool check_all(id<MTLTexture> texture, uint32_t width, uint32_t height,
                       uint32_t sequence, uint8_t *pixels)
{
    [texture getBytes:pixels bytesPerRow:(size_t)width * 4
           fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    const uint8_t colors[4][4] = {{0,0,255,255},{255,0,0,255},
                                {0,255,0,255},{0,255,255,255}};
    for (uint32_t y = 0; y < height; y++) {
        for (uint32_t x = 0; x < width; x++) {
            unsigned q = (x >= width / 2) + 2 * (y >= height / 2);
            const uint8_t *expected = colors[(q + sequence) % 4];
            const uint8_t *actual = pixels + ((size_t)y * width + x) * 4;
            if (memcmp(actual, expected, 4)) { return false; }
        }
    }
    return true;
}


#endif
