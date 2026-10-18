// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore

@testable import MacOpenVMApp
@testable import Qemu

@MainActor private final class PresentationSettingsWindow: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isOnActiveSpace: Bool { true }
}

/// Hidden native responders and public synthetic pixels only. Pointer effects
/// are injected; these tests do not post events, activate the app, connect a
/// display, construct a Metal renderer or start a VM.
@MainActor @Suite(.serialized) struct GuestPresentationSettingsTests {
  private let pixels = PixelSize(width: 17, height: 13)

  @Test func defaultPresentationKeepsFitAndUnchangedAssignmentsKeepTheActiveSample() {
    let settings = GuestPresentationSettings()
    let session = RfbLabSession()
    #expect(settings.scaling == .fit && !settings.sharpeningEnabled)
    #expect(session.presentationSettings == settings && !session.canSharpenPresentation)
    let (window, view, epoch) = fixture()
    defer { cleanUp(window, view) }
    let capture = makeCapture(epoch)
    view.beginTimingCapture(capture)
    var invalidations = 0
    view.onDisplayMeasurementInvalidated = { _ in invalidations += 1 }
    view.setPresentationSettings(settings)
    #expect(invalidations == 0 && capture.diagnostics().status == .sampling)
    capture.cancel()
  }

  @Test(arguments: [false, true])
  func changedPresentationCancelsTimingAndRestoresPointerBeforeChangingGeometry(
    sharpeningOnly: Bool
  ) throws {
    let (window, view, epoch) = fixture()
    defer { cleanUp(window, view) }
    let oldOnlyPoint = try oldFitOnlyPoint(in: view)
    let capture = makeCapture(epoch)
    view.beginTimingCapture(capture)
    try capture.receive(epoch: epoch, size: pixels, sequence: 2)
    let stale = try #require(capture.issue(epoch: epoch, size: pixels, sequence: 2))
    var changes: [String] = []
    view.onDisplayMeasurementInvalidated = { candidate in
      #expect(candidate === view && capture.diagnostics().status == .cancelled)
      #expect(view.relativeMouseLocked)
      changes.append("timing")
    }
    view.associateHostPointer = { restoring in
      guard restoring else { return .success }
      #expect(capture.diagnostics().status == .cancelled)
      // Restoration runs before installing the new mapping. This point is
      // inside ordinary fit but will become integer-scaling letterbox space.
      #expect(
        !view.cursor(at: oldOnlyPoint, applicationActive: true, keyWindow: true).isEqual(
          NSCursor.arrow))
      changes.append("restore")
      return .success
    }
    // Seed the injected platform lease directly, without positive native
    // capture eligibility or a real pointer warp.
    view.setRelativeMouseCapture(true)
    var settings = GuestPresentationSettings()
    if sharpeningOnly { settings.sharpeningEnabled = true } else { settings.scaling = .integer }
    view.setPresentationSettings(settings)
    #expect(changes == ["timing", "restore"] && !view.relativeMouseLocked)
    #expect(view.needsDisplay)
    #expect(
      view.cursor(at: oldOnlyPoint, applicationActive: true, keyWindow: true).isEqual(
        NSCursor.arrow)
        == !sharpeningOnly)
    stale.completed(success: true, hostTime: 1.1)
    stale.presented(hostTime: 1.2)
    let after = capture.diagnostics()
    #expect(after.status == .cancelled && after.drawn == 0 && after.presented == 0)
    view.onDisplayMeasurementInvalidated = nil
  }

  @Test func sessionChoiceSuspendsHeldInputBeforeTheNewViewportIsUsed() throws {
    let (window, view, epoch) = fixture()
    defer { cleanUp(window, view) }
    let session = RfbLabSession()
    session.attach(view)
    let oldOnlyPoint = try oldFitOnlyPoint(in: view)
    var buttons: [UInt8] = []
    view.onPointer = { _, value, _, _ in buttons.append(value) }
    view.mouseDown(with: try mouseEvent(.leftMouseDown, at: oldOnlyPoint, in: view))
    #expect(buttons == [1])
    let capture = makeCapture(epoch)
    view.beginTimingCapture(capture)
    var settings = GuestPresentationSettings()
    settings.scaling = .integer
    session.presentationSettings = settings
    #expect(!view.captured && !view.capturePending && !view.relativeMouseLocked)
    #expect(capture.diagnostics().status == .cancelled)
    view.captured = true
    #expect(
      view.cursor(at: oldOnlyPoint, applicationActive: true, keyWindow: true).isEqual(
        NSCursor.arrow))
    let viewport = try expectedViewport(view, scaling: .integer)
    let center = pixelCenter(x: 8, y: 6, viewport: viewport)
    view.mouseMoved(with: try mouseEvent(.mouseMoved, at: center, in: view))
    #expect(buttons == [1, 0])
  }

  @Test(arguments: GuestDisplayScaling.allCases)
  func motionButtonsWheelAndCursorAgreeWithTheBackingAwareViewport(
    scaling: GuestDisplayScaling
  ) throws {
    let (window, view, _) = fixture()
    defer { cleanUp(window, view) }
    var settings = GuestPresentationSettings()
    settings.scaling = scaling
    view.setPresentationSettings(settings)
    let viewport = try expectedViewport(view, scaling: scaling)
    let point = pixelCenter(x: 1, y: 2, viewport: viewport)
    var pointers: [GuestPixelPoint] = []
    var buttons: [UInt8] = []
    var scrolls: [GuestPixelPoint] = []
    view.onPointer = { guestPoint, held, _, _ in
      pointers.append(guestPoint)
      buttons.append(held)
    }
    view.onScroll = { guestPoint, _, _, _ in scrolls.append(guestPoint) }
    view.mouseMoved(with: try mouseEvent(.mouseMoved, at: point, in: view))
    view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: view))
    view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: view))
    view.scrollWheel(with: try wheelEvent(at: point, in: view))
    let guestPoint = GuestPixelPoint(x: 1, y: 2)
    #expect(pointers == [guestPoint, guestPoint, guestPoint] && buttons == [0, 1, 0])
    #expect(scrolls == [guestPoint])
    #expect(
      !view.cursor(at: point, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))

    let fit = viewport.fittedRect
    let letterbox: CGPoint
    if fit.minX > view.bounds.minX {
      letterbox = CGPoint(x: (fit.minX + view.bounds.minX) / 2, y: fit.midY)
    } else {
      try #require(fit.minY > view.bounds.minY)
      letterbox = CGPoint(x: fit.midX, y: (fit.minY + view.bounds.minY) / 2)
    }
    view.mouseMoved(with: try mouseEvent(.mouseMoved, at: letterbox, in: view))
    view.scrollWheel(with: try wheelEvent(at: letterbox, in: view))
    #expect(pointers.count == 3 && scrolls.count == 1)
    #expect(
      view.cursor(at: letterbox, applicationActive: true, keyWindow: true).isEqual(NSCursor.arrow))
    #expect(
      view.cursor(at: CGPoint(x: fit.maxX, y: fit.midY), applicationActive: true, keyWindow: true)
        .isEqual(NSCursor.arrow))
  }

  private func makeCapture(_ epoch: UUID) -> GuestFrameTimingCapture {
    GuestFrameTimingCapture(
      epoch: epoch, size: pixels, initialSequence: 1, presentationFeedback: true, origin: 0,
      clock: .init(now: { 1 }, schedule: { _, _ in }))
  }

  private func expectedViewport(_ view: RfbGuestView, scaling: GuestDisplayScaling) throws
    -> GuestViewport
  {
    try GuestViewport(
      viewBounds: view.bounds, guestPixels: pixels,
      backingBounds: view.convertToBacking(view.bounds),
      scaling: scaling)
  }

  private func oldFitOnlyPoint(in view: RfbGuestView) throws -> CGPoint {
    let fit = try expectedViewport(view, scaling: .fit).fittedRect
    let integer = try expectedViewport(view, scaling: .integer).fittedRect
    try #require(integer.minX > fit.minX)
    return CGPoint(x: (fit.minX + integer.minX) / 2, y: fit.midY)
  }

  private func pixelCenter(x: Int, y: Int, viewport: GuestViewport) -> CGPoint {
    CGPoint(
      x: viewport.fittedRect.minX + (CGFloat(x) + 0.5) * viewport.fittedRect.width
        / CGFloat(pixels.width),
      y: viewport.fittedRect.minY + (CGFloat(y) + 0.5) * viewport.fittedRect.height
        / CGFloat(pixels.height))
  }

  private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in view: RfbGuestView)
    throws
    -> NSEvent
  {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 10,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
  }

  private func wheelEvent(at point: CGPoint, in view: RfbGuestView) throws -> NSEvent {
    let location = view.convert(point, to: nil)
    let primary = try #require(NSScreen.screens.first)
    let cgEvent = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
    cgEvent.location = CGPoint(x: location.x, y: primary.frame.maxY - location.y)
    let event = try #require(NSEvent(cgEvent: cgEvent))
    #expect(event.type == .scrollWheel && event.scrollingDeltaY != 0)
    #expect(abs(event.locationInWindow.x - location.x) < 1e-9)
    #expect(abs(event.locationInWindow.y - location.y) < 1e-9)
    return event
  }

  private func fixture() -> (PresentationSettingsWindow, RfbGuestView, UUID) {
    _ = NSApplication.shared
    let window = PresentationSettingsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 67, height: 53), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 67, height: 53))
    view.hostPointerCapture = GuestHostPointerCapture()
    view.setHostCursor = { _ in }
    view.associateHostPointer = { _ in .success }
    view.warpHostPointer = { _ in .success }
    window.contentView = view
    let epoch = UUID()
    view.update(
      frame: RFBFrame(
        connectionEpoch: epoch, sequence: 1, size: pixels,
        rgbaData: Data(repeating: 0, count: pixels.width * pixels.height * 4)))
    view.useGuestCursor = true
    #expect(window.makeFirstResponder(view))
    view.captured = true
    return (window, view, epoch)
  }

  private func cleanUp(_ window: NSWindow, _ view: RfbGuestView) {
    view.onDisplayMeasurementInvalidated = nil
    view.capturePending = false
    view.captured = false
    view.setRelativeMouseCapture(false)
    view.associateHostPointer = { _ in .success }
    view.onPointer = nil
    view.onScroll = nil
    window.contentView = nil
  }
}
