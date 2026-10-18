// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

private func recorded(_ snapshot: RuntimeSnapshot, version: Int = 1) -> RuntimeRecord {
  RuntimeRecord(
    sessionID: UUID(), sequence: 1, recordedAt: 100, snapshot: snapshot, schemaVersion: version)
}
private let launching = RuntimeSnapshot(
  state: .starting, operation: .start, backendActive: false, outcome: .pending)
private let stopped = RuntimeSnapshot(
  state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped)

@Test func runtimeCodecRejectsFalseStopFutureSchemaAndUnboundedInputs() throws {
  let valid = recorded(stopped)
  #expect(try RuntimeHistoryCodec.decode(RuntimeHistoryCodec.encode(valid)) == valid)
  #expect(throws: VMError.self) { try RuntimeHistoryCodec.encode(recorded(stopped, version: 2)) }
  #expect(throws: VMError.self) {
    try RuntimeHistoryCodec.encode(
      recorded(
        RuntimeSnapshot(
          state: .stopped,
          operation: nil, backendActive: true, outcome: .guestStopped)))
  }
  #expect(throws: VMError.self) {
    try RuntimeHistoryCodec.encode(
      recorded(
        RuntimeSnapshot(
          state: .stopping,
          operation: .stop, backendActive: true, outcome: .guestStopped)))
  }
  #expect(throws: VMError.self) { try RuntimeHistoryCodec.decode(Data(repeating: 0, count: 4097)) }
  #expect(throws: VMError.self) { try RuntimeHistoryCodec.decode(Data("{broken".utf8)) }
  #expect(throws: VMError.self) {
    try RuntimeHistoryCodec.encode(
      RuntimeRecord(
        sessionID: UUID(), sequence: 0,
        recordedAt: 100, snapshot: launching))
  }
  #expect(throws: VMError.self) {
    try RuntimeHistoryCodec.encode(
      RuntimeRecord(
        sessionID: UUID(), sequence: 1,
        recordedAt: .nan, snapshot: launching))
  }
  #expect(
    RuntimeHistoryCodec.status(recorded(launching), writer: .available)
      == .interruptedOrUnreconciled)
  #expect(RuntimeHistoryCodec.status(valid, writer: .held) == .writerHeld)
}

private func historyDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macopenvm-history-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return url
}

@Test @MainActor func priorInterruptedHistoryIsArchivedExactlyWithoutReplacingIdentity()
  async throws
{
  let directory = try historyDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let lock = try VMLock(directory: directory)
  let prior = recorded(launching)
  let bytes = try RuntimeHistoryCodec.encode(prior)
  try await files.atomicWrite(bytes, at: directory.appendingPathComponent("runtime.json"))
  let identity = directory.appendingPathComponent("identity-sentinel")
  try Data("preserved identity".utf8).write(to: identity)
  let history = try await VMRuntimeHistory.open(
    in: directory, files: files, lock: lock, now: { Date(timeIntervalSince1970: 200) })
  #expect(history.previousStatus == .interruptedOrUnreconciled)
  #expect(
    try await files.readMetadata(at: directory.appendingPathComponent("runtime.json")) == bytes)
  try await history.persist(launching)
  try await history.persist(stopped)
  let archive = directory.appendingPathComponent(
    "runtime-\(prior.sessionID.uuidString.lowercased()).json")
  #expect(try await files.readMetadata(at: archive) == bytes)
  let current = try RuntimeHistoryCodec.decode(
    await files.readMetadata(at: directory.appendingPathComponent("runtime.json")))
  #expect(current.sequence == 2)
  #expect(current.sessionID != prior.sessionID)
  #expect(current.snapshot == stopped)
  #expect(current.recordedAt == 200)
  #expect(try Data(contentsOf: identity) == Data("preserved identity".utf8))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasPrefix("runtime-")
    }.count == 1)
}

@Test @MainActor func corruptOrAliasedHistoryAndWrongLockArePreserved() async throws {
  let directory = try historyDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let lock = try VMLock(directory: directory)
  let url = directory.appendingPathComponent("runtime.json")
  let sentinel = Data("{corrupt preserved history".utf8)
  try sentinel.write(to: url)
  let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  await #expect(throws: VMError.self) { try await VMRuntimeHistory.open(in: directory, lock: lock) }
  #expect(try Data(contentsOf: url) == sentinel)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
  try FileManager.default.removeItem(at: url)
  #expect(mkfifo(url.path, 0o600) == 0)
  await #expect(throws: VMError.self) { try await VMRuntimeHistory.open(in: directory, lock: lock) }
  #expect((await VMFiles().status(at: url)).kind == .other)
  try FileManager.default.removeItem(at: url)
  let target = directory.appendingPathComponent("source-history")
  let original = try RuntimeHistoryCodec.encode(recorded(stopped))
  try original.write(to: target)
  try FileManager.default.linkItem(at: target, to: url)
  await #expect(throws: VMError.self) { try await VMRuntimeHistory.open(in: directory, lock: lock) }
  #expect(try Data(contentsOf: target) == original)
  #expect((await VMFiles().status(at: url)).links == 2)
  let other = try historyDirectory()
  defer { try? FileManager.default.removeItem(at: other) }
  await #expect(throws: VMError.self) { try await VMRuntimeHistory.open(in: other, lock: lock) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
}

@Test @MainActor func conflictingArchiveBlocksLaunchAndPreservesPriorRecord() async throws {
  let directory = try historyDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let lock = try VMLock(directory: directory)
  let prior = recorded(launching)
  let original = try RuntimeHistoryCodec.encode(prior)
  let runtime = directory.appendingPathComponent("runtime.json")
  try await files.atomicWrite(original, at: runtime)
  let archive = directory.appendingPathComponent(
    "runtime-\(prior.sessionID.uuidString.lowercased()).json")
  let conflict = Data("preserved conflicting archive".utf8)
  try await files.writeNewMetadata(conflict, at: archive)
  let history = try await VMRuntimeHistory.open(in: directory, files: files, lock: lock)
  let backend = FakeBackend()
  let controller = VMController(backend: backend, history: history)
  await #expect(throws: VMError.self) { try await controller.perform(.start) }
  #expect(!backend.isActive)
  #expect(controller.state == .failed)
  #expect(controller.historyError != nil)
  #expect(try await files.readMetadata(at: runtime) == original)
  #expect(try await files.readMetadata(at: archive) == conflict)
}

@MainActor private final class ControlledHistory: LifecycleHistory {
  var snapshots: [RuntimeSnapshot] = []
  var fail = false
  var blockGuestStop = false
  private var blocked: CheckedContinuation<Void, Never>?
  private var waiting: CheckedContinuation<Void, Never>?
  func persist(_ snapshot: RuntimeSnapshot) async throws {
    snapshots.append(snapshot)
    if fail { throw VMError(.storage, "Injected history failure.", recovery: "Test fixture only.") }
    if blockGuestStop && snapshot.outcome == .guestStopped {
      await withCheckedContinuation { continuation in
        blocked = continuation
        waiting?.resume()
        waiting = nil
      }
    }
  }
  func waitUntilBlocked() async {
    if blocked != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func release() {
    blocked?.resume()
    blocked = nil
  }
}

@Test @MainActor func launchIntentFailurePreventsNativeStartAndUnsupportedCallsWriteNothing()
  async throws
{
  let backend = FakeBackend()
  let history = ControlledHistory()
  history.fail = true
  let controller = VMController(backend: backend, history: history)
  await #expect(throws: VMError.self) { try await controller.perform(.suspend) }
  #expect(history.snapshots.isEmpty)
  await #expect(throws: VMError.self) { try await controller.perform(.start) }
  #expect(!backend.isActive)
  #expect(history.snapshots.count == 1)
  #expect(history.snapshots.first?.state == .starting)
  #expect(controller.historyError != nil)
}

@Test @MainActor func activeHistoryFailureRetainsOwnershipAndNeverRecordsCleanStop() async throws {
  let backend = FakeBackend()
  let history = ControlledHistory()
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  try await controller.perform(.start)
  await controller.finishPersistence()
  history.fail = true
  try await controller.perform(.pause)
  await controller.finishPersistence()
  #expect(controller.isActive)
  #expect(!released)
  #expect(controller.historyError != nil)
  backend.failStop = true
  await #expect(throws: VMError.self) { try await controller.perform(.forceStop) }
  await controller.finishPersistence()
  #expect(controller.isActive)
  #expect(!released)
  #expect(
    !history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .forcedStopped })
}

@Test(.timeLimit(.minutes(1))) @MainActor func observedStopKeepsOwnerUntilItsOrderedRecordSettles()
  async throws
{
  let backend = FakeBackend()
  let history = ControlledHistory()
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  try await controller.perform(.start)
  await controller.finishPersistence()
  try await controller.perform(.stop)
  await controller.finishPersistence()
  #expect(controller.state == .stopping)
  #expect(history.snapshots.last?.outcome == .pending)
  #expect(!released)
  history.blockGuestStop = true
  backend.guestShutdown()
  await history.waitUntilBlocked()
  #expect(controller.state == .stopped)
  #expect(controller.isSettling)
  #expect(!released)
  history.release()
  await controller.finishPersistence()
  #expect(released)
  #expect(!controller.isSettling)
  #expect(history.snapshots.last == stopped)
  await #expect(throws: VMError.self) { try await controller.perform(.start) }
}

@Test @MainActor func forceStopCallbackIsRecordedAsForcedAndNotGuestShutdown() async throws {
  let backend = FakeBackend()
  let history = ControlledHistory()
  let controller = VMController(backend: backend, history: history)
  try await controller.perform(.start)
  try await controller.perform(.forceStop)
  await controller.finishPersistence()
  #expect(controller.state == .stopped)
  #expect(history.snapshots.last?.outcome == .forcedStopped)
  #expect(!history.snapshots.contains { $0.outcome == .guestStopped })
}

@Test @MainActor func dishonestForceStopCompletionCannotReleaseWriterOrClaimStopped() async throws {
  let backend = FakeBackend()
  backend.pretendForceStopCompletion = true
  let history = ControlledHistory()
  let controller = VMController(backend: backend, history: history)
  var released = false
  controller.onQuiescent = { released = true }
  try await controller.perform(.start)
  await #expect(throws: VMError.self) { try await controller.perform(.forceStop) }
  await controller.finishPersistence()
  #expect(controller.state == .failed)
  #expect(controller.isActive)
  #expect(!released)
  #expect(history.snapshots.last?.outcome == .failed)
  #expect(
    !history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .forcedStopped })
}

@Test func inspectionClassifiesUnfinishedForcedAndInvalidHistoryWithoutExposingRecordFields()
  async throws
{
  let directory = try historyDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let runtime = directory.appendingPathComponent("runtime.json")
  let inspector = VMInspection(files: files)
  for (snapshot, expected) in [
    (launching, RuntimeHistoryStatus.interruptedOrUnreconciled),
    (stopped, .guestStopRecorded),
    (
      RuntimeSnapshot(
        state: .stopped, operation: nil, backendActive: false, outcome: .forcedStopped),
      .forcedStopRecorded
    ),
  ] {
    let record = recorded(snapshot)
    let bytes = try RuntimeHistoryCodec.encode(record)
    try await files.atomicWrite(bytes, at: runtime)
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let report = await inspector.inspect(at: directory)
    #expect(report.history == expected)
    #expect(report.writer == .missing)
    #expect(try await files.readMetadata(at: runtime) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == entries)
    let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    #expect(!output.contains(record.sessionID.uuidString))
    #expect(!output.contains("sessionID"))
    #expect(!output.contains("recordedAt"))
    #expect(!output.contains(directory.path))
  }
  let malformed = Data("{broken runtime preserved".utf8)
  try await files.atomicWrite(malformed, at: runtime)
  #expect(await inspector.inspect(at: directory).history == .invalid)
  #expect(try await files.readMetadata(at: runtime) == malformed)
  #expect(
    (await files.status(at: directory.appendingPathComponent("writer.lock"))).kind == .missing)
}
