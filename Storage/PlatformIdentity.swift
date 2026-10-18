// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

extension VMFiles {
  /// Flush one newly created private empty child under the actual VM writer.
  /// This establishes a filesystem prerequisite, never device or guest health.
  public func syncPrivateEmptyDirectory(
    in directory: URL, relativeName: String, lock: VMLock
  ) throws {
    try Task.checkCancellation()
    guard lock.owns(directory), ConfigurationValidator.isSafeComponent(relativeName),
      !relativeName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw platformDirectoryError() }
    try lock.withRuntimeIntentDirectory { anchor in
      try PlatformIdentityDirectoryIO.flush(relativeName, at: anchor)
    }
  }
}

/// The internal flush closure permits deterministic filesystem failure/race tests.
/// Public callers always use real fsync; the retained directory anchor is never reconstructed.
enum PlatformIdentityDirectoryIO {
  static func flush(_ name: String, at anchor: Int32) throws {
    try flush(name, at: anchor, synchronize: synchronizeDescriptor)
  }

  static func flush(
    _ name: String, at anchor: Int32,
    synchronize: (Int32) throws -> Void
  ) throws {
    guard ConfigurationValidator.isSafeComponent(name),
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw platformDirectoryError() }
    let descriptor = openat(
      anchor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw platformDirectoryError() }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, safe(before) else { throw platformDirectoryError() }
    try verify(descriptor, name: name, at: anchor, expected: before)
    try requireEmpty(descriptor)
    try verify(descriptor, name: name, at: anchor, expected: before)
    try synchronize(descriptor)
    try requireEmpty(descriptor)
    try verify(descriptor, name: name, at: anchor, expected: before)
    try synchronize(anchor)
    try requireEmpty(descriptor)
    try verify(descriptor, name: name, at: anchor, expected: before)
  }

  private static func synchronizeDescriptor(_ descriptor: Int32) throws {
    guard fsync(descriptor) == 0 else { throw platformDirectoryError() }
  }

  private static func requireEmpty(_ descriptor: Int32) throws {
    let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
    guard copy >= 0 else { throw platformDirectoryError() }
    guard let entries = fdopendir(copy) else {
      close(copy)
      throw platformDirectoryError()
    }
    defer { closedir(entries) }
    rewinddir(entries)
    while true {
      errno = 0
      guard let entry = readdir(entries) else {
        guard errno == 0 else { throw platformDirectoryError() }
        return
      }
      let capacity = Int(entry.pointee.d_namlen) + 1
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
          String(cString: $0)
        }
      }
      guard name == "." || name == ".." else { throw platformDirectoryError() }
    }
  }

  private static func verify(
    _ descriptor: Int32, name: String, at anchor: Int32, expected: stat
  ) throws {
    var opened = stat()
    var named = stat()
    guard fstat(descriptor, &opened) == 0,
      fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      stable(expected, opened), stable(opened, named)
    else { throw platformDirectoryError() }
  }

  private static func safe(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid()
      && info.st_mode & 0o7777 == 0o700
  }

  private static func stable(_ before: stat, _ after: stat) -> Bool {
    safe(after) && before.st_dev == after.st_dev && before.st_ino == after.st_ino
      && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
      && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
      && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
      && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
  }
}

private func platformDirectoryError() -> VMError {
  VMError(
    .storage, "The new private platform directory could not be safely flushed.",
    recovery: "Preserve the incomplete VM and its identity entries; inspect before retrying.")
}
