// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu
import Testing

@MainActor
private final class WeakSettlementBackend {
  weak var value: QemuMachineBackend?
}

@Suite("QemuSettlementTests", .serialized)
@MainActor
struct QemuSettlementTests {
  @Test func unusedSourceReceiptRetainsAndPermanentlySealsActualSource() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = UUID()
    let witness = WeakSettlementBackend()
    var receipt: BackendQuiescenceReceipt?
    do {
      let source = QemuMachineBackend(plan: unusedPlan(directory))
      witness.value = source
      try source.bindRecordedSession(sessionID: session)
      receipt = try await source.freezeForSettlement(sessionID: session)
      #expect(receipt?.sessionID == session && receipt?.sourceID == ObjectIdentifier(source))
      #expect(receipt?.launchDisposition == .neverInvoked)
      #expect(receipt?.terminationObservation == .notObserved && !source.isActive)
      #expect(source.settledMonitorObservation == nil)
      await expectRejected { try await source.start() }
      await expectRejected { try await source.pause() }
      await expectRejected { try await source.resume() }
      await expectRejected { try await source.forceStop() }
      await expectRejected { try await source.freezeForSettlement(sessionID: session) }
      #expect(throws: VMError.self) { try source.bindRecordedSession(sessionID: UUID()) }
    }
    #expect(witness.value != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    withExtendedLifetime(receipt) {}
    receipt = nil
    #expect(witness.value == nil)
  }

  @Test func bindingIsOneShotAndMustPrecedeAnyRuntimeOperation() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let used = QemuMachineBackend(plan: unusedPlan(directory))
    await expectRejected { try await used.pause() }
    #expect(throws: VMError.self) { try used.bindRecordedSession(sessionID: UUID()) }
    await expectRejected { try await used.freezeForSettlement(sessionID: UUID()) }

    let fresh = QemuMachineBackend(plan: unusedPlan(directory))
    let session = UUID()
    try fresh.bindRecordedSession(sessionID: session)
    #expect(throws: VMError.self) { try fresh.bindRecordedSession(sessionID: session) }
    await expectRejected { try await fresh.freezeForSettlement(sessionID: UUID()) }
    let receipt = try await fresh.freezeForSettlement(sessionID: session)
    #expect(receipt.sessionID == session && receipt.launchDisposition == .neverInvoked)
  }

  @Test func failedAttemptWithoutAChildCannotBecomeNewSessionEvidence() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = QemuMachineBackend(plan: unusedPlan(directory, missingDaemon: true))
    let session = UUID()
    try source.bindRecordedSession(sessionID: session)
    await expectStartupFailure { try await source.start() }
    await source.refreshOutput()
    #expect(!source.isActive && source.tpmSnapshot?.started == false)
    #expect(source.lastFailure != nil && source.terminationObservation == .notObserved)
    await expectRejected { try await source.freezeForSettlement(sessionID: UUID()) }
    let receipt = try await source.freezeForSettlement(sessionID: session)
    #expect(receipt.launchDisposition == .failedAttempt)
    #expect(receipt.terminationObservation == .notObserved && source.lastFailure != nil)

    let unboundDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: unboundDirectory) }
    let unbound = QemuMachineBackend(plan: unusedPlan(unboundDirectory, missingDaemon: true))
    await expectStartupFailure { try await unbound.start() }
    #expect(throws: VMError.self) { try unbound.bindRecordedSession(sessionID: UUID()) }
    await expectRejected { try await unbound.freezeForSettlement(sessionID: UUID()) }
  }

  @Test func cancelledStartBeforeSpawnIsAFailedAttemptWithoutExitEvidence() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = QemuMachineBackend(plan: unusedPlan(directory))
    let session = UUID()
    try source.bindRecordedSession(sessionID: session)
    let startup = Task { try await source.start() }
    startup.cancel()
    do {
      try await startup.value
      Issue.record("Expected cancelled start")
    } catch { #expect(error is CancellationError) }
    #expect(!source.isActive && source.qemuSnapshot == nil && source.tpmSnapshot == nil)
    #expect(source.lastFailure?.code == .cancelled)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    let receipt = try await source.freezeForSettlement(sessionID: session)
    #expect(receipt.launchDisposition == .failedAttempt)
    #expect(receipt.terminationObservation == .notObserved)
    #expect(throws: VMError.self) { try source.bindRecordedSession(sessionID: UUID()) }
  }

  @Test(
    .enabled(
      if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
      "Requires existing Python for ordinary private child/socket fixtures."))
  func guestShutdownCallbackAndFrozenReceiptUseIdenticalSettledEvidence() async throws {
    try await withPair("guest-auto") { fixture, source, session in
      #expect(source.settledMonitorObservation == nil)
      try await source.start()
      #expect(source.settledMonitorObservation == nil)
      try fixture.mark("send-shutdown")
      try await fixture.until { fixture.stoppedCount == 1 }
      #expect(source.terminationObservation == .guestStopObserved && source.lastFailure == nil)
      let monitor = try #require(source.settledMonitorObservation)
      #expect(monitor.guestShutdownObserved && monitor.shutdown?.guest == true)
      #expect(monitor.shutdown?.reason == .guestShutdown)
      #expect(monitor.naturalEOF && monitor.readerDrained && !monitor.intentionalClose)
      #expect(monitor.failure == nil)
      let receipt = try await source.freezeForSettlement(sessionID: session)
      #expect(receipt.launchDisposition == .completedAttempt)
      #expect(receipt.terminationObservation == source.terminationObservation)
      #expect(receipt.terminationObservation == .guestStopObserved)
      #expect(!source.isActive && fixture.stoppedCount == 1)
      #expect(source.settledMonitorObservation == monitor)
    }
  }

  @Test(
    .enabled(
      if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
      "Requires existing Python for ordinary private child/socket fixtures."))
  func activePairRejectsReceiptUntilExplicitTerminalDrainCompletion() async throws {
    try await withPair("normal") { fixture, source, session in
      try await source.start()
      #expect(source.terminationObservation == .notObserved)
      await expectRejected { try await source.freezeForSettlement(sessionID: session) }
      try await fixture.requirePairRunning()
      try await fixture.forceStopAndCheck()
      let receipt = try await source.freezeForSettlement(sessionID: session)
      #expect(receipt.launchDisposition == .completedAttempt)
      #expect(receipt.terminationObservation == .explicitForcedTermination)
      #expect(receipt.sourceID == ObjectIdentifier(source) && !source.isActive)
      await expectRejected { try await source.start() }
      await expectRejected { try await source.forceStop() }
    }
  }

  @Test(
    .enabled(
      if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
      "Requires existing Python for ordinary private child/socket fixtures."))
  func failedPartialLaunchMustObserveSurvivorAndDrainsBeforeSealing() async throws {
    try await withPair("spawn-failure") { fixture, source, session in
      await expectStartupFailure { try await source.start() }
      await source.refreshOutput()
      #expect(source.qemuSnapshot?.started == false && source.tpmSnapshot?.running == true)
      await expectRejected { try await source.freezeForSettlement(sessionID: session) }
      #expect(source.isActive && fixture.stoppedCount == 0)
      try await source.forceStop()
      await source.refreshOutput()
      #expect(source.tpmSnapshot?.termination != nil && source.tpmSnapshot?.drainsFinished == true)
      #expect(source.qemuSnapshot?.started == false && !source.isActive)
      let receipt = try await source.freezeForSettlement(sessionID: session)
      #expect(receipt.launchDisposition == .failedAttempt)
      #expect(receipt.terminationObservation == .explicitForcedTermination)
      #expect(source.lastFailure != nil)
    }
  }

  @Test(
    .enabled(
      if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
      "Requires existing Python for ordinary private child/socket fixtures."))
  func ordinaryRuntimeExitIsNeverGuestShutdownEvidence() async throws {
    try await withPair("fail-pause") { fixture, source, session in
      try await source.start()
      do {
        try await source.pause()
        Issue.record("Expected local control failure")
      } catch { #expect(error as? QMPClientError == .commandRejected("GenericError")) }
      try await fixture.until { !source.isActive }
      // A late cleanup request cannot relabel an already observed runtime exit.
      try await source.forceStop()
      #expect(source.terminationObservation == .runtimeExited)
      let receipt = try await source.freezeForSettlement(sessionID: session)
      #expect(receipt.launchDisposition == .completedAttempt)
      #expect(receipt.terminationObservation == .runtimeExited)
      #expect(source.terminationObservation == .runtimeExited && fixture.stoppedCount == 1)
      #expect(source.lastFailure != nil)
    }
  }

  private func expectRejected<T>(_ operation: () async throws -> T) async {
    do {
      _ = try await operation()
      Issue.record("Expected sealed/active/session rejection")
    } catch { #expect((error as? VMError)?.code == .invalidTransition) }
  }

  private func expectStartupFailure(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected private child launch failure")
    } catch { #expect((error as? VMError)?.code == .backendFailure) }
  }

  private func makeDirectory() throws -> URL {
    let directory = URL(
      fileURLWithPath: "/private/tmp/mvo-settle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }

  private func unusedPlan(_ directory: URL, missingDaemon: Bool = false) -> QemuRuntimePlan {
    func configuration(_ role: String, missing: Bool = false) -> OwnedProcess.Configuration {
      .init(
        executable: URL(
          fileURLWithPath: missing ? "/nonexistent/macopenvm-settle-child" : "/usr/bin/true"),
        arguments: [], workingDirectory: directory,
        stdoutLog: directory.appendingPathComponent("\(role)-out.log"),
        stderrLog: directory.appendingPathComponent("\(role)-err.log"))
    }
    return QemuRuntimePlan(
      qemu: configuration("machine"), tpm: configuration("daemon", missing: missingDaemon),
      qmpSocket: directory.appendingPathComponent("qmp.sock"),
      tpmSocket: directory.appendingPathComponent("tpm.sock"))
  }

  private func withPair(
    _ mode: String,
    _ operation: (RuntimePairFixture, QemuMachineBackend, UUID) async throws -> Void
  ) async throws {
    let fixture = try RuntimePairFixture(mode: mode)
    let source = try #require(fixture.backend)
    let session = UUID()
    try source.bindRecordedSession(sessionID: session)
    do { try await operation(fixture, source, session) } catch {
      do { try await fixture.cleanup() } catch {
        Issue.record("Private settlement fixture cleanup remains unresolved: \(error)")
      }
      throw error
    }
    try await fixture.cleanup()
  }
}
