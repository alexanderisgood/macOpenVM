// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private func privateIdentityFixture() throws -> (root: URL, child: URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let child = root.appendingPathComponent("platform-state")
  try FileManager.default.createDirectory(
    at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return (root, child)
}

private func identityDirectoryStat(_ path: URL) throws -> stat {
  var value = stat()
  guard lstat(path.path, &value) == 0 else {
    throw VMError(.storage, "Fixture stat failed", recovery: "inspect")
  }
  return value
}

@Test func privateEmptyIdentityDirectoryFlushUsesActualWriter() async throws {
  let fixture = try privateIdentityFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let writer = try VMLock(directory: fixture.root)
  let before = try identityDirectoryStat(fixture.child)
  try await VMFiles().syncPrivateEmptyDirectory(
    in: fixture.root, relativeName: "platform-state", lock: writer)
  let after = try identityDirectoryStat(fixture.child)
  #expect(after.st_ino == before.st_ino && after.st_dev == before.st_dev)
  #expect(after.st_mode & 0o7777 == 0o700)
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.child.path).isEmpty)
  #expect(throws: VMError.self) { _ = try VMLock(directory: fixture.root) }
  withExtendedLifetime(writer) {}
}

@Test func privateIdentityDirectoryRejectsWrongWriterWithoutCreatingAClaim() async throws {
  let first = try privateIdentityFixture()
  let second = try privateIdentityFixture()
  defer {
    try? FileManager.default.removeItem(at: first.root)
    try? FileManager.default.removeItem(at: second.root)
  }
  let writer = try VMLock(directory: first.root)
  let before = try identityDirectoryStat(second.child)
  await #expect(throws: VMError.self) {
    try await VMFiles().syncPrivateEmptyDirectory(
      in: second.root, relativeName: "platform-state", lock: writer)
  }
  #expect(try identityDirectoryStat(second.child).st_ino == before.st_ino)
  #expect(
    !FileManager.default.fileExists(atPath: second.root.appendingPathComponent("writer.lock").path))
  withExtendedLifetime(writer) {}
}

enum UnsafePrivateIdentityDirectory: CaseIterable, Sendable {
  case symlink, regularFile, fifo, readableByOthers, writableByOthers, nonempty, danglingEntry
}

@Test(arguments: UnsafePrivateIdentityDirectory.allCases)
func unsafePrivateIdentityDirectoryRefusesWithoutRepair(_ kind: UnsafePrivateIdentityDirectory)
  async throws
{
  let fixture = try privateIdentityFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let writer = try VMLock(directory: fixture.root)
  switch kind {
  case .symlink:
    let other = fixture.root.appendingPathComponent("original-state")
    try FileManager.default.moveItem(at: fixture.child, to: other)
    try FileManager.default.createSymbolicLink(at: fixture.child, withDestinationURL: other)
  case .regularFile:
    try FileManager.default.removeItem(at: fixture.child)
    try Data("preserve".utf8).write(to: fixture.child)
  case .fifo:
    try FileManager.default.removeItem(at: fixture.child)
    #expect(mkfifo(fixture.child.path, 0o600) == 0)
  case .readableByOthers: #expect(chmod(fixture.child.path, 0o755) == 0)
  case .writableByOthers: #expect(chmod(fixture.child.path, 0o770) == 0)
  case .nonempty:
    try Data("preserve".utf8).write(to: fixture.child.appendingPathComponent("existing"))
  case .danglingEntry:
    try FileManager.default.createSymbolicLink(
      at: fixture.child.appendingPathComponent("existing"),
      withDestinationURL: fixture.root.appendingPathComponent("absent"))
  }
  let before = try identityDirectoryStat(fixture.child)
  await #expect(throws: VMError.self) {
    try await VMFiles().syncPrivateEmptyDirectory(
      in: fixture.root, relativeName: "platform-state", lock: writer)
  }
  let after = try identityDirectoryStat(fixture.child)
  #expect(before.st_ino == after.st_ino && before.st_mode == after.st_mode)
  withExtendedLifetime(writer) {}
}

@Test(arguments: ["../platform-state", "platform-state/child", ".", "", "platform\nstate"])
func privateIdentityDirectoryRejectsNonDirectNames(_ name: String) async throws {
  let fixture = try privateIdentityFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let writer = try VMLock(directory: fixture.root)
  await #expect(throws: VMError.self) {
    try await VMFiles().syncPrivateEmptyDirectory(
      in: fixture.root, relativeName: name, lock: writer)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.child.path).isEmpty)
  withExtendedLifetime(writer) {}
}

@Test(arguments: [1, 2])
func identityDirectoryFlushFailurePreservesBothInodes(_ failingCall: Int) throws {
  let fixture = try privateIdentityFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let writer = try VMLock(directory: fixture.root)
  let child = try identityDirectoryStat(fixture.child)
  let parent = try identityDirectoryStat(fixture.root)
  var calls = 0
  #expect(throws: VMError.self) {
    try writer.withRuntimeIntentDirectory { anchor in
      try PlatformIdentityDirectoryIO.flush("platform-state", at: anchor) { descriptor in
        calls += 1
        var actual = stat()
        #expect(fstat(descriptor, &actual) == 0)
        #expect(actual.st_ino == (calls == 1 ? child.st_ino : parent.st_ino))
        if calls == failingCall {
          throw VMError(.storage, "Injected directory flush failure", recovery: "inspect")
        }
        #expect(fsync(descriptor) == 0)
      }
    }
  }
  #expect(calls == failingCall)
  #expect(try identityDirectoryStat(fixture.child).st_ino == child.st_ino)
  #expect(try identityDirectoryStat(fixture.root).st_ino == parent.st_ino)
  withExtendedLifetime(writer) {}
}

@Test func identityDirectoryReplacementAfterChildFlushRefusesParentFlush() throws {
  let fixture = try privateIdentityFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let writer = try VMLock(directory: fixture.root)
  let retained = fixture.root.appendingPathComponent("retained-state")
  let before = try identityDirectoryStat(fixture.child)
  var calls = 0
  #expect(throws: VMError.self) {
    try writer.withRuntimeIntentDirectory { anchor in
      try PlatformIdentityDirectoryIO.flush("platform-state", at: anchor) { descriptor in
        calls += 1
        #expect(fsync(descriptor) == 0)
        try FileManager.default.moveItem(at: fixture.child, to: retained)
        try FileManager.default.createDirectory(
          at: fixture.child, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
    }
  }
  #expect(calls == 1)
  #expect(try identityDirectoryStat(retained).st_ino == before.st_ino)
  #expect(try identityDirectoryStat(fixture.child).st_ino != before.st_ino)
  withExtendedLifetime(writer) {}
}
