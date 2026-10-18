# 59. Give shared Metal presentation an AppKit surface and reconcile visibility

Status: App79 active-Space correction passes component tests and bounded live
windowed/fullscreen/resume/reconnect checks. VM and actual app parent close
normally. Sustained120FPS and games remain unqualified.

The frozen wire2/ABI1 host and signed v0.4 driver remain paired. App75 and App77
fresh Windows readbacks agree on a 3456 × 2168 source and CCD target, GDI 120 Hz,
CCD VSync/path 120/1, hardware D3D11 FL11.1 and unset original recovery overrides.
These mode observations do not establish 120 FPS.

App75 receives shared updates after reconnect but completes no draws. App76
reconciles visibility on each received frame, covering notifications that occur
before renderer creation. Its actual shared-memory/GPU regression passes, but
live fullscreen still reports false visibility and no drawable requests while
cache copies continue. Reconciliation alone is insufficient. Its background test
build prevents performance qualification.

App77 gives the renderer a dedicated NSView whose actual backing layer is the
CAMetalLayer, rather than attaching a sublayer to the raster input view. Hit
testing remains on the original input view. Only MainActor changes surface and
drawable geometry, inside a disabled-actions Core Animation transaction, and
only when values change. The dispatch GPU queues consume numeric geometry and
perform cache copies, acquisition and rendering. Apple documents this custom
[Metal view pattern](https://developer.apple.com/documentation/metal/creating-a-custom-metal-view)
and [transaction ownership](https://developer.apple.com/documentation/quartzcore/catransaction).
This motivates the correction; it does not prove every former stall had one cause.

A visible, nonminimized, active key fullscreen owner remains eligible when its
occlusion bit is absent. Ordinary hidden/minimized/background/nonkey owners do
not gain that exception. Focus/fullscreen changes replay current activity for a
static cache. Producer ACK remains actual GPU cache-copy completion. Hidden
windows continue copies/ACKs without requesting drawables. No idle-stream timeout,
driver/backend change or guest recovery override is added.

The actual shared-memory/GPU regression uses an unshown window with controlled
visibility getters. It verifies hidden copy, showing without an occlusion
notification, one resulting drawable request, and hiding again. It additionally
checks the dedicated backing layer, resize geometry and unchanged input hit
testing. Visibility policy, frame timing, recovery, cursor and input checks pass:
26 app tests across five suites and six backend tests. Strict formatting and a
signed release build/package pass. These tests do not claim a physical drawable
was displayed by an unshown test window.

App77's valid 20-second windowed live sample measures 107.8 receives/s, 107.8 GPU
draw completions/s and **107.5 Mac presentations/s**. Presentation gaps are median
8.33 ms, p95 16.67 ms and worst 33.33 ms; receive-to-draw is median 0.91 ms and
p95 3.14 ms. Windows remains 3456 × 2168, but the Mac viewport is 3456 × 2002,
so this is not native fullscreen qualification. The queued browser shader's
fullscreen drawing buffer is 3456 × 2169 at DPR 3 because of CSS rounding; do not
call it the exact native height or confuse its roughly 110 FPS with delivery.

After native fullscreen transition, a settled 20-second sample measures 107.3
receives/s and 107.1 draw completions/s, but **zero reported Mac presentations**.
Recreating the surface via Reconnect Display repeats 107.3/107.2/0. No independent
display observer or screenshot runs during these samples. Two other samples are
cancelled and carry no performance claim. Native screenshots and the standard
GPU display are used only outside timed windows; no guest screenshots are saved.
The remaining fullscreen issue must not be called fixed from GPU completions.

Numeric sample boundaries report view/window visibility, layer attachment and
copy/draw/request counters. App78 additionally records active-Space status,
numeric layer geometry/visibility, cancellation boundaries and raw Metal
callback zero/positive counts. These opt-in diagnostics retain no pixels, guest
text or credentials and do not change production ACK or rendering policy.

Private evidence is in `.lab/mac-presentation-feedback-20261016/app75-live-result.json`,
`app76-live-result.json` and `app77-live-result.json`, plus signed package pins,
actual parent exit records and preparation logs. App77's VM and actual app parent
settle normally. Preserve App74–App77 rollback packages, disk, UEFI, TPM and VM
identity. Native fullscreen delivery, sustained 120 FPS, gaming and physical
scanout remain open.


App78 repeats windowed delivery at 108.2 receives/s, 108.0 draws/s and 107.8 Mac
presentations/s, with worst presentation gap 16.67 ms. A native 3456 × 2168
fullscreen run reports 106.0/106.0/105.8 per second and worst presentation gap
16.67 ms. Raw callbacks confirm positive timestamps, and the window is on the
active Space at both boundaries. This is one bounded shader workload, not 120
FPS, game performance or physical scanout qualification.

A later fullscreen reconnect diagnostic reports key/active/visible flags while
`isOnActiveSpace` is false at both boundaries. All 2,157 raw callbacks have zero
presentation timestamps; GPU draws continue. This explains that particular
zero-presentation run and motivates App79's narrower policy. Earlier App77
samples lack the active-Space field, so their precise cause remains unproved.

App79 requires `isOnActiveSpace` before drawable acquisition and throughout an
opt-in sample. An attempt on another Space clears old results and explains that
the window must be on the current desktop. It also suspends fullscreen chrome
and input focus handling off that Space. A workspace notification reconciles
activity for a static cache when Spaces change, using the workspace notification
center for both registration and removal. A regression rejects even a key,
active, visible fullscreen owner on another Space, including a stale visible
occlusion bit. The actual shared-frame test window supplies controlled active-
Space status. All 27 focused app tests and six backend tests pass, as do the
signed release build and package. No 120 FPS claim is added.


At the earlier App79 live checkpoint, the native-control tool reports macOS locked.
Read-only worker status still reports state 2, held ownership 0, backend active,
no pending operation and error 0. The actual app parent is retained and has not
exited; no app replacement or VM force stop is performed. App79's static sample
is not a performance result. Live animation, off-Space suppression/resumption and
normal closure initially require the user to unlock macOS directly.

After the user manually unlocks macOS, fresh inventory, actual retained parent
and admitted status are reconciled. Windows sign-in and desktop are verified.
App79 repeats source/CCD target3456×2168, GDI120Hz, CCD VSync/path120/1,
hardwareD3D11 result0/FL11.1 and unset recovery overrides. No mode apply is needed.

Four20-second samples with no extra observer or concurrent build establish:

| Sample | Mac viewport | Shader buffer | Receive / draw / Mac presentations per second |
| --- | --- | --- | --- |
| Windowed, browser chrome |3456×2002|3432×1773|107.8 /107.8 /107.6|
| Native fullscreen, browser chrome |3456×2168|3432×1773|108.2 /108.2 /108.0|
| Native fullscreen reconnect, browser chrome |3456×2168|3432×1773|106.2 /106.2 /106.0|
| Native fullscreen, full-display shader |3456×2168|3456×2169|107.3 /107.3 /107.1|

The guest framebuffer remains3456×2168. Active-Space status is true at every
valid sample boundary; raw positive timestamps agree. All four presentation-gap
distributions are median8.33/p9516.67/worst16.67ms. The full-display sample's
receive→draw is median0.92/p951.45ms; draw gaps are9.34/10.98/12.46ms. Separate
browser readback reports110.0FPS, median9.10/p959.60/worst11.20ms. Its extra
shader row is the documentedDPR3 CSS rounding, not exact-native-height proof.

Lost focus cancels one sample; attempts on another Space reject measurement and
clear the old result. Windowed/fullscreen transitions resume presentation. The
reconnect sample above succeeds; a later full-display reconnect is on another
Space and is correctly rejected, so it has no performance result. This is bounded
live eligibility/resume evidence, not a full multi-Space stress qualification.

Existing numeric producer records show full-readback batch means near2.3ms per
native frame, plus roughly0.5–0.7ms shared host copy. These batches are not
correlated per frame with the timing samples; they identify costs, not the whole
critical path. The current readback already uses NEON conversion, and the reviewed
driver source already uses an exact periodic high-resolution vsync timer.

Ordinary Windows shutdown completes: actual QEMU/TPM exit0, no signals, drained
output, platform state flushed/revalidated, settled intent. Native Quit then
closes/reaps the retained app parent0. All four frozen graphics pins and three
App79 pins match after closure. VM disk, UEFI/TPM/identity and rollback packages
are preserved; no guest screenshot files are saved. Private `app79-live-result.json`
records the numeric evidence and actual normal result.120FPS, game pacing,
physical scanout, audio and long-running stability remain open.
