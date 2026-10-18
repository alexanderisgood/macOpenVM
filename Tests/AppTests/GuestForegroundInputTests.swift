// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp
@testable import Qemu

@MainActor private final class ForegroundInputWindow: NSWindow {
  var controlledKey = true
  var controlledSpace = true
  override var isKeyWindow: Bool { controlledKey }
  override var isOnActiveSpace: Bool { controlledSpace }
}

/// Controlled native window state and injected pointer effects only. No app activation,
/// event posting, real pointer capture, guest connection or VM is required.
@MainActor @Suite(.serialized) struct GuestForegroundInputTests {
  @Test func offSpaceWindowCannotHideTheHostCursorWithStaleKeyAndActiveFlags() {
    let (window, view) = fixture()
    defer { window.contentView = nil }
    let point = NSPoint(x: 32, y: 32)
    #expect(
      !view.cursor(at: point, applicationActive: true, keyWindow: window.isKeyWindow)
        .isEqual(NSCursor.arrow))
    window.controlledSpace = false
    #expect(window.isKeyWindow && !window.isOnActiveSpace)
    #expect(
      view.cursor(at: point, applicationActive: true, keyWindow: window.isKeyWindow)
        .isEqual(NSCursor.arrow))
    window.controlledSpace = true
    #expect(
      !view.cursor(at: point, applicationActive: true, keyWindow: window.isKeyWindow)
        .isEqual(NSCursor.arrow))
    window.controlledKey = false
    #expect(
      view.cursor(at: point, applicationActive: true, keyWindow: window.isKeyWindow)
        .isEqual(NSCursor.arrow))
  }

  @Test func actualViewEligibilityReleasesPointerAndNewFramesCannotRelockOffSpace() {
    let (window, view) = fixture()
    window.controlledSpace = false
    view.relativeMouse = true
    #expect(window.makeFirstResponder(view))
    var associations: [Bool] = []
    var warps = 0
    view.warpHostPointer = { _ in
      warps += 1
      return .success
    }
    view.associateHostPointer = {
      associations.append($0)
      return .success
    }
    defer {
      view.setRelativeMouseCapture(false)
      window.contentView = nil
    }
    // Seed the injected platform state directly. Positive real-view eligibility would
    // warp the host pointer, so only negative eligibility paths are invoked below.
    view.setRelativeMouseCapture(true)
    #expect(view.relativeMouseLocked && associations == [false])
    view.updateRelativeMouseLock(applicationActive: true)
    #expect(!view.relativeMouseLocked && associations == [false, true])
    view.update(
      frame: RFBFrame(
        connectionEpoch: UUID(), sequence: 2, size: PixelSize(width: 4, height: 2),
        rgbaData: Data(repeating: 0, count: 32)))
    view.updateRelativeMouseLock(applicationActive: true)
    #expect(!view.relativeMouseLocked && associations == [false, true])
    window.controlledSpace = true
    window.controlledKey = false
    view.setRelativeMouseCapture(true)
    view.updateRelativeMouseLock(applicationActive: true)
    #expect(!view.relativeMouseLocked && associations == [false, true, false, true])
    window.controlledKey = true
    #expect(window.makeFirstResponder(nil))
    view.setRelativeMouseCapture(true)
    view.updateRelativeMouseLock(applicationActive: true)
    #expect(!view.relativeMouseLocked && associations == [false, true, false, true, false, true])
    #expect(warps == 0)
  }

  @Test func failedPointerRestorationOnDetachKeepsCustodyUntilARealSuccessfulRetry() {
    let (window, view) = fixture()
    window.controlledSpace = false
    view.relativeMouse = true
    var canRestore = false
    var associations: [Bool] = []
    view.associateHostPointer = {
      associations.append($0)
      return $0 && !canRestore ? .failure : .success
    }
    view.setRelativeMouseCapture(true)
    #expect(view.relativeMouseLocked)
    window.contentView = nil
    #expect(view.window == nil && view.relativeMouseLocked)
    #expect(associations.first == false && associations.dropFirst().contains(true))
    canRestore = true
    view.setRelativeMouseCapture(false)
    #expect(!view.relativeMouseLocked && associations.last == true)
  }

  @Test func failedPointerRestorationOnTerminationCanRetryWithoutInventingUnlock() {
    let (window, view) = fixture()
    window.controlledSpace = false
    view.relativeMouse = true
    var canRestore = false
    var attempts = 0
    view.associateHostPointer = {
      if $0 { attempts += 1 }
      return $0 && !canRestore ? .failure : .success
    }
    defer {
      canRestore = true
      view.setRelativeMouseCapture(false)
      window.contentView = nil
    }
    view.setRelativeMouseCapture(true)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
    #expect(view.relativeMouseLocked && attempts >= 1)
    let failedAttempts = attempts
    canRestore = true
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
    #expect(!view.relativeMouseLocked && attempts > failedAttempts)
  }

  @Test func staleKeyWindowCannotAdmitQueuedOrPendingKeysAfterSpaceLoss() {
    let (window, _) = fixture()
    defer { window.contentView = nil }
    var policy = GuestInputCapturePolicy(automatic: true)
    let queued = policy.generation
    let identity = GuestPendingKeyboardCapture.Identity(
      connection: UUID(), frameEpoch: UUID(), attempt: UUID(), policyGeneration: queued)
    var pending = GuestPendingKeyboardCapture()
    pending.begin(identity)
    let bufferedModifier = pending.append(
      RFBKeyStroke(0xffe3, down: true), for: identity, foreground: true)
    #expect(bufferedModifier)
    window.controlledSpace = false
    let foreground = GuestInputCapturePolicy.isForeground(
      applicationActive: true, keyWindow: window.isKeyWindow,
      onActiveSpace: window.isOnActiveSpace)
    #expect(!foreground)
    #expect(!policy.permitsQueuedInput(queued, captured: true, foreground: foreground))
    let bufferedKey = pending.append(
      RFBKeyStroke(0x77, down: true), for: identity, foreground: foreground)
    #expect(!bufferedKey)
    #expect(pending.finish(identity, verified: true, foreground: true).isEmpty)
    policy.suspend()
    window.controlledSpace = true
    #expect(!policy.permitsQueuedInput(queued, captured: true, foreground: true))
    #expect(policy.permitsQueuedInput(policy.generation, captured: true, foreground: true))
  }

  @Test func offSpaceMouseUpSuspendsAStillCapturedGuestWithoutWaitingForANotification() throws {
    let (window, view) = fixture()
    defer { window.contentView = nil }
    #expect(window.makeFirstResponder(view))
    var buttons: [UInt8] = []
    var suspensions = 0
    view.onPointer = { _, held, _, _ in buttons.append(held) }
    view.onSuspend = { [weak view] in
      suspensions += 1
      view?.captured = false
    }
    view.mouseDown(with: try mouseEvent(.leftMouseDown))
    #expect(buttons == [1])
    window.controlledSpace = false
    // No Space notification is posted. A real mouse-up must detect the loss and
    // tell the session to release its peer, rather than silently preserving capture.
    view.mouseUp(with: try mouseEvent(.leftMouseUp))
    #expect(suspensions == 1 && !view.captured && buttons == [1])
    window.controlledSpace = true
    view.captured = true
    view.mouseMoved(with: try mouseEvent(.mouseMoved))
    #expect(buttons == [1, 0])
  }

  @Test(arguments: [false, true])
  func sessionWindowCloseReleasesTheStillAttachedViewBeforeAnyKeyLossNotification(
    restorationSucceeds: Bool
  ) {
    let (window, view) = fixture()
    let session = RfbLabSession()
    var canRestore = restorationSucceeds
    var associations: [Bool] = []
    var warps = 0
    view.associateHostPointer = {
      associations.append($0)
      return $0 && !canRestore ? .failure : .success
    }
    view.warpHostPointer = { _ in
      warps += 1
      return .success
    }
    defer {
      canRestore = true
      view.setRelativeMouseCapture(false)
      view.onDetach = nil
      window.contentView = nil
    }
    // Seed only the injected platform boundary. A hidden, off-Space fixture
    // cannot acquire from positive native eligibility or move the real cursor.
    window.controlledSpace = false
    view.relativeMouse = true
    #expect(window.makeFirstResponder(view))
    session.attach(view)
    view.onDetach = session.detach
    view.captured = true
    view.capturePending = true
    view.setRelativeMouseCapture(true)
    #expect(view.captured && view.capturePending && view.relativeMouseLocked)

    // AppKit may notify closure while its content view and stale key state
    // remain attached. Do not post resign-key or physically close a window.
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    #expect(view.window === window && window.firstResponder === view && window.isKeyWindow)
    #expect(!view.captured && !view.capturePending)
    #expect(associations == [false, true] && warps == 0)
    #expect(view.relativeMouseLocked == !restorationSucceeds)
    #expect(view.hostPointerCapture.restorationPending == !restorationSucceeds)
    if !restorationSucceeds {
      canRestore = true
      view.setRelativeMouseCapture(false)
      #expect(!view.relativeMouseLocked && !view.hostPointerCapture.restorationPending)
      #expect(associations == [false, true, true])
    }
  }

  private func fixture() -> (ForegroundInputWindow, RfbGuestView) {
    _ = NSApplication.shared
    let window = ForegroundInputWindow(
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
    view.useGuestCursor = true
    view.captured = true
    return (window, view)
  }

  private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: 32, y: 32), modifierFlags: [], timestamp: 10,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
  }
}
