// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private struct UpgradeInspectionFixture {
  let directory: URL
  let configuration: VMConfiguration
  var journal: URL { directory.appendingPathComponent(DiskGrowthIntent.filename) }
  var disk: URL { directory.appendingPathComponent(configuration.diskFile) }

  static func create(legacy: Bool = true, completed: Bool = true) async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("macOpenVM-upgrade-inspection-\(UUID())")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "fresh synthetic legacy inspection", guest: .linux, backend: .qemuHVF,
      diskBytes: 1_073_741_824)
    let fixture = Self(directory: directory, configuration: configuration)
    let files = VMFiles()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let original = try encoder.encode(configuration)
    var target = configuration
    target.diskBytes += 1024
    let replacement = try encoder.encode(target)
    try await files.atomicWrite(
      original, at: directory.appendingPathComponent("configuration.json"))
    try await files.createSparseDisk(at: fixture.disk, bytes: configuration.diskBytes)
    do {
      let lock = try VMLock(directory: directory, expectedVMID: configuration.id)
      let permit = try await files.beginDiskGrowth(
        in: directory, vmID: configuration.id, diskFile: configuration.diskFile,
        oldBytes: configuration.diskBytes, targetBytes: target.diskBytes,
        originalConfiguration: original, replacementConfiguration: replacement, lock: lock)
      if completed { _ = try await files.commitDiskGrowth(permit) }
      withExtendedLifetime((lock, permit)) {}
    }
    if legacy {
      // Synthetic fresh fixture only: this is neither historical migration nor remount proof.
      try await fixture.changeJournal {
        $0["schemaVersion"] = 1
        $0.removeValue(forKey: "directoryVolumeUUID")
        $0.removeValue(forKey: "diskVolumeUUID")
      }
    }
    return fixture
  }

  func changeJournal(_ change: (inout [String: Any]) -> Void) async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
    change(&object)
    let bytes =
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      + Data("\n \n".utf8)
    try await VMFiles().atomicWrite(bytes, at: journal)
  }

  func metadata() throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
    where name != configuration.diskFile {
      result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
    }
    return result
  }
}

@Suite struct DiskGrowthIdentityUpgradeInspectionTests {
  @Test func eligibleObservationIsReadOnlyAndRetainsExactLegacyBytes() async throws {
    let fixture = try await UpgradeInspectionFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let before = try fixture.metadata()
    let observed = try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory)
    guard case .eligibleAtCheck = observed.kind else {
      Issue.record("Expected eligible fresh v1")
      return
    }
    let snapshot = try #require(observed.snapshot)
    #expect(snapshot.journal == before[DiskGrowthIntent.filename])
    #expect(snapshot.history == nil && snapshot.intent == nil)
    #expect(try fixture.metadata() == before)
    #expect(
      try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory).snapshot
        == snapshot)
  }

  @Test(arguments: [false, true]) func pendingNeverOffersUpgrade(legacy: Bool) async throws {
    let fixture = try await UpgradeInspectionFixture.create(legacy: legacy, completed: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let before = try fixture.metadata()
    let observed = try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory)
    guard case .pendingGrowth = observed.kind else {
      Issue.record("Expected pending")
      return
    }
    #expect(observed.sourceSchemaVersion == (legacy ? 1 : 2))
    #expect(observed.snapshot == nil)
    #expect(try fixture.metadata() == before)
  }

  @Test func stableCompletedAndAbsentJournalAreNotUpgradeCandidates() async throws {
    let fixture = try await UpgradeInspectionFixture.create(legacy: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let observed = try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory)
    guard case .alreadyStable = observed.kind else {
      Issue.record("Expected stable")
      return
    }
    try FileManager.default.removeItem(at: fixture.journal)
    let absent = try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory)
    guard case .notNeeded = absent.kind else {
      Issue.record("Expected absent")
      return
    }
    #expect(absent.snapshot == nil)
  }

  @Test(arguments: ["directoryDevice", "diskDevice", "directoryInode", "diskInode"])
  func legacyIdentityMismatchRefusesUnchanged(field: String) async throws {
    let fixture = try await UpgradeInspectionFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.changeJournal { $0[field] = ($0[field] as! NSNumber).uint64Value + 1 }
    let before = try fixture.metadata()
    let observed = try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory)
    guard case .legacyProofUnavailable = observed.kind else {
      Issue.record("Legacy mismatch admitted")
      return
    }
    #expect(observed.snapshot == nil)
    #expect(try fixture.metadata() == before)
  }

  @Test(arguments: ["missing", "symlink", "hardlink", "permissions"])
  func unsafeOrMissingExistingWriterIsNeverRepaired(condition: String) async throws {
    let fixture = try await UpgradeInspectionFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = fixture.directory.appendingPathComponent("writer.lock")
    if condition == "permissions" {
      #expect(chmod(writer.path, 0o644) == 0)
    } else {
      try FileManager.default.removeItem(at: writer)
      if condition == "symlink" {
        try FileManager.default.createSymbolicLink(
          atPath: writer.path, withDestinationPath: "configuration.json")
      } else if condition == "hardlink" {
        try FileManager.default.linkItem(at: fixture.journal, to: writer)
      }
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
    await #expect(throws: VMError.self) {
      try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == names)
    if condition == "missing" { #expect(!FileManager.default.fileExists(atPath: writer.path)) }
  }

  @Test func conflictingLegacyArchiveIsRefusedWithoutReplacement() async throws {
    let fixture = try await UpgradeInspectionFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let record = try #require(try await VMFiles().readDiskGrowthIntent(in: fixture.directory))
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(record.transactionID)-schema1-completed.json")
    try await VMFiles().writeNewMetadata(Data("conflicting archive".utf8), at: archive)
    let before = try fixture.metadata()
    await #expect(throws: VMError.self) {
      try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: fixture.directory)
    }
    #expect(try fixture.metadata() == before)
  }

  @Test func staleRuntimeBytesRefuseBeforeArchiveEvenWithPermissivePackageCallback() async throws {
    let fixture = try await UpgradeInspectionFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    let observed = try #require(
      try await files.inspectDiskGrowthIdentityUpgrade(in: fixture.directory).snapshot)
    try await files.atomicWrite(
      Data("changed runtime bytes".utf8),
      at: fixture.directory.appendingPathComponent("runtime.json"))
    let before = try fixture.metadata()
    let lock = try VMLock(
      existingDirectory: fixture.directory, expectedVMID: fixture.configuration.id)
    await #expect(throws: VMError.self) {
      try await files.upgradeCompletedDiskGrowthIdentity(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: observed.record.transactionID, lock: lock,
        observed: observed, validateStopped: { _, _, _ in })
    }
    #expect(try fixture.metadata() == before)
    withExtendedLifetime(lock) {}
  }

  @Test func productObservationAndCallbackMustBePaired() async throws {
    let fixture = try await UpgradeInspectionFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    let observed = try #require(
      try await files.inspectDiskGrowthIdentityUpgrade(in: fixture.directory).snapshot)
    let before = try fixture.metadata()
    let lock = try VMLock(
      existingDirectory: fixture.directory, expectedVMID: fixture.configuration.id)
    await #expect(throws: VMError.self) {
      try await files.upgradeCompletedDiskGrowthIdentity(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: observed.record.transactionID, lock: lock, observed: observed)
    }
    #expect(try fixture.metadata() == before)
    withExtendedLifetime(lock) {}
  }

  @Test(arguments: [1, 2, 3])
  func mutationDuringSynchronousValidationNeverReportsSuccess(phase: Int) async throws {
    let fixture = try await UpgradeInspectionFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    let observed = try #require(
      try await files.inspectDiskGrowthIdentityUpgrade(in: fixture.directory).snapshot)
    let action = UpgradeValidationMutation(
      phase: phase, runtime: fixture.directory.appendingPathComponent("runtime.json"))
    let lock = try VMLock(
      existingDirectory: fixture.directory, expectedVMID: fixture.configuration.id)
    await #expect(throws: VMError.self) {
      try await files.upgradeCompletedDiskGrowthIdentity(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: observed.record.transactionID, lock: lock,
        observed: observed, validateStopped: { _, _, _ in try action.validate() })
    }
    let current = try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
    #expect(current.schemaVersion == (phase == 3 ? 2 : 1))
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(observed.record.transactionID)-schema1-completed.json")
    if phase == 1 {
      #expect(!FileManager.default.fileExists(atPath: archive.path))
    } else {
      #expect(try Data(contentsOf: archive) == observed.journal)
    }
    if phase != 3 { #expect(try Data(contentsOf: fixture.journal) == observed.journal) }
    #expect(try Data(contentsOf: action.runtime) == UpgradeValidationMutation.bytes)
    withExtendedLifetime(lock) {}
  }
}

/// Deliberate test-only callback mutation at the actual pre-archive, post-archive,
/// or post-rename phase. It is not a power-loss or external-process race simulation.
/// The count is the sole mutable state and is protected by the private mutex.
private final class UpgradeValidationMutation: @unchecked Sendable {
  static let bytes = Data("retained test mutation during validation".utf8)
  let runtime: URL
  private let phase: Int
  private let mutex = NSLock()
  private var count = 0
  init(phase: Int, runtime: URL) {
    self.phase = phase
    self.runtime = runtime
  }
  func validate() throws {
    mutex.lock()
    count += 1
    let perform = count == phase
    mutex.unlock()
    guard perform else { return }
    let fd = open(runtime.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw diskGrowthError(.storage) }
    defer { close(fd) }
    let written = Self.bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    guard written == Self.bytes.count, fsync(fd) == 0 else { throw diskGrowthError(.storage) }
  }
}
