// SPDX-License-Identifier: Apache-2.0

/// Finite delayed attempts for one static cache. Only new content, redraw or
/// renewed activity starts another budget; cancelled tickets cannot revive it.
struct SharedDrawableRetryPolicy: Sendable {
  struct Ticket: Equatable, Sendable {
    fileprivate let generation: UInt64
    let delayMS: Int
  }
  private static let delays = [16, 50, 150]
  private var generation: UInt64 = 0
  private var attempts = 0

  mutating func reset() {
    generation &+= 1
    attempts = 0
  }

  mutating func cancel() {
    generation &+= 1
    attempts = Self.delays.count
  }

  mutating func next() -> Ticket? {
    guard attempts < Self.delays.count else { return nil }
    let ticket = Ticket(generation: generation, delayMS: Self.delays[attempts])
    attempts += 1
    return ticket
  }

  func isCurrent(_ ticket: Ticket) -> Bool { ticket.generation == generation }
}
