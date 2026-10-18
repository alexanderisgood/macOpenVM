// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import MacOpenVMCLI

private func snapshotFixture() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp/mvo-snapshot-output-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  return url
}

private func snapshotAddACL(at url: URL) throws {
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw snapshotFixtureFailure() }
  defer { close(fd) }
  var acl = acl_init(1)
  defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
  var entry: acl_entry_t?
  guard acl_create_entry(&acl, &entry) == 0, let acl, let entry,
    acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0
  else { throw snapshotFixtureFailure() }
  let qualifier = UUID().uuid
  let setQualifier = withUnsafeBytes(of: qualifier) { acl_set_qualifier(entry, $0.baseAddress) }
  var permissions: acl_permset_t?
  guard setQualifier == 0, acl_get_permset(entry, &permissions) == 0, let permissions,
    acl_clear_perms(permissions) == 0, acl_add_perm(permissions, ACL_READ_DATA) == 0,
    acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0
  else { throw snapshotFixtureFailure() }
}

private func snapshotFixtureFailure() -> VMError {
  VMError(
    .storage, "The synthetic snapshot ACL fixture failed.", recovery: "Inspect its private files.")
}

struct PrivateSnapshotOutputTests {
  @Test func parentACLRefusesAdmissionAndChangesDuringCapture() throws {
    let parent = try snapshotFixture()
    defer { try? FileManager.default.removeItem(at: parent) }
    let target = parent.appendingPathComponent("frame.ppm")
    let output = try PrivateSnapshotOutput(at: target)
    try snapshotAddACL(at: parent)
    var info = stat()
    #expect(lstat(parent.path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
    #expect(throws: VMError.self) { try PrivateSnapshotOutput(at: target) }
    #expect(throws: VMError.self) { try output.save(Data("snapshot".utf8)) }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw snapshotFixtureFailure() }
    defer { close(fd) }
    #expect(throws: VMError.self) { try PrivateSnapshotOutput.requireNoACL(fd) }
  }

  @Test func outputDescriptorACLRefusesBeforeAnyBytes() throws {
    let parent = try snapshotFixture()
    defer { try? FileManager.default.removeItem(at: parent) }
    let target = parent.appendingPathComponent("empty.ppm")
    let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw snapshotFixtureFailure() }
    defer { close(fd) }
    try snapshotAddACL(at: target)
    var info = stat()
    #expect(fstat(fd, &info) == 0 && info.st_size == 0 && info.st_mode & 0o7777 == 0o600)
    #expect(throws: VMError.self) { try PrivateSnapshotOutput.requireNoACL(fd) }
    #expect(fstat(fd, &info) == 0 && info.st_size == 0)
  }

  @Test func savesExactBytesPrivatelyAndNeverReplacesAnExistingFile() throws {
    let parent = try snapshotFixture()
    defer { try? FileManager.default.removeItem(at: parent) }
    let target = parent.appendingPathComponent("frame.ppm")
    let output = try PrivateSnapshotOutput(at: target)
    let bytes = Data("P6\n1 1\n255\nABC".utf8)
    try output.save(bytes)
    #expect(try Data(contentsOf: target) == bytes)
    var info = stat()
    #expect(lstat(target.path, &info) == 0 && info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1)
    #expect(throws: VMError.self) { try output.save(Data("replacement".utf8)) }
    #expect(try Data(contentsOf: target) == bytes)
  }

  @Test func parentReplacementDuringCaptureCannotRedirectTheWrite() throws {
    let fixture = try snapshotFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let parent = fixture.appendingPathComponent("chosen")
    let retained = fixture.appendingPathComponent("retained")
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let output = try PrivateSnapshotOutput(at: parent.appendingPathComponent("frame.ppm"))
    try FileManager.default.moveItem(at: parent, to: retained)
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    #expect(throws: VMError.self) { try output.save(Data("snapshot".utf8)) }
    #expect(
      !FileManager.default.fileExists(atPath: parent.appendingPathComponent("frame.ppm").path))
    #expect(
      !FileManager.default.fileExists(atPath: retained.appendingPathComponent("frame.ppm").path))
  }

  @Test func symlinkParentAndEmptyDataRefuseWithoutCreatingAFile() throws {
    let fixture = try snapshotFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let alias = fixture.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture)
    #expect(throws: VMError.self) {
      try PrivateSnapshotOutput(at: alias.appendingPathComponent("frame.ppm"))
    }
    let target = fixture.appendingPathComponent("empty.ppm")
    let output = try PrivateSnapshotOutput(at: target)
    #expect(throws: VMError.self) { try output.save(Data()) }
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }
}
