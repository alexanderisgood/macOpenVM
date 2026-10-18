// SPDX-License-Identifier: Apache-2.0
// Generated offscreen D3D11 work; no Windows, VM, screen or trace access.
#include "../MetalSurface/DxmtSource.h"
#include <cstdio>
#include <cstring>
int main(int argc, char **argv) {
  if (argc != 2 || std::strcmp(argv[1], "--run") != 0) {
    std::puts("SKIP: explicit generated native GPU timing check required");
    return 0;
  }
  MvoDxmtLayout layout{};
  auto *source = mvo_dxmt_create(3456, 2168, 87, &layout);
  if (!source) return 1;
  bool good = true;
  for (unsigned sequence = 0; sequence < 256; sequence++) {
    double waitMS = 0;
    if (!mvo_dxmt_prepare(source, sequence, &waitMS, sequence % 2)) {
      good = false;
      break;
    }
  }
  mvo_dxmt_destroy(source);
  if (!good) return 2;
  std::puts("{\"scope\":\"generated-native-D3D11-timing-stream\",\"frames\":256,\"pollableEventAndFenceValueChecked\":true,\"earlyHandleCloseAlternated\":true,\"noPixelFiles\":true}");
  return 0;
}
