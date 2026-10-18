// SPDX-License-Identifier: Apache-2.0
// Generated solid colors only. No VM, display capture or user surface.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "damage.h"
#include "mvo-metal-readback.h"
extern bool mvo_before_copy(void *, uint8_t *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
static bool use_candidate;
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double milliseconds(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static bool clear_texture(id<MTLCommandQueue> queue, id<MTLTexture> texture, bool blue)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = blue ? MTLClearColorMake(0, 0, 1, 1)
                                              : MTLClearColorMake(1, 0, 0, 1);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!command || !encoder) { return false; }
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    return command.status == MTLCommandBufferStatusCompleted;
}

static bool copy_plan(id<MTLTexture> texture, uint8_t *target, uint32_t stride,
                      MVODamagePlan plan)
{
    if (!plan.width || !plan.height) { return true; }
    return (use_candidate ? mvo_metal_copy : mvo_before_copy)(texture,
        target + (size_t)plan.destination_y * stride + (size_t)plan.destination_x * 4,
        stride, plan.width, plan.height, plan.source_x, plan.source_y);
}

static bool check_pixels(const uint8_t *allocation, uint32_t width, uint32_t height,
                         uint32_t stride, bool all_blue, bool patch_blue)
{
    const uint8_t *target = allocation + 64;
    for (unsigned guard = 0; guard < 64; guard++) {
        if (allocation[guard] != 0xa7 || target[(size_t)stride * height + guard] != 0xa7) {
            return false;
        }
    }
    for (uint32_t row = 0; row < height; row++) {
        for (uint32_t col = 0; col < width; col++) {
            bool blue = all_blue || (patch_blue && col >= 100 && col < 612 &&
                                                 row >= 200 && row < 456);
            const uint8_t *pixel = target + (size_t)row * stride + (size_t)col * 4;
            if (pixel[0] != (blue ? 255 : 0) || pixel[1] != 0 ||
                pixel[2] != (blue ? 0 : 255) || pixel[3] != 255) { return false; }
        }
        for (uint32_t pad = width * 4; pad < stride; pad++) {
            if (target[(size_t)row * stride + pad] != 0xa7) { return false; }
        }
    }
    return true;
}

int main(int argc, const char *argv[])
{
    if (argc != 2 || strcmp(argv[1], "--run") != 0) { return 64; }
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) { return 1; }
        const uint32_t width = 3456, height = 2168, stride = width * 4 + 64;
        uint8_t *allocation = malloc((size_t)stride * height + 128);
        if (!allocation) { return 2; }
        MTLPixelFormat formats[] = {MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB,
                                   MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB};
        NSMutableArray *results = [NSMutableArray array];
        for (unsigned kind = 0; kind < 4; kind++) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:formats[kind]
                width:width + 3 height:height + 5 mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            desc.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
            if (!texture || !mvo_metal_can_read(texture)) { return 3; }
            MVODamagePlan full, patch, empty;
            if (!mvo_damage_plan(3, 5, width, height, width, height,
                                 103, 205, 512, 256, true, &full) ||
                !mvo_damage_plan(3, 5, width, height, width, height,
                                 103, 205, 512, 256, false, &patch) ||
                !mvo_damage_plan(3, 5, width, height, width, height,
                                 UINT32_MAX, UINT32_MAX, 123, 456, false, &empty)) { return 4; }
            for (unsigned variant = 0; variant < 2; variant++) {
                use_candidate = variant;
            memset(allocation, 0xa7, (size_t)stride * height + 128);
            if (!clear_texture(queue, texture, false) ||
                !copy_plan(texture, allocation + 64, stride, full) ||
                !check_pixels(allocation, width, height, stride, false, false)) { return 5; }
            if (!clear_texture(queue, texture, true) ||
                !copy_plan(texture, allocation + 64, stride, patch) ||
                !check_pixels(allocation, width, height, stride, false, true)) { return 6; }
            if (!copy_plan(texture, allocation + 64, stride, empty) ||
                !check_pixels(allocation, width, height, stride, false, true)) { return 7; }
            if (!copy_plan(texture, allocation + 64, stride, full) ||
                !check_pixels(allocation, width, height, stride, true, false)) { return 8; }
            }
            NSMutableArray *fullSamples[2] = {[NSMutableArray array], [NSMutableArray array]};
            NSMutableArray *partialSamples[2] = {[NSMutableArray array], [NSMutableArray array]};
            // Declared paired order alternates implementations and full/partial work.
            // GPU source is completed and immutable throughout measurement.
            for (unsigned trial = 0; trial < 10; trial++) {
                for (unsigned variantOrder = 0; variantOrder < 2; variantOrder++) {
                    unsigned variant = (trial + variantOrder) % 2;
                    use_candidate = variant;
                    for (unsigned order = 0; order < 2; order++) {
                        bool partial = ((trial + order) % 2) != 0;
                        MVODamagePlan plan = partial ? patch : full;
                        for (unsigned warm = 0; warm < 4; warm++) {
                            if (!copy_plan(texture, allocation + 64, stride, plan)) { return 9; }
                        }
                        double start = milliseconds();
                        for (unsigned frame = 0; frame < 20; frame++) {
                            if (!copy_plan(texture, allocation + 64, stride, plan)) { return 10; }
                        }
                        double elapsed = (milliseconds() - start) / 20;
                        [(partial ? partialSamples[variant] : fullSamples[variant]) addObject:@(elapsed)];
                    }
                }
            }
            if (!check_pixels(allocation, width, height, stride, true, false)) { return 11; }
            [results addObject:@{@"format":@(formats[kind]),
                @"beforeFullMS":fullSamples[0], @"candidateFullMS":fullSamples[1],
                @"beforePartialMS":partialSamples[0], @"candidatePartialMS":partialSamples[1],
                @"allPixelsAndGuardsCorrect":@YES}];
            [texture release];
        }
        NSDictionary *record = @{@"scope":@"paired-generated-before-after-readback-channel-swizzle-component",
            @"device":device.name, @"width":@(width), @"height":@(height),
            @"scanoutOrigin":@[@3,@5], @"partialSize":@[@512,@256],
            @"fullPixels":@(width * height), @"partialPixels":@(512 * 256),
            @"trials":@10, @"copiesPerSample":@20, @"warmupsPerSample":@4,
            @"timingScope":@"CPU completed getBytes plus channel conversion; no GPU render/fence wait in scope",
            @"guestOrDisplayPerformanceQualified":@NO, @"screenFileSaved":@NO, @"formats":results};
        NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
        if (!json) { return 12; }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        free(allocation); [queue release]; [device release];
        return 0;
    }
}
