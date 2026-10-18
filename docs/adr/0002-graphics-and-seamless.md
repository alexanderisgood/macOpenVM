# ADR 2: investigate graphics early; preserve a truthful 2D path

Status: experimental. The private ARM64 viogpu3d/Neptune/native DXMT path now
renders actual Windows D3D11 FL11.1 workloads through Metal at native and4K60
geometry. Broader API coverage, games, long-running stability, physical delivery
and120Hz remain unqualified. See the current GPU evidence (private development record omitted)
and [performance scopes](../../PERFORMANCE.md); dated investigations below retain
their original limitations.

| Path | Guest API / host rendering | Signing/licensing/limitations |
|---|---|---|
| Apple virtio + VZ view | Linux framebuffer, public host view; exact 3D API unproven | OS framework; one scanout; no verified Windows driver |
| QEMU RAMFB + original client | Firmware/basic 2D presentation; host Cocoa for spike | GPL QEMU redistribution review; no DirectX acceleration |
| virtio-gpu/virgl + Mesa | Linux GL candidates; Metal translation needs actual supported renderer | Component license/build review, synchronization/copies and host support unproven |
| Vulkan translation layers | Guest Vulkan path only if suitable guest driver exists | Layer license/patent review; translation alone is not Windows driver |
| Original/licensed Windows virtio GPU driver | DirectX/OpenGL/Vulkan versions undecided | ARM64, Windows signing/security, shader correctness and distribution gates |

Each viable design must record supported API versions, Metal translation, copies/
zero-copy, synchronization, shader compilation/cache, memory limits and crash
containment. The selected private evaluation is ARM64 viogpu3d with Neptune and
native DXMT; the other paths remain exploratory. CUDA, games and general API
support cannot be inferred. No signature/security bypass or software fallback
benchmark qualifies the selected path.

The next host delivery experiment uses dedicated GPU output surfaces;
[ADR43](0043-metal-surface-delivery.md) records the generated native/4K component
proof, failure tests and the producer-completion/runtime-admission gates required
before live integration. It does not change the signed driver's refresh limit.

For basic Windows desktop measure guest render, transport and host presentation
separately: frame-time distribution, stalls, latency, memory growth and main-thread
blocking at actually applied native resolution. Prefer no stale-frame queue growth.

Seamless mode is planned, then experimental until all seven stages pass: window
enumeration/lifecycle; independent surfaces; input/focus/IME/DPI/z-order/modal/
multi-monitor; safe UAC handling; reconnect/restart; sharing policy; automated
scenarios and long manual stress. Cropping a desktop never satisfies these gates.

## Next prerequisite experiment: real no-OS framebuffer and keyboard

The reviewed Windows-platform QEMU candidate is an isolated headless HVF build
with a macOS27 minimum. Evaluate its RAMFB path before introducing another host
display dependency. An original EFI application may use the public GOP interface
to discover available modes, draw known colors and change to a distinct available
mode. Capture each applied framebuffer with QMP, then require its exact dimensions
and sampled pixels to agree with the guest observation. A command acknowledgement
or advertised mode alone cannot pass.

Attach one explicit USB keyboard to the new offline, diskless fixture. Send a
small fixed sequence only after the application announces its current input
target, and require each actual UEFI key observation before advancing. Preserve
the bounded serial stream, PPM captures, source/artifact hashes and cleanup result.
No arbitrary media, host keyboard focus or current user VM is an input to this
experiment. QMP quit must acknowledge and both owned processes must exit before
writer ownership is released.

This experiment can establish guest RAMFB/QMP capture and a narrow synthetic-key
path. It cannot establish a native macOS display client, pointer transforms,
Retina, Windows modes/drivers, physical keys/modifier releases, graphics
acceleration or interactive frame pacing. A macOS27 candidate does not satisfy
the macOS14 floor. These remain separate product acceptance gates.

Primary contracts: [UEFI GOP and console input](https://uefi.org/specs/UEFI/2.11/)
and [QMP screendump/send-key](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html),
with exact definitions also retained in the pinned EDK2 headers and QEMU QAPI
source. The master QMP page is background documentation; actual behavior must
match the pinned11.1.0 source and executable.


## Released ARM64 display-only candidate — 13 October 2026

Offline candidate inspection (private development record omitted)
verifies pinned viogpudo ARM64 SYS/INF/CAT and offline signatures narrowly. Its
PCI1050 device differs from the live RAMFB plan. Keep the signed-in VM unchanged;
qualify the device/firmware/Windows loading path on a preserved copy before
applied native geometry, resize, frame pacing or acceleration claims.

## Windows CPU-rendered desktop limitation — 13 October 2026

Actual Windows TaskManager reports12virtualprocessors/24GiB; current GPU scanout
can render4096x2160, but this does not establish3D acceleration. The selected
viogpudo is a WDDM display-only path and the QEMU device is its default2D variant.
QEMU explicitly describes this variant as requiring guest software rendering
for3D: https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html .
Changing RAM/vCPU or display resolution does not create a Windows rendering driver.
Apple's documented VZVirtioGraphicsDeviceConfiguration targets Linux VMs:
https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration .
No verified public Apple-silicon GPU PCI passthrough path has been selected.

Current user priority is actual Windows GPU rendering. Build and qualify the
matched open Neptune/DXMT stack before resuming host presentation optimization.
A Metal presenter accelerates host presentation only.
Windows DirectX requires an actual ARM64 rendering driver with signed kernel/user
components plus a reviewed host command renderer to Metal, bounded resources/
fences/device-loss handling and representative correctness tests. Virgl/Venus/
rutabaga's documented Linux guest stacks do not qualify Windows by themselves.
No switch or passthrough control is exposed without that executable stack.

The native host prerequisite (private development record omitted)
now passes 145 upstream offscreen D3D11 checks on the host GPU. The open native
DXMT backend and matching ARM64 viogpu3d candidate provide a concrete next path.
Use native DXMT without D3DMetal; verify the actual guest protocol and hardware
workloads before any Windows acceleration claim.


14 October monitor-mode follow-up: keep the current signed driver's measured60Hz
separate from the user's120Hz target. Evaluate an explicit matching EDID rate on
the private Neptune profile: native75Hz timing exceeds the basic EDID descriptor,
where native60Hz fits. Generated checksum checks and diskless QMP qualification
are complete; real Windows acceptance is pending. Do not lower native geometry
silently or treat a raw mode, test return, or shader cadence as delivered frames.
See the updated Windows GPU evidence for failed GDI/4K results and the narrow HVF
ISV hardware/lifecycle qualification.
