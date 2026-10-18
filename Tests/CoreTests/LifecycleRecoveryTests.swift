// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@MainActor private final class RecoveryBackend: MachineBackend {
  var terminationObservation = BackendTerminationObservation.notObserved
  enum StartMode { case active, inactiveCompletion, failInactive, failActive, waitAfterActivation }
  let capabilities = BackendCapabilities(
    id: .appleVz, operations: [.start, .stop, .forceStop, .pause, .resume], limitations: [])
  var isActive = false
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  var startMode = StartMode.active
  var startCalls = 0
  var forceStopCalls = 0
  var guestStopBeforeForceFailure = false
  private var startGate: CheckedContinuation<Void, Never>?
  private var startWaiter: CheckedContinuation<Void, Never>?
  let injectedFailure = VMError(
    .backendFailure, "Injected runtime failure.", recovery: "Disposable test fixture only.")

  func start() async throws {
    startCalls += 1
    terminationObservation = .notObserved
    switch startMode {
    case .active: isActive = true
    case .inactiveCompletion: return
    case .failInactive: throw injectedFailure
    case .failActive:
      isActive = true
      throw injectedFailure
    case .waitAfterActivation:
      isActive = true
      await withCheckedContinuation { continuation in
        startGate = continuation
        startWaiter?.resume()
        startWaiter = nil
      }
      try Task.checkCancellation()
    }
  }
  func waitUntilStartIsSuspended() async {
    if startGate != nil { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func completeStartCall() {
    startGate?.resume()
    startGate = nil
  }
  func requestStop() throws {}
  func forceStop() async throws {
    forceStopCalls += 1
    if guestStopBeforeForceFailure {
      guestShutdown()
      throw injectedFailure
    }
    isActive = false
    terminationObservation = .explicitForcedTermination
    onGuestStopped?()
  }
  func pause() async throws {}
  func resume() async throws {}
  func failWhileActive() { onFailure?(injectedFailure) }
  func guestShutdown() {
    isActive = false
    terminationObservation = .guestStopObserved
    onGuestStopped?()
  }
}

@Test @MainActor
func guestStopCallbackBeforeForceErrorLeavesFailedDurableHistory() async throws {
  let directory = try recoveryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let lock = try VMLock(directory: directory)
  let files = VMFiles()
  let history = try await VMRuntimeHistory.open(in: directory, files: files, lock: lock)
  let backend = RecoveryBackend()
  let controller = VMController(backend: backend, history: history)
  try await controller.perform(.start)
  await controller.finishPersistence()
  let started = try RuntimeHistoryCodec.decode(
    await files.readMetadata(at: directory.appendingPathComponent("runtime.json")))
  backend.guestStopBeforeForceFailure = true
  await #expect(throws: VMError.self) { try await controller.perform(.forceStop) }
  await #expect(throws: VMError.self) { try await controller.settleRuntime() }
  let record = try RuntimeHistoryCodec.decode(
    await files.readMetadata(at: directory.appendingPathComponent("runtime.json")))
  #expect(backend.forceStopCalls == 1 && backend.terminationObservation == .guestStopObserved)
  #expect(controller.state == .failed && controller.runtimeError == backend.injectedFailure)
  #expect(record.snapshot.state == .failed && record.snapshot.outcome == .failed)
  #expect(!record.snapshot.backendActive && record.snapshot.operation == nil)
  #expect(record.sessionID == started.sessionID)
  withExtendedLifetime(lock) {}
}

@MainActor private final class RecoveryHistory: LifecycleHistory {
  var snapshots: [RuntimeSnapshot] = []
  var blockOutcome: RuntimeOutcome?
  private var gate: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  func persist(_ snapshot: RuntimeSnapshot) async throws {
    snapshots.append(snapshot)
    if blockOutcome == snapshot.outcome {
      blockOutcome = nil
      await withCheckedContinuation { continuation in
        gate = continuation
        waiter?.resume()
        waiter = nil
      }
    }
  }
  func waitUntilBlocked() async {
    if gate != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    gate?.resume()
    gate = nil
  }
}

private func recoveryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macopenvm-recovery-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return directory
}

@Test @MainActor func inactiveStartCompletionCannotClaimRunningOrGuestShutdown() async throws {
  let backend = RecoveryBackend()
  backend.startMode = .inactiveCompletion
  let history = RecoveryHistory()
  let controller = VMController(backend: backend, history: history)
  await #expect(throws: VMError.self) { try await controller.perform(.start) }
  await #expect(throws: VMError.self) { try await controller.settleRuntime() }
  #expect(controller.state == .failed)
  #expect(!controller.isActive)
  #expect(controller.runtimeError?.code == .backendFailure)
  #expect(history.snapshots.last?.outcome == .failed)
  #expect(!history.snapshots.contains { $0.state == .running || $0.outcome == .guestStopped })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cancelledSettlementRetainsFailedActiveOwnerAndReportsFailureAfterGuestShutdown() async throws {
  let directory = try recoveryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  var lock: VMLock? = try VMLock(directory: directory)
  let backend = RecoveryBackend()
  let history = RecoveryHistory()
  let controller = VMController(backend: backend, history: history)
  controller.onQuiescent = { lock = nil }
  try await controller.perform(.start)
  backend.failWhileActive()
  let settlement = Task { @MainActor () -> VMError? in
    do {
      try await controller.settleRuntime()
      return nil
    } catch { return error as? VMError }
  }
  settlement.cancel()
  try await Task.sleep(for: .milliseconds(50))
  #expect(lock != nil)
  #expect(await VMFiles().writerStatus(in: directory) == .held)
  #expect(controller.isActive)
  #expect(backend.forceStopCalls == 0)
  backend.guestShutdown()
  #expect(await settlement.value == backend.injectedFailure)
  #expect(lock == nil)
  #expect(await VMFiles().writerStatus(in: directory) == .available)
  #expect(history.snapshots.last?.outcome == .failed)
  #expect(controller.runtimeError == backend.injectedFailure)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cancellationAfterActivationDoesNotForceStopOrRecordGuestShutdown() async throws {
  let backend = RecoveryBackend()
  backend.startMode = .waitAfterActivation
  let history = RecoveryHistory()
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  let launch = Task { @MainActor in try await controller.perform(.start) }
  await backend.waitUntilStartIsSuspended()
  launch.cancel()
  backend.completeStartCall()
  await #expect(throws: CancellationError.self) { try await launch.value }
  await controller.finishPersistence()
  #expect(controller.state == .failed)
  #expect(controller.runtimeError?.code == .cancelled)
  #expect(controller.isActive)
  #expect(!released)
  #expect(backend.forceStopCalls == 0)
  #expect(history.snapshots.last?.outcome == .failed)
  #expect(
    !history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .forcedStopped })
  backend.guestShutdown()
  await #expect(throws: VMError.self) { try await controller.settleRuntime() }
  #expect(released)
  #expect(backend.forceStopCalls == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cancellationDuringLaunchIntentNeverInvokesBackendAndDrainsFailure() async throws {
  let backend = RecoveryBackend()
  let history = RecoveryHistory()
  history.blockOutcome = .pending
  let controller = VMController(backend: backend, history: history)
  let launch = Task { @MainActor in try await controller.perform(.start) }
  await history.waitUntilBlocked()
  launch.cancel()
  history.release()
  await #expect(throws: CancellationError.self) { try await launch.value }
  await #expect(throws: VMError.self) { try await controller.settleRuntime() }
  #expect(backend.startCalls == 0)
  #expect(backend.forceStopCalls == 0)
  #expect(!controller.isActive)
  #expect(controller.runtimeError?.code == .cancelled)
  #expect(history.snapshots.count == 2)
  #expect(history.snapshots.last?.outcome == .failed)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedLaunchCannotReleaseOwnerBeforeFailureRecordSettles() async throws {
  let backend = RecoveryBackend()
  backend.startMode = .failInactive
  let history = RecoveryHistory()
  history.blockOutcome = .failed
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  await #expect(throws: VMError.self) { try await controller.perform(.start) }
  await history.waitUntilBlocked()
  let settlement = Task { @MainActor () -> VMError? in
    do {
      try await controller.settleRuntime()
      return nil
    } catch { return error as? VMError }
  }
  settlement.cancel()
  try await Task.sleep(for: .milliseconds(50))
  #expect(!released)
  #expect(controller.isSettling)
  history.release()
  #expect(await settlement.value == backend.injectedFailure)
  #expect(released)
  #expect(!controller.isSettling)
  #expect(history.snapshots.last?.outcome == .failed)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func observedStopKeepsOwnerWhileStartCompletionIsOutstanding() async throws {
  let backend = RecoveryBackend()
  backend.startMode = .waitAfterActivation
  let history = RecoveryHistory()
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  let launch = Task { @MainActor in try await controller.perform(.start) }
  await backend.waitUntilStartIsSuspended()
  backend.guestShutdown()
  await controller.finishPersistence()
  #expect(controller.state == .stopped)
  #expect(!released)
  backend.completeStartCall()
  try await launch.value
  try await controller.settleRuntime()
  #expect(released)
  #expect(controller.state == .stopped)
  #expect(!history.snapshots.contains { $0.state == .running })
}

@Test(arguments: ["hardlink", "group-writable"])
@MainActor func equalUnsafeArchiveBlocksLaunchWithoutReplacingPriorBytes(kind: String) async throws
{
  let directory = try recoveryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let lock = try VMLock(directory: directory)
  let prior = RuntimeRecord(
    sessionID: UUID(), sequence: 3, recordedAt: 100,
    snapshot: RuntimeSnapshot(
      state: .running, operation: nil, backendActive: true, outcome: .pending))
  let original = try RuntimeHistoryCodec.encode(prior)
  let runtime = directory.appendingPathComponent("runtime.json")
  let archive = directory.appendingPathComponent(
    "runtime-\(prior.sessionID.uuidString.lowercased()).json")
  let source = directory.appendingPathComponent("preserved-source.json")
  try await files.atomicWrite(original, at: runtime)
  if kind == "hardlink" {
    try await files.writeNewMetadata(original, at: source)
    try FileManager.default.linkItem(at: source, to: archive)
  } else {
    try await files.writeNewMetadata(original, at: archive)
    try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: archive.path)
  }
  let history = try await VMRuntimeHistory.open(in: directory, files: files, lock: lock)
  let backend = RecoveryBackend()
  let controller = VMController(backend: backend, history: history)
  await #expect(throws: VMError.self) { try await controller.perform(.start) }
  await #expect(throws: VMError.self) { try await controller.settleRuntime() }
  #expect(backend.startCalls == 0)
  #expect(!backend.isActive)
  #expect(try await files.readMetadata(at: runtime) == original)
  #expect(try await files.readMetadata(at: archive) == original)
  if kind == "hardlink" {
    #expect(try await files.readMetadata(at: source) == original)
    #expect(await files.status(at: archive).links == 2)
  } else {
    #expect(await files.status(at: archive).otherWriteBits == true)
  }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedActiveLaunchRetainsOwnerUntilExplicitGuestShutdown() async throws {
  let backend = RecoveryBackend()
  backend.startMode = .failActive
  let history = RecoveryHistory()
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  await #expect(throws: VMError.self) { try await controller.perform(.start) }
  await controller.finishPersistence()
  #expect(controller.state == .failed)
  #expect(controller.isActive)
  #expect(!released)
  #expect(backend.forceStopCalls == 0)
  #expect(history.snapshots.last?.outcome == .failed)
  backend.guestShutdown()
  await #expect(throws: VMError.self) { try await controller.settleRuntime() }
  #expect(released)
  #expect(controller.runtimeError == backend.injectedFailure)
  #expect(backend.forceStopCalls == 0)
}

@MainActor private func boundedInactiveSettlement(
  _ controller: VMController, backend: RecoveryBackend
) async throws -> VMError? {
  var completed = false
  let settlement = Task { @MainActor () -> VMError? in
    defer { completed = true }
    do {
      try await controller.settleRuntime()
      return nil
    } catch { return error as? VMError }
  }
  for _ in 0..<20 {
    if completed { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(completed, "An inactive backend must not wait indefinitely for a missing callback.")
  if !completed {
    // Test-only recovery makes a regression fail without leaving an unbounded fixture task.
    backend.guestShutdown()
  }
  return await settlement.value
}

@Test(arguments: ["running", "pending-stop"])
@MainActor func missingInactiveCallbackIsRecordedAsFailureAndSettles(state: String) async throws {
  let backend = RecoveryBackend()
  let history = RecoveryHistory()
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  try await controller.perform(.start)
  await controller.finishPersistence()
  if state == "pending-stop" {
    try await controller.perform(.stop)
    await controller.finishPersistence()
    #expect(controller.state == .stopping)
  } else {
    #expect(controller.state == .running)
  }
  backend.isActive = false  // Inject actual inactivity with no completion or stop callback.
  #expect(!released)
  let failure = try await boundedInactiveSettlement(controller, backend: backend)
  #expect(failure?.code == .backendFailure)
  #expect(controller.state == .failed)
  #expect(controller.runtimeError == failure)
  #expect(released)
  #expect(!controller.isSettling)
  #expect(history.snapshots.last?.state == .failed)
  #expect(history.snapshots.last?.operation == nil)
  #expect(history.snapshots.last?.backendActive == false)
  #expect(history.snapshots.last?.outcome == .failed)
  #expect(
    !history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .forcedStopped })
  #expect(backend.forceStopCalls == 0)
}

private actor CommitThenFailHistoryStore: RuntimeHistoryStore {
  private let files = VMFiles()
  private(set) var atomicCalls = 0
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
    atomicCalls += 1
    try await files.atomicWrite(data, at: url)
    throw VMError(
      .storage, "Injected error after metadata commit.", recovery: "Disposable fixture only.")
  }
}

@Test @MainActor func postCommitHistoryFaultFreezesSessionAndPreservesCommittedSequence()
  async throws
{
  let directory = try recoveryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let lock = try VMLock(directory: directory)
  let prior = RuntimeRecord(
    sessionID: UUID(), sequence: 7, recordedAt: 100,
    snapshot: RuntimeSnapshot(
      state: .running, operation: nil, backendActive: true, outcome: .pending))
  let priorBytes = try RuntimeHistoryCodec.encode(prior)
  let runtime = directory.appendingPathComponent("runtime.json")
  let identity = directory.appendingPathComponent("preserved-identity")
  let identityBytes = Data("Original test identity stays unchanged.".utf8)
  try await files.atomicWrite(priorBytes, at: runtime)
  try await files.writeNewMetadata(identityBytes, at: identity)
  let store = CommitThenFailHistoryStore()
  let history = try await VMRuntimeHistory.open(in: directory, files: store, lock: lock)
  let intent = RuntimeSnapshot(
    state: .starting, operation: .start, backendActive: false, outcome: .pending)
  await #expect(throws: VMError.self) { try await history.persist(intent) }
  let committedBytes = try await files.readMetadata(at: runtime)
  let committed = try RuntimeHistoryCodec.decode(committedBytes)
  #expect(committed.sessionID != prior.sessionID)
  #expect(committed.sequence == 1)
  #expect(committed.snapshot == intent)
  #expect(await store.atomicCalls == 1)
  let stop = RuntimeSnapshot(
    state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped)
  await #expect(throws: VMError.self) { try await history.persist(stop) }
  #expect(await store.atomicCalls == 1)
  #expect(try await files.readMetadata(at: runtime) == committedBytes)
  let archive = directory.appendingPathComponent(
    "runtime-\(prior.sessionID.uuidString.lowercased()).json")
  #expect(try await files.readMetadata(at: archive) == priorBytes)
  #expect(try await files.readMetadata(at: identity) == identityBytes)
}
