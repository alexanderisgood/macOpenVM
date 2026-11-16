// SPDX-License-Identifier: Apache-2.0
#ifndef MACOPENVM_STORAGE_PLAN_H
#define MACOPENVM_STORAGE_PLAN_H

enum MVOStorageStep { MVO_DISABLE_HIBERNATION, MVO_RETRIM };
enum MVOStorageState { MVO_STORAGE_SKIPPED, MVO_STORAGE_READY,
  MVO_STORAGE_COMMAND_FAILED, MVO_STORAGE_VERIFY_FAILED, MVO_STORAGE_VOLUME_FAILED };
typedef struct { enum MVOStorageState hibernation, reclaim; } MVOStorageResult;
typedef struct {
  void *context;
  int (*volume)(void *);
  unsigned long (*run)(void *, enum MVOStorageStep);
  int (*hibernationAbsent)(void *);
} MVOStorageOperations;

// Separate outcomes: a successful reclaim cannot conceal failed hibernation
// setup. An unchecked option performs no reads or writes through the adapter.
static MVOStorageResult mvoOptimizeStorage(int selected, MVOStorageOperations ops) {
  MVOStorageResult result = { MVO_STORAGE_SKIPPED, MVO_STORAGE_SKIPPED };
  if (!selected) return result;
  if (!ops.volume(ops.context)) {
    result.hibernation = result.reclaim = MVO_STORAGE_VOLUME_FAILED;
    return result;
  }
  result.hibernation = ops.run(ops.context, MVO_DISABLE_HIBERNATION)
    ? MVO_STORAGE_COMMAND_FAILED : ops.hibernationAbsent(ops.context) == 1
    ? MVO_STORAGE_READY : MVO_STORAGE_VERIFY_FAILED;
  result.reclaim = ops.run(ops.context, MVO_RETRIM)
    ? MVO_STORAGE_COMMAND_FAILED : MVO_STORAGE_READY;
  return result;
}
#endif
