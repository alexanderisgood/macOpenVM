// SPDX-License-Identifier: Apache-2.0
// Closed numeric JSON, bounded storage. Never accepts names, labels or pixels.
#pragma once
#include "GpuTimings.hpp"
#include <cstdarg>
#include <cstdio>

namespace mvo_gpu_timing {
class Report {
  char data_[4096]{};
  size_t size_ = 0;
  bool good_ = true;
  void append(const char *format, ...) {
    if (!good_) return;
    va_list args;
    va_start(args, format);
    int count = std::vsnprintf(data_ + size_, sizeof(data_) - size_, format, args);
    va_end(args);
    if (count < 0 || static_cast<size_t>(count) >= sizeof(data_) - size_) {
      good_ = false;
      return;
    }
    size_ += static_cast<size_t>(count);
  }
public:
  Report(uint32_t queue, const Sample *samples, size_t count, uint64_t processNS = 0) {
    if (!samples || !count || count > Batch::capacity) { good_ = false; return; }
    append("{\"mvoNativeGpuTiming\":1,\"processNS\":%llu,\"queue\":%u,\"count\":%zu,\"firstObservedNS\":%llu,\"lastObservedNS\":%llu,\"gpuSpanNS\":[",
           static_cast<unsigned long long>(processNS), queue, count, static_cast<unsigned long long>(samples[0].observedNS),
           static_cast<unsigned long long>(samples[count - 1].observedNS));
    for (size_t i = 0; i < count; i++) {
      if (i) append(",");
      if (samples[i].gpuKnown) append("%llu", static_cast<unsigned long long>(samples[i].gpuSpanNS));
      else append("null");
    }
    append("],\"submitWaitNS\":[");
    for (size_t i = 0; i < count; i++) {
      if (i) append(",");
      if (samples[i].submitWaitKnown) append("%llu", static_cast<unsigned long long>(samples[i].submitWaitNS));
      else append("null");
    }
    append("],\"completed\":[");
    for (size_t i = 0; i < count; i++) append("%s%u", i ? "," : "", samples[i].completed ? 1 : 0);
    append("]}\n");
  }
  bool good() const { return good_; }
  const char *data() const { return data_; }
  size_t size() const { return good_ ? size_ : 0; }
};
} // namespace mvo_gpu_timing
