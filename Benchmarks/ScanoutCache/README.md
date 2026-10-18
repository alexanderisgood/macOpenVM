# Resource-owned Metal scanout imports

These fixtures exercise the renderer modified by
[the incremental MIT patch](../../Backends/Qemu/patches/renderer-shm-scanout-cache.patch).
Apply it to the paired protocol2 renderer source, retaining its existing notices
and native loader configuration. The change does not require a guest driver update.

`scanout_cache_test.c` includes the actual patched production header. It checks
19 ownership, key, invalidation, eviction, size-budget and failure cases using
counted objects. Compile with the patched renderer's `src` directory:

```sh
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror \
  -fsanitize=address,undefined -I "$RENDERER_SOURCE/src" \
  Benchmarks/ScanoutCache/scanout_cache_test.c -o "$OUTPUT/cache-test"
ASAN_OPTIONS=detect_leaks=0 "$OUTPUT/cache-test"
```

`MetalProductionCacheIntegration.m` uses the actual renderer's public SHM resource
table and hardware ANGLE Metal device. Its 11 cases perform 38 completed GPU
readbacks, checking mutation through aliases, two/three-buffer reuse, eviction,
numeric resource-ID reuse, FD close, unref, reset and cleanup. Caller handles
remain independently owned. Compare stdout exactly with `expected-stdout.txt`.

`MetalNativeImportCostBenchmark.m` measures only warm public acquire/release calls
over three independent native 3456×2168 BGRA resources. It uses 12 warm calls,
1,200 measured calls and nine GPU readbacks outside timing. Link the same object
against the old and new libraries and alternate process order. Keep three live
anchors so pointer recycling cannot masquerade as reuse. Check the reported three
page-rounded mapping charges fit within 96 MiB before interpreting cache hits.

For either Objective-C fixture, use reviewed, matching renderer and ANGLE headers,
the generated renderer headers, and the actual paired EGL library:

```sh
xcrun clang -arch arm64 -O2 -std=c11 -Wall -Wextra -Werror \
  -DVIRGL_RENDERER_UNSTABLE_APIS -fno-objc-arc -fblocks \
  -I "$RENDERER_SOURCE/src" -I "$RENDERER_BUILD/src" -I "$ANGLE_INCLUDE" \
  -c Benchmarks/ScanoutCache/MetalProductionCacheIntegration.m -o "$OUTPUT/fixture.o"
xcrun clang "$OUTPUT/fixture.o" "$RENDERER_LIBRARY" "$GRAPHICS_LIB/libEGL.dylib" \
  -framework Foundation -framework Metal -lobjc -Wl,-rpath,"$GRAPHICS_LIB" \
  -o "$OUTPUT/fixture"
(cd "$GRAPHICS_LIB" && "$OUTPUT/fixture" "$RUN_OUTPUT")
```

All supplied paths must be absolute. `RUN_OUTPUT` must be fresh, user-owned and
mode 0700; each fixture creates and removes its own bounded scratch child there.
The EGL rpath is necessary for its install ID. The working directory separately
resolves ANGLE's existing lazy GLES framework request. Review the actual signed
renderer and provider closure before running; no dependency is downloaded here.
The native fixtures neither start nor open a VM, guest context or display window.

The [recorded comparison](results/native-import-cost-20261018.json) has six
counterbalanced process pairs and full pixel checks. Warm 1,200-call loop medians
were 14.911 ms before and 0.018625 ms after. Individual cached-call timestamps
approach the clock's 41.667 ns granularity; zero medians do not mean zero cost.
The first result reader used an incorrect field name after a successful old run;
the reader was corrected and that original successful sample was retained.

These timings exclude setup, rendering, GPU readback and autorelease-pool drain.
They measure view-import call cost, not total object lifetime, guest FPS, input
latency or physical scanout. The resource cache removes no pixel copy and changes
no producer completion rule. Six process pairs are the replicates; the 1,200
within-process calls are not independent trials. Host load and builds were not
controlled, and no confidence interval or whole-app speedup is claimed.
