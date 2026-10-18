// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Testing

@testable import MacOpenVMApp
@testable import Qemu

@MainActor private final class PointerCaptureWindow: NSWindow {
  var controlledSpace = true
  override var isOnActiveSpace: Bool { controlledSpace }
  override var isKeyWindow: Bool { true }
}

@MainActor @Suite(.serialized) struct GuestHostPointerCaptureTests {
  @MainActor private final class Scheduler {
    var delays: [Int] = []
    var callbacks: [@MainActor @Sendable () -> Void] = []
    func schedule(_ delay: Int, _ action: @escaping @MainActor @Sendable () -> Void) {
      delays.append(delay)
      callbacks.append(action)
    }
    func fire() {
      guard !callbacks.isEmpty else { return }
      callbacks.removeFirst()()
    }
  }

  @MainActor private final class Effects {
    var canRestore = false
    var associations: [Bool] = []
    var warps = 0
    func associate(_ restoring: Bool) -> CGError {
      associations.append(restoring)
      return restoring && !canRestore ? .failure : .success
    }
  }

  @Test func detachedViewCanDieWhileRestorationCustodySurvives() {
    _ = NSApplication.shared
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    var canRestore = false
    var changes: [Bool] = []
    weak var witness: RfbGuestView?
    autoreleasepool {
      let view = RfbGuestView()
      witness = view
      view.hostPointerCapture = capture
      view.associateHostPointer = {
        changes.append($0)
        return $0 && !canRestore ? .failure : .success
      }
      view.setHostCursor = { _ in }
      window.contentView = view
      view.setRelativeMouseCapture(true)
      window.contentView = nil
      #expect(view.relativeMouseLocked && capture.restorationPending)
    }
    #expect(witness == nil)
    #expect(capture.restorationPending && scheduler.delays == [16])
    canRestore = true
    scheduler.fire()
    #expect(!capture.restorationPending && changes == [false, true, true])
  }

  @Test func staleRetryCannotReleaseANewCapture() {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let old = UUID()
    let replacement = UUID()
    var canRestore = false
    var oldCalls = 0
    var newCalls = 0
    #expect(
      capture.acquire(for: old) { restore in
        oldCalls += 1
        return restore && !canRestore ? .failure : .success
      })
    capture.restore(for: old)
    canRestore = true
    capture.retryPendingRestoration()
    #expect(
      capture.acquire(for: replacement) { _ in
        newCalls += 1
        return .success
      })
    let before = oldCalls
    scheduler.fire()
    capture.retryPendingRestoration()
    #expect(capture.isCaptured(by: replacement) && oldCalls == before && newCalls == 1)
    capture.restore(for: replacement)
  }

  @Test func exhaustedBudgetRetainsCustodyAndRejectsAnotherOwnerUntilExplicitRecovery() {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let owner = UUID()
    let other = UUID()
    var canRestore = false
    var calls = 0
    #expect(
      capture.acquire(for: owner) { restore in
        calls += 1
        return restore && !canRestore ? .failure : .success
      })
    capture.restore(for: owner)
    for _ in 0..<5 { scheduler.fire() }
    #expect(scheduler.delays == [16, 50, 150, 500, 1000])
    #expect(scheduler.callbacks.isEmpty && capture.isCaptured(by: owner))
    #expect(capture.restorationPending && !capture.canAcquire(for: other))
    var unexpectedCalls = 0
    #expect(
      !capture.acquire(for: other) { _ in
        unexpectedCalls += 1
        return .success
      })
    capture.restore(for: owner, retryPending: false)
    #expect(calls == 7 && unexpectedCalls == 0 && scheduler.callbacks.isEmpty)
    canRestore = true
    capture.retryPendingRestoration()
    #expect(!capture.isCaptured(by: owner) && !capture.restorationPending)
    #expect(capture.canAcquire(for: other))
  }

  @Test func anotherViewIsRejectedBeforeWarpOrAssociation() {
    _ = NSApplication.shared
    let capture = GuestHostPointerCapture()
    let owner = UUID()
    #expect(capture.acquire(for: owner) { _ in .success })
    let view = RfbGuestView()
    view.hostPointerCapture = capture
    view.setHostCursor = { _ in }
    var associations = 0
    var warps = 0
    var releases = 0
    view.associateHostPointer = { _ in
      associations += 1
      return .success
    }
    view.warpHostPointer = { _ in
      warps += 1
      return .success
    }
    view.onRelease = { releases += 1 }
    let window = attach(view)
    defer { window.contentView = nil }
    view.relativeMouse = true
    view.captured = true
    view.updateRelativeMouseLock(applicationActive: true)
    #expect(!view.relativeMouseLocked && releases >= 1 && associations == 0 && warps == 0)
    capture.restore(for: owner)
  }

  @Test func theSameViewCannotRecaptureWhileItsRestorationIsPending() {
    _ = NSApplication.shared
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let view = RfbGuestView()
    view.hostPointerCapture = capture
    view.setHostCursor = { _ in }
    var canRestore = false
    var associations = 0
    var warps = 0
    var releases = 0
    view.associateHostPointer = { restore in
      associations += 1
      return restore && !canRestore ? .failure : .success
    }
    view.warpHostPointer = { _ in
      warps += 1
      return .success
    }
    let window = attach(view)
    defer {
      canRestore = true
      view.setRelativeMouseCapture(false)
      window.contentView = nil
    }
    view.setRelativeMouseCapture(true)
    view.setRelativeMouseCapture(false)
    #expect(view.relativeMouseLocked && capture.restorationPending)
    view.onRelease = { [weak view] in
      releases += 1
      view?.captured = false
    }
    let before = associations
    view.relativeMouse = true
    view.captured = true
    view.updateRelativeMouseLock(applicationActive: true)
    #expect(!view.captured && releases >= 1 && warps == 0 && associations == before)
  }

  @Test func pendingRelativeRestorationRefusesAbsoluteRecaptureAndPointerDeliveryUntilRecovered()
    throws
  {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let effects = Effects()
    let view = injectedView(capture: capture, effects: effects)
    let window = attach(view)
    defer { cleanUp(view, window: window, effects: effects) }
    seedRelativeLease(view, in: window)
    // Mouse-mode changes release the old capture before changing the device.
    view.captured = false
    #expect(capture.restorationPending && view.relativeMouseLocked)
    view.relativeMouse = false
    window.controlledSpace = true
    var releases = 0
    view.onRelease = { [weak view] in
      releases += 1
      view?.captured = false
      view?.capturePending = false
    }
    var buttons: [UInt8] = []
    view.onPointer = { _, held, _, _ in buttons.append(held) }
    // Model the real capture commit through its actual view setter. No admitted
    // session or host activation is manufactured by this private fixture.
    view.captured = true
    view.mouseDown(with: try mouseDown())
    #expect(!view.captured)
    #expect(releases >= 1)
    #expect(buttons.isEmpty)
    #expect(capture.restorationPending && view.relativeMouseLocked)
    #expect(effects.associations == [false, true] && effects.warps == 0)

    // A successful injected restoration must permit a fresh Desktop Mouse
    // capture, rather than permanently suppressing the recovered view.
    view.captured = false
    effects.canRestore = true
    view.setRelativeMouseCapture(false)
    #expect(!capture.restorationPending && !view.relativeMouseLocked)
    buttons.removeAll()
    view.captured = true
    view.mouseDown(with: try mouseDown())
    #expect(view.captured && buttons == [1])
    #expect(effects.associations == [false, true, true] && effects.warps == 0)
  }

  @Test(arguments: [false, true])
  func replacementAbsoluteViewCannotUseAnotherViewsActiveOrPendingPointerLease(
    restorationPending: Bool
  ) throws {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let oldEffects = Effects()
    let old = injectedView(capture: capture, effects: oldEffects)
    let oldWindow = attach(old)
    defer { cleanUp(old, window: oldWindow, effects: oldEffects) }
    seedRelativeLease(old, in: oldWindow)
    if restorationPending { old.captured = false }
    #expect(old.relativeMouseLocked && capture.restorationPending == restorationPending)
    let oldAssociations = oldEffects.associations

    let effects = Effects()
    let view = injectedView(capture: capture, effects: effects)
    let window = attach(view)
    defer { cleanUp(view, window: window, effects: effects) }
    var releases = 0
    view.onRelease = { [weak view] in
      releases += 1
      view?.captured = false
      view?.capturePending = false
    }
    var buttons: [UInt8] = []
    view.onPointer = { _, held, _, _ in buttons.append(held) }
    view.captured = true
    view.mouseDown(with: try mouseDown())
    #expect(!view.captured)
    #expect(releases >= 1)
    #expect(buttons.isEmpty)
    // Refusing the replacement must not release a legitimate foreign owner or
    // silently reset its pending restoration budget.
    #expect(old.relativeMouseLocked && capture.restorationPending == restorationPending)
    #expect(oldEffects.associations == oldAssociations)
    #expect(effects.associations.isEmpty && effects.warps == 0 && oldEffects.warps == 0)

    view.captured = false
    oldEffects.canRestore = true
    old.captured = false
    old.setRelativeMouseCapture(false)
    #expect(!old.relativeMouseLocked && !capture.restorationPending)
    buttons.removeAll()
    view.captured = true
    view.mouseDown(with: try mouseDown())
    #expect(view.captured && buttons == [1] && effects.associations.isEmpty && effects.warps == 0)
  }

  @Test func relativeToAbsoluteTransitionReleasesCaptureWhenReassociationActuallyFails() throws {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let effects = Effects()
    let view = injectedView(capture: capture, effects: effects)
    let window = attach(view)
    defer { cleanUp(view, window: window, effects: effects) }
    seedRelativeLease(view, in: window)
    window.controlledSpace = true
    var releases = 0
    view.onRelease = { [weak view] in
      releases += 1
      view?.captured = false
      view?.capturePending = false
    }
    var buttons: [UInt8] = []
    view.onPointer = { _, held, _, _ in buttons.append(held) }
    // Unlike the ordinary mode command, this directly exercises the view's
    // transition while it still owns capture, without a prior session release.
    view.relativeMouse = false
    view.mouseDown(with: try mouseDown())
    #expect(!view.captured)
    #expect(releases >= 1)
    #expect(buttons.isEmpty)
    #expect(capture.restorationPending && view.relativeMouseLocked)
    #expect(effects.associations == [false, true] && effects.warps == 0)

    view.captured = false
    effects.canRestore = true
    view.setRelativeMouseCapture(false)
    #expect(!capture.restorationPending && !view.relativeMouseLocked)
    buttons.removeAll()
    view.captured = true
    view.mouseDown(with: try mouseDown())
    #expect(view.captured && buttons == [1] && effects.associations == [false, true, true])
  }

  @Test func relativeMotionCannotEscapeAfterPendingRestorationReleasesCapture() throws {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let effects = Effects()
    let view = injectedView(capture: capture, effects: effects)
    let window = attach(view)
    defer { cleanUp(view, window: window, effects: effects) }
    seedRelativeLease(view, in: window)
    // Preserve logical capture while the injected lower-level restoration fails.
    // The next actual motion ingress must revoke capture and then stop before
    // treating a retained physical lease as permission to send relative input.
    view.setRelativeMouseCapture(false)
    #expect(view.captured && view.relativeMouseLocked && capture.restorationPending)
    window.controlledSpace = true
    var releases = 0
    view.onRelease = { [weak view] in
      releases += 1
      view?.captured = false
      view?.capturePending = false
    }
    var callbacks = 0
    view.onRelativePointer = { _, _, _, _ in callbacks += 1 }
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: NSPoint(x: 32, y: 32), modifierFlags: [], timestamp: 10,
        windowNumber: 0, context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
    view.mouseMoved(with: event)
    #expect(!view.captured)
    #expect(releases >= 1)
    #expect(callbacks == 0)
    #expect(view.relativeMouseLocked && capture.restorationPending)
    // Event handling must neither re-arm the pending platform boundary
    // nor warp the host pointer as part of refusing the event.
    #expect(effects.associations == [false, true] && effects.warps == 0)
    #expect(scheduler.delays == [16] && scheduler.callbacks.count == 1)
  }

  @Test(arguments: [false, true])
  func passiveRefusalExplainsRecoveryWithoutChangingForeignPointerCustody(
    restorationPending: Bool
  ) {
    let applicationBefore: NSApplication? = NSApp
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let owner = UUID()
    var associations: [Bool] = []
    var canRestore = false
    #expect(
      capture.acquire(for: owner) { restoring in
        associations.append(restoring)
        return restoring && !canRestore ? .failure : .success
      })
    defer {
      canRestore = true
      capture.restore(for: owner)
    }
    if restorationPending { capture.restore(for: owner) }
    let before = associations
    let delays = scheduler.delays
    let pendingCallbacks = scheduler.callbacks.count
    let session = RfbLabSession(hostPointerCapture: capture)
    session.rejectUnavailableHostPointerCapture()
    #expect(!session.captured && capture.isCaptured(by: owner))
    #expect(capture.restorationPending == restorationPending)
    #expect(associations == before)
    #expect(scheduler.delays == delays && scheduler.callbacks.count == pendingCallbacks)
    #expect(NSApp === applicationBefore)
    let expected =
      restorationPending
      ? "Mouse restoration blocked input capture. Choose Release Input, then capture again."
      : "Another VM window blocked mouse capture. Release its input, then capture this window."
    #expect(session.message == expected)
  }

  @Test func actualSessionPassiveRefusalPreservesRetriesWhileExplicitReleaseCanRecover() {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let effects = Effects()
    let view = injectedView(capture: capture, effects: effects)
    let window = attach(view)
    let session = RfbLabSession(hostPointerCapture: capture)
    defer {
      session.detach(view)
      cleanUp(view, window: window, effects: effects)
    }
    var refusals = 0
    view.onCaptureRefused = {
      refusals += 1
      session.rejectUnavailableHostPointerCapture()
    }
    view.onRelease = session.releaseInput
    session.attach(view)
    seedRelativeLease(view, in: window)
    view.captured = false
    view.relativeMouse = false
    #expect(view.relativeMouseLocked && capture.restorationPending)
    #expect(effects.associations == [false, true])
    #expect(scheduler.delays == [16] && scheduler.callbacks.count == 1)

    window.controlledSpace = true
    view.capturePending = true
    view.captured = true
    #expect(refusals == 1)
    #expect(
      session.message
        == "Mouse restoration blocked input capture. Choose Release Input, then capture again.")
    #expect(!view.captured && !view.capturePending && !session.captured)
    #expect(view.relativeMouseLocked && capture.restorationPending)
    // This is the real ordinary session callback, with the same private
    // controller dependency as its attached view. A passive refusal must not
    // call the copied platform association or reset its scheduled retry.
    #expect(effects.associations == [false, true] && effects.warps == 0)
    #expect(scheduler.delays == [16] && scheduler.callbacks.count == 1)

    session.releaseInput()
    #expect(effects.associations == [false, true, true])
    #expect(view.relativeMouseLocked && capture.restorationPending)
    #expect(scheduler.delays == [16, 16] && scheduler.callbacks.count == 2)
    // The first ticket predates the explicit retry and must be harmless.
    scheduler.fire()
    #expect(effects.associations == [false, true, true] && capture.restorationPending)
    effects.canRestore = true
    session.releaseInput()
    #expect(effects.associations == [false, true, true, true])
    #expect(!view.relativeMouseLocked && !capture.restorationPending)
    scheduler.fire()
    #expect(effects.associations == [false, true, true, true] && effects.warps == 0)
  }

  @Test(
    arguments: [false, true],
    [
      "captured mouse", "captured scroll", "captured key", "pending mouse", "pending scroll",
      "pending key", "both mouse",
    ])
  func aLateForeignLeaseRevokesExistingAbsoluteCaptureOrPendingInput(
    restorationPending: Bool, ingress: String
  ) throws {
    let scheduler = Scheduler()
    let capture = GuestHostPointerCapture(schedule: scheduler.schedule)
    let effects = Effects()
    let view = injectedView(capture: capture, effects: effects)
    let window = attach(view)
    defer { cleanUp(view, window: window, effects: effects) }
    let pendingOnly = ingress.hasPrefix("pending ")
    view.captured = !pendingOnly
    view.capturePending = pendingOnly || ingress.hasPrefix("both ")
    // The absolute view obtained its logical state while custody was free.
    // Neither setter is touched after the late foreign lease appears.
    #expect(view.captured || view.capturePending)
    let foreignEffects = Effects()
    let foreign = injectedView(capture: capture, effects: foreignEffects)
    let foreignWindow = attach(foreign)
    defer { cleanUp(foreign, window: foreignWindow, effects: foreignEffects) }
    seedRelativeLease(foreign, in: foreignWindow)
    if restorationPending { foreign.captured = false }
    #expect(foreign.relativeMouseLocked && capture.restorationPending == restorationPending)
    #expect(view.captured == !pendingOnly)
    #expect(view.capturePending == (pendingOnly || ingress.hasPrefix("both ")))
    let associations = foreignEffects.associations
    let delays = scheduler.delays
    let tickets = scheduler.callbacks.count
    var refusals = 0
    var callbacks = 0
    var captureRequests = 0
    view.onCaptureRefused = { refusals += 1 }
    view.onCapture = { captureRequests += 1 }
    view.onPointer = { _, _, _, _ in callbacks += 1 }
    view.onScroll = { _, _, _, _ in callbacks += 1 }
    view.onKey = { _, _ in callbacks += 1 }
    try deliverAbsoluteInput(ingress, to: view)
    #expect(refusals == 1)
    #expect(!view.captured && !view.capturePending)
    #expect(callbacks == 0 && captureRequests == 0)
    #expect(foreign.relativeMouseLocked && capture.restorationPending == restorationPending)
    #expect(foreignEffects.associations == associations && foreignEffects.warps == 0)
    #expect(scheduler.delays == delays && scheduler.callbacks.count == tickets)
    #expect(effects.associations.isEmpty && effects.warps == 0)

    foreignEffects.canRestore = true
    foreign.captured = false
    foreign.setRelativeMouseCapture(false)
    #expect(!foreign.relativeMouseLocked && !capture.restorationPending)
    view.captured = true
    try deliverAbsoluteInput(ingress, to: view)
    #expect(view.captured && callbacks == 1 && captureRequests == 0)
    // A previously scheduled foreign ticket must not revoke recovered input.
    scheduler.fire()
    #expect(view.captured && !capture.restorationPending)
    #expect(effects.associations.isEmpty && effects.warps == 0 && foreignEffects.warps == 0)
  }

  private func deliverAbsoluteInput(_ ingress: String, to view: RfbGuestView) throws {
    if ingress.hasSuffix(" mouse") {
      view.mouseDown(with: try mouseDown())
    } else if ingress.hasSuffix(" scroll") {
      let cgEvent = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
          wheel1: 1, wheel2: 0, wheel3: 0))
      cgEvent.flags = []
      let primary = try #require(NSScreen.screens.first)
      cgEvent.location = CGPoint(x: 32, y: primary.frame.maxY - 32)
      let event = try #require(NSEvent(cgEvent: cgEvent))
      #expect(event.type == .scrollWheel && event.scrollingDeltaY != 0)
      #expect(event.locationInWindow == NSPoint(x: 32, y: 32))
      view.scrollWheel(with: event)
    } else {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 10,
          windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
          isARepeat: false, keyCode: 13))
      view.keyDown(with: event)
    }
  }

  private func injectedView(capture: GuestHostPointerCapture, effects: Effects) -> RfbGuestView {
    _ = NSApplication.shared
    let view = RfbGuestView()
    view.hostPointerCapture = capture
    view.setHostCursor = { _ in }
    view.associateHostPointer = { effects.associate($0) }
    view.warpHostPointer = { _ in
      effects.warps += 1
      return .success
    }
    return view
  }

  private func seedRelativeLease(_ view: RfbGuestView, in window: PointerCaptureWindow) {
    window.controlledSpace = false
    view.relativeMouse = true
    view.captured = true
    // Seed only the injected platform boundary. Positive native eligibility is
    // deliberately excluded, so no host activation or pointer warp is involved.
    view.setRelativeMouseCapture(true)
    #expect(view.relativeMouseLocked)
  }

  private func cleanUp(_ view: RfbGuestView, window: NSWindow, effects: Effects) {
    effects.canRestore = true
    view.onRelease = nil
    view.captured = false
    view.setRelativeMouseCapture(false)
    window.contentView = nil
  }

  private func mouseDown() throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 32, y: 32), modifierFlags: [], timestamp: 10,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
  }

  private func attach(_ view: RfbGuestView) -> PointerCaptureWindow {
    let window = PointerCaptureWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 64, height: 64)
    window.contentView = view
    view.update(
      frame: RFBFrame(
        connectionEpoch: UUID(), sequence: 1, size: PixelSize(width: 2, height: 2),
        rgbaData: Data(repeating: 0, count: 16)))
    #expect(window.makeFirstResponder(view))
    return window
  }
}
