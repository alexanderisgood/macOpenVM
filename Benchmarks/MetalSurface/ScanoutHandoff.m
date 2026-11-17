// SPDX-License-Identifier: Apache-2.0
// Generated pixels only. A native DXMT producer and a separate Metal consumer
// share render targets using independently opened read-only descriptors.
#include "Fixture.h"
#include "ScanoutDxmt.h"
#include "SharedHDRFrameTransport.h"

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

enum { CHILD_SOCKET = 3, CHILD_FIRST_SLOT = 4 };
typedef struct {
    uint32_t width, height, stride;
    size_t bytes;
} Layout;

#define CHECK(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "Scanout handoff line %d: %s\n", __LINE__, #expr); \
        return false; \
    } \
} while (0)

static bool create_slot(size_t bytes, int *writer, int *reader)
{
    char name[28];
    snprintf(name, sizeof(name), "/mvoh%08x%08x", arc4random(), arc4random());
    int w = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (w < 0) {
        return false;
    }
    int r = ftruncate(w, (off_t)bytes) == 0 ? shm_open(name, O_RDONLY, 0) : -1;
    int unlinked = shm_unlink(name);
    if (r < 0 || unlinked != 0) {
        close(w);
        if (r >= 0) {
            close(r);
        }
        return false;
    }
    *writer = w;
    *reader = r;
    return true;
}

static bool spawn_consumer(const char *executable, int socket, const int *reads, pid_t *pid)
{
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) {
        return false;
    }
    // Relocate sources out of the destination range before scheduling dup2.
    int originals[] = {socket, reads[0], reads[1], reads[2]};
    int copies[sizeof originals / sizeof originals[0]];
    for (size_t i = 0; i < sizeof copies / sizeof copies[0]; ++i) {
        copies[i] = -1;
    }
    bool ok = true;
    for (size_t i = 0; i < sizeof copies / sizeof copies[0]; ++i) {
        copies[i] = fcntl(originals[i], F_DUPFD_CLOEXEC, 32);
        if (copies[i] < 0 || posix_spawn_file_actions_adddup2(&actions, copies[i], CHILD_SOCKET + (int)i)) {
            ok = false;
            break;
        }
    }
    posix_spawnattr_t attrs;
    if (ok && posix_spawnattr_init(&attrs) == 0) {
        char *args[] = {(char *)executable, "--consumer", NULL};
        ok = posix_spawnattr_setflags(&attrs, POSIX_SPAWN_CLOEXEC_DEFAULT) == 0 &&
            posix_spawn(pid, executable, &actions, &attrs, args, environ) == 0;
        posix_spawnattr_destroy(&attrs);
    } else {
        ok = false;
    }
    for (size_t i = 0; i < sizeof copies / sizeof copies[0]; ++i) {
        if (copies[i] >= 0) {
            close(copies[i]);
        }
    }
    posix_spawn_file_actions_destroy(&actions);
    return ok;
}

static id<MTLTexture> import_slot(id<MTLDevice> device, int fd, Layout layout)
{
    void *memory = mmap(NULL, layout.bytes, PROT_READ, MAP_SHARED, fd, 0);
    if (memory == MAP_FAILED) {
        return nil;
    }
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:memory length:layout.bytes
        options:MTLResourceStorageModeShared deallocator:^(void *pointer, NSUInteger bytes) {
            munmap(pointer, bytes);
        }];
    if (!buffer) {
        munmap(memory, layout.bytes);
        return nil;
    }
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:layout.width height:layout.height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [buffer newTextureWithDescriptor:desc offset:0 bytesPerRow:layout.stride];
    [buffer release];
    return [texture autorelease];
}

static bool reply(int socket, char result)
{
    return send(socket, &result, 1, 0) == 1;
}

static bool await_reply(int socket, char result)
{
    char response;
    return recv(socket, &response, 1, 0) == 1 && response == result;
}

static bool consumer(int socket)
{
    Layout layout;
    CHECK(recv(socket, &layout, sizeof(layout), 0) == sizeof(layout));
    CHECK((layout.width == 2880 && layout.height == 1800) ||
          (layout.width == 3456 && layout.height == 2168));
    CHECK(layout.stride >= layout.width * 4 && layout.stride <= 16384 &&
          layout.bytes >= (size_t)layout.stride * layout.height && layout.bytes <= 64 * 1024 * 1024);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [[device newCommandQueue] autorelease];
    id<MTLTexture> sources[MVO_SCANOUT_SLOT_COUNT];
    for (uint32_t slot = 0; slot < MVO_SCANOUT_SLOT_COUNT; ++slot) {
        int fd = CHILD_FIRST_SLOT + (int)slot;
        for (int prior = CHILD_FIRST_SLOT; prior < fd; ++prior) {
            CHECK(mvo_hdr_readonly_slots_distinct(prior, fd, layout.bytes));
        }
        sources[slot] = import_slot(device, fd, layout);
        CHECK(sources[slot]);
    }
    for (uint32_t slot = 0; slot < MVO_SCANOUT_SLOT_COUNT; ++slot) {
        close(CHILD_FIRST_SLOT + (int)slot);
    }
    NSString *code = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 fullscreen(uint v [[vertex_id]]) {"
        "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[v],0,1);}\n"
        "fragment half4 sampleFrame(float4 p [[position]], texture2d<half, access::read> t [[texture(0)]]) {"
        "return t.read(uint2(p.xy));}";
    NSError *error = nil;
    id<MTLLibrary> library = [[device newLibraryWithSource:code options:nil error:&error] autorelease];
    id<MTLRenderPipelineState> state = [pipeline(device, library, @"sampleFrame", MTLPixelFormatBGRA8Unorm) autorelease];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:layout.width height:layout.height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> output = [[device newTextureWithDescriptor:desc] autorelease];
    id<MTLSharedEvent> gate = [[device newSharedEvent] autorelease];
    NSMutableData *pixels = [NSMutableData dataWithLength:(size_t)layout.width * layout.height * 4];
    CHECK(device && queue && state && output && gate && pixels);
    for (uint64_t i = 1; i <= 3; ++i) {
        MVOScanoutLease lease;
        CHECK(recv(socket, &lease, sizeof(lease), 0) == sizeof(lease) && lease.slot < MVO_SCANOUT_SLOT_COUNT);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        CHECK(command);
        [command encodeWaitForEvent:gate value:i];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = output;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        CHECK(encoder);
        [encoder setRenderPipelineState:state];
        [encoder setFragmentTexture:sources[lease.slot] atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [command commit];

        // Hold the texture GPU read open while the producer moves on. Only the
        // producer test's release signal allows the consumer to sample it.
        bool handshake = reply(socket, 'Q') && await_reply(socket, 'G');
        gate.signaledValue = i;
        [command waitUntilCompleted];
        CHECK(handshake && command.status == MTLCommandBufferStatusCompleted);
        CHECK(check_all(output, layout.width, layout.height, (uint32_t)lease.sequence, pixels.mutableBytes));
        CHECK(send(socket, &lease, sizeof(lease), 0) == sizeof(lease));
    }
    return true;
}

static bool start_read(int socket, MVOScanoutLease lease)
{
    return send(socket, &lease, sizeof(lease), 0) == sizeof(lease) && await_reply(socket, 'Q');
}

static bool complete_read(int socket, MVOScanoutLeasePool *pool, MVOScanoutLease expected)
{
    MVOScanoutLease release;
    return reply(socket, 'G') && recv(socket, &release, sizeof(release), 0) == sizeof(release) &&
        release.epoch == expected.epoch && release.sequence == expected.sequence && release.slot == expected.slot &&
        mvo_scanout_lease_release_read(pool, release);
}

static bool render_next(MVOScanoutDxmt *producer, MVOScanoutLeasePool *pool, MVOScanoutLease *lease)
{
    return mvo_scanout_lease_begin_write(pool, lease) && mvo_scanout_dxmt_render(producer, *lease) &&
        mvo_scanout_lease_finish_write(pool, *lease, true);
}

static bool exercise(int socket, Layout layout, MVOScanoutDxmt *dxmt)
{
    MVOScanoutLeasePool pool;
    MVOScanoutLease first, second, newest, held, pending, final, other;
    CHECK(mvo_scanout_lease_init(&pool, 1));
    CHECK(send(socket, &layout, sizeof(layout), 0) == sizeof(layout));
    CHECK(render_next(dxmt, &pool, &first) && mvo_scanout_lease_take_latest(&pool, &first));
    CHECK(start_read(socket, first));
    CHECK(render_next(dxmt, &pool, &second) && render_next(dxmt, &pool, &newest));
    CHECK(mvo_scanout_lease_take_latest(&pool, &held) && held.sequence == newest.sequence);
    CHECK(held.slot != first.slot && held.slot != second.slot);
    CHECK(render_next(dxmt, &pool, &pending) && pending.slot == second.slot);
    CHECK(render_next(dxmt, &pool, &other) && other.slot == pending.slot);
    CHECK(!mvo_scanout_lease_take_latest(&pool, &pending));
    CHECK(!mvo_scanout_lease_release_read(&pool, (MVOScanoutLease){2, first.sequence, first.slot}));
    CHECK(complete_read(socket, &pool, first));
    CHECK(render_next(dxmt, &pool, &final) && final.slot == first.slot);
    CHECK(mvo_scanout_lease_take_latest(&pool, &final) && !mvo_scanout_lease_release_read(&pool, first));
    CHECK(start_read(socket, held) && complete_read(socket, &pool, held));
    CHECK(start_read(socket, final) && complete_read(socket, &pool, final));
    mvo_scanout_lease_retire(&pool);
    CHECK(mvo_scanout_lease_is_drained(&pool));
    return true;
}

static bool producer(const char *executable, uint32_t width, uint32_t height)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    CHECK(device && alignment > 0 && alignment <= 4096);
    uint32_t stride = (uint32_t)((width * 4 + alignment - 1) / alignment * alignment);
    size_t page = (size_t)getpagesize();
    size_t bytes = ((size_t)stride * height + page - 1) / page * page;
    Layout layout = {width, height, stride, bytes};

    int writes[MVO_SCANOUT_SLOT_COUNT], reads[MVO_SCANOUT_SLOT_COUNT];
    for (uint32_t slot = 0; slot < MVO_SCANOUT_SLOT_COUNT; ++slot) {
        CHECK(create_slot(layout.bytes, &writes[slot], &reads[slot]));
    }
    int sockets[2];
    CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) == 0);
    struct timeval timeout = {.tv_sec = 12};
    for (size_t i = 0; i < 2; ++i) {
        CHECK(setsockopt(sockets[i], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    }
    pid_t child;
    CHECK(spawn_consumer(executable, sockets[1], reads, &child));
    close(sockets[1]);
    MVOScanoutDxmt *dxmt = mvo_scanout_dxmt_create(width, height, stride, writes);
    for (uint32_t slot = 0; slot < MVO_SCANOUT_SLOT_COUNT; ++slot) {
        close(writes[slot]);
        close(reads[slot]);
    }
    bool ok = dxmt && exercise(sockets[0], layout, dxmt);
    close(sockets[0]);
    if (!ok) {
        kill(child, SIGKILL);
    }
    int result;
    pid_t reaped = waitpid(child, &result, 0);
    mvo_scanout_dxmt_destroy(dxmt);
    CHECK(ok && reaped == child && WIFEXITED(result) && WEXITSTATUS(result) == 0);
    printf("%ux%u: direct DXMT render, three cross-process Metal reads, delayed release and slot reuse passed\n",
           width, height);
    return true;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--consumer") == 0) {
            return consumer(CHILD_SOCKET) ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "2880x1800") == 0) {
            return producer(argv[0], 2880, 1800) ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "3456x2168") == 0) {
            return producer(argv[0], 3456, 2168) ? 0 : 1;
        }
        return 64;
    }
}
