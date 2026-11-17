// SPDX-License-Identifier: Apache-2.0
#include "ScanoutDxmt.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11_4.h>
#include <directx-native/dxn_shared.h>
#include <dxmt_native.h>
#include <memory>
#include <poll.h>
#include <unistd.h>

template<class T> struct COMPointer {
    T *value = nullptr;
    ~COMPointer() { if (value) value->Release(); }
    T *operator->() const { return value; }
};

struct MVOScanoutDxmt {
    COMPointer<ID3D11Device> device;
    COMPointer<ID3D11DeviceContext> context;
    COMPointer<ID3D11DeviceContext1> context1;
    COMPointer<ID3D11DeviceContext4> context4;
    COMPointer<ID3D11Fence> fence;
    COMPointer<ID3D11Texture2D> textures[MVO_SCANOUT_SLOT_COUNT];
    COMPointer<ID3D11RenderTargetView> targets[MVO_SCANOUT_SLOT_COUNT];
    LONG halfWidth;
    LONG halfHeight;
};

MVOScanoutDxmt *mvo_scanout_dxmt_create(uint32_t width, uint32_t height, uint32_t stride,
                                       const int fds[MVO_SCANOUT_SLOT_COUNT])
{
    auto source = std::make_unique<MVOScanoutDxmt>();
    COMPointer<ID3D11Device5> device5;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_1;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1,
                                D3D11_SDK_VERSION, &source->device.value, nullptr, &source->context.value)) ||
        FAILED(source->context->QueryInterface(__uuidof(ID3D11DeviceContext1), (void **)&source->context1.value)) ||
        FAILED(source->context->QueryInterface(__uuidof(ID3D11DeviceContext4), (void **)&source->context4.value)) ||
        FAILED(source->device->QueryInterface(__uuidof(ID3D11Device5), (void **)&device5.value)) ||
        FAILED(device5->CreateFence(0, D3D11_FENCE_FLAG_NONE, __uuidof(ID3D11Fence),
                                    (void **)&source->fence.value))) {
        return nullptr;
    }

    for (uint32_t slot = 0; slot < MVO_SCANOUT_SLOT_COUNT; ++slot) {
        dxn_shared_texture descriptor{};
        DXN_SHARED_INIT(&descriptor, DXN_SHARED_TEXTURE_MAGIC);
        descriptor.fd = fds[slot];
        descriptor.meta.width = width;
        descriptor.meta.height = height;
        descriptor.meta.mip_levels = 1;
        descriptor.meta.array_size = 1;
        descriptor.meta.dxgi_format = DXGI_FORMAT_B8G8R8A8_UNORM;
        descriptor.meta.sample_count = 1;
        descriptor.meta.usage = D3D11_USAGE_DEFAULT;
        descriptor.meta.bind_flags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        descriptor.meta.misc_flags = D3D11_RESOURCE_MISC_SHARED;
        descriptor.plane_count = 1;
        descriptor.planes[0].pitch = stride;
        descriptor.size = uint64_t(stride) * height;
        if (FAILED(source->device->OpenSharedResource((HANDLE)&descriptor, __uuidof(ID3D11Texture2D),
                                                      (void **)&source->textures[slot].value)) ||
            FAILED(source->device->CreateRenderTargetView(source->textures[slot].value, nullptr,
                                                          &source->targets[slot].value))) {
            return nullptr;
        }
    }
    source->halfWidth = LONG(width / 2);
    source->halfHeight = LONG(height / 2);
    return source.release();
}

void mvo_scanout_dxmt_destroy(MVOScanoutDxmt *source)
{
    delete source;
}

bool mvo_scanout_dxmt_render(MVOScanoutDxmt *source, MVOScanoutLease lease)
{
    void *event = dxmt_event_create(0, 0);
    if (!event) {
        return false;
    }
    int fd = dxmt_event_dup_fd(event);
    pollfd completion{fd, POLLIN, 0};
    bool complete = false;
    if (fd >= 0 && SUCCEEDED(source->fence->SetEventOnCompletion(lease.sequence, (HANDLE)event))) {
        const float colors[4][4] = {{1, 0, 0, 1}, {0, 0, 1, 1}, {0, 1, 0, 1}, {1, 1, 0, 1}};
        for (uint32_t i = 0; i < 4; ++i) {
            LONG left = (i % 2) * source->halfWidth;
            LONG top = (i / 2) * source->halfHeight;
            D3D11_RECT rect{left, top, left + source->halfWidth, top + source->halfHeight};
            source->context1->ClearView(source->targets[lease.slot].value, colors[(i + lease.sequence) % 4], &rect, 1);
        }
        const HRESULT signal = source->context4->Signal(source->fence.value, lease.sequence);
        source->context->Flush();
        uint8_t wake = 0;
        complete = SUCCEEDED(signal) && poll(&completion, 1, 5000) == 1 && (completion.revents & POLLIN) &&
            read(fd, &wake, sizeof(wake)) == sizeof(wake) && wake == 1 &&
            source->fence->GetCompletedValue() >= lease.sequence && source->device->GetDeviceRemovedReason() == S_OK;
    }
    if (fd >= 0) {
        close(fd);
    }
    dxmt_event_close(event);
    return complete;
}
