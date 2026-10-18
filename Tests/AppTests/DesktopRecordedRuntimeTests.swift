// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Controlled backend events only; these tests never construct a native VZ VM.
@MainActor private final class DesktopOwnershipBackend: BackendSettlementSource {
  let capabilities = BackendCapabilities(
    id: .appleVz, operations: [.start, .stop, .forceStop, .pause, .resume], limitations: [])
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  private(set) var terminationObservation = BackendTerminationObservation.notObserved
  private(set) var starts = 0
  private(set) var forceStops = 0
  private(set) var sessionID: UUID?
  private var nativeActive = false
  private var terminalPending = false
  private var sealed = false
  var isActive: Bool { nativeActive || terminalPending }

  func bindRecordedSession(sessionID: UUID) throws {
    guard self.sessionID == nil, starts == 0, !sealed else { throw desktopOwnershipFailure() }
    self.sessionID = sessionID
  }
  func start() async throws {
    guard sessionID != nil, starts == 0, !sealed else { throw desktopOwnershipFailure() }
    starts += 1
    nativeActive = true
    terminalPending = true
  }
  func requestStop() throws {
    guard nativeActive, !sealed else { throw desktopOwnershipFailure() }
  }
  func forceStop() async throws {
    guard !sealed else { throw desktopOwnershipFailure() }
    forceStops += 1
    nativeActive = false
    terminalPending = false
    terminationObservation = .explicitForcedTermination
    onGuestStopped?()
  }
  func pause() async throws {}
  func resume() async throws {}
  func nativeStoppedBeforeDelegate() { nativeActive = false }
  func guestStopped() {
    guard !sealed else { return }
    nativeActive = false
    terminalPending = false
    terminationObservation = .guestStopObserved
    onGuestStopped?()
  }
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    guard self.sessionID == sessionID, !isActive, !sealed else { throw desktopOwnershipFailure() }
    sealed = true
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID,
      launchDisposition: starts == 0 ? .neverInvoked : .completedAttempt,
      terminationObservation: terminationObservation)
  }
}

/// Only the final commit/fault is injected. Intents, history and lease admission
/// go through the actual storage implementation on private temporary files.
private actor DesktopOwnershipStore: RecordedRuntimeStore {
  private let files = VMFiles()
  private let failPreparation: Bool
  private let failCommit: Bool
  private var atCommit = false
  private var released = false
  private var gate: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  private(set) var begins = 0
  private(set) var commits = 0
  private(set) var receiptVMID: UUID?
  private(set) var receiptSessionID: UUID?
  private(set) var receiptSourceID: ObjectIdentifier?

  init(failPreparation: Bool = false, failCommit: Bool = false) {
    self.failPreparation = failPreparation
    self.failCommit = failCommit
  }
  func beginOwnership(in directory: URL, vmID: UUID, lock: VMLock) async throws
    -> RuntimeSessionPermit
  {
    begins += 1
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: lock)
    if failPreparation { throw desktopOwnershipFailure() }
    return permit
  }
  func commitOwnership(in directory: URL, receipt: RuntimeSettlementReceipt) async throws {
    commits += 1
    receiptVMID = receipt.permit.vmID
    receiptSessionID = receipt.permit.sessionID
    receiptSourceID = receipt.sourceID
    atCommit = true
    entered?.resume()
    entered = nil
    if !released { await withCheckedContinuation { gate = $0 } }
    if failCommit { throw desktopOwnershipFailure() }
    try await files.commitRuntimeSettlement(in: directory, receipt: receipt)
  }
  func waitForCommit() async {
    if atCommit { return }
    await withCheckedContinuation { entered = $0 }
  }
  func releaseCommit() {
    released = true
    gate?.resume()
    gate = nil
  }
  func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    try await files.readRuntimeIntent(in: directory)
  }
  func status(at url: URL) async -> VMFileStatus { await files.status(at: url) }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    try await files.writeNewMetadata(data, at: url)
  }
  func atomicWrite(_ data: Data, at url: URL) async throws {
    try await files.atomicWrite(data, at: url)
  }
}

@MainActor private final class WeakDesktopRuntime {
  weak var value: DesktopRecordedRuntime?
}

private func desktopOwnershipFailure() -> VMError {
  VMError(
    .storage, "Injected desktop ownership fault.", recovery: "Private filesystem fixture only.")
}

@Suite(.serialized) @MainActor struct DesktopRecordedRuntimeTests {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "macOpenVM-desktop-owner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }

  private func fixture() throws -> (URL, UUID, DesktopOwnershipBackend, DesktopRecordedRuntime) {
    let directory = try directory()
    let id = UUID()
    let backend = DesktopOwnershipBackend()
    let runtime = DesktopRecordedRuntime(
      lock: try VMLock(directory: directory, expectedVMID: id), backend: backend)
    return (directory, id, backend, runtime)
  }

  @Test func preparationFailureAfterMintingIntentRetainsActualWriterAndBlocksClose() async throws {
    let directory = try directory()
    let id = UUID()
    let backend = DesktopOwnershipBackend()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DesktopOwnershipStore(failPreparation: true)
    var runtime: DesktopRecordedRuntime? = DesktopRecordedRuntime(
      lock: try VMLock(directory: directory, expectedVMID: id), backend: backend)
    let weak = WeakDesktopRuntime()
    weak.value = runtime
    await #expect(throws: VMError.self) {
      try await runtime?.prepare(in: directory, vmID: id, files: store)
    }
    #expect(runtime?.phase == .recoveryRequired && runtime?.isBusy == true)
    #expect(runtime?.owner == nil && runtime?.lastFailure?.code == .storage)
    #expect(backend.sessionID == nil && backend.starts == 0 && backend.forceStops == 0)
    let intent = try #require(try await VMFiles().readRuntimeIntent(in: directory))
    #expect(intent.vmID == id && intent.state == .unsettled)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    #expect(await store.begins == 1)
    #expect(await store.commits == 0)
    runtime = nil
    #expect(weak.value?.isBusy == true)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
  }

  @Test(.timeLimit(.minutes(1)))
  func delayedDelegateAndDurableCommitControlReleaseOfExactOwner() async throws {
    let (directory, id, backend, runtime) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DesktopOwnershipStore()
    var settled = 0
    runtime.onSettled = { settled += 1 }
    try await runtime.prepare(in: directory, vmID: id, files: store)
    let ownerID = ObjectIdentifier(try #require(runtime.owner))
    let sessionID = try #require(runtime.owner?.sessionID)
    let oldQuiescent = runtime.controller?.onQuiescent
    await #expect(throws: VMError.self) {
      try await runtime.prepare(in: directory, vmID: UUID(), files: store)
    }
    #expect(ObjectIdentifier(try #require(runtime.owner)) == ownerID)
    #expect(await store.begins == 1)
    try await runtime.perform(.start)
    await runtime.controller?.finishPersistence()
    backend.nativeStoppedBeforeDelegate()
    #expect(runtime.isBusy && runtime.phase == .prepared && backend.isActive)
    await #expect(throws: VMError.self) { try await runtime.waitForSettlement() }
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
    #expect(settled == 0 && backend.forceStops == 0)
    backend.guestStopped()
    await store.waitForCommit()
    #expect(runtime.phase == .settling && runtime.isBusy && settled == 0)
    #expect(await store.receiptSourceID == ownerID)
    #expect(await store.receiptVMID == id)
    #expect(await store.receiptSessionID == sessionID)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
    await store.releaseCommit()
    try await runtime.waitForSettlement()
    #expect(runtime.phase == .settled && !runtime.isBusy && settled == 1)
    #expect(runtime.owner == nil && runtime.controller == nil && runtime.lastFailure == nil)
    #expect(await VMFiles().writerStatus(in: directory) == .available)
    let intent = try #require(try await VMFiles().readRuntimeIntent(in: directory))
    let history = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(intent.state == .settled && intent.vmID == id && intent.sessionID == sessionID)
    #expect(history.sessionID == sessionID && history.snapshot.outcome == .guestStopped)
    oldQuiescent?()
    backend.guestStopped()
    try await runtime.waitForSettlement()
    #expect(await store.commits == 1 && settled == 1)
    #expect(
      try RuntimeHistoryCodec.decode(
        await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
        == history)
  }

  @Test(.timeLimit(.minutes(1)))
  func failedCommitKeepsInactiveRuntimeBusyAndDoesNotRetryOrReleaseWriter() async throws {
    let (directory, id, backend, runtime) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DesktopOwnershipStore(failCommit: true)
    var settled = 0
    runtime.onSettled = { settled += 1 }
    try await runtime.prepare(in: directory, vmID: id, files: store)
    let ownerID = ObjectIdentifier(try #require(runtime.owner))
    try await runtime.perform(.start)
    backend.guestStopped()
    await store.waitForCommit()
    await store.releaseCommit()
    await #expect(throws: VMError.self) { try await runtime.waitForSettlement() }
    #expect(runtime.phase == .recoveryRequired && runtime.isBusy && !backend.isActive)
    #expect(ObjectIdentifier(try #require(runtime.owner)) == ownerID)
    #expect(runtime.owner?.ownershipState == .recoveryRequired && settled == 0)
    #expect(runtime.lastFailure?.code == .storage)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
    await #expect(throws: VMError.self) { try await runtime.waitForSettlement() }
    await #expect(throws: VMError.self) { try await runtime.perform(.start) }
    #expect(await store.commits == 1 && backend.starts == 1 && backend.forceStops == 0)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingSettlementWaiterDoesNotCancelOwnedCommitOrReleaseEarly() async throws {
    let (directory, id, backend, runtime) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DesktopOwnershipStore()
    try await runtime.prepare(in: directory, vmID: id, files: store)
    try await runtime.perform(.start)
    backend.guestStopped()
    await store.waitForCommit()
    var returned = false
    let waiter = Task { @MainActor in
      defer { returned = true }
      try await runtime.waitForSettlement()
    }
    waiter.cancel()
    await Task.yield()
    #expect(!returned && runtime.phase == .settling && runtime.isBusy)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    #expect(await store.commits == 1 && backend.forceStops == 0)
    await store.releaseCommit()
    try await waiter.value
    #expect(returned && runtime.phase == .settled && !runtime.isBusy)
    #expect(await VMFiles().writerStatus(in: directory) == .available)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
    #expect(await store.commits == 1 && backend.forceStops == 0)
  }
}
