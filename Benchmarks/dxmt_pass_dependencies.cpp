#include "dxmt_deptrack.hpp"
#include <algorithm>
#include <array>
#include <bitset>
#include <chrono>
#include <cstdio>
#include <random>
#include <vector>

using namespace dxmt;
using Bits = std::bitset<kParityLane>;

struct Step {
  EncoderId id;
  FenceSet input;
  bool fragment;
};

static Bits bits(FenceSet fences) {
  Bits result;
  fences.forEach([&](unsigned index) { result.set(index); });
  return result;
}

static Bits reference(const Step &step, std::array<Bits, kParityLane> &history) {
  Bits required = bits(step.input);
  if (step.fragment) required.set((step.id - 1) % kParityLane);
  Bits strong = required;
  for (unsigned distance = kLane; distance < 2 * kLane; ++distance) {
    const unsigned slot = (step.id - distance) % kParityLane;
    bool hasStrong = false;
    for (unsigned generation = 0; generation < kParity; ++generation)
      hasStrong |= strong.test(generation * kLane + slot % kLane);
    if (!hasStrong) required.set(slot);
  }
  Bits reached, waits;
  for (unsigned distance = 1; distance < kParityLane; ++distance) {
    const unsigned slot = (step.id - distance) % kParityLane;
    if (required.test(slot) && !reached.test(slot)) {
      waits.set(slot);
      reached.set(slot);
    }
    if (reached.test(slot)) reached |= history[slot];
    if ((reached & required) == required) break;
  }
  history[step.id % kParityLane] = required;
  if (step.fragment) waits.reset((step.id - 1) % kParityLane);
  return waits;
}

int main() {
  const char *names[] = {"independent", "chain", "sparse", "dense"};
  for (unsigned shape = 0; shape < 4; ++shape) {
    std::mt19937 random(12345 + shape);
    std::vector<Step> trace;
    EncoderId id = ~EncoderId{0} - 128;
    for (unsigned pass = 0; pass < 8192; ++pass) {
      id += pass % 127 == 0 ? 3 : 1;
      Step step{id, {}, (pass % 3) == 1};
      if (shape == 1) step.input.set(id - 1);
      if (shape >= 2) {
        const unsigned count = shape == 2 ? 3 : 80;
        for (unsigned index = 0; index < count; ++index)
          step.input.set(id - 1 - random() % (kParityLane - 1));
      }
      trace.push_back(step);
    }
    FenceLocalityCheck check{};
    std::array<Bits, kParityLane> history{};
    for (const auto &step : trace) {
      auto actual = check.collectAndSimplifyWaits(step.input, step.id, step.fragment);
      if (bits(actual) != reference(step, history)) {
        std::fprintf(stderr, "%s mismatch at encoder %llu\n", names[shape], (unsigned long long)step.id);
        return 1;
      }
    }
    std::array<double, 9> samples;
    unsigned long long checksum = 0;
    for (auto &sample : samples) {
      FenceLocalityCheck timed{};
      const auto start = std::chrono::steady_clock::now();
      for (const auto &step : trace)
        checksum += timed.collectAndSimplifyWaits(step.input, step.id, step.fragment).laneMask();
      sample = std::chrono::duration<double, std::nano>(std::chrono::steady_clock::now() - start).count() / trace.size();
    }
    std::sort(samples.begin(), samples.end());
    std::printf("%s %.2f ns/pass checksum %llu\n", names[shape], samples[samples.size() / 2], checksum);
  }
}
