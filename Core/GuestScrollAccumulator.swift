// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Converts finite AppKit wheel deltas to bounded vertical wheel detents.
/// Precise trackpad deltas accumulate in logical points; release resets the carry.
public struct GuestScrollAccumulator: Sendable {
  private var remainder = 0.0
  private var precise: Bool?
  public init() {}

  public mutating func consume(verticalDelta: Double, precise: Bool) -> Int {
    guard verticalDelta.isFinite, abs(verticalDelta) <= 10_000 else {
      reset()
      return 0
    }
    if self.precise != precise { remainder = 0 }
    self.precise = precise
    let amount = verticalDelta / (precise ? 20 : 1)
    let total = max(-8, min(8, remainder + amount))
    let steps = Int(total.rounded(.towardZero))
    remainder = total - Double(steps)
    return steps
  }

  public mutating func reset() {
    remainder = 0
    precise = nil
  }
}
