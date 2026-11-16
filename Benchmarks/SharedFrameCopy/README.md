# Shared display copy comparison

This generated-pixel Metal microbenchmark compares the former linear-texture
blit (`variant=0`) with the direct buffer-to-texture blit (`variant=1`). It does
not require Windows, a VM, drivers, or installation media.

Run on a Mac with Metal and the Apple command-line tools, from the repository
root. Reuse the output directory; do not retain duplicate build trees:

```sh
mkdir -p .lab/shared-frame-copy
xcrun clang -O2 -fobjc-arc -framework Foundation -framework Metal \
  Benchmarks/SharedFrameCopy/main.m -o .lab/shared-frame-copy/benchmark
.lab/shared-frame-copy/benchmark > .lab/shared-frame-copy/results.csv
```

The process must have native GPU access. The fixture uses padded BGRA rows at
321 × 241, 1920 × 1080, 2560 × 1600, 3456 × 2168 and 3840 × 2160. Six blocks
alternate which variant runs first. Each variant discards four warmups per
block and records 40 GPU command-buffer durations, for 240 samples per variant
per geometry. Every block verifies all visible pixels by reading the private
cache back to CPU memory. Any allocation, GPU, timestamp or pixel failure exits
nonzero; disregard incomplete CSV output.

Report the host, OS, build command and all geometries, including mixed results.
These durations isolate GPU copies of generated pixels. They exclude guest
rendering, shared-memory transport, frame pacing and display presentation, and
cannot establish a Windows FPS or end-to-end latency improvement. Actual
renderer ownership, read-only mappings and repeated slot reuse are covered by
`SharedFrameClientTests`.
