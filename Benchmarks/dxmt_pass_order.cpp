#define main upstream_suite_main
#include <d3d11_test.cpp>
#undef main
#include <algorithm>
#include <array>
#include <chrono>

static void runPasses(Ctx &ctx) {
  const char *name = "pass-order";
  constexpr unsigned size = 32;
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = desc.Height = size;
  desc.MipLevels = desc.ArraySize = 1;
  desc.SampleDesc.Count = 4;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET;
  Com<ID3D11Texture2D> multisampled, resolved, snapshot;
  Com<ID3D11RenderTargetView> target;
  CHECK_HR(name, ctx.device->CreateTexture2D(&desc, nullptr, &multisampled));
  CHECK_HR(name, ctx.device->CreateRenderTargetView(multisampled, nullptr, &target));
  desc.SampleDesc.Count = 1;
  desc.BindFlags = 0;
  CHECK_HR(name, ctx.device->CreateTexture2D(&desc, nullptr, &resolved));
  CHECK_HR(name, ctx.device->CreateTexture2D(&desc, nullptr, &snapshot));
  D3D11_BUFFER_DESC verticesDesc{};
  verticesDesc.ByteWidth = sizeof(kQuadLeft);
  verticesDesc.Usage = D3D11_USAGE_IMMUTABLE;
  verticesDesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  const D3D11_SUBRESOURCE_DATA initial{kQuadLeft};
  Com<ID3D11Buffer> vertices;
  Com<ID3D11VertexShader> vertex;
  Com<ID3D11PixelShader> pixel;
  Com<ID3D11InputLayout> layout;
  CHECK_HR(name, ctx.device->CreateBuffer(&verticesDesc, &initial, &vertices));
  CHECK_HR(name, ctx.device->CreateVertexShader(dxbc_vs_pass, sizeof(dxbc_vs_pass), nullptr, &vertex));
  CHECK_HR(name, ctx.device->CreatePixelShader(dxbc_ps_color, sizeof(dxbc_ps_color), nullptr, &pixel));
  CHECK_HR(name, ctx.device->CreateInputLayout(kLayout, 3, dxbc_vs_pass, sizeof(dxbc_vs_pass), &layout));
  UINT stride = sizeof(Vertex), offset = 0;
  D3D11_VIEWPORT viewport{0, 0, size, size, 0, 1};
  ctx.ctx->OMSetRenderTargets(1, &target, nullptr);
  ctx.ctx->RSSetViewports(1, &viewport);
  ctx.ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  ctx.ctx->IASetInputLayout(layout);
  ctx.ctx->IASetVertexBuffers(0, 1, &vertices, &stride, &offset);
  ctx.ctx->VSSetShader(vertex, nullptr, 0);
  ctx.ctx->PSSetShader(pixel, nullptr, 0);

  for (unsigned clears : {1u, 32u, 256u}) {
    std::array<double, 7> samples;
    for (auto &sample : samples) {
      const auto start = std::chrono::steady_clock::now();
      for (unsigned frame = 0; frame < 32; ++frame) {
        for (unsigned pass = 0; pass < clears; ++pass) {
          const float color[4] = {0, float(frame % 2), float(pass % 2), 1};
          ctx.ctx->ClearRenderTargetView(target, color);
        }
        ctx.ctx->Draw(6, 0);
        ctx.ctx->ResolveSubresource(resolved, 0, multisampled, 0, desc.Format);
        if (frame == 30) ctx.ctx->CopyResource(snapshot, resolved);
      }
      const auto last = readback_tex2d(ctx, resolved, 0, 4);
      const auto previous = readback_tex2d(ctx, snapshot, 0, 4);
      sample = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
      const unsigned blue = ((clears - 1) % 2) * 255;
      CHECK(name, last.size() == size * size * 4 && previous.size() == last.size(), return);
      CHECK(name, px_eq(last, size, 4, 16, 255, 128, 64, 255, 1));
      CHECK(name, px_eq(previous, size, 4, 16, 255, 128, 64, 255, 1));
      CHECK(name, px_eq(last, size, 28, 16, 0, 255, blue, 255, 0));
      CHECK(name, px_eq(previous, size, 28, 16, 0, 0, blue, 255, 0));
    }
    std::sort(samples.begin(), samples.end());
    emit("[PASS_TIME] %u %.3f ms per 32 frames", clears, samples[samples.size()/2]);
  }
}

int main() {
  g_out = stdout;
  Ctx context;
  if (!create_device(context)) return 2;
  runPasses(context);
  emit("[SUMMARY] passed=%d failed=%d", g_passes, g_fails);
  return g_fails != 0;
}
