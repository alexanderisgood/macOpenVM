// SPDX-License-Identifier: Apache-2.0
// Worker retains one instance for its actual lifetime, not per IPC connection.
import BackendAPI
import Foundation

struct CapturePolicy {
  let binding: CaptureBinding
  let capability: CaptureCapability?
  private(set) var attached = false
  private(set) var closed = false
  private(set) var armAttempted = false
  private(set) var stopAttempted = false
  private(set) var pending: CaptureCommand?
  private(set) var snapshot: CaptureStatus?
  private(set) var cursor: UInt32 = 0
  private(set) var capture: UInt64 = 0
  private var nextRequest: UInt64 = 1
  private var statusCount = 0
  private var pageCount = 0
  private var attachmentID: UUID?

  init(binding: CaptureBinding, capability: CaptureCapability? = nil) {
    self.binding = binding
    self.capability = capability
  }

  func ownsAttachment(_ id: UUID) -> Bool { attachmentID == id }

  mutating func admit(
    _ request: CaptureWorkerRequest, connectionID: UUID, actualBinding: CaptureBinding,
    revision: UInt64, active: Bool, lifecyclePending: Bool
  ) throws
    -> CaptureCommand?
  {
    guard capability == .boundedProducerV1 else { throw CaptureFault.unavailable }
    guard !closed else { throw CaptureFault.closed }
    if let attachmentID, attachmentID != connectionID { throw CaptureFault.identity }
    guard actualBinding == binding, request.binding == binding else { throw CaptureFault.identity }
    guard active else { throw CaptureFault.unavailable }
    guard pending == nil, !lifecyclePending else { throw CaptureFault.busy }
    try request.validateShape()
    guard request.requestID == nextRequest else { throw CaptureFault.stale }
    if request.operation == .hello {
      guard !attached else { throw CaptureFault.alreadyUsed }
      attached = true
      attachmentID = connectionID  // Existing WorkerIPCServer acceptLoop UUID, never from wire.
      nextRequest += 1
      return nil
    }
    guard attached else { throw CaptureFault.notReady }
    guard revision > 0, request.observedRevision == revision else { throw CaptureFault.stale }
    let command: CaptureCommand
    switch request.operation {
    case .hello: throw CaptureFault.malformed
    case .arm:
      guard !armAttempted, snapshot?.phase == .disarmed else { throw CaptureFault.alreadyUsed }
      // Reserve before the first await or attempted QMP send. Never reset.
      armAttempted = true
      capture = request.capture
      command = .arm(capture)
    case .status:
      guard statusCount < 16, request.capture == capture else { throw CaptureFault.limit }
      statusCount += 1
      command = .status
    case .stop:
      guard armAttempted, !stopAttempted, request.capture == capture else {
        throw CaptureFault.alreadyUsed
      }
      stopAttempted = true
      command = .stop
    case .read:
      guard let snapshot, snapshot.terminal, request.capture == capture,
        request.offset == cursor, cursor < snapshot.records, pageCount < 64
      else { throw CaptureFault.notReady }
      pageCount += 1
      command = .read(offset: request.offset, count: request.count)
    }
    nextRequest += 1
    pending = command
    return command
  }

  mutating func complete(_ reply: CaptureReply) throws {
    guard !closed, let pending else { throw CaptureFault.closed }
    if case .rejected = reply {
      // Known rejection is a completed QMP envelope, not monitor failure.
      // It still ends this once-only diagnostic conversation.
      self.pending = nil
      closed = true
      return
    }
    do {
      switch (pending, reply) {
      case (.arm, .status(let value)), (.status, .status(let value)), (.stop, .status(let value)):
        guard value.capture == capture, value.cursor == cursor else { throw CaptureFault.malformed }
        if let old = snapshot, old.terminal {
          guard value.terminal, value.capture == old.capture, value.records == old.records,
            value.reasons == old.reasons
          else { throw CaptureFault.malformed }
        } else if let old = snapshot {
          guard value.phase.rawValue >= old.phase.rawValue else { throw CaptureFault.malformed }
        }
        if case .stop = pending {
          guard value.phase.rawValue >= CapturePhase.stopping.rawValue else {
            throw CaptureFault.malformed
          }
        }
        if armAttempted {
          guard value.phase != .disarmed, value.phase != .initializing else {
            throw CaptureFault.malformed
          }
        } else {
          guard value.phase == .disarmed else { throw CaptureFault.alreadyUsed }
        }
        snapshot = value
      case (.read(let offset, let count), .rows(let rows)):
        guard let old = snapshot, old.terminal, offset == cursor,
          rows.count == Int(min(UInt32(count), old.records - cursor))
        else {
          throw CaptureFault.malformed
        }
        for (position, row) in rows.enumerated() {
          let index = UInt64(cursor) + UInt64(position)
          guard row.words[0] == index, row.words[3] == capture else { throw CaptureFault.malformed }
          if index == 0 {
            guard row.words[1] == 1 else { throw CaptureFault.malformed }
          } else if index == UInt64(old.records - 1) {
            guard row.words[1] == 2, row.words[14] == UInt64(old.records),
              row.words[15] == UInt64(old.reasons)
            else { throw CaptureFault.malformed }
          } else {
            guard row.words[1] >= 3 else { throw CaptureFault.malformed }
          }
        }
        cursor += UInt32(rows.count)
        snapshot = try CaptureStatus(
          capture: old.capture, phase: old.phase.rawValue,
          records: old.records, reasons: old.reasons, cursor: cursor, terminal: 1)
      default: throw CaptureFault.malformed
      }
      self.pending = nil
    } catch {
      abandon()
      throw error
    }
  }

  // EOF, cancellation, wrong generation, output failure or unknown send outcome
  // closes only this diagnostic state. No protocol/lifecycle action is returned.
  mutating func abandon() {
    closed = true
    pending = nil
  }
}

// The actual coordinator reserves its operationPending/revision before this
// worker-owned session dispatches; ordinary lifecycle admission shares that gate.
// Accepted work has a worker-owned Task; cancellation of a waiter does not cancel it.
@MainActor final class CaptureOwnedSession {
  private(set) var policy: CapturePolicy
  private var operation: Task<Result<CaptureReply, CaptureFault>, Never>?
  private var attachmentClosed = false
  private(set) var diagnosticLost = false
  private var acceptedPending = false
  private let exchange:
    @MainActor @Sendable (CaptureCommand, CaptureStatus?, UInt64) async throws -> CaptureReply

  init(
    binding: CaptureBinding, capability: CaptureCapability? = nil,
    exchange:
      @escaping @MainActor @Sendable (CaptureCommand, CaptureStatus?, UInt64) async throws ->
      CaptureReply
  ) {
    policy = CapturePolicy(binding: binding, capability: capability)
    self.exchange = exchange
  }

  func handle(
    _ request: CaptureWorkerRequest, connectionID: UUID,
    actualBinding: CaptureBinding, revision: UInt64,
    active: Bool, lifecyclePending: Bool
  ) async throws -> CaptureReply? {
    let command = try prepare(
      request, connectionID: connectionID,
      actualBinding: actualBinding, revision: revision, active: active,
      lifecyclePending: lifecyclePending)
    return try await runPrepared(command)
  }

  // Synchronous reservation permits the real coordinator to reject a foreign
  // attachment/stale request without advancing the actual owner's revision.
  func prepare(
    _ request: CaptureWorkerRequest, connectionID: UUID,
    actualBinding: CaptureBinding, revision: UInt64,
    active: Bool, lifecyclePending: Bool
  ) throws -> CaptureCommand? {
    guard !attachmentClosed else { throw CaptureFault.closed }
    if policy.attached, !policy.ownsAttachment(connectionID) { throw CaptureFault.identity }
    guard operation == nil, !acceptedPending else { throw CaptureFault.busy }
    let command: CaptureCommand?
    do {
      command = try policy.admit(
        request, connectionID: connectionID,
        actualBinding: actualBinding, revision: revision,
        active: active, lifecyclePending: lifecyclePending)
    } catch {
      // An admitted peer's failure consumes its conversation; a rejected foreign
      // connection never cancels or closes the actual attached peer's operation.
      if policy.ownsAttachment(connectionID) {
        attachmentClosed = true
        policy.abandon()
      }
      throw error
    }
    acceptedPending = command != nil
    return command
  }

  func runPrepared(_ prepared: CaptureCommand?) async throws -> CaptureReply? {
    guard let command = prepared else { return nil }
    guard operation == nil, acceptedPending, policy.pending == command else {
      throw CaptureFault.busy
    }
    let task = Task { @MainActor [self] in
      do {
        let reply = try await exchange(command, policy.snapshot, policy.capture)
        try policy.complete(reply)
        return Result<CaptureReply, CaptureFault>.success(reply)
      } catch {
        diagnosticLost = true
        policy.abandon()
        return .failure((error as? CaptureFault) ?? .unknownOutcome)
      }
    }
    operation = task
    let result = await task.value
    // No cancellation check here: the accepted operation must finish recording
    // its outcome even when the IPC reader or its waiter has disappeared.
    operation = nil
    acceptedPending = false
    if attachmentClosed { policy.abandon() }
    return try result.get()
  }

  func attachmentEnded(connectionID: UUID, lostReply: Bool = false) {
    guard policy.ownsAttachment(connectionID) else { return }
    if lostReply || operation != nil || acceptedPending { diagnosticLost = true }
    attachmentClosed = true
    // A pending task still owns its reply/cursor commit. Do not mutate its state
    // under it or release it on EOF; close after it completes instead.
    if operation == nil, !acceptedPending { policy.abandon() }
  }

  func closeAdmission() {
    if operation != nil || acceptedPending { diagnosticLost = true }
    attachmentClosed = true
    if operation == nil, !acceptedPending { policy.abandon() }
  }
}
