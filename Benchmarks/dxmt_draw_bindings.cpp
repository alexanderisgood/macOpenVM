// SPDX-License-Identifier: Apache-2.0
#define main upstream_suite_main
#include <d3d11_test.cpp>
#undef main
#include <algorithm>
#include <array>
#include <chrono>
#include <string_view>

static void exercise(Ctx &c, bool checkLayouts) {
  const char *test = "draw-bindings";
  constexpr UINT width = 32;
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = desc.Height = width;
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET;
  Com<ID3D11Texture2D> texture;
  Com<ID3D11RenderTargetView> target;
  CHECK_HR(test, c.device->CreateTexture2D(&desc, nullptr, &texture));
  CHECK_HR(test, c.device->CreateRenderTargetView(texture, nullptr, &target));
  Com<ID3D11VertexShader> vs;
  Com<ID3D11PixelShader> ps;
  CHECK_HR(test, c.device->CreateVertexShader(dxbc_vs_pass, sizeof(dxbc_vs_pass), nullptr, &vs));
  CHECK_HR(test, c.device->CreatePixelShader(dxbc_ps_color, sizeof(dxbc_ps_color), nullptr, &ps));
  std::array<Com<ID3D11Buffer>, 2> buffers;
  std::array<Com<ID3D11InputLayout>, 2> layouts;
  for (UINT slot = 0; slot < 2; ++slot) {
    auto elements = std::to_array(kLayout);
    for (auto &element : elements) element.InputSlot = slot;
    CHECK_HR(test, c.device->CreateInputLayout(elements.data(), elements.size(), dxbc_vs_pass, sizeof(dxbc_vs_pass), &layouts[slot]));
    auto vertices = std::to_array(kQuadFull);
    for (auto &v : vertices) {
      v.color[0] = float(slot);
      v.color[1] = float(1 - slot);
      v.color[2] = 0;
    }
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = sizeof(vertices);
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    D3D11_SUBRESOURCE_DATA initial{vertices.data()};
    CHECK_HR(test, c.device->CreateBuffer(&bd, &initial, &buffers[slot]));
  }
  const D3D11_VIEWPORT viewport{0, 0, width, width, 0, 1};
  auto bind = [&](ID3D11DeviceContext *ctx) {
    ctx->VSSetShader(vs, nullptr, 0);
    ctx->PSSetShader(ps, nullptr, 0);
    ctx->IASetInputLayout(layouts[0]);
    ctx->RSSetViewports(1, &viewport);
    ctx->OMSetRenderTargets(1, &target, nullptr);
  };
  auto setup = [&](ID3D11DeviceContext *ctx) {
    bind(ctx);
    ID3D11Buffer *slots[]{buffers[0], buffers[1]};
    const UINT strides[]{sizeof(Vertex), sizeof(Vertex)}, offsets[]{0, 0};
    ctx->IASetVertexBuffers(0, 2, slots, strides, offsets);
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  };
  Com<ID3D11DeviceContext> deferred;
  CHECK_HR(test, c.device->CreateDeferredContext(0, &deferred));
  if (checkLayouts) {
    for (bool record : {false, true}) {
      auto *ctx = record ? deferred.p : c.ctx.p;
      setup(ctx);
      // Consume both slot dirty bits, then switch back without rebinding either buffer.
      for (UINT slot : {0u, 1u, 0u}) {
        ctx->IASetInputLayout(layouts[slot]);
        ctx->Draw(6, 0);
      }
      if (record) {
        Com<ID3D11CommandList> list;
        CHECK_HR(test, deferred->FinishCommandList(FALSE, &list));
        c.ctx->ExecuteCommandList(list, FALSE);
      }
      auto image = readback_tex2d(c, texture, 0, 4);
      CHECK(test, image.size() == width * width * 4, return);
      CHECK(test, px_eq(image, width, 16, 16, 0, 255, 0, 255, 0));
    }
    return;
  }
  // Time CPU command recording independently of shader compilation, presentation and GPU execution.
  constexpr unsigned draws = 8192;
  for (bool rebind : {false, true}) {
    std::array<double, 9> samples;
    for (unsigned trial = 0; trial <= samples.size(); ++trial) {
      setup(deferred);
      deferred->Draw(6, 0);
      auto start = std::chrono::steady_clock::now();
      for (unsigned i = 0; i < draws; ++i) {
        if (rebind) bind(deferred);
        deferred->Draw(6, 0);
      }
      double ns = std::chrono::duration<double, std::nano>(std::chrono::steady_clock::now() - start).count();
      if (trial) samples[trial - 1] = ns / draws;
      Com<ID3D11CommandList> list;
      CHECK_HR(test, deferred->FinishCommandList(FALSE, &list));
      if (trial == samples.size()) {
        c.ctx->ExecuteCommandList(list, FALSE);
        auto image = readback_tex2d(c, texture, 0, 4);
        CHECK(test, image.size() == width * width * 4, return);
        CHECK(test, px_eq(image, width, 16, 16, 0, 255, 0, 255, 0));
      }
    }
    std::sort(samples.begin(), samples.end());
    emit("[RECORD_NS] %s %.2f", rebind ? "rebind" : "draw", samples[samples.size() / 2]);
  }
}

int main(int argc, char **argv) {
  if (argc != 2 || (std::string_view(argv[1]) != "--benchmark" && std::string_view(argv[1]) != "--check-layouts"))
    return 2;
  g_out = stdout;
  Ctx c;
  if (!create_device(c)) return 2;
  exercise(c, std::string_view(argv[1]) == "--check-layouts");
  emit("[SUMMARY] passed=%d failed=%d", g_passes, g_fails);
  return g_fails != 0;
}
