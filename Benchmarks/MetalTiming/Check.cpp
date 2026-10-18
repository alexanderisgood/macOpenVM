// SPDX-License-Identifier: Apache-2.0
// Generated completion vectors only; no GPU, VM, screen or process control.
#include "GpuTimings.hpp"
#include "Report.hpp"
#include <cstring>
#include <cassert>
#include <limits>
#include <mutex>
#include <thread>
#include <vector>
using namespace mvo_gpu_timing;
struct Records { std::vector<Sample> samples; std::vector<size_t> batches; };
static void collect(void *opaque, uint32_t queue, const Sample *samples, size_t count) {
  auto &records = *static_cast<Records *>(opaque);
  assert(queue == 7 && count && count <= Batch::capacity);
  records.samples.insert(records.samples.end(), samples, samples + count);
  records.batches.push_back(count);
}
int main() {
  Records records;
  Budget budget(131);
  {
    Batch batch(budget, 7, collect, &records);
    assert(batch.record(true, 10, 20, 50, 60));
    assert(batch.record(true, 10, 0, 0, 70));
    assert(batch.record(false, 10, 20, 50, 80));
    assert(batch.record(true, 10, 50, 20, 90));
    assert(batch.record(true, 100, 20, 50, 110));
    assert(batch.record(true, 1, 2, std::numeric_limits<uint64_t>::max(), 120));
    for (unsigned n = 6; n < 131; n++) assert(batch.record(true, n, n + 1, n + 4, n + 5));
    for (unsigned n = 0; n < 100; n++) assert(!batch.record(true, 1, 2, 3, 4));
  }
  assert((records.batches == std::vector<size_t>{64, 64, 3}));
  assert(records.samples.size() == 131);
  assert(records.samples[0].gpuSpanNS == 30 && records.samples[0].submitWaitNS == 10);
  assert(!records.samples[1].gpuKnown && records.samples[1].completed);
  assert(!records.samples[2].gpuKnown && !records.samples[2].completed);
  assert(!records.samples[3].gpuKnown);
  assert(records.samples[4].gpuKnown && !records.samples[4].submitWaitKnown);
  assert(records.samples[5].gpuSpanNS == std::numeric_limits<uint64_t>::max() - 2);
  for (size_t n = 6; n < 131; n++) {
    assert(records.samples[n].gpuSpanNS == 3 && records.samples[n].submitWaitNS == 1);
    assert(records.samples[n].observedNS == n + 5);
  }
  Budget shared(32768);
  std::atomic<uint32_t> accepted{0};
  std::vector<std::thread> workers;
  for (unsigned i = 0; i < 8; i++) workers.emplace_back([&] {
    for (unsigned n = 0; n < 20000; n++) if (shared.admit()) accepted.fetch_add(1);
  });
  for (auto &worker : workers) worker.join();
  assert(accepted.load() == 32768 && !shared.admit());
  Budget empty(0);
  assert(!empty.admit() && !empty.available());
  Budget byteLimit(1024);
  assert(!byteLimit.admit(0) && !byteLimit.admit(1025));
  assert(byteLimit.admit(1000) && !byteLimit.admit(25) && byteLimit.admit(24));
  assert(!byteLimit.available() && !byteLimit.admit());
  Budget stopped(100);
  stopped.stop();
  assert(!stopped.available() && !stopped.admit(1));
  std::array<Sample, Batch::capacity> largest;
  for (auto &sample : largest) sample = {UINT64_MAX, UINT64_MAX, UINT64_MAX, true, true, true};
  Report line(UINT32_MAX, largest.data(), largest.size());
  assert(line.good() && line.size() < 4096 && line.data()[line.size() - 1] == '\n');
  assert(std::strstr(line.data(), "18446744073709551615") != nullptr);
  Report atomicLine(UINT32_MAX, largest.data(), 4, UINT64_MAX);
  assert(atomicLine.good() && atomicLine.size() <= 512);
  Sample unknown;
  Report missing(0, &unknown, 1);
  assert(missing.good() && std::strstr(missing.data(), "\"gpuSpanNS\":[null]") &&
         std::strstr(missing.data(), "\"submitWaitNS\":[null]") &&
         std::strstr(missing.data(), "\"completed\":[0]"));
  assert(!Report(1, nullptr, 1).good());
  assert(!Report(1, largest.data(), 0).good());
  assert(!Report(1, largest.data(), 65).good());
  std::fwrite(line.data(), 1, line.size(), stdout);
  std::fwrite(missing.data(), 1, missing.size(), stdout);
  return 0;
}
