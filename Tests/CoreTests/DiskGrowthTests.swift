// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMStorage

@testable import VMCore

private let growthGiB: UInt64 = 1_073_741_824
private let growthHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
private let growthPrefix = Data("preserve the original disk prefix\n".utf8)
private let growthTail = Data("preserve bytes at the original disk end\n".utf8)
private let growthPrivateFailure = "untrusted-storage-detail-that-must-not-be-published"

private struct GrowthFixture {
  let root: URL
  let directory: URL
  let configuration: VMConfiguration
  let original: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
  var disk: URL { directory.appendingPathComponent(configuration.diskFile) }
}

private func makeGrowthFixture(windows: Bool = false) async throws -> GrowthFixture {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("macOpenVM-growth-\(UUID().uuidString)")
  let directory = root.appendingPathComponent("fixture.macopenvm")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  let configuration = VMConfiguration(
    name: "original fixture", guest: windows ? .windows11 : .linux,
    backend: windows ? .qemuHVF : .appleVz,
    memoryBytes: windows ? 4 * growthGiB : 2 * growthGiB,
    diskBytes: windows ? 64 * growthGiB : growthGiB)
  var original = try ConfigurationCodec.encode(configuration)
  original.append(Data("\n \n".utf8))
  let files = VMFiles()
  try await files.atomicWrite(original, at: directory.appendingPathComponent("configuration.json"))
  let disk = directory.appendingPathComponent(configuration.diskFile)
  try await files.createSparseDisk(at: disk, bytes: configuration.diskBytes)
  let fd = open(disk.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  defer { close(fd) }
  #expect(
    growthPrefix.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == growthPrefix.count)
  #expect(
    growthTail.withUnsafeBytes {
      pwrite(fd, $0.baseAddress, $0.count, off_t(configuration.diskBytes) - off_t($0.count))
    } == growthTail.count)
  #expect(fsync(fd) == 0)
  let initialOwner = try VMLock(directory: directory, expectedVMID: configuration.id)
  withExtendedLifetime(initialOwner) {}
  return .init(root: root, directory: directory, configuration: configuration, original: original)
}

private func diskBytes(_ path: URL, at offset: UInt64, count: Int) throws -> Data {
  let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  defer { close(fd) }
  var bytes = Data(count: count)
  let read = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
  guard read == count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  return bytes
}

private struct GrowthStamp: Equatable {
  let inode: UInt64
  let device: Int32
  let size: Int64
  let mode: mode_t
  let links: UInt16
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
  let metadata: Data?
}

private func growthInventory(_ directory: URL) throws -> [String: GrowthStamp] {
  var result: [String: GrowthStamp] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let path = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(path.path, &info) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    result[name] = .init(
      inode: info.st_ino, device: info.st_dev, size: info.st_size, mode: info.st_mode,
      links: info.st_nlink, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changedSeconds: Int64(info.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(info.st_ctimespec.tv_nsec),
      metadata: info.st_mode & S_IFMT == S_IFREG && info.st_size <= 131_072
        ? try Data(contentsOf: path) : nil)
  }
  return result
}

private actor GrowthBoundaryStore: DiskGrowthStore {
  enum Fault: Equatable, Sendable {
    case beforeCommit, afterCommit, changedIdentityAfterFirstRead, changedSettingsAfterFirstRead
  }
  private let files = VMFiles()
  private let fault: Fault
  private var reads = 0
  init(_ fault: Fault) { self.fault = fault }

  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    reads += 1
    if (fault == .changedIdentityAfterFirstRead || fault == .changedSettingsAfterFirstRead)
      && reads == 2
    {
      let old = try ConfigurationCodec.decode(await files.readMetadata(at: url, limit: limit))
      var replacement = old
      if fault == .changedIdentityAfterFirstRead {
        replacement.id = UUID()
      } else {
        replacement.name = "Changed after observation"
      }
      try await files.atomicWrite(ConfigurationCodec.encode(replacement), at: url)
    }
    return try await files.readMetadata(at: url, limit: limit)
  }
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableConfiguration(at: url)
  }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func readDiskGrowthIntent(in directory: URL) async throws -> DiskGrowthIntent? {
    try await files.readDiskGrowthIntent(in: directory)
  }
  func beginDiskGrowth(
    in directory: URL, vmID: UUID, diskFile: String, oldBytes: UInt64,
    targetBytes: UInt64, originalConfiguration: Data,
    replacementConfiguration: Data, lock: VMLock
  ) async throws -> DiskGrowthPermit {
    try await files.beginDiskGrowth(
      in: directory, vmID: vmID, diskFile: diskFile, oldBytes: oldBytes,
      targetBytes: targetBytes, originalConfiguration: originalConfiguration,
      replacementConfiguration: replacementConfiguration, lock: lock)
  }
  func openDiskGrowthRecovery(in directory: URL, vmID: UUID, expectedTransactionID: UUID)
    async throws -> DiskGrowthPermit
  {
    try await files.openDiskGrowthRecovery(
      in: directory, vmID: vmID, expectedTransactionID: expectedTransactionID)
  }
  func commitDiskGrowth(_ permit: DiskGrowthPermit) async throws -> DiskGrowthCompletion {
    if fault == .beforeCommit {
      throw NSError(
        domain: growthPrivateFailure, code: 1,
        userInfo: [NSLocalizedDescriptionKey: growthPrivateFailure])
    }
    let result = try await files.commitDiskGrowth(permit)
    if fault == .afterCommit {
      throw NSError(
        domain: growthPrivateFailure, code: 2,
        userInfo: [NSLocalizedDescriptionKey: growthPrivateFailure])
    }
    return result
  }
}

@Test func diskGrowthSurgicalDocumentPreservesEscapesWhitespaceAndOtherNumericText() throws {
  let original = Data(
    #"""
     {
      "schemaVersion":1,"id":"72814d7e-ef35-4f4b-8780-1b3b9594f5c9",
      "name":"a \"diskBytes\": 1073741824 text","guest":"linux","architecture":"arm64",
      "backend":"appleVz","cpuCount":2,"memoryBytes":2147483648,
      "\u0064iskBytes"  : 1073741824 ,"diskFile":"disk.raw","boot":"efi",
      "kernelArguments":"escaped \\ value and 1073741824","network":"disconnected",
      "macAddress":"02:01:02:03:04:05"
     }

    """#.utf8)
  let expected = Data(
    String(decoding: original, as: UTF8.self)
      .replacingOccurrences(
        of: #""\u0064iskBytes"  : 1073741824"#,
        with: #""\u0064iskBytes"  : 2147483648"#
      ).utf8)
  #expect(expected != original)
  for bytes in [original, Data([0xef, 0xbb, 0xbf]) + original] {
    let result = try StrictConfigurationDocument(bytes).replacingDiskBytes(with: 2 * growthGiB)
    let desired =
      bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data([0xef, 0xbb, 0xbf]) + expected : expected
    #expect(result.bytes == desired)
    #expect(result.configuration.diskBytes == 2 * growthGiB)
  }
}

@Test func diskGrowthChangesOnlyCapacityAndPreservesActualDiskData() async throws {
  let fixture = try await makeGrowthFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try growthInventory(fixture.directory)
  let result = try await DiskGrowth().grow(
    in: fixture.directory, toBytes: 2 * growthGiB, expected: fixture.configuration, host: growthHost
  )
  #expect(result.changed && !result.recovered)
  var expected = fixture.configuration
  expected.diskBytes = 2 * growthGiB
  #expect(result.configuration == expected)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(result.backupFile))
      == fixture.original)
  #expect(
    try Data(contentsOf: fixture.registration)
      == StrictConfigurationDocument(fixture.original).replacingDiskBytes(with: 2 * growthGiB).bytes
  )
  let after = try growthInventory(fixture.directory)
  let oldDisk = try #require(before["disk.raw"])
  let newDisk = try #require(after["disk.raw"])
  #expect(oldDisk.inode == newDisk.inode && oldDisk.device == newDisk.device)
  #expect(
    newDisk.size == Int64(2 * growthGiB) && newDisk.mode & 0o7777 == 0o600 && newDisk.links == 1)
  #expect(try diskBytes(fixture.disk, at: 0, count: growthPrefix.count) == growthPrefix)
  #expect(
    try diskBytes(fixture.disk, at: growthGiB - UInt64(growthTail.count), count: growthTail.count)
      == growthTail)
  #expect(try diskBytes(fixture.disk, at: growthGiB, count: 512) == Data(repeating: 0, count: 512))
  #expect(
    try diskBytes(fixture.disk, at: 2 * growthGiB - 512, count: 512)
      == Data(repeating: 0, count: 512))
  let intent = try #require(await VMFiles().readDiskGrowthIntent(in: fixture.directory))
  #expect(
    intent.state == .completed && intent.vmID == fixture.configuration.id
      && intent.transactionID == result.transactionID)
}

@Test func diskGrowthWindowsConfigurationUsesSharedStorageWithoutLaunchingBackend() async throws {
  let fixture = try await makeGrowthFixture(windows: true)
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let result = try await DiskGrowth().grow(
    in: fixture.directory, toBytes: 65 * growthGiB, host: growthHost)
  #expect(result.configuration.guest == .windows11 && result.configuration.backend == .qemuHVF)
  #expect(result.configuration.diskBytes == 65 * growthGiB)
  #expect(try diskBytes(fixture.disk, at: 0, count: growthPrefix.count) == growthPrefix)
}

@Test func diskGrowthRejectsShrinkEqualUnalignedAndExcessiveTargetsWithoutMutation() async throws {
  let fixture = try await makeGrowthFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try growthInventory(fixture.directory)
  for target in [
    UInt64(0), growthGiB - 512, growthGiB, growthGiB + 1, 2 * UInt64(1_099_511_627_776) + 512,
  ] {
    await #expect(throws: VMError.self) {
      try await DiskGrowth().grow(in: fixture.directory, toBytes: target, host: growthHost)
    }
    #expect(try growthInventory(fixture.directory) == before)
  }
}

@Test func diskGrowthRejectsUnknownAndEscapedDuplicateFieldsBeforeJournal() async throws {
  for kind in ["unknown", "duplicate"] {
    let fixture = try await makeGrowthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var text = String(decoding: fixture.original, as: UTF8.self)
    let field = kind == "unknown" ? #""futureFormat":"qcow2","# : #""\u0064iskBytes":1073741824,"#
    text.insert(contentsOf: field, at: text.index(after: text.firstIndex(of: "{")!))
    try await VMFiles().atomicWrite(Data(text.utf8), at: fixture.registration)
    let before = try growthInventory(fixture.directory)
    await #expect(throws: VMError.self) {
      try await DiskGrowth().grow(in: fixture.directory, toBytes: 2 * growthGiB, host: growthHost)
    }
    #expect(try growthInventory(fixture.directory) == before)
  }
}

@Test func diskGrowthRereadsIdentityBeforeAnyTransactionAndRejectsUnsettledRuntime() async throws {
  let fixture = try await makeGrowthFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let disk = try #require(try growthInventory(fixture.directory)["disk.raw"])
  await #expect(throws: VMError.self) {
    try await DiskGrowth(files: GrowthBoundaryStore(.changedIdentityAfterFirstRead))
      .grow(in: fixture.directory, toBytes: 2 * growthGiB, host: growthHost)
  }
  #expect(try growthInventory(fixture.directory)["disk.raw"] == disk)
  #expect(try await VMFiles().readDiskGrowthIntent(in: fixture.directory) == nil)
  try await VMFiles().atomicWrite(fixture.original, at: fixture.registration)
  do {
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    let permit = try await VMFiles().beginRuntimeSession(
      in: fixture.directory,
      forVMID: fixture.configuration.id, lock: owner)
    withExtendedLifetime((owner, permit)) {}
  }
  let before = try growthInventory(fixture.directory)
  await #expect(throws: VMError.self) {
    try await DiskGrowth().grow(in: fixture.directory, toBytes: 2 * growthGiB, host: growthHost)
  }
  #expect(try growthInventory(fixture.directory) == before)
}

@Test func diskGrowthBeforeCommitFailureRequiresExplicitFinishAndHidesForeignError() async throws {
  let fixture = try await makeGrowthFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  do {
    _ = try await DiskGrowth(files: GrowthBoundaryStore(.beforeCommit))
      .grow(in: fixture.directory, toBytes: 2 * growthGiB, host: growthHost)
    Issue.record("The injected boundary must fail")
  } catch let error as VMError {
    #expect(error.code == .storage && !error.localizedDescription.contains(growthPrivateFailure))
  }
  #expect(try Data(contentsOf: fixture.registration) == fixture.original)
  #expect(try await VMFiles().inspectDisk(at: fixture.disk).virtualBytes == growthGiB)
  let intent = try #require(await VMFiles().readDiskGrowthIntent(in: fixture.directory))
  #expect(intent.state == .pending)
  let before = try growthInventory(fixture.directory)
  await #expect(throws: VMError.self) {
    try await DiskGrowth().grow(in: fixture.directory, toBytes: 3 * growthGiB, host: growthHost)
  }
  #expect(try growthInventory(fixture.directory) == before)
  let finished = try await DiskGrowth().finish(in: fixture.directory, host: growthHost)
  #expect(
    finished.recovered && finished.transactionID == intent.transactionID
      && finished.targetBytes == 2 * growthGiB)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(finished.backupFile))
      == fixture.original)
  #expect(try diskBytes(fixture.disk, at: 0, count: growthPrefix.count) == growthPrefix)
}

@Test func diskGrowthLostCommitReplyNeverShrinksOrRollsBack() async throws {
  let fixture = try await makeGrowthFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  await #expect(throws: VMError.self) {
    try await DiskGrowth(files: GrowthBoundaryStore(.afterCommit))
      .grow(in: fixture.directory, toBytes: 2 * growthGiB, host: growthHost)
  }
  #expect(try await VMFiles().inspectDisk(at: fixture.disk).virtualBytes == 2 * growthGiB)
  #expect(
    try ConfigurationCodec.decode(await VMFiles().readMetadata(at: fixture.registration)).diskBytes
      == 2 * growthGiB)
  let intent = try #require(await VMFiles().readDiskGrowthIntent(in: fixture.directory))
  #expect(intent.state == .completed)
  let before = try growthInventory(fixture.directory)
  await #expect(throws: VMError.self) {
    try await DiskGrowth().finish(in: fixture.directory, host: growthHost)
  }
  #expect(try growthInventory(fixture.directory) == before)
  #expect(try diskBytes(fixture.disk, at: 0, count: growthPrefix.count) == growthPrefix)
}

@Test func diskGrowthEditorSnapshotRejectsEveryStaleConfigurationBeforeWriting() async throws {
  let fixture = try await makeGrowthFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try growthInventory(fixture.directory)
  for mutation in ["identity", "name", "memory", "disk", "network"] {
    var stale = fixture.configuration
    switch mutation {
    case "identity": stale.id = UUID()
    case "name": stale.name = "Another editor"
    case "memory": stale.memoryBytes += growthGiB
    case "disk": stale.diskBytes += growthGiB
    default: stale.network = .shared
    }
    await #expect(throws: VMError.self) {
      try await DiskGrowth().grow(
        in: fixture.directory, toBytes: 2 * growthGiB,
        expected: stale, host: growthHost)
    }
    #expect(try growthInventory(fixture.directory) == before)
  }
}

@Test func diskGrowthSameIdentityChangedSettingsAfterObservationCannotGrowTheDisk() async throws {
  let fixture = try await makeGrowthFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let disk = try #require(try growthInventory(fixture.directory)["disk.raw"])
  await #expect(throws: VMError.self) {
    try await DiskGrowth(files: GrowthBoundaryStore(.changedSettingsAfterFirstRead))
      .grow(
        in: fixture.directory, toBytes: 2 * growthGiB,
        expected: fixture.configuration, host: growthHost)
  }
  #expect(try growthInventory(fixture.directory)["disk.raw"] == disk)
  #expect(try await VMFiles().readDiskGrowthIntent(in: fixture.directory) == nil)
  let changed = try ConfigurationCodec.decode(Data(contentsOf: fixture.registration))
  #expect(changed.id == fixture.configuration.id && changed.name == "Changed after observation")
}
