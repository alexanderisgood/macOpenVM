// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Capture preference survives focus changes; queued input never survives suspension.
struct GuestInputCapturePolicy {
  /// Bounded native event bursts may arrive faster than the paced USB keyboard.
  /// Physical focus/epoch checks still apply to each event as it leaves the queue.
  static let maximumPendingEvents = 4096
  private(set) var wanted: Bool
  private(set) var generation = UUID()

  init(automatic: Bool = false) { wanted = automatic }

  static func isForeground(applicationActive: Bool, keyWindow: Bool, onActiveSpace: Bool) -> Bool {
    applicationActive && keyWindow && onActiveSpace
  }

  mutating func request() { wanted = true }
  mutating func release() {
    wanted = false
    suspend()
  }
  mutating func suspend() { generation = UUID() }

  func permitsQueuedInput(_ token: UUID, captured: Bool, foreground: Bool) -> Bool {
    wanted && token == generation && captured && foreground
  }
}
