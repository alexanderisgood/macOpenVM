# 61. Keep scaling in native backing pixels

Status: implemented in the development branch, with component and native Metal
checks. Installed adoption and live no-FPS-regression acceptance remain pending.
Sharpening is off by default. This work does not enable Windows HDR.

## Scaling inspection

The inspected shared-display route has one resampling pass: a source-sized
shared-to-private Metal blit followed by a nearest-sampled draw into the actual
backing-sized drawable. The producer readback and shared-frame copy preserve
source dimensions. The current KMD also rejects stretched VidPN paths. No
steady-state double scaling was found in these stages. This does not exclude
scaling inside Windows, DWM or an individual game's rendering settings.

Fractional enlargement necessarily gives some source pixels different physical
widths. A lower-resolution raster also contains less detail. Sharpening cannot
recover missing detail, and Windows' text/UI scale is a separate setting.

## Shared geometry

`GuestViewport` adds an opt-in integer mode using the view's actual backing
bounds. It selects the largest whole-pixel multiple that fits, centers it on
backing pixels and letterboxes the remainder. If a 1x image cannot fit, ordinary
fit keeps the entire guest visible. The original default-fit initializer remains
the early path, without extra AppKit backing conversions.

Drawing, pointer/button/wheel mapping, cursor rectangles and relative mouse
centering use this same geometry. Changing presentation cancels the active
measurement, releases held input/capture and restores host pointer association
before changing the mapping. These settings affect host presentation only; they
do not change guest resolution, configuration, disk, EFI or TPM state.

The renderer also rejects an asynchronously acquired drawable whose dimensions
belong to the previous resize. It keeps the latest frame pending and uses the
existing bounded retry policy. Desired layer and renderer dimensions use the
same rounded-up backing size. Tests exercise growth, shrinkage, black borders
and viewport-only coalescing. This fixes a real transient cropping/stretching
race; it is not proof that the race caused every blurry lower-resolution image.

## Optional sharpening

The unchanged original `opaque` shader remains the default. The optional shader
uses a light five-tap source-pixel unsharp filter, constrained to the local
sample range. It applies only when both displayed dimensions exceed the source;
native and reduced-size images use the original shader.

The optional shader library and pipeline compile on a separate queue only after
enabling the option. The original renderer remains usable until compilation
succeeds, and an optional failure preserves the original draw path. Baseline
pipeline/command-queue initialization publishes atomically. Late sharpening
activation cancels a timing capture that began during compilation; a sample
cannot silently mix fallback and sharpening. Compilation is excluded from the
warmed component benchmark and remains an enabled-path qualification item.

## Qualification and limits

The [reproducible fixtures](../../Benchmarks/DisplayScaling/README.md) extract
the exact separate production shader libraries and historical baseline source.
Eight generated-image cases byte-match the original default GPU output and
check integer/native pixels, orientation, alpha, black borders, constant fields,
native bypass and bounded sharpening. Six counterbalanced pairs per geometry
retain raw timing blocks; producer transport, AppKit acquisition, guest work and
physical scanout are excluded.

The 18 October Apple M5 Pro run at 3456 x 2168 output measured approximately
34–50 microseconds of additional median GPU work in the enlarged sharpening
cases. Mean paired p95 differences were approximately 32–83 microseconds.
Same-shader controls vary within the experiment. The CPU default geometry/map
fixture measured block medians of 23.71 ns before and 24.76 ns after, with equal
geometry checksums across eight cases. This component cost is not an FPS result.

Full Swift checks, strict formatting, generated protocol and SBOM consistency,
native generated Metal regressions and a signed staged release build are the
development checks. Repeated live workload comparisons still need fixed scene,
source/backing dimensions, refresh, visibility and thermal conditions, retaining
positive presentation timestamps and gap tails. The control tool currently
reads the existing VM but cannot deliver guest clicks or verified keyboard input.
A static desktop is not a live FPS test. Accordingly these changes are not yet
installed over the working app and sharpening is not accepted as FPS-neutral.

HDR has a separate precision/color/driver contract. Its current investigation
and remaining implementation gates are in the
HDR evidence report (private development record omitted).
