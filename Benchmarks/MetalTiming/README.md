# Native completion timing component

This original Apache-2.0 component observes numeric completion intervals through
public Metal timestamps. It neither opens a VM nor captures pixels or GPU traces.
See [ADR44](../../docs/adr/0044-native-gpu-timing.md) and the
generated evidence (private development record omitted).

`GpuTimings.hpp` reduces completed, missing, failed and inconsistent timestamp
vectors. Each queue has a serial64-record batch; a shared atomic budget admits
at most32768 records per process. `Report.hpp` formats closed numeric JSON.
`NativeTiming.hpp` uses public Mach time, a1MiB output budget and at most four
records in one512-byte POSIX write. A stop marker explicitly identifies exhausted
output. A process initialization clock is correlation metadata, never authority
for finding or controlling a process. Per-process limits do not bound the
aggregate output of every possible VM worker.

The [incremental dependency patch](../../Backends/Qemu/patches/dxmt-native-gpu-timing-evaluation.patch)
targets the reviewed modified native DXMT source. Its `native_gpu_timing` Meson
option defaults to false and applies only to native builds. It samples after
the existing finish-thread wait and before releasing the command buffer; it
adds no GPU wait or completion handler. The batch initializes before the threads
start and flushes its final partial batch after they join. It does not change
Windows drivers, source ownership, present-token retirement or error recovery.

For CPU checks on an Apple-silicon Mac, compile `Check.cpp` and `NativeCheck.cpp`
separately with C++20, warnings as errors and address/undefined-behaviour
sanitizers. Each needs this directory on its include path. Retain generated
stdout/stderr in a fresh owned test directory. The checks exercise unknown/error
timestamps, extreme values, final partial batches,160000 concurrent admission
attempts and concurrent output pressure. Run two separately owned `NativeCheck`
children with one shared diagnostic pipe; require both actual waits to return0,
every line to parse as closed numeric JSON, two distinct initialization clocks,
one stop marker per child and at most1MiB plus128 marker bytes per child. All
lines must fit512 bytes. Do not substitute a PID lookup for owned-child waits.

For native qualification, build the reviewed DXMT fork with this patch and the
timing option, using its pinned LLVM and compression inputs. Retain source,
configuration, compiler, binary and signature records. Run its159-check native
D3D11 suite with an explicit result path in the owned test directory. Then link
the existing `MetalSurface/DxmtSource.cpp` and `ProducerOrdering.m` against the
frozen library. Require all eight native/4K format cases, every pixel, both event
and fence checks, early event-handle closure and source overwrite to pass.
`Stress.cpp --run`, linked to that same source fixture, exercises256 generated
frames and full timing batches. Without `--run` it skips. These are generated
offscreen workloads, and establish no Windows performance result.

The current raw result retains two declared warmup pairs and ten subsequent
alternating timing-on/off pairs. It retains all trials and samples. The measured
wall scope includes process startup, pixel validation and teardown. GPU execution
spans may include waits and overlapping work; their sum is not utilization.
No confidence interval, physical scanout, game FPS or120Hz claim follows.

The native library is a release build; sanitizers cover the original CPU/output
and source-ordering fixtures. The dependency retains LGPL notices. Combining the
original Apache-2.0 helper with the native library needs license, source and
relinking review before distribution. No release binaries are provided here.
