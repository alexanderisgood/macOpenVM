// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bound consecutive transient failures without disabling recovery merely
/// because Windows changes its display after the boot window has elapsed.
struct SharedDisplayRecovery {
  struct FrameRequest {
    let retryDeadline: ContinuousClock.Instant?
    var incremental: Bool { retryDeadline == nil }
  }
  private static let delays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(3)]
  private var attempts = 0
  private var completedFrames = 0
  private var eligibleAfter: ContinuousClock.Instant?
  private var pendingRetryDeadline: ContinuousClock.Instant?

  func canAttempt(at now: ContinuousClock.Instant) -> Bool {
    eligibleAfter.map { now >= $0 } ?? true
  }

  /// Consume one bounded recovery request before waiting for another RFB update.
  /// A full refresh after backoff also completes when Windows pixels stay quiet.
  mutating func nextFrameRequest() -> FrameRequest {
    defer { pendingRetryDeadline = nil }
    return FrameRequest(retryDeadline: pendingRetryDeadline)
  }

  mutating func completedFrame() {
    completedFrames = min(completedFrames + 1, 120)
    if completedFrames == 120 {
      attempts = 0
      eligibleAfter = nil
      pendingRetryDeadline = nil
    }
  }

  mutating func transientFailure(at now: ContinuousClock.Instant) -> Bool {
    completedFrames = 0
    pendingRetryDeadline = nil
    guard attempts < Self.delays.count else { return false }
    eligibleAfter = now + Self.delays[attempts]
    pendingRetryDeadline = eligibleAfter
    attempts += 1
    return true
  }
}
