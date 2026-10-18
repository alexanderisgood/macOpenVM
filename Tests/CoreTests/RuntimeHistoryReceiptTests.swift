// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

private let receiptStarting = RuntimeSnapshot(
  state: .starting, operation: .start, backendActive: false, outcome: .pending)
private let receiptStopped = RuntimeSnapshot(
  state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped)

private func receiptDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-history-receipt-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return directory
}

private func receiptTestError() -> VMError {
  VMError(.storage, "Injected receipt fixture error.", recovery: "Disposable fixture only.")
}

@MainActor private final class WeakReceiptOwner<Owner: AnyObject> {
  weak var value: Owner?
  init(_ value: Owner?) { self.value = value }
}

private actor ReceiptHistoryStore: RuntimeHistoryStore {
  enum Fault: Sendable {
    case commitAfterWrite, readFailure
    case replaceRuntime(Data)
    case replaceIntent(Data)
    case replaceWriter
  }
  let files = VMFiles()
  private var fault: Fault?
  private var blockNextCommit = false
  private var commitGate: CheckedContinuation<Void, Never>?
  private(set) var atomicCalls = 0
  private(set) var boundedReadLimits: [Int] = []

  func configure(_ fault: Fault? = nil, blockNextCommit: Bool = false) {
    self.fault = fault
    self.blockNextCommit = blockNextCommit
  }
  func commitIsBlocked() -> Bool { commitGate != nil }
  func releaseCommit() {
    commitGate?.resume()
    commitGate = nil
  }
  func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    try await files.readRuntimeIntent(in: directory)
  }
  func status(at url: URL) async -> VMFileStatus { await files.status(at: url) }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    boundedReadLimits.append(limit)
    if url.lastPathComponent == "runtime.json", let fault {
      self.fault = nil
      switch fault {
      case .readFailure: throw receiptTestError()
      case .replaceRuntime(let bytes): try await files.atomicWrite(bytes, at: url)
      case .replaceIntent(let bytes):
        try await files.atomicWrite(
          bytes, at: url.deletingLastPathComponent().appendingPathComponent(RuntimeIntent.filename))
      case .replaceWriter:
        let directory = url.deletingLastPathComponent()
        let writer = directory.appendingPathComponent("writer.lock")
        try FileManager.default.moveItem(
          at: writer, to: directory.appendingPathComponent("preserved-writer.lock"))
        try await files.writeNewMetadata(Data(), at: writer)
      case .commitAfterWrite: break
      }
    }
    return try await files.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    try await files.writeNewMetadata(data, at: url)
  }
  func atomicWrite(_ data: Data, at url: URL) async throws {
    atomicCalls += 1
    if blockNextCommit {
      blockNextCommit = false
      await withCheckedContinuation { commitGate = $0 }
    }
    try await files.atomicWrite(data, at: url)
    if case .commitAfterWrite? = fault { throw receiptTestError() }
  }
}

@MainActor private struct ReceiptHistoryFixture {
  let directory: URL
  let owner: VMLock
  let permit: RuntimeSessionPermit
  let store: ReceiptHistoryStore
  let history: VMRuntimeHistory

  static func create() async throws -> Self {
    let directory = try receiptDirectory()
    do {
      let vmID = UUID()
      let owner = try VMLock(directory: directory, expectedVMID: vmID)
      let permit = try await VMFiles().beginRuntimeSession(
        in: directory, forVMID: vmID, lock: owner)
      let store = ReceiptHistoryStore()
      let history = try await VMRuntimeHistory.open(
        in: directory, files: store, lock: owner, permit: permit)
      return Self(
        directory: directory, owner: owner, permit: permit, store: store, history: history)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func currentBytes() async throws -> Data {
    try await VMFiles().readMetadata(at: directory.appendingPathComponent("runtime.json"))
  }
  func currentIntent() async throws -> RuntimeIntent {
    let current = try await VMFiles().readRuntimeIntent(in: directory)
    return try #require(current)
  }
}

private func waitForReceiptCommitGate(_ store: ReceiptHistoryStore) async throws {
  for _ in 0..<200 {
    if await store.commitIsBlocked() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw receiptTestError()
}

@Suite(.serialized) @MainActor struct RuntimeHistoryReceiptTests {
  @Test(arguments: [RuntimeOutcome.guestStopped, .forcedStopped, .failed])
  func onlyActualFinalCommittedBytesCanSeal(_ outcome: RuntimeOutcome) async throws {
    let fixture = try await ReceiptHistoryFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.history.persist(receiptStarting)
    let final = RuntimeSnapshot(
      state: outcome == .failed ? .failed : .stopped, operation: nil, backendActive: false,
      outcome: outcome)
    try await fixture.history.persist(final)
    let bytes = try await fixture.currentBytes()
    let intent = try await fixture.currentIntent()
    let receipt = try await fixture.history.sealCommittedHistory(for: fixture.permit)
    #expect(receipt.isFrom(fixture.history))
    #expect(receipt.sourceID == ObjectIdentifier(fixture.history))
    #expect(receipt.permit === fixture.permit && receipt.sequence == 2)
    #expect(receipt.finalBytes == bytes && !receipt.finalBytes.isEmpty)
    #expect(receipt.finalBytes.count <= RuntimeHistoryCodec.maximumBytes)
    let record = try RuntimeHistoryCodec.decode(receipt.finalBytes)
    #expect(record.sessionID == fixture.permit.sessionID && record.snapshot == final)
    #expect(try await fixture.currentIntent() == intent)
    #expect(intent.state == .unsettled)
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    await #expect(throws: VMError.self) { try await fixture.history.persist(receiptStarting) }
    #expect(await fixture.store.atomicCalls == 2)
    #expect(await fixture.store.boundedReadLimits == [RuntimeHistoryCodec.maximumBytes])
    #expect(try await fixture.currentBytes() == bytes)
  }

  @Test(arguments: ["none", "pending", "activeFailure", "operatingFailure"])
  func nonfinalOrUncommittedHistoryCannotMintAndAttemptIsPermanent(_ kind: String) async throws {
    let fixture = try await ReceiptHistoryFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    if kind != "none" {
      let snapshot =
        kind == "pending"
        ? receiptStarting
        : RuntimeSnapshot(
          state: .failed, operation: kind == "operatingFailure" ? .pause : nil,
          backendActive: kind == "activeFailure", outcome: .failed)
      try await fixture.history.persist(snapshot)
    }
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    await #expect(throws: VMError.self) { try await fixture.history.persist(receiptStopped) }
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    #expect(await fixture.store.atomicCalls == (kind == "none" ? 0 : 1))
    #expect(try await fixture.currentIntent().state == .unsettled)
  }

  @Test func legacyAndWrongPermitCannotMintHistoryReceipt() async throws {
    let fixture = try await ReceiptHistoryFixture.create()
    let other = try await ReceiptHistoryFixture.create()
    let legacy = try receiptDirectory()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
      try? FileManager.default.removeItem(at: other.directory)
      try? FileManager.default.removeItem(at: legacy)
    }
    try await fixture.history.persist(receiptStopped)
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: other.permit)
    }
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    let owner = try VMLock(directory: legacy)
    let legacyHistory = try await VMRuntimeHistory.open(in: legacy, lock: owner)
    try await legacyHistory.persist(receiptStopped)
    await #expect(throws: VMError.self) {
      try await legacyHistory.sealCommittedHistory(for: fixture.permit)
    }
    await #expect(throws: VMError.self) { try await legacyHistory.persist(receiptStarting) }
    #expect(try await fixture.currentIntent().state == .unsettled)
    #expect(try await VMFiles().readRuntimeIntent(in: legacy) == nil)
  }

  @Test func commitErrorCannotMintEvenIfFinalBytesReachedDisk() async throws {
    let fixture = try await ReceiptHistoryFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    await fixture.store.configure(.commitAfterWrite)
    await #expect(throws: VMError.self) { try await fixture.history.persist(receiptStopped) }
    let bytes = try await fixture.currentBytes()
    let record = try RuntimeHistoryCodec.decode(bytes)
    #expect(record.sessionID == fixture.permit.sessionID && record.snapshot == receiptStopped)
    await fixture.store.configure()
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    await #expect(throws: VMError.self) { try await fixture.history.persist(receiptStopped) }
    #expect(await fixture.store.atomicCalls == 1)
    #expect(try await fixture.currentBytes() == bytes)
    #expect(try await fixture.currentIntent().state == .unsettled)
  }

  @Test(arguments: ["bytes", "oversized", "writer", "intent", "read"])
  func sealReadbackOrOwnershipFaultNeverRetries(_ kind: String) async throws {
    let fixture = try await ReceiptHistoryFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.history.persist(receiptStopped)
    let fault: ReceiptHistoryStore.Fault
    switch kind {
    case "bytes":
      fault = .replaceRuntime(
        try RuntimeHistoryCodec.encode(
          RuntimeRecord(
            sessionID: fixture.permit.sessionID, sequence: 2, recordedAt: 100,
            snapshot: receiptStopped)))
    case "oversized": fault = .replaceRuntime(Data(repeating: 32, count: 4097))
    case "writer": fault = .replaceWriter
    case "intent":
      fault = .replaceIntent(
        Data(
          ("{\"schemaVersion\":1,\"vmID\":\"\(fixture.permit.vmID.uuidString)\","
            + "\"sessionID\":\"\(UUID().uuidString)\",\"state\":\"unsettled\"}").utf8))
    default: fault = .readFailure
    }
    await fixture.store.configure(fault)
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    await fixture.store.configure()
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    await #expect(throws: VMError.self) { try await fixture.history.persist(receiptStopped) }
    #expect(await fixture.store.atomicCalls == 1)
    #expect(try await fixture.currentIntent().state == .unsettled)
  }

  @Test func busySealDoesNotConsumeQuiescentAttempt() async throws {
    let fixture = try await ReceiptHistoryFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    await fixture.store.configure(blockNextCommit: true)
    let write = Task { try await fixture.history.persist(receiptStopped) }
    do {
      try await waitForReceiptCommitGate(fixture.store)
      do {
        _ = try await fixture.history.sealCommittedHistory(for: fixture.permit)
        Issue.record("Busy history incorrectly minted a receipt.")
      } catch let error as VMError {
        #expect(error.code == .busy)
      }
    } catch {
      await fixture.store.releaseCommit()
      _ = await write.result
      throw error
    }
    await fixture.store.releaseCommit()
    try await write.value
    let receipt = try await fixture.history.sealCommittedHistory(for: fixture.permit)
    #expect(receipt.isFrom(fixture.history) && receipt.sequence == 1)
    #expect(try await fixture.currentIntent().state == .unsettled)
  }

  @Test func receiptRetainsActualHistoryPermitAndWriterOwner() async throws {
    let directory = try receiptDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vmID = UUID()
    var owner: VMLock? = try VMLock(directory: directory, expectedVMID: vmID)
    let weakOwner = WeakReceiptOwner(owner)
    var permit: RuntimeSessionPermit? = try await VMFiles().beginRuntimeSession(
      in: directory, forVMID: vmID, lock: try #require(owner))
    let weakPermit = WeakReceiptOwner(permit)
    var history: VMRuntimeHistory? = try await VMRuntimeHistory.open(
      in: directory, lock: try #require(owner), permit: permit)
    let weakHistory = WeakReceiptOwner(history)
    try await history?.persist(receiptStopped)
    var receipt: RuntimeHistoryCommitReceipt? = try await history?.sealCommittedHistory(
      for: try #require(permit))
    #expect(receipt != nil)
    withExtendedLifetime((history, permit, owner)) {}
    history = nil
    permit = nil
    owner = nil
    #expect(weakHistory.value != nil && weakPermit.value != nil && weakOwner.value != nil)
    #expect(await VMFiles().writerStatus(in: directory) == .held)
    withExtendedLifetime(receipt) {}
    receipt = nil
    #expect(weakHistory.value == nil && weakPermit.value == nil && weakOwner.value == nil)
    #expect(await VMFiles().writerStatus(in: directory) == .available)
    #expect(throws: VMError.self) { _ = try VMLock(directory: directory, expectedVMID: vmID) }
  }

  @Test func cancelledQuiescentSealIsPermanentWithoutChangingIntent() async throws {
    let fixture = try await ReceiptHistoryFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.history.persist(receiptStopped)
    let bytes = try await fixture.currentBytes()
    let attempt = Task { try await fixture.history.sealCommittedHistory(for: fixture.permit) }
    // The inherited MainActor task cannot enter seal before this synchronous cancellation.
    attempt.cancel()
    await #expect(throws: CancellationError.self) { try await attempt.value }
    await #expect(throws: VMError.self) {
      try await fixture.history.sealCommittedHistory(for: fixture.permit)
    }
    await #expect(throws: VMError.self) { try await fixture.history.persist(receiptStopped) }
    #expect(try await fixture.currentBytes() == bytes)
    #expect(try await fixture.currentIntent().state == .unsettled)
  }
}
