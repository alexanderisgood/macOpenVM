// SPDX-License-Identifier: Apache-2.0
// Numeric completion records only; no Metal resource, label, guest data or I/O.
#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace mvo_gpu_timing {
class Budget {
  std::atomic<uint32_t> remaining_;
public:
  explicit Budget(uint32_t limit = 32768) : remaining_(limit) {}
  bool available() const { return remaining_.load(std::memory_order_relaxed) != 0; }
  void stop() { remaining_.store(0, std::memory_order_relaxed); }
  bool admit(uint32_t count = 1) {
    if (!count) return false;
    auto remaining = remaining_.load(std::memory_order_relaxed);
    while (remaining >= count && !remaining_.compare_exchange_weak(
        remaining, remaining - count, std::memory_order_relaxed)) {}
    return remaining >= count;
  }
};

struct Sample {
  uint64_t gpuSpanNS = 0, submitWaitNS = 0, observedNS = 0;
  bool completed = false, gpuKnown = false, submitWaitKnown = false;
};

// Each batch has one serial finish-thread producer. The sink is synchronous,
// non-reentrant, and must copy records it retains. All queues share one budget.
class Batch {
public:
  using Sink = void (*)(void *, uint32_t, const Sample *, size_t);
  static constexpr size_t capacity = 64;
private:
  Budget &budget_;
  Sink sink_;
  void *context_;
  uint32_t queue_;
  std::array<Sample, capacity> samples_{};
  size_t count_ = 0;
public:
  Batch(Budget &budget, uint32_t queue, Sink sink, void *context)
      : budget_(budget), sink_(sink), context_(context), queue_(queue) {}
  Batch(const Batch &) = delete;
  Batch &operator=(const Batch &) = delete;
  ~Batch() { flush(); }
  bool active() const { return budget_.available(); }
  bool record(bool completed, uint64_t submittedNS, uint64_t gpuStartNS,
              uint64_t gpuEndNS, uint64_t observedNS) {
    if (!budget_.admit()) return false;
    Sample sample{};
    sample.completed = completed;
    sample.observedNS = observedNS;
    // Zero timestamps stay unknown. Failed work never becomes a fast sample.
    if (completed && gpuStartNS && gpuEndNS >= gpuStartNS) {
      sample.gpuKnown = true;
      sample.gpuSpanNS = gpuEndNS - gpuStartNS;
      if (submittedNS && gpuStartNS >= submittedNS) {
        sample.submitWaitKnown = true;
        sample.submitWaitNS = gpuStartNS - submittedNS;
      }
    }
    samples_[count_++] = sample;
    if (count_ == capacity) flush();
    return true;
  }
  void flush() {
    if (!count_) return;
    if (sink_) sink_(context_, queue_, samples_.data(), count_);
    count_ = 0;
  }
};
} // namespace mvo_gpu_timing
