# Performance evidence

No speed or parity claim. Benchmarks/results contains structured raw evidence;
local guest output, paths and private metadata stay ignored under .lab or
Benchmarks/results/local. Published reports must be deliberately redacted.

## Method

Use a minimal AppleVz runner as the Linux native baseline. QEMU/HVF Windows is a
separate guest/device baseline. Do not compare unlike guests or silent TCG fallback.
Measure monotonic durations, preserve all trials, declare warm/cold cache and
background load, and report median, p95 and confidence interval. At least 20 stable
trials for regression claims; a one-trial feasibility result has no meaningful CI.
Publish exclusions before results, not after observing them. Target unexplained
regressions ≤5%, lifecycle medians within 10% of best viable comparable path,
and no unexplained idle integration wakeups. These are objectives, not results.

## Required metadata

Benchmarks/result.schema.json defines versioned fields for model/chip/P/E/GPU cores,
RAM, storage model/free bytes, power/thermal state/displays; macOS version/build,
app revision/backend/entitlements/config; guest edition/build/architecture/patch
and driver/agent versions; cache/trials/outlier/background/confidence policy.
Unknown metadata is explicit null with reasons; never substitute guessed values.

## GPU surface delivery experiment

Dedicated surface evidence (private development record omitted)
records actual two-process GPU export/draw with every-pixel checks at native and4K
geometry, four source formats and five sanitizer fault cases. Export medians span
0.513–1.014ms and consumer draw0.559–1.210ms across eight cases. These generated,
offscreen component measurements exclude source rendering and CPU validation;
ACK timing includes validation and a declared pause. No VM FPS, physical scanout
or120Hz claim follows. [ADR43](docs/adr/0043-metal-surface-delivery.md) keeps live
adoption gated on real producer completion and resource lifetime.

Readback conversion evidence (private development record omitted)
retains paired GPU-texture before/after timings and every-byte sanitizer checks.
RGBA conversion costs decreased in that component, but the live Windows workload
uses BGRA and bypasses it. App44 clean native draws measured41.2/38.6 per second,
below earlier App43 samples; no live gain or identified regression cause is
claimed. The completed App46/QEMU28 comparison measures53.4/52.4 native draws/s in two clean
trials, with draw p9532.01/32.68ms and worst45.04/45.60ms. The guest queued shader
separately completes55.0FPS at3440×1904/DPR2. QEMU28 stays current;29 is preserved.
Ordering/restart/cache/load are uncontrolled and App46 also changes input admission,
so no isolated causal regression or physical presentation claim follows.

Bounded native completion timing (private development record omitted)
now passes generated Direct3D, native/4K pixel/fence and concurrent output checks.
Ten alternating generated-workload pairs observe843.96ms timing-on and856.30ms
timing-off wall medians, including startup, pixel oracle and teardown; this is
neither a speedup nor live overhead claim. The subsequent App47 Windows trial
retains8448 completed records, with closed output below2MiB and normal shutdown.
Whole reports in the broad Start bracket have GPU span median2.409ms/p954.474ms;
overlap, omitted queues/readback and control/static time prevent utilization or
critical-path attribution. Native shader delivery is52.6 callbacks/s.

Receive-buffer borrowing (private development record omitted) removes
one materialization for validated Raw body chunks. Ten alternating generated
pairs observe native feed medians3.451→3.180ms and4K3.799→3.472ms; all pixels and
snapshots pass, as do50 parser/socket tests and a separate ASAN fixture. App48
restores the timing-disabled QEMU28/library and measures53.7/51.5 native draws/s
in two clean trials. Results overlap earlier observations: no clear guest FPS
gain is established. Start delivery is43.4/s in one synthetic trial; changed
instrumentation, boot/cache/load/order prevent an isolated causal claim. Native
fullscreen/menu and first-shortcut capture checks pass narrowly. Physical cursor,
GPU-surface transport, games and120Hz remain open.

## Workloads

Launch-to-library; cold/warm start-to-authenticated-agent-ready; suspend/resume;
clean/forced shutdown and recovery; sequential/random durable disk throughput,
IOPS and latency; NAT throughput/latency/CPU/connections; guest single/multi CPU and
host overhead; display frame-time/stalls and input median/p95; resize latency and
memory growth; large/small shared files; clipboard/drag-drop latency and memory;
idle CPU/wakeups/energy/thermal; clone/snapshot space/time/restore; long soak,
lifecycle cycles and crash recovery. State durability/flush options in every I/O run.

Rendering, transport and host presentation must be measured separately. Hardware
host compositing is not proof of guest GPU acceleration. Native-resolution 60 Hz
desktop behavior requires named host and applied guest-mode evidence.

The maintainer's current display is 120 Hz. The active engineering target is now
120 Hz interaction at the measured native guest viewport, with an 8.33 ms frame
budget and reported median/p95/p99 stalls. The earlier 60 Hz baseline remains
historical evidence; it is not the final acceptance target for this host. 4K
(3840×2160) and the actual Mac guest viewport are separate mode checks.

`examples/windows-gpu-check.html` v2 records its actual drawing buffer, browser
CSS viewport and pixel ratio, and discards trials on resize, DPI change, hidden
page or context loss. Queued drawing and the original synchronous `gl.finish`
workload have distinct identifiers and must not be compared as one workload.
`Benchmarks/test_windows_gpu_check.cjs` checks those measurement boundaries with
deterministic browser fixtures; it establishes no real GPU/FPS result.

## Current baseline

Five real ARM64 Linux direct-boot trials are recorded in
[apple-vz-alpine-console-2026-10-06.json](Benchmarks/results/apple-vz-alpine-console-2026-10-06.json).
The harness is [Benchmarks/native_boot.py](Benchmarks/native_boot.py); running it
requires an explicit --run, the prepared official fixture, a signed CLI and an
idle disposable VM. It verifies a live ARM64 console and clean guest shutdown.
New runs require a current build/build-manifest.json, verify source/binary/profile
and pinned media, and save unique exclusive reports and private sessions. See
[run instructions](Benchmarks/README.md) and
provenance/preservation evidence (private development record omitted).

| Metric | Five-trial median | Observed range |
|---|---:|---:|
| Native framework start completion | 81.11 ms | 78.16–86.27 ms |
| CLI spawn to guest console login | 3.635 s | 3.453–3.665 s |
| Guest poweroff to observed-stop CLI exit | 2.693 s | 2.635–2.871 s |

These are uncontrolled feasibility measurements on the named M5 Pro development
host, a debug runner, live RAM-root Alpine 3.24.2 / Linux 6.18.52-0-virt, 2 CPUs,
2 GiB RAM, full-synchronization sparse raw storage and no NIC. All samples are
retained; cache and background load were uncontrolled. Missing GPU, storage,
power/thermal, agent and driver metadata have reasons in the result. There is no
confidence interval, regression threshold or comparison result for these trials.

Framework completion and console login are distinct from authenticated-agent or
desktop readiness. This baseline does not establish guest CPU, I/O, desktop or
Windows performance. Never weaken authentication, isolation, disk durability or
Windows driver/security requirements to improve numbers.

Two additional release trials exercised the hardened harness and its provenance
checks; their raw values are in the linked evidence and unique JSON. The historical
debug report is unchanged. Profile, source scope and harness changed, and both sets
have uncontrolled cache/host load, so no regression or improvement is inferred.

Two further release trials exercised durable runtime history; see
runtime evidence (private development record omitted). The adapter now
times machine.start itself, excluding Core's launch-intent persistence. Earlier
framework-labelled samples included ordinary controller-call overhead. Keep that
boundary change explicit; no historical result is overwritten or directly compared.

## Process-monitor feasibility comparison

Event-monitor evidence (private development record omitted) records an
unchanged debug harness/package comparison on the named macOS 27 host. Each revision
has three sequential five-second trials with two system sleep children and no VM.
RUSAGE_SELF measures parent CPU over launch, monitoring and child exit/reaping:
before samples 0.055694/0.055425/0.058616 seconds, after
0.002520/0.001934/0.001991 seconds; medians 0.055694 and 0.001991 seconds.
Involuntary context-switch deltas were 1594/1617/1687 and 18/16/17; voluntary deltas
were all zero. All sources, binaries, raw records and comparison provenance remain
private and preserved.

Host load was uncontrolled and n=3 per revision. These observed samples do not
establish a confidence interval, regression threshold, parity, guest performance,
energy or wakeup result. Context switches are not system wakeup measurements. The
external per-trial budget was 15 seconds; the harness has no internal unresolved-
wait deadline and can remain pending after an observation fault. This component
comparison does not replace the guest/desktop performance acceptance above.

## Pending pointer work reduction

The motion coalescer's deterministic stress test (private development record omitted)
retains one pending slot for 10,001 adjacent unsent positions and preserves button
edge coordinates and other-input barriers. This is an operation-count invariant,
not a measured latency, frame-rate, energy or throughput improvement. Actual
AppKit-to-guest input latency and drag behavior need a named-host benchmark.

## Raw display decoder component

Row-decoding evidence (private development record omitted) records five
samples each for nine generated workloads with the same release harness and
verified pixels. On the named M5 Pro/macOS27 host, 4K steady decode medians changed
from20.619 to5.204 ms and initial decode from26.107 to16.485 ms. All decode medians
decreased; one small snapshot median increased and remains reported. Snapshots
stayed near0.55 ms at4K.

These are component observations with uncontrolled cache/load/thermal/power and
no confidence interval or threshold. They do not establish native frame pacing,
60 Hz presentation, guest rendering, Retina application or VM parity. Both raw
results and immutable build/source records remain preserved.

## Registered Windows transport timing

The experimental read-only registered observer reports frameWaitMilliseconds and
receiveIntervalsMilliseconds on a monotonic clock, limited to120 frames and a
30-second admission window. The five-second quiet-frame timeout is explicit;
incomplete runs retain only completed timing samples and the ending phase. No
pixels or guest text are exported. Receive intervals include ownership/route
validation between requests. Use a declared changing guest workload before
interpreting cadence; idle incremental silence is not a performance failure.
These samples do not prove screen scanout, guest application FPS, native mode,
acceleration or input latency. Actual applied Windows geometry and display-driver
health must be verified separately under ADR42.


## Packed raw conversion and first Windows GPU workload

The next same-harness release comparison uses four-pixel packed conversion with
unaligned loads and a scalar tail. All nine generated frame hashes match. Five
trials per case were run with the Windows VM running and uncontrolled thermal/load.
Private immutable before/after records are under the unique rfb-vector-conversion
laboratory; they are component observations without a confidence interval.

| Generated workload | Previous median ms | Packed median ms |
|---|---:|---:|
|720p initial|2.449875|1.962958|
|720p steady|0.834250|0.359708|
|720p dirty|0.010833|0.005416|
|1440p initial|10.047834|7.840500|
|1440p steady|3.222666|1.244292|
|1440p dirty|0.014125|0.007792|
|4K initial|17.465708|17.680583|
|4K steady|5.639542|2.732958|
|4K dirty|0.012375|0.008792|

The 4K initial median increased and remains reported. Snapshots are separately
recorded in the raw files. Fragmentation, odd strides, scalar tails and opaque alpha
pass the new parameterized decoder test. This is not a guest-FPS or native display
claim.

One original20-second Windows WebGL2 shader completed at30.5FPS, canvas2038×987
on a2048×1152 desktop, with the VirtIO/ANGLE hardware D3D11 path and no reported
renderer death, command error or former staging-upload abort. The scoped
graphics evidence (private development record omitted)
records the exact runtime and limitations. Metal readback samples were roughly
0.74–0.83ms per copy for2048×1152; they measure a component, not delivered frames.
Native-resolution good-FPS, input latency, host median/p95 presentation and soak
remain acceptance requirements.


14 October native transport follow-up: real Windows GDI/CCD accepted3456×2168,
but the old RFB path cropped at2160rows. After removing the limit and moving
expanded worker scratch to reused heap memory, an original diskless RAMFB test
received the full3456×2168 and checked every generated pixel. Its matching old
worker timed out before a frame. This is correctness and stall containment,
not a frame-rate benchmark.120Hz remains the goal; actual signed Windows mode
queries still report60Hz and no>=120Hz raw modes. See the Windows GPU evidence.

14 October live follow-up: the corrected transport also receives all3456×2168
from real Windows, matching its GDI/CCD mode. A guest0x119/parameter1=1 crash
followed benchmark navigation; stability is not qualified. Candidatev24 fixes
async global/context fence isolation and per-command inflight accounting; the
actual-source synthetic-queue regression fails on the old callback and passes
all10 cases on the correction. Its 4K60 EDID advertisement passes generated
checks, with live Windows acceptance pending. The private app's new20-second
measurement counts normal receives/draw callbacks without an observer or pixels;
results must distinguish these events from guest rendering and physical scanout.
Start-menu/window animations and native shader queued/synchronous trials are
next; no120FPS or crash-resolution claim is made.

Live v24 follow-up verifies4K3840×2160 GDI/CCD/RFB with apply0 and restore to
native3456×2168. Performance remains poor: original queued shader at3448×2036
completes3.5FPS; a20s Start-menu update/draw trial gives16.6 callbacks/s and
101.63ms p95 gaps. App receive-to-draw is0.21ms median/4.38ms p95 in that trial.
Corrected host sampling finds845/920 main-loop samples in VNC output-buffer
`memmove`, which shifts the unread suffix on every short write. Candidatev25
uses a readable cursor, compacting on capacity adjustment. Actual Buffer code
passes30000 seeded operations under ASAN/UBSAN; generated native8KB-drain
component median765.673ms becomes0.655ms with identical bytes (3 trials).
Bothv24/v25 diskless real RFB fixtures preserve every7,492,608 native pixel and
identical hash, exit0/reaped. End-to-end Windows v25 comparison is still pending;
these component timings do not establish FPS,120Hz or physical scanout.

### Native Windows transport follow-up, 2026-10-14

Private GPU evaluation remains experimental. At a native 3456 × 2168 guest/Mac
viewport, the normal 20-second receive/AppKit-draw trial measured 9.6 updates/s
on runtime25 and 20.6 on runtime26. The latter used a 3440 × 1904 shader drawing
buffer/DPR2; the former used3448 ×2036/DPR1, so these are not identical workloads.
Runtime27's bounded200ms active-to-idle VNC grace measured27.9 received/drawn
updates/s with median35.56ms, p9543.98ms and worst63.60ms; receive-to-draw median
0.35ms/p952.04ms. This trial used3440 ×1904/DPR2, actual native fullscreen and
no observer, build or profiler during the measurement. It is one trial of ordinary
frames/draw callbacks, not unique content, physical scanout, gaming or120Hz proof.
Private numeric record: native-delivery-v35-result.json. Runtime26 Start-menu
16-cycle trial measured17.9/s, p9552.88ms/worst220.15ms; runtime27 comparison pending.

An independent active host-stack trial, after visually verifying the original shader
was running at3440 ×1904/DPR2, found CPU cost in parser Data buffer allocation and
conversion, whole-surface Metal readback and VNC surface processing. No guest heap,
register dump or screen file was retained. Readback counters recorded120 copies of
3456 ×2168 in270.706–365.658ms for the displayed recent batches. The Windows driver
source's FlushToScreen emits a whole-resource flush; partial-damage optimization
cannot be assumed useful for this path. Parser allocation reuse passed29 focused decoder/client tests, but five generated
trials per case gave no material4K steady-full improvement (median2.6008ms before
and2.5913ms after). Initial4K decode regressed17.1111ms→17.8948ms. The candidate
was reverted; these component measurements do not establish a Windows FPS gain.

The desktop-fill presentation trial was rejected by the user because it was not
true macOS fullscreen. It has been removed from production source. App38 corrects the native fullscreen menu policy. An isolated real AppKit comparison
found that omitting the native autoHideMenuBar option forced hard hiding; retaining
the native option honored the unchanged system Never preference. The real Windows
VM reports menuVisible on entry and re-entry, requested0x405/effective0x400, with
one native fullscreen command. Native exit restores the windowed viewport. This
current-host proof does not qualify older macOS releases.

App37/runtime27 repeated the unchanged queued shader at3440 ×1904/DPR2:55.3 FPS,
1106 intervals, median17.50ms/p9532.30/p9936.10/worst36.60ms. These are renderer
results, not physical Mac delivery. A separate clean20s Start-menu trial with16
open/close cycles at350ms per press measured25.4 received/drawn updates/s,
median17.94ms/p9541.05/worst176.92ms; receive-to-draw0.21ms/p952.42. Both guest
and Mac viewport remained3456 ×2168. It used true native fullscreen; the previous
App31 trial used desktop-fill, so this is not an identical presentation comparison.
GPU utilization was not recorded and120Hz remains unverified.

Five generated30MB local-socket transfers per capacity produced median11.983ms at
256KiB,12.928ms at1MiB and12.211ms at2MiB, with identical payload hashes and all
writer threads joined. The256KiB hint is retained; larger buffers are not a proven
improvement and these components do not establish guest FPS.

App38/runtime27 completed the original synchronous GPU-wait shader at3440 ×1904/
DPR2:55.8 FPS,1116 measured intervals, median17.50ms/p9519.50/p9935.90/worst36.60ms.
1096 intervals exceeded9.17ms. The timed scope had no observer, build or profiler.
This confirms that this workload can complete GPU work near the signed driver's60Hz
limit; it does not qualify games, physical Mac delivery or120Hz. Display transport
remains the larger measured gap for this particular workload.

App39 tested requesting the next frame immediately after decoding the previous
frame, before its presentation on the main actor. Two clean 20-second trials
measured 29.0 and 28.0 received/drawn updates/s at the same native viewport and
3440 × 1904/DPR2 shader buffer. Median draw gaps were 33.88 and 35.28ms; p95
41.97 and 45.18ms. Timing began immediately before reloading the shader to avoid
including its stopped animation tail. This differs from the older baseline's
reload-before-timing procedure. No meaningful gain is established; the private
record is native-delivery-v39-result.json.

App41 requests one future frame after validating the
first Raw rectangle header of the current response. It permits at most two wire
requests and one immutable ready frame; default clients retain one wire request
and no prefetch. This is scoped to the evaluated QEMU server. The
[RFB specification](https://www.rfc-editor.org/rfc/rfc6143#section-3) permits a
single update to satisfy multiple requests, so a generic positive update header
or resize acknowledgement cannot safely trigger this overlap. Synthetic socket
tests cover partial bodies, backpressure, forced refresh, resize, cancellation,
input fairness and malformed responses. After the authorized restart, two clean
20-second trials using timing-before-reload measured30.9 and30.8 received/drawn
updates/s at3456×2168. Draw-gap median31.53/31.05ms, p9544.70/43.72ms and
worst56.05/89.47ms; receive-to-draw median0.31/0.32ms and p952.04/2.17ms.
This is a modest observed improvement on App39's same-procedure trials, without
a confidence interval. One earlier mixed trial was excluded because CS2 startup
replaced the shader during timing; it cannot establish a prefetch regression.
The completed queued shader observed57.4FPS at3440×1904/DPR2. These timings
remain distinct; neither establishes physical scanout, gameplay or120Hz.

The candidate passes an actual diskless QEMU27/HVF RAMFB conformance fixture using
four immutable generated public surfaces at3456 ×2168. The release client checks
every RGBA pixel in all four frames, retains earlier snapshots unchanged, checks delivery after
a consumer pause, and drains prefetch before a forced fresh refresh. The actual
QEMU request trace verifies two full requests and four incremental requests, all
for the native geometry. The actual client and QEMU children exit0 and are reaped; QMP quit
acknowledges. No user VM, disk, NIC or GPU workload participates. An initial bare
metal alignment fault and a deliberately mutable CPU-fill/tearing fixture were
corrected in the fixture and preserved as failed attempts. This establishes
protocol conformance for this evaluated server, not a Windows FPS improvement.

Source42 avoids copying already-validated RAW body fragments into the parser's
buffer when no prefix is waiting. Component evidence (private development record omitted)
records48 passing decoder/client tests and all nine matching generated frame
hashes. Five-sample4K steady full-frame median decode decreased from2.682 to
1.918ms; snapshot copy remained0.545/0.554ms. Dirty updates and every sample are
retained, including small increases. Host scheduling/cache/load were uncontrolled.
Actual diskless QEMU27/HVF conformance with the current retained release objects
also passed: four native generated frames, immutable snapshots and fresh refresh;
actual probe/QEMU exit0 and normal acknowledged cleanup. After the authorized
normal restart, two native3456×2168 Windows trials measured51.6/50.5 AppKit draw
callbacks/s (received52.6/51.1), median draw gap18.91/18.92ms and p9533.39/33.49ms.
This improves the observed App41 rates, with guest restart/cache/background state
uncontrolled and no randomized causal or confidence claim. The separately measured
first queued shader completed55.2FPS at3440×1904/DPR2. Start-menu toggling still
shows stalls: median17.81ms/p9540.75ms/worst192.79ms; GPU utilization unmeasured.
See the component evidence for all scopes.60/120Hz, physical scanout and games
remain unqualified.

The partial Metal readback experiment (private development record omitted)
passes generated-pixel and exact-callback checks, but establishes no live gain.
App43 observed50.1/46.6 native draws/s. All57 captured120-copy batches remained
full-frame, with zero partial copies or failures; the signed driver did not expose
the synthetic small-copy opportunity in that scope. A32-cycle Start workload now
keeps input active across the full20s measurement:44.1 draws/s, median17.96ms,
p9538.53ms and worst207.53ms. Its protocol differs from the earlier16-cycle test,
whose static tail can inflate the worst gap. All old samples remain retained.

The 15 October live CS2 investigation (private development record omitted)
reproduces roughly10-second delivery gaps on both display routes while
receive-to-draw delay stays low. App52 prevents measured App Nap but does not
resolve the gaps. Windows records0x119/subtype1 graphics completion-ID crashes.
The57 trial reports4GiB dedicated graphics memory after enlarging the host-visible
mapping window; performance comparison remains pending. These are distinct
observations, not proof that memory capacity caused the freezes or crashes.


## Fenced cleanup and actual CS2 follow-up

[ADR48](docs/adr/0048-fenced-blob-unmap-suspension.md) records the suspended-fenced
unmap bug and its attributed upstream fix. Actual App60/QEMU34 main-menu delivery
measures58.3/s at3456×2168, versus6.8/s for preceding App59/QEMU33. First offline
DustII stationary-camera gameplay measures55.7/s, with gap median16.00ms,
p9530.44ms and worst404.18ms. Receipt-to-draw median1.00ms/p951.70ms. These are
short sequential samples without controlled host load; no universal improvement,
physical scanout or120Hz claim follows. The shorter hitch and long-term scheduler
stability remain open. The [relative mouse slice](docs/adr/0049-relative-game-mouse.md)
addresses the newly confirmed absolute-pointer limit on camera turning separately.

App66/QEMU34 main-menu delivery at3456×2168 measured47.8/s with24GiB guest RAM,
draw gaps19.85ms median/32.06ms p95/327.46ms worst. A sequential16GiB run measured
54.2/s and18.59/24.68/84.92ms respectively, after manual reconnect restored the
Metal path from a startup fallback. These samples do not control restart/cache
state or host load. Separate10-second host aggregate counters showed compression
at94.9/95.3MB/s and swap reads4.2/60.8MB/s for24/16GiB; counters were not synchronized
with individual frames or attributed to the VM. The memory conclusion is mixed,
so24GiB was restored while stopped. Do not advertise a lower-RAM FPS improvement.
The [terminal-cause fix](docs/adr/0050-shared-display-terminal-cause.md) preserves
the reset reason needed by bounded accelerated-display recovery; live acceptance
remains pending. Neither sample measures internal game FPS or physical scanout.


In the subsequent exclusive test window, App67/QEMU34 with the original24GiB and
unchanged graphics libraries delivers60.4/s in the native CS2 menu (36.95ms worst
gap) and56.7/s in local DustII with bots (130.65ms worst). Startup/game transitions
retain Metal without manual reconnect. Receipt-to-draw stays low at1.50/0.83ms
median. The separate host sample has negligible swap reads and zero compression;
changed host/cache state prevents attribution to the display fix alone. The
remaining gameplay hitch, applied120Hz guest mode and physical presentation gates
remain open. See ADR50–51 for recovery and the separately prepared identifier
optimization; no candidate-library benefit is included in these results.


[ADR51](docs/adr/0051-constant-interface-identifiers.md) records App68's forced
constant literal IDs. The actual O3 header probe eliminates runtime parsing and
preserves known GUID bits; the signed native library retains all16 public exports
and imports. Actual native Windows CS2 menu55.5/s is lower than preceding60.4;
DustII58.4/s is higher than56.7 but its worst gap149.22ms exceeds130.65ms. These
mixed sequential results establish no overall FPS gain. The experimental change
is retained for demonstrated eliminated work, with prior bytes and rollback
available. Physical scanout/internal game FPS,120Hz and long-term stability stay
unqualified. Both Windows/App68 stop and actual parent reaping complete normally.

## Paired Windows120Hz mode,16October

The matched wire2/ABI1 host and signed v0.4 driver pass191 native D3D11 cases.
App74 readback verifies3456 ×2168 in both Windows source and CCD target, GDI120Hz
and CCD VSync/path120/1; hardware D3D11 FL11.1 uses the same render/display
adapter. The original graphics recovery overrides are absent after reboot.
CS2 settings independently show3456 ×2168 at120Hz. This supersedes earlier
current-driver60Hz limitations above; those results remain historical. See
[ADR57](docs/adr/0057-graphics-protocol-pairing.md) and the private pinned
`neptune-protocol2-20261016/windows74-live-result.json`. The CCD application is
temporary and mode persistence remains unverified.

120FPS has not been achieved or qualified. A visible Nuke spectator counter near
48FPS is uncontrolled. One20-second app sample records zero received/drawn
updates despite a changing independent GPU view; later views agree. This
discrepancy requires live investigation, not a claim of permanent transport
failure. App75 adds opt-in Metal presentation timestamps separately from GPU
completion under [ADR58](docs/adr/0058-mac-presentation-feedback.md). Keep gameFPS,
receive/completion rates, Mac presentation feedback and physical scanout distinct.


## Shared Metal surface presentation, 16 October

App77's dedicated AppKit Metal surface, MainActor geometry and visibility replay
pass regression tests and a 20-second windowed Windows shader sample: 107.8
received/s, 107.8 GPU draws/s and 107.5 Mac presentations/s. Presentation gaps are
median 8.33 ms, p95 16.67 ms and worst 33.33 ms. The guest framebuffer is native
3456 × 2168; the windowed Mac viewport is 3456 × 2002, so this does not qualify
native fullscreen. The browser's fullscreen drawing buffer is 3456 × 2169 at
DPR 3, with roughly 110 FPS for that shader, distinct from delivery/game FPS.

Native fullscreen's settled sample receives/draws 107.3/107.1 per second but
reports zero Mac presentations; reconnect repeats 107.3/107.2/0. No extra display
observer runs during the samples. Cancelled/idle samples carry no FPS claim.
120 FPS, native fullscreen presentation and gaming remain unresolved. See
[ADR59](docs/adr/0059-presentation-visibility-reconciliation.md) and the private
`mac-presentation-feedback-20261016/app77-live-result.json`. The VM and App77 close
normally. App78 adds numeric diagnostics to distinguish raw zero presentation
timestamps from callback filtering and fullscreen layer/window state.


App78 subsequently measures 107.8 Mac presentations/s windowed and **105.8/s at
the native 3456 × 2168 fullscreen viewport**. Both 20-second samples have median
presentation gap 8.33 ms, p95 16.67 ms and worst 16.67 ms. Native fullscreen
receive/draw rates are 106.0/106.0 per second. No independent observer runs during
the sample. The guest shader, actual Mac presentation and physical scanout stay
separate; sustained 120 FPS and games remain unqualified.

The zero-presentation fullscreen reconnect diagnostic is on another macOS Space
at both boundaries despite key/active/visible flags: all 2,157 raw callbacks have
zero timestamps. App79 requires active-Space eligibility for rendering and
measurement, and replays visibility when Spaces change. It passes 27 focused app
and six backend tests plus signed release/provenance checks. After manual unlock,
App79 measures107.6 Mac presentations/s windowed and107.1/s with the full-display
shader at the native3456×2168 Mac viewport. The shader itself is3456×2169 atDPR3,
not exact native height. Both samples have worst presentation gap16.67ms; the
fullscreen receive→draw median/p95 is0.92/1.45ms. A browser-chrome fullscreen
reconnect sample measures106.0 presentations/s. Off-Space attempts reject the
sample, and lost focus cancels it. Fullscreen eligibility/resume and reconnect
are verified within this bounded scope;120FPS, games and physical scanout remain
open. Producer full-readback batch means near2.3ms/frame are a measured cost,
not a complete critical-path attribution. VM and App79 close normally with actual
exit/reap0 and settled intent. See ADR59 and private `app79-live-result.json`.


## Resource-owned scanout view reuse, 18 October

[ADR60](docs/adr/0060-resource-owned-scanout-imports.md) and the
[reproduction fixtures](Benchmarks/ScanoutCache/README.md) record the cache of
shared-memory Metal import views. Nineteen sanitizer cases and eleven actual
public-renderer cases with 38 GPU reads passed. Six counterbalanced native-size
process pairs show 1,200 warm acquire/release loop medians of 14.911 ms before and
0.018625 ms after, with correct pixels in every run. All 7,200 candidate acquisitions
reuse their independently retained resource views. Timing excludes autorelease
drain, setup, GPU work and readback; individual new calls approach clock resolution.
These are import-call measurements, not game FPS, 120 FPS, producer-fence or physical
scanout acceptance. Existing frame copies and GPU/readback ordering remain.
The signed app was subsequently installed after clean guest shutdown. The same
Windows VM booted and signed into its desktop, and its running QEMU process was
verified to have loaded the new renderer. Live game FPS remains unmeasured.

## Native pixel scaling development, 18 October

[ADR61](docs/adr/0061-native-pixel-scaling.md) records the scaling inspection,
resize correction, opt-in integer presentation and default-off light sharpening.
No steady-state double scaling was found in the inspected host stages. Integer
presentation avoids fractional pixel blocks by adding letterboxing; it does not
increase guest detail. Shared geometry keeps input aligned with the image.

The exact-source [component fixtures](Benchmarks/DisplayScaling/README.md) pass
historical/default pixel equality at all eight geometries. The new two-library
native experiment measures about 34–50 microseconds additional median GPU work
for enlarged sharpening and about 32–83 microseconds mean paired p95 cost.
Native and integer 1x cases bypass sharpening. The default CPU geometry/map
component measures approximately 23.71 ns before and 24.76 ns after per call.
These results exclude the guest, producer, drawable acquisition and compositor.
They do not establish no live FPS regression, near-native performance or 120 FPS.
The installed app remains unchanged pending that live gate.

The separate [HDR wire foundation](Benchmarks/HDRFrameWire/README.md) preserves
explicit FP16 scRGB values and snapshot ownership in generated CPU tests. It has
no producer/client/EDR/driver integration and does not enable Windows HDR.
