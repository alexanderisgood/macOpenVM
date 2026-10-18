/* SPDX-License-Identifier: MIT
 * Finite component regression for the exact production cache helper.
 * Backend objects below count owned references; they are not Metal stand-ins
 * for pixels, mappings, GPU completion, device behavior or performance.
 */
#include "virgl_scanout_cache.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
   if (!(condition)) { \
      fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
      exit(1); \
   } \
} while (0)

struct counted_texture {
   unsigned references;
   unsigned serial;
   struct virgl_scanout_cache_key imported;
};

static struct {
   struct counted_texture textures[512];
   unsigned attempts, imports, retains, releases, destroyed, live;
   bool fail_next;
} backend;
static int device_a, device_b;
static struct virgl_scanout_cache_pool test_pool;
static struct virgl_scanout_cache *release_must_observe_unlinked;
static void *watched_texture;
static unsigned watched_count;
static uint64_t watched_bytes;
static bool unlink_observed;

static void
reset_backend(void)
{
   CHECK(backend.live == 0);
   CHECK(test_pool.count == 0 && test_pool.bytes == 0);
   memset(&backend, 0, sizeof(backend));
   virgl_scanout_cache_pool_init(&test_pool, 16384);
}

static void *
create_texture(const struct virgl_scanout_cache_key *key)
{
   backend.attempts++;
   if (backend.fail_next) {
      backend.fail_next = false;
      return NULL;
   }
   CHECK(backend.imports < 512);
   struct counted_texture *texture = &backend.textures[backend.imports++];
   texture->references = 1;
   texture->serial = backend.imports;
   texture->imported = *key;
   backend.live++;
   return texture;
}

static void *
retain_texture(void *opaque)
{
   struct counted_texture *texture = opaque;
   CHECK(texture && texture->references > 0);
   texture->references++;
   backend.retains++;
   return texture;
}

static void
release_texture(void *opaque)
{
   struct counted_texture *texture = opaque;
   CHECK(texture && texture->references > 0);
   if (release_must_observe_unlinked && opaque == watched_texture) {
      CHECK(release_must_observe_unlinked->texture == NULL);
      CHECK(release_must_observe_unlinked->charge == 0);
      CHECK(test_pool.count == watched_count && test_pool.bytes == watched_bytes);
      for (unsigned i = 0; i < test_pool.count; i++)
         CHECK(test_pool.entries[i] != release_must_observe_unlinked);
      unlink_observed = true;
   }
   backend.releases++;
   if (--texture->references == 0) {
      backend.destroyed++;
      backend.live--;
   }
}

static struct virgl_scanout_cache_key
native_key(void)
{
   return (struct virgl_scanout_cache_key) {
      .winsys = &device_a, .fd = 17, .size = 29982720,
      .width = 3456, .height = 2168, .stride = 13824,
      .offset = 0, .format = 80,
   };
}

static struct counted_texture *
acquire(struct virgl_scanout_cache *cache,
        const struct virgl_scanout_cache_key *key)
{
   /* Same owner binding as production virgl_resource_create; no cache logic
    * is duplicated in this fixture wrapper. */
   if (!cache->pool)
      cache->pool = &test_pool;
   return virgl_scanout_cache_acquire(cache, key, create_texture,
                                       retain_texture, release_texture);
}

static void
clear(struct virgl_scanout_cache *cache)
{
   virgl_scanout_cache_clear(cache, release_texture);
}

static void
same_key_keeps_one_cache_reference_and_two_callers(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *first = acquire(&cache, &key);
   struct counted_texture *second = acquire(&cache, &key);
   CHECK(first == second);
   CHECK(backend.attempts == 1 && backend.imports == 1);
   CHECK(first->references == 3 && backend.retains == 2);
   release_texture(first);
   CHECK(second->references == 2);
   release_texture(second);
   CHECK(backend.live == 1 && backend.destroyed == 0);
   clear(&cache);
   CHECK(backend.live == 0 && backend.destroyed == 1);
}

static void
replacement_and_clear_preserve_outstanding_callers(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *old = acquire(&cache, &key);
   key.offset = 256;
   struct counted_texture *replacement = acquire(&cache, &key);
   CHECK(old != replacement && old->references == 1);
   CHECK(replacement->references == 2 && backend.live == 2);
   clear(&cache);
   CHECK(replacement->references == 1 && backend.live == 2);
   release_texture(old);
   CHECK(backend.live == 1);
   release_texture(replacement);
   CHECK(backend.destroyed == 2 && backend.live == 0);
}

static void
failed_changed_import_never_returns_the_prior_view(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *old = acquire(&cache, &key);
   struct virgl_scanout_cache_key changed = key;
   changed.width--;
   backend.fail_next = true;
   unsigned retains = backend.retains, releases = backend.releases;
   CHECK(acquire(&cache, &changed) == NULL);
   CHECK(backend.attempts == 2 && backend.imports == 1);
   CHECK(backend.retains == retains && backend.releases == releases);
   CHECK(old->references == 2);
   struct counted_texture *again = acquire(&cache, &key);
   CHECK(again == old && again->references == 3);
   CHECK(backend.attempts == 2);
   release_texture(old);
   release_texture(again);
   clear(&cache);
   CHECK(backend.live == 0 && backend.destroyed == 1);
}

static void
failed_empty_import_does_not_create_ownership(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   backend.fail_next = true;
   CHECK(acquire(&cache, &key) == NULL);
   CHECK(backend.imports == 0 && backend.retains == 0);
   clear(&cache);
   CHECK(backend.releases == 0 && backend.destroyed == 0);
   struct counted_texture *valid = acquire(&cache, &key);
   CHECK(valid && backend.attempts == 2 && valid->references == 2);
   release_texture(valid);
   clear(&cache);
   CHECK(backend.live == 0 && backend.destroyed == 1);
}

static void
every_interpretation_field_requires_a_fresh_import(void)
{
   for (unsigned field = 0; field < 8; field++) {
      reset_backend();
      struct virgl_scanout_cache cache = {0};
      struct virgl_scanout_cache_key key = native_key();
      struct counted_texture *old = acquire(&cache, &key);
      switch (field) {
      case 0: key.winsys = &device_b; break;
      case 1: key.fd++; break;
      case 2: key.size += 16384; break;
      case 3: key.width--; break;
      case 4: key.height--; break;
      case 5: key.stride += 256; break;
      case 6: key.offset = 256; break;
      case 7: key.format++; break;
      }
      struct counted_texture *fresh = acquire(&cache, &key);
      CHECK(fresh && fresh != old && backend.attempts == 2);
      CHECK(old->references == 1 && fresh->references == 2);
      CHECK(fresh->imported.winsys == key.winsys);
      CHECK(fresh->imported.fd == key.fd && fresh->imported.size == key.size);
      CHECK(fresh->imported.width == key.width && fresh->imported.height == key.height);
      CHECK(fresh->imported.stride == key.stride && fresh->imported.offset == key.offset);
      CHECK(fresh->imported.format == key.format);
      release_texture(old);
      release_texture(fresh);
      clear(&cache);
      CHECK(backend.live == 0 && backend.destroyed == 2);
   }
}

static void
separate_resources_never_share_a_cache_by_fd_or_layout(void)
{
   struct virgl_scanout_cache resources[2] = {0};
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *a = acquire(&resources[0], &key);
   struct counted_texture *b = acquire(&resources[1], &key);
   CHECK(a != b && backend.imports == 2);
   release_texture(a);
   release_texture(b);
   clear(&resources[0]);
   CHECK(backend.live == 1);
   clear(&resources[1]);
   CHECK(backend.live == 0 && backend.destroyed == 2);
}

static void
two_and_three_revisited_buffers_import_once_each(void)
{
   for (unsigned buffer_count = 2; buffer_count <= 3; buffer_count++) {
      reset_backend();
      struct virgl_scanout_cache resources[3] = {0};
      for (unsigned frame = 0; frame < 24; frame++) {
         unsigned resource = frame % buffer_count;
         struct virgl_scanout_cache_key key = native_key();
         key.fd += resource;
         struct counted_texture *texture = acquire(&resources[resource], &key);
         CHECK(texture && texture->references == 2);
         CHECK(texture->imported.fd == key.fd);
         release_texture(texture);
      }
      CHECK(backend.attempts == buffer_count && backend.live == buffer_count);
      CHECK(test_pool.count == buffer_count);
      CHECK(test_pool.bytes == (uint64_t)buffer_count * native_key().size);
      for (unsigned resource = 0; resource < buffer_count; resource++)
         clear(&resources[resource]);
      CHECK(backend.live == 0 && backend.destroyed == buffer_count);
      CHECK(test_pool.count == 0 && test_pool.bytes == 0);
   }
}

static void
clear_then_same_fd_layout_requires_new_import(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *old_caller = acquire(&cache, &key);
   clear(&cache);
   CHECK(old_caller->references == 1);
   struct counted_texture *new_caller = acquire(&cache, &key);
   CHECK(new_caller != old_caller && backend.imports == 2);
   CHECK(old_caller->references == 1 && new_caller->references == 2);
   release_texture(old_caller);
   clear(&cache);
   CHECK(new_caller->references == 1);
   release_texture(new_caller);
   CHECK(backend.live == 0 && backend.destroyed == 2);
}

static void
many_historically_scanned_resources_keep_only_three_cache_references(void)
{
   struct virgl_scanout_cache resources[32] = {0};
   for (unsigned resource = 0; resource < 32; resource++) {
      struct virgl_scanout_cache_key key = native_key();
      key.fd += resource;
      struct counted_texture *texture = acquire(&resources[resource], &key);
      CHECK(texture && texture->imported.size == key.size);
      release_texture(texture);
      CHECK(test_pool.count <= 3 && test_pool.bytes <= VIRGL_SCANOUT_CACHE_BYTES);
      CHECK(backend.live <= 3);
   }
   CHECK(backend.imports == 32 && backend.live == 3 && backend.destroyed == 29);
   for (unsigned resource = 0; resource < 32; resource++)
      clear(&resources[resource]);
   CHECK(backend.live == 0 && backend.destroyed == 32);
   CHECK(test_pool.count == 0 && test_pool.bytes == 0);
}

static void
repeated_empty_clear_is_idempotent(void)
{
   struct virgl_scanout_cache cache = {0};
   clear(&cache);
   clear(&cache);
   CHECK(backend.releases == 0);
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *caller = acquire(&cache, &key);
   release_texture(caller);
   clear(&cache);
   unsigned releases = backend.releases;
   clear(&cache);
   CHECK(backend.releases == releases && backend.destroyed == 1);
}

static void
hit_promotes_the_resource_and_evicts_the_least_recent_view(void)
{
   struct virgl_scanout_cache resources[4] = {0};
   struct virgl_scanout_cache_key key = native_key();
   for (unsigned i = 0; i < 3; i++) {
      key.fd = 17 + (int)i;
      release_texture(acquire(&resources[i], &key));
   }
   key.fd = 17;
   release_texture(acquire(&resources[0], &key));
   CHECK(backend.attempts == 3);
   key.fd = 20;
   release_texture(acquire(&resources[3], &key));
   CHECK(resources[1].texture == NULL && resources[0].texture != NULL);
   CHECK(resources[2].texture != NULL && resources[3].texture != NULL);
   key.fd = 17;
   release_texture(acquire(&resources[0], &key));
   CHECK(backend.attempts == 4);
   key.fd = 18;
   release_texture(acquire(&resources[1], &key));
   CHECK(backend.attempts == 5 && resources[2].texture == NULL);
   for (unsigned i = 0; i < 4; i++)
      clear(&resources[i]);
   CHECK(backend.live == 0 && test_pool.bytes == 0 && test_pool.count == 0);
}

static void
whole_resource_bytes_can_evict_before_the_entry_count_cap(void)
{
   struct virgl_scanout_cache resources[3] = {0};
   struct virgl_scanout_cache_key key = native_key();
   key.size = UINT64_C(40) * 1024 * 1024;
   for (unsigned i = 0; i < 3; i++) {
      key.fd = 17 + (int)i;
      release_texture(acquire(&resources[i], &key));
   }
   CHECK(test_pool.count == 2 && test_pool.bytes == UINT64_C(80) * 1024 * 1024);
   CHECK(resources[0].texture == NULL && backend.destroyed == 1);
   CHECK(resources[1].charge == key.size && resources[2].charge == key.size);
   for (unsigned i = 0; i < 3; i++)
      clear(&resources[i]);
   CHECK(backend.live == 0 && test_pool.bytes == 0);
}

static void
page_rounding_is_charged_instead_of_visible_bytes_or_raw_size(void)
{
   struct virgl_scanout_cache resources[3] = {0};
   struct virgl_scanout_cache_key key = native_key();
   key.size = UINT64_C(32) * 1024 * 1024 + 1;
   uint64_t expected = UINT64_C(32) * 1024 * 1024 + 16384;
   for (unsigned i = 0; i < 3; i++) {
      key.fd = 17 + (int)i;
      release_texture(acquire(&resources[i], &key));
   }
   CHECK(test_pool.count == 2 && test_pool.bytes == expected * 2);
   CHECK(resources[0].texture == NULL);
   CHECK(resources[1].charge == expected && resources[2].charge == expected);
   for (unsigned i = 0; i < 3; i++)
      clear(&resources[i]);
   CHECK(test_pool.bytes == 0 && backend.live == 0);
}

static void
oversized_success_is_returned_uncached_instead_of_rejected(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   key.size = UINT64_C(256) * 1024 * 1024;
   struct counted_texture *a = acquire(&cache, &key);
   CHECK(a && a->references == 1);
   CHECK(cache.texture == NULL && test_pool.count == 0 && test_pool.bytes == 0);
   struct counted_texture *b = acquire(&cache, &key);
   CHECK(b && b != a && b->references == 1);
   CHECK(backend.attempts == 2 && backend.retains == 0);
   release_texture(a);
   release_texture(b);
   clear(&cache);
   CHECK(backend.live == 0 && backend.destroyed == 2);
}

static void
changed_oversized_success_keeps_the_previous_cache_and_accounting(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *old = acquire(&cache, &key);
   release_texture(old);
   uint64_t bytes = test_pool.bytes;
   struct virgl_scanout_cache_key changed = key;
   changed.size = VIRGL_SCANOUT_CACHE_BYTES + 1;
   struct counted_texture *large = acquire(&cache, &changed);
   CHECK(large && large->references == 1 && old->references == 1);
   CHECK(cache.texture == old && test_pool.count == 1 && test_pool.bytes == bytes);
   struct counted_texture *again = acquire(&cache, &key);
   CHECK(again == old && backend.attempts == 2 && again->references == 2);
   release_texture(again);
   clear(&cache);
   CHECK(large->references == 1 && backend.live == 1);
   release_texture(large);
   CHECK(backend.live == 0 && test_pool.bytes == 0);
}

static void
unaccountable_size_and_missing_pool_bypass_without_ownership_changes(void)
{
   struct virgl_scanout_cache cache = {0};
   struct virgl_scanout_cache_key key = native_key();
   key.size = UINT64_MAX;
   struct counted_texture *overflow = acquire(&cache, &key);
   CHECK(overflow && overflow->references == 1 && cache.texture == NULL);
   CHECK(test_pool.bytes == 0 && backend.retains == 0);
   release_texture(overflow);
   key = native_key();
   struct virgl_scanout_cache unattached = {0};
   struct counted_texture *no_pool = virgl_scanout_cache_acquire(
      &unattached, &key, create_texture, retain_texture, release_texture);
   CHECK(no_pool && no_pool->references == 1 && unattached.texture == NULL);
   release_texture(no_pool);
   uint64_t untouched = 91;
   CHECK(!virgl_scanout_cache_charge(UINT64_MAX, 16384, &untouched));
   CHECK(untouched == 91);
   CHECK(!virgl_scanout_cache_charge(1, 0, &untouched));
   CHECK(untouched == 91);
   clear(&cache);
   clear(&unattached);
   CHECK(backend.live == 0 && test_pool.count == 0);
}

static void
failed_import_with_a_full_pool_preserves_all_entries_and_lru_order(void)
{
   struct virgl_scanout_cache resources[4] = {0};
   struct virgl_scanout_cache_key key = native_key();
   for (unsigned i = 0; i < 3; i++) {
      key.fd = 17 + (int)i;
      release_texture(acquire(&resources[i], &key));
   }
   uint64_t bytes = test_pool.bytes;
   backend.fail_next = true;
   key.fd = 20;
   CHECK(acquire(&resources[3], &key) == NULL);
   CHECK(test_pool.count == 3 && test_pool.bytes == bytes && backend.destroyed == 0);
   CHECK(test_pool.entries[0] == &resources[0]);
   CHECK(test_pool.entries[1] == &resources[1]);
   CHECK(test_pool.entries[2] == &resources[2]);
   release_texture(acquire(&resources[3], &key));
   CHECK(resources[0].texture == NULL && backend.attempts == 5);
   for (unsigned i = 0; i < 4; i++)
      clear(&resources[i]);
   CHECK(backend.live == 0 && test_pool.bytes == 0);
}

static void
evicted_cache_reference_does_not_destroy_an_outstanding_caller(void)
{
   struct virgl_scanout_cache resources[4] = {0};
   struct virgl_scanout_cache_key key = native_key();
   struct counted_texture *caller = acquire(&resources[0], &key);
   for (unsigned i = 1; i < 4; i++) {
      key.fd = 17 + (int)i;
      release_texture(acquire(&resources[i], &key));
   }
   CHECK(resources[0].texture == NULL && caller->references == 1);
   CHECK(test_pool.count == 3 && backend.live == 4);
   CHECK(test_pool.bytes <= VIRGL_SCANOUT_CACHE_BYTES);
   clear(&resources[0]);
   CHECK(caller->references == 1);
   release_texture(caller);
   CHECK(backend.live == 3);
   for (unsigned i = 1; i < 4; i++)
      clear(&resources[i]);
   CHECK(backend.live == 0 && test_pool.count == 0 && test_pool.bytes == 0);
}

static void
eviction_unlinks_debits_and_zeroes_before_backend_release(void)
{
   struct virgl_scanout_cache resources[4] = {0};
   struct virgl_scanout_cache_key key = native_key();
   for (unsigned i = 0; i < 3; i++) {
      key.fd = 17 + (int)i;
      release_texture(acquire(&resources[i], &key));
   }
   release_must_observe_unlinked = &resources[0];
   watched_texture = resources[0].texture;
   watched_count = 2;
   watched_bytes = 2 * native_key().size;
   unlink_observed = false;
   key.fd = 20;
   release_texture(acquire(&resources[3], &key));
   CHECK(unlink_observed);
   release_must_observe_unlinked = NULL;
   watched_texture = NULL;
   for (unsigned i = 0; i < 4; i++)
      clear(&resources[i]);
   CHECK(test_pool.count == 0 && test_pool.bytes == 0);
   for (unsigned i = 0; i < VIRGL_SCANOUT_CACHE_ENTRIES; i++)
      CHECK(test_pool.entries[i] == NULL);
}

#define RUN(test) do { \
   reset_backend(); \
   test(); \
   CHECK(backend.live == 0); \
   puts("PASS " #test); \
} while (0)

int
main(void)
{
   RUN(same_key_keeps_one_cache_reference_and_two_callers);
   RUN(replacement_and_clear_preserve_outstanding_callers);
   RUN(failed_changed_import_never_returns_the_prior_view);
   RUN(failed_empty_import_does_not_create_ownership);
   RUN(every_interpretation_field_requires_a_fresh_import);
   RUN(separate_resources_never_share_a_cache_by_fd_or_layout);
   RUN(two_and_three_revisited_buffers_import_once_each);
   RUN(clear_then_same_fd_layout_requires_new_import);
   RUN(many_historically_scanned_resources_keep_only_three_cache_references);
   RUN(repeated_empty_clear_is_idempotent);
   RUN(hit_promotes_the_resource_and_evicts_the_least_recent_view);
   RUN(whole_resource_bytes_can_evict_before_the_entry_count_cap);
   RUN(page_rounding_is_charged_instead_of_visible_bytes_or_raw_size);
   RUN(oversized_success_is_returned_uncached_instead_of_rejected);
   RUN(changed_oversized_success_keeps_the_previous_cache_and_accounting);
   RUN(unaccountable_size_and_missing_pool_bypass_without_ownership_changes);
   RUN(failed_import_with_a_full_pool_preserves_all_entries_and_lru_order);
   RUN(evicted_cache_reference_does_not_destroy_an_outstanding_caller);
   RUN(eviction_unlinks_debits_and_zeroes_before_backend_release);
   puts("PASS 19 component cases; key-field case covers 8 independent changes");
   return 0;
}
