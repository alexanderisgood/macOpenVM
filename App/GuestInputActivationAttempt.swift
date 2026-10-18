// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A bounded explicit focus request, never permission to deliver guest input.
/// App activation, window key status and Space membership can settle separately.
struct GuestInputActivationAttempt: Sendable {
  enum Action: Equatable { case wait, orderOwnedWindow, ready, cancel }
  let capture: UUID
  let window: ObjectIdentifier
  let deadline: ContinuousClock.Instant
  private var observedActive: Bool
  private var orderedWindow = false
  private var cancelled = false

  init(
    capture: UUID, window: AnyObject, applicationActive: Bool,
    now: ContinuousClock.Instant = .now
  ) {
    self.capture = capture
    self.window = ObjectIdentifier(window)
    deadline = now + .seconds(2)
    observedActive = applicationActive
  }

  func matches(capture: UUID?, window: AnyObject?) -> Bool {
    self.capture == capture && window.map(ObjectIdentifier.init) == self.window
  }

  /// Losing activation after it was observed revokes the request. Before that,
  /// an inactive notification can simply describe the still-pending handoff.
  mutating func observe(applicationActive: Bool, now: ContinuousClock.Instant = .now) -> Bool {
    guard !cancelled, now < deadline, applicationActive || !observedActive else {
      cancelled = true
      return false
    }
    observedActive = observedActive || applicationActive
    return true
  }

  mutating func next(
    applicationActive: Bool, keyWindow: Bool, onActiveSpace: Bool,
    now: ContinuousClock.Instant = .now
  ) -> Action {
    guard observe(applicationActive: applicationActive, now: now) else { return .cancel }
    guard applicationActive else { return .wait }
    if !orderedWindow {
      orderedWindow = true
      return .orderOwnedWindow
    }
    return keyWindow && onActiveSpace ? .ready : .wait
  }
}
