// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

/// Package test receipts are deliberately manufactured. These files test Storage's guards,
/// not real backend quiescence, worker recovery, power loss or clean guest shutdown.
@MainActor private final class ManufacturedBackendSource: BackendSettlementSource {
  let capabilities = BackendCapabilities(id: .qemuHVF, operations: [], limitations: [])
  var isActive: Bool { false }
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  func start() async throws {}
  func requestStop() throws {}
  func forceStop() async throws {}
  func pause() async throws {}
  func resume() async throws {}
  func bindRecordedSession(sessionID: UUID) throws {}
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    BackendQuiescenceReceipt(
      source: self, sessionID: sessionID, launchDisposition: .completedAttempt,
      terminationObservation: .explicitForcedTermination)
  }
}

private final class ManufacturedHistorySource: RuntimeHistoryReceiptSource {}
private final class ManufacturedSettlementSource: RuntimeSettlementReceiptSource {}

@MainActor private struct SettlementFixture {
  let directory: URL
  let vmID: UUID
  let lock: VMLock
  let permit: RuntimeSessionPermit
  let historyBytes: Data
  let backendSource: ManufacturedBackendSource
  let historySource: ManufacturedHistorySource
  let settlementSource: ManufacturedSettlementSource

  static func make() async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "macOpenVM-settlement-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let vmID = UUID()
    let lock = try VMLock(directory: directory, expectedVMID: vmID)
    let files = VMFiles()
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: lock)
    let historyBytes = Data(
      ("{\"schemaVersion\":1,\"sessionID\":\"\(permit.sessionID.uuidString)\","
        + "\"sequence\":1,\"recordedAt\":0,\"snapshot\":{\"state\":\"failed\","
        + "\"backendActive\":false,\"outcome\":\"failed\"}}").utf8)
    try await files.atomicWrite(historyBytes, at: directory.appendingPathComponent("runtime.json"))
    return Self(
      directory: directory, vmID: vmID, lock: lock, permit: permit, historyBytes: historyBytes,
      backendSource: ManufacturedBackendSource(), historySource: ManufacturedHistorySource(),
      settlementSource: ManufacturedSettlementSource())
  }

  func receipt(
    backendSession: UUID? = nil, historyPermit: RuntimeSessionPermit? = nil,
    sequence: UInt64 = 1, bytes: Data? = nil
  ) throws -> RuntimeSettlementReceipt {
    let backend = BackendQuiescenceReceipt(
      source: backendSource, sessionID: backendSession ?? permit.sessionID,
      launchDisposition: .completedAttempt, terminationObservation: .explicitForcedTermination)
    let history = try RuntimeHistoryCommitReceipt(
      source: historySource, permit: historyPermit ?? permit,
      sequence: sequence, finalBytes: bytes ?? historyBytes)
    return try RuntimeSettlementReceipt(
      source: settlementSource, permit: permit, backend: backend, history: history)
  }
}

@Suite(.serialized) @MainActor struct RuntimeSettlementTests {
  @Test func exactOpaqueEvidenceSettlesAndCannotBeCommittedTwice() async throws {
    let fixture = try await SettlementFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = try fixture.receipt()
    #expect(receipt.isFrom(fixture.settlementSource))
    #expect(receipt.sourceID == ObjectIdentifier(fixture.settlementSource))
    #expect(receipt.history.isFrom(fixture.historySource))
    #expect(receipt.history.sourceID == ObjectIdentifier(fixture.historySource))
    let files = VMFiles()
    try await files.commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    let intent = try #require(try await files.readRuntimeIntent(in: fixture.directory))
    #expect(intent.state == .settled && intent.vmID == fixture.vmID)
    #expect(intent.sessionID == fixture.permit.sessionID)
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json"))
        == fixture.historyBytes)
    let settledBytes = try Data(
      contentsOf: fixture.directory.appendingPathComponent(RuntimeIntent.filename))
    await #expect(throws: VMError.self) {
      try await files.commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent(RuntimeIntent.filename))
        == settledBytes)
    #expect(
      !((try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)).contains {
        $0.hasPrefix(".runtime-intent-")
      }))
  }

  @Test func invalidBoundsAndMismatchedReceiptsCannotMintCombinedEvidence() async throws {
    let fixture = try await SettlementFixture.make()
    let other = try await SettlementFixture.make()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
      try? FileManager.default.removeItem(at: other.directory)
    }
    for bytes in [Data(), Data(repeating: 0, count: RuntimeIntent.maximumBytes + 1)] {
      #expect(throws: VMError.self) { _ = try fixture.receipt(bytes: bytes) }
    }
    #expect(throws: VMError.self) { _ = try fixture.receipt(sequence: 0) }
    #expect(throws: VMError.self) { _ = try fixture.receipt(backendSession: UUID()) }
    #expect(throws: VMError.self) { _ = try fixture.receipt(historyPermit: other.permit) }
    #expect((try await VMFiles().readRuntimeIntent(in: fixture.directory))?.state == .unsettled)
  }

  @Test(arguments: ["vm", "session", "settled", "missing"])
  func currentIntentMismatchRejectsSettlement(_ kind: String) async throws {
    let fixture = try await SettlementFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = try fixture.receipt()
    let path = fixture.directory.appendingPathComponent(RuntimeIntent.filename)
    if kind == "missing" {
      try FileManager.default.removeItem(at: path)
    } else {
      let vmID = kind == "vm" ? UUID() : fixture.vmID
      let sessionID = kind == "session" ? UUID() : fixture.permit.sessionID
      let state = kind == "settled" ? "settled" : "unsettled"
      try await VMFiles().atomicWrite(
        Data(
          ("{\"schemaVersion\":1,\"vmID\":\"\(vmID.uuidString)\","
            + "\"sessionID\":\"\(sessionID.uuidString)\",\"state\":\"\(state)\"}").utf8), at: path)
    }
    await #expect(throws: VMError.self) {
      try await VMFiles().commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json"))
        == fixture.historyBytes)
  }

  @Test func changedHistoryConsumesClaimAndNeverSettlesOnRetry() async throws {
    let fixture = try await SettlementFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = try fixture.receipt()
    let path = fixture.directory.appendingPathComponent("runtime.json")
    let changed = Data(
      String(decoding: fixture.historyBytes, as: UTF8.self)
        .replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":2").utf8)
    #expect(changed.count == fixture.historyBytes.count && changed != fixture.historyBytes)
    try await VMFiles().atomicWrite(changed, at: path)
    await #expect(throws: VMError.self) {
      try await VMFiles().commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
    #expect((try await VMFiles().readRuntimeIntent(in: fixture.directory))?.state == .unsettled)
    try await VMFiles().atomicWrite(fixture.historyBytes, at: path)
    await #expect(throws: VMError.self) {
      try await VMFiles().commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
    #expect((try await VMFiles().readRuntimeIntent(in: fixture.directory))?.state == .unsettled)
  }

  @Test(arguments: ["symlink", "hardlink", "fifo", "mode"])
  func unsafeHistoryNeverSettlesOrFollowsAliases(_ kind: String) async throws {
    let fixture = try await SettlementFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = try fixture.receipt()
    let history = fixture.directory.appendingPathComponent("runtime.json")
    let protected = fixture.directory.appendingPathComponent("history-preserved.json")
    if kind == "symlink" || kind == "fifo" {
      try FileManager.default.moveItem(at: history, to: protected)
      if kind == "symlink" {
        #expect(symlink(protected.path, history.path) == 0)
      } else {
        #expect(mkfifo(history.path, 0o600) == 0)
      }
    } else if kind == "hardlink" {
      #expect(link(history.path, protected.path) == 0)
    } else {
      #expect(chmod(history.path, 0o640) == 0)
    }
    await #expect(throws: VMError.self) {
      try await VMFiles().commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
    #expect((try await VMFiles().readRuntimeIntent(in: fixture.directory))?.state == .unsettled)
    if kind != "mode" {
      #expect(try Data(contentsOf: protected) == fixture.historyBytes)
    }
  }

  @Test func settlementWriteFailureRemainsUnsettledAndConsumesClaim() async throws {
    let fixture = try await SettlementFixture.make()
    defer {
      _ = chmod(fixture.directory.path, 0o700)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let receipt = try fixture.receipt()
    #expect(chmod(fixture.directory.path, 0o500) == 0)
    await #expect(throws: VMError.self) {
      try await VMFiles().commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
    #expect(chmod(fixture.directory.path, 0o700) == 0)
    #expect((try await VMFiles().readRuntimeIntent(in: fixture.directory))?.state == .unsettled)
    await #expect(throws: VMError.self) {
      try await VMFiles().commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
  }

  @Test func replacedWriterIdentityRejectsSettlement() async throws {
    let fixture = try await SettlementFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = fixture.directory.appendingPathComponent("writer.lock")
    try FileManager.default.moveItem(
      at: writer, to: fixture.directory.appendingPathComponent("old-writer.lock"))
    try Data().write(to: writer, options: .withoutOverwriting)
    #expect(chmod(writer.path, 0o600) == 0)
    let receipt = try fixture.receipt()
    await #expect(throws: VMError.self) {
      try await VMFiles().commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
    }
    #expect((try await VMFiles().readRuntimeIntent(in: fixture.directory))?.state == .unsettled)
    #expect(!fixture.lock.owns(fixture.directory))
  }

  @Test func competingFileActorsCannotCommitTheSamePermitTwice() async throws {
    let fixture = try await SettlementFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let receipt = try fixture.receipt()
    let attempts = [VMFiles(), VMFiles()].map { files in
      Task { () -> Result<Void, any Error> in
        do {
          try await files.commitRuntimeSettlement(in: fixture.directory, receipt: receipt)
          return .success(())
        } catch { return .failure(error) }
      }
    }
    var successful = 0
    var rejected = 0
    for attempt in attempts {
      switch await attempt.value {
      case .success: successful += 1
      case .failure(let error):
        #expect((error as? VMError)?.code == .busy)
        rejected += 1
      }
    }
    #expect(successful == 1 && rejected == 1)
    #expect((try await VMFiles().readRuntimeIntent(in: fixture.directory))?.state == .settled)
  }
}
