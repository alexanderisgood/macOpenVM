// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import Testing

@testable import MacOpenVMApp

@MainActor @Suite(.serialized) struct GuestInputActivationAttemptTests {
  @Test func waitsForApplicationBeforeOrderingOwnedWindow() {
    let window = NSObject()
    let began = ContinuousClock.now
    var attempt = GuestInputActivationAttempt(
      capture: UUID(), window: window, applicationActive: false, now: began)
    let inactive = attempt.next(
      applicationActive: false, keyWindow: true, onActiveSpace: true, now: began)
    #expect(inactive == .wait)
    let activated = attempt.next(
      applicationActive: true, keyWindow: false, onActiveSpace: false, now: began)
    #expect(activated == .orderOwnedWindow)
    let settling = attempt.next(
      applicationActive: true, keyWindow: false, onActiveSpace: false, now: began)
    #expect(settling == .wait)
    let ready = attempt.next(
      applicationActive: true, keyWindow: true, onActiveSpace: true, now: began)
    #expect(ready == .ready)
  }

  @Test func intermediateWindowAndSpaceFactsCannotGrantCapture() {
    let began = ContinuousClock.now
    var attempt = GuestInputActivationAttempt(
      capture: UUID(), window: NSObject(), applicationActive: false, now: began)
    let inactive = attempt.observe(applicationActive: false, now: began)
    #expect(inactive)
    let activated = attempt.observe(applicationActive: true, now: began)
    #expect(activated)
    let order = attempt.next(
      applicationActive: true, keyWindow: false, onActiveSpace: false, now: began)
    #expect(order == .orderOwnedWindow)
    let offSpace = attempt.next(
      applicationActive: true, keyWindow: true, onActiveSpace: false, now: began)
    #expect(offSpace == .wait)
    let notKey = attempt.next(
      applicationActive: true, keyWindow: false, onActiveSpace: true, now: began)
    #expect(notKey == .wait)
    let ready = attempt.next(
      applicationActive: true, keyWindow: true, onActiveSpace: true, now: began)
    #expect(ready == .ready)
  }

  @Test func activeThenResignRevokesAttempt() {
    let began = ContinuousClock.now
    var attempt = GuestInputActivationAttempt(
      capture: UUID(), window: NSObject(), applicationActive: false, now: began)
    let activated = attempt.observe(applicationActive: true, now: began)
    #expect(activated)
    let resigned = attempt.observe(applicationActive: false, now: began)
    #expect(!resigned)
    let inactive = attempt.next(
      applicationActive: false, keyWindow: true, onActiveSpace: true, now: began)
    #expect(inactive == .cancel)
    let reactivated = attempt.next(
      applicationActive: true, keyWindow: true, onActiveSpace: true, now: began)
    #expect(reactivated == .cancel)
  }

  @Test func identityAndDeadlineRejectStaleOrReplacementRequests() {
    let window = NSObject()
    let replacement = NSObject()
    let capture = UUID()
    let began = ContinuousClock.now
    var attempt = GuestInputActivationAttempt(
      capture: capture, window: window, applicationActive: false, now: began)
    #expect(attempt.matches(capture: capture, window: window))
    #expect(!attempt.matches(capture: UUID(), window: window))
    #expect(!attempt.matches(capture: capture, window: replacement))
    #expect(!attempt.matches(capture: nil, window: window))
    #expect(!attempt.matches(capture: capture, window: nil))
    let expired = attempt.next(
      applicationActive: true, keyWindow: true, onActiveSpace: true, now: began + .seconds(2))
    #expect(expired == .cancel)
  }

  @Test func requestWindowOnlyOnceWhileNativeFactsSettle() {
    let began = ContinuousClock.now
    var attempt = GuestInputActivationAttempt(
      capture: UUID(), window: NSObject(), applicationActive: true, now: began)
    let order = attempt.next(
      applicationActive: true, keyWindow: false, onActiveSpace: false, now: began)
    #expect(order == .orderOwnedWindow)
    for tick in 1...10 {
      let settling = attempt.next(
        applicationActive: true, keyWindow: false, onActiveSpace: false,
        now: began + .milliseconds(tick * 20))
      #expect(settling == .wait)
    }
  }

  @Test func focusObserversUseCoordinatorAndFallbackSuspends() {
    _ = NSApplication.shared
    let window = ActivationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView()
    window.contentView = view
    defer { window.contentView = nil }
    var coordinated = 0
    var suspended = 0
    view.onPresentationFocusChanged = { coordinated += 1 }
    view.onSuspend = { suspended += 1 }
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(coordinated == 1 && suspended == 0)
    view.onPresentationFocusChanged = nil
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(coordinated == 1 && suspended == 1)
  }

  @Test func nativeKeyLossPreservesOnlyTheEmptyExplicitRequestUntilRelease() throws {
    let (window, view, session) = disconnectedFixture()
    defer { window.contentView = nil }
    let attempt = try #require(session.beginInputActivationForValidation(view))
    view.onPresentationFocusChanged = session.focusChanged
    view.onSuspend = session.suspendInput
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(session.hasInputActivationForValidation(attempt))
    #expect(!session.captured && !view.captured && !view.capturePending)
    session.releaseInput()
    #expect(!session.hasInputActivationForValidation(attempt))
  }

  @Test(arguments: [false, true])
  func sheetOrDetachRevokesThePendingRequest(detach: Bool) throws {
    let (window, view, session) = disconnectedFixture()
    defer { window.contentView = nil }
    let attempt = try #require(session.beginInputActivationForValidation(view))
    if detach {
      session.detach(view)
    } else {
      window.controlledSheet = NSWindow(
        contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
      session.focusChanged()
    }
    #expect(!session.hasInputActivationForValidation(attempt))
    #expect(!session.captured && !view.captured && !view.capturePending)
  }

  private func disconnectedFixture() -> (ActivationWindow, RfbGuestView, RfbLabSession) {
    _ = NSApplication.shared
    let window = ActivationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let capture = GuestHostPointerCapture()
    let view = RfbGuestView()
    view.hostPointerCapture = capture
    window.contentView = view
    return (window, view, RfbLabSession(hostPointerCapture: capture))
  }

  private final class ActivationWindow: NSWindow {
    var controlledSheet: NSWindow?
    override var isKeyWindow: Bool { false }
    override var isOnActiveSpace: Bool { false }
    override var attachedSheet: NSWindow? { controlledSheet }
  }
}
