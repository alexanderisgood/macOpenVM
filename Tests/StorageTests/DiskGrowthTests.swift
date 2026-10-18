// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private let growthOldBytes: UInt64 = 1_073_741_824
private let growthTargetBytes = growthOldBytes + 2048
private let growthPrefix = Data((0..<512).map { UInt8(($0 * 7 + 3) & 255) })
private let growthOldTail = Data((0..<512).map { UInt8(($0 * 11 + 9) & 255) })

private struct GrowthFixture {
  let directory: URL
  let vmID: UUID
  let original: Data
  let replacement: Data
  var disk: URL { directory.appendingPathComponent("disk.raw") }
  var configuration: URL { directory.appendingPathComponent("configuration.json") }
}

private func makeGrowthFixture() async throws -> GrowthFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-growth-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let configuration = VMConfiguration(
    name: "original growth fixture", guest: .linux, backend: .qemuHVF, diskBytes: growthOldBytes)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let original = try encoder.encode(configuration)
  let text = String(decoding: original, as: UTF8.self)
  let replacement = Data(
    text.replacingOccurrences(
      of: "\"diskBytes\":\(growthOldBytes)", with: "\"diskBytes\":\(growthTargetBytes)"
    ).utf8)
  let files = VMFiles()
  try await files.createSparseDisk(
    at: directory.appendingPathComponent("disk.raw"), bytes: growthOldBytes)
  try await files.atomicWrite(original, at: directory.appendingPathComponent("configuration.json"))
  let fixture = GrowthFixture(
    directory: directory, vmID: configuration.id, original: original, replacement: replacement)
  try writeGrowthRange(growthPrefix, at: fixture.disk, offset: 0)
  try writeGrowthRange(growthOldTail, at: fixture.disk, offset: growthOldBytes - 512)
  return fixture
}

private func writeGrowthRange(_ data: Data, at url: URL, offset: UInt64) throws {
  let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw diskGrowthTestError() }
  defer { close(fd) }
  let written = data.withUnsafeBytes { buffer in
    pwrite(fd, buffer.baseAddress, buffer.count, off_t(offset))
  }
  guard written == data.count, fsync(fd) == 0 else { throw diskGrowthTestError() }
}

private func readGrowthRange(at url: URL, offset: UInt64, bytes: Int) throws -> Data {
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw diskGrowthTestError() }
  defer { close(fd) }
  var result = Data(count: bytes)
  let count = result.withUnsafeMutableBytes { buffer in
    pread(fd, buffer.baseAddress, buffer.count, off_t(offset))
  }
  guard count == bytes else { throw diskGrowthTestError() }
  return result
}

private func growthDiskStat(_ fixture: GrowthFixture) throws -> stat {
  var info = stat()
  guard lstat(fixture.disk.path, &info) == 0 else { throw diskGrowthTestError() }
  return info
}

private func assertGrowthContents(_ fixture: GrowthFixture, grown: Bool) throws {
  let prefix = try readGrowthRange(at: fixture.disk, offset: 0, bytes: 512)
  let oldTail = try readGrowthRange(at: fixture.disk, offset: growthOldBytes - 512, bytes: 512)
  #expect(prefix == growthPrefix && oldTail == growthOldTail)
  let info = try growthDiskStat(fixture)
  #expect(UInt64(info.st_size) == (grown ? growthTargetBytes : growthOldBytes))
  if grown {
    let newTail = try readGrowthRange(at: fixture.disk, offset: growthOldBytes, bytes: 2048)
    #expect(newTail == Data(repeating: 0, count: 2048))
  }
}

private func beginGrowth(_ fixture: GrowthFixture, files: VMFiles, lock: VMLock) async throws
  -> DiskGrowthPermit
{
  try await files.beginDiskGrowth(
    in: fixture.directory, vmID: fixture.vmID, diskFile: "disk.raw",
    oldBytes: growthOldBytes, targetBytes: growthTargetBytes,
    originalConfiguration: fixture.original, replacementConfiguration: fixture.replacement,
    lock: lock)
}

private func leavePendingGrowth(_ fixture: GrowthFixture) async throws -> DiskGrowthIntent {
  let files = VMFiles()
  let lock = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
  let permit = try await beginGrowth(fixture, files: files, lock: lock)
  let record = try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
  withExtendedLifetime((lock, permit)) {}
  return record
}

private final class WeakGrowthOwner {
  weak var value: VMLock?
  init(_ owner: VMLock?) { value = owner }
}

private func diskGrowthTestError() -> VMError {
  VMError(.storage, "Fresh growth fixture failed.", recovery: "Preserve its test evidence.")
}

private func cancelGrowthCommit(files: VMFiles, permit: DiskGrowthPermit?) async throws -> Bool {
  guard let permit else { throw diskGrowthTestError() }
  let attempt = Task { () -> Bool in
    withUnsafeCurrentTask { $0?.cancel() }
    do {
      _ = try await files.commitDiskGrowth(permit)
      return false
    } catch is CancellationError { return true } catch { return false }
  }
  return await attempt.value
}

private func completeGrowthAndRelease(_ fixture: GrowthFixture) async throws -> DiskGrowthIntent {
  let files = VMFiles()
  do {
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let permit = try await beginGrowth(fixture, files: files, lock: owner)
    _ = try await files.commitDiskGrowth(permit)
    withExtendedLifetime((owner, permit)) {}
  }
  return try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
}

private func beginNextGrowth(_ fixture: GrowthFixture, files: VMFiles, lock: VMLock) async throws
  -> DiskGrowthPermit
{
  let target = growthTargetBytes + 512
  let replacement = Data(
    String(decoding: fixture.replacement, as: UTF8.self).replacingOccurrences(
      of: "\"diskBytes\":\(growthTargetBytes)", with: "\"diskBytes\":\(target)"
    ).utf8)
  return try await files.beginDiskGrowth(
    in: fixture.directory, vmID: fixture.vmID, diskFile: "disk.raw",
    oldBytes: growthTargetBytes, targetBytes: target,
    originalConfiguration: fixture.replacement, replacementConfiguration: replacement, lock: lock)
}

@Suite struct DiskGrowthTests {
  @Test func durableGrowPreservesPrefixAndZeroTailAndRetainsActualLease() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    var lock: VMLock? = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let witness = WeakGrowthOwner(lock)
    var permit: DiskGrowthPermit? = try await beginGrowth(
      fixture, files: files, lock: try #require(lock))
    let pending = try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
    #expect(pending.state == .pending && pending.vmID == fixture.vmID)
    let backup = try Data(contentsOf: fixture.directory.appendingPathComponent(pending.backupFile))
    let target = try Data(contentsOf: fixture.directory.appendingPathComponent(pending.targetFile))
    #expect(backup == fixture.original && target == fixture.replacement)
    lock = nil
    #expect(witness.value != nil)
    #expect(await files.writerStatus(in: fixture.directory) == .held)
    let completion = try await files.commitDiskGrowth(try #require(permit))
    #expect(
      completion.transactionID == pending.transactionID
        && completion.backupFile == pending.backupFile)
    #expect(completion.oldBytes == growthOldBytes && completion.targetBytes == growthTargetBytes)
    try assertGrowthContents(fixture, grown: true)
    let current = try Data(contentsOf: fixture.configuration)
    #expect(current == fixture.replacement)
    #expect(try await files.readDiskGrowthIntent(in: fixture.directory)?.state == .completed)
    await #expect(throws: VMError.self) { try await files.commitDiskGrowth(try #require(permit)) }
    permit = nil
    #expect(witness.value == nil)
    let next = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    withExtendedLifetime(next) {}
  }

  @Test(arguments: [DiskGrowthFaultPoint.afterBackup, .afterSidecarsFlush])
  func beforePendingFailurePreservesArtifactsButCannotMutateDisk(_ point: DiskGrowthFaultPoint)
    async throws
  {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    await files.injectDiskGrowthFault(point)
    var owner: VMLock? = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    await #expect(throws: VMError.self) {
      _ = try await beginGrowth(fixture, files: files, lock: try #require(owner))
    }
    #expect(try await files.readDiskGrowthIntent(in: fixture.directory) == nil)
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    #expect(names.contains { $0.hasPrefix("disk-growth-") && $0.hasSuffix("-original.json") })
    let current = try Data(contentsOf: fixture.configuration)
    #expect(current == fixture.original)
    try assertGrowthContents(fixture, grown: false)
    await #expect(throws: VMError.self) {
      _ = try await beginGrowth(fixture, files: VMFiles(), lock: try #require(owner))
    }
    await #expect(throws: VMError.self) {
      _ = try await files.beginRuntimeSession(
        in: fixture.directory, forVMID: fixture.vmID, lock: try #require(owner))
    }
    owner = nil
    let next = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    withExtendedLifetime(next) {}
  }

  @Test func durablePendingBlocksAllNormalAdmissionAndRequiresExplicitRecovery() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    await files.injectDiskGrowthFault(.afterPending)
    var owner: VMLock? = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    await #expect(throws: VMError.self) {
      _ = try await beginGrowth(fixture, files: files, lock: try #require(owner))
    }
    owner = nil
    #expect(await files.writerStatus(in: fixture.directory) == .available)
    #expect(throws: VMError.self) { _ = try VMLock(directory: fixture.directory) }
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    }
    let record = try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
    let recovery = VMFiles()
    let permit = try await recovery.openDiskGrowthRecovery(
      in: fixture.directory, vmID: fixture.vmID, expectedTransactionID: record.transactionID)
    _ = try await recovery.commitDiskGrowth(permit)
    #expect(try await recovery.readDiskGrowthIntent(in: fixture.directory)?.state == .completed)
    try assertGrowthContents(fixture, grown: true)
    withExtendedLifetime(permit) {}
  }

  @Test(arguments: [
    DiskGrowthFaultPoint.afterGrow, .afterDiskFlush, .afterConfigurationRename,
    .afterConfigurationFlush, .afterCompletedRename, .afterCompletedFlush,
  ])
  func irreversibleBoundaryFailuresFreezeAttemptAndRecoveryNeverRetruncatesTarget(
    _ point: DiskGrowthFaultPoint
  ) async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    var lock: VMLock? = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    var permit: DiskGrowthPermit? = try await beginGrowth(
      fixture, files: files, lock: try #require(lock))
    lock = nil
    await files.injectDiskGrowthFault(point)
    await #expect(throws: VMError.self) {
      _ = try await files.commitDiskGrowth(try #require(permit))
    }
    await #expect(throws: VMError.self) {
      _ = try await VMFiles().commitDiskGrowth(try #require(permit))
    }
    #expect(await files.writerStatus(in: fixture.directory) == .held)
    try assertGrowthContents(fixture, grown: true)
    let record = try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
    let completedVisible = point == .afterCompletedRename || point == .afterCompletedFlush
    #expect(record.state == (completedVisible ? .completed : .pending))
    permit = nil
    if completedVisible {
      // Post-rename/flush failure is reported honestly; visible completed state may
      // pass critical binding even though the caller observed an uncertain error.
      let next = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
      withExtendedLifetime(next) {}
    } else {
      #expect(throws: VMError.self) {
        _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
      }
      let before = try growthDiskStat(fixture)
      let recovery = VMFiles()
      let restored = try await recovery.openDiskGrowthRecovery(
        in: fixture.directory, vmID: fixture.vmID, expectedTransactionID: record.transactionID)
      _ = try await recovery.commitDiskGrowth(restored)
      let after = try growthDiskStat(fixture)
      #expect(before.st_ino == after.st_ino && before.st_size == after.st_size)
      #expect(
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
          && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
      #expect(
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
          && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec)
      let current = try Data(contentsOf: fixture.configuration)
      #expect(current == fixture.replacement)
      withExtendedLifetime(restored) {}
    }
  }

  @Test func recoveryLeaseCannotLaunchOrDuplicateAndRuntimeLatchStillWins() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let record = try await leavePendingGrowth(fixture)
    do {
      let owner = try VMLock.diskGrowthRecovery(
        in: fixture.directory, vmID: fixture.vmID, transactionID: record.transactionID)
      #expect(throws: VMError.self) { _ = try owner.duplicateForInheritance() }
      await #expect(throws: VMError.self) {
        _ = try await VMFiles().beginRuntimeSession(
          in: fixture.directory, forVMID: fixture.vmID, lock: owner)
      }
      withExtendedLifetime(owner) {}
    }
    let runtime = Data(
      ("{\"schemaVersion\":1,\"vmID\":\"\(fixture.vmID.uuidString)\",\"sessionID\":\"\(UUID().uuidString)\",\"state\":\"unsettled\"}")
        .utf8)
    try await VMFiles().atomicWrite(
      runtime, at: fixture.directory.appendingPathComponent(RuntimeIntent.filename))
    await #expect(throws: VMError.self) {
      _ = try await VMFiles().openDiskGrowthRecovery(
        in: fixture.directory, vmID: fixture.vmID, expectedTransactionID: record.transactionID)
    }
    let preserved = try Data(
      contentsOf: fixture.directory.appendingPathComponent(RuntimeIntent.filename))
    #expect(preserved == runtime)
    try assertGrowthContents(fixture, grown: false)
  }

  @Test func runtimeAndGrowthShareOneShotReservationAcrossActors() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let growth = Task { () -> Bool in
      do {
        _ = try await beginGrowth(fixture, files: VMFiles(), lock: owner)
        return true
      } catch { return false }
    }
    let runtime = Task { () -> Bool in
      do {
        _ = try await VMFiles().beginRuntimeSession(
          in: fixture.directory, forVMID: fixture.vmID, lock: owner)
        return true
      } catch { return false }
    }
    let results = [await growth.value, await runtime.value]
    #expect(results.filter { $0 }.count == 1)
    try assertGrowthContents(fixture, grown: false)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [
    "transaction", "vm", "inode", "size", "configuration", "backup-symlink", "backup-hardlink",
  ])
  func recoveryRejectsUnexpectedIdentityLengthConfigurationAndSidecarAliases(_ kind: String)
    async throws
  {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let record = try await leavePendingGrowth(fixture)
    var vmID = fixture.vmID
    var transactionID = record.transactionID
    switch kind {
    case "transaction": transactionID = UUID()
    case "vm": vmID = UUID()
    case "inode":
      try FileManager.default.moveItem(
        at: fixture.disk, to: fixture.directory.appendingPathComponent("preserved.raw"))
      try await VMFiles().createSparseDisk(at: fixture.disk, bytes: growthOldBytes)
    case "size":
      let fd = open(fixture.disk.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw diskGrowthTestError() }
      #expect(ftruncate(fd, off_t(growthOldBytes + 512)) == 0)
      close(fd)
    case "configuration":
      let altered = Data(
        String(decoding: fixture.original, as: UTF8.self).replacingOccurrences(
          of: "original growth fixture", with: "changed fixture"
        ).utf8)
      try await VMFiles().atomicWrite(altered, at: fixture.configuration)
    default:
      let backup = fixture.directory.appendingPathComponent(record.backupFile)
      let other = fixture.directory.appendingPathComponent("preserved-config.json")
      if kind == "backup-symlink" {
        try FileManager.default.moveItem(at: backup, to: other)
        #expect(symlink(other.path, backup.path) == 0)
      } else {
        #expect(link(backup.path, other.path) == 0)
      }
    }
    let before = try Data(contentsOf: fixture.configuration)
    await #expect(throws: VMError.self) {
      _ = try await VMFiles().openDiskGrowthRecovery(
        in: fixture.directory, vmID: vmID, expectedTransactionID: transactionID)
    }
    let after = try Data(contentsOf: fixture.configuration)
    #expect(after == before)
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    }
  }

  @Test func strictFlatGrowthIntentRejectsDuplicatesUnknownAndUnsafeBindings() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let record = try await leavePendingGrowth(fixture)
    let url = fixture.directory.appendingPathComponent(DiskGrowthIntent.filename)
    let original = try Data(contentsOf: url)
    let text = String(decoding: original, as: UTF8.self)
    let schema = "\"schemaVersion\":\(record.schemaVersion)"
    let cases = [
      text.replacingOccurrences(of: schema, with: "\(schema),\(schema)"),
      text.replacingOccurrences(
        of: schema, with: "\(schema),\"\\u0073chemaVersion\":\(record.schemaVersion)"),
      text.replacingOccurrences(of: schema, with: "\"schemaVersion\":true"),
      text.replacingOccurrences(of: schema, with: "\"schemaVersion\":[1]"),
      text.replacingOccurrences(of: "}", with: ",\"unknown\":1}"),
      text.replacingOccurrences(
        of: "\"diskFile\":\"disk.raw\"", with: "\"diskFile\":\"../disk.raw\""),
      text.replacingOccurrences(
        of: "\"diskFile\":\"disk.raw\"", with: "\"diskFile\":\"configuration.json\""),
      text.replacingOccurrences(
        of: "\"targetBytes\":\(growthTargetBytes)", with: "\"targetBytes\":18446744073709551616"),
      text.replacingOccurrences(
        of: "\"targetBytes\":\(growthTargetBytes)", with: "\"targetBytes\":\(growthOldBytes + 1)"),
      text + "trailing", String(repeating: " ", count: 4097),
      "\u{FEFF}" + text,
    ]
    for invalid in cases {
      let bytes = Data(invalid.utf8)
      try await VMFiles().atomicWrite(bytes, at: url)
      await #expect(throws: VMError.self) {
        _ = try await VMFiles().readDiskGrowthIntent(in: fixture.directory)
      }
      #expect(throws: VMError.self) {
        _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
      }
      let unchanged = try Data(contentsOf: url)
      #expect(unchanged == bytes)
    }
  }

  @Test func completedAdmissionAllowsOtherConfigurationChangesButRejectsCriticalMismatch()
    async throws
  {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    do {
      let files = VMFiles()
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
      let permit = try await beginGrowth(fixture, files: files, lock: owner)
      _ = try await files.commitDiskGrowth(permit)
      withExtendedLifetime((owner, permit)) {}
    }
    let renamed = Data(
      String(decoding: fixture.replacement, as: UTF8.self).replacingOccurrences(
        of: "original growth fixture", with: "renamed after growth"
      ).utf8)
    try await VMFiles().atomicWrite(renamed, at: fixture.configuration)
    try await VMFiles().verifyCompletedDiskGrowth(in: fixture.directory, expectedVMID: fixture.vmID)
    do {
      let admitted = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
      withExtendedLifetime(admitted) {}
    }
    let invalid = Data(
      String(decoding: renamed, as: UTF8.self).replacingOccurrences(
        of: "\"diskBytes\":\(growthTargetBytes)", with: "\"diskBytes\":\(growthOldBytes)"
      ).utf8)
    try await VMFiles().atomicWrite(invalid, at: fixture.configuration)
    await #expect(throws: VMError.self) {
      try await VMFiles().verifyCompletedDiskGrowth(
        in: fixture.directory, expectedVMID: fixture.vmID)
    }
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    }
  }

  @Test func nextGrowthArchivesCompletedEvidenceExclusively() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var firstID: UUID?
    do {
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
      let files = VMFiles()
      let permit = try await beginGrowth(fixture, files: files, lock: owner)
      firstID = permit.transactionID
      _ = try await files.commitDiskGrowth(permit)
      withExtendedLifetime((owner, permit)) {}
    }
    let completedBytes = try Data(
      contentsOf: fixture.directory.appendingPathComponent(DiskGrowthIntent.filename))
    let larger = growthTargetBytes + 512
    let replacement = Data(
      String(decoding: fixture.replacement, as: UTF8.self).replacingOccurrences(
        of: "\"diskBytes\":\(growthTargetBytes)", with: "\"diskBytes\":\(larger)"
      ).utf8)
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let files = VMFiles()
    let permit = try await files.beginDiskGrowth(
      in: fixture.directory, vmID: fixture.vmID, diskFile: "disk.raw", oldBytes: growthTargetBytes,
      targetBytes: larger, originalConfiguration: fixture.replacement,
      replacementConfiguration: replacement, lock: owner)
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(try #require(firstID).uuidString)-completed.json")
    let actual = try Data(contentsOf: archive)
    #expect(actual == completedBytes)
    #expect(permit.transactionID != firstID)
    _ = try await files.commitDiskGrowth(permit)
    #expect(try await files.readDiskGrowthIntent(in: fixture.directory)?.targetBytes == larger)
    withExtendedLifetime((owner, permit)) {}
  }

  @Test func archivedCompletedJournalSurvivesFailedPreparationAndFreshExplicitGrowth() async throws
  {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let first = try await completeGrowthAndRelease(fixture)
    let journal = fixture.directory.appendingPathComponent(DiskGrowthIntent.filename)
    let completedBytes = try Data(contentsOf: journal)
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(first.transactionID.uuidString)-completed.json")
    let interrupted = VMFiles()
    await interrupted.injectDiskGrowthFault(.afterCompletedArchive)
    var failedOwner: VMLock? = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let witness = WeakGrowthOwner(failedOwner)
    await #expect(throws: VMError.self) {
      _ = try await beginNextGrowth(fixture, files: interrupted, lock: try #require(failedOwner))
    }
    let unchangedJournal = try Data(contentsOf: journal)
    let unchangedConfiguration = try Data(contentsOf: fixture.configuration)
    let preservedArchive = try Data(contentsOf: archive)
    #expect(unchangedJournal == completedBytes && unchangedConfiguration == fixture.replacement)
    #expect(preservedArchive == completedBytes)
    try assertGrowthContents(fixture, grown: true)
    var before = stat()
    #expect(lstat(archive.path, &before) == 0)
    #expect(before.st_mode & 0o7777 == 0o600 && before.st_nlink == 1)
    await #expect(throws: VMError.self) {
      _ = try await beginNextGrowth(fixture, files: VMFiles(), lock: try #require(failedOwner))
    }
    failedOwner = nil
    #expect(witness.value == nil)
    let freshOwner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let fresh = VMFiles()
    let permit = try await beginNextGrowth(fixture, files: fresh, lock: freshOwner)
    #expect(permit.transactionID != first.transactionID)
    _ = try await fresh.commitDiskGrowth(permit)
    var after = stat()
    #expect(lstat(archive.path, &after) == 0)
    #expect(DiskGrowthIO.stable(before, after))
    let retained = try Data(contentsOf: archive)
    #expect(retained == completedBytes)
    let current = try #require(try await fresh.readDiskGrowthIntent(in: fixture.directory))
    #expect(current.state == .completed && current.transactionID == permit.transactionID)
    #expect(current.targetBytes == growthTargetBytes + 512)
    let prefix = try readGrowthRange(at: fixture.disk, offset: 0, bytes: 512)
    let oldTail = try readGrowthRange(at: fixture.disk, offset: growthOldBytes - 512, bytes: 512)
    let tail = try readGrowthRange(at: fixture.disk, offset: growthOldBytes, bytes: 2560)
    #expect(
      prefix == growthPrefix && oldTail == growthOldTail && tail == Data(repeating: 0, count: 2560))
    withExtendedLifetime((freshOwner, permit)) {}
  }

  @Test(arguments: ["conflict", "symlink", "hardlink", "mode", "directory", "fifo"])
  func conflictingOrUnsafeCompletedArchiveCannotChangeDiskConfigurationOrJournal(_ kind: String)
    async throws
  {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let first = try await completeGrowthAndRelease(fixture)
    let journal = fixture.directory.appendingPathComponent(DiskGrowthIntent.filename)
    let completedBytes = try Data(contentsOf: journal)
    let archive = fixture.directory.appendingPathComponent(
      "disk-growth-\(first.transactionID.uuidString)-completed.json")
    let other = fixture.directory.appendingPathComponent("preserved-archive.json")
    var expectedArchiveBytes = completedBytes
    switch kind {
    case "conflict":
      // Keep all metadata and byte count valid so the exact-content check is essential.
      expectedArchiveBytes[expectedArchiveBytes.startIndex + 5] ^= 1
      try await VMFiles().atomicWrite(expectedArchiveBytes, at: archive)
    case "symlink":
      try await VMFiles().atomicWrite(completedBytes, at: other)
      #expect(symlink(other.path, archive.path) == 0)
    case "hardlink":
      try await VMFiles().atomicWrite(completedBytes, at: archive)
      #expect(link(archive.path, other.path) == 0)
    case "mode":
      try await VMFiles().atomicWrite(completedBytes, at: archive)
      #expect(chmod(archive.path, 0o640) == 0)
    case "directory":
      try FileManager.default.createDirectory(
        at: archive, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    default: #expect(mkfifo(archive.path, 0o600) == 0)
    }
    var before = stat()
    #expect(lstat(archive.path, &before) == 0)
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    await #expect(throws: VMError.self) {
      _ = try await beginNextGrowth(fixture, files: VMFiles(), lock: owner)
    }
    let actualJournal = try Data(contentsOf: journal)
    let actualConfiguration = try Data(contentsOf: fixture.configuration)
    #expect(actualJournal == completedBytes && actualConfiguration == fixture.replacement)
    try assertGrowthContents(fixture, grown: true)
    var after = stat()
    #expect(lstat(archive.path, &after) == 0)
    #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
    #expect(
      before.st_mode == after.st_mode && before.st_nlink == after.st_nlink
        && before.st_size == after.st_size)
    if ["conflict", "hardlink", "mode"].contains(kind) {
      let actualArchive = try Data(contentsOf: archive)
      #expect(actualArchive == expectedArchiveBytes)
    } else if kind == "symlink" {
      let preserved = try Data(contentsOf: other)
      #expect(preserved == completedBytes)
    }
    withExtendedLifetime(owner) {}
  }

  @Test func earlierInheritanceDeniesGrowthButPreservesRuntimeDuplication() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let first = try owner.duplicateForInheritance()
    let second = try owner.duplicateForInheritance()
    await #expect(throws: VMError.self) {
      _ = try await beginGrowth(fixture, files: VMFiles(), lock: owner)
    }
    #expect(try await VMFiles().readDiskGrowthIntent(in: fixture.directory) == nil)
    let current = try Data(contentsOf: fixture.configuration)
    #expect(current == fixture.original)
    try assertGrowthContents(fixture, grown: false)
    let runtime = try await VMFiles().beginRuntimeSession(
      in: fixture.directory, forVMID: fixture.vmID, lock: owner)
    let third = try owner.duplicateForInheritance()
    #expect(runtime.owns(owner))
    withExtendedLifetime((owner, first, second, third, runtime)) {}
  }

  @Test func freeSpaceReserveIncludesMetadataWithoutOverflowOrVirtualAllocationClaim() {
    let minimum = DiskGrowthIO.minimumFreeBytes
    let blocks = minimum / 4096 + (minimum % 4096 == 0 ? 0 : 1)
    #expect(!DiskGrowthIO.freeSpaceSufficient(availableBlocks: blocks - 1, blockBytes: 4096))
    #expect(DiskGrowthIO.freeSpaceSufficient(availableBlocks: blocks, blockBytes: 4096))
    #expect(!DiskGrowthIO.freeSpaceSufficient(availableBlocks: UInt64.max, blockBytes: 0))
    #expect(DiskGrowthIO.freeSpaceSufficient(availableBlocks: UInt64.max, blockBytes: UInt64.max))
    #expect(minimum > 1_073_741_824)
  }

  @Test func configurationBOMAndEscapedDiskBytesKeyPreserveExactOtherBytes() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let escapedKey = "\"\\u0064iskBytes\""
    let text = String(decoding: fixture.original, as: UTF8.self).replacingOccurrences(
      of: "\"diskBytes\"", with: escapedKey)
    let original = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    let replacement =
      Data([0xEF, 0xBB, 0xBF])
      + Data(
        text.replacingOccurrences(
          of: "\(escapedKey):\(growthOldBytes)", with: "\(escapedKey):\(growthTargetBytes)"
        ).utf8)
    let changed = GrowthFixture(
      directory: fixture.directory, vmID: fixture.vmID, original: original, replacement: replacement
    )
    let files = VMFiles()
    try await files.atomicWrite(original, at: fixture.configuration)
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    let permit = try await beginGrowth(changed, files: files, lock: owner)
    _ = try await files.commitDiskGrowth(permit)
    let actual = try Data(contentsOf: fixture.configuration)
    #expect(actual == replacement && actual.starts(with: [0xEF, 0xBB, 0xBF]))
    try assertGrowthContents(fixture, grown: true)
    withExtendedLifetime((owner, permit)) {}
  }

  @Test func cancelledCommitConsumesPermitAndRequiresNewRecovery() async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let files = VMFiles()
    var owner: VMLock? = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    var permit: DiskGrowthPermit? = try await beginGrowth(
      fixture, files: files, lock: try #require(owner))
    let record = try #require(try await files.readDiskGrowthIntent(in: fixture.directory))
    let wasCancelled = try await cancelGrowthCommit(files: files, permit: permit)
    #expect(wasCancelled)
    await #expect(throws: VMError.self) {
      _ = try await files.commitDiskGrowth(try #require(permit))
    }
    try assertGrowthContents(fixture, grown: false)
    let current = try Data(contentsOf: fixture.configuration)
    #expect(current == fixture.original)
    #expect(try await files.readDiskGrowthIntent(in: fixture.directory) == record)
    // Cancellation itself neither unlocks nor authorizes another writer.
    #expect(await files.writerStatus(in: fixture.directory) == .held)
    owner = nil
    permit = nil
    #expect(await files.writerStatus(in: fixture.directory) == .available)
    #expect(throws: VMError.self) {
      _ = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    }
    let recovery = VMFiles()
    let recovered = try await recovery.openDiskGrowthRecovery(
      in: fixture.directory, vmID: fixture.vmID, expectedTransactionID: record.transactionID)
    _ = try await recovery.commitDiskGrowth(recovered)
    try assertGrowthContents(fixture, grown: true)
    withExtendedLifetime(recovered) {}
  }

  @Test(arguments: [
    "disk-symlink", "disk-hardlink", "configuration-symlink", "configuration-hardlink", "disk-mode",
    "configuration-mode",
  ])
  func unsafeInitialFilesNeverReachPendingOrGrow(_ kind: String) async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let selected = kind.hasPrefix("disk-") ? fixture.disk : fixture.configuration
    let preserved = fixture.directory.appendingPathComponent(
      kind.hasPrefix("disk-") ? "preserved.raw" : "preserved.json")
    if kind.hasSuffix("symlink") {
      try FileManager.default.moveItem(at: selected, to: preserved)
      #expect(symlink(preserved.path, selected.path) == 0)
    } else if kind.hasSuffix("hardlink") {
      #expect(link(selected.path, preserved.path) == 0)
    } else {
      #expect(chmod(selected.path, 0o640) == 0)
    }
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    await #expect(throws: VMError.self) {
      _ = try await beginGrowth(fixture, files: VMFiles(), lock: owner)
    }
    #expect(try await VMFiles().readDiskGrowthIntent(in: fixture.directory) == nil)
    let diskPath = kind == "disk-symlink" ? preserved : fixture.disk
    let prefix = try readGrowthRange(at: diskPath, offset: 0, bytes: 512)
    #expect(prefix == growthPrefix)
    var info = stat()
    #expect(lstat(diskPath.path, &info) == 0 && UInt64(info.st_size) == growthOldBytes)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [
    "configuration.json", "writer.lock", "runtime-intent.json", "disk-growth-intent.json",
    "../disk.raw", ".metadata-reserved", "machine-identity.bin", "efi-variables.bin",
    "Machine-Identity.BIN", "configuration-media-backup-preserved.json",
  ])
  func reservedOrNonBasenameDiskArgumentsNeverMutate(_ name: String) async throws {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var original = fixture.original
    var replacement = fixture.replacement
    var observedDisk = fixture.disk
    if [
      "machine-identity.bin", "efi-variables.bin", "Machine-Identity.BIN",
      "configuration-media-backup-preserved.json",
    ].contains(name) {
      // Isolate the platform-name guard: both the manually authored configuration
      // and a real 1 GiB file otherwise match every growth requirement.
      original = Data(
        String(decoding: original, as: UTF8.self).replacingOccurrences(
          of: "\"diskFile\":\"disk.raw\"", with: "\"diskFile\":\"\(name)\""
        ).utf8)
      replacement = Data(
        String(decoding: replacement, as: UTF8.self).replacingOccurrences(
          of: "\"diskFile\":\"disk.raw\"", with: "\"diskFile\":\"\(name)\""
        ).utf8)
      observedDisk = fixture.directory.appendingPathComponent(name)
      try FileManager.default.moveItem(at: fixture.disk, to: observedDisk)
      try await VMFiles().atomicWrite(original, at: fixture.configuration)
    }
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    await #expect(throws: VMError.self) {
      _ = try await VMFiles().beginDiskGrowth(
        in: fixture.directory, vmID: fixture.vmID, diskFile: name,
        oldBytes: growthOldBytes, targetBytes: growthTargetBytes,
        originalConfiguration: original, replacementConfiguration: replacement,
        lock: owner)
    }
    let prefix = try readGrowthRange(at: observedDisk, offset: 0, bytes: 512)
    let oldTail = try readGrowthRange(at: observedDisk, offset: growthOldBytes - 512, bytes: 512)
    #expect(prefix == growthPrefix && oldTail == growthOldTail)
    var diskInfo = stat()
    #expect(lstat(observedDisk.path, &diskInfo) == 0 && UInt64(diskInfo.st_size) == growthOldBytes)
    let actualConfiguration = try Data(contentsOf: fixture.configuration)
    #expect(actualConfiguration == original)
    #expect(try await VMFiles().readDiskGrowthIntent(in: fixture.directory) == nil)
    withExtendedLifetime(owner) {}
  }
}
