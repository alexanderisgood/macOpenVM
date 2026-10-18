# 60. Reuse resource-owned Metal scanout views

Status: implemented and installed after clean guest shutdown. Native component,
actual Metal integration, full Swift checks, signed release build and package
review passed. The existing VM booted and signed into its desktop; the running
QEMU process loaded the new renderer. Game FPS remains unverified. This is one
bounded improvement to the existing graphics path.

The renderer already imports cross-process scanouts as Metal buffers and linear
textures aliasing shared pages. Recreating a view repeats mapping and object work
even when the resource storage and layout are unchanged. Retain one view per
resource in a shared three-entry LRU pool, with a 96 MiB page-rounded whole-map
charge limit. This bounds cache ownership, not resident memory or caller handles.

The key covers winsys, resource-owned FD, map size, width, height, stride, offset
and effective exporter format. A hit returns a separately retained caller handle.
Pixel changes remain visible through the alias. Layout changes reimport. Failed
imports preserve the old entry without returning a stale incompatible handle;
oversized successful imports are returned uncached. Resource destruction clears
the entry before closing the FD. Reset and cleanup use that destructor.

All acquire/remove/reset/cleanup operations remain serialized by the current QEMU
frontend. The cache adds neither a thread nor a lock. Independent Metal handles
protect their mappings, not the cache structure. Existing producer readiness,
fences and readback ordering remain required and unchanged. GPU rendering,
readback, frame copies, upload and presentation remain outside this optimisation.

The incremental patch preserves existing MIT notices and adds MIT helper/tests.
The new renderer retains all 51 public exports and the unchanged public header.
Guest driver, wire protocol2, backend ABI1 and DXMT are unchanged. A fresh build
keeps the original verified render-server path through an absolute `libexecdir`;
no install target writes into that existing directory. Two separately retained
QEMU executable copies change only the renderer load request and signature,
preserving their executable sections and Hypervisor-only entitlements.

The [fixtures](../../Benchmarks/ScanoutCache/README.md) cover 19 sanitizer component
cases and 11 public-resource-table cases with 38 real GPU reads. Six alternating
old/new process pairs additionally check three native buffers with nine GPU reads
each. Their 1,200-call warm-loop medians change from 14.911 to 0.018625 ms. This
establishes import reuse and reduced warm call cost; it establishes no game-FPS,
120 FPS, zero-copy, total-lifetime or producer-fence result. Both old and new
libraries remain available for rollback.
