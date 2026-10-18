// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Controlled native callbacks only; ownership, intent, history and leases are real.
@MainActor private final class DesktopWindowsFixtureBackend: BackendSettlementSource {
  let capabilities = BackendCapabilities(
    id: .qemuHVF, operations: [.start, .forceStop], limitations: [])
  var isActive = false
  var terminationObservation = BackendTerminationObservation.notObserved
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  var failStart = false
  private var session: UUID?
  private var sealed = false
  func bindRecordedSession(sessionID: UUID) throws { session = sessionID }
  func start() async throws {
    isActive = true
    if failStart { throw windowsFixtureError() }
  }
  func forceStop() async throws {
    isActive = false
    terminationObservation = .explicitForcedTermination
    onGuestStopped?()
  }
  func requestStop() throws { throw windowsFixtureError() }
  func pause() async throws { throw windowsFixtureError() }
  func resume() async throws { throw windowsFixtureError() }
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    guard session == sessionID, !sealed, !isActive else { throw windowsFixtureError() }
    sealed = true
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID,
      launchDisposition: .completedAttempt, terminationObservation: terminationObservation)
  }
}

@MainActor private final class DesktopWindowsFileFixture {
  let directory: URL, run: URL
  let configuration: VMConfiguration
  let files = VMFiles()
  let backend = DesktopWindowsFixtureBackend()
  private var owner: RecordedRuntimeOwner?
  private var lock: VMLock?
  private(set) var sessionID: UUID?
  init() async throws {
    directory = URL(
      fileURLWithPath: "/private/tmp/mvo-desktop-windows-\(UUID().uuidString)", isDirectory: true)
    try await files.createDirectory(directory)
    let runtime = directory.appendingPathComponent(".runtime", isDirectory: true)
    try await files.createDirectory(runtime)
    run = runtime.appendingPathComponent(
      "run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
      isDirectory: true)
    try await files.createDirectory(run)
    configuration = VMConfiguration(
      name: "File-only desktop Windows fixture", guest: .windows11,
      backend: .qemuHVF, cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    try await files.writeNewMetadata(
      try ConfigurationCodec.encode(configuration),
      at: directory.appendingPathComponent("configuration.json"))
    lock = try VMLock(directory: directory, expectedVMID: configuration.id)
  }
  func settle(failed: Bool = false) async throws {
    let actualLock = try #require(lock)
    let prepared = try await RecordedRuntimeOwner.open(
      in: directory, vmID: configuration.id,
      lock: actualLock, backend: backend, files: files)
    owner = prepared
    sessionID = prepared.sessionID
    backend.failStart = failed
    if failed {
      await #expect(throws: VMError.self) { try await prepared.perform(.start) }
    } else {
      try await prepared.perform(.start)
    }
    try await prepared.perform(.forceStop)
    try await prepared.settleOwnership()
    owner = nil
    lock = nil
  }
  func releaseUnstartedLock() { lock = nil }
  func result(outcome: String, change: (inout [String: Any]) -> Void = { _ in }) async throws {
    var record: [String: Any] = [
      "schemaVersion": 1, "scope": "macopenvm-registered-qemu-runtime-result",
      "vmID": configuration.id.uuidString, "sessionID": try #require(sessionID).uuidString,
      "outcome": outcome, "qemuExit": 0, "tpmExit": 0, "qemuSignalled": false,
      "tpmSignalled": false, "drainsFinished": true, "runtimeIntentSettled": true,
      "resourcesRevalidated": true, "platformStateFlushed": true,
      "windowsCompatibilityVerified": false, "guestFilesystemVerified": false,
    ]
    change(&record)
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    let url = run.appendingPathComponent("result.json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try await files.writeNewMetadata(data, at: url)
  }
  func close() { try? FileManager.default.removeItem(at: directory) }
}

private func windowsFixtureError() -> VMError {
  VMError(
    .backendFailure, "Controlled file-only worker fixture.",
    recovery: "No native process or VM is involved.")
}
private func parentSnapshot(reaped: Bool = true, closed: Bool = true, exit: Int32 = 0)
  -> DesktopWindowsParentSnapshot
{
  DesktopWindowsParentSnapshot(
    submitted: true, started: true, reaped: reaped,
    descriptorsClosed: closed, exitStatus: reaped ? exit : nil, signalled: false, failure: nil)
}

@MainActor @Suite(.serialized) struct DesktopWindowsRuntimeTests {
  @Test func staleStatusCannotOverwriteNewerRecoveryState() {
    let vm = UUID()
    let session = UUID()
    func status(_ revision: UInt64, _ state: UInt8, vmID: UUID? = nil) -> WorkerResponse {
      WorkerResponse(
        vmID: vmID ?? vm, sessionID: session, requestID: 1, revision: revision,
        state: state, ownership: 0, backendActive: true, operationPending: false, error: .none)
    }
    let recovery = status(8, 6)
    #expect(!DesktopWindowsRuntime.acceptsStatus(status(5, 3), after: recovery))
    #expect(DesktopWindowsRuntime.acceptsStatus(status(8, 6), after: recovery))
    #expect(DesktopWindowsRuntime.acceptsStatus(status(9, 2), after: recovery))
    #expect(!DesktopWindowsRuntime.acceptsStatus(status(9, 2, vmID: UUID()), after: recovery))
  }

  @Test func exactSettledPriorWaitsOnlyBeforeCurrentSessionAdoption() async throws {
    let f = try await DesktopWindowsFileFixture()
    defer { f.close() }
    try await f.settle()
    let intent = try #require(try await f.files.readRuntimeIntent(in: f.directory))
    let prior = try #require(f.sessionID)
    let path = f.directory.appendingPathComponent(RuntimeIntent.filename)
    let before = try Data(contentsOf: path)
    let inode =
      try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber]
      as? NSNumber
    #expect(intent.state == .settled && intent.sessionID == prior)
    #expect(
      try DesktopWindowsRuntime.sessionCandidate(
        intent, vmID: f.configuration.id, priorSession: prior, adoptedSession: nil, preparing: true)
        == nil)
    for (vm, previous, adopted, preparing) in [
      (UUID(), prior, Optional<UUID>.none, true),
      (f.configuration.id, UUID(), nil, true),
      (f.configuration.id, prior, UUID(), true),
      (f.configuration.id, prior, nil, false),
    ] {
      #expect(throws: VMError.self) {
        try DesktopWindowsRuntime.sessionCandidate(
          intent, vmID: vm, priorSession: previous, adoptedSession: adopted, preparing: preparing)
      }
    }
    #expect(try Data(contentsOf: path) == before)
    #expect(
      try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
        == inode)
    #expect(await f.files.writerStatus(in: f.directory) == .available)
  }

  @Test func newlyMintedIntentSupersedesPriorWithoutPromotingOldOrChangedSessions() async throws {
    let f = try await DesktopWindowsFileFixture()
    defer { f.close() }
    try await f.settle()
    let priorIntent = try #require(try await f.files.readRuntimeIntent(in: f.directory))
    let prior = priorIntent.sessionID
    let lock = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
    let permit = try await f.files.beginRuntimeSession(
      in: f.directory, forVMID: f.configuration.id, lock: lock)
    let current = try #require(try await f.files.readRuntimeIntent(in: f.directory))
    let before = try Data(contentsOf: f.directory.appendingPathComponent(RuntimeIntent.filename))
    #expect(current.state == .unsettled && current.sessionID == permit.sessionID)
    #expect(current.sessionID != prior)
    for (adopted, preparing) in [(Optional<UUID>.none, true), (current.sessionID, false)] {
      #expect(
        try DesktopWindowsRuntime.sessionCandidate(
          current, vmID: f.configuration.id, priorSession: prior,
          adoptedSession: adopted, preparing: preparing) == current.sessionID)
    }
    for (intent, previous, adopted) in [
      (current, current.sessionID, Optional<UUID>.none),
      (current, prior, Optional(UUID())),
      (priorIntent, prior, Optional(current.sessionID)),
    ] {
      #expect(throws: VMError.self) {
        try DesktopWindowsRuntime.sessionCandidate(
          intent, vmID: f.configuration.id, priorSession: previous,
          adoptedSession: adopted, preparing: true)
      }
    }
    #expect(
      try Data(contentsOf: f.directory.appendingPathComponent(RuntimeIntent.filename)) == before)
    #expect(await f.files.writerStatus(in: f.directory) == .held)
    // Candidate classification grants no runtime custody; production still
    // requires its active retained parent, held writer and matching typed IPC.
    withExtendedLifetime((lock, permit)) {}
  }

  @Test func cancellationBeforeNativeCallCompletesWithoutInventingAReap() async throws {
    let f = try await DesktopWindowsFileFixture()
    defer { f.close() }
    let actual = DesktopWindowsParent(
      executable: URL(fileURLWithPath: "/never-executed-worker"),
      arguments: [], directory: f.directory, runDirectory: f.run)
    let caller = Task { try await actual.launch() }
    caller.cancel()
    await #expect(throws: CancellationError.self) { try await caller.value }
    let snapshot = await actual.waitForTermination()
    #expect(!snapshot.submitted && !snapshot.started && !snapshot.reaped)
    #expect(snapshot.descriptorsClosed && !snapshot.isActive)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.run.path).isEmpty)
    f.releaseUnstartedLock()
    let result = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: nil, parent: snapshot)
    #expect(result.failed && !result.parentReaped && !result.producerQualified)
  }
  @Test func actualParentAndLeaseCompletionPrecedeTerminalAdmission() async throws {
    let f = try await DesktopWindowsFileFixture()
    defer { f.close() }
    #expect(await f.files.writerStatus(in: f.directory) == .held)
    await #expect(throws: VMError.self) {
      try await DesktopWindowsRuntime.qualifyTermination(
        configuration: f.configuration,
        in: f.directory, runDirectory: f.run, sessionID: nil, parent: parentSnapshot())
    }
    try await f.settle()
    #expect(await f.files.writerStatus(in: f.directory) == .available)
    try await f.result(outcome: "forcedStopped")
    for value in [parentSnapshot(reaped: false), parentSnapshot(closed: false)] {
      await #expect(throws: VMError.self) {
        try await DesktopWindowsRuntime.qualifyTermination(
          configuration: f.configuration,
          in: f.directory, runDirectory: f.run, sessionID: f.sessionID, parent: value)
      }
    }
    let result = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: f.sessionID, parent: parentSnapshot())
    #expect(result.outcome == .forcedStopped && result.producerQualified && !result.failed)
    #expect(result.parentReaped && result.regularDescriptorsClosed)
    let previous = try #require(f.sessionID)
    try FileManager.default.removeItem(at: f.run.appendingPathComponent("result.json"))
    let old = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: nil, priorSessionID: previous,
      parent: parentSnapshot(exit: 1))
    #expect(old.failed && !old.producerQualified)
    try await f.result(outcome: "forcedStopped")
    await #expect(throws: VMError.self) {
      try await DesktopWindowsRuntime.qualifyTermination(
        configuration: f.configuration,
        in: f.directory, runDirectory: f.run, sessionID: nil, priorSessionID: previous,
        parent: parentSnapshot())
    }
  }
  @Test func qualifiedExitZeroDoesNotPromoteStickyCoreFailure() async throws {
    let f = try await DesktopWindowsFileFixture()
    defer { f.close() }
    try await f.settle(failed: true)
    try await f.result(outcome: "failed")
    let result = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: f.sessionID, parent: parentSnapshot())
    #expect(result.outcome == .failed && result.producerQualified && result.failed)
    #expect((try await f.files.readRuntimeIntent(in: f.directory))?.state == .settled)
    #expect(await f.files.writerStatus(in: f.directory) == .available)
  }
  @Test func missingMalformedAndMismatchedProducerEvidenceStaysFailed() async throws {
    let f = try await DesktopWindowsFileFixture()
    defer { f.close() }
    try await f.settle()
    let missing = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: f.sessionID, parent: parentSnapshot(exit: 1))
    #expect(!missing.producerQualified && missing.failed)
    for key in [
      "drainsFinished", "resourcesRevalidated", "platformStateFlushed", "runtimeIntentSettled",
    ] {
      try await f.result(outcome: "forcedStopped") { $0[key] = false }
      let bad = try await DesktopWindowsRuntime.qualifyTermination(
        configuration: f.configuration,
        in: f.directory, runDirectory: f.run, sessionID: f.sessionID, parent: parentSnapshot())
      #expect(!bad.producerQualified && bad.failed)
    }
    try await f.result(outcome: "forcedStopped") { $0["sessionID"] = UUID().uuidString }
    let foreign = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: f.sessionID, parent: parentSnapshot())
    #expect(!foreign.producerQualified && foreign.failed)
    await #expect(throws: VMError.self) {
      try await DesktopWindowsRuntime.qualifyTermination(
        configuration: f.configuration,
        in: f.directory, runDirectory: f.run, sessionID: UUID(), parent: parentSnapshot())
    }
  }
  @Test func preOwnerTerminalHasNoSuccessfulRuntimeAndNoSavedIdentityAdoption() async throws {
    let f = try await DesktopWindowsFileFixture()
    defer { f.close() }
    f.releaseUnstartedLock()
    let result = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: nil, parent: parentSnapshot(exit: 1))
    #expect(result.failed && !result.producerQualified && result.outcome == .failed)
    let never = DesktopWindowsParentSnapshot(
      submitted: false, started: false, reaped: false,
      descriptorsClosed: true, exitStatus: nil, signalled: false, failure: windowsFixtureError())
    let unsubmitted = try await DesktopWindowsRuntime.qualifyTermination(
      configuration: f.configuration,
      in: f.directory, runDirectory: f.run, sessionID: nil, parent: never)
    #expect(unsubmitted.failed && !unsubmitted.producerQualified && !unsubmitted.parentReaped)
    let ambiguous = DesktopWindowsParentSnapshot(
      submitted: true, started: false, reaped: false,
      descriptorsClosed: true, exitStatus: nil, signalled: false, failure: windowsFixtureError())
    await #expect(throws: VMError.self) {
      try await DesktopWindowsRuntime.qualifyTermination(
        configuration: f.configuration,
        in: f.directory, runDirectory: f.run, sessionID: nil, parent: ambiguous)
    }
    #expect((try await f.files.readRuntimeIntent(in: f.directory)) == nil)
    await #expect(throws: VMError.self) {
      try await DesktopWindowsRuntime.qualifyTermination(
        configuration: f.configuration,
        in: f.directory, runDirectory: f.run, sessionID: UUID(), parent: parentSnapshot())
    }
  }
}
