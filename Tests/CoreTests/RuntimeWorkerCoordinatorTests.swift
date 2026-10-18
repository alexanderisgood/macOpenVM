// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@Suite(.serialized) @MainActor struct RuntimeWorkerCoordinatorTests {
  private func request(
    _ command: WorkerCommand, vmID: UUID, owner: RecordedRuntimeOwner,
    revision: UInt64 = 0, id: UInt64 = 1
  ) -> WorkerRequest {
    WorkerRequest(
      vmID: vmID, sessionID: owner.sessionID, requestID: id,
      observedRevision: revision, command: command)
  }

  @Test func mouseModeUsesOwnerAdmissionAndRetainsNormalLifecycle() async throws {
    let (directory, vmID, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    var selections: [Bool] = []
    coordinator.selectRelativeMouse = { selections.append($0) }
    await coordinator.start()
    let status = await coordinator.handle(request(.status, vmID: vmID, owner: owner))
    #expect(
      await coordinator.handle(
        request(
          .relativeMouse, vmID: UUID(), owner: owner,
          revision: status.revision)
      ).error == .identity)
    #expect(
      await coordinator.handle(
        request(
          .relativeMouse, vmID: vmID, owner: owner,
          revision: status.revision - 1)
      ).error == .stale)
    #expect(selections.isEmpty)
    let selected = await coordinator.handle(
      request(
        .relativeMouse, vmID: vmID, owner: owner,
        revision: status.revision))
    #expect(selected.error == .none && selections == [true] && selected.state == 2)
    #expect(backend.pauseCalls == 0 && selected.backendActive && selected.ownership == 0)
    let desktop = await coordinator.handle(
      request(
        .absoluteMouse, vmID: vmID, owner: owner,
        revision: selected.revision))
    #expect(desktop.error == .none && selections == [true, false])
    let stop = await coordinator.handle(
      request(
        .forceStop, vmID: vmID, owner: owner,
        revision: desktop.revision))
    #expect(stop.error == .none && stop.ownership == 2)
    withExtendedLifetime(lock) {}
  }

  @Test func identityAndStaleRevisionNeverInvokeBackend() async throws {
    let (directory, vmID, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    await coordinator.start()
    let before = try await VMFiles().readMetadata(
      at: directory.appendingPathComponent("runtime.json"))
    let status = await coordinator.handle(request(.status, vmID: vmID, owner: owner))
    #expect(status.state == 2 && status.backendActive && !status.operationPending)
    let wrongVM = await coordinator.handle(
      request(.pause, vmID: UUID(), owner: owner, revision: status.revision))
    #expect(wrongVM.error == .identity)
    let wrongSession = WorkerRequest(
      vmID: vmID, sessionID: UUID(), requestID: 2, observedRevision: status.revision,
      command: .pause)
    #expect(await coordinator.handle(wrongSession).error == .identity)
    let stale = await coordinator.handle(
      request(.pause, vmID: vmID, owner: owner, revision: status.revision - 1))
    #expect(stale.error == .stale && backend.pauseCalls == 0)
    #expect(
      try await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json"))
        == before)
    let stop = await coordinator.handle(
      request(.forceStop, vmID: vmID, owner: owner, revision: status.revision, id: 3))
    #expect(stop.error == .none && stop.ownership == 2 && !stop.backendActive)
    let sealed = await coordinator.handle(
      request(.pause, vmID: vmID, owner: owner, revision: stop.revision, id: 4))
    #expect(sealed.error == .recovery && backend.pauseCalls == 0)
    withExtendedLifetime(lock) {}
  }

  @Test func disconnectedWaiterDoesNotCancelOperationAndOldRevisionCannotReplay() async throws {
    let (directory, vmID, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    await coordinator.start()
    let status = await coordinator.handle(request(.status, vmID: vmID, owner: owner))
    backend.gatePause = true
    let pauseRequest = request(.pause, vmID: vmID, owner: owner, revision: status.revision, id: 2)
    let disconnected = Task { @MainActor in await coordinator.handle(pauseRequest) }
    await backend.waitForPause()
    disconnected.cancel()
    let during = await coordinator.handle(request(.status, vmID: vmID, owner: owner, id: 3))
    #expect(during.operationPending && during.backendActive && during.revision > status.revision)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
    let competing = await coordinator.handle(
      request(.forceStop, vmID: vmID, owner: owner, revision: during.revision, id: 4))
    #expect(competing.error == .busy && backend.pauseCalls == 1)
    backend.releasePause()
    let completed = await disconnected.value
    #expect(completed.state == 4 && !completed.operationPending && completed.error == .none)
    #expect(!backend.pauseWasCancelled && backend.pauseCalls == 1)
    // A reconnected client must inspect status. Replaying the old mutation cannot
    // execute it again; there is no implicit idempotency/retry cache in protocol 1.
    let replay = await coordinator.handle(pauseRequest)
    #expect(replay.error == .stale && backend.pauseCalls == 1)
    let reconciled = await coordinator.handle(request(.status, vmID: vmID, owner: owner, id: 1))
    let stop = await coordinator.handle(
      request(.forceStop, vmID: vmID, owner: owner, revision: reconciled.revision, id: 2))
    #expect(stop.ownership == 2 && stop.state == 0 && !stop.backendActive)
    let record = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(record.sessionID == owner.sessionID && record.snapshot.outcome == .forcedStopped)
    withExtendedLifetime(lock) {}
  }

  @Test func actualQuiescenceSettlesFailureWithoutAClientOrImplicitForceStop() async throws {
    let (directory, vmID, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    var settled: CheckedContinuation<Void, Never>?
    var finished = false
    coordinator.onSettled = {
      finished = true
      settled?.resume()
      settled = nil
    }
    await coordinator.start()
    backend.runtimeExit()
    if !finished { await withCheckedContinuation { settled = $0 } }
    let status = await coordinator.handle(request(.status, vmID: vmID, owner: owner))
    #expect(status.state == 10 && status.ownership == 2 && status.error == .operationFailed)
    #expect(backend.terminationObservation == .runtimeExited)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
    withExtendedLifetime(lock) {}
  }

  @Test func stopAcknowledgementRetainsOwnershipUntilObservedGuestStop() async throws {
    let (directory, vmID, lock, backend, owner) = try await recordedFixture(normalStop: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    var settled: CheckedContinuation<Void, Never>?
    var finished = false
    coordinator.onSettled = {
      finished = true
      settled?.resume()
      settled = nil
    }
    await coordinator.start()
    let status = await coordinator.handle(request(.status, vmID: vmID, owner: owner))
    let accepted = await coordinator.handle(
      request(.stop, vmID: vmID, owner: owner, revision: status.revision, id: 2))
    #expect(accepted.error == .none && accepted.state == 6 && accepted.backendActive)
    #expect(accepted.ownership == 0 && !accepted.operationPending && backend.stopRequests == 1)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
    let pending = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(pending.snapshot.outcome == .pending && pending.snapshot.backendActive)
    backend.guestStop()
    if !finished { await withCheckedContinuation { settled = $0 } }
    let complete = await coordinator.handle(request(.status, vmID: vmID, owner: owner, id: 3))
    #expect(complete.state == 0 && complete.ownership == 2 && !complete.backendActive)
    #expect(complete.error == .none && backend.stopRequests == 1)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
    let record = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(record.sessionID == owner.sessionID && record.snapshot.outcome == .guestStopped)
    withExtendedLifetime(lock) {}
  }

  @Test func acknowledgedStopFollowedByOpaqueExitRemainsFailure() async throws {
    let (directory, vmID, lock, backend, owner) = try await recordedFixture(normalStop: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    var settled: CheckedContinuation<Void, Never>?
    var finished = false
    coordinator.onSettled = {
      finished = true
      settled?.resume()
      settled = nil
    }
    await coordinator.start()
    let status = await coordinator.handle(request(.status, vmID: vmID, owner: owner))
    let accepted = await coordinator.handle(
      request(.stop, vmID: vmID, owner: owner, revision: status.revision, id: 2))
    #expect(accepted.error == .none && accepted.backendActive && accepted.ownership == 0)
    backend.runtimeExit()
    if !finished { await withCheckedContinuation { settled = $0 } }
    let complete = await coordinator.handle(request(.status, vmID: vmID, owner: owner, id: 3))
    #expect(complete.state == 10 && complete.ownership == 2 && !complete.backendActive)
    #expect(complete.error == .operationFailed && backend.stopRequests == 1)
    let record = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(record.snapshot.outcome == .failed)
    withExtendedLifetime(lock) {}
  }

  @Test func stopIdentityAndRevisionGuardsPreserveLiveOwner() async throws {
    let (directory, vmID, lock, backend, owner) = try await recordedFixture(normalStop: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    await coordinator.start()
    let status = await coordinator.handle(request(.status, vmID: vmID, owner: owner))
    let before = try await VMFiles().readMetadata(
      at: directory.appendingPathComponent("runtime.json"))
    #expect(
      await coordinator.handle(
        request(.stop, vmID: UUID(), owner: owner, revision: status.revision)
      ).error == .identity)
    #expect(
      await coordinator.handle(
        request(.stop, vmID: vmID, owner: owner, revision: status.revision - 1)
      ).error == .stale)
    #expect(backend.stopRequests == 0 && backend.isActive)
    #expect(
      try await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json"))
        == before)
    let cleanup = await coordinator.handle(
      request(.forceStop, vmID: vmID, owner: owner, revision: status.revision, id: 4))
    #expect(cleanup.ownership == 2 && !cleanup.backendActive && backend.stopRequests == 0)
    withExtendedLifetime(lock) {}
  }
}
