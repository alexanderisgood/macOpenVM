# Explicit native baseline

This measures the offline Alpine live console experiment, not installed-OS,
desktop or authenticated-agent readiness. Follow the media preparation and CLI
fixture instructions in Tests/Integration/README.md. Only the pinned official
ISO, prepared raw ARM64 kernel and initrd are accepted. No download is implicit.

Run `./scripts/build.sh release` (or debug), then
`python3 Benchmarks/native_boot.py --run --trials 5` with the disposable offline
Alpine-native fixture stopped. Without explicit consent, native support, current
development signing/build provenance or pinned media, no guest is started. Run
`python3 scripts/build_manifest.py verify` to check packaging independently.

Each invocation creates a unique private .lab/native-benchmark session. Structured
reports use a new exclusive UTC/UUID filename in Benchmarks/results. Historical
reports and all trial logs are preserved; an existing destination is rejected.
Each trial records its process handle immediately. Console buffers are bounded,
failure phase/partial samples stay private, and an active guest is retained for
console recovery through that same session. Observe its shell before commands;
do not restart or force-stop on timeout. Failures are never completed measurements.

The report uses the actual packaged build profile, source/recipe and runner hashes,
Swift/SDK metadata, build-record/harness hashes, pinned media hashes and actual
guest kernel. The local build record is advisory, not a signed release attestation.
Do not rebuild or edit production inputs during a run. Cache/background load and
several hardware fields remain uncontrolled/unknown with explicit reasons. Retain
all trials; debug/release and unlike source scopes are not regression comparisons.

## Host process monitor

[ProcessMonitorBenchmark](ProcessMonitor/main.swift) is a separate host-only target
with two system sleep children and no guest. Its exact arguments are --label
(before-polling or after-exit-event), --source (absolute immutable helper copy),
--expected-source-sha256, --output (new absolute exclusive report path), and --seconds
(2–15). The published feasibility slice used three sequential five-second trials
per revision, an unchanged harness/package and preserved debug binaries; see
event-monitor evidence (private development record omitted).

RUSAGE_SELF covers parent launch, monitoring and child exit/reaping, excluding child
CPU and report creation. The source is hashed before and after each trial, and the
executed binary hash is recorded. Preserve source/binary copies and every raw
record; do not rebuild or edit inputs during a run. A comparison also needs an
independent source-to-binary provenance record; passing a source path alone does
not prove which code was built into a binary.

Use a separately owned external per-trial budget; the recorded slice used 15
seconds. The executable has no internal unresolved-wait watchdog, and its failure
cleanup also awaits actual child status. If it remains pending, retain that same
process/child ownership and private evidence; an external timeout is not a
completed measurement or permission to start replacement trials. The n=3,
uncontrolled-load observations make no guest, energy, wakeup, confidence-interval,
regression or parity claim.

## Raw display decoder component

`python3 Benchmarks/build_rfb_decode.py --build` builds only the release
`RfbDecodeBenchmark` product and retains a unique immutable binary, source copies,
compiler/SDK metadata and build record. It does not execute the benchmark. Native
tool access may be needed by the compiler's debug-symbol step.

Run `python3 Benchmarks/rfb_decode.py --run --artifact ABS_ARTIFACT --label baseline`
for an unchanged decoder, or `--label row-segments` for the reviewed candidate.
The artifact must match current production and benchmark sources. Five samples
per fixed workload are retained; generated frame hashes are independently checked.
The runner records current host facts and writes a unique schema-validated result
under `Benchmarks/results`, with raw child output retained privately in `.lab`.

Workloads cover initial full, steady full and 48×32 dirty updates at 1280×720,
2560×1440 and 3840×2160. Decode feeds/draining and Data snapshots are timed
separately. Generated wire construction, handshake, pixel validation and hashing
are outside the measured intervals. Previous frames are retained to test snapshot
independence. Fragment sizes are fixed and never exceed 64 KiB.

Preserve both binaries/results before changing sources, and use the same benchmark,
runner, release profile and fixtures for a comparison. No VM, transport, guest
pixels, rendering or display scanout is involved. Cache, thermal/power conditions
and interactive host load are uncontrolled; these timings are not UI frame pacing,
input latency, GPU acceleration, Retina application or virtualization parity.

## Windows browser graphics workload

Open the original `examples/windows-gpu-check.html` in the test guest. Maximize or
resize the browser to the intended workload size; the v2 test restarts on geometry,
DPI and visibility changes and states its drawing-buffer and CSS viewport sizes.
Run both modes separately: queued drawing, and the original synchronous GPU-wait
workload. A two-second warm-up precedes twenty measured seconds. Record the
renderer, geometry, workload identifier and frame-time percentiles. Do not compare
unlike dimensions or modes, or treat browser FPS as delivery to the Mac screen.

The bounded in-memory `window.macOpenVMGpuResult` contains numeric intervals and
declared benchmark metadata only; the page writes no guest file or network data.
Context loss invalidates even a completed result. Run the deterministic control
checks with `node Benchmarks/test_windows_gpu_check.cjs`. Node.js is required for
these checks; their fake WebGL/browser fixture makes no hardware claim.
