// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

enum BootConfigurationFault: Equatable, Sendable { case afterBackup, afterRename, afterCommit }

extension VMFiles {
  /// Readable nonempty local image selection only; no format, version or authentication claim.
  package func inspectLinuxBootImage(at url: URL, maximumBytes: Int64) throws {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
      !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      maximumBytes > 0, maximumBytes <= 512 * 1_048_576
    else { throw diskGrowthError(.invalidConfiguration) }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw diskGrowthError(.storage) }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0, before.st_size <= maximumBytes
    else { throw diskGrowthError(.invalidConfiguration) }
    var byte: UInt8 = 0
    var count: Int
    repeat { count = pread(fd, &byte, 1, 0) } while count < 0 && errno == EINTR
    var opened = stat()
    var named = stat()
    func unchanged(_ first: stat, _ second: stat) -> Bool {
      second.st_mode & S_IFMT == S_IFREG && first.st_dev == second.st_dev
        && first.st_ino == second.st_ino && first.st_uid == second.st_uid
        && first.st_gid == second.st_gid && first.st_mode == second.st_mode
        && first.st_nlink == second.st_nlink && first.st_size == second.st_size
        && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
        && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
        && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
        && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    guard count == 1, fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
      unchanged(before, opened), unchanged(opened, named)
    else { throw diskGrowthError(.storage) }
  }

  /// Exact one- or three-string transaction under the actual retained matching writer.
  /// No disk data, runtime permit, boot-image bytes or platform identity is changed.
  package func commitLinuxKernelArguments(
    in directory: URL, vmID: UUID, original: Data, replacement: Data,
    backupID: UUID, lock: VMLock
  ) throws -> String {
    try commitLinuxKernelArguments(
      in: directory, vmID: vmID, original: original, replacement: replacement,
      backupID: backupID, lock: lock, fault: nil)
  }

  func commitLinuxKernelArguments(
    in directory: URL, vmID: UUID, original: Data, replacement: Data,
    backupID: UUID, lock: VMLock, fault: BootConfigurationFault?
  ) throws -> String {
    guard lock.owns(directory) else { throw diskGrowthError(.busy) }
    try lock.reserveConfigurationChange(forVMID: vmID)
    try Task.checkCancellation()
    return try lock.withRuntimeIntentDirectory { anchor in
      try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: vmID)
      try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: vmID)
      let selectsImages = try DiskGrowthIO.validateKernelArgumentReplacement(
        original, replacement, vmID: vmID)
      if selectsImages {
        let selected = try DiskGrowthIO.decodeConfiguration(replacement)
        guard let kernel = selected.kernel, let initialRamdisk = selected.initialRamdisk else {
          throw diskGrowthError(.corruptMetadata)
        }
        try inspectLinuxBootImage(at: URL(fileURLWithPath: kernel), maximumBytes: 128 * 1_048_576)
        try inspectLinuxBootImage(
          at: URL(fileURLWithPath: initialRamdisk), maximumBytes: 512 * 1_048_576)
      }
      guard try DiskGrowthIO.configuration(at: anchor) == original else {
        throw diskGrowthError(.busy)
      }
      try DiskGrowthIO.requireFreeSpace(at: anchor)
      let backup = "configuration-boot-backup-\(backupID.uuidString).json"
      try DiskGrowthIO.exclusive(original, name: backup, at: anchor)
      guard fsync(anchor) == 0,
        try DiskGrowthIO.readFile(backup, at: anchor, limit: DiskGrowthIO.configurationLimit)
          == original
      else { throw diskGrowthError(.storage) }
      guard fault != .afterBackup else { throw diskGrowthError(.storage) }
      try Task.checkCancellation()
      guard try DiskGrowthIO.configuration(at: anchor) == original else {
        throw diskGrowthError(.busy)
      }
      try DiskGrowthIO.atomic(
        replacement, name: DiskGrowthIO.configurationFile, at: anchor,
        afterRename: {
          guard fault != .afterRename else { throw diskGrowthError(.storage) }
        })
      guard try DiskGrowthIO.configuration(at: anchor) == replacement else {
        throw diskGrowthError(.storage)
      }
      guard
        try DiskGrowthIO.readFile(backup, at: anchor, limit: DiskGrowthIO.configurationLimit)
          == original
      else { throw diskGrowthError(.storage) }
      guard fault != .afterCommit else { throw diskGrowthError(.storage) }
      return backup
    }
  }
}
