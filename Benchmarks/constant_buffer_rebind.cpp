// SPDX-License-Identifier: Apache-2.0
// Offscreen regression: a whole-buffer rebind must reset a previous range.
#define main upstream_suite_main
#include <d3d11_test.cpp>
#undef main

static int rebindMode;
static void bindRange(Ctx &c, ID3D11DeviceContext *ctx) {
  const char *T = "cbuffer_rebind";
  Com<ID3D11DeviceContext1> c1;
  CHECK_HR(T, ctx->QueryInterface(__uuidof(ID3D11DeviceContext1), (void **)&c1));
  UINT offset = 16, count = 16;
  c1->PSSetConstantBuffers1(0, 1, &g_cbuf, &offset, &count);
  if (rebindMode == 1) ctx->PSSetConstantBuffers(0, 1, &g_cbuf);
  if (rebindMode == 2) c1->PSSetConstantBuffers1(0, 1, &g_cbuf, nullptr, nullptr);
  UINT actualOffset = ~0u, actualCount = ~0u;
  Com<ID3D11Buffer> actual;
  c1->PSGetConstantBuffers1(0, 1, &actual, &actualOffset, &actualCount);
  CHECK(T, actualOffset == (rebindMode ? 0u : 16u));
}

static void testRebinding(Ctx &c) {
  float values[128] = {};
  values[0] = 1; values[3] = 1; // first constant = opaque red
  values[65] = 1; values[67] = 1; // constant 16 = opaque green
  D3D11_BUFFER_DESC bd = {};
  bd.ByteWidth = sizeof(values); bd.Usage = D3D11_USAGE_DEFAULT;
  bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  D3D11_SUBRESOURCE_DATA data = { values, 0, 0 };
  CHECK_HR("cbuffer", c.device->CreateBuffer(&bd, &data, &g_cbuf));
  for (int deferred = 0; deferred != 2; ++deferred) {
    Com<ID3D11DeviceContext> dc;
    if (deferred) CHECK_HR("deferred", c.device->CreateDeferredContext(0, &dc));
    for (rebindMode = 0; rebindMode != 3; ++rebindMode) {
      auto img = draw_and_read(c, 64, 64, kQuadFull, 6, dxbc_vs_pass,
          sizeof(dxbc_vs_pass), dxbc_ps_cbuf, sizeof(dxbc_ps_cbuf),
          DXGI_FORMAT_R8G8B8A8_UNORM, bindRange, dc.p);
      emit("[CASE] deferred=%d mode=%d", deferred, rebindMode);
      CHECK("cbuffer_pixels", img.size() == 64*64*4);
      CHECK("cbuffer_pixels", px_eq(img, 64, 32, 32, rebindMode?255:0,
          rebindMode?0:255, 0, 255, 0), log_px(img,64,32,32,"actual"));
    }
  }
}
int main() {
  g_out = stdout;
  Ctx c;
  if (!create_device(c)) return 2;
  testRebinding(c);
  emit("[SUMMARY] passed=%d failed=%d",g_passes,g_fails);
  return g_fails ? 1 : 0;
}
