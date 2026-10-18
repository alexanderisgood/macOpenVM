// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

/// Contract fixture only; actual QEMU terminal/drain qualification is a separate native test.
@MainActor final class RecordedFixtureBackend: BackendSettlementSource {
  let capabilities: BackendCapabilities
  private let normalStop: Bool
  private(set) var stopRequests = 0
  var isActive = false
  var terminationObservation = BackendTerminationObservation.notObserved
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  var failStart = false
  var notifyOnForceStop = true
  var gatePause = false
  private(set) var pauseCalls = 0
  private(set) var pauseWasCancelled = false
  private var pauseGate: CheckedContinuation<Void, Never>?
  private var pauseWaiter: CheckedContinuation<Void, Never>?
  private var session: UUID?
  private var attempted = false
  private var sealed = false

  init(normalStop: Bool = false) {
    self.normalStop = normalStop
    capabilities = BackendCapabilities(
      id: .qemuHVF,
      operations: normalStop
        ? [.start, .stop, .forceStop, .pause, .resume] : [.start, .forceStop, .pause, .resume],
      limitations: [])
  }

  func bindRecordedSession(sessionID: UUID) throws {
    guard session == nil, !attempted, !sealed else { throw fixtureFailure() }
    session = sessionID
  }
  func start() async throws {
    guard !sealed, !attempted else { throw fixtureFailure() }
    attempted = true
    if failStart { throw fixtureFailure() }
    isActive = true
  }
  func requestStop() throws {
    guard normalStop, isActive, !sealed else { throw fixtureFailure() }
    stopRequests += 1
  }
  func guestStop() {
    isActive = false
    terminationObservation = .guestStopObserved
    onGuestStopped?()
  }
  func forceStop() async throws {
    guard !sealed else { throw fixtureFailure() }
    if isActive {
      isActive = false
      terminationObservation = .explicitForcedTermination
    }
    if notifyOnForceStop { onGuestStopped?() }
  }
  func pause() async throws {
    guard !sealed else { throw fixtureFailure() }
    pauseCalls += 1
    if gatePause {
      await withCheckedContinuation { continuation in
        pauseGate = continuation
        pauseWaiter?.resume()
        pauseWaiter = nil
      }
    }
    pauseWasCancelled = Task.isCancelled
  }
  func waitForPause() async {
    if pauseGate != nil { return }
    await withCheckedContinuation { pauseWaiter = $0 }
  }
  func releasePause() {
    pauseGate?.resume()
    pauseGate = nil
  }
  func resume() async throws { guard !sealed else { throw fixtureFailure() } }
  func runtimeExit(notify: Bool = true) {
    isActive = false
    terminationObservation = .runtimeExited
    if notify { onGuestStopped?() }
  }
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    guard !sealed, !isActive, session == sessionID else { throw fixtureFailure() }
    sealed = true
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID,
      launchDisposition: attempted ? .completedAttempt : .neverInvoked,
      terminationObservation: terminationObservation)
  }
  private func fixtureFailure() -> VMError {
    VMError(.backendFailure, "Recorded fixture operation failed.", recovery: "Synthetic test only.")
  }
}

@MainActor func recordedFixture(normalStop: Bool = false) async throws -> (
  URL, UUID, VMLock, RecordedFixtureBackend, RecordedRuntimeOwner
) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-recorded-owner-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let id = UUID()
  let lock = try VMLock(directory: directory, expectedVMID: id)
  let backend = RecordedFixtureBackend(normalStop: normalStop)
  let owner = try await RecordedRuntimeOwner.open(
    in: directory, vmID: id, lock: lock, backend: backend)
  return (directory, id, lock, backend, owner)
}

/// Controls only the final receipt transaction; every other boundary uses actual VMFiles.
private actor RecordedCommitGate: RecordedRuntimeStore {
  let files = VMFiles()
  private var gate: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  private var atCommit = false
  private var released = false
  private let failCommit: Bool
  private(set) var commits = 0
  init(failCommit: Bool) { self.failCommit = failCommit }
  func beginOwnership(in directory: URL, vmID: UUID, lock: VMLock) async throws
    -> RuntimeSessionPermit
  {
    try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: lock)
  }
  func commitOwnership(in directory: URL, receipt: RuntimeSettlementReceipt) async throws {
    commits += 1
    atCommit = true
    entered?.resume()
    entered = nil
    if !released { await withCheckedContinuation { gate = $0 } }
    if failCommit {
      throw VMError(
        .storage, "Injected final commit failure.", recovery: "Preserved synthetic fixture.")
    }
    try await files.commitRuntimeSettlement(in: directory, receipt: receipt)
  }
  func awaitCommit() async {
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

@MainActor private final class WeakRecordedReference<Owner: AnyObject> {
  weak var value: Owner?
  init(_ value: Owner?) { self.value = value }
}

@Suite(.serialized) @MainActor struct RecordedRuntimeOwnerTests {
  @Test func explicitForceSettlesSameSessionAndPermanentlySealsOperations() async throws {
    let (directory, id, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var notified = false
    owner.onOwnershipSettled = { notified = true }
    try await owner.perform(.start)
    await #expect(throws: VMError.self) { try await owner.settleOwnership() }
    #expect(owner.ownershipState == .unsettled && backend.isActive && !notified)
    try await owner.perform(.forceStop)
    try await owner.settleOwnership()
    #expect(owner.ownershipState == .settled && notified)
    let intent = try #require(try await VMFiles().readRuntimeIntent(in: directory))
    let history = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(intent.vmID == id && intent.sessionID == owner.sessionID && intent.state == .settled)
    #expect(history.sessionID == owner.sessionID && history.snapshot.outcome == .forcedStopped)
    backend.onGuestStopped?()  // Duplicate delegate delivery after the durable history seal.
    await owner.controller.finishPersistence()
    let unchanged = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(unchanged == history && owner.controller.historyError == nil)
    await #expect(throws: VMError.self) { try await owner.perform(.start) }
    await #expect(throws: VMError.self) { try await backend.start() }
    try await owner.settleOwnership()  // Same transaction result; no second mutation.
    withExtendedLifetime(lock) {}
  }

  @Test func ordinaryProcessExitRecordsFailureAndCanSettlePhysicalOwnership() async throws {
    let (directory, _, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await owner.perform(.start)
    backend.runtimeExit()
    try await owner.settleOwnership()
    #expect(owner.controller.state == .failed && owner.controller.runtimeError != nil)
    let record = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(record.snapshot.outcome == .failed && !record.snapshot.backendActive)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
    withExtendedLifetime(lock) {}
  }

  @Test(arguments: [false, true])
  func lateForceRequestCannotRelabelEarlierRuntimeExit(notifyOnForceStop: Bool) async throws {
    let (directory, _, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await owner.perform(.start)
    await owner.controller.finishPersistence()
    backend.runtimeExit(notify: false)
    backend.notifyOnForceStop = notifyOnForceStop
    try await owner.perform(.forceStop)
    try await owner.settleOwnership()
    #expect(backend.terminationObservation == .runtimeExited)
    #expect(owner.controller.state == .failed && owner.controller.runtimeError != nil)
    let record = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(record.snapshot.outcome == .failed && !record.snapshot.backendActive)
    #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
    withExtendedLifetime(lock) {}
  }

  @Test(arguments: [false, true])
  func noLaunchedGuestSettlesOnlyHonestFailedHistory(failedAttempt: Bool) async throws {
    let (directory, _, lock, backend, owner) = try await recordedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    if failedAttempt {
      backend.failStart = true
      await #expect(throws: VMError.self) { try await owner.perform(.start) }
    }
    let waiter = Task { @MainActor in try await owner.settleOwnership() }
    waiter.cancel()
    try await waiter.value
    #expect(owner.ownershipState == .settled)
    let record = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(record.snapshot.outcome == .failed && !record.snapshot.backendActive)
    #expect(record.snapshot.operation == nil && record.sessionID == owner.sessionID)
    withExtendedLifetime(lock) {}
  }

  @Test(arguments: [false, true])
  func finalCommitRetainsKernelCustodyAndFailedTransactionCannotRetry(failCommit: Bool) async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "macOpenVM-recorded-commit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let id = UUID()
    var lock: VMLock? = try VMLock(directory: directory, expectedVMID: id)
    let weakLock = WeakRecordedReference(lock)
    let store = RecordedCommitGate(failCommit: failCommit)
    let backend = RecordedFixtureBackend()
    var owner: RecordedRuntimeOwner? = try await RecordedRuntimeOwner.open(
      in: directory, vmID: id, lock: try #require(lock), backend: backend, files: store)
    let weakOwner = WeakRecordedReference(owner)
    withExtendedLifetime(lock) {}
    lock = nil
    var released = false
    owner?.onOwnershipSettled = { released = true }
    do {
      let live = try #require(owner)
      let transaction = Task { @MainActor in try await live.settleOwnership() }
      await store.awaitCommit()
      #expect(live.ownershipState == .settling && !released)
      #expect(await VMFiles().writerStatus(in: directory) == .held)
      #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
      transaction.cancel()
      await store.releaseCommit()
      if failCommit {
        await #expect(throws: VMError.self) { try await transaction.value }
        #expect(live.ownershipState == .recoveryRequired && !released)
        await #expect(throws: VMError.self) { try await live.settleOwnership() }
        #expect(await store.commits == 1)
      } else {
        try await transaction.value
        #expect(live.ownershipState == .settled && released)
        #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
      }
    }
    withExtendedLifetime(owner) {}
    owner = nil
    if failCommit {
      #expect(weakOwner.value != nil && weakLock.value != nil)
      #expect(await VMFiles().writerStatus(in: directory) == .held)
      #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
      // Intentional recovery custody and private fixture remain; no hidden release API.
    } else {
      #expect(weakOwner.value == nil && weakLock.value == nil)
      #expect(await VMFiles().writerStatus(in: directory) == .available)
      let next = try VMLock(directory: directory, expectedVMID: id)
      withExtendedLifetime(next) {}
      try FileManager.default.removeItem(at: directory)
    }
  }
}
