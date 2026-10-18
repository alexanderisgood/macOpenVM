// SPDX-License-Identifier: Apache-2.0
import AppKit
import Qemu
import Testing

@testable import MacOpenVMApp

@MainActor private final class ModifiedKeyWindow: NSWindow {
  var controlledSpace = true
  override var isKeyWindow: Bool { true }
  override var isOnActiveSpace: Bool { controlledSpace }
}

/// Real responder methods, with a hidden controlled key window and captured callbacks.
/// These tests neither post events nor activate a window, connect a guest or capture a mouse.
@MainActor @Suite(.serialized) struct GuestModifiedKeyTests {
  @Test(arguments: [NSEvent.ModifierFlags.control, .option])
  func modifiedMovementStaysHeldUntilPhysicalKeyUp(_ modifiers: NSEvent.ModifierFlags) throws {
    let (window, view) = try fixture()
    defer { window.contentView = nil }
    var delivered: [RFBKeyStroke] = []
    view.onKey = { delivered.append(.init($0, down: $1)) }
    view.flagsChanged(with: try event(.flagsChanged, modifiers: modifiers))
    let down = try event(.keyDown, modifiers: modifiers)
    if !view.performKeyEquivalent(with: down) { view.keyDown(with: down) }
    #expect(delivered.filter { $0.symbol == 0x77 } == [RFBKeyStroke(0x77, down: true)])

    let repeated = try event(.keyDown, modifiers: modifiers, repeating: true)
    if !view.performKeyEquivalent(with: repeated) { view.keyDown(with: repeated) }
    #expect(delivered.filter { $0.symbol == 0x77 } == [RFBKeyStroke(0x77, down: true)])

    view.keyUp(with: try event(.keyUp, modifiers: modifiers))
    view.flagsChanged(with: try event(.flagsChanged, modifiers: []))
    let modifier: UInt32 = modifiers == .control ? 0xffe3 : 0xffe9
    #expect(
      delivered == [
        RFBKeyStroke(modifier, down: true), RFBKeyStroke(0x77, down: true),
        RFBKeyStroke(0x77, down: false), RFBKeyStroke(modifier, down: false),
      ])
  }

  @Test func ordinaryKeyDownAndKeyUpUseTheSameHeldStateAsModifiedMovement() throws {
    let (window, view) = try fixture()
    defer { window.contentView = nil }
    var delivered: [RFBKeyStroke] = []
    view.onKey = { delivered.append(.init($0, down: $1)) }
    view.keyDown(with: try event(.keyDown, modifiers: .control))
    #expect(
      delivered == [RFBKeyStroke(0xffe3, down: true), RFBKeyStroke(0x77, down: true)])
    view.keyUp(with: try event(.keyUp, modifiers: []))
    #expect(
      delivered == [
        RFBKeyStroke(0xffe3, down: true), RFBKeyStroke(0x77, down: true),
        RFBKeyStroke(0x77, down: false), RFBKeyStroke(0xffe3, down: false),
      ])
  }

  @Test func menuConsumedCommandTransactionBalancesWithoutAHostKeyUp() throws {
    let (window, view) = try fixture()
    defer { window.contentView = nil }
    var delivered: [RFBKeyStroke] = []
    view.onKey = { delivered.append(.init($0, down: $1)) }
    let expected = [
      RFBKeyStroke(0xffeb, down: true), RFBKeyStroke(0x77, down: true),
      RFBKeyStroke(0x77, down: false), RFBKeyStroke(0xffeb, down: false),
    ]
    for count in 1...3 {
      #expect(view.performKeyEquivalent(with: try event(.keyDown, modifiers: .command)))
      #expect(delivered == Array(repeating: expected, count: count).flatMap { $0 })
    }
    // A late key-up cannot manufacture another release or poison the next physical hold.
    view.keyUp(with: try event(.keyUp, modifiers: []))
    #expect(delivered == Array(repeating: expected, count: 3).flatMap { $0 })
    view.keyDown(with: try event(.keyDown, modifiers: []))
    #expect(delivered.last == RFBKeyStroke(0x77, down: true))
    view.keyUp(with: try event(.keyUp, modifiers: []))
    #expect(
      delivered.suffix(2) == [RFBKeyStroke(0x77, down: true), RFBKeyStroke(0x77, down: false)])
  }

  @Test func hostSwitchingFullscreenAndEmergencyReleaseNeverBecomeGuestShortcuts() throws {
    let (window, view) = try fixture()
    defer { window.contentView = nil }
    var delivered: [RFBKeyStroke] = []
    var releases = 0
    view.onKey = { delivered.append(.init($0, down: $1)) }
    view.onRelease = { releases += 1 }
    #expect(
      !view.performKeyEquivalent(
        with: try event(.keyDown, modifiers: .command, characters: "\t", keyCode: 48)))
    #expect(
      !view.performKeyEquivalent(
        with: try event(.keyDown, modifiers: [.control, .command], characters: "f", keyCode: 3)))
    #expect(
      view.performKeyEquivalent(
        with: try event(
          .keyDown, modifiers: [.control, .option], characters: "\u{1b}", keyCode: 53)))
    #expect(delivered.isEmpty && releases == 1)
  }

  @Test(arguments: [false, true])
  func offSpaceModifiedEventsCannotReachCapturedOrPendingGuestInput(_ pending: Bool) throws {
    let (window, view) = try fixture()
    defer { window.contentView = nil }
    window.controlledSpace = false
    var delivered: [RFBKeyStroke] = []
    view.onKey = { delivered.append(.init($0, down: $1)) }
    func restoreLocalCapture() {
      view.captured = !pending
      view.capturePending = pending
    }
    for modifiers: NSEvent.ModifierFlags in [.control, .option, .command] {
      restoreLocalCapture()
      view.flagsChanged(with: try event(.flagsChanged, modifiers: modifiers))
      restoreLocalCapture()
      let down = try event(.keyDown, modifiers: modifiers)
      if !view.performKeyEquivalent(with: down) { view.keyDown(with: down) }
      restoreLocalCapture()
      view.keyDown(with: down)
      restoreLocalCapture()
      view.keyUp(with: try event(.keyUp, modifiers: modifiers))
      restoreLocalCapture()
      view.flagsChanged(with: try event(.flagsChanged, modifiers: []))
    }
    #expect(window.isKeyWindow && !window.isOnActiveSpace)
    #expect(delivered.isEmpty)
  }

  @Test func offSpaceKeyUpSuspendsHeldStateBeforeTheSameKeyCanBeRecaptured() throws {
    let (window, view) = try fixture()
    defer { window.contentView = nil }
    var delivered: [RFBKeyStroke] = []
    var suspensions = 0
    view.onKey = { delivered.append(.init($0, down: $1)) }
    // The session synchronously clears view capture before it drains the client's
    // held-input release. This checks the view's retained key state, not wire delivery.
    view.onSuspend = { [weak view] in
      suspensions += 1
      view?.captured = false
    }
    view.keyDown(with: try event(.keyDown, modifiers: []))
    #expect(delivered == [RFBKeyStroke(0x77, down: true)])
    window.controlledSpace = false
    // Deliberately omit the Space notification. The actual event must notice loss.
    view.keyUp(with: try event(.keyUp, modifiers: []))
    #expect(suspensions == 1 && !view.captured)
    window.controlledSpace = true
    view.captured = true
    view.keyDown(with: try event(.keyDown, modifiers: []))
    view.keyUp(with: try event(.keyUp, modifiers: []))
    #expect(delivered.filter { $0.down }.count == 2)
    #expect(delivered.last == RFBKeyStroke(0x77, down: false))
  }

  private func fixture() throws -> (ModifiedKeyWindow, RfbGuestView) {
    _ = NSApplication.shared
    let window = ModifiedKeyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    view.hostPointerCapture = GuestHostPointerCapture()
    view.setHostCursor = { _ in }
    view.associateHostPointer = { _ in .success }
    view.warpHostPointer = { _ in .success }
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    #expect(window.firstResponder === view)
    view.captured = true
    return (window, view)
  }

  private func event(
    _ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, characters: String = "w",
    keyCode: UInt16 = 13, repeating: Bool = false
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: keyCode))
  }
}
