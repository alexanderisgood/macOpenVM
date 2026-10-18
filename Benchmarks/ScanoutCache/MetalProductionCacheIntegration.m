/* SPDX-License-Identifier: MIT
 * SOURCE ONLY. Actual R3-patched renderer public resource-table integration.
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
#include "virglrenderer.h"
#include "virgl_hw.h"

#define CHECK(condition) do { if (!(condition)) { \
   fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)

enum { BUFFER_COUNT = 6, WIDTH = 16, HEIGHT = 4, ACTIVE_ROW = WIDTH * 4 };
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
   row_stride = (uint32_t)(alignment > 256 ? alignment : 256);
   texture_offset = row_stride;
   size_t required = texture_offset + (size_t)row_stride * HEIGHT;
   mapping_size = ((required + page_size - 1) / page_size) * page_size;
   CHECK(mapping_size <= 65536);
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

/* This reaches the actual R3 library's resource-owned cache. The fixture has
 * no helper include, shadow cache, importer adapter or import-call counter.
 * Each successful call returns one independent caller-owned reference.
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

int main(int argc, char **argv)
{
   @autoreleasepool {
      CHECK(argc == 2);
      /* Root separately qualifies the staged R3-patched renderer image and
       * exact loader providers. Only this new private scratch child changes.
       */
      int output = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      CHECK(output >= 0);
      struct stat information;
      CHECK(fstat(output, &information) == 0 && S_ISDIR(information.st_mode));
      CHECK(information.st_uid == getuid() && (information.st_mode & 077) == 0);
      CHECK(mkdirat(output, "production-metal-cache-scratch", 0700) == 0);
      int scratch = openat(output, "production-metal-cache-scratch",
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      CHECK(scratch >= 0);
      initialize_real_renderer();
      for (unsigned index = 0; index < 4; ++index)
         create_resource(scratch, index, UINT32_C(0xcace0001) + index);
      puts("PASS actual_r3_public_resource_imports");

      void *first = acquire(0); /* This owned anchor remains live until teardown. */
      verify_actual_alias(first, &resources[0]);
      mutate(&resources[0], 9);
      void *same = acquire(0);
      CHECK(first == same); /* R3 hit returns the same retained texture object. */
      verify_actual_alias(same, &resources[0]);
      release_actual_texture(same);
      puts("PASS actual_cache_hit_observes_shared_mutation");

      void *anchors[3] = { first, acquire(1), NULL };
      for (unsigned frame = 0; frame < 6; ++frame) {
         unsigned index = frame % 2;
         mutate(&resources[index], 20 + frame);
         void *view = acquire(index);
         CHECK(view == anchors[index]);
         verify_actual_alias(view, &resources[index]);
         release_actual_texture(view);
      }
      puts("PASS actual_two_buffer_texture_reuse");

      anchors[2] = acquire(2);
      for (unsigned frame = 0; frame < 9; ++frame) {
         unsigned index = frame % 3;
         mutate(&resources[index], 40 + frame);
         void *view = acquire(index);
         CHECK(view == anchors[index]);
         verify_actual_alias(view, &resources[index]);
         release_actual_texture(view);
      }
      puts("PASS actual_three_buffer_texture_reuse");

      void *fourth = acquire(3); /* Actual R3 LRU order was 0, 1, 2. */
      mutate(&resources[0], 70);
      verify_actual_alias(first, &resources[0]);
      verify_actual_alias(fourth, &resources[3]);
      void *fresh = acquire(0); /* Cache 0 was evicted, but first is still owned. */
      CHECK(fresh != first);
      CHECK([(id<MTLTexture>)fresh buffer].contents !=
            [(id<MTLTexture>)first buffer].contents);
      verify_actual_alias(fresh, &resources[0]);
      same = acquire(0);
      CHECK(same == fresh);
      release_actual_texture(same);
      puts("PASS actual_eviction_preserves_caller_and_reimports");

      close_original(0);
      mutate(&resources[0], 71);
      verify_actual_alias(first, &resources[0]);
      verify_actual_alias(fresh, &resources[0]);
      /* No manual helper clear: the actual R3 resource destructor must unlink
       * and release its cache-owned reference before closing its duplicate.
       */
      virgl_renderer_resource_unref(resources[0].id);
      resources[0].registered = false;
      require_resource_absent(0);
      mutate(&resources[0], 72);
      verify_actual_alias(first, &resources[0]);
      verify_actual_alias(fresh, &resources[0]);
      puts("PASS actual_unref_and_fd_close_preserve_callers");

      create_resource(scratch, 4, resources[0].id); /* Reuse only the numeric ID. */
      void *replacement = acquire(4);
      CHECK(replacement != first && replacement != fresh);
      verify_actual_alias(replacement, &resources[4]);
      mutate(&resources[0], 90);
      mutate(&resources[4], 91);
      verify_actual_alias(first, &resources[0]);
      verify_actual_alias(fresh, &resources[0]);
      verify_actual_alias(replacement, &resources[4]);
      puts("PASS numeric_resource_id_reuse_has_independent_pages");

      /* Cached resources 2, 3 and 4 are live here. Real table reset must run
       * their R3 destructors. Strong caller handles also retain evicted views.
       */
      virgl_renderer_reset();
      for (unsigned index = 0; index < 5; ++index) {
         resources[index].registered = false;
         require_resource_absent(index);
         if (resources[index].original_fd >= 0)
            close_original(index);
      }
      mutate(&resources[1], 101);
      mutate(&resources[2], 102);
      mutate(&resources[3], 103);
      mutate(&resources[4], 104);
      verify_actual_alias(anchors[1], &resources[1]);
      verify_actual_alias(anchors[2], &resources[2]);
      verify_actual_alias(fourth, &resources[3]);
      verify_actual_alias(replacement, &resources[4]);
      mutate(&resources[0], 105);
      verify_actual_alias(first, &resources[0]);
      verify_actual_alias(fresh, &resources[0]);
      puts("PASS actual_table_reset_preserves_all_owned_views");

      create_resource(scratch, 5, resources[1].id); /* Reset permits ID reuse. */
      void *after_reset = acquire(5);
      CHECK(after_reset != anchors[1]); /* Both independently owned and live. */
      verify_actual_alias(after_reset, &resources[5]);
      mutate(&resources[5], 111);
      same = acquire(5);
      CHECK(same == after_reset);
      verify_actual_alias(same, &resources[5]);
      release_actual_texture(same);
      puts("PASS actual_pool_reuse_after_reset");

      close_original(5);
      mutate(&resources[5], 112);
      verify_actual_alias(after_reset, &resources[5]);
      /* A populated actual table is destroyed before winsys cleanup. There
       * are no public lookups after cleanup; only release_handle is used.
       */
      virgl_renderer_cleanup(&renderer_cookie);
      resources[5].registered = false;
      mutate(&resources[5], 113);
      verify_actual_alias(after_reset, &resources[5]);
      CHECK(gpu_reads == 38 && unexpected_callbacks == 0);
      puts("PASS actual_cleanup_preserves_independent_caller");

      release_actual_texture(after_reset);
      release_actual_texture(replacement);
      release_actual_texture(fourth);
      release_actual_texture(anchors[2]);
      release_actual_texture(anchors[1]);
      release_actual_texture(fresh);
      release_actual_texture(first);
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
      CHECK(unlinkat(output, "production-metal-cache-scratch", AT_REMOVEDIR) == 0);
      CHECK(close(output) == 0);
      puts("PASS owned_handle_release_and_private_scratch_removal");
      puts("PASS all 11 actual R3 renderer integration cases (38 GPU reads)");
   }
   return 0;
}
