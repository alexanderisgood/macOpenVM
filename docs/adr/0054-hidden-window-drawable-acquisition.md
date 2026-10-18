# 54. Pause drawable acquisition for hidden VM windows

Status: native fixture, signed release and live Windows startup/fullscreen/focus
recovery pass; controlled foreground gameplay delivery remains pending.

App69/70 record drawable acquisition waits around429–483ms outside controlled
frame measurements. Their relationship to foreground gameplay, Spaces and focus
transitions is unproven. The renderer currently acquires drawables even when its
native window is occluded; a waiting acquisition also delays the next visible
presentation. Do not attribute every CS2 freeze to this observation.

Use AppKit's public window occlusion state and its change notification to gate
screen acquisition. Continue the existing ordered GPU cache copy and producer
ACK while hidden. Retain the latest cache/stamp, then request a drawable on
return to visibility. Suppress hidden completion callbacks as display-delivery
evidence. Keep the same GPU queue, mapping lifetime, timeout and closed checks.
An already waiting public nextDrawable call cannot be cancelled; it may return
later and must re-check visibility before submitting presentation.

The actual shared-pool fixture must complete native/4K cache copies with no
drawable acquisition on an unattached layer. Read pixels back from that existing
cache, without another source copy, and verify every pixel before producer ACK.
Live acceptance requires initial Windows presentation without manual reconnect,
hidden/visible and native fullscreen recovery, one VM-owning window, correct
menu/input behavior and a controlled native CS2 delivery sample. Reduced hidden
draw requests alone cannot establish a foreground FPS or hitch improvement.

Sources: [NSWindow occlusionState](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property),
[occlusion change notification](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification).

The native/4K fixture passes with zero drawable requests while hidden, actual GPU
copy completion, every-pixel readback from the existing cache and normal peer
ACK/lifetime checks. Eight focused capture-policy tests pass, including physical
Escape without a character string, host pointer reassociation and no release key
forwarded to the guest. Strict changed-file formatting and App71 release/signing/
provenance pass. The updated single app is installed with App70 preserved.
After the Mac was unlocked, App71 starts Windows without manual reconnect and
its actual native window displays the guest. View reports guest and Mac viewport
3456×2168, macOS Menu Bar Visible, Native fullscreen, requested0x405/effective0x400.
Exit and re-entry recover the displayed guest; leaving fullscreen reports a
3456×2002 viewport. Four recorded occlusion transitions return to active state
with no acquisition pending. Windows later displays its desktop through the
existing connection. The log contains no slow acquisition line in this run;
that absence is not a foreground FPS or hitch result. The Game Mouse menu exposes
Release Game Mouse and Control–Option–Escape, and the shortcut changes capture to
Input Released while retaining Game Mouse selection. Normal shutdown and native
Quit settle/reap all owned runtime/app parents; no trial instance remains.
No controlled CS2 sample was completed in the coordinated live slot. Native120Hz
and sustained gameplay delivery remain unqualified.
