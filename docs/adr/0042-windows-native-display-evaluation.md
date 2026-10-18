# 42. Qualify Windows 2D native display and active frame cadence

Status: experimental execution path under verification. The human requires
permanent VM controls, automatic capture after app switching, native Mac viewport
resolution, improved stability and good FPS. Continue through executable slices.

Retain the signed-in disk and RAMFB firmware recovery. Select virtio-gpu PCI1050
only through a closed private typed display request; ordinary registered startup
remains unchanged. Bound initial pixels to the existing canvas limit. Derive
desired dimensions from the actual guest view's backing rectangle, excluding
window chrome; do not infer applied Windows modes from requested dimensions.

A separate pinned QEMU candidate changes only active VNC refresh floor30ms to16ms,
retaining idle backoff and the existing host-loopback block. It has exact source,
recipe, build, sign, loader and native diskless device provenance. This is not
measured60FPS or improved guest performance. Keep the original runtime immutable.

One private read-only carrier has a single macOpenVM Setup entry point for pinned
ARM64 display/network/serial drivers, using Windows pnputil with normal signature
enforcement and visible errors. It does not yet install the macOpenVM agent.
Account/password/UAC input and new terms remain human-controlled where required.

Acceptance: parser/host-focus/backing-geometry/launch-resource tests; immutable
release build; actual diskless PCI/mode/clean-exit probe; preserved stopped Windows
copy; normal driver loading; actual applied framebuffer and console selection;
authoritative pointer alignment; native viewport resize acknowledgements; frame
intervals/input latency/idle CPU/soak and recovery. Do not stop at the package,
probe or component tests. Advanced graphics/seamless/service/release work remains
on the full ledger.

The registered trial now has a typed toolbar Display menu for firmware console1
and GPU console2. It sends QEMU's balanced Ctrl-Alt console chord on the current
private RFB connection only after current owner/intent/lease/launch validation.
Capture suspends during the chord and resumes according to the user's existing
preference. It is absent from ordinary sessions. A successful write is not a
guest applied-mode acknowledgement. Native trial verification remains required.

The read-only observer now records bounded per-frame wait and receive intervals
on ContinuousClock, with no pixel/text output. Admission checks occur between
frames, so receive intervals include their overhead. Quiet desktop updates may
wait; incomplete observations preserve samples and failure phase. These are
transport observations, not scanout FPS, application frame rate or input latency.

Explicit nextFrame(incremental:false) allows a diagnostic full refresh while the
default remains incremental. The CLI liveView action has no output-file option
and returns pixels only on explicit stdout; it must not be piped into generic
logs. Current private-screen display required fresh human approval for chat
retention after an automatic review rejection.

Pinned-runtime inspection found VNC SetDesktopSize forwards width/height to
virtio_gpu_ui_info, which updates requested output geometry and notifies
VIRTIO_GPU_EVENT_DISPLAY. Its ExtendedDesktopSize status4 means forwarded, not
applied. Current client advertises only Raw and DesktopSize; it does not parse
ExtendedDesktopSize or send SetDesktopSize. Add a bounded opt-in transport/parser
slice with one-screen validation, status separation, coalescing and observed
framebuffer completion before enabling automatic resize. Firmware console lacks
this UI-info support. Driver behavior remains an independent Windows test.

The driver's maintainer describes dynamic resize as depending on viogpuap.exe
and the vgpusrv.exe service in addition to viogpudo (July2025, driver0.1.271):
https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1391 . This is a
prerequisite to inspect and verify on the selected0.1.302 ARM64 candidate, not
proof that the kernel display driver alone supplies runtime resize. Do not adopt
or install uninspected helper binaries or start a service from this reference.

The exact retained0.1.302 RPM contains the ARM64 Windows11 helpers. A new bounded
private inspection selected only three EXEs and notice, resolved known byte-identical
archive aliases to ordinary private files, rehashed package/member/tool inputs and
ran offline PE/signature checks. vgpusrv (195224bytes) and viogpuap (194200bytes)
passed; viogpures (184416bytes) fails the pinned trust chain with a self-signed
development certificate. Preserve it as unqualified; no certificate import or
security bypass. No helper executed, installed, or redistributed. Source/license
closure, actual Windows service/session behavior and resize remain unverified.
Private qualification: windows-viogpu-helpers-302-57527e7121e3454a937d343f742fa40b.
