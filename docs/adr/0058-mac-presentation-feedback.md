# 58. Measure Metal presentation separately from GPU completion

Status: implemented; numeric tests, signed releases and bounded Windows
presentation pass. App78 measures 107.8 Mac presentations/s windowed and 105.8/s
at the native 3456 × 2168 fullscreen viewport. A separate off-Space diagnostic
returns only zero timestamps despite key/active flags; App79 excludes that state.
120 FPS, gaming and physical scanout remain unqualified. Final App79 live testing
awaits manual macOS unlock. See [ADR59](0059-presentation-visibility-reconciliation.md).

The existing 20-second display sample counts incoming shared frames and GPU
command completion. A completed copy/render command does not establish that
its drawable appeared on the Mac display. Preserve these existing metrics and
add a separate observation using Metal's public drawable presentation callback
and `presentedTime`, which the SDK defines as zero for a skipped or unpresented
frame. Keep callbacks disabled outside an explicitly started sample.

Associate each callback with the copied frame's stream epoch, sequence and
geometry. Use the reported host timestamp relative to the sample's Core
Animation host-clock origin, rather than when a delayed callback reaches the
main thread. Count each received sequence at most once, exclude timestamps
outside the fixed sample, and sort presentation times before calculating gaps.
Reject changed streams, missing sequences, invalid timestamps and a presentation
preceding that frame's receipt. Late callbacks from a closed renderer or an old
view token cannot enter a new stream's measurement. Keep producer-slot ACKs and
GPU resource retirement independent of presentation callbacks.

Expose Mac presentation rate and gap distribution beside the existing metrics
in the development display menu. These are operating-system presentation
reports, not internal game FPS, unique-pixel detection or a physical panel
scanout measurement. A 120 Hz mode, GPU completion rate and Metal presentation
rate remain separate observations. Qualify the live path in Windows at its
actual mode before making a performance claim.
