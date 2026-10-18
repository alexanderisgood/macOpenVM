// SPDX-License-Identifier: Apache-2.0
// Generated D3D11 quadrants; no Windows process, VM, window or screen capture.
#include "DxmtSource.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi.h>
#include <dxmt_native.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>

template<class T> struct OwnedCOM {
    T *p = nullptr;
    ~OwnedCOM() { if (p) p->Release(); }
    T *operator->() const { return p; }
};
struct MvoDxmtSource {
    OwnedCOM<ID3D11Device> device;
    OwnedCOM<ID3D11DeviceContext> context;
    OwnedCOM<ID3D11DeviceContext1> context1;
    OwnedCOM<ID3D11DeviceContext4> context4;
    OwnedCOM<ID3D11Device5> device5;
    OwnedCOM<ID3D11Texture2D> texture;
    OwnedCOM<ID3D11RenderTargetView> view;
    OwnedCOM<IDXGIResource> resource;
    OwnedCOM<ID3D11Fence> fence;
    uint32_t width = 0, height = 0;
    uint64_t nextValue = 1;
};
static double milliseconds() {
    timespec t{}; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}
void mvo_dxmt_destroy(MvoDxmtSource *source) { delete source; }
MvoDxmtSource *mvo_dxmt_create(uint32_t width, uint32_t height, uint32_t format,
                              MvoDxmtLayout *layout) {
    if (!layout || (width != 3456 && width != 3840) ||
        height != (width == 3456 ? 2168u : 2160u) ||
        (format != 87 && format != 91 && format != 28 && format != 29)) return nullptr;
    auto *s = new MvoDxmtSource;
    D3D_FEATURE_LEVEL level{};
    const D3D_FEATURE_LEVEL requested[] = {D3D_FEATURE_LEVEL_11_1};
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        requested, 1, D3D11_SDK_VERSION, &s->device.p, &level, &s->context.p)) ||
        level != D3D_FEATURE_LEVEL_11_1 ||
        FAILED(s->context->QueryInterface(__uuidof(ID3D11DeviceContext1), (void **)&s->context1.p)) ||
        FAILED(s->context->QueryInterface(__uuidof(ID3D11DeviceContext4), (void **)&s->context4.p)) ||
        FAILED(s->device->QueryInterface(__uuidof(ID3D11Device5), (void **)&s->device5.p))) {
        delete s; return nullptr;
    }
    D3D11_TEXTURE2D_DESC d{};
    d.Width = width; d.Height = height; d.MipLevels = 1; d.ArraySize = 1;
    d.Format = (DXGI_FORMAT)format; d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    d.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    HANDLE handle = nullptr;
    if (FAILED(s->device->CreateTexture2D(&d, nullptr, &s->texture.p)) ||
        FAILED(s->device->CreateRenderTargetView(s->texture.p, nullptr, &s->view.p)) ||
        FAILED(s->texture->QueryInterface(__uuidof(IDXGIResource), (void **)&s->resource.p)) ||
        FAILED(s->resource->GetSharedHandle(&handle)) || !handle ||
        FAILED(s->device5->CreateFence(0, D3D11_FENCE_FLAG_NONE, __uuidof(ID3D11Fence),
                                     (void **)&s->fence.p))) { delete s; return nullptr; }
    const auto *shared = (const dxmt_shared_texture_handle *)handle;
    if (shared->magic != DXMT_SHARED_TEXTURE_MAGIC || shared->version != 2 ||
        shared->fd < 0 || shared->width != width || shared->height != height ||
        shared->dxgi_format != format || shared->mip_levels != 1 ||
        shared->array_size != 1 || shared->sample_count != 1) { delete s; return nullptr; }
    *layout = {shared->fd, width, height, format, shared->stride, shared->size, shared->offset};
    s->width = width; s->height = height;
    return s;
}
int mvo_dxmt_prepare(MvoDxmtSource *s, uint32_t sequence, double *waitMS,
                     int closeHandleBeforeWait) {
    if (!s || !waitMS || s->nextValue > 1000) return 0;
    void *event = dxmt_event_create(0, 0);
    if (!event) return 0;
    int fd = dxmt_event_dup_fd(event);
    if (fd < 0) { dxmt_event_close(event); return 0; }
    pollfd p{fd, POLLIN, 0};
    bool valid = poll(&p, 1, 0) == 0; // Never infer completion from an unarmed event.
    uint64_t value = s->nextValue++;
    valid = valid && SUCCEEDED(s->fence->SetEventOnCompletion(value, (HANDLE)event));
    if (valid) {
        const float colors[4][4] = {{1,0,0,.25f},{0,0,1,.25f},{0,1,0,.25f},{1,1,0,.25f}};
        for (uint32_t quadrant = 0; quadrant < 4; quadrant++) {
            LONG x = (quadrant % 2) * (s->width / 2), y = (quadrant / 2) * (s->height / 2);
            D3D11_RECT rect{x, y, x + (LONG)s->width / 2, y + (LONG)s->height / 2};
            s->context1->ClearView(s->view.p, colors[(quadrant + sequence) % 4], &rect, 1);
        }
        valid = SUCCEEDED(s->context4->Signal(s->fence.p, value));
        s->context->Flush();
    }
    if (closeHandleBeforeWait) { dxmt_event_close(event); event = nullptr; }
    double begin = milliseconds(), deadline = begin + 5000;
    int ready = 0;
    while (valid && ready == 0 && milliseconds() < deadline) {
        p.revents = 0;
        ready = poll(&p, 1, 50);
        if (ready < 0 && errno == EINTR) ready = 0;
    }
    *waitMS = milliseconds() - begin;
    uint8_t wake = 0; // DXMT exports a byte pipe, not an eventfd counter.
    valid = valid && ready == 1 && (p.revents & POLLIN) && !(p.revents & (POLLNVAL | POLLERR)) &&
        read(fd, &wake, sizeof(wake)) == sizeof(wake) && wake == 1 &&
        s->fence->GetCompletedValue() >= value && s->device->GetDeviceRemovedReason() == S_OK;
    close(fd); if (event) dxmt_event_close(event);
    return valid ? 1 : 0;
}
