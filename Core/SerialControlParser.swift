// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Same-process command intent only; a runtime owner must validate capability/state before acting.
public enum SerialHostCommand: Equatable, Sendable {
  case pause, resume, requestShutdown
  case forceStop(confirmationID: UInt64)
}

/// Guest bytes are an ephemeral forwarding payload. Descriptions never include their contents.
public enum SerialControlEvent: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  case guestBytes(Data)
  case menuOpened, menuClosed, unknownMenuCommand
  case request(SerialHostCommand)
  case forceConfirmationNeeded(UInt64)
  case forceConfirmationArmed(UInt64)
  case inputBarrierRequired, staleConfirmation
  case confirmationCancelled, confirmationExpired, confirmationRejected

  public var description: String {
    switch self {
    case .guestBytes: "serial.guest.bytes"
    case .menuOpened: "serial.host.menu.opened"
    case .menuClosed: "serial.host.menu.closed"
    case .unknownMenuCommand: "serial.host.menu.unknown-command"
    case .request(.pause): "serial.host.pause.requested"
    case .request(.resume): "serial.host.resume.requested"
    case .request(.requestShutdown): "serial.host.shutdown.requested"
    case .request(.forceStop): "serial.host.force-stop.confirmed"
    case .forceConfirmationNeeded: "serial.host.force-confirmation.barrier-needed"
    case .forceConfirmationArmed: "serial.host.force-confirmation.armed"
    case .inputBarrierRequired: "serial.host.force-confirmation.barrier-required"
    case .staleConfirmation: "serial.host.force-confirmation.stale"
    case .confirmationCancelled: "serial.host.force-confirmation.cancelled"
    case .confirmationExpired: "serial.host.force-confirmation.expired"
    case .confirmationRejected: "serial.host.force-confirmation.rejected"
    }
  }
  public var debugDescription: String { description }
}

/// The caller must retain and feed any unconsumed input; this batch is always bounded.
public struct SerialControlBatch: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let consumedBytes: Int
  public let events: [SerialControlEvent]
  public var description: String {
    "serial.control.batch consumed=\(consumedBytes) events=\(events.count)"
  }
  public var debugDescription: String { description }
}

/// Pure experimental parser. It does not read terminals, perform lifecycle operations or log input.
/// Runtime wiring must drain buffered input before acknowledging a force-confirmation barrier.
public struct SerialControlParser: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public enum Phase: String, Sendable {
    case guest, menu, awaitingInputBarrier, awaitingConfirmation, discardingConfirmation
  }
  public static let maximumInputBytes = 4096
  public static let maximumEvents = 16
  public static let maximumConfirmationBytes = 32
  public static let confirmationTimeoutMilliseconds: UInt64 = 10_000
  private static let confirmation = Array("FORCE STOP".utf8)
  private enum Mode: Sendable {
    case guest, menu
    case barrier(id: UInt64, deadline: UInt64)
    case confirmation(id: UInt64, deadline: UInt64, count: Int, matches: Bool)
    case discardLine
  }
  private var mode = Mode.guest
  private var lastTime: UInt64 = 0
  private var nextConfirmationID: UInt64 = 0
  private var swallowLineFeed = false
  public init() {}
  // Internal sequence injection makes exhaustion verifiable without billions of prompt cycles.
  init(nextConfirmationID: UInt64) { self.nextConfirmationID = nextConfirmationID }
  public var phase: Phase {
    switch mode {
    case .guest: .guest
    case .menu: .menu
    case .barrier: .awaitingInputBarrier
    case .confirmation: .awaitingConfirmation
    case .discardLine: .discardingConfirmation
    }
  }
  public var description: String { "serial.control.parser phase=\(phase.rawValue)" }
  public var debugDescription: String { description }

  /// Time is caller-supplied monotonic milliseconds. Regressions never extend an existing deadline.
  public mutating func advanceTime(to nowMilliseconds: UInt64) -> [SerialControlEvent] {
    lastTime = max(lastTime, nowMilliseconds)
    let deadline: UInt64
    switch mode {
    case .barrier(_, let value), .confirmation(_, let value, _, _): deadline = value
    default: return []
    }
    guard lastTime >= deadline else { return [] }
    mode = .discardLine
    return [.confirmationExpired]
  }

  /// Call only after discarding all already-buffered input and displaying the host warning.
  /// Bytes alone cannot arm confirmation. A stale completion never arms or resets a prompt;
  /// the supplied monotonic time still applies normal expiration to the current prompt.
  public mutating func completeInputBarrier(
    for confirmationID: UInt64, nowMilliseconds: UInt64
  ) -> [SerialControlEvent] {
    let expired = advanceTime(to: nowMilliseconds)
    guard case .barrier(let currentID, let deadline) = mode, currentID == confirmationID else {
      return expired + [.staleConfirmation]
    }
    mode = .confirmation(id: currentID, deadline: deadline, count: 0, matches: true)
    return [.forceConfirmationArmed(currentID)]
  }

  /// Cancellation closes host control without forwarding any buffered confirmation input.
  public mutating func cancelHostControl() -> [SerialControlEvent] {
    let wasConfirmation: Bool
    switch mode {
    case .guest: return []
    case .menu: wasConfirmation = false
    default: wasConfirmation = true
    }
    mode = .guest
    swallowLineFeed = false
    return wasConfirmation ? [.confirmationCancelled, .menuClosed] : [.menuClosed]
  }

  /// Ctrl-] opens the host menu; doubling it sends a literal Ctrl-] to the guest.
  /// Menu keys are p/r/s/f/c/?; Ctrl-C and Escape cancel host prompts. Outside the menu,
  /// all bytes, including Ctrl-C, pass through unchanged. Confirmation text is compared
  /// incrementally and is never stored. Invalid/expired lines are discarded through their newline.
  public mutating func consume(_ input: Data, nowMilliseconds: UInt64) -> SerialControlBatch {
    var events = advanceTime(to: nowMilliseconds)
    var guest = Data()
    var consumed = 0
    var discardRemainder = false
    for byte in input.prefix(Self.maximumInputBytes) {
      // Reserve room for a pending guest batch and at most two events from this byte.
      guard events.count <= Self.maximumEvents - 3 else { break }
      consumed += 1
      if swallowLineFeed {
        swallowLineFeed = false
        if byte == 0x0A { continue }
      }
      if discardRemainder { continue }
      switch mode {
      case .guest:
        if byte == 0x1D {
          if !guest.isEmpty {
            events.append(.guestBytes(guest))
            guest.removeAll(keepingCapacity: true)
          }
          mode = .menu
          events.append(.menuOpened)
        } else {
          guest.append(byte)
        }
      case .menu:
        switch byte {
        case 0x1D:
          mode = .guest
          events.append(.guestBytes(Data([0x1D])))
          events.append(.menuClosed)
        case 0x03, 0x1B, 0x63:
          mode = .guest
          events.append(.menuClosed)
          discardRemainder = true
        case 0x70: events.append(.request(.pause))
        case 0x72: events.append(.request(.resume))
        case 0x73: events.append(.request(.requestShutdown))
        case 0x3F: events.append(.menuOpened)
        case 0x66:
          let (id, overflow) = nextConfirmationID.addingReportingOverflow(1)
          let (deadline, deadlineOverflow) = lastTime.addingReportingOverflow(
            Self.confirmationTimeoutMilliseconds)
          if overflow || deadlineOverflow {
            events.append(.confirmationRejected)
          } else {
            nextConfirmationID = id
            mode = .barrier(id: id, deadline: deadline)
            events.append(.forceConfirmationNeeded(id))
          }
          discardRemainder = true
        case 0x0A, 0x0D: break
        default: events.append(.unknownMenuCommand)
        }
      case .barrier:
        if byte == 0x03 || byte == 0x1B {
          mode = .menu
          events.append(.confirmationCancelled)
          discardRemainder = true
        }
      case .confirmation(let id, let deadline, let count, let matches):
        if byte == 0x03 || byte == 0x1B || byte == 0x1D {
          mode = .menu
          events.append(.confirmationCancelled)
          discardRemainder = true
        } else if byte == 0x0A || byte == 0x0D {
          if matches && count == Self.confirmation.count {
            mode = .guest
            swallowLineFeed = byte == 0x0D
            events.append(.request(.forceStop(confirmationID: id)))
            events.append(.menuClosed)
          } else {
            mode = .menu
            events.append(.confirmationRejected)
          }
          discardRemainder = true
        } else if byte < 0x20 || byte > 0x7E || count >= Self.maximumConfirmationBytes {
          mode = .discardLine
          events.append(.confirmationRejected)
        } else {
          let matchesNext =
            matches && count < Self.confirmation.count
            && byte == Self.confirmation[count]
          mode = .confirmation(id: id, deadline: deadline, count: count + 1, matches: matchesNext)
        }
      case .discardLine:
        if byte == 0x0A || byte == 0x0D {
          mode = .menu
          discardRemainder = true
        } else if byte == 0x03 || byte == 0x1B {
          mode = .menu
          events.append(.confirmationCancelled)
          discardRemainder = true
        }
      }
    }
    if !guest.isEmpty { events.append(.guestBytes(guest)) }
    return SerialControlBatch(consumedBytes: consumed, events: events)
  }
}
