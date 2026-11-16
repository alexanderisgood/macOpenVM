# 66. Smooth fractional display scaling and offer a native startup size

Status: implementation and qualification in progress.

## Problem and decision

The 16 November guest rendered 3840 × 2160 into a 3456 × 2168 fullscreen
viewport. Aspect fit correctly preserved the desktop, but produced black bars;
nearest-neighbour fractional reduction also discarded text-edge samples.
This is separate from Windows text scaling or game antialiasing.

Use one hardware bilinear sample for fractional host scaling. Keep the existing
nearest sampler for aligned native pixels and equal whole-number enlargement.
Keep the optional sharpening path separate. No extra image copy, render pass,
CPU filtering, guest driver or security-setting change is introduced.

Offer a stopped graphics-settings button to copy the current Mac screen's
backing-pixel size, excluding the greater of the camera safe area and main menu
height, into the existing startup-size draft. The native menu remains reachable.
Saving still uses the existing bounds, stopped-owner admission and
explicit refresh choice. This avoids hand-entering dimensions for fullscreen.

Live resize remains experimental. The current signed graphics driver restarted
Windows during a fullscreen mode change: event 1001 reported bugcheck 0x119,
subtype 1 (invalid fence ID), after a window-sized request had succeeded.
Do not enable automatic live resize or suppress Windows GPU recovery to hide it.
Use the startup-size setting for the native-resolution test.

## Acceptance

- Generated Metal pixels must retain exact native/whole-number mapping, opaque
  alpha, orientation and black borders; fractional reduction/enlargement must
  blend adjacent source samples with bounded values.
- Existing drawable geometry, cancellation and late-sharpening tests pass.
- A native-size preset must reject invalid/over-budget screen sizes without
  changing a draft, and preserve the selected refresh rate.
- Native adoption must report the actual guest size, fullscreen viewport and
  driver health. A successful startup is not a dynamic-resize stability claim.
- Record component timing separately from live frame delivery. No native-speed
  or game-FPS claim follows from a display mode or a static desktop.

Microsoft's [0x119 reference](https://learn.microsoft.com/windows-hardware/drivers/debugger/bug-check-0x119---video-scheduler-internal-error)
defines subtype 1. A dump-level cause and signed-driver fix remain outstanding.
