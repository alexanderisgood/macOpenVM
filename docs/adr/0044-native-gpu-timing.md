# 44. Measure bounded native GPU completion intervals

Status: qualified generated component and one bounded live trial; disabled afterward.

At preparation, App46 kept the tested QEMU28 runtime and input fix. Native delivery measures
52–53 AppKit callbacks/s while the signed Windows driver reports60Hz. The
maintainer's120Hz target, Start-menu spikes and physical presentation remain open.
The next diagnostic separates native Metal command-buffer execution intervals
from queue scheduling and the already measured display-copy/draw costs.

Use public [gpuStartTime](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime)
and [gpuEndTime](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpuendtime)
after actual completion. Apple's timestamps are unavailable until GPU completion.
The existing DXMT finish thread already waits for that boundary, so the probe
must use it rather than introduce a new synchronization wait. Submit timestamps
use the same public Mach clock domain. Missing, failed and inconsistent timing
records remain explicit; they never become zero-cost success samples.

The original numeric reducer retains64 raw records per batch with a process-wide
32768-record budget. Each serial queue has its own batch. Output splits a batch
into at most four records per atomic512-byte write, preserving concurrent worker
reports. Each process also has a1MiB numeric output budget and emits an explicit
stop marker when exhausted. These are per-process limits; combined VM logging
and live overhead still require qualification. Queued reports contain
only numeric identifiers, intervals and validity flags. They include no Metal
resource, label, pixel, process name, path or credential. No GPU trace or screen
file is produced. Execution spans can include GPU waits and overlapping work;
their sum is not hardware utilization, physical scanout or game FPS.

Add a default-off native build option in a separate source copy. Preserve the
working library, renderer, runtime and guest. Before any live trial, qualify the
reducer's concurrent budget, null/error/order/extreme values and final partial
batch; compile the actual native library; run existing D3D11 correctness/fence
checks; pin its source, binary, system imports and signing provenance; admit the
separately frozen renderer/runtime loader paths. No environment override or
foreign-process injection is permitted. Profiling overhead needs its own check.

The helper is original Apache-2.0 code. The dependency patch retains DXMT's LGPL
notices. Source, relinking, combined-license compatibility and distribution
obligations require review before redistribution; this local experiment does
not resolve them. Keep the tested runtime selected until a candidate has a
concrete, measurable result and unchanged ownership/input/lifecycle behavior.

The generated checks and raw observations (private development record omitted)
now pass. Both timing variants pass159 existing D3D11 checks; eight native/4K
format cases pass pixel, event/fence and source-overwrite checks. Two owned CPU
processes sharing a pipe produce only closed numeric records within their budgets.
The separately frozen renderer and a copy of QEMU28 pass generated display
conformance, normal QMP quit and actual reap. All16 file-backed QEMU code/data
sections remain identical; only its renderer load command and signature change.
Source47 is fully packaged as a separate trial build. The production read-only
GPU catalog verifier passes every actual binary/hash/import/signature using a
synthetic configuration and preserves creation provenance without minting a
writer. Its opt-in test is `QemuGpuCatalogNativeTests`;19 registered-resource
tests also pass. The subsequent live App47 trial retains8448 numeric completion
records with no malformed lines/stop markers, below the owned2MiB stderr limit.
Broad trial brackets separate Start/shader observations; they are not hardware
utilization or critical-path attribution. Normal guest shutdown, native Quit and
actual launcher reap precede App48, which restores the original timing-disabled
runtime/library and improves bounded receive handling. Fullscreen/menu and
first-shortcut checks pass narrowly; physical cursor,120Hz and a clear live FPS
improvement remain unqualified. See the updated evidence above.
