/* SPDX-License-Identifier: Apache-2.0
 * An owner must separately qualify compilation/execution.
 * Exact production vertex/fragment functions come from separate extracted
 * baseline/sharpening .metal files, matching production's separate libraries.
 * No VM, guest, socket, UI, display-layer or process control is present.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>

enum { TARGET_W = 3456, TARGET_H = 2168, INITIAL_WARM = 120,
       SWITCH_WARM = 12, MEASURED = 300, PAIRS = 6 };
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> nearestPipeline, sharpPipeline, originalPipeline;
static double clockScale, runStart;

static double nowMS(void) { return (double)mach_continuous_time() * clockScale; }
static void fail(const char *message) {
    fprintf(stderr, "FAILED: %s\n", message);
    exit(1);
}
static void check(BOOL value, const char *message) { if (!value) fail(message); }
static void deadline(void) { if (nowMS() - runStart > 180000) fail("180s fixture deadline"); }

typedef struct {
    NSUInteger width, height;
    MTLViewport viewport;
    BOOL integer;
    BOOL nativeExact;
    BOOL upscaled;
} Geometry;
typedef struct { double gpu, host, encode; } Observation;

static Geometry geometry(NSUInteger width, NSUInteger height, BOOL integer) {
    double scale = fmin((double)TARGET_W / width, (double)TARGET_H / height);
    if (integer && scale >= 1) scale = floor(scale);
    double w = width * scale, h = height * scale;
    double x = (TARGET_W - w) / 2, y = (TARGET_H - h) / 2;
    if (integer) { x = floor(x); y = floor(y); }
    Geometry g = { width, height, { x, y, w, h, 0, 1 }, integer,
                   integer || fabs(scale - 1) < 1e-12, scale > 1 + 1e-12 };
    return g;
}

/* Nonuniform low-contrast values plus edges and a flat interior. Alpha is
 * deliberately nonopaque to verify the production forced-alpha contract. */
static uint8_t component(NSUInteger x, NSUInteger y, NSUInteger channel) {
    if (channel == 3) return (uint8_t)((x * 3 + y * 5) & 255);
    if (x < 48 && y < 48) return (uint8_t)(87 + channel * 23);
    if (y == 0 || x == 0) return (uint8_t)(channel == 0 ? 251 : channel == 1 ? 13 : 109);
    if (y < 80) return (uint8_t)((x & 1) ? (95 + channel * 9) : (143 + channel * 7));
    return (uint8_t)(64 + ((x * 7 + y * 11 + (x * y) % 83 + channel * 19) % 128));
}
static id<MTLTexture> makeTexture(NSUInteger width, NSUInteger height,
                                 MTLStorageMode storage, MTLTextureUsage usage) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
    desc.storageMode = storage;
    desc.usage = usage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    check(texture != nil, "texture allocation");
    return texture;
}
static id<MTLTexture> makeSource(Geometry g) {
    id<MTLTexture> texture = makeTexture(g.width, g.height,
                                       MTLStorageModeShared, MTLTextureUsageShaderRead);
    NSMutableData *data = [NSMutableData dataWithLength:g.width * g.height * 4];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger y = 0; y < g.height; ++y)
        for (NSUInteger x = 0; x < g.width; ++x)
            for (NSUInteger c = 0; c < 4; ++c)
                bytes[(y * g.width + x) * 4 + c] = component(x, y, c);
    [texture replaceRegion:MTLRegionMake2D(0, 0, g.width, g.height)
               mipmapLevel:0 withBytes:bytes bytesPerRow:g.width * 4];
    return texture;
}
static id<MTLRenderPipelineState> makePipeline(id<MTLLibrary> library, NSString *name) {
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"plane"];
    desc.fragmentFunction = [library newFunctionWithName:name];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    check(desc.vertexFunction != nil && desc.fragmentFunction != nil, "production entry points");
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) { fprintf(stderr, "%s\n", error.description.UTF8String); fail("pipeline compilation"); }
    return pipeline;
}

/* Same-size source->cache blit and the exact final production render pass.
 * One combined command buffer is used for this fixture: it does not simulate
 * production's asynchronous copy ACK, drawable acquisition or presentation. */
static Observation draw(Geometry g, NSUInteger variant,
                        id<MTLTexture> source, id<MTLTexture> cache,
                        id<MTLTexture> target) {
    deadline();
    double began = nowMS();
    id<MTLCommandBuffer> command = [queue commandBuffer];
    check(command != nil, "command buffer");
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    check(blit != nil, "blit encoder");
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(g.width,g.height,1)
                 toTexture:cache destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    check(encoder != nil, "render encoder");
    id<MTLRenderPipelineState> selected = variant == 2 ? originalPipeline
        : variant == 1 && g.upscaled ? sharpPipeline : nearestPipeline;
    [encoder setRenderPipelineState:selected];
    [encoder setViewport:g.viewport];
    [encoder setFragmentTexture:cache atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    double encoded = nowMS();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block double callback = 0;
    [command addCompletedHandler:^(id<MTLCommandBuffer> value) {
        (void)value; callback = nowMS(); dispatch_semaphore_signal(done);
    }];
    double submitted = nowMS();
    [command commit];
    check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
          "5s GPU completion timeout");
    check(command.status == MTLCommandBufferStatusCompleted, "GPU command failed");
    double start = command.GPUStartTime, end = command.GPUEndTime;
    check(isfinite(start) && start > 0 && isfinite(end) && end >= start,
          "missing/invalid GPU timestamps");
    Observation result = { (end-start)*1000, callback-submitted, encoded-began };
    return result;
}

static NSDictionary *distribution(NSArray<NSNumber *> *values) {
    NSArray<NSNumber *> *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger n = sorted.count, over120 = 0, over60 = 0;
    check(n > 0, "empty timing distribution");
    for (NSNumber *value in values) { if (value.doubleValue > 1000.0/120) ++over120;
                                   if (value.doubleValue > 1000.0/60) ++over60; }
    return @{ @"p50MS":sorted[(NSUInteger)ceil(n*0.50)-1],
              @"p95MS":sorted[(NSUInteger)ceil(n*0.95)-1],
              @"p99MS":sorted[(NSUInteger)ceil(n*0.99)-1],
              @"maxMS":sorted.lastObject, @"over120HzBudget":@(over120), @"over60HzBudget":@(over60) };
}
static NSDictionary *block(Geometry g, NSUInteger pair, NSUInteger position,
                           BOOL sharp, id<MTLTexture> source,
                           id<MTLTexture> cache, id<MTLTexture> target) {
    for (NSUInteger i=0; i<SWITCH_WARM; ++i) @autoreleasepool { draw(g,sharp,source,cache,target); }
    NSMutableArray *gpu=[NSMutableArray new], *host=[NSMutableArray new], *encode=[NSMutableArray new];
    for (NSUInteger i=0; i<MEASURED; ++i) @autoreleasepool {
        Observation o=draw(g,sharp,source,cache,target);
        [gpu addObject:@(o.gpu)]; [host addObject:@(o.host)]; [encode addObject:@(o.encode)];
    }
    return @{ @"sourceWidth":@(g.width), @"sourceHeight":@(g.height),
        @"targetWidth":@(TARGET_W), @"targetHeight":@(TARGET_H),
        @"geometry":g.integer ? @"integer" : @"aspectFit", @"pair":@(pair), @"position":@(position),
        @"variant":sharp ? @"automaticSharp" : @"nearest",
        @"effectiveFragment":sharp && g.upscaled ? @"lightSharp" : @"opaque",
        @"viewport":@[ @(g.viewport.originX),@(g.viewport.originY),@(g.viewport.width),@(g.viewport.height) ],
        @"coveredPixels":@(g.viewport.width*g.viewport.height), @"frames":@(MEASURED),
        @"gpu":distribution(gpu), @"submitToCallback":distribution(host), @"encoding":distribution(encode),
        @"rawGpuMS":gpu, @"rawSubmitToCallbackMS":host, @"rawEncodingMS":encode };
}

/* Correctness readback is outside measured runs and uses a separate shared
 * output. Exact nearest reference is required at native/integer scale. Floating
 * fit sampling at an exact source edge is not used as a byte-exact oracle. */
static NSDictionary *checkImage(Geometry g, id<MTLTexture> source, id<MTLTexture> cache) {
    id<MTLTexture> target=makeTexture(TARGET_W,TARGET_H,MTLStorageModeShared,MTLTextureUsageRenderTarget);
    NSMutableData *plain=[NSMutableData dataWithLength:TARGET_W*TARGET_H*4];
    NSMutableData *sharp=[NSMutableData dataWithLength:TARGET_W*TARGET_H*4];
    NSMutableData *original=[NSMutableData dataWithLength:TARGET_W*TARGET_H*4];
    draw(g,2,source,cache,target);
    [target getBytes:original.mutableBytes bytesPerRow:TARGET_W*4
          fromRegion:MTLRegionMake2D(0,0,TARGET_W,TARGET_H) mipmapLevel:0];
    draw(g,NO,source,cache,target);
    [target getBytes:plain.mutableBytes bytesPerRow:TARGET_W*4
          fromRegion:MTLRegionMake2D(0,0,TARGET_W,TARGET_H) mipmapLevel:0];
    draw(g,YES,source,cache,target);
    [target getBytes:sharp.mutableBytes bytesPerRow:TARGET_W*4
          fromRegion:MTLRegionMake2D(0,0,TARGET_W,TARGET_H) mipmapLevel:0];
    check([original isEqualToData:plain],"default output differs from exact historical shader");
    const uint8_t *a=plain.bytes,*b=sharp.bytes;
    NSUInteger exactChecks=0, changed=0, flatChecks=0, outsideChecks=0, rangeChecks=0;
    for (NSUInteger y=0;y<TARGET_H;++y) for(NSUInteger x=0;x<TARGET_W;++x) {
        NSUInteger offset=(y*TARGET_W+x)*4;
        check(a[offset+3]==255 && b[offset+3]==255,"output alpha must be opaque");
        double u=((double)x+.5-g.viewport.originX)/g.viewport.width;
        double v=((double)y+.5-g.viewport.originY)/g.viewport.height;
        BOOL inside=u>=0 && u<1 && v>=0 && v<1;
        if (!inside) {
            for(NSUInteger c=0;c<3;++c) check(a[offset+c]==0 && b[offset+c]==0,"letterbox must remain black");
            ++outsideChecks; continue;
        }
        NSUInteger sx=MIN(g.width-1,(NSUInteger)floor(u*g.width));
        NSUInteger sy=MIN(g.height-1,(NSUInteger)floor(v*g.height));
        if(g.nativeExact) {
            for(NSUInteger c=0;c<3;++c) check(a[offset+c]==component(sx,sy,c),"nearest pixel-reference mismatch");
            ++exactChecks;
            if(g.upscaled) {
                for(NSUInteger c=0;c<3;++c) {
                    NSUInteger xs[]={sx,sx>0?sx-1:0,MIN(sx+1,g.width-1),sx,sx};
                    NSUInteger ys[]={sy,sy,sy,sy>0?sy-1:0,MIN(sy+1,g.height-1)};
                    int minimum=255, maximum=0;
                    for(NSUInteger tap=0;tap<5;++tap) {
                        int value=component(xs[tap],ys[tap],c);
                        minimum=MIN(minimum,value); maximum=MAX(maximum,value);
                    }
                    check((int)b[offset+c]>=minimum-1 && (int)b[offset+c]<=maximum+1,
                          "sharpen exceeded five-tap local range");
                }
                ++rangeChecks;
            }
        }
        if(!g.upscaled) for(NSUInteger c=0;c<4;++c) check(a[offset+c]==b[offset+c],"native mode must bypass sharpening");
        if(sx>=4 && sx<44 && sy>=4 && sy<44) {
            for(NSUInteger c=0;c<3;++c) check(a[offset+c]==b[offset+c],"sharpen changed constant field");
            ++flatChecks;
        }
        if(a[offset]!=b[offset] || a[offset+1]!=b[offset+1] || a[offset+2]!=b[offset+2]) ++changed;
    }
    check(flatChecks>0,"missing flat reference region");
    if(g.upscaled) check(changed>0,"upscaled sharpening fixture made no pixel changes");
    return @{ @"sourceWidth":@(g.width), @"sourceHeight":@(g.height),
        @"geometry":g.integer ? @"integer" : @"aspectFit", @"status":@"passed",
        @"byteExactNearestPixelsChecked":@(exactChecks), @"flatPixelsChecked":@(flatChecks),
        @"blackLetterboxPixelsChecked":@(outsideChecks), @"changedSharpPixels":@(changed),
        @"localFiveTapRangePixelsChecked":@(rangeChecks),
        @"exactHistoricalDefaultOutputMatches":@YES,
        @"fractionalFitExactReferenceSkipped":@(!g.nativeExact) };
}

int main(int argc,char **argv) {
    @autoreleasepool {
        check(argc==4,"usage: RendererScalingBenchmark baseline.metal sharpening.metal original.metal");
        mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
        clockScale=(double)timebase.numer/timebase.denom/1e6;
        runStart=nowMS();
        device=MTLCreateSystemDefaultDevice();
        check(device!=nil && device.hasUnifiedMemory,"unified-memory Metal device required");
        queue=[device newCommandQueue]; check(queue!=nil,"Metal queue");
        NSError *error=nil;
        NSMutableArray<NSString *> *shaderPaths=[NSMutableArray new];
        for(NSUInteger i=1;i<=3;++i) {
            NSString *path=[NSString stringWithUTF8String:argv[i]];
            [shaderPaths addObject:path];
            NSString *shader=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
            check(shader!=nil,"read exact extracted shader");
            id<MTLLibrary> library=[device newLibraryWithSource:shader options:nil error:&error];
            if(!library) { fprintf(stderr,"%s\n",error.description.UTF8String);fail("shader compilation"); }
            if(i==1) nearestPipeline=makePipeline(library,@"opaque");
            else if(i==2) sharpPipeline=makePipeline(library,@"lightSharp");
            else originalPipeline=makePipeline(library,@"opaque");
        }
        NSMutableArray *blocks=[NSMutableArray new],*images=[NSMutableArray new];
        const NSUInteger widths[]={3456,2560,1920,1728}, heights[]={2168,1600,1080,1084};
        for(NSUInteger index=0;index<4;++index) for(NSUInteger mode=0;mode<2;++mode) @autoreleasepool {
            Geometry g=geometry(widths[index],heights[index],mode==1);
            id<MTLTexture> source=makeSource(g);
            id<MTLTexture> cache=makeTexture(g.width,g.height,MTLStorageModePrivate,MTLTextureUsageShaderRead);
            id<MTLTexture> target=makeTexture(TARGET_W,TARGET_H,MTLStorageModePrivate,MTLTextureUsageRenderTarget);
            [images addObject:checkImage(g,source,cache)];
            for(NSUInteger variant=0;variant<2;++variant)
                for(NSUInteger i=0;i<INITIAL_WARM;++i) @autoreleasepool { draw(g,variant==1,source,cache,target); }
            for(NSUInteger pair=0;pair<PAIRS;++pair) for(NSUInteger position=0;position<2;++position) {
                BOOL sharp=(pair%2==0) ? position==1 : position==0;
                [blocks addObject:block(g,pair,position,sharp,source,cache,target)];
            }
        }
        NSDictionary *result=@{ @"schemaVersion":@2, @"fixture":@"exact-production-shader-cache-copy-plus-final-pass",
            @"device":device.name, @"targetWidth":@(TARGET_W),@"targetHeight":@(TARGET_H),
            @"shaderFiles":shaderPaths,@"separateProductionShaderLibraries":@YES,
            @"exactHistoricalDefaultOutputMatches":@YES,
            @"initialWarmPerVariant":@(INITIAL_WARM),@"switchWarmPerBlock":@(SWITCH_WARM),
            @"samplesPerBlock":@(MEASURED),@"pairs":@(PAIRS),@"elapsedMS":@(nowMS()-runStart),
            @"inFlightCommandBuffers":@1,@"copyAndDrawCombinedForFixture":@YES,
            @"includesDrawableAcquisition":@NO,@"includesProducerTransport":@NO,
            @"liveFPSMeasured":@NO,@"physicalScanoutMeasured":@NO,@"images":images,@"blocks":blocks };
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
        check(json!=nil,"serialize result"); fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout);
    }
    return 0;
}
