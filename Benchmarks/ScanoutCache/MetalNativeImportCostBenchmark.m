/* SPDX-License-Identifier: MIT
 * SOURCE ONLY. Native-resolution public scanout import-cost benchmark.
 * No GUI, VM, guest context, render server, process or socket API is used.
 */
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dispatch/dispatch.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include "virglrenderer.h"
#include "virgl_hw.h"

#define CHECK(condition) do { if (!(condition)) { \
   fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)

enum { BUFFER_COUNT = 3, WIDTH = 3456, HEIGHT = 2168,
       ACTIVE_ROW = WIDTH * 4, WARM_CALLS = 12, TIMED_CALLS = 1200 };
static struct test_resource {
   uint32_t id;
   int original_fd, renderer_fd;
   bool registered;
   unsigned char *mapping;
   char name[24];
   unsigned seed;
} resources[BUFFER_COUNT];
static unsigned char renderer_cookie;
static EGLDisplay display = EGL_NO_DISPLAY;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static size_t page_size, mapping_size;
static uint32_t row_stride, texture_offset;
static unsigned unexpected_callbacks, gpu_reads;

static void *get_display(void *cookie)
{
   CHECK(cookie == &renderer_cookie);
   return display;
}

/* The public v4 interface requires these callbacks. NO_VIRGL makes them
 * unnecessary; any invocation is an unexpected path and fails this fixture.
 */
static virgl_renderer_gl_context
unexpected_create(void *cookie, int scanout,
                  struct virgl_renderer_gl_ctx_param *parameters)
{
   (void)cookie; (void)scanout; (void)parameters;
   ++unexpected_callbacks;
   return NULL;
}

static void unexpected_destroy(void *cookie, virgl_renderer_gl_context context)
{
   (void)cookie; (void)context;
   ++unexpected_callbacks;
}

static int unexpected_current(void *cookie, int scanout,
                               virgl_renderer_gl_context context)
{
   (void)cookie; (void)scanout; (void)context;
   ++unexpected_callbacks;
   return -1;
}

static void initialize_real_renderer(void)
{
   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
   CHECK(get_platform != NULL);
   const EGLint attributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
      EGL_NONE
   };
   display = get_platform(EGL_PLATFORM_ANGLE_ANGLE, NULL, attributes);
   CHECK(display != EGL_NO_DISPLAY);
   EGLint major = 0, minor = 0;
   CHECK(eglInitialize(display, &major, &minor) == EGL_TRUE);

   PFNEGLQUERYDISPLAYATTRIBEXTPROC query_display =
      (PFNEGLQUERYDISPLAYATTRIBEXTPROC)eglGetProcAddress("eglQueryDisplayAttribEXT");
   PFNEGLQUERYDEVICEATTRIBEXTPROC query_device =
      (PFNEGLQUERYDEVICEATTRIBEXTPROC)eglGetProcAddress("eglQueryDeviceAttribEXT");
   CHECK(query_display != NULL && query_device != NULL);
   EGLAttrib native_device = 0, metal_device = 0;
   CHECK(query_display(display, EGL_DEVICE_EXT, &native_device) == EGL_TRUE);
   CHECK(query_device((EGLDeviceEXT)native_device, EGL_METAL_DEVICE_ANGLE,
                      &metal_device) == EGL_TRUE);
   CHECK(metal_device != 0);
   device = [(id<MTLDevice>)metal_device retain];
   queue = [device newCommandQueue];
   CHECK(queue != nil);

   static struct virgl_renderer_callbacks callbacks;
   callbacks.version = 4;
   callbacks.create_gl_context = unexpected_create;
   callbacks.destroy_gl_context = unexpected_destroy;
   callbacks.make_current = unexpected_current;
   callbacks.get_egl_display = get_display;
   /* USE_EGL cannot initialize this build: ENABLE_GBM is disabled. The
    * exported external-display route initializes the actual Metal importer.
    * No RENDER_SERVER/NEPTUNE/THREAD_SYNC flag or context creation is used.
    */
   CHECK(virgl_renderer_init(&renderer_cookie, VIRGL_RENDERER_NO_VIRGL, &callbacks) == 0);
   CHECK(unexpected_callbacks == 0);

   int host_page_size = getpagesize();
   CHECK(host_page_size > 0 && host_page_size <= 65536);
   page_size = (size_t)host_page_size;
   NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:
                                  MTLPixelFormatBGRA8Unorm];
   CHECK(alignment != 0 && alignment <= 4096 &&
          (alignment & (alignment - 1)) == 0);
   row_stride = (uint32_t)(((NSUInteger)ACTIVE_ROW + alignment - 1) /
                           alignment * alignment);
   texture_offset = 0;
   size_t required = texture_offset + (size_t)row_stride * HEIGHT;
   mapping_size = ((required + page_size - 1) / page_size) * page_size;
   CHECK(mapping_size <= 36U * 1024U * 1024U);
}

static unsigned char pixel_byte(unsigned seed, unsigned y, unsigned byte)
{
   return (unsigned char)(seed * 29U + y * 41U + byte * 7U);
}

static void mutate(struct test_resource *resource, unsigned seed)
{
   resource->seed = seed;
   for (unsigned y = 0; y < HEIGHT; ++y)
      for (unsigned byte = 0; byte < ACTIVE_ROW; ++byte)
         resource->mapping[texture_offset + (size_t)y * row_stride + byte] =
            pixel_byte(seed, y, byte);
}

static void create_resource(int directory, unsigned index, uint32_t id)
{
   struct test_resource *resource = &resources[index];
   resource->id = id;
   CHECK(snprintf(resource->name, sizeof(resource->name), "buffer%u.shm", index) > 0);
   resource->original_fd = openat(directory, resource->name,
                                  O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
   CHECK(resource->original_fd >= 0);
   CHECK(ftruncate(resource->original_fd, (off_t)mapping_size) == 0);
   resource->mapping = mmap(NULL, mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                             resource->original_fd, 0);
   CHECK(resource->mapping != MAP_FAILED);
   memset(resource->mapping, 0xa5, mapping_size);
   mutate(resource, index + 1);
   resource->renderer_fd = dup(resource->original_fd);
   CHECK(resource->renderer_fd >= 0);
   CHECK(fcntl(resource->renderer_fd, F_SETFD, FD_CLOEXEC) == 0);
   const struct virgl_renderer_resource_import_blob_args arguments = {
      .res_handle = resource->id,
      .blob_mem = VIRGL_RENDERER_BLOB_MEM_HOST3D,
      .fd_type = VIRGL_RENDERER_BLOB_FD_TYPE_SHM,
      .fd = resource->renderer_fd,
      .size = mapping_size
   };
   CHECK(virgl_renderer_resource_import_blob(&arguments) == 0);
   resource->registered = true; /* Renderer now owns this duplicate FD. */
}

static void release_actual_texture(void *texture)
{
   virgl_renderer_release_handle_for_scanout(VIRGL_NATIVE_HANDLE_METAL_TEXTURE, texture);
}

/* Exercise only the linked renderer's public resource-table API. There is no
 * private cache helper, shadow importer or synthetic import-call counter.
 * Both old and new libraries return one caller-owned reference per acquisition.
 */
static void *acquire(unsigned index)
{
   struct test_resource *resource = &resources[index];
   CHECK(resource->registered);
   virgl_renderer_native_handle handle = NULL;
   enum virgl_renderer_native_handle_type type =
      virgl_renderer_create_handle_for_scanout(resource->id, WIDTH, HEIGHT,
         VIRGL_FORMAT_B8G8R8A8_UNORM, 0, row_stride, texture_offset, &handle);
   CHECK(type == VIRGL_NATIVE_HANDLE_METAL_TEXTURE && handle != NULL);
   return handle;
}

static void close_original(unsigned index)
{
   CHECK(resources[index].original_fd >= 0);
   CHECK(close(resources[index].original_fd) == 0);
   resources[index].original_fd = -1;
}

/* Separate caller mmap, actual importer MTLBuffer, and an actual GPU copy all
 * observe the newly written bytes. A nested pool releases each completed
 * command/encoder before subsequent lifetime checks. There is no getBytes
 * fallback, synthetic texture, shader compilation or copied importer model.
 */
static void verify_actual_alias(void *handle, struct test_resource *resource)
{
   @autoreleasepool {
      id<MTLTexture> texture = (id<MTLTexture>)handle;
      CHECK(texture.device == device && texture.pixelFormat == MTLPixelFormatBGRA8Unorm);
      CHECK(texture.width == WIDTH && texture.height == HEIGHT);
      CHECK(texture.storageMode == MTLStorageModeShared && texture.buffer != nil);
      CHECK(texture.bufferOffset == texture_offset && texture.bufferBytesPerRow == row_stride);
      CHECK(texture.buffer.length == mapping_size);
      CHECK(texture.buffer.contents != resource->mapping);
      CHECK(memcmp(texture.buffer.contents, resource->mapping, mapping_size) == 0);
      for (size_t offset = 0; offset < mapping_size; ++offset) {
         bool active = offset >= texture_offset &&
            offset < texture_offset + (size_t)row_stride * HEIGHT &&
            (offset - texture_offset) % row_stride < ACTIVE_ROW;
         if (!active)
            CHECK(resource->mapping[offset] == 0xa5);
      }

      size_t readback_size = (size_t)row_stride * HEIGHT;
      id<MTLBuffer> readback = [device newBufferWithLength:readback_size
                                                   options:MTLResourceStorageModeShared];
      CHECK(readback != nil);
      id<MTLCommandBuffer> command = [queue commandBuffer];
      id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
      CHECK(command != nil && blit != nil);
      [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(WIDTH, HEIGHT, 1)
                   toBuffer:readback destinationOffset:0 destinationBytesPerRow:row_stride
            destinationBytesPerImage:readback_size];
      [blit endEncoding];
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      CHECK(done != NULL);
      [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
         (void)completed;
         dispatch_semaphore_signal(done);
      }];
      [command commit];
      CHECK(dispatch_semaphore_wait(done,
         dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) == 0);
      CHECK(command.status == MTLCommandBufferStatusCompleted && command.error == nil);
      const unsigned char *bytes = readback.contents;
      for (unsigned y = 0; y < HEIGHT; ++y)
         for (unsigned byte = 0; byte < ACTIVE_ROW; ++byte)
            CHECK(bytes[(size_t)y * row_stride + byte] == pixel_byte(resource->seed, y, byte));
      ++gpu_reads;
      dispatch_release(done);
      [readback release];
   }
}

static void require_resource_absent(unsigned index)
{
   virgl_renderer_native_handle handle = NULL;
   CHECK(virgl_renderer_create_handle_for_scanout(resources[index].id, WIDTH, HEIGHT,
      VIRGL_FORMAT_B8G8R8A8_UNORM, 0, row_stride, texture_offset, &handle) ==
      VIRGL_NATIVE_HANDLE_NONE);
   CHECK(handle == NULL);
}

static int compare_ticks(const void *left, const void *right)
{
   const uint64_t a = *(const uint64_t *)left;
   const uint64_t b = *(const uint64_t *)right;
   return (a > b) - (a < b);
}

static long double nanoseconds(uint64_t ticks,
                               const mach_timebase_info_data_t *timebase)
{
   return (long double)ticks * timebase->numer / timebase->denom;
}

int main(int argc, char **argv)
{
   @autoreleasepool {
      CHECK(argc == 2);
      int output = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      CHECK(output >= 0);
      struct stat information;
      CHECK(fstat(output, &information) == 0 && S_ISDIR(information.st_mode));
      CHECK(information.st_uid == getuid() && (information.st_mode & 077) == 0);
      CHECK(mkdirat(output, "native-import-cost-scratch", 0700) == 0);
      int scratch = openat(output, "native-import-cost-scratch",
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      CHECK(scratch >= 0);

      mach_timebase_info_data_t timebase;
      CHECK(mach_timebase_info(&timebase) == 0 && timebase.numer && timebase.denom);
      initialize_real_renderer();
      for (unsigned index = 0; index < BUFFER_COUNT; ++index)
         create_resource(scratch, index, UINT32_C(0xcace1001) + index);

      /* Three independently owned anchors are kept until teardown. A temporary
       * result can equal its anchor only while that exact old object is alive;
       * allocator address recycling cannot manufacture a reported reuse hit.
       * No history of released pointer addresses is interpreted as uniqueness.
       */
      void *anchors[BUFFER_COUNT];
      for (unsigned index = 0; index < BUFFER_COUNT; ++index)
         anchors[index] = acquire(index);
      CHECK(anchors[0] != anchors[1] && anchors[0] != anchors[2] &&
            anchors[1] != anchors[2]);
      @autoreleasepool {
         for (unsigned call = 0; call < WARM_CALLS; ++call) {
            void *view = acquire(call % BUFFER_COUNT);
            release_actual_texture(view);
         }
      }

      /* Mutate after original imports. This detects stale copied pixels in the
       * retained views before the timed loop. All GPU work stays outside it.
       */
      for (unsigned index = 0; index < BUFFER_COUNT; ++index) {
         mutate(&resources[index], 31 + index);
         verify_actual_alias(anchors[index], &resources[index]);
      }

      uint64_t samples[TIMED_CALLS];
      unsigned anchor_matches[BUFFER_COUNT] = {0};
      unsigned anchor_misses[BUFFER_COUNT] = {0};
      uint64_t loop_start, loop_end;
      @autoreleasepool {
         loop_start = mach_absolute_time();
         for (unsigned call = 0; call < TIMED_CALLS; ++call) {
            unsigned index = call % BUFFER_COUNT;
            uint64_t start = mach_absolute_time();
            void *view = acquire(index);
            bool matches = view == anchors[index];
            release_actual_texture(view);
            uint64_t end = mach_absolute_time();
            CHECK(end >= start);
            samples[call] = end - start;
            if (matches)
               ++anchor_matches[index];
            else
               ++anchor_misses[index];
         }
         loop_end = mach_absolute_time();
      }
      CHECK(loop_end >= loop_start);
      for (unsigned index = 0; index < BUFFER_COUNT; ++index)
         CHECK(anchor_matches[index] + anchor_misses[index] ==
               TIMED_CALLS / BUFFER_COUNT);

      /* Check a fresh public-table view for each native resource after timing.
       * A cache implementation that returns stale pixels or a different
       * resource's texture fails here independently of identity statistics.
       */
      for (unsigned index = 0; index < BUFFER_COUNT; ++index) {
         mutate(&resources[index], 61 + index);
         void *view = acquire(index);
         verify_actual_alias(view, &resources[index]);
         release_actual_texture(view);
      }

      /* Destroy real table resources and original FDs, then verify the bounded
       * three caller-owned anchors still observe changes to their own pages.
       */
      for (unsigned index = 0; index < BUFFER_COUNT; ++index) {
         close_original(index);
         virgl_renderer_resource_unref(resources[index].id);
         resources[index].registered = false;
         require_resource_absent(index);
         mutate(&resources[index], 91 + index);
         verify_actual_alias(anchors[index], &resources[index]);
      }
      CHECK(gpu_reads == 9 && unexpected_callbacks == 0);
      virgl_renderer_cleanup(&renderer_cookie);
      for (unsigned index = 0; index < BUFFER_COUNT; ++index)
         release_actual_texture(anchors[index]);
      [queue release];
      queue = nil;
      [device release];
      device = nil;
      CHECK(eglTerminate(display) == EGL_TRUE);
      display = EGL_NO_DISPLAY;
      CHECK(eglReleaseThread() == EGL_TRUE);
      for (unsigned index = 0; index < BUFFER_COUNT; ++index) {
         CHECK(munmap(resources[index].mapping, mapping_size) == 0);
         resources[index].mapping = NULL;
         CHECK(unlinkat(scratch, resources[index].name, 0) == 0);
      }
      CHECK(close(scratch) == 0);
      CHECK(unlinkat(output, "native-import-cost-scratch", AT_REMOVEDIR) == 0);
      CHECK(close(output) == 0);

      /* Sorting, conversion and output happen only after timing and validation.
       * Nearest-rank p95 is item 1140 of 1200. Median averages items 600/601.
       */
      uint64_t ordered[TIMED_CALLS];
      memcpy(ordered, samples, sizeof(ordered));
      qsort(ordered, TIMED_CALLS, sizeof(ordered[0]), compare_ticks);
      uint64_t sample_total = 0;
      for (unsigned call = 0; call < TIMED_CALLS; ++call) {
         CHECK(UINT64_MAX - sample_total >= samples[call]);
         sample_total += samples[call];
      }
      long double median_ns = (nanoseconds(ordered[TIMED_CALLS / 2 - 1], &timebase) +
                               nanoseconds(ordered[TIMED_CALLS / 2], &timebase)) / 2;
      long double p95_ns = nanoseconds(ordered[(TIMED_CALLS * 95 + 99) / 100 - 1],
                                      &timebase);
      printf("{\"status\":\"PASS\",\"benchmark\":\"public_scanout_import_cost\","
             "\"width\":%u,\"height\":%u,\"buffers\":%u,\"row_stride\":%u,"
             "\"mapped_bytes_per_buffer\":%zu,\"anchor_acquisitions\":%u,"
             "\"warm_acquire_release_calls\":%u,\"timed_acquire_release_calls\":%u,"
             "\"post_validation_acquisitions\":%u,\"calls_per_buffer\":%u,"
             "\"live_anchor_matches\":[%u,%u,%u],\"live_anchor_misses\":[%u,%u,%u],"
             "\"pair_median_ns\":%.3Lf,\"pair_p95_ns\":%.3Lf,"
             "\"pair_sample_total_ns\":%.3Lf,\"loop_elapsed_ns\":%.3Lf,"
             "\"gpu_reads_outside_timing\":%u,\"global_unique_handles_counted\":false,"
             "\"rendering_or_fps_measured\":false}\n",
             (unsigned)WIDTH, (unsigned)HEIGHT, (unsigned)BUFFER_COUNT, row_stride,
             mapping_size, (unsigned)BUFFER_COUNT, (unsigned)WARM_CALLS,
             (unsigned)TIMED_CALLS, (unsigned)BUFFER_COUNT,
             (unsigned)(TIMED_CALLS / BUFFER_COUNT),
             anchor_matches[0], anchor_matches[1], anchor_matches[2],
             anchor_misses[0], anchor_misses[1], anchor_misses[2],
             median_ns, p95_ns, nanoseconds(sample_total, &timebase),
             nanoseconds(loop_end - loop_start, &timebase), gpu_reads);
   }
   return 0;
}
