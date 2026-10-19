// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMCore
@testable import VMStorage

private let interruptionRun = "run-0123456789abcdef0123456789abcdef"
private let interruptionReboot = Data(
  "GENERATED FIXTURE: explicit operator reboot observation".utf8)
private let interruptionOwnerExit = Data(
  "GENERATED FIXTURE: operator reviewed owner exit in the current boot; no reaping proof".utf8)
private let interruptionProcesses = Data(
  "GENERATED FIXTURE: operator reviewed process observation".utf8)

enum InterruptionRecoveryTestBasis: CaseIterable, Equatable, Sendable {
  case hostReboot, abandonedOwner
}

private struct InterruptionFixture {
  let directory: URL
  let vmID: UUID
  let sessionID: UUID
  let configuration: Data
  let intent: Data
  let history: Data
  let run: [String: Data]
}

private func writeInterruptionFixture(_ data: Data, to url: URL) throws {
  try data.write(to: url, options: .withoutOverwriting)
  try #require(chmod(url.path, 0o600) == 0)
}

private func interruptionFixture(diskBytes: UInt64 = 1_073_741_824) throws -> InterruptionFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macopenvm-explicit-recovery-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  var configuration = VMConfiguration(
    name: "Generated interruption fixture", guest: .windows11, backend: .qemuHVF,
    cpuCount: 2, memoryBytes: 4_294_967_296, diskBytes: diskBytes)
  configuration.network = .disconnected
  let registration = try ConfigurationCodec.encode(configuration)
  try writeInterruptionFixture(
    registration, to: directory.appendingPathComponent("configuration.json"))
  let disk = open(
    directory.appendingPathComponent(configuration.diskFile).path,
    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
  try #require(disk >= 0)
  guard ftruncate(disk, off_t(configuration.diskBytes)) == 0 else {
    close(disk)
    throw VMError(
      .storage, "Generated sparse fixture failed.", recovery: "Preserve only this fixture.")
  }
  close(disk)
  do {
    let initial = try VMLock(directory: directory, expectedVMID: configuration.id)
    withExtendedLifetime(initial) {}
  }
  let session = UUID()
  let intent = Data(
    ("{\"schemaVersion\":1,\"vmID\":\"\(configuration.id.uuidString)\","
      + "\"sessionID\":\"\(session.uuidString)\",\"state\":\"unsettled\"}\n").utf8)
  let history = try RuntimeHistoryCodec.encode(
    RuntimeRecord(
      sessionID: session, sequence: 2, recordedAt: 1_792_310_350.901952,
      snapshot: RuntimeSnapshot(
        state: .running, operation: nil, backendActive: true, outcome: .pending)))
  try writeInterruptionFixture(intent, to: directory.appendingPathComponent(RuntimeIntent.filename))
  try writeInterruptionFixture(history, to: directory.appendingPathComponent("runtime.json"))
  let runtime = directory.appendingPathComponent(".runtime")
  let runDirectory = runtime.appendingPathComponent(interruptionRun)
  for folder in [runtime, runDirectory] {
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  var run: [String: Data] = [:]
  let scopes = [
    "worker.json": "macopenvm-registered-qemu-worker-route",
    "display.json": "macopenvm-registered-qemu-display-route",
    "surface.json": "macopenvm-registered-qemu-shared-frame-route",
  ]
  for (name, scope) in scopes {
    let bytes = Data(
      ("{\"schemaVersion\":1,\"scope\":\"\(scope)\",\"vmID\":\"\(configuration.id.uuidString)\","
        + "\"sessionID\":\"\(session.uuidString)\",\"fixture\":\"\(name)\","
        + "\"historicalDevice\":16777232}").utf8)
    run[name] = bytes
    try writeInterruptionFixture(bytes, to: runDirectory.appendingPathComponent(name))
  }
  return .init(
    directory: directory, vmID: configuration.id, sessionID: session,
    configuration: registration, intent: intent, history: history, run: run)
}

@MainActor private func inspectInterruption(
  _ fixture: InterruptionFixture, owner: RegisteredWindowsInterruptionRecovery
) async throws -> RuntimeInterruptionInspection {
  try await owner.inspect(
    in: fixture.directory, expectedVMID: fixture.vmID, expectedSessionID: fixture.sessionID,
    runName: interruptionRun)
}

@MainActor private func recoverInterruption(
  _ fixture: InterruptionFixture, owner: RegisteredWindowsInterruptionRecovery,
  digest: String, basis: InterruptionRecoveryTestBasis = .hostReboot
) async throws -> RuntimeInterruptionRecoveryResult {
  switch basis {
  case .hostReboot:
    return try await owner.recover(
      in: fixture.directory, expectedVMID: fixture.vmID, expectedSessionID: fixture.sessionID,
      runName: interruptionRun, expectedMetadataSHA256: digest,
      rebootObservation: interruptionReboot, processObservation: interruptionProcesses,
      acknowledgement: .observedHostRebootAndReviewedNoOtherRuntime)
  case .abandonedOwner:
    return try await owner.recoverAbandonedOwner(
      in: fixture.directory, expectedVMID: fixture.vmID, expectedSessionID: fixture.sessionID,
      runName: interruptionRun, expectedMetadataSHA256: digest,
      ownerExitObservation: interruptionOwnerExit, processObservation: interruptionProcesses,
      acknowledgement: .reviewedOwnerExitAndNoOtherRuntime)
  }
}

private func interruptionArchives(_ fixture: InterruptionFixture) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter {
    $0.hasPrefix("runtime-interruption-")
  }
}

private func expectOriginalInterruption(_ fixture: InterruptionFixture) throws {
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(RuntimeIntent.filename))
      == fixture.intent)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json"))
      == fixture.history)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent("configuration.json"))
      == fixture.configuration)
}

private func expectInterruptionLeaseHeld(_ fixture: InterruptionFixture) throws {
  let fd = open(
    fixture.directory.appendingPathComponent("writer.lock").path,
    O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
  try #require(fd >= 0)
  defer { close(fd) }
  let status = flock(fd, LOCK_EX | LOCK_NB)
  let failure = errno
  #expect(status == -1 && failure == EWOULDBLOCK)
}

private func completedInterruptionGrowth(_ fixture: InterruptionFixture) throws -> [String: Data] {
  let target = try StrictConfigurationDocument(fixture.configuration)
  let oldBytes = target.configuration.diskBytes - 1024
  let original = try target.replacingDiskBytes(with: oldBytes).bytes
  let transaction = UUID()
  let backup = "disk-growth-\(transaction.uuidString)-original.json"
  let replacement = "disk-growth-\(transaction.uuidString)-target.json"
  var parent = stat()
  var disk = stat()
  try #require(lstat(fixture.directory.path, &parent) == 0)
  try #require(lstat(fixture.directory.appendingPathComponent("disk.raw").path, &disk) == 0)
  let object: [String: Any] = [
    "schemaVersion": 1, "vmID": fixture.vmID.uuidString,
    "transactionID": transaction.uuidString, "state": "completed", "diskFile": "disk.raw",
    "directoryDevice": parent.st_dev, "directoryInode": parent.st_ino,
    "diskDevice": disk.st_dev, "diskInode": disk.st_ino,
    "oldBytes": oldBytes, "targetBytes": target.configuration.diskBytes,
    "originalConfigurationSHA256": DiskGrowthIO.digest(original),
    "replacementConfigurationSHA256": DiskGrowthIO.digest(fixture.configuration),
    "backupFile": backup, "targetFile": replacement,
  ]
  let journal = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let files = [
    backup: original, replacement: fixture.configuration,
    DiskGrowthIntent.filename: journal,
  ]
  for (name, bytes) in files {
    try writeInterruptionFixture(bytes, to: fixture.directory.appendingPathComponent(name))
  }
  return files
}

private func expectInterruptionLeaseAvailable(_ fixture: InterruptionFixture) throws {
  let fd = open(
    fixture.directory.appendingPathComponent("writer.lock").path,
    O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
  try #require(fd >= 0)
  defer { close(fd) }
  // Raw independent positive flock: ordinary VMLock must still reject the old unsettled intent.
  let status = flock(fd, LOCK_EX | LOCK_NB)
  let failure = errno
  #expect(status == 0, "Expected no retained recovery lease; errno \(failure)")
}

@Suite @MainActor struct RuntimeInterruptionRecoveryTests {
  @Test func rebootEvidenceEncodingRemainsExactAndOwnerExitHasItsOwnField() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let processes = Data("process".utf8)
    let reboot = RuntimeInterruptionEvidence(
      rebootObservation: Data("reboot".utf8), processObservation: processes)
    let ownerExit = RuntimeInterruptionEvidence(
      ownerExitObservation: Data("owner-exit".utf8), processObservation: processes)
    #expect(
      try encoder.encode(reboot)
        == Data(
          "{\"processObservation\":\"cHJvY2Vzcw==\",\"rebootObservation\":\"cmVib290\"}".utf8))
    #expect(
      try encoder.encode(ownerExit)
        == Data(
          "{\"ownerExitObservation\":\"b3duZXItZXhpdA==\",\"processObservation\":\"cHJvY2Vzcw==\"}"
            .utf8))
  }

  @Test(arguments: ["directoryDevice", "diskDevice"], InterruptionRecoveryTestBasis.allCases)
  func completedLegacyGrowthDeviceMismatchRefusesBeforeRecoveryCustody(
    field: String, basis: InterruptionRecoveryTestBasis
  ) async throws {
    let fixture = try interruptionFixture(diskBytes: 1_073_742_848)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let growth = try completedInterruptionGrowth(fixture)
    let files = VMFiles()
    // Prove this exact generated journal/sidecars are valid before changing only one device.
    try await files.verifyCompletedDiskGrowth(in: fixture.directory, expectedVMID: fixture.vmID)
    let owner = RegisteredWindowsInterruptionRecovery()
    let observed = try await inspectInterruption(fixture, owner: owner)
    let journal = fixture.directory.appendingPathComponent(DiskGrowthIntent.filename)
    let recordedJournal = try #require(growth[DiskGrowthIntent.filename])
    let journalObject = try JSONSerialization.jsonObject(with: recordedJournal)
    var object = try #require(journalObject as? [String: Any])
    let current = try #require(object[field] as? NSNumber).int32Value
    object[field] = current == Int32.max ? Int32.min : current + 1
    let mismatched = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try await files.atomicWrite(mismatched, at: journal)
    let record = try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
    #expect(record.schemaVersion == 1 && record.state == .completed)
    // Growth metadata is not part of the interrupted-session digest. The recovery boundary
    // must independently preflight it, rather than first noticing it after retaining custody.
    let afterChange = try await inspectInterruption(fixture, owner: owner)
    #expect(afterChange.metadataSHA256 == observed.metadataSHA256)
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
    var diskBefore = stat()
    try #require(lstat(fixture.directory.appendingPathComponent("disk.raw").path, &diskBefore) == 0)
    await #expect(throws: VMError.self) {
      _ = try await recoverInterruption(
        fixture, owner: owner, digest: observed.metadataSHA256, basis: basis)
    }
    #expect(!owner.custodyRetained)
    try expectInterruptionLeaseAvailable(fixture)
    try expectOriginalInterruption(fixture)
    #expect(try interruptionArchives(fixture).isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == names)
    for (name, bytes) in growth {
      #expect(
        try Data(contentsOf: fixture.directory.appendingPathComponent(name))
          == (name == DiskGrowthIntent.filename ? mismatched : bytes))
    }
    for (name, bytes) in fixture.run {
      #expect(
        try Data(
          contentsOf: fixture.directory.appendingPathComponent(".runtime")
            .appendingPathComponent(interruptionRun).appendingPathComponent(name)) == bytes)
    }
    var diskAfter = stat()
    try #require(lstat(fixture.directory.appendingPathComponent("disk.raw").path, &diskAfter) == 0)
    #expect(diskAfter.st_dev == diskBefore.st_dev && diskAfter.st_ino == diskBefore.st_ino)
    #expect(diskAfter.st_size == diskBefore.st_size)
    #expect(diskAfter.st_mtimespec.tv_sec == diskBefore.st_mtimespec.tv_sec)
    #expect(diskAfter.st_mtimespec.tv_nsec == diskBefore.st_mtimespec.tv_nsec)
  }

  @Test func admittedCompletedLegacyGrowthStillAllowsExplicitInterruptionRecovery() async throws {
    let fixture = try interruptionFixture(diskBytes: 1_073_742_848)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let growth = try completedInterruptionGrowth(fixture)
    let files = VMFiles()
    try await files.verifyCompletedDiskGrowth(in: fixture.directory, expectedVMID: fixture.vmID)
    let owner = RegisteredWindowsInterruptionRecovery()
    let observed = try await inspectInterruption(fixture, owner: owner)
    let result = try await recoverInterruption(
      fixture, owner: owner, digest: observed.metadataSHA256)
    #expect(result.recoverySessionID != fixture.sessionID && !owner.custodyRetained)
    #expect(try interruptionArchives(fixture) == [result.archiveFile])
    try expectInterruptionLeaseAvailable(fixture)
    let intent = try #require(try await files.readRuntimeIntent(in: fixture.directory))
    #expect(intent.state == .settled && intent.sessionID == result.recoverySessionID)
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent("configuration.json"))
        == fixture.configuration)
    for (name, bytes) in growth {
      #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(name)) == bytes)
    }
  }

  @Test(arguments: InterruptionRecoveryTestBasis.allCases)
  func explicitRecoveryArchivesExactOldFactsAndPublishesNewFailedSession(
    basis: InterruptionRecoveryTestBasis
  ) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = RegisteredWindowsInterruptionRecovery()
    let observed = try await inspectInterruption(fixture, owner: owner)
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    }
    var diskBefore = stat()
    try #require(lstat(fixture.directory.appendingPathComponent("disk.raw").path, &diskBefore) == 0)
    let result = try await recoverInterruption(
      fixture, owner: owner, digest: observed.metadataSHA256, basis: basis)
    #expect(result.recoverySessionID != fixture.sessionID && result.newOutcome == .failed)
    #expect(!result.oldSessionNormallySettled && !result.oldChildReapingProved)
    #expect(result.operatorAttestedInterruption && !owner.custodyRetained)
    let files = VMFiles()
    let intent = try #require(try await files.readRuntimeIntent(in: fixture.directory))
    #expect(intent.state == .settled && intent.sessionID == result.recoverySessionID)
    let history = try RuntimeHistoryCodec.decode(
      Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json")))
    #expect(history.sessionID == result.recoverySessionID && history.sequence == 1)
    #expect(history.snapshot.state == .failed && history.snapshot.outcome == .failed)
    #expect(!history.snapshot.backendActive && history.snapshot.operation == nil)
    let archiveBytes = try Data(
      contentsOf: fixture.directory.appendingPathComponent(result.archiveFile))
    let archive = try #require(
      try JSONSerialization.jsonObject(with: archiveBytes) as? [String: Any])
    let expectedBasis =
      basis == .hostReboot
      ? "operator-observed-host-reboot-and-reviewed-processes"
      : "operator-reviewed-owner-exit-and-no-other-runtime"
    #expect(archive["basis"] as? String == expectedBasis)
    #expect(archive["oldSessionNormallySettled"] as? Bool == false)
    #expect(archive["oldChildReapingProved"] as? Bool == false)
    #expect(archive["oldBackendQuiescenceReceipt"] as? Bool == false)
    let prior = try #require(archive["prior"] as? [String: Any])
    let rows = try #require(prior["entries"] as? [[String: Any]])
    let expected = [
      "configuration.json": fixture.configuration, RuntimeIntent.filename: fixture.intent,
      "runtime.json": fixture.history,
    ].merging(fixture.run) { first, _ in first }
    for (name, bytes) in expected {
      let row = try #require(rows.first { $0["name"] as? String == name })
      #expect(Data(base64Encoded: try #require(row["bytes"] as? String)) == bytes)
    }
    let evidence = try #require(archive["evidence"] as? [String: Any])
    let observationKey = basis == .hostReboot ? "rebootObservation" : "ownerExitObservation"
    let expectedObservation = basis == .hostReboot ? interruptionReboot : interruptionOwnerExit
    #expect(Set(evidence.keys) == [observationKey, "processObservation"])
    #expect(
      Data(base64Encoded: try #require(evidence[observationKey] as? String))
        == expectedObservation)
    #expect(
      Data(base64Encoded: try #require(evidence["processObservation"] as? String))
        == interruptionProcesses)
    for (name, bytes) in fixture.run {
      let path = fixture.directory.appendingPathComponent(".runtime")
        .appendingPathComponent(interruptionRun).appendingPathComponent(name)
      #expect(try Data(contentsOf: path) == bytes)
    }
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent("configuration.json"))
        == fixture.configuration)
    var diskAfter = stat()
    try #require(lstat(fixture.directory.appendingPathComponent("disk.raw").path, &diskAfter) == 0)
    #expect(diskAfter.st_ino == diskBefore.st_ino && diskAfter.st_size == diskBefore.st_size)
    #expect(diskAfter.st_dev == diskBefore.st_dev)
    #expect(diskAfter.st_mtimespec.tv_sec == diskBefore.st_mtimespec.tv_sec)
    #expect(diskAfter.st_mtimespec.tv_nsec == diskBefore.st_mtimespec.tv_nsec)
    #expect(diskAfter.st_ctimespec.tv_sec == diskBefore.st_ctimespec.tv_sec)
    #expect(diskAfter.st_ctimespec.tv_nsec == diskBefore.st_ctimespec.tv_nsec)
    let ordinary = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    withExtendedLifetime(ordinary) {}
  }

  @Test(arguments: InterruptionRecoveryTestBasis.allCases)
  func positiveExistingWriterAlwaysBlocksRecovery(basis: InterruptionRecoveryTestBasis) async throws
  {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = RegisteredWindowsInterruptionRecovery()
    let observed = try await inspectInterruption(fixture, owner: owner)
    let fd = open(fixture.directory.appendingPathComponent("writer.lock").path, O_RDWR | O_CLOEXEC)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
    await #expect(throws: VMError.self) {
      _ = try await recoverInterruption(
        fixture, owner: owner, digest: observed.metadataSHA256, basis: basis)
    }
    try expectOriginalInterruption(fixture)
    #expect(try interruptionArchives(fixture).isEmpty)
    #expect(!owner.custodyRetained)
  }

  @Test(
    arguments: ["contents", "same-bytes-new-inode", "writer-new-inode"],
    InterruptionRecoveryTestBasis.allCases)
  func changedObservationCannotBeAdopted(
    kind: String, basis: InterruptionRecoveryTestBasis
  ) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = RegisteredWindowsInterruptionRecovery()
    let observed = try await inspectInterruption(fixture, owner: owner)
    let path =
      kind == "writer-new-inode"
      ? fixture.directory.appendingPathComponent("writer.lock")
      : fixture.directory.appendingPathComponent(".runtime")
        .appendingPathComponent(interruptionRun).appendingPathComponent("surface.json")
    let original = try Data(contentsOf: path)
    // Keep the old inode allocated; a new name cannot recycle its still-open inode.
    let retained = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try #require(retained >= 0)
    defer { close(retained) }
    try FileManager.default.removeItem(at: path)
    let replacement = kind == "contents" ? original + Data(" ".utf8) : original
    try writeInterruptionFixture(replacement, to: path)
    await #expect(throws: VMError.self) {
      _ = try await recoverInterruption(
        fixture, owner: owner, digest: observed.metadataSHA256, basis: basis)
    }
    try expectOriginalInterruption(fixture)
    #expect(try Data(contentsOf: path) == replacement)
    #expect(try interruptionArchives(fixture).isEmpty)
  }

  @Test func completedRecoveryCannotReplayTheOldObservation() async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = RegisteredWindowsInterruptionRecovery()
    let observed = try await inspectInterruption(fixture, owner: owner)
    _ = try await recoverInterruption(fixture, owner: owner, digest: observed.metadataSHA256)
    let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json"))
    await #expect(throws: VMError.self) {
      _ = try await recoverInterruption(
        fixture, owner: RegisteredWindowsInterruptionRecovery(), digest: observed.metadataSHA256)
    }
    #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json")) == bytes)
    #expect(try interruptionArchives(fixture).count == 1)
  }

  @Test(arguments: ["malformed", "foreign-session", "already-final"])
  func malformedOrNonpendingHistoryIsRefused(kind: String) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let path = fixture.directory.appendingPathComponent("runtime.json")
    try FileManager.default.removeItem(at: path)
    let bytes: Data
    if kind == "malformed" {
      bytes = Data("{}".utf8)
    } else {
      bytes = try RuntimeHistoryCodec.encode(
        RuntimeRecord(
          sessionID: kind == "foreign-session" ? UUID() : fixture.sessionID,
          sequence: 3, recordedAt: 1_792_310_350,
          snapshot: RuntimeSnapshot(
            state: kind == "already-final" ? .failed : .running, operation: nil,
            backendActive: kind != "already-final",
            outcome: kind == "already-final" ? .failed : .pending)))
    }
    try writeInterruptionFixture(bytes, to: path)
    await #expect(throws: VMError.self) {
      _ = try await inspectInterruption(fixture, owner: RegisteredWindowsInterruptionRecovery())
    }
    #expect(try Data(contentsOf: path) == bytes)
    #expect(try interruptionArchives(fixture).isEmpty)
  }

  @Test(arguments: ["malformed", "settled", "foreign-vm", "foreign-session"])
  func strictOldIntentMustMatchTheExplicitInterruptedSession(kind: String) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let path = fixture.directory.appendingPathComponent(RuntimeIntent.filename)
    let bytes: Data
    if kind == "malformed" {
      bytes = Data("{}".utf8)
    } else {
      let vm = kind == "foreign-vm" ? UUID() : fixture.vmID
      let session = kind == "foreign-session" ? UUID() : fixture.sessionID
      let state = kind == "settled" ? "settled" : "unsettled"
      bytes = Data(
        ("{\"schemaVersion\":1,\"vmID\":\"\(vm.uuidString)\","
          + "\"sessionID\":\"\(session.uuidString)\",\"state\":\"\(state)\"}\n").utf8)
    }
    try FileManager.default.removeItem(at: path)
    try writeInterruptionFixture(bytes, to: path)
    await #expect(throws: VMError.self) {
      _ = try await inspectInterruption(fixture, owner: RegisteredWindowsInterruptionRecovery())
    }
    #expect(try Data(contentsOf: path) == bytes)
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json"))
        == fixture.history)
    #expect(try interruptionArchives(fixture).isEmpty)
  }

  @Test(arguments: ["symlink", "hardlink", "fifo", "mode"])
  func unsafeMetadataCannotReachAnArchive(kind: String) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let directory = fixture.directory.appendingPathComponent(".runtime")
      .appendingPathComponent(interruptionRun)
    let path = directory.appendingPathComponent("surface.json")
    try FileManager.default.removeItem(at: path)
    switch kind {
    case "symlink":
      try #require(symlink(directory.appendingPathComponent("display.json").path, path.path) == 0)
    case "hardlink":
      try #require(link(directory.appendingPathComponent("display.json").path, path.path) == 0)
    case "fifo": try #require(mkfifo(path.path, 0o600) == 0)
    default:
      try writeInterruptionFixture(Data("{}".utf8), to: path)
      try #require(chmod(path.path, 0o644) == 0)
    }
    await #expect(throws: VMError.self) {
      _ = try await inspectInterruption(fixture, owner: RegisteredWindowsInterruptionRecovery())
    }
    try expectOriginalInterruption(fixture)
    #expect(try interruptionArchives(fixture).isEmpty)
  }

  @Test func archiveCollisionPreservesBytesAndRetainsActualRecoveryLease() async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let id = UUID()
    let path = fixture.directory.appendingPathComponent(
      "runtime-interruption-\(id.uuidString.lowercased()).json")
    let preserved = Data("preexisting conflicting archive".utf8)
    try writeInterruptionFixture(preserved, to: path)
    let owner = RegisteredWindowsInterruptionRecovery(fault: nil, recoveryID: id)
    let observed = try await inspectInterruption(fixture, owner: owner)
    await #expect(throws: VMError.self) {
      _ = try await recoverInterruption(fixture, owner: owner, digest: observed.metadataSHA256)
    }
    try expectOriginalInterruption(fixture)
    #expect(try Data(contentsOf: path) == preserved)
    #expect(owner.custodyRetained)
    try expectInterruptionLeaseHeld(fixture)
    await #expect(throws: VMError.self) {
      _ = try await recoverInterruption(fixture, owner: owner, digest: observed.metadataSHA256)
    }
  }

  @Test(arguments: RuntimeInterruptionFault.allCases, InterruptionRecoveryTestBasis.allCases)
  func everyCommitBoundaryIsOneShotAndRetainsCustodyAfterFailure(
    point: RuntimeInterruptionFault, basis: InterruptionRecoveryTestBasis
  ) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let id = UUID()
    let owner = RegisteredWindowsInterruptionRecovery(fault: point, recoveryID: id)
    let observed = try await inspectInterruption(fixture, owner: owner)
    await #expect(throws: VMError.self) {
      _ = try await recoverInterruption(
        fixture, owner: owner, digest: observed.metadataSHA256, basis: basis)
    }
    #expect(owner.custodyRetained)
    try expectInterruptionLeaseHeld(fixture)
    let files = VMFiles()
    let intent = try #require(try await files.readRuntimeIntent(in: fixture.directory))
    if point == .afterArchive {
      try expectOriginalInterruption(fixture)
    } else {
      #expect(intent.sessionID == id)
      #expect(intent.state == (point == .afterFinal ? .settled : .unsettled))
    }
    if point == .afterHistory || point == .beforeFinal || point == .afterFinal {
      let current = try RuntimeHistoryCodec.decode(
        Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json")))
      #expect(current.sessionID == id && current.snapshot.outcome == .failed)
    }
    #expect(try interruptionArchives(fixture).count == 1)
    await #expect(throws: VMError.self) {
      // Changing the acknowledgement basis cannot reopen a one-shot owner.
      _ = try await recoverInterruption(
        fixture, owner: owner, digest: observed.metadataSHA256,
        basis: basis == .hostReboot ? .abandonedOwner : .hostReboot)
    }
  }

  @Test(arguments: ["empty-owner", "empty-processes", "oversized-owner", "oversized-processes"])
  func abandonedOwnerRequiresBothBoundedObservationsBeforeCustody(kind: String) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = RegisteredWindowsInterruptionRecovery()
    let observed = try await inspectInterruption(fixture, owner: owner)
    let ownerExit =
      kind == "empty-owner"
      ? Data()
      : kind == "oversized-owner" ? Data(repeating: 65, count: 65_537) : interruptionOwnerExit
    let processes =
      kind == "empty-processes"
      ? Data()
      : kind == "oversized-processes" ? Data(repeating: 65, count: 65_537) : interruptionProcesses
    await #expect(throws: VMError.self) {
      _ = try await owner.recoverAbandonedOwner(
        in: fixture.directory, expectedVMID: fixture.vmID, expectedSessionID: fixture.sessionID,
        runName: interruptionRun, expectedMetadataSHA256: observed.metadataSHA256,
        ownerExitObservation: ownerExit, processObservation: processes,
        acknowledgement: .reviewedOwnerExitAndNoOtherRuntime)
    }
    #expect(!owner.custodyRetained)
    #expect(try interruptionArchives(fixture).isEmpty)
    try expectOriginalInterruption(fixture)
    try expectInterruptionLeaseAvailable(fixture)
  }

  @Test(arguments: ["scope", "vm", "session"])
  func historicalRoutesMustBindTheExpectedVMAndInterruptedSession(kind: String) async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let path = fixture.directory.appendingPathComponent(".runtime")
      .appendingPathComponent(interruptionRun).appendingPathComponent("surface.json")
    let original = String(decoding: try #require(fixture.run["surface.json"]), as: UTF8.self)
    let changed: String
    switch kind {
    case "scope":
      changed = original.replacingOccurrences(
        of: "macopenvm-registered-qemu-shared-frame-route", with: "foreign-route")
    case "vm":
      changed = original.replacingOccurrences(of: fixture.vmID.uuidString, with: UUID().uuidString)
    default:
      changed = original.replacingOccurrences(
        of: fixture.sessionID.uuidString, with: UUID().uuidString)
    }
    try #require(changed != original)
    try FileManager.default.removeItem(at: path)
    let bytes = Data(changed.utf8)
    try writeInterruptionFixture(bytes, to: path)
    await #expect(throws: VMError.self) {
      _ = try await inspectInterruption(fixture, owner: RegisteredWindowsInterruptionRecovery())
    }
    #expect(try Data(contentsOf: path) == bytes)
    try expectOriginalInterruption(fixture)
    #expect(try interruptionArchives(fixture).isEmpty)
  }

  @Test func unknownRunMetadataRefusesToSilentlyOmitAnOldFact() async throws {
    let fixture = try interruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let path = fixture.directory.appendingPathComponent(".runtime")
      .appendingPathComponent(interruptionRun).appendingPathComponent("unknown.json")
    try writeInterruptionFixture(Data("{}".utf8), to: path)
    await #expect(throws: VMError.self) {
      _ = try await inspectInterruption(fixture, owner: RegisteredWindowsInterruptionRecovery())
    }
    try expectOriginalInterruption(fixture)
    #expect(try interruptionArchives(fixture).isEmpty)
  }
}
