# Display scaling component fixtures

These generated-pixel fixtures measure the final Metal scaling component and the
default CPU viewport component. They do not open a window, connect a display,
read guest pixels, launch a VM, change a guest mode, or install an application.
They do not measure live game FPS or physical scanout.

The production default is ordinary fit with sharpening off. Its original
`plane`/`opaque` Metal source remains separate from the optional
`plane`/`lightSharp` source. `extract_shaders.py` copies those literals exactly,
without combining libraries or rewriting shader bodies. A supplied historical
renderer source must contain the same default shader literal, byte for byte
after removing Swift multiline indentation.

## Exact-source Metal fixture

Use a fresh absolute output directory and retain source, toolchain, executable,
arguments and process-exit identities. From the repository root, the preparation
and compilation steps are:

```sh
OUTPUT="/absolute/path/to/fresh-display-scaling-run"
mkdir -m 700 "$OUTPUT"
git show 9262cff:App/SharedFrameMetalRenderer.swift > "$OUTPUT/original-renderer.swift"
python3 Benchmarks/DisplayScaling/extract_shaders.py \
  App/SharedFrameMetalRenderer.swift "$OUTPUT/original-renderer.swift" \
  "$OUTPUT/shaders" > "$OUTPUT/shader-receipt.json"
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
  -framework Foundation -framework Metal \
  Benchmarks/DisplayScaling/RendererScalingBenchmark.m \
  -o "$OUTPUT/renderer-scaling-benchmark"
```

Run the executable with three absolute arguments, in this order:

```text
renderer-scaling-benchmark shaders/baseline.metal shaders/sharpening.metal shaders/original.metal
```

Resolve those example paths against `OUTPUT`. Use the established finite process
owner when running native fixtures. Retain stdout, stderr, actual exit status,
deadline and normal child completion/reaping evidence. The executable checks an
internal 180-second deadline before each submission and waits at most five
seconds per GPU completion. An outer 210-second deadline leaves collection
margin. A failed pixel assertion, missing timestamp, timeout or nonzero exit
invalidates the result; partial output is not a performance pass.

Native stdout contains roughly 2 MiB of raw timing arrays. Save it directly to a
file rather than displaying it. Produce the smaller report separately:

```sh
python3 Benchmarks/DisplayScaling/summarize.py "$OUTPUT/native.stdout" \
  > "$OUTPUT/summary.json"
```

The summary validates all eight image cases, 96 complete blocks, AB/BA order,
coverage, effective shader selection, raw-sample percentiles, finite work counts,
and unsupported FPS claims before calculating paired differences. Add
`--detailed` for per-pair values, p99 and CPU encoding results. Keep raw evidence
for tail analysis instead of treating the smaller summary as a replacement.

The fixed target is 3456 × 2168. Source sizes are 3456 × 2168, 2560 × 1600,
1920 × 1080 and 1728 × 1084, each with aspect fit and integer fit. Every variant
receives 120 initial warm commands; six pairs alternate A/B and B/A; each block
has 12 switch warm commands and 300 measured commands. A is current `opaque`.
B selects `lightSharp` only when both viewport dimensions exceed the source,
matching production's native/downscale bypass. Each pair uses identical geometry.
Native and integer1× cases therefore use `opaque` in both arms and quantify
repeatability. Do not pool fit and integer timings: their covered pixel counts
can differ substantially.

Each measured command contains the same-size shared-source to private-cache
blit and one clear/store final draw into a private target. The shaders come from
the exact production libraries. GPU start/end, CPU encoding and
submit-to-completion-callback times are retained separately. Pipeline compilation,
texture allocation, image readback and result formatting are excluded from
measured intervals.

This fixture combines blit and draw into one command buffer with one in flight.
Production independently acknowledges cache copies and acquires/presents
drawables. The fixture does not reproduce that scheduling, transport, display
synchronization, the compositor, thermal competition with a game, or production's
asynchronous first-use sharpening compilation. It cannot establish an application
startup improvement, end-to-end latency or no live FPS regression.

## Rendered default and pixel oracles

Before timing, the fixture compiles the historical default shader in its own
library. For every geometry, its generated output must byte-match the current
default output across the entire target. `extract_shaders.py` separately requires
the default shader text to match. This establishes unchanged shader work and
rendered default pixels in the fixture. It does not count the real Swift
renderer’s encoders, backing conversions, command buffers or queue operations.

Separate untimed readbacks check exact native/integer nearest mapping,
orientation, forced alpha, black letterboxing, native sharpening bypass,
constant-field invariance and bounded five-tap sharpening values. A nonuniform
upscaled image must actually change. Fractional-fit source-boundary rounding
does not serve as a byte-exact CPU texel oracle; the historical/current GPU
default outputs still must match each other there.

## Portable default geometry hotpath

The CPU fixture stages the exact historical and current `GuestViewport.swift`
in separate modules inside a fresh, dependency-free Swift package. Only the
`CoreGraphics` import is conditionalized for non-Apple Swift hosts; Foundation
supplies `CGRect`. Function bodies are not rewritten. Minimal `PixelSize` and
`VMError` fixture types support successful geometry calls; error-path cost is
outside this experiment. The generated package declares macOS14, matching the
application minimum and the `ContinuousClock`/`Duration` timing API availability.

```sh
git show 9262cff:Core/GuestViewport.swift > "$OUTPUT/original-viewport.swift"
python3 Benchmarks/DisplayScaling/prepare_geometry.py \
  "$OUTPUT/original-viewport.swift" Core/GuestViewport.swift \
  "$OUTPUT/geometry-package" > "$OUTPUT/geometry-receipt.json"
swift build --package-path "$OUTPUT/geometry-package" -c release \
  --product GeometryHotpath
```

Run the generated release executable through the same finite process owner,
with an outer deadline longer than its internal 45-second budget. No GPU is used.
Retain the actual Swift version, platform and release flags. The fixture compares
the original and new default-fit initializers plus point mapping over eight
native, fractional and letterboxed cases. It warms 20,000 iterations per arm and
measures eight counterbalanced pairs of 200,000 calls per block. Checksum equality
guards observable geometry/map results. Cross-module calls and `@inline(never)`
loop boundaries keep the measured work observable.

The output reports per-block mean nanoseconds per call and paired ratios.
Iterations within a block are not independent replicates. This fixture excludes
AppKit's backing conversion and the native view's branch selection; production
must preserve the `.fit` early return and its own tests. Do not translate a small
CPU difference into an FPS claim. Cross-platform results characterize only that
host/compiler, and a platform without a compatible Swift Foundation CGRect
implementation cannot run this optional fixture.

## Interpretation and live acceptance

Compare paired block distributions, including p95/p99 and 8.333/16.667 ms budget
misses. The six pairs are the replicates; 300 commands within a block are not
independent trials. Bootstrap intervals describe this component experiment and
its noise. A lower median with a worse tail is not an unconditional improvement.

The earlier development experiment on 2026-10-18 found nonzero sharpening cost:
roughly 37–50 µs mean paired median GPU overhead and 53–79 µs mean paired p95
overhead in its upscaled cases. That earlier one-library fixture did not include
the historical-default oracle added here. Its result cannot be relabeled as a
run of these promoted sources. It also did not qualify live game FPS.

For a strict no-FPS-regression decision, separately collect repeated,
counterbalanced steady-state live samples with fixed guest mode/scene, backing
size, viewport, scaling choice, sharpening choice, screen refresh, visibility,
power and thermal conditions. Use unique producer sequences, positive Metal
presentation timestamps, presentation-gap tails, coalesced frames and budget
misses. Record sample metadata and invalidate on settings or geometry changes.
If live testing is unavailable or inconclusive, the no-regression condition
remains unproved. An optional feature being off by default does not qualify its
enabled path.

The portable tool tests never compile or run Metal, Swift or a VM:

```sh
python3 -m unittest discover -s Benchmarks/DisplayScaling -p 'test_*.py'
```
