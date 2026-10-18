# 41. Measure generated frames through the native display client and renderer

Status: experimental qualification prerequisite.

The raw decoder component improved on generated-frame workloads, but that does
not measure Unix transport, the main-actor handoff, SwiftUI updates or AppKit
drawing. Exercise those layers next with original public test frames rather than
reading a guest or account screen.

A separately gated private app mode connects the production RFBClient to one
fresh owned Unix socket. The fixture is an original RFB3.8/None server with Raw
and DesktopSize only; it supplies no VM worker, ownership or authentication facts.
Generate six full frames at each of 800×600, 1920×1080 and 3840×2160, with exact
opaque color markers for all eighteen frames. Pace responses at least100ms apart
and verify actual full-frame requests after size changes.

The app must validate actual received bytes/epoch/sequence/geometry and present
them through the existing RfbGuestView. Observe natural SDK draw callbacks, their
view/window attachment and visibility, receive-to-draw delay and draw intervals.
Record received, drawn and coalesced sequences separately. Do not force a draw
inside the measured path, fabricate a callback or count duplicate repaints as
new frames. Actual viewport points and backing scale remain distinct from the
generated framebuffer pixels.

Request, receive, publication and draw timestamps use one app-local monotonic
clock. Validate complete generated pixels on a utility task before publication;
publication-to-draw excludes that qualification overhead. Request-to-receive
includes fixture pacing/transport/decoding and is not pure network latency.
Server timestamps use a separate clock and are never subtracted from app times.
The first run uses the isolated development app's debug profile, so it cannot
be compared directly with the preceding release decoder microbenchmark.

This measures SDK draw observations, not physical display scanout, compositor
latency, monitor refresh, guest rendering, mouse-to-pixel response or Retina mode
application. A visible flag alone does not prove what the user saw. Any later
visual/pixel verification must be limited to this generated public surface and
kept outside timing. No existing app, VM, network interface, media, credentials or
account pixels are involved.

Acceptance: closed request/result schemas and geometry/sequence tests; strict
app build with exact provenance; original fixture protocol tests; actual retained
app/server execution with client close, result persistence and real app exit;
report all timings and omitted/coalesced draws without a universal frame-rate
claim. Timeouts retain the exact live parent rather than kill or restart it.
