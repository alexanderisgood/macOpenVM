// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

public enum VMState: String, CaseIterable, Codable, Sendable {
  case stopped, starting, running, pausing, paused, resuming, stopping
  case saving, suspended, restoring, failed
}

/// An explicit state machine with operation IDs to reject stale asynchronous completion.
public struct VMStateMachine: Sendable {
  public private(set) var state: VMState
  public private(set) var operationID: UUID?
  public private(set) var operation: LifecycleOperation?
  public init(state: VMState = .stopped) { self.state = state }

  public static func destination(from state: VMState, operation: LifecycleOperation) -> VMState? {
    switch (state, operation) {
    case (.stopped, .start): .starting
    case (.running, .pause): .pausing
    case (.paused, .resume): .resuming
    case (.running, .stop): .stopping
    case (.running, .forceStop), (.paused, .forceStop), (.failed, .forceStop),
      (.stopping, .forceStop):
      .stopping
    case (.paused, .suspend): .saving
    case (.suspended, .restore): .restoring
    default: nil
    }
  }

  @discardableResult
  public mutating func begin(_ operation: LifecycleOperation, id: UUID = UUID()) throws -> UUID {
    let supersedesShutdown =
      state == .stopping && self.operation == .stop && operation == .forceStop
    guard self.operationID == nil || supersedesShutdown,
      let next = Self.destination(from: state, operation: operation)
    else {
      throw VMError(
        .invalidTransition, "That operation is invalid in the current VM state.",
        recovery: "Wait for the current operation or inspect recovery status.")
    }
    state = next
    self.operation = operation
    operationID = id
    return id
  }

  public mutating func complete(id: UUID) throws {
    guard operationID == id, let operation else { throw stale() }
    switch operation {
    case .start, .resume, .restore: state = .running
    case .pause: state = .paused
    case .stop, .forceStop: state = .stopped
    case .suspend: state = .suspended
    }
    clearOperation()
  }

  public mutating func fail(id: UUID) throws {
    guard operationID == id else { throw stale() }
    state = .failed
    clearOperation()
  }

  /// Call only after the backend has actually stopped, including an unsolicited guest shutdown.
  public mutating func backendStopped() {
    state = .stopped
    clearOperation()
  }

  private mutating func clearOperation() {
    operation = nil
    operationID = nil
  }
  private func stale() -> VMError {
    VMError(
      .staleOperation, "An obsolete operation result was rejected.",
      recovery: "Inspect the current VM state.")
  }
}
