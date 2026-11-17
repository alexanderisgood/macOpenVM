// SPDX-License-Identifier: Apache-2.0
// Host-only D3D11 regression and synthetic timing fixture, built with the pinned DXMT native suite.
#define main upstream_suite_main
#include <d3d11_test.cpp>
#undef main
#include <algorithm>
#include <array>
#include <chrono>
#include <string_view>
#include <thread>

using Clock = std::chrono::steady_clock;

static bool discard(ID3D11DeviceContext *ctx, ID3D11Buffer *buffer, const void *bytes, size_t length) {
  D3D11_MAPPED_SUBRESOURCE map{};
  if (FAILED(ctx->Map(buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &map)))
    return false;
  memcpy(map.pData, bytes, length);
  ctx->Unmap(buffer, 0);
  return true;
}

static void pollingRead(Ctx &c) {
  const char *test = "polling readback";
  const std::array<UINT, 4> pattern{0x13579bdf, 2, 3, 4};
  D3D11_BUFFER_DESC desc{};
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.ByteWidth = sizeof(pattern);
  D3D11_SUBRESOURCE_DATA init{pattern.data(), 0, 0};
  Com<ID3D11Buffer> source, staging;
  CHECK_HR(test, c.device->CreateBuffer(&desc, &init, &source));
  desc.Usage = D3D11_USAGE_STAGING;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  CHECK_HR(test, c.device->CreateBuffer(&desc, nullptr, &staging));
  c.ctx->CopyResource(staging, source);
  D3D11_MAPPED_SUBRESOURCE map{};
  const auto start = Clock::now();
  HRESULT hr;
  do {
    hr = c.ctx->Map(staging, 0, D3D11_MAP_READ, D3D11_MAP_FLAG_DO_NOT_WAIT, &map);
    if (hr != DXGI_ERROR_WAS_STILL_DRAWING) break;
    std::this_thread::sleep_for(std::chrono::microseconds(100));
  } while (Clock::now() - start < std::chrono::milliseconds(500));
  emit("[POLL_MS] %.3f", std::chrono::duration<double, std::milli>(Clock::now() - start).count());
  CHECK(test, hr == S_OK, return);
  CHECK(test, memcmp(pattern.data(), map.pData, sizeof(pattern)) == 0);
  c.ctx->Unmap(staging, 0);
}

static void streamDraws(Ctx &c, ID3D11DeviceContext *ctx, bool measure) {
  const char *test = "streamed bindings";
  D3D11_BUFFER_DESC desc{};
  desc.Usage = D3D11_USAGE_DYNAMIC;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  desc.ByteWidth = sizeof(kQuadLeft);
  desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  Com<ID3D11Buffer> vb, nextVB, cb, nextCB;
  CHECK_HR(test, c.device->CreateBuffer(&desc, nullptr, &vb));
  CHECK_HR(test, c.device->CreateBuffer(&desc, nullptr, &nextVB));
  desc.ByteWidth = 16;
  desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  CHECK_HR(test, c.device->CreateBuffer(&desc, nullptr, &cb));
  CHECK_HR(test, c.device->CreateBuffer(&desc, nullptr, &nextCB));

  auto elements = std::to_array(kLayout);
  const UINT slot = measure ? 0 : 31;
  for (auto &element : elements) element.InputSlot = slot;
  Com<ID3D11InputLayout> layout;
  CHECK_HR(test, c.device->CreateInputLayout(elements.data(), elements.size(), dxbc_vs_pass, sizeof(dxbc_vs_pass), &layout));
  ctx->IASetInputLayout(layout);
  const UINT stride = sizeof(Vertex), offset = 0;
  ctx->IASetVertexBuffers(slot, 1, &vb, &stride, &offset);
  ctx->PSSetConstantBuffers(0, 1, &cb);
  const std::array<float, 4> red{1,0,0,1}, green{0,1,0,1};
  CHECK(test, discard(ctx, vb, kQuadLeft, sizeof(kQuadLeft)), return);
  CHECK(test, discard(ctx, cb, red.data(), sizeof(red)), return);
  ctx->Draw(6, 0);

  if (measure) {
    // Stream the next material and geometry while drawing the current ones.
    // Include periodic updates to resources that the draw actually uses.
    constexpr unsigned draws = 1024;
    const auto start = Clock::now();
    for (unsigned i = 0; i < draws; ++i) {
      const bool bound = (i % 8) == 0;
      if (!discard(ctx, bound ? vb.p : nextVB.p, kQuadLeft, sizeof(kQuadLeft)) ||
          !discard(ctx, bound ? cb.p : nextCB.p, red.data(), sizeof(red))) {
        CHECK(test, false, return);
      }
      ctx->Draw(6, 0);
    }
    emit("[STREAM_US] %.3f", std::chrono::duration<double, std::micro>(Clock::now() - start).count());
  }

  auto right = std::to_array(kQuadLeft);
  for (auto &vertex : right) vertex.pos[0] += 1;
  CHECK(test, discard(ctx, vb, right.data(), sizeof(right)), return);
  CHECK(test, discard(ctx, cb, green.data(), sizeof(green)), return);
  // draw_and_read issues the final draw with these renamed but still-bound buffers.
}

int main(int argc, char **argv) {
  g_out = stdout;
  if (argc != 2) return 2;
  Ctx c;
  if (!create_device(c)) return 2;
  const std::string_view mode = argv[1];
  if (mode == "--poll") {
    pollingRead(c);
  } else if (mode == "--check" || mode == "--bench") {
    const bool measure = mode == "--bench";
    for (bool deferred : {false, true}) {
      if (measure && deferred) continue;
      Com<ID3D11DeviceContext> record;
      if (deferred && FAILED(c.device->CreateDeferredContext(0, &record))) return 2;
      for (unsigned frame = 0; frame < (measure ? 20u : 1u); ++frame) {
        const auto start = Clock::now();
        auto pixels = draw_and_read(c, 32, 32, kQuadFull, 6, dxbc_vs_pass, sizeof(dxbc_vs_pass), dxbc_ps_cbuf,
          sizeof(dxbc_ps_cbuf), DXGI_FORMAT_R8G8B8A8_UNORM, measure
            ? +[](Ctx &c, ID3D11DeviceContext *ctx) { streamDraws(c, ctx, true); }
            : +[](Ctx &c, ID3D11DeviceContext *ctx) { streamDraws(c, ctx, false); }, record.p);
        if (pixels.size() != 32 * 32 * 4) return 1;
        if (measure) emit("[FRAME_MS] %.3f", std::chrono::duration<double, std::milli>(Clock::now() - start).count());
        CHECK("left remains red", px_eq(pixels, 32, 8, 16, 255, 0, 0, 255, 0));
        CHECK("right becomes green", px_eq(pixels, 32, 24, 16, 0, 255, 0, 255, 0));
      }
    }
  } else return 2;
  emit("[SUMMARY] passed=%d failed=%d", g_passes, g_fails);
  return g_fails != 0;
}
