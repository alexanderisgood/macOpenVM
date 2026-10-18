// SPDX-License-Identifier: Apache-2.0
// Generated numeric output-pressure check; no Metal, VM or screen access.
#include "NativeTiming.hpp"
#include <cassert>
#include <thread>
#include <vector>
int main() {
  using namespace mvo_gpu_timing;
  assert(nowNS() > 0);
  assert(nextQueue() == 1 && nextQueue() == 2);
  std::array<Sample, Batch::capacity> largest;
  for (auto &sample : largest) sample = {UINT64_MAX, UINT64_MAX, UINT64_MAX, true, true, true};
  std::vector<std::thread> workers;
  for (unsigned i = 0; i < 8; i++) workers.emplace_back([&,i] {
    for (unsigned n = 0; n < 1000; n++) report(nullptr,i+3,largest.data(),largest.size());
  });
  for (auto &worker : workers) worker.join();
  assert(!processBudget().available());
  return 0;
}
