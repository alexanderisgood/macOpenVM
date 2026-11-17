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
  private static let rasterDelays: [Duration] = [.seconds(8), .seconds(20)]
  private var attempts = 0
  private var rasterAttempts = 0
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
    guard completedFrames < 120 else { return }
    completedFrames += 1
    if completedFrames == 120 {
      attempts = 0
      rasterAttempts = 0
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

  /// After the quick attempts, keep presenting standard display frames. The
  /// first new raster after each cooldown can retry the shared route. Quiet
  /// guests stay on the working display and never need a polling loop.
  mutating func retryDuringRasterDelivery(at now: ContinuousClock.Instant) -> Bool {
    guard attempts == Self.delays.count, rasterAttempts < Self.rasterDelays.count else {
      return false
    }
    eligibleAfter = now + Self.rasterDelays[rasterAttempts]
    rasterAttempts += 1
    return true
  }
}
