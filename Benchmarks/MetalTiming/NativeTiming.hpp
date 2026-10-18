// SPDX-License-Identifier: Apache-2.0
// Local native experiment only. Default-off dependency hook; no trace capture.
#pragma once
#include "Report.hpp"
#include <mach/mach_time.h>
#include <limits>
#include <cerrno>
#include <unistd.h>

namespace mvo_gpu_timing {
inline Budget &processBudget() { static Budget budget; return budget; }
inline uint32_t nextQueue() {
  static std::atomic<uint32_t> next{1};
  auto value = next.load(std::memory_order_relaxed);
  while (value != std::numeric_limits<uint32_t>::max()) {
    if (next.compare_exchange_weak(value, value + 1, std::memory_order_relaxed)) return value;
  }
  return 0; // Saturated ordinal is explicitly unknown; never a process identity.
}
inline uint64_t nowNS() {
  static const mach_timebase_info_data_t scale = [] {
    mach_timebase_info_data_t value{};
    if (mach_timebase_info(&value) != KERN_SUCCESS) return mach_timebase_info_data_t{};
    return value;
  }();
  if (!scale.denom || !scale.numer) return 0;
  auto ns = static_cast<__uint128_t>(mach_absolute_time()) * scale.numer / scale.denom;
  return ns <= std::numeric_limits<uint64_t>::max() ? static_cast<uint64_t>(ns) : 0;
}
inline void report(void *, uint32_t queue, const Sample *samples, size_t count) {
  // Keep numeric diagnostics below the owned worker's existing 2 MiB log cap.
  // The record count alone cannot bound bytes when many queues end partially.
  static Budget bytes(1048576);
  static std::atomic<bool> stopReported{false};
  // Correlation only: process-local initialization clock, never an identity or
  // authority for accessing or controlling a renderer process.
  static const uint64_t processNS = nowNS();
  if (!samples || !count || count > Batch::capacity) return;
  for (size_t offset = 0; offset < count; offset += 4) {
    auto length = count - offset < 4 ? count - offset : 4;
    Report line(queue, samples + offset, length, processNS);
    // At most four records keeps worst-case numeric output below POSIX's
    // minimum atomic pipe-write size. Use one write, avoiding stdio buffering
    // and interleaving when several renderer processes inherit stderr.
    if (!line.good() || line.size() > 512) { processBudget().stop(); return; }
    if (!bytes.admit(static_cast<uint32_t>(line.size()))) {
      bytes.stop();
      processBudget().stop();
      if (!stopReported.exchange(true, std::memory_order_relaxed)) {
        char marker[128];
        int size = std::snprintf(marker, sizeof(marker),
            "{\"mvoNativeGpuTimingStop\":1,\"processNS\":%llu,\"reason\":1}\n",
            static_cast<unsigned long long>(processNS));
        if (size > 0 && static_cast<size_t>(size) < sizeof(marker)) {
          ssize_t written;
          do { written = ::write(STDERR_FILENO, marker, static_cast<size_t>(size)); } while (written < 0 && errno == EINTR);
        }
      }
      return;
    }
    ssize_t written;
    do { written = ::write(STDERR_FILENO, line.data(), line.size()); } while (written < 0 && errno == EINTR);
    if (written != static_cast<ssize_t>(line.size())) {
      bytes.stop();
      processBudget().stop();
      return; // A partial/error record is unqualified; never append its tail.
    }
  }
}
} // namespace mvo_gpu_timing
