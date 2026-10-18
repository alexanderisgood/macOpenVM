// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private let supportDiskBytes: UInt64 = 1_073_741_824
private let supportTargetBytes = supportDiskBytes + 2048
private let supportSeed = Data((0..<512).map { UInt8(($0 * 13 + 5) & 255) })

private struct SupportFixture {
  let directory: URL
  let configuration: VMConfiguration
  let original: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
  var image: URL { directory.appendingPathComponent("support carrier.raw") }
  var disk: URL { directory.appendingPathComponent("disk.raw") }
}

private func supportFixture() async throws -> SupportFixture {
  let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("macOpenVM-support-storage-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let files = VMFiles()
  let image = directory.appendingPathComponent("support carrier.raw")
  try await files.writeNewMetadata(supportSeed, at: image)
  guard chmod(image.path, 0o400) == 0 else { throw supportTestError() }
  var configuration = VMConfiguration(
    name: "original support fixture", guest: .linux, backend: .appleVz,
    memoryBytes: 2 * supportDiskBytes, diskBytes: supportDiskBytes)
  configuration.boot = .linuxKernel
  configuration.kernel = "/synthetic/kernel"
  configuration.initialRamdisk = "/synthetic/initramfs"
  configuration.installationMedia = "/synthetic/install.iso"
  configuration.supportMedia = image.path
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let text = String(decoding: try encoder.encode(configuration), as: UTF8.self)
    .replacingOccurrences(of: "\"supportMedia\"", with: "\"\\u0073upportMedia\"")
  let original = Data([0xef, 0xbb, 0xbf]) + Data(text.utf8) + Data("\n \n".utf8)
  try await files.writeNewMetadata(
    original, at: directory.appendingPathComponent("configuration.json"))
  try await files.createSparseDisk(
    at: directory.appendingPathComponent("disk.raw"), bytes: supportDiskBytes)
  let fd = open(directory.appendingPathComponent("disk.raw").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw supportTestError() }
  defer { close(fd) }
  guard
    supportSeed.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == supportSeed.count,
    fsync(fd) == 0
  else { throw supportTestError() }
  return .init(directory: directory, configuration: configuration, original: original)
}

private struct SupportFileState: Equatable {
  let device: Int32
  let inode: UInt64
  let mode: mode_t
  let links: UInt16
  let size: Int64
  let blocks: Int64
  let modifiedSeconds: Int64
  let modifiedNanos: Int64
  let changedSeconds: Int64
  let changedNanos: Int64
  let bytes: Data
}

private func supportFileState(_ url: URL, count: Int = 512) throws -> SupportFileState {
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard fd >= 0 else { throw supportTestError() }
  defer { close(fd) }
  var info = stat()
  guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= count else {
    throw supportTestError()
  }
  var data = Data(count: count)
  guard data.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, $0.count, 0) }) == count else {
    throw supportTestError()
  }
  return .init(
    device: info.st_dev, inode: info.st_ino, mode: info.st_mode, links: info.st_nlink,
    size: info.st_size, blocks: info.st_blocks,
    modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
    modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
    changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec),
    bytes: data)
}

private func supportTestError() -> VMError {
  .init(.storage, "Fresh support-media fixture failed.", recovery: "Preserve its test evidence.")
}

private func supportBootReplacement(_ fixture: SupportFixture) throws -> Data {
  var bytes = fixture.original
  let old = try JSONEncoder().encode(fixture.configuration.kernelArguments)
  let range = try #require(bytes.range(of: old))
  bytes.replaceSubrange(range, with: try JSONEncoder().encode("console=hvc0 root=synthetic ro"))
  return bytes
}

private func supportGrowthReplacement(_ original: Data) -> Data {
  Data(
    String(decoding: original, as: UTF8.self).replacingOccurrences(
      of: "\"diskBytes\":\(supportDiskBytes)", with: "\"diskBytes\":\(supportTargetBytes)"
    ).utf8)
}

private func completeSupportGrowth(_ fixture: SupportFixture, original: Data) async throws {
  let files = VMFiles()
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let permit = try await files.beginDiskGrowth(
    in: fixture.directory, vmID: fixture.configuration.id, diskFile: "disk.raw",
    oldBytes: supportDiskBytes, targetBytes: supportTargetBytes,
    originalConfiguration: original, replacementConfiguration: supportGrowthReplacement(original),
    lock: owner)
  _ = try await files.commitDiskGrowth(permit)
  withExtendedLifetime((owner, permit)) {}
}

@Test func readOnlySupportImageInspectionPreservesSharedAliasesAndLegacyInspection() async throws {
  let fixture = try await supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let alias = fixture.directory.appendingPathComponent("shared-alias.raw")
  #expect(link(fixture.image.path, alias.path) == 0)
  let before = try supportFileState(fixture.image)
  let files = VMFiles()
  for path in [fixture.image, alias] {
    let usage = try await files.inspectReadOnlyImage(at: path)
    #expect(usage.virtualBytes == 512)
  }
  #expect(try supportFileState(fixture.image) == before)
  #expect(try supportFileState(alias) == before)
  let unaligned = fixture.directory.appendingPathComponent("legacy-unaligned.raw")
  try await files.writeNewMetadata(Data([1, 2, 3]), at: unaligned)
  #expect(try await files.inspectDisk(at: unaligned).virtualBytes == 3)
  await #expect(throws: VMError.self) { try await files.inspectReadOnlyImage(at: unaligned) }
}

@Test(arguments: ["empty", "unaligned", "missing", "directory", "symlink", "fifo", "oversized"])
func readOnlySupportImageRejectsUnsafeOrUnsupportedFiles(_ kind: String) async throws {
  let fixture = try await supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let invalid = fixture.directory.appendingPathComponent("invalid-image")
  let files = VMFiles()
  if kind == "empty" || kind == "unaligned" {
    try await files.writeNewMetadata(kind == "empty" ? Data() : Data([1]), at: invalid)
  } else if kind == "directory" {
    try FileManager.default.createDirectory(
      at: invalid, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  } else if kind == "symlink" {
    #expect(symlink(fixture.image.path, invalid.path) == 0)
  } else if kind == "fifo" {
    #expect(mkfifo(invalid.path, 0o600) == 0)
  } else if kind == "oversized" {
    // Fresh sparse metadata only; no data allocation or read of this logical range.
    try await files.createSparseDisk(at: invalid, bytes: 2_199_023_255_552 + 512)
  }
  let image = try supportFileState(fixture.image)
  let disk = try supportFileState(fixture.disk)
  await #expect(throws: VMError.self) { try await files.inspectReadOnlyImage(at: invalid) }
  #expect(try supportFileState(fixture.image) == image)
  #expect(try supportFileState(fixture.disk) == disk)
  #expect(try Data(contentsOf: fixture.registration) == fixture.original)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.directory.appendingPathComponent("writer.lock").path))
}

@Test func storageSupportMediaStrictDecodePreservesOptionalStringAndRejectsAliases() async throws {
  let fixture = try await supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  #expect(try DiskGrowthIO.decodeConfiguration(fixture.original) == fixture.configuration)
  var legacy = fixture.configuration
  legacy.supportMedia = nil
  #expect(try DiskGrowthIO.decodeConfiguration(JSONEncoder().encode(legacy)) == legacy)
  let text = String(decoding: fixture.original.dropFirst(3), as: UTF8.self)
  for extra in [#""supportMedia":"/duplicate","#, #""supportMedia":42,"#] {
    let duplicate = Data(("{" + extra + String(text.dropFirst())).utf8)
    #expect(throws: VMError.self) { try DiskGrowthIO.decodeConfiguration(duplicate) }
  }
  let originalToken = try JSONEncoder().encode(fixture.image.path)
  var absentValue = fixture.original
  absentValue.replaceSubrange(
    try #require(absentValue.range(of: originalToken)), with: Data("null".utf8))
  #expect(try DiskGrowthIO.decodeConfiguration(absentValue).supportMedia == nil)
  for token in [Data("42".utf8), Data("true".utf8), Data("[]".utf8), Data("{}".utf8)] {
    var wrongType = fixture.original
    wrongType.replaceSubrange(try #require(wrongType.range(of: originalToken)), with: token)
    #expect(throws: VMError.self) { try DiskGrowthIO.decodeConfiguration(wrongType) }
  }
  #expect(try Data(contentsOf: fixture.registration) == fixture.original)
}

@Test func storageSupportMediaSurvivesActualBootAndGrowthCommits() async throws {
  let fixture = try await supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let imageBefore = try supportFileState(fixture.image)
  let boot = try supportBootReplacement(fixture)
  let backup = try await {
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    let result = try await VMFiles().commitLinuxKernelArguments(
      in: fixture.directory, vmID: fixture.configuration.id, original: fixture.original,
      replacement: boot, backupID: UUID(), lock: owner)
    withExtendedLifetime(owner) {}
    return result
  }()
  #expect(try Data(contentsOf: fixture.registration) == boot)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(backup)) == fixture.original)
  try await completeSupportGrowth(fixture, original: boot)
  let target = supportGrowthReplacement(boot)
  #expect(try Data(contentsOf: fixture.registration) == target)
  #expect(try DiskGrowthIO.decodeConfiguration(target).supportMedia == fixture.image.path)
  #expect(try supportFileState(fixture.image) == imageBefore)
  let disk = try supportFileState(fixture.disk)
  #expect(disk.size == Int64(supportTargetBytes) && disk.bytes == supportSeed)
  try await VMFiles().verifyCompletedDiskGrowth(
    in: fixture.directory, expectedVMID: fixture.configuration.id)
}

@Test func completedGrowthTreatsSupportSelectionAsNoncriticalButKeepsDiskIdentity() async throws {
  let fixture = try await supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  try await completeSupportGrowth(fixture, original: fixture.original)
  let imageBefore = try supportFileState(fixture.image)
  let alternate = fixture.directory.appendingPathComponent("alternate-support.raw")
  try await VMFiles().writeNewMetadata(supportSeed, at: alternate)
  var configuration = try DiskGrowthIO.decodeConfiguration(Data(contentsOf: fixture.registration))
  configuration.supportMedia = alternate.path
  try await VMFiles().atomicWrite(JSONEncoder().encode(configuration), at: fixture.registration)
  let edited = try Data(contentsOf: fixture.registration)
  try await VMFiles().verifyCompletedDiskGrowth(
    in: fixture.directory, expectedVMID: fixture.configuration.id)
  #expect(try Data(contentsOf: fixture.registration) == edited)
  #expect(try supportFileState(fixture.image) == imageBefore)
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  withExtendedLifetime(owner) {}
  configuration.diskBytes += 512
  try await VMFiles().atomicWrite(JSONEncoder().encode(configuration), at: fixture.registration)
  let invalid = try Data(contentsOf: fixture.registration)
  let disk = try supportFileState(fixture.disk)
  await #expect(throws: VMError.self) {
    try await VMFiles().verifyCompletedDiskGrowth(
      in: fixture.directory, expectedVMID: fixture.configuration.id)
  }
  #expect(try Data(contentsOf: fixture.registration) == invalid)
  #expect(try supportFileState(fixture.disk) == disk)
}

@Test func pendingGrowthWithSupportMediaStillRejectsFreshWriterAdmission() async throws {
  let fixture = try await supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let before = try supportFileState(fixture.image)
  let files = VMFiles()
  try await {
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    await files.injectDiskGrowthFault(.afterPending)
    await #expect(throws: VMError.self) {
      try await files.beginDiskGrowth(
        in: fixture.directory, vmID: fixture.configuration.id, diskFile: "disk.raw",
        oldBytes: supportDiskBytes, targetBytes: supportTargetBytes,
        originalConfiguration: fixture.original,
        replacementConfiguration: supportGrowthReplacement(fixture.original), lock: owner)
    }
    withExtendedLifetime(owner) {}
  }()
  #expect(try await files.readDiskGrowthIntent(in: fixture.directory)?.state == .pending)
  #expect(await files.writerStatus(in: fixture.directory) == .available)
  #expect(throws: VMError.self) {
    try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  }
  #expect(try Data(contentsOf: fixture.registration) == fixture.original)
  #expect(try supportFileState(fixture.image) == before)
}
