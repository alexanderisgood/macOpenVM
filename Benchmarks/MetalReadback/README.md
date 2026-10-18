# Generated readback conversion comparison

`Compare.m` exercises the exact before/after Metal readback functions on completed,
immutable generated textures. It never opens a VM, window or user surface and
saves no pixels. Native3456×2168, a nonzero3,5 source origin, four source formats,
full and512×256 copies, independent pixel/row-padding/allocation guards are checked.
Ten paired samples alternate implementation and full/partial order. Each sample
has four warmup copies and20 timed copies. Rendering and GPU fence waits are
outside the CPU getBytes/conversion scope. `Check.c` separately checks139 widths,
32 unaligned offsets, every byte, alpha, tails, guards and the inverse operation.

Use the retained reviewed QEMU28 `ui` source as the baseline and the source with
[the original GPL conversion patch](../../Backends/Qemu/patches/metal-readback-swizzle.patch)
as the candidate. Baseline `mvo-metal-readback.m` SHA256 is
`de9a0af4bf3e586f0a178d08cb52076090f8351a1096e15c1e20656d763ae799`.
The two source directories below must be supplied explicitly. No third-party
binary is downloaded or installed by this procedure.

```sh
MVO_BEFORE=/absolute/path/to/reviewed/baseline/ui
MVO_AFTER=/absolute/path/to/reviewed/candidate/ui
MVO_BUILD=$(mktemp -d /private/tmp/mvo-readback-XXXXXX)
cp "$MVO_AFTER/mvo-metal-damage.h" "$MVO_BUILD/damage.h"
xcrun clang -O2 -Wall -Wextra -Werror -fno-objc-arc \
  -Dmvo_metal_copy=mvo_before_copy -Dmvo_metal_can_read=mvo_before_can_read \
  -Dmvo_metal_retain=mvo_before_retain -Dmvo_metal_release=mvo_before_release \
  -c "$MVO_BEFORE/mvo-metal-readback.m" -o "$MVO_BUILD/before.o"
xcrun clang -O2 -Wall -Wextra -Werror -fno-objc-arc \
  -c "$MVO_AFTER/mvo-metal-readback.m" -o "$MVO_BUILD/after.o"
xcrun clang -O2 -Wall -Wextra -Werror -fno-objc-arc \
  -I "$MVO_AFTER" -I "$MVO_BUILD" -framework Foundation -framework Metal \
  Benchmarks/MetalReadback/Compare.m "$MVO_BUILD/before.o" "$MVO_BUILD/after.o" \
  -o "$MVO_BUILD/compare"
xcrun clang -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$MVO_AFTER" Benchmarks/MetalReadback/Check.c -o "$MVO_BUILD/check-neon"
xcrun clang -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -U__ARM_NEON -I "$MVO_AFTER" Benchmarks/MetalReadback/Check.c -o "$MVO_BUILD/check-scalar"
"$MVO_BUILD/check-neon"
"$MVO_BUILD/check-scalar"
"$MVO_BUILD/compare" --run
```

The [retained measurements](../results/metal-readback-swizzle-c97b508350614861b926cdbf1a4922ce.json)
include the earlier ordered observation and the paired run, without discarded
samples or a confidence interval. The measured object was frozen before adding
the later numeric format diagnostic; its exact source/binary pins and complete
private recipe remain preserved. The row conversion is identical.

The current Windows test workload uses BGRA80, which bypasses RGBA conversion.
These component observations therefore establish no live improvement. Guest FPS,
GPU utilization, physical scanout and120Hz remain distinct acceptance work.
