// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Testing

@testable import MacOpenVMApp
@testable import Qemu

@MainActor private final class PointerModifierWindow: NSWindow {
  var controlledKey = true
  var controlledSpace = true
  var controlledResponderLost = false
  override var firstResponder: NSResponder? { controlledResponderLost ? nil : super.firstResponder }
  override var isKeyWindow: Bool { controlledKey }
  override var isOnActiveSpace: Bool { controlledSpace }
}

/// Actual responder/event ordering only. All host cursor effects are injected;
/// no app activation, event posting, session admission or guest is required.
@MainActor @Suite(.serialized) struct GuestPointerModifierTests {
  private enum Delivery: Equatable {
    case key(UInt32, Bool)
    case pointer, scroll
  }

  // AppKit redirects a Shift wheel to horizontal scrolling. This vertical-wheel
  // regression uses Control; Shift remains covered by actual clicks and motion.
  @Test(arguments: [
    "shift-click", "shift-motion", "control-click", "control-motion", "control-wheel",
  ])
  func modifiersHeldBeforeCapturePrecedeTheFirstPointerAction(input: String) throws {
    let modifier: NSEvent.ModifierFlags = input.hasPrefix("shift") ? .shift : .control
    let ingress = String(input.split(separator: "-").last!)
    let (window, view) = fixture(captured: false)
    defer { cleanUp(window, view) }
    var deliveries: [Delivery] = []
    record(view, into: { deliveries.append($0) })
    view.flagsChanged(with: try modifierEvent(modifier))
    #expect(deliveries.isEmpty)
    view.captured = true
    try deliver(ingress, flags: modifier, to: view)
    let symbol = modifierSymbol(modifier)
    #expect(deliveries == [.key(symbol, true), action(ingress)])
    view.flagsChanged(with: try modifierEvent([], released: modifier))
    #expect(deliveries == [.key(symbol, true), action(ingress), .key(symbol, false)])
  }

  @Test(arguments: [NSEvent.ModifierFlags.shift, .control], ["click", "motion", "wheel"])
  func aMissedModifierUpIsReconciledBeforeTheNextPointerAction(
    modifier: NSEvent.ModifierFlags, ingress: String
  ) throws {
    let (window, view) = fixture()
    defer { cleanUp(window, view) }
    var deliveries: [Delivery] = []
    record(view, into: { deliveries.append($0) })
    view.flagsChanged(with: try modifierEvent(modifier))
    let symbol = modifierSymbol(modifier)
    #expect(deliveries == [.key(symbol, true)])
    // No flagsChanged notification accompanies the physical release. The next
    // real mouse event supplies the authoritative empty modifier snapshot.
    try deliver(ingress, flags: [], to: view)
    #expect(deliveries == [.key(symbol, true), .key(symbol, false), action(ingress)])
  }

  @Test(arguments: ["release", "foreign-custody"], ["click", "motion", "wheel"])
  func aModifierCallbackCannotLetFurtherInputEscapeAfterCaptureChanges(
    change: String, ingress: String
  ) throws {
    let (window, view) = fixture()
    let capture = view.hostPointerCapture
    let foreign = UUID()
    defer {
      capture.restore(for: foreign)
      cleanUp(window, view)
    }
    var deliveries: [Delivery] = []
    var refusals = 0
    var associations: [Bool] = []
    view.capturePending = true
    view.onCaptureRefused = { refusals += 1 }
    view.onPointer = { _, _, _, _ in deliveries.append(.pointer) }
    view.onScroll = { _, _, _, _ in deliveries.append(.scroll) }
    view.onKey = { symbol, down in
      deliveries.append(.key(symbol, down))
      guard deliveries.count == 1 else { return }
      if change == "release" {
        view.capturePending = false
        view.captured = false
      } else {
        #expect(
          capture.acquire(for: foreign) { restoring in
            associations.append(restoring)
            return .success
          })
      }
    }
    // The first modifier callback revokes capture. The second modifier and
    // pointer operation must stop; vertical wheels use Control + Option because
    // AppKit redirects any Shift wheel to horizontal scrolling.
    let flags: NSEvent.ModifierFlags =
      ingress == "wheel" ? [.control, .option] : [.shift, .control]
    let firstSymbol: UInt32 = ingress == "wheel" ? 0xffe3 : 0xffe1
    try deliver(ingress, flags: flags, to: view)
    #expect(deliveries == [.key(firstSymbol, true)])
    #expect(!view.captured && !view.capturePending)
    #expect(refusals == (change == "foreign-custody" ? 1 : 0))
    #expect(capture.isCaptured(by: foreign) == (change == "foreign-custody"))
    #expect(associations == (change == "foreign-custody" ? [false] : []))
  }

  @Test(arguments: ["non-key", "non-responder"], ["click", "motion", "wheel"])
  func modifierCallbackFocusLossStopsTheBurstAndFreshCaptureResendsAllModifiers(
    rejection: String, ingress: String
  ) throws {
    let (window, view) = fixture()
    defer { cleanUp(window, view) }
    var deliveries: [Delivery] = []
    var interrupted = false
    var suspensions = 0
    view.capturePending = true
    view.onSuspend = { suspensions += 1 }
    view.onPointer = { _, _, _, _ in deliveries.append(.pointer) }
    view.onScroll = { _, _, _, _ in deliveries.append(.scroll) }
    view.onKey = { symbol, down in
      deliveries.append(.key(symbol, down))
      guard !interrupted else { return }
      interrupted = true
      if rejection == "non-key" {
        // Deliberately omit AppKit's focus notification. Revalidation after the
        // callback must catch the actual window state itself.
        window.controlledKey = false
      } else {
        #expect(window.makeFirstResponder(nil))
      }
    }
    let flags: NSEvent.ModifierFlags =
      ingress == "wheel" ? [.control, .option] : [.shift, .control]
    let first: UInt32 = ingress == "wheel" ? 0xffe3 : 0xffe1
    let second: UInt32 = ingress == "wheel" ? 0xffe9 : 0xffe3
    try deliver(ingress, flags: flags, to: view)
    #expect(deliveries == [.key(first, true)])
    #expect(!view.captured && !view.capturePending && suspensions > 0)

    window.controlledKey = true
    #expect(window.makeFirstResponder(view))
    view.captured = true
    try deliver(ingress, flags: flags, to: view)
    // The aborted burst must not remember its untransmitted second modifier.
    // Fresh capture sends both held keys again, then the admitted pointer action.
    #expect(
      deliveries == [
        .key(first, true), .key(first, true), .key(second, true), action(ingress),
      ])
  }

  @Test(arguments: ["off-space", "non-key", "non-responder", "letterbox"], ["click", "wheel"])
  func pointerModifierSnapshotsCannotBypassInputAdmission(
    rejection: String, ingress: String
  ) throws {
    let (window, view) = fixture()
    defer { cleanUp(window, view) }
    var deliveries: [Delivery] = []
    record(view, into: { deliveries.append($0) })
    var location = NSPoint(x: 32, y: 32)
    switch rejection {
    case "off-space": window.controlledSpace = false
    case "non-key": window.controlledKey = false
    case "non-responder": #expect(window.makeFirstResponder(nil))
    default:
      view.update(
        frame: RFBFrame(
          connectionEpoch: UUID(), sequence: 2, size: PixelSize(width: 2, height: 1),
          rgbaData: Data(repeating: 0, count: 8)))
      location.y = 2
    }
    let flags: NSEvent.ModifierFlags =
      ingress == "wheel" ? [.control, .option] : [.shift, .control]
    try deliver(ingress, flags: flags, at: location, to: view)
    #expect(deliveries.isEmpty)
  }

  @Test(arguments: ["non-key", "letterbox"])
  func aRejectedClickCannotPoisonTheNextAdmittedPointerMotion(rejection: String) throws {
    let (window, view) = fixture()
    defer { cleanUp(window, view) }
    var transmittedButtons: [UInt8] = []
    view.onPointer = { _, buttons, _, _ in transmittedButtons.append(buttons) }
    var rejectedLocation = NSPoint(x: 32, y: 32)
    if rejection == "non-key" {
      window.controlledKey = false
    } else {
      view.update(
        frame: RFBFrame(
          connectionEpoch: UUID(), sequence: 2, size: PixelSize(width: 2, height: 1),
          rgbaData: Data(repeating: 0, count: 8)))
      rejectedLocation.y = 2
    }
    try deliver("click", flags: [], at: rejectedLocation, to: view)
    #expect(transmittedButtons.isEmpty)
    // Restoring external focus/location alone cannot revive revoked capture.
    // A rejected non-key click requires a fresh capture before input can resume.
    window.controlledKey = true
    try deliver("motion", flags: [], to: view)
    if rejection == "non-key" {
      #expect(!view.captured && transmittedButtons.isEmpty)
      view.captured = true
      try deliver("motion", flags: [], to: view)
    }
    #expect(transmittedButtons == [0])
  }

  @Test(
    arguments: [
      "captured/non-key", "captured/non-responder", "pending/non-key", "pending/non-responder",
      "both/non-key", "both/non-responder",
    ], ["up", "motion", "wheel", "click"])
  func missedFocusNotificationCannotCarryHeldButtonsIntoRestoredPointerInput(
    ownership: String, ingress: String
  ) throws {
    let pendingOnly = ownership.hasPrefix("pending/")
    let (window, view) = fixture(captured: !pendingOnly)
    defer { cleanUp(window, view) }
    view.capturePending = !ownership.hasPrefix("captured/")
    var transmittedButtons: [UInt8] = []
    var keys: [Delivery] = []
    var scrolls = 0
    var suspensions = 0
    var captureRequests = 0
    view.onPointer = { _, buttons, _, _ in transmittedButtons.append(buttons) }
    view.onKey = { keys.append(.key($0, $1)) }
    view.onScroll = { _, _, _, _ in scrolls += 1 }
    view.onSuspend = { suspensions += 1 }
    view.onCapture = { captureRequests += 1 }
    try #require(window.firstResponder === view && window.isKeyWindow)
    func keyEvent(_ type: NSEvent.EventType) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: [], timestamp: 10,
          windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
          isARepeat: false, keyCode: 13))
    }
    if pendingOnly {
      view.keyDown(with: try keyEvent(.keyDown))
      try #require(keys == [.key(0x77, true)] && transmittedButtons.isEmpty)
    } else {
      try deliver("click", flags: [], to: view)
      try #require(transmittedButtons == [1])
    }
    let beforeLoss = transmittedButtons

    if ownership.hasSuffix("/non-key") {
      window.controlledKey = false
    } else {
      // Retain the real responder but omit its resignation notification, as for
      // a stale observer. Input must revalidate what the window reports now.
      window.controlledResponderLost = true
    }
    try deliver(ingress, flags: [], to: view)
    #expect(transmittedButtons == beforeLoss && scrolls == 0 && captureRequests == 0)
    #expect(!view.captured && !view.capturePending && suspensions > 0)

    window.controlledKey = true
    window.controlledResponderLost = false
    #expect(window.firstResponder === view)
    // Restoring only focus cannot replay input admitted before focus loss.
    try deliver("motion", flags: [], to: view)
    #expect(transmittedButtons == beforeLoss)

    view.captured = true
    try deliver("motion", flags: [], to: view)
    #expect(transmittedButtons == beforeLoss + [0])
    if pendingOnly {
      // This checks view-held key state only. No admitted session buffer or
      // guest exists; a fresh physical press must not disappear as a duplicate.
      view.keyDown(with: try keyEvent(.keyDown))
      #expect(keys == [.key(0x77, true), .key(0x77, true)])
      view.keyUp(with: try keyEvent(.keyUp))
      #expect(keys.last == .key(0x77, false))
    }
  }

  private func record(_ view: RfbGuestView, into append: @escaping (Delivery) -> Void) {
    view.onKey = { append(.key($0, $1)) }
    view.onPointer = { _, _, _, _ in append(.pointer) }
    view.onScroll = { _, _, _, _ in append(.scroll) }
  }

  private func modifierSymbol(_ modifier: NSEvent.ModifierFlags) -> UInt32 {
    modifier == .shift ? 0xffe1 : 0xffe3
  }

  private func action(_ ingress: String) -> Delivery { ingress == "wheel" ? .scroll : .pointer }

  private func modifierEvent(
    _ flags: NSEvent.ModifierFlags, released: NSEvent.ModifierFlags = []
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 10,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: flags.contains(.control) || released == .control ? 59 : 56))
  }

  private func deliver(
    _ ingress: String, flags: NSEvent.ModifierFlags,
    at location: NSPoint = NSPoint(x: 32, y: 32), to view: RfbGuestView
  ) throws {
    if ingress == "wheel" {
      let cgEvent = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
          wheel1: 1, wheel2: 0, wheel3: 0))
      let primary = try #require(NSScreen.screens.first)
      cgEvent.location = CGPoint(x: location.x, y: primary.frame.maxY - location.y)
      var cgFlags = CGEventFlags()
      if flags.contains(.shift) { cgFlags.insert(.maskShift) }
      if flags.contains(.control) { cgFlags.insert(.maskControl) }
      if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
      cgEvent.flags = cgFlags
      let event = try #require(NSEvent(cgEvent: cgEvent))
      #expect(event.type == .scrollWheel && event.scrollingDeltaY != 0)
      #expect(event.locationInWindow == location)
      #expect(event.modifierFlags.intersection([.shift, .control, .option]) == flags)
      view.scrollWheel(with: event)
    } else {
      let event = try #require(
        NSEvent.mouseEvent(
          with: ingress == "motion"
            ? .mouseMoved : (ingress == "up" ? .leftMouseUp : .leftMouseDown),
          location: location,
          modifierFlags: flags, timestamp: 10, windowNumber: 0, context: nil,
          eventNumber: 1, clickCount: ingress == "motion" ? 0 : 1, pressure: 1))
      if ingress == "motion" {
        view.mouseMoved(with: event)
      } else if ingress == "up" {
        view.mouseUp(with: event)
      } else {
        view.mouseDown(with: event)
      }
    }
  }

  private func fixture(captured: Bool = true) -> (PointerModifierWindow, RfbGuestView) {
    _ = NSApplication.shared
    let window = PointerModifierWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    view.hostPointerCapture = GuestHostPointerCapture()
    view.setHostCursor = { _ in }
    view.associateHostPointer = { _ in .success }
    view.warpHostPointer = { _ in .success }
    window.contentView = view
    view.update(
      frame: RFBFrame(
        connectionEpoch: UUID(), sequence: 1, size: PixelSize(width: 2, height: 2),
        rgbaData: Data(repeating: 0, count: 16)))
    #expect(window.makeFirstResponder(view))
    view.captured = captured
    return (window, view)
  }

  private func cleanUp(_ window: NSWindow, _ view: RfbGuestView) {
    view.capturePending = false
    view.captured = false
    view.setRelativeMouseCapture(false)
    window.contentView = nil
  }
}
