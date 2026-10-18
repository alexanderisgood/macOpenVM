// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation

enum RegisteredQemuIO {
  static func ancestry(_ url: URL, homebrew: Bool = false) throws {
    guard QemuCreationLocalPath.isValid(url, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    var path = ""
    for component in url.path.split(separator: "/") {
      path += "/" + component
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == 0 || info.st_uid == geteuid()
      else { throw registeredQemuFailure() }
      let reviewedCellar =
        homebrew && path == "/opt/homebrew/Cellar" && info.st_uid == geteuid()
        && info.st_gid == 80 && info.st_mode & 0o7777 == 0o775
      guard info.st_mode & 0o022 == 0 || path == "/private/tmp" || reviewedCellar else {
        throw registeredQemuFailure()
      }
    }
  }
  static func directory(_ url: URL) throws -> stat {
    try ancestry(url)
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else { throw registeredQemuFailure() }
    return info
  }
  static func reviewed(_ url: URL, count: UInt64, sha256: String) throws -> Data {
    guard registeredDigestShape(sha256), count > 0, count <= 134_217_728 else {
      throw registeredQemuFailure()
    }
    let bytes = try read(
      url, maximum: Int(count), mode: nil, homebrew: url.path.hasPrefix("/opt/homebrew/Cellar/"))
    guard UInt64(bytes.count) == count,
      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256
    else { throw registeredQemuFailure() }
    return bytes
  }
  static func read(_ url: URL, maximum: Int, mode: mode_t?, homebrew: Bool = false) throws -> Data {
    guard QemuCreationLocalPath.isValid(url, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    try ancestry(url.deletingLastPathComponent(), homebrew: homebrew)
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw registeredQemuFailure() }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, fileSafe(before, mode: mode),
      before.st_size >= 0, before.st_size <= maximum
    else { throw registeredQemuFailure() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var bytes = Data()
    while let chunk = try handle.read(upToCount: min(1_048_576, maximum - bytes.count + 1)),
      !chunk.isEmpty
    {
      bytes.append(chunk)
      guard bytes.count <= maximum else { throw registeredQemuFailure() }
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
      stable(before, after), stable(after, named), bytes.count == after.st_size
    else { throw registeredQemuFailure() }
    return bytes
  }
  static func readOnlyImage(_ url: URL) throws {
    guard QemuCreationLocalPath.isValid(url, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    try ancestry(url.deletingLastPathComponent())
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw registeredQemuFailure() }
    defer { close(fd) }
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
      opened.st_size > 0, UInt64(opened.st_size) <= 16 * 1_073_741_824,
      opened.st_uid == geteuid() || opened.st_uid == 0, opened.st_mode & 0o022 == 0,
      lstat(url.path, &named) == 0, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
      opened.st_size == named.st_size, opened.st_mode == named.st_mode
    else { throw registeredQemuFailure() }
  }
  static func writable(_ url: URL, bytes: UInt64? = nil, maximum: UInt64) throws {
    guard QemuCreationLocalPath.isValid(url, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    var info = stat()
    guard lstat(url.path, &info) == 0, fileSafe(info, mode: 0o600), info.st_uid == geteuid(),
      info.st_size >= 0,
      UInt64(info.st_size) <= maximum, bytes == nil || UInt64(info.st_size) == bytes
    else { throw registeredQemuFailure() }
  }
  static func platformState(in directory: URL, diskFile: String, diskBytes: UInt64) throws {
    _ = try self.directory(directory)
    try writable(directory.appendingPathComponent(diskFile), bytes: diskBytes, maximum: diskBytes)
    try writable(
      directory.appendingPathComponent(QemuPlatformIdentityCodec.variablesFilename),
      maximum: 1_048_576)
    let tpm = directory.appendingPathComponent(QemuPlatformIdentityCodec.tpmDirectory)
    _ = try self.directory(tpm)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: tpm.path))
    guard names.isEmpty || names == [".lock", "tpm2-00.permall"] else {
      throw registeredQemuFailure()
    }
    for name in names { try writable(tpm.appendingPathComponent(name), maximum: 16_777_216) }
  }
  private static func fileSafe(_ info: stat, mode: mode_t?) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
      && (info.st_uid == geteuid() || info.st_uid == 0)
      && info.st_mode & 0o022 == 0 && (mode == nil || info.st_mode & 0o7777 == mode)
  }
  private static func stable(_ a: stat, _ b: stat) -> Bool {
    fileSafe(b, mode: nil) && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
      && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink
      && a.st_size == b.st_size
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
      && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
}
