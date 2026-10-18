# 49. Relative mouse capture for Windows games

Status: experimental; live App65 and physical CS2 turning verified narrowly.

The existing macOS view maps absolute screen positions through GuestViewport
and sends standard RFB PointerEvent messages to a USB tablet. CS2 receives
limited movement, then stops turning when the host cursor reaches a display
edge. Hiding that cursor alone does not fix the input semantics.

Retain the tablet for integrated desktop input and add QEMU's standard USB HID
mouse for relative input. The Input menu selects Game Mouse or Desktop Mouse.
The actual registered worker admits two fixed commands under its existing VM,
session, revision, running-state and operation gates. Its original QMP owner
uses query-mice, a fixed mouse_set command containing only a validated numeric
index, then query-mice again to confirm selection. No competing monitor reader
or caller-supplied monitor command is introduced.

Negotiate the public QEMU Pointer Motion Change pseudo-encoding(-257). Treat
its notification as unsolicited control rather than a completed pixel request.
Wait for the independently received mode before enabling input. Relative RFB
coordinates encode signed movement biased by32767, rather than guest pixels.
The transport validates the actual mode on its existing I/O queue. Motion
coalescing sums deltas, splits before overflow and retains button/key/wheel
boundaries. Release messages use zero deltas, preventing a repeated camera turn.

Use documented CGAssociateMouseAndMouseCursorPosition(false) with NSEvent
movement deltas while the captured VM view is the active key-window responder.
Center once on acquisition using runtime screen coordinates, preserve fractional
movement, and stop associating screen coordinates with camera input. Restore
association on release, focus loss, native menu tracking, detach and normal
termination. Cursor presentation remains scoped to the guest view, without a
global cursor hide count. Native menu completion repairs that cursor even when
there is no later mouse movement. The release shortcut remains Control–Option–Escape.

References: [Apple pointer association](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition(_:))
and [public RFB extension](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#qemu-pointer-motion-change-pseudo-encoding).
No new guest driver, privilege, signing bypass or graphics-library change is needed.

Acceptance: independent RFB wire tests for signed deltas, unsolicited mode
messages and zero-motion releases; summed-motion and edge/barrier tests; worker
admission and actual-QMP selection tests; hidden-view association/cursor repair
checks; then actual CS2 repeated turns beyond the host display width in both
directions, gameplay buttons/wheel, release and recapture, app switching, native
menus and a matching-resolution display-delivery sample. Physical mouse motion
must also be checked; synthesized movement alone cannot prove its feel or latency.


Live App65/QEMU34 was installed after normal Windows shutdown and actual app
parent exit0, preserving the previous bundle and all disk/platform records.
The initial USB device change rejected an absolute event and closed the display;
manual reconnect plus Desktop Mouse selection recovered the same live VM.
CS2 then entered offline DustII. Input→Game Mouse confirmed both QMP selection
and the received RFB relative mode; Input Captured remained visible. After the
menu closed, the maintainer tested a physical mouse and answered “Turning works
now”. This closes the reported screen-edge turning defect for that trial,
without claiming all pointer/focus or game compatibility acceptance.

The follow-up candidate distinguishes a valid device-mode race from malformed
input: reject the event before writing bytes, preserve the same transport and
ordered input tail, release held input, restore the requested device through its
original worker, then confirm its RFB mode before recapture. The independent
wire test injects a wrong-mode event and verifies subsequent wheel/movement/
release bytes remain usable. App66 was installed after normal Windows/app settlement. Windows startup and sign-in succeeded without manual display reconnect. An intentionally forced live device-mode race is not yet qualified.
