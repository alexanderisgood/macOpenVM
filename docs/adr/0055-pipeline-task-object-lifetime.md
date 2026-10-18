# 55. Release temporary Metal objects after each pipeline compilation task

Status: native lifetime probe/build/signature/interface checks pass; candidate
not installed and Windows qualification pending.

The D3D11 pipeline-cache task adapter calls `RunThreadpoolWork()` on persistent
scheduler threads without an autorelease pool. Shader compilation already has a
local pool, but graphics, geometry and tessellation pipeline compilation also run
through this adapter and call Metal pipeline creation and error-description APIs
without equivalent coverage. A pool on the command encoding or completion thread
cannot release temporary objects created on a different compilation thread.

Create the existing `WMT::MakeAutoreleasePool()` RAII object in the D3D11 task
adapter before invoking each work item. Drain it as the adapter returns, including
when a work item returns a shader dependency for rescheduling. The scheduler
publishes completion after the adapter returns. Preserve the work item's returned
pointer, its strongly held pipeline/function references, task dependencies,
compilation concurrency, guest fences and resource-retirement order. Include the
pool declaration explicitly in the adapter's translation unit.

This follows Apple's [secondary-thread autorelease-pool guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html).
It provides a bounded lifetime for temporary objects; existing renderer memory
totals do not prove how much is reclaimable or establish a cause of CS2 hitches.
Do not claim an FPS, memory or120Hz improvement from the source change alone.

Before admission, preserve the current signed renderer and record the incremental
LGPL patch and complete source inventory. Qualify the actual task adapter with
native generated autoreleased objects and normal/dependency returns; verify the
native renderer build, signatures, exported ABI and dependency closure. Keep the
current installed App71/QEMU38 immutable until stopped admission and app build
provenance pass. The live comparison must use Windows/CS2 at the actual native
viewport, recording frame gaps and renderer memory in separate, coordinated runs.
Normal shutdown, runtime settlement, native Quit and actual parent reap remain
required. The current signed Windows driver still exposes60Hz; this lifetime
change does not add a120Hz guest mode.

The extracted actual task adapter and actual WMT reference/pool header run on a
native secondary thread with Foundation retain/release/pool bridging. Across128
generated normal/dependency returns, the old adapter defers128 temporary objects
until its outer thread pool drains (exit43); the candidate leaves0 deferred after
each task (exit0). Both preserve a strongly retained result until its work object
ends, pointer returns and done-state forwarding. ASAN/UBSAN report no error.
This fixture does not execute a real Metal pipeline or the renderer's complete
bridge; those remain native-build/live integration gates.

The actual incremental renderer build takes1.82s; signing and strict verification
pass. All16 exported names and library imports match the prior renderer. The
active installed library remains unchanged and its prior bytes are preserved.
The build retains existing duplicate-library and zstd macOS-floor linker warnings;
this is not a warning-free or macOS14-qualified release. No live memory/FPS gain
is inferred. Complete source inventory, candidate hash and actual parent reaps
are recorded in the private trial; source adoption awaits the coordinated app
build and Windows run.

The candidate additionally passes the existing159 generated native D3D11 checks
using its actual library, with hardware Metal operations offscreen. Build/check
parents exit/reap0; installed renderer bytes stay unchanged. This qualifies those
pipeline/resource behaviors after the pool drains, including retained results;
it remains a component result, not Windows/CS2 frame pacing or leak measurement.
