// SPDX-License-Identifier: Apache-2.0
import Foundation
import Qemu

/// First keystrokes remain in memory while this exact capture is being verified.
/// No guest input is delivered until fresh ownership and foreground checks pass.
struct GuestPendingKeyboardCapture {
  struct Identity: Equatable {
    let connection: UUID
    let frameEpoch: UUID
    let attempt: UUID
    let policyGeneration: UUID
  }

  private(set) var identity: Identity?
  private var strokes: [RFBKeyStroke] = []
  private let limit: Int

  init(limit: Int = GuestInputCapturePolicy.maximumPendingEvents) { self.limit = max(0, limit) }

  mutating func begin(_ identity: Identity) {
    cancel()
    self.identity = identity
  }

  mutating func append(_ stroke: RFBKeyStroke, for identity: Identity, foreground: Bool) -> Bool {
    guard self.identity == identity, foreground, strokes.count < limit else {
      cancel()
      return false
    }
    strokes.append(stroke)
    return true
  }

  mutating func finish(_ identity: Identity, verified: Bool, foreground: Bool) -> [RFBKeyStroke] {
    let admitted = self.identity == identity && verified && foreground ? strokes : []
    cancel()
    return admitted
  }

  mutating func cancel() {
    identity = nil
    strokes.removeAll(keepingCapacity: false)
  }
}
