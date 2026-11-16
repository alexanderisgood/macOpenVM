// SPDX-License-Identifier: Apache-2.0
#include <assert.h>
#include "storage_plan.h"

typedef struct {
  int valid, absent, reads, calls, verified;
  unsigned long hibernateExit, trimExit;
} Fixture;
static int volume(void *opaque) {
  Fixture *f = opaque; f->reads++; return f->valid;
}
static unsigned long run(void *opaque, enum MVOStorageStep step) {
  Fixture *f = opaque;
  assert((f->calls++ % 2 == 0) == (step == MVO_DISABLE_HIBERNATION));
  return step == MVO_DISABLE_HIBERNATION ? f->hibernateExit : f->trimExit;
}
static int absent(void *opaque) {
  Fixture *f = opaque; f->verified++; return f->absent;
}
static MVOStorageResult apply(Fixture *f, int selected) {
  MVOStorageOperations ops = { f, volume, run, absent };
  return mvoOptimizeStorage(selected, ops);
}
int main(void) {
  Fixture f = { .valid = 1, .absent = 1 };
  MVOStorageResult r = apply(&f, 0);
  assert(r.hibernation == MVO_STORAGE_SKIPPED && r.reclaim == MVO_STORAGE_SKIPPED);
  assert(!f.reads && !f.calls && !f.verified);
  r = apply(&f, 1);
  assert(r.hibernation == MVO_STORAGE_READY && r.reclaim == MVO_STORAGE_READY);
  r = apply(&f, 1); // Repeat with hibernation already disabled.
  assert(r.hibernation == MVO_STORAGE_READY && r.reclaim == MVO_STORAGE_READY);
  assert(f.calls == 4 && f.verified == 2);
  f = (Fixture){ .valid = 0 };
  r = apply(&f, 1);
  assert(r.hibernation == MVO_STORAGE_VOLUME_FAILED && r.reclaim == MVO_STORAGE_VOLUME_FAILED);
  assert(!f.calls && !f.verified);
  f = (Fixture){ .valid = 1, .absent = 1, .hibernateExit = 5 };
  r = apply(&f, 1);
  assert(r.hibernation == MVO_STORAGE_COMMAND_FAILED && r.reclaim == MVO_STORAGE_READY);
  assert(f.calls == 2 && !f.verified);
  for (int state = -1; state <= 0; state++) {
    f = (Fixture){ .valid = 1, .absent = state };
    r = apply(&f, 1);
    assert(r.hibernation == MVO_STORAGE_VERIFY_FAILED && r.reclaim == MVO_STORAGE_READY);
    assert(f.calls == 2 && f.verified == 1);
  }
  f = (Fixture){ .valid = 1, .absent = 1, .trimExit = 50 };
  r = apply(&f, 1);
  assert(r.hibernation == MVO_STORAGE_READY && r.reclaim == MVO_STORAGE_COMMAND_FAILED);
  f = (Fixture){ .valid = 1, .hibernateExit = 5, .trimExit = 50 };
  r = apply(&f, 1);
  assert(r.hibernation == MVO_STORAGE_COMMAND_FAILED && r.reclaim == MVO_STORAGE_COMMAND_FAILED);
  return 0;
}
