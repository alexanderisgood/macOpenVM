// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@MainActor private final class WeakHistoryOwner<Owner: AnyObject> {
  weak var value: Owner?
  init(_ value: Owner?) { self.value = value }
}

private func sessionHistoryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-history-session-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return directory
}

private func sessionIntentBytes(vmID: UUID, sessionID: UUID, state: String = "unsettled") -> Data {
  Data(
    ("{\"schemaVersion\":1,\"vmID\":\"\(vmID.uuidString)\","
      + "\"sessionID\":\"\(sessionID.uuidString)\",\"state\":\"\(state)\"}").utf8)
}

private let sessionStarting = RuntimeSnapshot(
  state: .starting, operation: .start, backendActive: false, outcome: .pending)
private let sessionRunning = RuntimeSnapshot(
  state: .running, operation: nil, backendActive: true, outcome: .pending)

/// Every operation remains injectable. Ownership reading delegates to Storage's strict
/// reader rather than a second decoder or an unobserved VMFiles instance in Core.
private actor SessionHistoryStore: RuntimeHistoryStore {
  enum Mutation: Sendable {
    case intentDuringSpaceCheck(Data)
    case intentDuringArchiveStatus(Data)
    case intentAfterArchiveWrite(Data)
    case writerDuringSpaceCheck
  }
  let files = VMFiles()
  private var mutation: Mutation?
  private var failRead = false
  private var failAfterCommit = false
  private var mutationFailed = false
  private(set) var intentReads = 0
  private(set) var archiveWrites = 0
  private(set) var atomicWrites = 0

  func configure(mutation: Mutation? = nil, failRead: Bool = false, failAfterCommit: Bool = false) {
    self.mutation = mutation
    self.failRead = failRead
    self.failAfterCommit = failAfterCommit
    mutationFailed = false
  }
  func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    intentReads += 1
    if mutationFailed { throw sessionHistoryFailure() }
    return try await files.readRuntimeIntent(in: directory)
  }
  func status(at url: URL) async -> VMFileStatus {
    if url.lastPathComponent.hasPrefix("runtime-"),
      url.lastPathComponent != RuntimeIntent.filename,
      case .intentDuringArchiveStatus(let bytes)? = mutation
    {
      mutation = nil
      // A controlled failure below is observable through the following strict read.
      do {
        try await files.atomicWrite(
          bytes, at: url.deletingLastPathComponent().appendingPathComponent(RuntimeIntent.filename))
      } catch {
        mutationFailed = true
      }
    }
    return await files.status(at: url)
  }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    if failRead { throw sessionHistoryFailure() }
    return try await files.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    if let mutation {
      switch mutation {
      case .intentDuringSpaceCheck(let bytes):
        self.mutation = nil
        try await files.atomicWrite(
          bytes, at: directory.appendingPathComponent(RuntimeIntent.filename))
      case .writerDuringSpaceCheck:
        self.mutation = nil
        let writer = directory.appendingPathComponent("writer.lock")
        try FileManager.default.moveItem(
          at: writer, to: directory.appendingPathComponent("preserved-writer.lock"))
        try await files.writeNewMetadata(Data(), at: writer)
      case .intentDuringArchiveStatus, .intentAfterArchiveWrite: break
      }
    }
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    archiveWrites += 1
    try await files.writeNewMetadata(data, at: url)
    if case .intentAfterArchiveWrite(let bytes)? = mutation {
      mutation = nil
      try await files.atomicWrite(
        bytes, at: url.deletingLastPathComponent().appendingPathComponent(RuntimeIntent.filename))
    }
  }
  func atomicWrite(_ data: Data, at url: URL) async throws {
    atomicWrites += 1
    try await files.atomicWrite(data, at: url)
    if failAfterCommit { throw sessionHistoryFailure() }
  }
}

/// Deliberately omits the strict reader to exercise the fail-closed protocol default.
private actor LegacySessionHistoryStore: RuntimeHistoryStore {
  let files = VMFiles()
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

private func sessionHistoryFailure() -> VMError {
  VMError(.storage, "Injected session-history failure.", recovery: "Disposable fixture only.")
}

@Suite(.serialized) @MainActor struct RuntimeHistorySessionTests {
  @Test func permitSessionAndOwnerAreRetainedThroughOrderedHistory() async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    var owner: VMLock? = try VMLock(directory: directory, expectedVMID: vmID)
    let weakOwner = WeakHistoryOwner(owner)
    let files = VMFiles()
    let prior = RuntimeRecord(
      sessionID: UUID(), sequence: 7, recordedAt: 100, snapshot: sessionRunning)
    let priorBytes = try RuntimeHistoryCodec.encode(prior)
    let runtime = directory.appendingPathComponent("runtime.json")
    try await files.atomicWrite(priorBytes, at: runtime)
    var permit: RuntimeSessionPermit? = try await files.beginRuntimeSession(
      in: directory, forVMID: vmID, lock: try #require(owner))
    let weakPermit = WeakHistoryOwner(permit)
    let sessionID = try #require(permit).sessionID
    let intent = try await files.readMetadata(
      at: directory.appendingPathComponent(RuntimeIntent.filename))
    let store = SessionHistoryStore()
    var history: VMRuntimeHistory? = try await VMRuntimeHistory.open(
      in: directory, files: store, lock: try #require(owner), permit: permit,
      now: { Date(timeIntervalSince1970: 200) })
    withExtendedLifetime((owner, permit)) {}
    owner = nil
    permit = nil
    #expect(weakOwner.value != nil && weakPermit.value != nil)
    try await history?.persist(sessionStarting)
    try await history?.persist(sessionRunning)
    let current = try RuntimeHistoryCodec.decode(await files.readMetadata(at: runtime))
    #expect(current.sessionID == sessionID && current.sequence == 2)
    #expect(current.recordedAt == 200 && current.snapshot == sessionRunning)
    let archive = directory.appendingPathComponent(
      "runtime-\(prior.sessionID.uuidString.lowercased()).json")
    #expect(try await files.readMetadata(at: archive) == priorBytes)
    #expect(
      try await files.readMetadata(at: directory.appendingPathComponent(RuntimeIntent.filename))
        == intent)
    #expect(await store.archiveWrites == 1)
    #expect(await store.atomicWrites == 2)
    #expect(await store.intentReads > 2)
    withExtendedLifetime(history) {}
    history = nil
    #expect(weakOwner.value == nil && weakPermit.value == nil)
    #expect(await files.writerStatus(in: directory) == .available)
    #expect(throws: VMError.self) { _ = try VMLock(directory: directory, expectedVMID: vmID) }
  }

  @Test func duplicatePermitOpenCannotCreateAnotherSequenceWriter() async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    let owner = try VMLock(directory: directory, expectedVMID: vmID)
    let permit = try await VMFiles().beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
    let store = SessionHistoryStore()
    let history = try await VMRuntimeHistory.open(
      in: directory, files: store, lock: owner, permit: permit)
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner, permit: permit)
    }
    try await history.persist(sessionStarting)
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner, permit: permit)
    }
    #expect(await store.atomicWrites == 1)
    let current = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(current.sequence == 1 && current.sessionID == permit.sessionID)
  }

  @Test func failedOpenConsumesBindingAndPreservesPriorHistory() async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    let owner = try VMLock(directory: directory, expectedVMID: vmID)
    let files = VMFiles()
    let runtime = directory.appendingPathComponent("runtime.json")
    let original = try RuntimeHistoryCodec.encode(
      RuntimeRecord(sessionID: UUID(), sequence: 3, recordedAt: 100, snapshot: sessionRunning))
    try await files.atomicWrite(original, at: runtime)
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
    let store = SessionHistoryStore()
    await store.configure(failRead: true)
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner, permit: permit)
    }
    await store.configure()
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner, permit: permit)
    }
    #expect(try await files.readMetadata(at: runtime) == original)
    #expect(await store.archiveWrites == 0)
    #expect(await store.atomicWrites == 0)
  }

  @Test func priorSameSessionCannotBeReopenedWithSequenceReset() async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    let owner = try VMLock(directory: directory, expectedVMID: vmID)
    let files = VMFiles()
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
    let runtime = directory.appendingPathComponent("runtime.json")
    let original = try RuntimeHistoryCodec.encode(
      RuntimeRecord(
        sessionID: permit.sessionID, sequence: 7, recordedAt: 100, snapshot: sessionRunning))
    try await files.atomicWrite(original, at: runtime)
    let store = SessionHistoryStore()
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner, permit: permit)
    }
    #expect(try await files.readMetadata(at: runtime) == original)
    #expect(await store.archiveWrites == 0)
    #expect(await store.atomicWrites == 0)
  }

  @Test func diskIntentAndAnotherLockCannotReconstructHistoryAuthority() async throws {
    let directory = try sessionHistoryDirectory()
    let other = try sessionHistoryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: other)
    }
    let vmID = UUID()
    let owner = try VMLock(directory: directory, expectedVMID: vmID)
    let otherOwner = try VMLock(directory: other, expectedVMID: vmID)
    let files = VMFiles()
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
    let bytes = try await files.readMetadata(
      at: directory.appendingPathComponent(RuntimeIntent.filename))
    try await files.atomicWrite(bytes, at: other.appendingPathComponent(RuntimeIntent.filename))
    let store = SessionHistoryStore()
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner)
    }
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: other, files: store, lock: otherOwner, permit: permit)
    }
    #expect(await store.archiveWrites == 0)
    #expect(await store.atomicWrites == 0)
    #expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.json").path)
    )
    #expect(
      !FileManager.default.fileExists(atPath: other.appendingPathComponent("runtime.json").path))
  }

  @Test(arguments: ["vm", "session", "settled", "missing"])
  func mismatchedCurrentIntentRejectsPermitWithoutWriting(_ kind: String) async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    let owner = try VMLock(directory: directory, expectedVMID: vmID)
    let files = VMFiles()
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
    let intent = directory.appendingPathComponent(RuntimeIntent.filename)
    if kind == "missing" {
      try FileManager.default.removeItem(at: intent)
    } else {
      try await files.atomicWrite(
        sessionIntentBytes(
          vmID: kind == "vm" ? UUID() : vmID,
          sessionID: kind == "session" ? UUID() : permit.sessionID,
          state: kind == "settled" ? "settled" : "unsettled"), at: intent)
    }
    let store = SessionHistoryStore()
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner, permit: permit)
    }
    #expect(await store.archiveWrites == 0)
    #expect(await store.atomicWrites == 0)
  }

  @Test func defaultInjectedReaderAllowsOnlyAbsentLegacyIntent() async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = try VMLock(directory: directory)
    let store = LegacySessionHistoryStore()
    let history = try await VMRuntimeHistory.open(in: directory, files: store, lock: owner)
    try await history.persist(sessionStarting)
    let current = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json")))
    #expect(current.sequence == 1)
    let original = sessionIntentBytes(vmID: UUID(), sessionID: UUID(), state: "settled")
    try await VMFiles().atomicWrite(
      original, at: directory.appendingPathComponent(RuntimeIntent.filename))
    await #expect(throws: VMError.self) {
      try await VMRuntimeHistory.open(in: directory, files: store, lock: owner)
    }
    await #expect(throws: VMError.self) { try await history.persist(sessionRunning) }
    #expect(
      try await VMFiles().readMetadata(at: directory.appendingPathComponent(RuntimeIntent.filename))
        == original)
  }

  @Test(arguments: ["intent", "writer", "archive", "afterArchive"])
  func boundaryReplacementFreezesAllLaterHistoryWrites(_ kind: String) async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    let owner = try VMLock(directory: directory, expectedVMID: vmID)
    let files = VMFiles()
    let prior = RuntimeRecord(
      sessionID: UUID(), sequence: 2, recordedAt: 100, snapshot: sessionRunning)
    let priorBytes = try RuntimeHistoryCodec.encode(prior)
    let runtime = directory.appendingPathComponent("runtime.json")
    try await files.atomicWrite(priorBytes, at: runtime)
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
    let store = SessionHistoryStore()
    let history = try await VMRuntimeHistory.open(
      in: directory, files: store, lock: owner, permit: permit)
    let changed = sessionIntentBytes(vmID: vmID, sessionID: UUID())
    let mutation: SessionHistoryStore.Mutation
    switch kind {
    case "writer": mutation = .writerDuringSpaceCheck
    case "archive": mutation = .intentDuringArchiveStatus(changed)
    case "afterArchive": mutation = .intentAfterArchiveWrite(changed)
    default: mutation = .intentDuringSpaceCheck(changed)
    }
    await store.configure(mutation: mutation)
    await #expect(throws: VMError.self) { try await history.persist(sessionStarting) }
    await store.configure()
    await #expect(throws: VMError.self) { try await history.persist(sessionRunning) }
    #expect(await store.archiveWrites == (kind == "afterArchive" ? 1 : 0))
    #expect(await store.atomicWrites == 0)
    #expect(try await files.readMetadata(at: runtime) == priorBytes)
    let archive = directory.appendingPathComponent(
      "runtime-\(prior.sessionID.uuidString.lowercased()).json")
    if kind == "afterArchive" {
      #expect(try await files.readMetadata(at: archive) == priorBytes)
    } else {
      #expect(!FileManager.default.fileExists(atPath: archive.path))
    }
  }

  @Test func committedWriteFailureFreezesSameSessionAndKeepsIntentUnsettled() async throws {
    let directory = try sessionHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    let owner = try VMLock(directory: directory, expectedVMID: vmID)
    let files = VMFiles()
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
    let store = SessionHistoryStore()
    let history = try await VMRuntimeHistory.open(
      in: directory, files: store, lock: owner, permit: permit)
    await store.configure(failAfterCommit: true)
    await #expect(throws: VMError.self) { try await history.persist(sessionStarting) }
    let runtime = directory.appendingPathComponent("runtime.json")
    let committed = try await files.readMetadata(at: runtime)
    let record = try RuntimeHistoryCodec.decode(committed)
    #expect(record.sequence == 1 && record.sessionID == permit.sessionID)
    await store.configure()
    await #expect(throws: VMError.self) { try await history.persist(sessionRunning) }
    #expect(await store.atomicWrites == 1)
    #expect(try await files.readMetadata(at: runtime) == committed)
    let intent = try #require(try await files.readRuntimeIntent(in: directory))
    #expect(intent.state == .unsettled && intent.sessionID == permit.sessionID)
  }
}
