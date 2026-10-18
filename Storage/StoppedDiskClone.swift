// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

enum StoppedDiskCloneFault: Sendable { case afterClone, afterFlush }

extension VMFiles {
  package static func validateCloneDiskName(_ name: String) throws {
    guard DiskGrowthIO.safeDiskName(name) else {
      throw StoppedDiskCloneIO.failure(.invalidConfiguration)
    }
  }

  /// Copy only an admitted stopped disk. Core separately validates history semantics
  /// and creates fresh guest/platform identity before registering the new VM.
  package func cloneStoppedDisk(
    from source: URL, to destination: URL, configuration: VMConfiguration,
    registration: Data, history: Data?, destinationVMID: UUID,
    sourceLock: VMLock, destinationLock: VMLock
  ) throws -> DiskUsage {
    try cloneStoppedDisk(
      from: source, to: destination, configuration: configuration, registration: registration,
      history: history, destinationVMID: destinationVMID, sourceLock: sourceLock,
      destinationLock: destinationLock, fault: nil)
  }

  func cloneStoppedDisk(
    from source: URL, to destination: URL, configuration: VMConfiguration,
    registration: Data, history: Data?, destinationVMID: UUID,
    sourceLock: VMLock, destinationLock: VMLock, fault: StoppedDiskCloneFault?
  ) throws -> DiskUsage {
    guard sourceLock !== destinationLock, configuration.id != destinationVMID,
      sourceLock.owns(source), destinationLock.owns(destination),
      DiskGrowthIO.safeDiskName(configuration.diskFile),
      configuration.diskBytes > 0, configuration.diskBytes <= UInt64(Int64.max),
      try DiskGrowthIO.decodeConfiguration(registration) == configuration
    else { throw StoppedDiskCloneIO.failure(.invalidConfiguration) }
    try sourceLock.reserveConfigurationChange(forVMID: configuration.id)
    try destinationLock.reserveConfigurationChange(forVMID: destinationVMID)
    try Task.checkCancellation()
    return try sourceLock.withRuntimeIntentDirectory { sourceAnchor in
      try destinationLock.withRuntimeIntentDirectory { destinationAnchor in
        var sourceDirectory = stat()
        var destinationDirectory = stat()
        guard fstat(sourceAnchor, &sourceDirectory) == 0,
          fstat(destinationAnchor, &destinationDirectory) == 0,
          sourceDirectory.st_dev != destinationDirectory.st_dev
            || sourceDirectory.st_ino != destinationDirectory.st_ino
        else { throw StoppedDiskCloneIO.failure(.invalidConfiguration) }
        try StoppedDiskCloneIO.noACL(sourceAnchor)
        try StoppedDiskCloneIO.noACL(destinationAnchor)
        try RuntimeIntentIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        try DiskGrowthIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        let intent = try RuntimeIntentIO.read(at: sourceAnchor)
        try StoppedDiskCloneIO.unregistered(destinationAnchor, vmID: destinationVMID)
        try StoppedDiskCloneIO.sourceMetadata(
          at: sourceAnchor, registration: registration, history: history)
        let disk = try DiskGrowthIO.openDisk(
          configuration.diskFile, at: sourceAnchor, writable: false)
        defer { close(disk) }
        let original = try DiskGrowthIO.diskInfo(
          disk, name: configuration.diskFile, at: sourceAnchor)
        guard UInt64(original.st_size) == configuration.diskBytes else {
          throw StoppedDiskCloneIO.failure(.corruptMetadata)
        }
        guard original.st_dev == destinationDirectory.st_dev else {
          throw StoppedDiskCloneIO.failure(.unsupported)
        }
        try StoppedDiskCloneIO.noACL(disk)
        var capacity = statfs()
        guard fstatfs(destinationAnchor, &capacity) == 0, capacity.f_bsize > 0,
          StoppedDiskCloneIO.capacitySufficient(
            sourceBlocks: original.st_blocks, freeBlocks: UInt64(capacity.f_bavail),
            blockBytes: UInt64(capacity.f_bsize))
        else { throw StoppedDiskCloneIO.failure(.storage) }
        try Task.checkCancellation()
        guard
          fclonefileat(
            disk, destinationAnchor, configuration.diskFile, UInt32(CLONE_NOOWNERCOPY)) == 0
        else {
          let code: VMError.Code =
            [EXDEV, ENOTSUP, ENOSYS].contains(errno) ? .unsupported : .storage
          throw StoppedDiskCloneIO.failure(code)
        }
        // A failure never removes a created result or registers an incomplete VM.
        guard fault != .afterClone else { throw StoppedDiskCloneIO.failure(.storage) }
        let result = try DiskGrowthIO.openDisk(configuration.diskFile, at: destinationAnchor)
        defer { close(result) }
        try StoppedDiskCloneIO.noACL(result)
        guard fchmod(result, 0o600) == 0, fsync(result) == 0, fsync(destinationAnchor) == 0 else {
          throw StoppedDiskCloneIO.failure(.storage)
        }
        guard fault != .afterFlush else { throw StoppedDiskCloneIO.failure(.storage) }
        try Task.checkCancellation()
        let copied = try DiskGrowthIO.diskInfo(
          result, name: configuration.diskFile, at: destinationAnchor)
        let remaining = try DiskGrowthIO.diskInfo(
          disk, name: configuration.diskFile, at: sourceAnchor)
        guard DiskGrowthIO.stable(original, remaining), copied.st_size == original.st_size,
          copied.st_dev != original.st_dev || copied.st_ino != original.st_ino,
          copied.st_blocks >= 0, UInt64(copied.st_blocks) <= UInt64.max / 512
        else { throw StoppedDiskCloneIO.failure(.staleOperation) }
        try StoppedDiskCloneIO.noACL(sourceAnchor)
        try StoppedDiskCloneIO.noACL(destinationAnchor)
        try StoppedDiskCloneIO.noACL(disk)
        try StoppedDiskCloneIO.noACL(result)
        try StoppedDiskCloneIO.sourceMetadata(
          at: sourceAnchor, registration: registration, history: history)
        try RuntimeIntentIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        try DiskGrowthIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        guard try RuntimeIntentIO.read(at: sourceAnchor) == intent else {
          throw StoppedDiskCloneIO.failure(.staleOperation)
        }
        try StoppedDiskCloneIO.unregistered(destinationAnchor, vmID: destinationVMID)
        return DiskUsage(
          virtualBytes: UInt64(copied.st_size), allocatedBytes: UInt64(copied.st_blocks) * 512)
      }
    }
  }

  /// Publish a new registration only after the caller creates and flushes fresh
  /// platform identity. The disk-copy reservation remains held by both leases.
  package func commitNewCloneConfiguration(
    _ data: Data, from source: URL, to destination: URL, configuration: VMConfiguration,
    registration: Data, history: Data?, sourceLock: VMLock, destinationLock: VMLock,
    destinationVMID: UUID
  ) throws {
    let target = try DiskGrowthIO.decodeConfiguration(data)
    var expected = configuration
    expected.id = destinationVMID
    expected.name = target.name
    expected.macAddress = target.macAddress
    expected.network = .disconnected
    guard sourceLock !== destinationLock, configuration.id != destinationVMID,
      sourceLock.owns(source), destinationLock.owns(destination), target == expected,
      target.macAddress != configuration.macAddress,
      DiskGrowthIO.safeDiskName(target.diskFile),
      try DiskGrowthIO.decodeConfiguration(registration) == configuration
    else { throw StoppedDiskCloneIO.failure(.invalidConfiguration) }
    try Task.checkCancellation()
    try sourceLock.withRuntimeIntentDirectory { sourceAnchor in
      try destinationLock.withRuntimeIntentDirectory { destinationAnchor in
        try StoppedDiskCloneIO.noACL(sourceAnchor)
        try StoppedDiskCloneIO.noACL(destinationAnchor)
        try RuntimeIntentIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        try DiskGrowthIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        let intent = try RuntimeIntentIO.read(at: sourceAnchor)
        try StoppedDiskCloneIO.sourceMetadata(
          at: sourceAnchor, registration: registration, history: history)
        try StoppedDiskCloneIO.unregistered(destinationAnchor, vmID: destinationVMID)
        let original = try DiskGrowthIO.openDisk(
          configuration.diskFile, at: sourceAnchor, writable: false)
        defer { close(original) }
        let result = try DiskGrowthIO.openDisk(
          target.diskFile, at: destinationAnchor, writable: false)
        defer { close(result) }
        try StoppedDiskCloneIO.noACL(original)
        try StoppedDiskCloneIO.noACL(result)
        let sourceInfo = try DiskGrowthIO.diskInfo(
          original, name: configuration.diskFile, at: sourceAnchor)
        let targetInfo = try DiskGrowthIO.diskInfo(
          result, name: target.diskFile, at: destinationAnchor)
        guard UInt64(sourceInfo.st_size) == configuration.diskBytes,
          targetInfo.st_size == sourceInfo.st_size,
          sourceInfo.st_dev == targetInfo.st_dev, sourceInfo.st_ino != targetInfo.st_ino,
          sourceInfo.st_mtimespec.tv_sec == targetInfo.st_mtimespec.tv_sec,
          sourceInfo.st_mtimespec.tv_nsec == targetInfo.st_mtimespec.tv_nsec,
          fsync(result) == 0, fsync(destinationAnchor) == 0
        else { throw StoppedDiskCloneIO.failure(.staleOperation) }
        let temporary = ".metadata-clone-\(UUID().uuidString).tmp"
        let fd = openat(
          destinationAnchor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
          S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoppedDiskCloneIO.failure(.storage) }
        defer { close(fd) }
        try StoppedDiskCloneIO.noACL(fd)
        try data.withUnsafeBytes { buffer in
          var offset = 0
          while offset < buffer.count {
            guard let start = buffer.baseAddress else { throw StoppedDiskCloneIO.failure(.storage) }
            let count = write(fd, start.advanced(by: offset), buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw StoppedDiskCloneIO.failure(.storage) }
            offset += count
          }
        }
        guard fsync(fd) == 0 else { throw StoppedDiskCloneIO.failure(.storage) }
        try Task.checkCancellation()
        try StoppedDiskCloneIO.sourceMetadata(
          at: sourceAnchor, registration: registration, history: history)
        try RuntimeIntentIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        try DiskGrowthIO.requireAdmission(at: sourceAnchor, expectedVMID: configuration.id)
        guard try RuntimeIntentIO.read(at: sourceAnchor) == intent,
          DiskGrowthIO.stable(
            sourceInfo,
            try DiskGrowthIO.diskInfo(original, name: configuration.diskFile, at: sourceAnchor)),
          DiskGrowthIO.stable(
            targetInfo,
            try DiskGrowthIO.diskInfo(result, name: target.diskFile, at: destinationAnchor))
        else { throw StoppedDiskCloneIO.failure(.staleOperation) }
        try StoppedDiskCloneIO.noACL(sourceAnchor)
        try StoppedDiskCloneIO.noACL(destinationAnchor)
        try StoppedDiskCloneIO.noACL(original)
        try StoppedDiskCloneIO.noACL(result)
        try StoppedDiskCloneIO.noACL(fd)
        try StoppedDiskCloneIO.unregistered(destinationAnchor, vmID: destinationVMID)
        guard
          renameatx_np(
            destinationAnchor, temporary, destinationAnchor, "configuration.json",
            UInt32(RENAME_EXCL))
            == 0,
          fsync(destinationAnchor) == 0,
          try DiskGrowthIO.configuration(at: destinationAnchor) == data
        else { throw StoppedDiskCloneIO.failure(.storage) }
      }
    }
  }
}

enum StoppedDiskCloneIO {
  static let reserveBytes: UInt64 = 1_073_741_824

  static func capacitySufficient(sourceBlocks: Int64, freeBlocks: UInt64, blockBytes: UInt64)
    -> Bool
  {
    guard sourceBlocks >= 0, blockBytes > 0,
      UInt64(sourceBlocks) <= (UInt64.max - reserveBytes) / 512
    else { return false }
    let required = UInt64(sourceBlocks) * 512 + reserveBytes
    let blocks = required / blockBytes + (required % blockBytes == 0 ? 0 : 1)
    return freeBlocks >= blocks
  }

  static func noACL(_ descriptor: Int32) throws {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      // Darwin reports absent extended ACLs as ENOENT even for an existing fd.
      let absent = errno == ENOENT
      var info = stat()
      guard absent, fstat(descriptor, &info) == 0,
        [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT)
      else { throw failure(.storage) }
      return
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_valid(acl) == 0 else { throw failure(.storage) }
    var entry: acl_entry_t?
    errno = 0
    let status = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
    guard status == -1, errno == EINVAL else { throw failure(.storage) }
  }

  static func sourceMetadata(at anchor: Int32, registration: Data, history: Data?) throws {
    guard try DiskGrowthIO.configuration(at: anchor) == registration,
      try optionalHistory(at: anchor) == history
    else { throw failure(.staleOperation) }
  }

  static func optionalHistory(at anchor: Int32) throws -> Data? {
    var info = stat()
    guard fstatat(anchor, "runtime.json", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw failure(.storage)
    }
    return try DiskGrowthIO.readFile("runtime.json", at: anchor, limit: 4096)
  }

  static func unregistered(_ anchor: Int32, vmID: UUID) throws {
    var info = stat()
    guard fstatat(anchor, "configuration.json", &info, AT_SYMLINK_NOFOLLOW) == -1,
      errno == ENOENT, try optionalHistory(at: anchor) == nil,
      try RuntimeIntentIO.read(at: anchor) == nil, try DiskGrowthIO.read(at: anchor) == nil
    else { throw failure(.invalidConfiguration) }
    try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: vmID)
    try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: vmID)
  }

  static func failure(_ code: VMError.Code) -> VMError {
    VMError(
      code, "The stopped disk clone could not be confirmed.",
      recovery:
        "Keep the source and incomplete destination. Use private files on the same cloning-capable volume; do not register or overwrite partial copies."
    )
  }
}
