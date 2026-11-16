# 62. Size Windows defaults and import display buffers directly

Status: implemented with generated native Metal and allocation regression checks.
Live Windows performance and physical M-series coverage remain unqualified.

Windows creation in the app and CLI now derives a starting allocation from the
host: half the active CPU count, capped at eight vCPUs, and half physical memory
in whole GiB, capped at 16 GiB. The existing Windows minimum and host admission
rules still apply. Explicit edits override the recommendation. The hardware
editor offers the same recommendation without saving or changing a running VM.
This replaces fixed two-vCPU/four-GiB defaults; it is a starting point for
measurement, not a claim that more assigned resources always improve performance.

The shared display consumer now keeps two imported Metal buffers instead of
linear texture views. It blits the producer's padded BGRA rows directly into
the private display cache. This removes an intermediate view and the linear
texture alignment requirement. Validated protocol geometry, read-only mappings,
mapping lifetime, GPU-completion acknowledgement and asynchronous drawable
acquisition remain required. The copy and final presentation pass still exist.

Acceptance covers capacity-dependent defaults, explicit overrides, insufficient
hosts, padded rows, 1080p/native/4K pixels and repeated reuse of both producer
slots. The [copy fixture](../../Benchmarks/SharedFrameCopy/README.md) alternates
baseline and candidate blocks and verifies readback. Measurements are mixed and
do not establish an end-to-end FPS improvement. Neither change lowers the pinned
Windows runtime's macOS 27 requirement or establishes support on an untested Mac.
