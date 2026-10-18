# ADR 10: original native QEMU display client

Status: experimental implementation with synthetic checks and a passed headless
native observer trial. Visible-window acceptance remains open. Windows, accelerated graphics,
native Retina, host-requested guest resize and complete keyboard/pointer acceptance
remain unverified.

The independent worker retains runtime ownership. The native application observes
its private session through control IPC and an original RFB 3.8 client on a separate
owned Unix endpoint. Display EOF, cancellation or view detach closes only that
display connection; it never signals children, clears intent or launches another
worker. This preserves [ADR 9](0009-qemu-crash-ownership.md).

The display lab selects a separate, hash-pinned VNC-enabled QEMU build. The
previous firmware-only candidate remains selected by its existing platform profile.
Preflight validates the executable and original keyboard data before spawning any
runtime child. The explicit data directory and absolute keymap path prevent a
working-directory file from overriding the pinned keyboard map. This candidate is
host-specific development evidence, not a macOS 14 or distribution qualification.

Use public QEMU Unix VNC with explicit shared connections and a private directory,
same-UID peer check and captured endpoint identity. Do not embed another process's
window, use private AppKit APIs, or present a separate QEMU Cocoa application.
The first producer remains gated to a newly prepared original display/input EFI
fixture with no OS or persistent user disk. The application uses its existing
Liquid Glass design and a clearly labeled lab view in its one main window.

The first protocol scope is fixed RFB 3.8, negotiated 32-bit true-color pixels,
Raw rectangles and DesktopSize notifications. Validate dimensions, pixel products,
rectangles, encoding tags and aggregate bytes before allocation; cap a framebuffer
at 64 MiB and retain bounded complete-frame state. Reject unsupported messages and
malformed rectangles. Guest names, framebuffer contents and raw messages are not
diagnostic log fields. Clipboard and pointer forwarding remain gated.

Incremental updates can remain silent while a guest is idle. An idle read must be
event-driven and cannot monopolize writes. Once a message begins, use a bounded
completion deadline; bound pending input writes and cancel/drain descriptor sources
before actual close. Track key-down state and release it on focus loss, explicit
release and teardown. Initially qualify only the original fixture's digits 1/2.
The host cursor stays visible until a working client cursor path is proven.

Use one tested aspect-fit transform from host logical points to guest framebuffer
pixels. Host backing scale controls host drawing density and never multiplies guest
pointer coordinates. Reject letterboxes and stale session/frame completions.
DesktopSize reports a guest-generated framebuffer change; it is not evidence that
a requested host viewport or Windows DPI mode was applied.

Acceptance: strict bounded parser/transport fixtures and geometry tests, then one
fresh native worker plus visible app view showing the original 640x480 and 800x600
frame grids, eight actual EFI keyboard acknowledgements, focus/release behavior and
display reconnect while the same worker/session/writer stays held. Frame data or a
headless image alone does not prove visible-window updates. No Windows, Retina,
performance parity, accelerated graphics or broader input claim follows.

Primary references: [RFC 6143](https://www.rfc-editor.org/rfc/rfc6143),
[QEMU 11.1 VNC options](https://github.com/qemu/qemu/blob/v11.1.0/qemu-options.hx),
[QEMU VNC client/input lifecycle](https://github.com/qemu/qemu/blob/v11.1.0/ui/vnc.c).

The native observer trial (private development record omitted) now proves
both actual modes, three sampled frame patterns, eight repeated keyboard
acknowledgements and display reconnect with a new RFB epoch while the same worker
session and writer remain held. Read each applied mode from the guest rather than
assuming its order. Use a fresh correlated control connection for each status
observation; the worker deliberately bounds idle client connections at three
seconds. The observer never stops the worker. A separately authorized parent
harness explicitly ends its new diskless runtime and joins the actual worker.

Next acceptance is the real Liquid Glass app: visible frame updates, keyboard
capture/release, focus changes, reconnect, fullscreen and the owning window through
transitions. The Mac must be unlocked for that test. Neither the headless trial nor
the original no-OS fixture establishes Windows installation or desktop support.

The app now shares one display teardown across normal reconnect and failed
receive/input. It invalidates capture and the old frame synchronously, joins the
old input tail, releases/closes only the old display peer, then cancels its receiver.
Concurrent reconnects wait for this teardown before opening another peer. Static
review and strict compilation passed; live focus and window-transition acceptance
still requires the visible app test.

## General keyboard transport — 2026-10-07

The next bounded input slice replaces the two-digit wire restriction with RFC6143
printable Latin-1/Unicode, navigation, F1–F24 and modifier keysyms. The wire encoder
emits all four network-order keysym bytes. The client independently tracks at most
64 held symbols and retains its ordered, bounded writes and release-before-close
behavior. Invalid symbols and excess held keys are rejected without changing the
admitted held set. Synthetic peers check exact bytes, closure and release behavior.

The experimental AppKit observer translates one `charactersIgnoringModifiers`
scalar at a time, maps public AppKit function characters, and remembers the symbol
admitted for each physical key code. Host repeats are suppressed; guest repeat owns
a held key. Physical aliases retain a symbol until the last corresponding key-up.
Modifier families map to left Shift/Control/Alt/Super (Command becomes Super);
left/right identity and AltGr are not advertised. Option is a guest Alt modifier,
not a host character-composition command. Multi-scalar/dead-key/IME composition is
not implemented. Caps Lock is conveyed through character case, not guest lock toggles.

While captured and first responder, key equivalents go to the guest; the permanent
Control–Option–Escape shortcut releases input. Focus loss, explicit release and
disconnect retain the existing client key-up path. This is implemented experimental
behavior, not proof of physical-key delivery, Windows layout/IME compatibility or
native menu routing. Visible capture/focus/shortcut tests and actual non-digit guest
acknowledgements remain required. No media acceptance or Windows launch gate changes.

## Native Windows installer display checkpoint

Actual native-window evidence (private development record omitted) now covers the approved offline installer, Liquid Glass presentation, synthesized Tab/Shift–Tab, display reconnect and app-quit survival under the retained Swift worker. All runtime children settled; media and blank disk preserved. This remains experimental. Next: pointer routing using the same rendered-viewport transform, followed by native geometry/fullscreen verification and the guided installation workflow. No installation, Retina, physical keyboard or full compatibility claim.

## Absolute pointer slice

The first pointer path uses RFC 6143 PointerEvent with the same bounded input
queue as keyboard events. It accepts three button bits and coordinates within
the last delivered framebuffer, with expected size supplied by the caller.
Capture release/close emits a zero button mask at the last admitted point.
AppKit uses the existing `GuestViewport` for both drawing and input; letterbox
space releases capture rather than clamping a click onto a guest control.
The host cursor remains available while cursor-shape/visibility support is open.
Wheel pulses, motion coalescing, relative capture and dynamic-resize generation
handling remain separate work. Actual narrow Windows click evidence (private development record omitted)
does not establish complete pointer acceptance.


## RAMFB cursor and vertical wheel decision

The qualified QEMU RAMFB implementation does not publish an independent cursor
shape through its display callbacks; Windows Setup draws its software cursor in
the framebuffer. VNC's optional Cursor pseudo-encoding depends on a console
cursor and therefore cannot establish a responsive local Windows cursor for this
particular device. A separate cursor channel remains part of the driver work.

The experimental installer observer offers an explicit Use Guest Cursor option
for the already observed Windows software-cursor path. A transparent AppKit cursor
rectangle is restricted to the captured guest viewport; release/focus loss/detach
restores the host arrow, without a global cursor-hide count or host preference.
This option is not enabled for the original firmware observer. Actual visible
cursor/recovery acceptance is required before changing its default.

Vertical scrolling uses bounded RFC 6143 wheel-button pulses and restores held
mouse-button state after every detent. Precise trackpad movement accumulates in
logical points; changing precision source or releasing capture clears fractional
carry. Horizontal scrolling, relative capture and motion performance remain open.

Actual fixed-screen Windows wheel evidence now exists in the scroll/cursor trial (private development record omitted). A full-frame hash guard and explicit per-action review protected the setup-list test. This does not qualify AppKit trackpad/cursor acceptance or Retina/fullscreen.

## Pending motion batching — 2026-10-07

Coalesce adjacent unsent positions on the main actor, with a sealed snapshot at
transmission time. Never overwrite the coordinate of a button transition; later
drag motion starts a separate slot. Keyboard and wheel input freeze the previous
slot, and capture/display boundaries reset the pending reference. Retain the
existing bounded ordered transmission tail. This avoids filling it with redundant
motion without weakening discrete input ordering. Queue evidence (private development record omitted)
is synthetic; physical/native-window and latency acceptance is still required.

## Scoped fullscreen presentation — implementation plan

Use public application presentation options to request a hidden Dock and visible
menu bar while the guest window is active in native fullscreen. Capture only the
Dock/menu/toolbar options before entry and restore only those owned options;
never restore a stale full application snapshot or write the window style mask.
Remove automatic toolbar presentation when requesting a visible menu bar, keeping
valid combinations on macOS 14 as well as newer SDKs. Keep SwiftUI's existing
window/delegate. Focus loss and unavailable display suspend guest presentation;
returning to the same fullscreen guest reapplies it. Tests must prove flag
ownership and valid combinations; actual screen-edge behavior still needs native
window verification. References: [Apple presentation options](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct)
and [native fullscreen lifecycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/FullScreenApp/FullScreenApp.html).

The scoped policy is implemented in both guest paths and has six passing app-module tests; evidence and the remaining native acceptance procedure (private development record omitted) explicitly separate option-state tests from visible Dock/menu/window behavior.

The finite rectangle-budget correction (private development record omitted)
admits legitimate QEMU updates with more than 256 small dirty rectangles while
retaining independent geometry, canvas, payload, deadline and transport bounds.
Native long-running GUI disconnects remain separate evidence until a loaded
corrected build is exercised.

## Consumed AppKit menu key-up — 13 October 2026

Actual captured Command-I opened Windows Settings but left the i key repeating
in its search field. The previous performKeyEquivalent forwarded keyDown and
assumed AppKit would deliver keyUp. The corrected path leaves ordinary physical
keys on keyDown/keyUp and sends Command menu equivalents as complete bounded
shortcut transactions. It restores previously tracked physical modifiers and
does not release other held keys; Command-Tab remains a host action. Synthetic
wire checks require shortcut key-up and modifier restoration before the next
frame request. Native repeated-shortcut, switching and text acceptance remain
required after loading the new immutable build.
