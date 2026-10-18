# 43. Evaluate dedicated GPU surfaces for Windows display delivery

Status: experimental component proof; live integration is not adopted.

The current Windows D3D11/Metal path renders the native shader around the signed
driver's60Hz limit. Borrowed RAW input improved observed Mac delivery to roughly
50 updates/s. Partial readback showed no live gain: the captured driver updates
were full-screen. A direct GPU export path is the next experiment, while the
working RFB display/input path remains available.

Use dedicated host output IOSurfaces rather than exposing guest resource memory.
Apple documents [Metal textures backed by IOSurface](https://developer.apple.com/documentation/metal/mtldevice/maketexture(descriptor:iosurface:plane:))
and [Mach-port surface references](https://developer.apple.com/documentation/iosurface/iosurfacecreatemachport(_:)).
The component renders into a bounded two-surface pool, transfers capabilities over
a private inherited channel, and accepts one in-flight frame until the consumer
finishes GPU work and acknowledges its exact sequence/epoch. No pixel files,
global surface IDs or globally named service are needed in this fixture.

[Public component sources and procedure](../../Benchmarks/MetalSurface/README.md)
exercise single-process and actual two-process GPU delivery at native and4K
geometry across four source formats. Every consumer pixel is independently
checked. Replay, stale epoch, exit, stalled-consumer and malformed-metadata cases
exercise failure handling under address/undefined-behavior sanitizers. Actual
processes exit and are reaped, without forced cleanup.

This is evidence for a component, not guest performance. Source GPU completion
precedes each measurement. The future guest path must establish the real
Neptune/DXMT producer-completion boundary; it must not obtain faster results by
submitting an unfinished guest frame. Copy/export, notification, consumer draw,
and presentation need distinct timestamps. An offscreen draw is not scanout.

The inherited-channel fixture is limited to its purpose-built owned child. Before
adoption, bind the channel to the existing reviewed worker, actual runtime, VM,
session and frame epoch. Preserve unrelated registered ports, prevent inheritance
into unrelated helpers and validate kernel peer identity and resource admission.
Shader-read usage is not capability-enforced read-only access. Writable shared
output must never alias guest memory or a texture imported back into the guest.

Further acceptance requires exact geometry/format/row-stride budgets, initial
coverage, stale-frame rejection, resize and reconnection, bounded asynchronous
backpressure, GPU-completion-aware reuse, cancellation/peer-death recovery and
leak checks. Input must retain its authoritative viewport transform and normal
capture/release behavior. The consumer view must preserve the real macOS menu,
window ownership, fullscreen transitions and cursor behavior. Compare against
the existing display with repeatable live trials before changing its default.

The signed Windows driver still reports60Hz. This host transport experiment does
not qualify a120Hz driver, games, additional guest graphics APIs or release parity.
