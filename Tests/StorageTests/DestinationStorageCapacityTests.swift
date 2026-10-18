// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private func capacityFixture() throws -> URL {
  let directory = URL(fileURLWithPath: "/private/tmp/macOpenVM-capacity-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return directory
}

@Suite struct DestinationStorageCapacityTests {
  @Test func nativeSampleUsesSelectedDirectoryAndPreservesItsMetadata() async throws {
    let directory = try capacityFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    #expect(fd >= 0)
    defer { if fd >= 0 { close(fd) } }
    var before = stat()
    #expect(fstat(fd, &before) == 0)
    let sample = try await VMFiles().availableStorageCapacity(at: directory)
    var filesystem = statfs()
    #expect(fstatfs(fd, &filesystem) == 0)
    let direct = try DestinationStorageCapacity.byteCount(
      blocks: filesystem.f_bavail, blockSize: filesystem.f_bsize)
    // Other processes can change available blocks between these real samples.
    #expect(sample > 0 && direct > 0)
    var after = stat()
    #expect(fstat(fd, &after) == 0)
    #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
    #expect(before.st_mode == after.st_mode && before.st_uid == after.st_uid)
    #expect(before.st_size == after.st_size && before.st_nlink == after.st_nlink)
    #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
    #expect(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
    #expect(before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec)
    #expect(before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func byteArithmeticUsesAvailableBlocksAndRefusesOverflow() throws {
    #expect(try DestinationStorageCapacity.byteCount(blocks: 0, blockSize: 4096) == 0)
    #expect(try DestinationStorageCapacity.byteCount(blocks: 3, blockSize: 4096) == 12_288)
    #expect(
      try DestinationStorageCapacity.byteCount(blocks: UInt64.max, blockSize: 1) == UInt64.max)
    #expect(throws: VMError.self) {
      _ = try DestinationStorageCapacity.byteCount(blocks: 1, blockSize: 0)
    }
    #expect(throws: VMError.self) {
      _ = try DestinationStorageCapacity.byteCount(blocks: UInt64.max, blockSize: 2)
    }
    let blocks = UInt64.max / UInt64(UInt32.max)
    #expect(
      try DestinationStorageCapacity.byteCount(blocks: blocks, blockSize: UInt32.max)
        == blocks * UInt64(UInt32.max))
    #expect(throws: VMError.self) {
      _ = try DestinationStorageCapacity.byteCount(blocks: blocks + 1, blockSize: UInt32.max)
    }
  }

  @Test func readProbeDoesNotImposeVMDirectoryPermissionPolicy() async throws {
    let directory = try capacityFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(chmod(directory.path, 0o755) == 0)
    let sample = try await VMFiles().availableStorageCapacity(at: directory)
    #expect(sample > 0)
    var info = stat()
    #expect(lstat(directory.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o755)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func directoryURLTrailingSlashIsAcceptedWithoutChangingTheDirectory() async throws {
    let directory = try capacityFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let markedDirectory = URL(fileURLWithPath: directory.path, isDirectory: true)
    let slashURL = try #require(URL(string: "file://" + directory.path + "/"))
    for selected in [markedDirectory, slashURL] {
      #expect(selected.hasDirectoryPath)
      #expect(try await VMFiles().availableStorageCapacity(at: selected) > 0)
      try await VMFiles().checkFreeSpace(at: selected, reserveBytes: 0)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test(arguments: ["missing", "symlink", "file"])
  func nonDirectoryLeafIsRefusedWithoutCreatingEntries(_ kind: String) async throws {
    let directory = try capacityFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent(kind)
    if kind == "symlink" {
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: directory)
    } else if kind == "file" {
      try Data("public fixture".utf8).write(to: target)
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    await #expect(throws: VMError.self) {
      _ = try await VMFiles().availableStorageCapacity(at: target)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == names)
    if kind == "file" { #expect(try Data(contentsOf: target) == Data("public fixture".utf8)) }
  }

  @Test(arguments: [
    "https://example.invalid/", "file://remote.invalid/private/tmp", "file:///private/tmp?query=1",
    "file:///private/tmp#fragment", "file:///private/../tmp", "file:///private//tmp",
    "file:///private/tmp/%00invalid",
  ])
  func invalidURLIsRefusedWithBoundedError(_ text: String) async throws {
    let url = try #require(URL(string: text))
    do {
      _ = try await VMFiles().availableStorageCapacity(at: url)
      Issue.record("An invalid destination URL was admitted.")
    } catch let error as VMError {
      #expect(error.code == .invalidConfiguration)
      #expect(error.message == "Available destination storage could not be confirmed.")
      #expect(!error.localizedDescription.contains(text))
    }
    await #expect(throws: VMError.self) {
      try await VMFiles().checkFreeSpace(at: url, reserveBytes: 0)
    }
  }

  @Test func ancestorAliasSamplesActualDirectoryWithoutChangingTheAlias() async throws {
    let directory = try capacityFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let actual = directory.appendingPathComponent("actual")
    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createDirectory(
      at: actual, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
    let child = actual.appendingPathComponent("child")
    try FileManager.default.createDirectory(
      at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let throughAlias = alias.appendingPathComponent("child")
    #expect(try await VMFiles().availableStorageCapacity(at: throughAlias) > 0)
    try await VMFiles().checkFreeSpace(at: throughAlias, reserveBytes: 0)
    await #expect(throws: VMError.self) {
      _ = try await VMFiles().availableStorageCapacity(at: alias)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == actual.path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
  }

  @Test func commonReserveCheckUsesProbeWithoutChangingDestination() async throws {
    let directory = try capacityFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await VMFiles().checkFreeSpace(at: directory, reserveBytes: 0)
    await #expect(throws: VMError.self) {
      try await VMFiles().checkFreeSpace(at: directory, reserveBytes: UInt64.max)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }
}
