// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMStorage

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return url
}

@Test func sparseDiskDoesNotOverwriteAndReportsAllocation() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let disk = directory.appendingPathComponent("disk.raw")
  try await files.createSparseDisk(at: disk, bytes: 1_073_741_824)
  let usage = try await files.inspectDisk(at: disk)
  #expect(usage.virtualBytes == 1_073_741_824)
  #expect(usage.allocatedBytes < usage.virtualBytes)
  await #expect(throws: VMError.self) {
    try await files.createSparseDisk(at: disk, bytes: 2_147_483_648)
  }
  #expect(try await files.inspectDisk(at: disk).virtualBytes == 1_073_741_824)
}

@Test func lifetimeWriterExclusion() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let owner = try VMLock(directory: directory)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  withExtendedLifetime(owner) {}
}

/// The bounded scan identifies only descriptors for this test's uniquely named lock inode.
private func writerDescriptors(in directory: URL) throws -> Set<Int32> {
  var expected = stat()
  guard lstat(directory.appendingPathComponent("writer.lock").path, &expected) == 0 else {
    throw VMError(
      .storage, "Cannot inspect the test writer lock.",
      recovery: "Preserve the private test fixture for inspection.")
  }
  return Set(
    (Int32(0)..<min(getdtablesize(), 4096)).filter { descriptor in
      var actual = stat()
      return fstat(descriptor, &actual) == 0 && actual.st_dev == expected.st_dev
        && actual.st_ino == expected.st_ino
    })
}

private final class WeakStorageOwner<Owner: AnyObject> {
  weak var value: Owner?
  init(_ value: Owner?) { self.value = value }
}

@Test func inheritedWriterLeasePreservesParentFlagsAndClosesItsCopy() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let owner = try VMLock(directory: directory)
  let before = try writerDescriptors(in: directory)
  #expect(before.count == 1)
  let parent = try #require(before.first)
  let parentFlags = fcntl(parent, F_GETFD)
  var inherited: VMLock.InheritedLease? = try owner.duplicateForInheritance()
  let weakCopy = WeakStorageOwner(inherited)
  let copy = try #require(inherited?.descriptor)
  #expect(copy >= 3 && copy != parent)
  #expect(fcntl(copy, F_GETFD) & FD_CLOEXEC != 0)
  #expect(fcntl(parent, F_GETFD) == parentFlags && parentFlags & FD_CLOEXEC != 0)
  #expect(try writerDescriptors(in: directory) == before.union([copy]))
  withExtendedLifetime(inherited) {}
  inherited = nil
  #expect(weakCopy.value == nil)
  #expect(try writerDescriptors(in: directory) == before)
  #expect(fcntl(parent, F_GETFD) == parentFlags)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  withExtendedLifetime(owner) {}
}

@Test func inheritedWriterLeaseRemainsUntilLastSharedCopyCloses() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  var owner: VMLock? = try VMLock(directory: directory)
  let weakOwner = WeakStorageOwner(owner)
  var first = try owner?.duplicateForInheritance()
  var second = try owner?.duplicateForInheritance()
  let weakFirst = WeakStorageOwner(first)
  let weakSecond = WeakStorageOwner(second)
  #expect(try writerDescriptors(in: directory).count == 3)
  withExtendedLifetime(owner) {}
  owner = nil
  #expect(weakOwner.value == nil)
  #expect(await files.writerStatus(in: directory) == .held)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  withExtendedLifetime(first) {}
  first = nil
  #expect(weakFirst.value == nil && weakSecond.value != nil)
  #expect(await files.writerStatus(in: directory) == .held)
  withExtendedLifetime(second) {}
  second = nil
  #expect(weakSecond.value == nil)
  #expect(try writerDescriptors(in: directory).isEmpty)
  #expect(await files.writerStatus(in: directory) == .available)
  let next = try VMLock(directory: directory)
  #expect(await files.writerStatus(in: directory) == .held)
  withExtendedLifetime(next) {}
}

@Test func unsafeInheritedLeaseDuplicationPreservesOriginalOwnership() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let owner = try VMLock(directory: directory)
  let before = try writerDescriptors(in: directory)
  let parent = try #require(before.first)
  let flags = fcntl(parent, F_GETFD)
  let alias = directory.appendingPathComponent("writer-alias.lock")
  #expect(link(directory.appendingPathComponent("writer.lock").path, alias.path) == 0)
  #expect(throws: VMError.self) { _ = try owner.duplicateForInheritance() }
  #expect(try writerDescriptors(in: directory) == before)
  #expect(fcntl(parent, F_GETFD) == flags)
  try FileManager.default.removeItem(at: alias)
  #expect(await VMFiles().writerStatus(in: directory) == .held)
  let restored = try owner.duplicateForInheritance()
  #expect(fcntl(restored.descriptor, F_GETFD) & FD_CLOEXEC != 0)
  withExtendedLifetime((owner, restored)) {}
}

@Test func atomicMetadataAndSymlinkRejection() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let url = directory.appendingPathComponent("configuration.json")
  try await files.atomicWrite(Data("old".utf8), at: url)
  try await files.atomicWrite(Data("new".utf8), at: url)
  #expect(try await files.readMetadata(at: url) == Data("new".utf8))
  let link = directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
  await #expect(throws: VMError.self) { try await files.readMetadata(at: link) }
  await #expect(throws: VMError.self) { try await files.inspectDisk(at: link) }
  await #expect(throws: VMError.self) { try await files.createSparseDisk(at: link, bytes: 1024) }
  #expect(try await files.readMetadata(at: url) == Data("new".utf8))
}

@Test func failedWriteRetainsPriorMetadata() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let url = directory.appendingPathComponent("configuration.json")
  try await files.atomicWrite(Data("last-good".utf8), at: url)
  await #expect(throws: VMError.self) {
    try await files.atomicWrite(Data(repeating: 0, count: 65_537), at: url)
  }
  #expect(try await files.readMetadata(at: url) == Data("last-good".utf8))
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
  await #expect(throws: VMError.self) {
    try await files.atomicWrite(Data("replacement".utf8), at: url)
  }
  #expect(try await files.readMetadata(at: url) == Data("last-good".utf8))
}

@Test func freeSpaceAndMetadataBounds() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  await #expect(throws: VMError.self) {
    try await files.checkFreeSpace(at: directory, reserveBytes: UInt64.max)
  }
  let url = directory.appendingPathComponent("huge.json")
  try Data(repeating: 1, count: 65_537).write(to: url)
  await #expect(throws: VMError.self) { try await files.readMetadata(at: url) }
}

@Test(.timeLimit(.minutes(1))) func specialFilesDoNotBlockOrBecomeWriterLocks() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let fifo = directory.appendingPathComponent("pipe")
  #expect(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
  await #expect(throws: VMError.self) { try await files.readMetadata(at: fifo) }
  await #expect(throws: VMError.self) { try await files.inspectDisk(at: fifo) }
  await #expect(throws: VMError.self) { try await files.inspectWritableFile(at: fifo) }
  await #expect(throws: VMError.self) { try await files.syncRegularFile(at: fifo) }
  let writer = directory.appendingPathComponent("writer.lock")
  #expect(mkfifo(writer.path, S_IRUSR | S_IWUSR) == 0)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  var info = stat()
  #expect(lstat(writer.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO)
  await #expect(throws: VMError.self) { try await files.readMetadata(at: fifo, limit: -1) }
}

@Test func writableAliasesAndUnsafePermissionsAreRejectedWithoutChanges() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let disk = directory.appendingPathComponent("disk.raw")
  try await files.createSparseDisk(at: disk, bytes: 4096)
  #expect(try await files.inspectWritableFile(at: disk).virtualBytes == 4096)
  let alias = directory.appendingPathComponent("alias.raw")
  #expect(link(disk.path, alias.path) == 0)
  let before = try Data(contentsOf: disk)
  await #expect(throws: VMError.self) { try await files.inspectWritableFile(at: disk) }
  await #expect(throws: VMError.self) { try await files.inspectWritableFile(at: alias) }
  #expect(try await files.inspectDisk(at: disk).virtualBytes == 4096)
  #expect(try Data(contentsOf: disk) == before)
  #expect(try Data(contentsOf: alias) == before)
  let firmware = directory.appendingPathComponent("efi-variables.bin")
  try Data("firmware".utf8).write(to: firmware)
  #expect(chmod(firmware.path, 0o660) == 0)
  await #expect(throws: VMError.self) { try await files.inspectWritableFile(at: firmware) }
  #expect(try Data(contentsOf: firmware) == Data("firmware".utf8))
  var info = stat()
  #expect(lstat(firmware.path, &info) == 0 && info.st_mode & 0o777 == 0o660)
}

@Test func writerLockAliasesAndWritableDirectoryAreRejected() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let writer = directory.appendingPathComponent("writer.lock")
  #expect(chmod(directory.path, 0o770) == 0)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  #expect(!FileManager.default.fileExists(atPath: writer.path))
  #expect(chmod(directory.path, 0o700) == 0)
  do {
    let owner = try VMLock(directory: directory)
    withExtendedLifetime(owner) {}
  }
  let alias = directory.appendingPathComponent("other.lock")
  #expect(link(writer.path, alias.path) == 0)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  var info = stat()
  #expect(lstat(writer.path, &info) == 0 && info.st_nlink == 2)
  let directoryLink = directory.appendingPathComponent("directory-link")
  try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directoryLink) }
}

@Test func immutableMetadataArchivesRejectReplacementAndAliases() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = VMFiles()
  let original = directory.appendingPathComponent("archive.json")
  let bytes = Data("preserved immutable record".utf8)
  try await files.writeNewMetadata(bytes, at: original)
  await #expect(throws: VMError.self) {
    try await files.writeNewMetadata(Data("overwrite".utf8), at: original)
  }
  let alias = directory.appendingPathComponent("alias.json")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
  await #expect(throws: VMError.self) {
    try await files.writeNewMetadata(Data("overwrite".utf8), at: alias)
  }
  #expect(try await files.readMetadata(at: original) == bytes)
  #expect((await files.status(at: alias)).kind == .symlink)
  let new = directory.appendingPathComponent("too-large.json")
  await #expect(throws: VMError.self) {
    try await files.writeNewMetadata(Data(repeating: 0, count: 65_537), at: new)
  }
  #expect((await files.status(at: new)).kind == .missing)
}

@Test func remoteAndNonFileWriterDirectoriesCreateNothing() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let remote = try #require(URL(string: "file://remote.invalid\(directory.path)"))
  let nonfile = try #require(URL(string: "https://example.invalid\(directory.path)"))
  for url in [remote, nonfile] {
    #expect(throws: VMError.self) { _ = try VMLock(directory: url) }
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}
