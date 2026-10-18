// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp
@testable import Qemu

@MainActor private final class CursorInvalidationWindow: NSWindow {
  var controlledKey = true
  override var isKeyWindow: Bool { controlledKey }
  override var isOnActiveSpace: Bool { true }
  private(set) var invalidations = 0
  override func invalidateCursorRects(for view: NSView) { invalidations += 1 }
  func resetInvalidations() { invalidations = 0 }
}

/// Hidden AppKit views and public synthetic pixels only. No event is posted,
/// window shown, guest connected, or native VM started by these tests.
@MainActor @Suite(.serialized) struct RfbGuestCursorTests {
  @Test func relativeCaptureRestoresAssociationOnReleaseAndDetachWithoutGlobalHideCounts() {
    let (window, view) = fixture()
    var changes: [Bool] = []
    view.associateHostPointer = {
      changes.append($0)
      return .success
    }
    view.setHostCursor = { _ in }
    view.captured = true
    view.setRelativeMouseCapture(true)
    view.setRelativeMouseCapture(true)
    #expect(view.relativeMouseLocked && changes == [false])
    view.captured = false
    #expect(!view.relativeMouseLocked && changes == [false, true])
    view.setRelativeMouseCapture(true)
    window.contentView = nil
    #expect(!view.relativeMouseLocked && changes == [false, true, false, true])
  }

  @Test func nativeMenuEndRepairsCursorEvenWithoutPointerMovement() {
    let (window, view) = fixture()
    var selections = 0
    view.setHostCursor = { _ in selections += 1 }
    defer { window.contentView = nil }
    let menu = NSMenu()
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    let during = selections
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    #expect(during > 0 && selections > during)
  }

  @Test func closingASubmenuDoesNotRecaptureBeforeItsParentCloses() {
    let (window, view) = fixture()
    view.setHostCursor = { _ in }
    defer { window.contentView = nil }
    view.captured = true
    view.useGuestCursor = true
    view.update(
      frame: RFBFrame(
        connectionEpoch: UUID(), sequence: 1,
        size: PixelSize(width: 2, height: 2), rgbaData: Data(repeating: 0, count: 16)))
    let parent = NSMenu()
    let child = NSMenu()
    let center = NSPoint(x: 32, y: 32)
    for menu in [parent, child] {
      NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    }
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: child)
    #expect(
      view.cursor(at: center, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: parent)
    #expect(
      !view.cursor(at: center, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))
  }

  private func fixture() -> (CursorInvalidationWindow, RfbGuestView) {
    _ = NSApplication.shared
    let window = CursorInvalidationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    view.hostPointerCapture = GuestHostPointerCapture()
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    #expect(window.firstResponder === view)
    window.resetInvalidations()
    return (window, view)
  }

  private func cursorEvent(_ window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
    )
  }

  @Test func appKitCursorCallbackNeverInvalidatesStructuralRegions() throws {
    let (window, view) = fixture()
    let originalCursor = NSCursor.current
    defer {
      window.contentView = nil
      originalCursor.set()
    }
    let event = try cursorEvent(window)
    for (captured, guestCursor) in [(false, false), (true, false), (true, true), (false, true)] {
      view.captured = captured
      view.useGuestCursor = guestCursor
      window.resetInvalidations()
      for _ in 0..<16 { view.cursorUpdate(with: event) }
      #expect(window.invalidations == 0)
      #expect(NSCursor.current.isEqual(NSCursor.arrow))
    }
  }

  @Test func stateAndFrameGeometryStillInvalidateWhileReleaseRestoresHostCursor() throws {
    let (window, view) = fixture()
    let originalCursor = NSCursor.current
    defer {
      window.contentView = nil
      originalCursor.set()
    }
    view.captured = true
    view.useGuestCursor = true
    #expect(window.invalidations == 2)
    view.captured = true
    view.useGuestCursor = true
    #expect(window.invalidations == 2)
    let epoch = UUID()
    func frame(_ width: Int, _ sequence: UInt64) -> RFBFrame {
      RFBFrame(
        connectionEpoch: epoch, sequence: sequence, size: PixelSize(width: width, height: 2),
        rgbaData: Data(repeating: 0, count: width * 2 * 4))
    }
    view.update(frame: frame(2, 1))
    #expect(window.invalidations == 3)
    view.update(frame: frame(2, 2))
    #expect(window.invalidations == 3)
    view.update(frame: frame(4, 3))
    #expect(window.invalidations == 4)
    view.update(frame: nil)
    #expect(window.invalidations == 5)
    NSCursor.crosshair.set()
    view.captured = false
    #expect(window.invalidations == 6 && NSCursor.current.isEqual(NSCursor.arrow))
    view.cursorUpdate(with: try cursorEvent(window))
    #expect(window.invalidations == 6)
  }

  @Test func onlyTheOwnedGuestViewportSelectsTheTransparentCursor() {
    let (window, view) = fixture()
    view.setHostCursor = { _ in }
    defer { window.contentView = nil }
    view.captured = true
    view.useGuestCursor = true
    view.update(
      frame: RFBFrame(
        connectionEpoch: UUID(), sequence: 1, size: PixelSize(width: 4, height: 2),
        rgbaData: Data(repeating: 0, count: 32)))
    let center = NSPoint(x: 32, y: 32)
    let guest = view.cursor(at: center, applicationActive: true, keyWindow: true)
    #expect(!guest.isEqual(NSCursor.arrow))
    for point in [NSPoint(x: 32, y: 2), NSPoint(x: -1, y: 32), NSPoint(x: 65, y: 32)] {
      #expect(
        view.cursor(at: point, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))
    }
    #expect(
      view.cursor(at: center, applicationActive: false, keyWindow: true).isEqual(NSCursor.arrow))
    #expect(
      view.cursor(at: center, applicationActive: true, keyWindow: false).isEqual(NSCursor.arrow))
    view.captured = false
    #expect(
      view.cursor(at: center, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))
    view.captured = true
    view.useGuestCursor = false
    #expect(
      view.cursor(at: center, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))
    view.useGuestCursor = true
    view.update(frame: nil)
    #expect(
      view.cursor(at: center, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))
  }

  @Test func movementDragWheelAndTrackingRepairAnOverriddenCursorWithoutInvalidation() throws {
    let (window, view) = fixture()
    var selections = 0
    view.setHostCursor = { _ in selections += 1 }
    defer { window.contentView = nil }
    view.captured = true
    view.useGuestCursor = true
    window.resetInvalidations()
    let event = try cursorEvent(window)
    selections = 0
    for _ in 0..<16 {
      view.mouseMoved(with: event)
      view.mouseDragged(with: event)
      view.rightMouseDragged(with: event)
      view.otherMouseDragged(with: event)
      view.mouseDown(with: event)
      view.mouseUp(with: event)
      view.scrollWheel(with: event)
      view.mouseEntered(with: event)
      view.mouseExited(with: event)
      view.cursorUpdate(with: event)
    }
    #expect(selections == 160)
    #expect(window.invalidations == 0)
    view.updateTrackingAreas()
    let tracking = try #require(view.trackingAreas.last)
    #expect(tracking.options.contains(.mouseEnteredAndExited))
    #expect(tracking.options.contains(.enabledDuringMouseDrag))
    #expect(selections == 161)
    // AppKit may invalidate its structural regions while replacing a tracking
    // area. Subsequent cursor events must not create a new invalidation loop.
    let structuralInvalidations = window.invalidations
    for _ in 0..<16 { view.cursorUpdate(with: event) }
    #expect(selections == 177 && window.invalidations == structuralInvalidations)
  }
}
