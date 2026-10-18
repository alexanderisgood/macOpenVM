// SPDX-License-Identifier: Apache-2.0
// Package-private diagnostic values; no endpoint, process or lifecycle authority.
package enum CaptureFault: Error, Equatable, Sendable {
  case malformed, limit, identity, stale, unavailable, busy, alreadyUsed, notReady
  case unknownOutcome, closed
}

package enum CaptureCapability: UInt8, Sendable { case boundedProducerV1 = 1 }

package enum CaptureCommand: Equatable, Sendable {
  case arm(UInt64)
  case status, stop
  case read(offset: UInt32, count: UInt16)
}

package enum CapturePhase: UInt32, Sendable {
  case disarmed, initializing, armed, stopping, entryContention, entryLimit, spent
}

package enum CaptureRejection: UInt16, Sendable {
  case invalid = 1
  case busy, alreadyUsed, notReady, notLockFree, ownerAdmission
  case captureRange, readRange
}

package struct CaptureStatus: Equatable, Sendable {
  package let capture: UInt64
  package let phase: CapturePhase
  package let records: UInt32
  package let reasons: UInt32
  package let cursor: UInt32
  package let terminal: Bool

  package init(
    capture: UInt64, phase: UInt32, records: UInt32, reasons: UInt32,
    cursor: UInt32, terminal: UInt32
  ) throws {
    guard let phase = CapturePhase(rawValue: phase), terminal <= 1,
      capture <= UInt64(Int64.max), records <= 4096, reasons <= 127, cursor <= records,
      (terminal == 1) == (phase == .spent)
    else { throw CaptureFault.malformed }
    if phase == .spent {
      guard capture > 0, records >= 2 else { throw CaptureFault.malformed }
    } else {
      guard records == 0, reasons == 0, cursor == 0,
        phase == .disarmed ? capture == 0 : capture > 0
      else { throw CaptureFault.malformed }
    }
    self.capture = capture
    self.phase = phase
    self.records = records
    self.reasons = reasons
    self.cursor = cursor
    self.terminal = terminal == 1
  }
}

package struct CaptureRow: Equatable, Sendable {
  package static let keys = [
    "index", "event", "flags", "capture", "operation", "parent",
    "stream-hi", "stream-lo", "generation", "sequence", "t0", "t1", "t2", "t3",
    "a", "b", "c", "d",
  ]
  package let words: [UInt64]
  package init(_ words: [UInt64]) throws {
    guard words.count == 18, words[0] < 4096, (1...10).contains(words[1]),
      Self.validFlags(words[2], event: words[1]), words[3] > 0, words[3] <= UInt64(Int64.max),
      words[4] == words[0] + 1, words[5] < words[4]
    else { throw CaptureFault.malformed }
    self.words = words
  }

  private static func validFlags(_ flags: UInt64, event: UInt64) -> Bool {
    guard event == 10 else { return flags <= 7 }
    // Fixed producer GPU_DIAGNOSTIC labels: 1 command-gap, 2 reply, 3 pending.
    // Only this event adds bits16–17 to the three common low flag bits.
    guard flags & ~UInt64(0x0003_0007) == 0 else { return false }
    return (1...3).contains(flags >> 16)
  }
}

package enum CaptureReply: Equatable, Sendable {
  case status(CaptureStatus)
  case rows([CaptureRow])
  case rejected(CaptureRejection)
}
