// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// Pins an explicitly selected private parent through capture and exclusive save.
final class PrivateSnapshotOutput: @unchecked Sendable {
  private let parent: URL, name: String, descriptor: Int32
  private let device: dev_t, inode: ino_t
  init(at url: URL) throws {
    guard WindowsExternalFileIO.lexical(url), url.pathExtension == "ppm" else {
      throw Self.failure()
    }
    let parent = url.deletingLastPathComponent()
    try WindowsExternalFileIO.privateDirectory(parent)
    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw Self.failure() }
    var info = stat()
    var named = stat()
    guard fstat(fd, &info) == 0, lstat(parent.path, &named) == 0,
      info.st_dev == named.st_dev, info.st_ino == named.st_ino,
      info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else {
      close(fd)
      throw Self.failure()
    }
    do { try Self.requireNoACL(fd) } catch {
      close(fd)
      throw error
    }
    self.parent = parent
    name = url.lastPathComponent
    descriptor = fd
    device = info.st_dev
    inode = info.st_ino
  }
  deinit { close(descriptor) }
  func save(_ data: Data) throws {
    guard !data.isEmpty, data.count <= 50_331_712 else { throw Self.failure() }
    try verify()
    let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Self.failure() }
    defer { close(fd) }
    try Self.requireNoACL(fd)
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw Self.failure() }
        offset += count
      }
    }
    guard fsync(fd) == 0, fsync(descriptor) == 0 else { throw Self.failure() }
    try Self.requireNoACL(fd)
    try verify()
  }
  private func verify() throws {
    try WindowsExternalFileIO.privateDirectory(parent)
    var info = stat()
    var named = stat()
    guard fstat(descriptor, &info) == 0, lstat(parent.path, &named) == 0,
      info.st_dev == device, info.st_ino == inode, named.st_dev == device, named.st_ino == inode,
      info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else { throw Self.failure() }
    try Self.requireNoACL(descriptor)
  }
  /// A private POSIX mode alone does not exclude extended or inherited ACL grants.
  static func requireNoACL(_ descriptor: Int32) throws {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      // Darwin reports absent extended ACLs as ENOENT even for an existing fd.
      let absent = errno == ENOENT
      var info = stat()
      guard absent, fstat(descriptor, &info) == 0,
        [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT)
      else { throw failure() }
      return
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_valid(acl) == 0 else { throw failure() }
    var entry: acl_entry_t?
    errno = 0
    let status = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
    guard status == -1, errno == EINVAL else { throw failure() }
  }
  private static func failure() -> VMError {
    VMError(
      .storage, "The private snapshot destination is unavailable or changed.",
      recovery: "Choose a new private output file. An existing file is never replaced.")
  }
}
