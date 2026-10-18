# Windows HD Audio playback through CoreAudio

Status: experimental in App71/QEMU38. Windows device/endpoint checks and
non-silent CoreAudio delivery pass. The user's listening check still reports
missing or distorted sound; useful playback remains unqualified.

Before this work, the Windows GPU trial launched no audio device. QEMU34
reports only `none` and `wav` audio backends: CoreAudio was disabled by the
minimal build recipe. Adding a guest driver alone cannot produce Mac sound.

Build a separately pinned QEMU35 with the existing graphics/HVF fixes and
explicit CoreAudio support. Expose an Intel HDA controller and the output-only
HDA codec to the ARM64 guest. Windows' inbox HDA stack is the first candidate;
actual ARM64 device loading and playback must be observed before claiming
compatibility. No unsigned kernel driver or enforcement change is needed for
this candidate. The VM's disks, TPM, firmware and creation identity are retained.

A caller-reviewed runtime capability selects one fixed recipe. Ordinary resource
profiles default to no audio. Stored metadata cannot enable it, choose a backend,
inject device arguments or select recording. The capability requires an explicit
runtime descriptor with a verified CoreAudio import. Worker reconstruction must
retain it. The trial uses one 48 kHz stereo output voice, a requested10 ms device
buffer and four software buffers; the host may clamp that request. These settings
are a starting point for stability qualification, not a measured latency promise.

The codec exposes playback only, the CoreAudio backend has zero input voices,
and the plan explicitly sets `in.voices=0`. Microphone forwarding requires a
separate consent/configuration/revocation design and is not enabled by this work.

The public CoreAudio callback currently returns without writing when fewer than
a device buffer of samples are pending. The candidate first silences host output,
plays available complete frames in ring order, and leaves silence for the missing
frames. It also clamps writes to the actual host buffer capacity. Lock failures
and callbacks from an old device produce silence and consume no guest samples.
The callback contains no allocation or device-property access. Its existing
buffer-lock error helpers can call `error_report`/`strerror`; that realtime error
path remains a separate safety gap.

Counters record callback count, delivered frames, non-silent sample count and
underrun callbacks. They contain no sample contents or guest recordings. At
voice teardown, after stopping output, at most eight numeric summaries per QEMU
process are emitted under the existing buffer lock. Zero callbacks or non-silent
samples cannot be reported as working audio. Counters alone do not prove the
user heard sound or establish latency/channel balance.

An extracted actual-callback probe reproduces dropped partial sound in the prior
source (exit43), then passes wrapped partial playback, silence, host-buffer
canaries and lock/device-failure checks in the candidate (exit0). Both actual
parents are reaped. This proves the tested callback behavior, not Windows or
CoreAudio integration.

Acceptance requires the signed/pinned backend and framework closure, a real
Windows HDA device without a problem code, a playback endpoint, non-silent guest
sound reaching actual CoreAudio callbacks, speaker/channel confirmation, normal
VM/app settlement, and graphics delivery measured while audio plays. Device
changes, pause/resume, mute/volume, crackle/dropout and long playback remain
separate qualification gates. Preserve the prior immutable runtime and app for
rollback.

The native QEMU35 build, signing and exact loader-closure check pass. Its actual
help lists CoreAudio. App69's21 focused backend/catalog checks and release
provenance pass; the initial sandboxed debug-symbol step was refused by macOS,
then the authorized build retry completed. The normal single-app installation
preserves App68 and the prior renderer/runtime bytes.

Actual Windows reports Microsoft's High Definition Audio Device with statusOK
and problem code0, plus a healthy Speakers endpoint. Its Advanced page shows
16 bit/48 kHz. The standard Test button was clicked through the bounded VM
connection. The user reports missing or distorted sound. No playback-counter
summary appeared at normal shutdown. Therefore endpoint presence is not called
working playback, and absence of a teardown summary does not establish whether
the callback never ran or its finalizer was not reached. Windows/QEMU/TPM and
the retained app parent all settled/reaped with exit0; no app instance remains.

QEMU36 tracks the registered IOProc's own start/stop state instead
of inferring it from the device's running property. Apple's
[AudioDeviceStart contract](https://developer.apple.com/documentation/coreaudio/audiodevicestart%28_%3A_%3A%29?language=objc)
starts the specified callback; active hardware cannot establish that a newly
registered callback has started. An actual-function probe with a running-device
condition reproduces the skipped start (old exit43) and passes ownership,
duplicate suppression, failed-state retention, retry and unavailable-device
cases (candidate exit0). This is a control-function regression, not a proven
cause of this Windows failure. The candidate emits bounded initialization and
control status plus zero-callback summaries, and snapshots counters under the
buffer lock before logging outside it. Strict device initialization also rejects
an unknown output device or missing callback rather than returning success.
Actual-function probes reproduce false-success initialization in the older
source and pass the candidate's device/property/callback failure boundaries.
The admitted QEMU35 bytes are preserved unchanged.

App70's actual QEMU36 initializes the MacBook Pro Speakers at48kHz stereo with
a480-frame device buffer, and starts/stops its own callback with status0. Its
final numeric summary records28226 callbacks,13547963 delivered frames,
25779090 nonzero samples and2 underrun callbacks. These are cumulative counts
across several stream activations, not a timing or channel-quality measurement.
The user played CS2 during part of this run, then again reported missing or
distorted sound. This rules out a wholly unstarted output callback in this run;
it does not establish the samples' level, format, channel routing or audibility.
Next qualification must distinguish those boundaries using numeric PCM/format
checks and known generated audio without retaining guest recordings.

The next source candidate reads the device's output format back after the
existing request, and reports bounded numeric PCM peak/RMS, invalid/out-of-range
sample counts and the callback's actual buffer/channel/byte layout. It snapshots
those counters under the existing buffer lock and logs after unlocking, away
from the realtime callback. The callback keeps the existing copied PCM and
handles an empty/null output buffer without reading it. This diagnostic slice
does not alone fix or explain the listening failure. The diagnostic callback
passes partial/wrapped PCM, canary bounds, invalid/finite sample statistics and
empty/null buffers under ASAN/UBSAN. QEMU37 builds/signs and passes exact native
closure admission. A generated left440Hz/right660Hz probe through that callback
starts/stops/destroys its IOProc successfully:169 callbacks,72000 frames, one
stereo4096-byte output buffer, peak0.08/RMS0.035377 and no invalid sample. It
changes no device setting and retains no recording. The user missed both short
tone attempts; neither response establishes audibility or quality.

The supplied4096-byte buffer holds512 stereo float32 frames. The prior callback
caps consumption at the earlier device frame setting; a smaller setting injects
a silent tail despite available PCM and falls behind actual consumption.
QEMU38 uses the supplied byte capacity, retaining bounds and underrun silence.
An actual old/new probe reproduces under-consumption/silence with eight supplied
frames but an earlier setting of four (old43), then consumes all eight without
touching canaries in the correction (0), also under ASAN/UBSAN. This is a concrete
callback defect; its contribution to this user's Windows failure still requires
a live comparison. QEMU38 builds/signs. The signed/provenance-verified App71
combines it with the capture menu and hidden-window changes and preserves App70.
After the Mac was unlocked, App71 starts Windows without manual display reconnect.
The actual output format is48kHz, packed interleaved float32 stereo,8bytes/frame.
The final bounded signal summary records1040 callbacks,497345 delivered frames,
860109 nonzero samples and5 underrun callbacks. Peak is0.511238 and RMS0.061133,
with no nonfinite or outside-unit-range samples. The observed callback buffer is
one stereo3840-byte buffer:480frames, matching the earlier requested setting.
Thus the larger-capacity correction is a verified defect fix but does not explain
this run's listening failure. The user again reports missing or distorted browser
sound. These cumulative summaries do not establish continuity, channel phase,
Windows endpoint volume or physical speaker output.

A read-only native CoreAudio property check after shutdown observes the same
default output device, unmuted, scalar volume1.0 and nominal48kHz. The sandboxed
query returns no output device and is retained separately; it cannot be used as
hardware evidence. A12-second generated left/right tone through Apple's separate
[AudioQueue output API](https://developer.apple.com/documentation/audiotoolbox/audioqueuenewoutput%28_%3A_%3A_%3A_%3A_%3A_%3A_%3A%29)
creates, enqueues, starts, returns its buffer, stops and disposes with status0.
Its actual parent exits/reaps0. It opens no microphone, changes no device settings,
and retains no recording. The user requests a repeat, which also completes/reaps0,
then reports missing or distorted sound. macOS Sound shows built-in MacBook Pro
Speakers selected,100% output, mute off and centered balance. These observations
leave physical output/audibility unresolved even on the separate host path.
The user then goes AFK and requests graphics priority; listening tests are paused.
This comparison must not be described as repaired Windows playback.

Windows returned to its desktop after the user's session. The existing
Control–Option–Escape shortcut changed the native Input menu to Input Released
while Game Mouse remained selected. Normal Machine → Shut Down settled
QEMU/TPM with exit0 and no signals; the actual app parent was reaped with exit0,
and a refreshed app inventory showed no macOpenVM instance. App71 repeats the
live Game Mouse release check and shows the explicit Release Game Mouse action
and shortcut caption. Its normal runtime result flushes platform state and settles
intent; QEMU/TPM and the actual app parent exit/reap0 without signals. No new
gameplay FPS or120Hz result was measured in this run.

A later isolated source candidate rejects output-format readback failures,
incomplete ASBD property results and unsupported formats before registering an
IOProc or allocating the emulated output buffer. Its fixed experimental recipe
admits only48kHz, two interleaved channels, native float32,8bytes per frame and
packet, and one frame per packet. It explicitly requests native packed float.
Apple's SDK documents packed layout as implied when all channel bits fill the
frame, so the equivalent ASBD without the explicit Packed flag is also admitted.
Other format flags are rejected by this bounded recipe.

Each callback first silences every supplied non-null buffer over its advertised
byte capacity, retaining the buffer metadata. Playback then requires exactly one
stereo buffer, complete8-byte frames, a float-aligned data pointer and the
expected voice frame size. Mono, planar or multiple-buffer layouts, incomplete
frames and null/unaligned output cannot advance guest PCM or delivered-sample
counters. Supported callbacks retain the existing ring order, partial-underrun
silence and actual-capacity behavior. The format is checked during initialization;
per-callback metadata does not establish encoding stability after a same-device
format change.

The candidate's actual readback helper, initialization function and callback are
extracted unchanged into inert API fixtures. All69 candidate cases pass under
ASAN/UBSAN, while69 baseline cases retain the expected defect reproductions and
valid-path controls. They cover property errors and sizes, sample/packet/frame
format fields, mono/noninterleaved/multiple-buffer layouts, incomplete byte
capacities, null and unaligned data, ring wrap, partial/empty playback, lock/device
failures, generated signal statistics and surrounding buffer canaries. Every
actual compiler and fixture parent exits and is reaped. No CoreAudio device is
opened, no sound is played and no guest recording is retained. Evidence is under
`.lab/manager-iteration-20261016/audio/`; the new patch artifact is
`Backends/Qemu/patches/qemu-coreaudio-format-topology.patch`.

The isolated complete translation unit also passes `clang -fsyntax-only` against
the preserved QEMU build's real generated/source headers and Apple's CoreAudio
headers, with no warnings. The actual compiler parent exits/reaps0. The compiler
produces no object or dependency files, and before/after metadata snapshots show
no source/build tree changes. This checks compilation against the actual API and
QEMU types; it does not rebuild or admit a runtime.

This is an isolated source candidate, with frozen QEMU38 source and runtime bytes
preserved. It has no native QEMU rebuild, signing or live admission yet and does
not establish a cause or repair of the user's listening failure. Audio stays
experimental. The existing realtime error logging and the nonmixing direct-write
path's recursive acquisition of the same default nonrecursive buffer mutex remain
separate fixes. Physical output, channel routing and sustained Windows playback
still require the listening and stability gates above.

The 17 October callback-only candidate layers
`Backends/Qemu/patches/qemu-coreaudio-realtime-lock.patch` on that format/topology
patch. After silencing output, it uses `pthread_mutex_trylock` and returns without
consuming frames or changing counters on contention or error. Its three unlock
sites use the silent pthread primitive directly. Producer/control helpers and
their existing error reporting are unchanged. This removes the callback's
unbounded mutex wait and shared error-logging path in this candidate; contention
deliberately produces a silent buffer and does not prove better audible continuity.
An unlock error does not roll back frames already copied or repair the mutex.

Six inert CPU fixtures pass under ASAN/UBSAN: 36 fault/layout/control cases per
source, real-mutex contention and an 8,192-frame asymmetric stereo conservation
test per source. Eight baseline fault cases and baseline contention reproduce
the expected failure; all candidate cases pass. The contention verdict is checked
only after releasing the producer mutex and joining the callback thread. The
concurrent test covers committed ring frames, not the separate generic reservation/
copy/publication path. Byte canaries use correctly typed float backing storage,
and metadata checks compare fields rather than structure padding.

The complete candidate again passes real-header syntax compilation. All 83 actual
compiler/fixture parents and outer session 46636 have expected exits, both output
EOFs and reap proof, with no signals. The qualified process owner preserves failures
without terminating a child. Exact replay of both tracked patches on a fresh copy
of the frozen source produces candidate SHA256
`91cc657db2a78f7722320000e280abadbdef5dd2664d379ef3b8b59dfde938cf`.
Evidence is `.lab/manager-iteration-20261016/root-audio-rt-conformance-review.json`.
The frozen source/runtime are unchanged; no audio device or VM was opened.

Independent review also identifies nonmixing caller-format conversion as a separate
problem in addition to recursive locking: fixing dispatch alone could interpret
S16 bytes as the forced F32 hardware format. The current app recipe retains mixing,
so neither direct-mode defect establishes its reported listening cause. Stop/
destroy failure ownership and initialization/listener failure cleanup also remain
open. No candidate runtime is admitted and no useful-playback claim is made.


The separate nonmixing admission guard is preserved as
`Backends/Qemu/patches/qemu-coreaudio-nonmixing-admission.patch`, layered after
format/topology and callback locking. It rejects mixing-engine=off at the start
of coreaudio_init_out, before mutex/listener/device/buffer setup. The current
app recipe retains QEMU's normalized mixing-engine=on. The remaining supported
mixing initialization code is byte-identical; this does not repair direct-mode
conversion/recursive locking or teardown failure lifetime.

The before/candidate entry fixtures cover16 cases each under ASAN/UBSAN. Eight
unsupported baseline cases reproduce expected failure43; all candidate cases
and normal/failure-order controls pass. Real-header syntax also passes. All35
actual command parents have expected exit, EOF and reap proof, with outer exec
chunkcfd864 exit/reap0. Independent review agrees. Evidence is
`.lab/manager-iteration-20261016/root-audio-nonmixing-conformance-review.json`.
No device, QEMU, app or VM was started; no listening or runtime-admission claim.
