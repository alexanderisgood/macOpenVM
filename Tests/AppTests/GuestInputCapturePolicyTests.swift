// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

@Suite struct GuestInputCapturePolicyTests {
  @MainActor private final class GuestContainerFixture: NSView {
    override var acceptsFirstResponder: Bool { true }
  }

  @MainActor private final class CapturedGuestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isOnActiveSpace: Bool { true }
  }

  @MainActor @Test func restoresGuestFromItsContainerWithoutTakingSiblingControlFocus() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: .titled, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let container = GuestContainerFixture(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = container
    let guest = RfbGuestView(frame: container.bounds)
    guest.hostPointerCapture = GuestHostPointerCapture()
    container.addSubview(guest)
    #expect(window.makeFirstResponder(container))
    #expect(RfbLabSession.canRestoreGuestResponder(guest, in: window))
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
    container.addSubview(editor)
    #expect(window.makeFirstResponder(editor))
    #expect(!RfbLabSession.canRestoreGuestResponder(guest, in: window))
  }
  @Test func focusLossKeepsPreferenceButInvalidatesQueuedInput() {
    var policy = GuestInputCapturePolicy(automatic: true)
    let old = policy.generation
    #expect(policy.permitsQueuedInput(old, captured: true, foreground: true))
    policy.suspend()
    #expect(policy.wanted)
    #expect(!policy.permitsQueuedInput(old, captured: true, foreground: true))
    #expect(policy.permitsQueuedInput(policy.generation, captured: true, foreground: true))
    #expect(!policy.permitsQueuedInput(policy.generation, captured: true, foreground: false))
    #expect(!policy.permitsQueuedInput(policy.generation, captured: false, foreground: true))
  }

  @Test func explicitReleaseStaysReleasedAcrossFocusChanges() {
    var policy = GuestInputCapturePolicy(automatic: true)
    policy.release()
    policy.suspend()
    #expect(!policy.wanted)
    policy.request()
    #expect(policy.wanted)
  }

  @Test @MainActor func nativeResponderLossSuspendsWithoutExplicitRelease() {
    let view = RfbGuestView()
    view.hostPointerCapture = GuestHostPointerCapture()
    var suspended = 0
    var released = 0
    view.onSuspend = { suspended += 1 }
    view.onRelease = { released += 1 }
    _ = view.resignFirstResponder()
    #expect(suspended == 1)
    #expect(released == 0)
  }

  @Test @MainActor func applicationSwitchShortcutIsNeverForwarded() throws {
    let view = RfbGuestView()
    view.hostPointerCapture = GuestHostPointerCapture()
    view.captured = true
    var forwarded = 0
    view.onKey = { _, _ in forwarded += 1 }
    for flags: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
          isARepeat: false, keyCode: 48))
      #expect(!view.performKeyEquivalent(with: event))
    }
    #expect(forwarded == 0)
  }

  @Test @MainActor func releaseKeyReturnsGameMouseWithoutForwardingToGuest() throws {
    let view = RfbGuestView()
    view.hostPointerCapture = GuestHostPointerCapture()
    var association: [Bool] = []
    var forwarded = 0
    var released = 0
    var policy = GuestInputCapturePolicy(automatic: true)
    view.associateHostPointer = {
      association.append($0)
      return .success
    }
    view.setHostCursor = { _ in }
    view.onKey = { _, _ in forwarded += 1 }
    view.onRelease = {
      released += 1
      policy.release()
      view.captured = false
    }
    defer { view.onRelease = nil }
    view.captured = true
    view.setRelativeMouseCapture(true)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 53))
    view.keyDown(with: event)
    policy.suspend()
    #expect(released == 1 && forwarded == 0)
    #expect(!policy.wanted && !view.captured && !view.relativeMouseLocked)
    #expect(association == [false, true])
    view.keyDown(with: event)
    #expect(released == 1 && association == [false, true])
  }

  @Test @MainActor func ordinaryEscapeAndOtherModifierChordsDoNotReleaseCapture() throws {
    _ = NSApplication.shared
    for flags: NSEvent.ModifierFlags in [[], .control, .option, [.control, .option, .shift]] {
      let window = CapturedGuestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
        backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      let view = RfbGuestView()
      view.hostPointerCapture = GuestHostPointerCapture()
      view.setHostCursor = { _ in }
      view.associateHostPointer = { _ in .success }
      view.warpHostPointer = { _ in .success }
      window.contentView = view
      defer { window.contentView = nil }
      #expect(window.makeFirstResponder(view))
      view.captured = true
      var released = 0
      view.onRelease = { released += 1 }
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: 0, context: nil, characters: "\u{1b}",
          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
      view.keyDown(with: event)
      #expect(released == 0 && view.captured)
    }
  }
  @Test @MainActor func restoresWindowResponderButLeavesHostEditorAlone() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.hostPointerCapture = GuestHostPointerCapture()
    window.contentView = view
    defer { window.contentView = nil }
    #expect(window.makeFirstResponder(window))
    #expect(RfbLabSession.canRestoreGuestResponder(view, in: window))
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
    view.addSubview(editor)
    #expect(window.makeFirstResponder(editor))
    #expect(!RfbLabSession.canRestoreGuestResponder(view, in: window))
    #expect(window.makeFirstResponder(view))
    #expect(RfbLabSession.canRestoreGuestResponder(view, in: window))
    #expect(!RfbLabSession.canRestoreGuestResponder(RfbGuestView(), in: window))
  }

}
