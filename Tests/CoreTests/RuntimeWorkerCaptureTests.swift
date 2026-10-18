// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import RuntimeIPC
import Testing
import VMStorage

@testable import VMCore

@MainActor private final class WorkerCaptureProbe {
  var actual: CaptureBinding?
  var commands: [CaptureCommand] = []
  var records: UInt32 = 2
  var cursor: UInt32 = 0
  var armed = false
  var spent = false
  var failArm = false
  var rejection: CaptureRejection?
  var gateArm = false
  var gateRead = false
  var entered = false
  private var gate: CheckedContinuation<Void, Never>?
  private var released = false
  func release() {
    released = true
    gate?.resume()
    gate = nil
  }
  func waitEntered() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !entered {
      guard ContinuousClock.now < deadline else { throw CaptureFault.notReady }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
  func exchange(_ command: CaptureCommand, terminal: CaptureStatus?, capture: UInt64)
    async throws -> CaptureReply
  {
    commands.append(command)
    let waits: Bool
    switch command {
    case .arm: waits = gateArm
    case .read: waits = gateRead
    default: waits = false
    }
    if waits {
      entered = true
      if !released { await withCheckedContinuation { gate = $0 } }
    }
    if let rejection { return .rejected(rejection) }
    switch command {
    case .arm:
      if failArm { throw CaptureFault.unknownOutcome }
      armed = true
    case .stop: spent = true
    case .read(let offset, let count):
      guard let terminal, terminal.cursor == cursor, offset == cursor else {
        throw CaptureFault.malformed
      }
      let end = cursor + min(UInt32(count), records - cursor)
      let rows = try (cursor..<end).map { index in
        var words = [UInt64](repeating: 0, count: 18)
        words[0] = UInt64(index)
        words[1] = index == 0 ? 1 : index == records - 1 ? 2 : 3
        words[3] = capture
        words[4] = UInt64(index) + 1
        if index == 0 {
          words[14] = 4096
          words[15] = 144
        }
        if index == records - 1 {
          words[14] = UInt64(records)
          words[15] = 1
        }
        return try CaptureRow(words)
      }
      cursor = end
      return .rows(rows)
    case .status: break
    }
    return .status(
      try CaptureStatus(
        capture: armed ? capture : 0,
        phase: spent ? 6 : armed ? 2 : 0, records: spent ? records : 0,
        reasons: spent ? 1 : 0, cursor: spent ? cursor : 0, terminal: spent ? 1 : 0))
  }
}

@MainActor private func withWorkerCapture(
  configured: Bool = true,
  body: (
    RuntimeWorkerCoordinator, WorkerCaptureProbe, CaptureBinding, RecordedRuntimeOwner,
    RecordedFixtureBackend
  ) async throws -> Void
) async throws {
  let (directory, vmID, lock, backend, owner) = try await recordedFixture()
  let coordinator = RuntimeWorkerCoordinator(owner: owner)
  let probe = WorkerCaptureProbe()
  await coordinator.start()
  let binding = CaptureBinding(vmID: vmID, sessionID: owner.sessionID, monitorEpoch: UUID())
  probe.actual = binding
  let result: Result<Void, Error>
  do {
    if configured {
      try coordinator.configureProducerCapture(
        binding: binding, capability: .boundedProducerV1,
        actualBinding: { probe.actual },
        exchange: { try await probe.exchange($0, terminal: $1, capture: $2) })
    }
    try await body(coordinator, probe, binding, owner, backend)
    result = .success(())
  } catch { result = .failure(error) }
  // Synthetic backend quiescence only, no process/guest stop helper.
  let cleanup: Result<Void, Error>
  do {
    backend.runtimeExit()
    await owner.controller.finishPersistence()
    if owner.ownershipState != .settled { try await owner.settleOwnership() }
    withExtendedLifetime(lock) {}
    try FileManager.default.removeItem(at: directory)
    cleanup = .success(())
  } catch { cleanup = .failure(error) }
  try result.get()
  try cleanup.get()
}

private func captureRequest(
  _ binding: CaptureBinding, _ id: UInt64,
  _ operation: CaptureWorkerOperation, revision: UInt64 = 0,
  capture: UInt64 = 0, offset: UInt32 = 0, count: UInt16 = 0
)
  -> CaptureWorkerRequest
{
  CaptureWorkerRequest(
    binding: binding, requestID: id, observedRevision: revision,
    operation: operation, capture: capture, offset: offset, count: count)
}

@Suite(.serialized) @MainActor struct RuntimeWorkerCaptureTests {
  @Test func synchronousClaimSurvivesDisconnectBeforeTheAcceptedTaskStarts() async throws {
    // Explicit modeled binding; this seam does not verify resources or start a VM.
    let binding = CaptureBinding(vmID: UUID(), sessionID: UUID(), monitorEpoch: UUID())
    let connection = UUID()
    let probe = WorkerCaptureProbe()
    let session = CaptureOwnedSession(
      binding: binding, capability: .boundedProducerV1,
      exchange: { try await probe.exchange($0, terminal: $1, capture: $2) })
    _ = try await session.handle(
      captureRequest(binding, 1, .hello), connectionID: connection,
      actualBinding: binding, revision: 7, active: true, lifecyclePending: false)
    _ = try await session.handle(
      captureRequest(binding, 2, .status, revision: 7), connectionID: connection,
      actualBinding: binding, revision: 7, active: true, lifecyclePending: false)
    let reserved = try session.prepare(
      captureRequest(binding, 3, .arm, revision: 7, capture: 17),
      connectionID: connection, actualBinding: binding, revision: 7, active: true,
      lifecyclePending: false)
    session.attachmentEnded(connectionID: connection)
    let committed = try await session.runPrepared(reserved)
    let expected = try CaptureStatus(
      capture: 17, phase: 2, records: 0,
      reasons: 0, cursor: 0, terminal: 0)
    #expect(committed == .status(expected))
    #expect(session.policy.armAttempted && session.policy.closed && session.diagnosticLost)
    #expect(probe.commands == [.status, .arm(17)])
  }
  @Test func defaultCoordinatorHasNoCaptureAuthorityAndKeepsV1Status() async throws {
    try await withWorkerCapture(configured: false) { coordinator, probe, binding, _, _ in
      let before = coordinator.revision
      let reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello),
        connectionID: UUID())
      #expect(
        reply.code == .unavailable && coordinator.revision == before && probe.commands.isEmpty)
      let ordinary = await coordinator.handle(
        WorkerRequest(
          vmID: binding.vmID,
          sessionID: binding.sessionID, requestID: 1, observedRevision: 0, command: .status))
      #expect(ordinary.state == 2 && ordinary.backendActive && !ordinary.operationPending)
    }
  }

  @Test func configurationRequiresActualOwnerAndCannotBeReplaced() async throws {
    try await withWorkerCapture(configured: false) { coordinator, probe, binding, _, _ in
      let foreign = CaptureBinding(
        vmID: binding.vmID, sessionID: UUID(), monitorEpoch: binding.monitorEpoch)
      #expect(throws: CaptureFault.unavailable) {
        try coordinator.configureProducerCapture(
          binding: foreign, capability: .boundedProducerV1,
          actualBinding: { foreign },
          exchange: { try await probe.exchange($0, terminal: $1, capture: $2) })
      }
      #expect(throws: CaptureFault.alreadyUsed) {
        try coordinator.configureProducerCapture(
          binding: binding, capability: .boundedProducerV1,
          actualBinding: { binding },
          exchange: { try await probe.exchange($0, terminal: $1, capture: $2) })
      }
      #expect(probe.commands.isEmpty)
    }
  }

  @Test func knownRejectionEndsOnlyCaptureAndKeepsOrdinaryOwnerHealthy() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      let connection = UUID()
      let hello = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: connection)
      probe.rejection = .busy
      let rejected = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 2, .status,
          revision: hello.revision), connectionID: connection)
      #expect(rejected.code == .rejected && rejected.rejection == .busy)
      let ordinary = await coordinator.handle(
        WorkerRequest(
          vmID: binding.vmID, sessionID: binding.sessionID,
          requestID: 1, observedRevision: 0, command: .status))
      #expect(ordinary.error == .none && ordinary.state == 2 && ordinary.ownership == 0)
    }
  }

  @Test func bootstrapDisableCannotBeReenabledAndPreservesOrdinaryStatus() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      coordinator.disableProducerCapture()
      let before = coordinator.revision
      let capture = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello),
        connectionID: UUID())
      #expect(
        capture.code == .unavailable && coordinator.revision == before && probe.commands.isEmpty)
      #expect(throws: CaptureFault.alreadyUsed) {
        try coordinator.configureProducerCapture(
          binding: binding, capability: .boundedProducerV1,
          actualBinding: { binding },
          exchange: { try await probe.exchange($0, terminal: $1, capture: $2) })
      }
      let ordinary = await coordinator.handle(
        WorkerRequest(
          vmID: binding.vmID, sessionID: binding.sessionID,
          requestID: 1, observedRevision: 0, command: .status))
      #expect(ordinary.error == .none && ordinary.backendActive && ordinary.state == 2)
    }
  }

  @Test func foreignConnectionCannotAdvanceRevisionOrCloseTheActualAttachment() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      let connection = UUID()
      let hello = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello),
        connectionID: connection)
      let before = coordinator.revision
      let foreign = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 2, .status,
          revision: hello.revision), connectionID: UUID())
      #expect(foreign.code == .identity && coordinator.revision == before)
      coordinator.producerCaptureAttachmentEnded(connectionID: UUID())
      let status = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 2, .status,
          revision: hello.revision), connectionID: connection)
      #expect(status.code == .ok && probe.commands == [.status])
    }
  }

  @Test func acceptedArmSurvivesCancellationDisconnectAndBlocksLifecycle() async throws {
    try await withWorkerCapture { coordinator, probe, binding, owner, backend in
      let connection = UUID()
      let hello = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: connection)
      let status = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 2, .status,
          revision: hello.revision), connectionID: connection)
      probe.gateArm = true
      let waiter = Task { @MainActor in
        await coordinator.handleProducerCapture(
          captureRequest(binding, 3, .arm, revision: status.revision, capture: 17),
          connectionID: connection)
      }
      do {
        try await probe.waitEntered()
        waiter.cancel()
        coordinator.producerCaptureAttachmentEnded(connectionID: connection)
        let competing = await coordinator.handle(
          WorkerRequest(
            vmID: binding.vmID,
            sessionID: binding.sessionID, requestID: 1, observedRevision: coordinator.revision,
            command: .pause))
        #expect(competing.error == .busy && coordinator.operationPending && backend.pauseCalls == 0)
        #expect(owner.ownershipState == .unsettled && owner.controller.isActive)
        probe.release()
        let completed = await waiter.value
        #expect(completed.code == .ok && completed.status?.phase == .armed)
      } catch {
        probe.release()
        _ = await waiter.value
        throw error
      }
      let replacement = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: UUID())
      #expect(replacement.code == .spent && probe.commands == [.status, .arm(17)])
    }
  }

  @Test func staleAttachedRequestCannotAdvanceRevisionDispatchOrReattach() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      let connection = UUID()
      let hello = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello),
        connectionID: connection)
      let before = coordinator.revision
      let stale = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 2, .status,
          revision: hello.revision - 1), connectionID: connection)
      #expect(stale.code == .stale && coordinator.revision == before && probe.commands.isEmpty)
      let replay = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 2, .status,
          revision: hello.revision), connectionID: connection)
      let replacement = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello),
        connectionID: UUID())
      #expect(replay.code == .spent && replacement.code == .spent)
      #expect(coordinator.revision == before && probe.commands.isEmpty)
      let ordinary = await coordinator.handle(
        WorkerRequest(
          vmID: binding.vmID,
          sessionID: binding.sessionID, requestID: 1, observedRevision: 0, command: .status))
      #expect(ordinary.error == .none && ordinary.state == 2 && ordinary.backendActive)
    }
  }

  @Test func lostPageWaiterStillCommitsCursorAndCannotReadAgain() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      let connection = UUID()
      var reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: connection)
      reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 2, .status, revision: reply.revision), connectionID: connection)
      reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 3, .arm, revision: reply.revision, capture: 17),
        connectionID: connection)
      reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 4, .stop, revision: reply.revision, capture: 17),
        connectionID: connection)
      let revision = reply.revision
      probe.gateRead = true
      let waiter = Task { @MainActor in
        await coordinator.handleProducerCapture(
          captureRequest(binding, 5, .read, revision: revision, capture: 17, count: 64),
          connectionID: connection)
      }
      do {
        try await probe.waitEntered()
        waiter.cancel()
        coordinator.producerCaptureAttachmentEnded(connectionID: connection)
        probe.release()
        let committed = await waiter.value
        #expect(committed.code == .ok && committed.status?.cursor == 2 && committed.rows.count == 2)
      } catch {
        probe.release()
        _ = await waiter.value
        throw error
      }
      let replay = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: UUID())
      #expect(
        replay.code == .spent && probe.cursor == 2 && coordinator.producerCaptureDiagnosticLost)
      #expect(
        probe.commands.filter {
          if case .read = $0 { return true }
          return false
        }.count == 1)
    }
  }

  @Test func unknownArmOutcomeConsumesArmAndNeverDispatchesRetry() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      let connection = UUID()
      let hello = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: connection)
      let status = await coordinator.handleProducerCapture(
        captureRequest(binding, 2, .status, revision: hello.revision), connectionID: connection)
      probe.failArm = true
      let failed = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 3, .arm,
          revision: status.revision, capture: 17), connectionID: connection)
      let retry = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 4, .arm,
          revision: failed.revision, capture: 17), connectionID: connection)
      #expect(failed.code == .unknownOutcome && retry.code == .spent)
      #expect(probe.commands == [.status, .arm(17)])
    }
  }

  @Test func actualMonitorEpochReplacementRejectsBeforeDispatch() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      let connection = UUID()
      let hello = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: connection)
      let status = await coordinator.handleProducerCapture(
        captureRequest(binding, 2, .status, revision: hello.revision), connectionID: connection)
      probe.actual = CaptureBinding(
        vmID: binding.vmID, sessionID: binding.sessionID, monitorEpoch: UUID())
      let rejected = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 3, .arm,
          revision: status.revision, capture: 17), connectionID: connection)
      #expect(rejected.code == .identity && probe.commands == [.status])
    }
  }

  @Test func sixteenStatusesAndSixtyFourPagesAreActualWorkerLimits() async throws {
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      let connection = UUID()
      var reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: connection)
      for index in 2...17 {
        reply = await coordinator.handleProducerCapture(
          captureRequest(
            binding, UInt64(index), .status,
            revision: reply.revision), connectionID: connection)
        #expect(reply.code == .ok)
      }
      let excess = await coordinator.handleProducerCapture(
        captureRequest(
          binding, 18, .status,
          revision: reply.revision), connectionID: connection)
      #expect(excess.code == .malformed && probe.commands.count == 16)
    }
    try await withWorkerCapture { coordinator, probe, binding, _, _ in
      probe.records = 4096
      let connection = UUID()
      var reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 1, .hello), connectionID: connection)
      reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 2, .status, revision: reply.revision), connectionID: connection)
      reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 3, .arm, revision: reply.revision, capture: 17),
        connectionID: connection)
      reply = await coordinator.handleProducerCapture(
        captureRequest(binding, 4, .stop, revision: reply.revision, capture: 17),
        connectionID: connection)
      for page in 0..<64 {
        reply = await coordinator.handleProducerCapture(
          captureRequest(
            binding, UInt64(page + 5), .read,
            revision: reply.revision, capture: 17, offset: UInt32(page * 64), count: 64),
          connectionID: connection)
        #expect(reply.code == .ok && reply.rows.count == 64)
      }
      #expect(reply.status?.cursor == 4096 && probe.cursor == 4096)
    }
  }
}
