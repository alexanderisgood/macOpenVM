// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// A conservative point-in-time filesystem sample, not a space reservation or
/// permission/ACL assessment. Purgeable storage is not added to available bytes.
enum DestinationStorageCapacity {
  static func availableBytes(at directory: URL) throws -> UInt64 {
    guard normalizedLocalDirectory(directory) else { throw failure(.invalidConfiguration) }
    // macOS system aliases may occur in ancestors. The selected leaf itself
    // must be an actual directory; this read never authorizes a later write.
    let fd = open(
      directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw failure(.storage) }
    defer { close(fd) }
    let before = try identity(fd, named: directory)
    var filesystem = statfs()
    guard fstatfs(fd, &filesystem) == 0 else { throw failure(.storage) }
    let after = try identity(fd, named: directory)
    guard sameDirectory(before, after) else { throw failure(.staleOperation) }
    // Holding the FD pins the sampled filesystem, but public path checks cannot
    // exclude a same-UID replacement in the final check-to-return interval.
    return try byteCount(blocks: filesystem.f_bavail, blockSize: filesystem.f_bsize)
  }

  static func byteCount(blocks: UInt64, blockSize: UInt32) throws -> UInt64 {
    guard blockSize > 0 else { throw failure(.storage) }
    let (bytes, overflow) = blocks.multipliedReportingOverflow(by: UInt64(blockSize))
    guard !overflow else { throw failure(.storage) }
    return bytes
  }

  private static func normalizedLocalDirectory(_ url: URL) -> Bool {
    let path = url.path
    guard
      let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .percentEncodedPath.removingPercentEncoding,
      decoded == path || (url.hasDirectoryPath && decoded == path + "/")
    else { return false }
    return url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && path.hasPrefix("/") && path.utf8.count <= 4096
      && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && (path == "/"
        || path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
          .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
  }

  private static func identity(_ fd: Int32, named directory: URL) throws -> stat {
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0, lstat(directory.path, &named) == 0,
      sameDirectory(opened, named)
    else { throw failure(.staleOperation) }
    return opened
  }

  private static func sameDirectory(_ first: stat, _ second: stat) -> Bool {
    first.st_mode & S_IFMT == S_IFDIR && second.st_mode & S_IFMT == S_IFDIR
      && first.st_dev == second.st_dev && first.st_ino == second.st_ino
      && first.st_mode == second.st_mode && first.st_uid == second.st_uid
      && first.st_gid == second.st_gid
  }

  private static func failure(_ code: VMError.Code) -> VMError {
    VMError(
      code, "Available destination storage could not be confirmed.",
      recovery: "Choose an existing local directory and refresh its storage information.")
  }
}
