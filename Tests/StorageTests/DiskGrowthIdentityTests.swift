// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private let identityOldBytes: UInt64 = 1_073_741_824
private let identityTargetBytes = identityOldBytes + 1024
private let identitySeed = Data("preserve identity fixture raw contents".utf8)

private struct IdentityGrowthFixture {
  let directory: URL
  let configuration: VMConfiguration
  let original: Data
  let replacement: Data
  var disk: URL { directory.appendingPathComponent(configuration.diskFile) }
  var journal: URL { directory.appendingPathComponent(DiskGrowthIntent.filename) }
  var registration: URL { directory.appendingPathComponent("configuration.json") }

  static func create(completed: Bool = true) async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("macOpenVM-growth-identity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "fresh identity fixture", guest: .linux, backend: .qemuHVF,
      diskBytes: identityOldBytes)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let original = try encoder.encode(configuration)
    let replacement = Data(
      String(decoding: original, as: UTF8.self).replacingOccurrences(
        of: "\"diskBytes\":\(identityOldBytes)",
        with: "\"diskBytes\":\(identityTargetBytes)"
      ).utf8)
    let fixture = Self(
      directory: directory, configuration: configuration,
      original: original, replacement: replacement)
    let files = VMFiles()
    try await files.createSparseDisk(at: fixture.disk, bytes: identityOldBytes)
    try await files.atomicWrite(original, at: fixture.registration)
    let fd = open(fixture.disk.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw identityFixtureError() }
    defer { close(fd) }
    let written = identitySeed.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    guard written == identitySeed.count, fsync(fd) == 0 else { throw identityFixtureError() }
    do {
      let owner = try VMLock(directory: directory, expectedVMID: configuration.id)
      let permit = try await files.beginDiskGrowth(
        in: directory, vmID: configuration.id, diskFile: configuration.diskFile,
        oldBytes: identityOldBytes, targetBytes: identityTargetBytes,
        originalConfiguration: original, replacementConfiguration: replacement, lock: owner)
      if completed { _ = try await files.commitDiskGrowth(permit) }
      withExtendedLifetime((owner, permit)) {}
    }
    return fixture
  }

  /// This intentionally forges fresh metadata to model mount-number/schema compatibility.
  /// It never unmounts a volume and is not real-remount or historical-upgrade proof.
  func rewrite(_ change: (inout [String: Any]) -> Void) async throws -> Data {
    let source = try Data(contentsOf: journal)
    var object = try #require(JSONSerialization.jsonObject(with: source) as? [String: Any])
    change(&object)
    var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    bytes.append(Data("\n \n".utf8))
    try await VMFiles().atomicWrite(bytes, at: journal)
    return bytes
  }

  func makeSyntheticLegacy() async throws -> Data {
    try await rewrite {
      $0["schemaVersion"] = 1
      $0.removeValue(forKey: "directoryVolumeUUID")
      $0.removeValue(forKey: "diskVolumeUUID")
    }
  }

  func record() async throws -> DiskGrowthIntent {
    try #require(try await VMFiles().readDiskGrowthIntent(in: directory))
  }
}

private struct IdentityGrowthSnapshot: Equatable {
  let diskDevice: Int32
  let diskInode: UInt64
  let diskMode: mode_t
  let diskOwner: UInt32
  let diskLinks: UInt16
  let diskBytes: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
  let seed: Data
  let registration: Data
  let journal: Data

  init(_ fixture: IdentityGrowthFixture) throws {
    let fd = open(fixture.disk.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw identityFixtureError() }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw identityFixtureError() }
    var data = Data(count: identitySeed.count)
    let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
    guard count == data.count else { throw identityFixtureError() }
    diskDevice = info.st_dev
    diskInode = info.st_ino
    diskMode = info.st_mode
    diskOwner = info.st_uid
    diskLinks = info.st_nlink
    diskBytes = info.st_size
    modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    changedSeconds = Int64(info.st_ctimespec.tv_sec)
    changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    seed = data
    registration = try Data(contentsOf: fixture.registration)
    journal = try Data(contentsOf: fixture.journal)
  }

  func sameDiskAndRegistration(as other: Self) -> Bool {
    diskDevice == other.diskDevice && diskInode == other.diskInode
      && diskMode == other.diskMode && diskOwner == other.diskOwner
      && diskLinks == other.diskLinks && diskBytes == other.diskBytes
      && modifiedSeconds == other.modifiedSeconds
      && modifiedNanoseconds == other.modifiedNanoseconds
      && changedSeconds == other.changedSeconds && changedNanoseconds == other.changedNanoseconds
      && seed == other.seed && registration == other.registration
  }
}

private func identityFixtureError() -> VMError {
  VMError(.storage, "Fresh identity fixture failed.", recovery: "Preserve test evidence.")
}

private func differentMountNumber(_ number: Int32) -> Int32 {
  number == Int32.max ? number - 1 : number + 1
}

private func identityResponse(uuid: UUID = UUID()) -> [UInt8] {
  var words: [UInt32] = [
    40, UInt32(ATTR_CMN_RETURNED_ATTRS), UInt32(ATTR_VOL_UUID), 0, 0, 0,
  ]
  var bytes = words.withUnsafeMutableBytes { Array($0) }
  var tuple = uuid.uuid
  withUnsafeBytes(of: &tuple) { bytes.append(contentsOf: $0) }
  return bytes
}

@Suite struct DiskGrowthIdentityTests {
  @Test func descriptorVolumeUUIDMatchesForActualFreshDirectoryAndDisk() async throws {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let parent = try DiskGrowthIO.openDirectory(fixture.directory)
    defer { close(parent) }
    let disk = try DiskGrowthIO.openDisk(
      fixture.configuration.diskFile, at: parent, writable: false)
    defer { close(disk) }
    let record = try await fixture.record()
    #expect(record.schemaVersion == 2)
    #expect(
      record.directoryVolumeUUID != nil && record.directoryVolumeUUID == record.diskVolumeUUID)
    #expect(try DiskGrowthVolumeIdentity.read(from: parent) == record.directoryVolumeUUID)
    #expect(try DiskGrowthVolumeIdentity.read(from: disk) == record.diskVolumeUUID)
    let opened = try DiskGrowthOpenedIdentity(directory: parent, disk: disk)
    var parentInfo = stat()
    var diskInfo = stat()
    #expect(fstat(parent, &parentInfo) == 0 && fstat(disk, &diskInfo) == 0)
    #expect(opened.matches(directory: parentInfo, disk: diskInfo))
    parentInfo.st_dev = differentMountNumber(parentInfo.st_dev)
    #expect(!opened.matches(directory: parentInfo, disk: diskInfo))
    parentInfo.st_dev = opened.directoryDevice
    diskInfo.st_dev = differentMountNumber(diskInfo.st_dev)
    #expect(!opened.matches(directory: parentInfo, disk: diskInfo))
  }

  @Test func volumeResponseRequiresExactReturnedUUIDAndRejectsInvalidDescriptor() throws {
    let expected = UUID()
    #expect(
      try DiskGrowthVolumeIdentity.decodeResponse(identityResponse(uuid: expected)) == expected)
    #expect(throws: VMError.self) { _ = try DiskGrowthVolumeIdentity.read(from: -1) }
    var cases = [[UInt8]]()
    let good = identityResponse(uuid: expected)
    cases.append(Array(good.dropLast()))
    cases.append(good + [0])
    for offset in [0, 4, 8, 12, 16, 20] {
      var bytes = good
      bytes[offset] ^= 1
      cases.append(bytes)
    }
    var absent = good
    absent.replaceSubrange(8..<12, with: [0, 0, 0, 0])
    cases.append(absent)
    var zero = good
    zero.replaceSubrange(24..<40, with: [UInt8](repeating: 0, count: 16))
    cases.append(zero)
    for bytes in cases {
      #expect(throws: VMError.self) { _ = try DiskGrowthVolumeIdentity.decodeResponse(bytes) }
    }
  }

  @Test(arguments: [false, true])
  func injectedHistoricalMountNumberChangePreservesV2AdmissionAndPendingRecovery(pending: Bool)
    async throws
  {
    let fixture = try await IdentityGrowthFixture.create(completed: !pending)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let old = try await fixture.record()
    let stale = differentMountNumber(old.directoryDevice)
    _ = try await fixture.rewrite {
      $0["directoryDevice"] = stale
      $0["diskDevice"] = stale
    }
    let before = try IdentityGrowthSnapshot(fixture)
    if pending {
      #expect(throws: VMError.self) {
        _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      }
      let files = VMFiles()
      let permit = try await files.openDiskGrowthRecovery(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: old.transactionID)
      _ = try await files.commitDiskGrowth(permit)
      let after = try await fixture.record()
      #expect(after.schemaVersion == 2 && after.state == .completed)
      #expect(after.directoryDevice == stale && after.diskDevice == stale)
      #expect(after.directoryVolumeUUID == old.directoryVolumeUUID)
      #expect(after.diskVolumeUUID == old.diskVolumeUUID)
      withExtendedLifetime(permit) {}
    } else {
      try await VMFiles().verifyCompletedDiskGrowth(
        in: fixture.directory, expectedVMID: fixture.configuration.id)
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      #expect(try IdentityGrowthSnapshot(fixture) == before)
      withExtendedLifetime(owner) {}
    }
  }

  @Test(arguments: [
    "directory-uuid", "disk-uuid", "both-uuid", "directory-inode", "disk-inode", "device-pair",
  ])
  func v2RejectsChangedVolumeInodesAndMismatchedVolumeBindings(kind: String) async throws {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let record = try await fixture.record()
    _ = try await fixture.rewrite { object in
      switch kind {
      case "directory-uuid": object["directoryVolumeUUID"] = UUID().uuidString
      case "disk-uuid": object["diskVolumeUUID"] = UUID().uuidString
      case "both-uuid":
        let replacement = UUID().uuidString
        object["directoryVolumeUUID"] = replacement
        object["diskVolumeUUID"] = replacement
      case "directory-inode": object["directoryInode"] = record.directoryInode + 1
      case "disk-inode": object["diskInode"] = record.diskInode + 1
      default: object["diskDevice"] = differentMountNumber(record.diskDevice)
      }
    }
    let before = try IdentityGrowthSnapshot(fixture)
    await #expect(throws: VMError.self) {
      try await VMFiles().verifyCompletedDiskGrowth(
        in: fixture.directory, expectedVMID: fixture.configuration.id)
    }
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    }
    #expect(try IdentityGrowthSnapshot(fixture) == before)
  }

  @Test(arguments: [
    "missing", "null", "zero", "lowercase", "invalid", "legacy-with-uuid", "unknown-version",
  ])
  func schemaRejectsMissingInvalidOrUnexpectedVolumeFields(kind: String) async throws {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.rewrite { object in
      switch kind {
      case "missing": object.removeValue(forKey: "directoryVolumeUUID")
      case "null": object["directoryVolumeUUID"] = NSNull()
      case "zero":
        object["directoryVolumeUUID"] = "00000000-0000-0000-0000-000000000000"
        object["diskVolumeUUID"] = object["directoryVolumeUUID"]
      case "lowercase":
        object["directoryVolumeUUID"] = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE".lowercased()
        object["diskVolumeUUID"] = object["directoryVolumeUUID"]
      case "invalid": object["directoryVolumeUUID"] = "not-a-volume-uuid"
      case "legacy-with-uuid": object["schemaVersion"] = 1
      default: object["schemaVersion"] = 3
      }
    }
    let before = try IdentityGrowthSnapshot(fixture)
    await #expect(throws: VMError.self) { _ = try await fixture.record() }
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    }
    #expect(try IdentityGrowthSnapshot(fixture) == before)
  }

  @Test func escapedDuplicateVolumeKeyAndSchemaTwoDuplicatesRejectStrictly() async throws {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try Data(contentsOf: fixture.journal)
    let text = String(decoding: original, as: UTF8.self)
    for extra in [
      "\"\\u0064irectoryVolumeUUID\":\"\(UUID().uuidString)\"",
      "\"schemaVersion\":2",
    ] {
      let bad = Data(text.replacingOccurrences(of: "}", with: ",\(extra)}").utf8)
      try await VMFiles().atomicWrite(bad, at: fixture.journal)
      await #expect(throws: VMError.self) { _ = try await fixture.record() }
      #expect(try Data(contentsOf: fixture.journal) == bad)
    }
  }

  @Test(arguments: [false, true])
  func legacyMountNumberMismatchCannotAdmitRecoverOrUpgrade(pending: Bool) async throws {
    let fixture = try await IdentityGrowthFixture.create(completed: !pending)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.makeSyntheticLegacy()
    let record = try await fixture.record()
    var owner: VMLock?
    if !pending {
      owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    }
    let stale = differentMountNumber(record.directoryDevice)
    _ = try await fixture.rewrite {
      $0["directoryDevice"] = stale
      $0["diskDevice"] = stale
    }
    let before = try IdentityGrowthSnapshot(fixture)
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    }
    if pending {
      await #expect(throws: VMError.self) {
        _ = try await VMFiles().openDiskGrowthRecovery(
          in: fixture.directory, vmID: fixture.configuration.id,
          expectedTransactionID: record.transactionID)
      }
    } else {
      await #expect(throws: VMError.self) {
        _ = try await VMFiles().upgradeCompletedDiskGrowthIdentity(
          in: fixture.directory, vmID: fixture.configuration.id,
          expectedTransactionID: record.transactionID, lock: try #require(owner))
      }
    }
    #expect(try IdentityGrowthSnapshot(fixture) == before)
    withExtendedLifetime(owner) {}
  }

  @Test func validLegacyPendingRecoveryCompletesWithExactLegacyIdentitySchema() async throws {
    let fixture = try await IdentityGrowthFixture.create(completed: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.makeSyntheticLegacy()
    let prior = try await fixture.record()
    #expect(prior.schemaVersion == 1 && prior.directoryVolumeUUID == nil)
    let files = VMFiles()
    let permit = try await files.openDiskGrowthRecovery(
      in: fixture.directory, vmID: fixture.configuration.id,
      expectedTransactionID: prior.transactionID)
    _ = try await files.commitDiskGrowth(permit)
    let final = try await fixture.record()
    #expect(final.schemaVersion == 1 && final.state == .completed)
    #expect(final.directoryVolumeUUID == nil && final.diskVolumeUUID == nil)
    #expect(final.directoryDevice == prior.directoryDevice && final.diskDevice == prior.diskDevice)
    #expect(final.directoryInode == prior.directoryInode && final.diskInode == prior.diskInode)
    withExtendedLifetime(permit) {}
  }

  @Test func explicitLegacyUpgradePreservesExactJournalAndNeverWritesDiskOrConfiguration()
    async throws
  {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let priorBytes = try await fixture.makeSyntheticLegacy()
    let prior = try await fixture.record()
    let renamed = Data(
      String(decoding: fixture.replacement, as: UTF8.self).replacingOccurrences(
        of: "fresh identity fixture", with: "renamed after growth"
      ).utf8)
    try await VMFiles().atomicWrite(renamed, at: fixture.registration)
    let before = try IdentityGrowthSnapshot(fixture)
    let files = VMFiles()
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    let upgraded = try await files.upgradeCompletedDiskGrowthIdentity(
      in: fixture.directory, vmID: fixture.configuration.id,
      expectedTransactionID: prior.transactionID, lock: owner)
    #expect(upgraded.schemaVersion == 2 && upgraded.state == .completed)
    #expect(upgraded.vmID == prior.vmID && upgraded.transactionID == prior.transactionID)
    #expect(
      upgraded.directoryInode == prior.directoryInode && upgraded.diskInode == prior.diskInode)
    #expect(
      upgraded.directoryVolumeUUID != nil && upgraded.directoryVolumeUUID == upgraded.diskVolumeUUID
    )
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(prior.transactionID.uuidString)-schema1-completed.json")
    #expect(try Data(contentsOf: archive) == priorBytes)
    var info = stat()
    #expect(lstat(archive.path, &info) == 0 && DiskGrowthIO.safe(info))
    #expect(before.sameDiskAndRegistration(as: try IdentityGrowthSnapshot(fixture)))
    #expect(throws: VMError.self) { _ = try owner.duplicateForInheritance() }
    await #expect(throws: VMError.self) {
      _ = try await files.upgradeCompletedDiskGrowthIdentity(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: prior.transactionID, lock: owner)
    }
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [
    DiskGrowthFaultPoint.afterIdentityUpgradeArchive, .afterIdentityUpgradeRename,
    .afterIdentityUpgradeFlush,
  ])
  func upgradeBoundaryFailuresPreserveEvidenceAndSafeActualJournal(point: DiskGrowthFaultPoint)
    async throws
  {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let priorBytes = try await fixture.makeSyntheticLegacy()
    let prior = try await fixture.record()
    let before = try IdentityGrowthSnapshot(fixture)
    let files = VMFiles()
    await files.injectDiskGrowthFault(point)
    do {
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      await #expect(throws: VMError.self) {
        _ = try await files.upgradeCompletedDiskGrowthIdentity(
          in: fixture.directory, vmID: fixture.configuration.id,
          expectedTransactionID: prior.transactionID, lock: owner)
      }
      withExtendedLifetime(owner) {}
    }
    let current = try await fixture.record()
    #expect(current.schemaVersion == (point == .afterIdentityUpgradeArchive ? 1 : 2))
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(prior.transactionID.uuidString)-schema1-completed.json")
    #expect(try Data(contentsOf: archive) == priorBytes)
    #expect(before.sameDiskAndRegistration(as: try IdentityGrowthSnapshot(fixture)))
    if point == .afterIdentityUpgradeArchive {
      let retry = VMFiles()
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      var archiveBefore = stat()
      #expect(lstat(archive.path, &archiveBefore) == 0)
      _ = try await retry.upgradeCompletedDiskGrowthIdentity(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: prior.transactionID, lock: owner)
      var archiveAfter = stat()
      #expect(lstat(archive.path, &archiveAfter) == 0)
      #expect(DiskGrowthIO.stable(archiveBefore, archiveAfter))
      #expect(try Data(contentsOf: archive) == priorBytes)
      withExtendedLifetime(owner) {}
    }
  }

  @Test(arguments: ["conflict", "symlink", "hardlink", "mode", "directory", "fifo"])
  func unsafeOrConflictingLegacyArchiveNeverReplacesEvidence(kind: String) async throws {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let priorBytes = try await fixture.makeSyntheticLegacy()
    let prior = try await fixture.record()
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(prior.transactionID.uuidString)-schema1-completed.json")
    let files = VMFiles()
    switch kind {
    case "symlink":
      try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: fixture.journal)
    case "hardlink": #expect(link(fixture.journal.path, archive.path) == 0)
    case "directory":
      try FileManager.default.createDirectory(
        at: archive, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    case "fifo": #expect(mkfifo(archive.path, 0o600) == 0)
    default:
      try await files.atomicWrite(
        kind == "conflict" ? Data("conflict".utf8) : priorBytes, at: archive)
      if kind == "mode" { #expect(chmod(archive.path, 0o640) == 0) }
    }
    let before = try IdentityGrowthSnapshot(fixture)
    // A hard link also makes the live journal unsafe, and must fail at owner admission.
    if kind == "hardlink" {
      #expect(throws: VMError.self) {
        _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      }
    } else {
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      await #expect(throws: VMError.self) {
        _ = try await files.upgradeCompletedDiskGrowthIdentity(
          in: fixture.directory, vmID: fixture.configuration.id,
          expectedTransactionID: prior.transactionID, lock: owner)
      }
      withExtendedLifetime(owner) {}
    }
    #expect(try IdentityGrowthSnapshot(fixture) == before)
  }
  @Test(arguments: ["directory", "disk", "both"])
  func pendingV2ChangedVolumeCannotRecoverOrMutate(kind: String) async throws {
    let fixture = try await IdentityGrowthFixture.create(completed: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let prior = try await fixture.record()
    _ = try await fixture.rewrite { object in
      let replacement = UUID().uuidString
      if kind != "disk" { object["directoryVolumeUUID"] = replacement }
      if kind != "directory" { object["diskVolumeUUID"] = replacement }
    }
    let before = try IdentityGrowthSnapshot(fixture)
    await #expect(throws: VMError.self) {
      _ = try await VMFiles().openDiskGrowthRecovery(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: prior.transactionID)
    }
    #expect(try IdentityGrowthSnapshot(fixture) == before)
  }

  @Test(arguments: [
    "transaction", "vm", "runtime", "inherited", "pending", "configuration", "backup", "target",
    "disk-replace", "disk-mode", "disk-link", "directory-mode", "journal-link", "journal-symlink",
  ])
  func explicitUpgradeRechecksEveryExistingProofBeforeAnyArchive(kind: String) async throws {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.makeSyntheticLegacy()
    let prior = try await fixture.record()
    let files = VMFiles()
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    var vmID = fixture.configuration.id
    var transactionID = prior.transactionID
    var inherited: VMLock.InheritedLease?
    switch kind {
    case "transaction": transactionID = UUID()
    case "vm": vmID = UUID()
    case "runtime":
      let bytes = Data(
        ("{\"schemaVersion\":1,\"vmID\":\"\(vmID.uuidString)\",\"sessionID\":\"\(UUID().uuidString)\",\"state\":\"unsettled\"}")
          .utf8)
      try await files.atomicWrite(
        bytes, at: fixture.directory.appendingPathComponent(RuntimeIntent.filename))
    case "inherited": inherited = try owner.duplicateForInheritance()
    case "pending": _ = try await fixture.rewrite { $0["state"] = "pending" }
    case "configuration": try await files.atomicWrite(fixture.original, at: fixture.registration)
    case "backup":
      try await files.atomicWrite(
        Data("corrupt".utf8), at: fixture.directory.appendingPathComponent(prior.backupFile))
    case "target":
      try await files.atomicWrite(
        Data("corrupt".utf8), at: fixture.directory.appendingPathComponent(prior.targetFile))
    case "disk-replace":
      try FileManager.default.moveItem(
        at: fixture.disk, to: fixture.directory.appendingPathComponent("preserved-original.raw"))
      try await files.createSparseDisk(at: fixture.disk, bytes: identityTargetBytes)
    case "disk-mode": #expect(chmod(fixture.disk.path, 0o640) == 0)
    case "disk-link":
      #expect(
        link(fixture.disk.path, fixture.directory.appendingPathComponent("disk-alias.raw").path)
          == 0)
    case "directory-mode": #expect(chmod(fixture.directory.path, 0o770) == 0)
    case "journal-link":
      #expect(
        link(
          fixture.journal.path, fixture.directory.appendingPathComponent("journal-alias.json").path)
          == 0)
    default:
      let preserved = fixture.directory.appendingPathComponent("preserved-journal.json")
      try FileManager.default.moveItem(at: fixture.journal, to: preserved)
      try FileManager.default.createSymbolicLink(at: fixture.journal, withDestinationURL: preserved)
    }
    let before = try IdentityGrowthSnapshot(fixture)
    await #expect(throws: VMError.self) {
      _ = try await files.upgradeCompletedDiskGrowthIdentity(
        in: fixture.directory, vmID: vmID, expectedTransactionID: transactionID, lock: owner)
    }
    #expect(try IdentityGrowthSnapshot(fixture) == before)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent(
          "disk-growth-\(prior.transactionID.uuidString)-schema1-completed.json"
        ).path))
    withExtendedLifetime((owner, inherited)) {}
  }

  @Test(arguments: [false, true])
  func actualNextGrowthAfterLegacyCompletionPreservesExactPriorEvidence(explicitUpgrade: Bool)
    async throws
  {
    let fixture = try await IdentityGrowthFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacyBytes = try await fixture.makeSyntheticLegacy()
    let legacy = try await fixture.record()
    if explicitUpgrade {
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      _ = try await VMFiles().upgradeCompletedDiskGrowthIdentity(
        in: fixture.directory, vmID: fixture.configuration.id,
        expectedTransactionID: legacy.transactionID, lock: owner)
      withExtendedLifetime(owner) {}
    }
    let priorCompletedBytes = try Data(contentsOf: fixture.journal)
    let before = try IdentityGrowthSnapshot(fixture)
    let target = identityTargetBytes + 512
    let replacement = Data(
      String(decoding: fixture.replacement, as: UTF8.self).replacingOccurrences(
        of: "\"diskBytes\":\(identityTargetBytes)", with: "\"diskBytes\":\(target)"
      ).utf8)
    let files = VMFiles()
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    let permit = try await files.beginDiskGrowth(
      in: fixture.directory, vmID: fixture.configuration.id,
      diskFile: fixture.configuration.diskFile, oldBytes: identityTargetBytes, targetBytes: target,
      originalConfiguration: fixture.replacement, replacementConfiguration: replacement, lock: owner
    )
    let pending = try await fixture.record()
    #expect(pending.schemaVersion == 2 && pending.state == .pending)
    #expect(pending.transactionID != legacy.transactionID)
    let completedArchive = fixture.directory.appendingPathComponent(
      "disk-growth-\(legacy.transactionID.uuidString)-completed.json")
    #expect(try Data(contentsOf: completedArchive) == priorCompletedBytes)
    let legacyArchive =
      explicitUpgrade
      ? fixture.directory.appendingPathComponent(
        "disk-growth-\(legacy.transactionID.uuidString)-schema1-completed.json")
      : completedArchive
    #expect(try Data(contentsOf: legacyArchive) == legacyBytes)
    _ = try await files.commitDiskGrowth(permit)
    let final = try await fixture.record()
    #expect(final.schemaVersion == 2 && final.state == .completed && final.targetBytes == target)
    #expect(final.directoryVolumeUUID == pending.directoryVolumeUUID)
    #expect(final.diskVolumeUUID == pending.diskVolumeUUID)
    let after = try IdentityGrowthSnapshot(fixture)
    #expect(after.diskDevice == before.diskDevice && after.diskInode == before.diskInode)
    #expect(after.diskBytes == Int64(target) && after.seed == identitySeed)
    #expect(after.registration == replacement)
    #expect(try Data(contentsOf: legacyArchive) == legacyBytes)
    let fd = open(fixture.disk.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw identityFixtureError() }
    defer { close(fd) }
    var tail = Data(count: 1536)
    let count = tail.withUnsafeMutableBytes {
      pread(fd, $0.baseAddress, $0.count, off_t(identityOldBytes))
    }
    #expect(count == 1536 && tail == Data(repeating: 0, count: 1536))
    withExtendedLifetime((owner, permit)) {}
  }

}
