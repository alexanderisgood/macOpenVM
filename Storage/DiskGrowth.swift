// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation

/// Read-only transaction metadata. This record never grants runtime or resize authority.
public struct DiskGrowthIntent: Equatable, Sendable {
  public enum State: String, Sendable { case pending, completed }
  public static let filename = "disk-growth-intent.json"
  public static let maximumBytes = 4096
  public let schemaVersion: Int
  public let vmID: UUID
  public let transactionID: UUID
  public let state: State
  public let diskFile: String
  public let directoryDevice: Int32
  public let directoryInode: UInt64
  public let diskDevice: Int32
  public let diskInode: UInt64
  public let directoryVolumeUUID: UUID?
  public let diskVolumeUUID: UUID?
  public let oldBytes: UInt64
  public let targetBytes: UInt64
  public let originalConfigurationSHA256: String
  public let replacementConfigurationSHA256: String
  public let backupFile: String
  public let targetFile: String

  fileprivate init(
    schemaVersion: Int, vmID: UUID, transactionID: UUID, state: State, diskFile: String,
    directoryVolumeUUID: UUID?, diskVolumeUUID: UUID?,
    directoryDevice: Int32, directoryInode: UInt64, diskDevice: Int32, diskInode: UInt64,
    oldBytes: UInt64, targetBytes: UInt64, originalConfigurationSHA256: String,
    replacementConfigurationSHA256: String
  ) {
    self.schemaVersion = schemaVersion
    self.directoryVolumeUUID = directoryVolumeUUID
    self.diskVolumeUUID = diskVolumeUUID
    self.vmID = vmID
    self.transactionID = transactionID
    self.state = state
    self.diskFile = diskFile
    self.directoryDevice = directoryDevice
    self.directoryInode = directoryInode
    self.diskDevice = diskDevice
    self.diskInode = diskInode
    self.oldBytes = oldBytes
    self.targetBytes = targetBytes
    self.originalConfigurationSHA256 = originalConfigurationSHA256
    self.replacementConfigurationSHA256 = replacementConfigurationSHA256
    backupFile = "disk-growth-\(transactionID.uuidString)-original.json"
    targetFile = "disk-growth-\(transactionID.uuidString)-target.json"
  }

  fileprivate var completed: Self {
    Self(
      schemaVersion: schemaVersion, vmID: vmID, transactionID: transactionID,
      state: .completed, diskFile: diskFile,
      directoryVolumeUUID: directoryVolumeUUID, diskVolumeUUID: diskVolumeUUID,
      directoryDevice: directoryDevice, directoryInode: directoryInode,
      diskDevice: diskDevice, diskInode: diskInode, oldBytes: oldBytes, targetBytes: targetBytes,
      originalConfigurationSHA256: originalConfigurationSHA256,
      replacementConfigurationSHA256: replacementConfigurationSHA256)
  }
}

/// Storage alone constructs this after durable pending intent. Actual descriptors and the
/// real lease remain retained. A recovered permit is purpose-bound and cannot launch a runtime.
package final class DiskGrowthPermit: Sendable {
  package let vmID: UUID
  package let transactionID: UUID
  package let diskFile: String
  package let oldBytes: UInt64
  package let targetBytes: UInt64
  package let originalConfiguration: Data
  package let replacementConfiguration: Data
  package let currentConfiguration: Data
  package let backupFile: String
  private let owner: VMLock
  fileprivate let directory: URL
  fileprivate let anchor: Int32
  fileprivate let disk: Int32
  fileprivate let record: DiskGrowthIntent
  private let openedIdentity: DiskGrowthOpenedIdentity
  private let claim = DiskGrowthOperationClaim()

  fileprivate init(
    owner: VMLock, directory: URL, anchor: Int32, disk: Int32, record: DiskGrowthIntent,
    original: Data, replacement: Data, current: Data, openedIdentity: DiskGrowthOpenedIdentity
  ) {
    self.owner = owner
    self.directory = directory
    self.anchor = anchor
    self.disk = disk
    self.record = record
    self.openedIdentity = openedIdentity
    vmID = record.vmID
    transactionID = record.transactionID
    diskFile = record.diskFile
    oldBytes = record.oldBytes
    targetBytes = record.targetBytes
    backupFile = record.backupFile
    originalConfiguration = original
    replacementConfiguration = replacement
    currentConfiguration = current
  }

  fileprivate func reserve() throws { try claim.reserve() }

  fileprivate func withOwner<Result>(_ body: () throws -> Result) throws -> Result {
    guard owner.owns(directory) else { throw diskGrowthError(.storage) }
    return try owner.withRuntimeIntentDirectory { held in
      var first = stat()
      var second = stat()
      guard fstat(held, &first) == 0, fstat(anchor, &second) == 0,
        first.st_dev == second.st_dev, first.st_ino == second.st_ino
      else { throw diskGrowthError(.storage) }
      try openedIdentity.requireMatches(directory: anchor, disk: disk)
      let result = try body()
      try openedIdentity.requireMatches(directory: anchor, disk: disk)
      return result
    }
  }

  deinit {
    close(disk)
    close(anchor)
  }
}

package struct DiskGrowthCompletion: Sendable {
  package let oldBytes: UInt64
  package let targetBytes: UInt64
  package let backupFile: String
  package let transactionID: UUID
}

/// Only a one-shot flag is mutable; every access is protected by the private mutex.
private final class DiskGrowthOperationClaim: @unchecked Sendable {
  private let mutex = NSLock()
  private var attempted = false
  func reserve() throws {
    mutex.lock()
    defer { mutex.unlock() }
    guard !attempted else { throw diskGrowthError(.busy) }
    attempted = true
  }
}

/// Internal, deterministic fault seam used by fresh filesystem tests only.
enum DiskGrowthFaultPoint: CaseIterable, Equatable, Sendable {
  case afterBackup, afterSidecarsFlush, afterCompletedArchive, afterPending
  case afterGrow, afterDiskFlush, afterConfigurationRename, afterConfigurationFlush
  case afterCompletedRename, afterCompletedFlush
  case afterIdentityUpgradeArchive, afterIdentityUpgradeRename, afterIdentityUpgradeFlush
}

extension VMFiles {
  public func readDiskGrowthIntent(in directory: URL) throws -> DiskGrowthIntent? {
    let anchor = try DiskGrowthIO.openDirectory(directory)
    defer { close(anchor) }
    return try DiskGrowthIO.read(at: anchor)
  }

  /// Diagnostic validation only: no writer lease is created or acquired and no file is opened
  /// for writing. Historical full configuration hashes do not reject later legitimate edits.
  public func verifyCompletedDiskGrowth(in directory: URL, expectedVMID: UUID) throws {
    let anchor = try DiskGrowthIO.openDirectory(directory)
    defer { close(anchor) }
    guard let record = try DiskGrowthIO.read(at: anchor), record.state == .completed else {
      throw diskGrowthError(.busy)
    }
    try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: expectedVMID)
  }

  /// Explicit metadata-only upgrade while the complete legacy device/inode proof still
  /// holds. A remounted v1 journal cannot enter through this ordinarily admitted owner.
  /// The disk is opened read-only; exact prior journal bytes are durably retained first.
  package func upgradeCompletedDiskGrowthIdentity(
    in directory: URL, vmID: UUID, expectedTransactionID: UUID, lock: VMLock,
    observed: DiskGrowthIdentityUpgradeSnapshot? = nil,
    validateStopped: (@Sendable (Data, Data?, RuntimeIntent?) throws -> Void)? = nil
  ) throws -> DiskGrowthIntent {
    try Task.checkCancellation()
    // Existing package-only storage callers retain their original admission contract.
    // Product Core always supplies both the exact observation and full stopped validator.
    guard (observed == nil) == (validateStopped == nil) else { throw diskGrowthError(.busy) }
    guard lock.owns(directory) else { throw diskGrowthError(.invalidConfiguration) }
    try lock.reserveConfigurationChange(forVMID: vmID)
    return try lock.withRuntimeIntentDirectory { anchor in
      try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: vmID)
      guard let priorBytes = try DiskGrowthIO.readBytes(at: anchor) else {
        throw diskGrowthError(.busy)
      }
      let prior = try DiskGrowthIO.decode(priorBytes)
      guard prior.schemaVersion == 1, prior.state == .completed, prior.vmID == vmID,
        prior.transactionID == expectedTransactionID
      else { throw diskGrowthError(.busy) }
      try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: vmID)
      let current = try DiskGrowthIO.configuration(at: anchor)
      let disk = try DiskGrowthIO.openDisk(prior.diskFile, at: anchor, writable: false)
      defer { close(disk) }
      let before = try DiskGrowthIO.verifyDisk(
        prior, fd: disk, at: anchor, allowed: [prior.targetBytes])
      let opened = try DiskGrowthOpenedIdentity(directory: anchor, disk: disk)
      let directoryUUID = try DiskGrowthVolumeIdentity.read(from: anchor)
      let diskUUID = try DiskGrowthVolumeIdentity.read(from: disk)
      var parent = stat()
      guard fstat(anchor, &parent) == 0, parent.st_dev == before.st_dev,
        directoryUUID == diskUUID
      else { throw diskGrowthError(.storage) }
      let upgraded = DiskGrowthIntent(
        schemaVersion: 2, vmID: prior.vmID, transactionID: prior.transactionID,
        state: .completed, diskFile: prior.diskFile,
        directoryVolumeUUID: directoryUUID, diskVolumeUUID: diskUUID,
        directoryDevice: prior.directoryDevice, directoryInode: prior.directoryInode,
        diskDevice: prior.diskDevice, diskInode: prior.diskInode,
        oldBytes: prior.oldBytes, targetBytes: prior.targetBytes,
        originalConfigurationSHA256: prior.originalConfigurationSHA256,
        replacementConfigurationSHA256: prior.replacementConfigurationSHA256)
      let upgradedBytes = try DiskGrowthIO.encode(upgraded)
      let stopped: DiskGrowthIdentityUpgradeSnapshot?
      if let observed, let validateStopped {
        let captured = try DiskGrowthIdentityUpgradeIO.snapshot(at: anchor, record: prior)
        guard captured == observed else { throw diskGrowthError(.staleOperation) }
        try validateStopped(captured.configuration, captured.history, captured.intent)
        guard try DiskGrowthIdentityUpgradeIO.snapshot(at: anchor, record: prior) == captured else {
          throw diskGrowthError(.staleOperation)
        }
        stopped = captured
      } else {
        stopped = nil
      }
      try DiskGrowthIO.archiveCompleted(
        priorBytes,
        name: "disk-growth-\(prior.transactionID.uuidString)-schema1-completed.json", at: anchor)
      try DiskGrowthIO.checkpoint(.afterIdentityUpgradeArchive, fault: diskGrowthFault)
      try opened.requireMatches(directory: anchor, disk: disk)
      try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: vmID)
      let after = try DiskGrowthIO.verifyDisk(
        prior, fd: disk, at: anchor, allowed: [prior.targetBytes])
      guard DiskGrowthIO.stable(before, after),
        try DiskGrowthIO.readBytes(at: anchor) == priorBytes,
        try DiskGrowthIO.configuration(at: anchor) == current
      else { throw diskGrowthError(.corruptMetadata) }
      _ = try DiskGrowthIO.verifyDisk(
        upgraded, fd: disk, at: anchor, allowed: [prior.targetBytes])
      if let stopped, let validateStopped {
        let captured = try DiskGrowthIdentityUpgradeIO.snapshot(at: anchor, record: prior)
        guard captured == stopped else { throw diskGrowthError(.staleOperation) }
        try validateStopped(captured.configuration, captured.history, captured.intent)
        guard try DiskGrowthIdentityUpgradeIO.snapshot(at: anchor, record: prior) == captured else {
          throw diskGrowthError(.staleOperation)
        }
      }
      try DiskGrowthIO.atomic(
        upgradedBytes, name: DiskGrowthIntent.filename, at: anchor,
        afterRename: {
          try DiskGrowthIO.checkpoint(.afterIdentityUpgradeRename, fault: self.diskGrowthFault)
        })
      guard try DiskGrowthIO.readBytes(at: anchor) == upgradedBytes,
        try DiskGrowthIO.configuration(at: anchor) == current
      else { throw diskGrowthError(.storage) }
      try opened.requireMatches(directory: anchor, disk: disk)
      let final = try DiskGrowthIO.verifyDisk(
        upgraded, fd: disk, at: anchor, allowed: [prior.targetBytes])
      guard DiskGrowthIO.stable(before, final) else { throw diskGrowthError(.storage) }
      if let stopped, let validateStopped {
        let captured = try DiskGrowthIdentityUpgradeIO.snapshot(at: anchor, record: upgraded)
        guard captured.preservesStoppedState(of: stopped) else { throw diskGrowthError(.storage) }
        try validateStopped(captured.configuration, captured.history, captured.intent)
        guard try DiskGrowthIdentityUpgradeIO.snapshot(at: anchor, record: upgraded) == captured
        else {
          throw diskGrowthError(.storage)
        }
      }
      try DiskGrowthIO.checkpoint(.afterIdentityUpgradeFlush, fault: diskGrowthFault)
      return upgraded
    }
  }

  package func beginDiskGrowth(
    in directory: URL, vmID: UUID, diskFile: String, oldBytes: UInt64, targetBytes: UInt64,
    originalConfiguration: Data, replacementConfiguration: Data, lock: VMLock
  ) throws -> DiskGrowthPermit {
    try Task.checkCancellation()
    guard lock.owns(directory) else { throw diskGrowthError(.invalidConfiguration) }
    let transactionID = try lock.reserveDiskGrowth(forVMID: vmID)
    return try lock.withRuntimeIntentDirectory { anchor in
      try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: vmID)
      try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: vmID)
      try DiskGrowthIO.validateConfigurations(
        originalConfiguration, replacementConfiguration, vmID: vmID, diskFile: diskFile,
        oldBytes: oldBytes, targetBytes: targetBytes)
      try DiskGrowthIO.requireFreeSpace(at: anchor)
      guard try DiskGrowthIO.configuration(at: anchor) == originalConfiguration else {
        throw diskGrowthError(.corruptMetadata)
      }
      let disk = try DiskGrowthIO.openDisk(diskFile, at: anchor)
      var transferred = false
      defer { if !transferred { close(disk) } }
      let info = try DiskGrowthIO.diskInfo(disk, name: diskFile, at: anchor)
      guard UInt64(info.st_size) == oldBytes else { throw diskGrowthError(.corruptMetadata) }
      var parent = stat()
      guard fstat(anchor, &parent) == 0 else { throw diskGrowthError(.storage) }
      let directoryVolumeUUID = try DiskGrowthVolumeIdentity.read(from: anchor)
      let diskVolumeUUID = try DiskGrowthVolumeIdentity.read(from: disk)
      guard parent.st_dev == info.st_dev, directoryVolumeUUID == diskVolumeUUID else {
        throw diskGrowthError(.storage)
      }
      let record = DiskGrowthIntent(
        schemaVersion: 2, vmID: vmID, transactionID: transactionID,
        state: .pending, diskFile: diskFile,
        directoryVolumeUUID: directoryVolumeUUID, diskVolumeUUID: diskVolumeUUID,
        directoryDevice: parent.st_dev, directoryInode: parent.st_ino,
        diskDevice: info.st_dev, diskInode: info.st_ino, oldBytes: oldBytes,
        targetBytes: targetBytes,
        originalConfigurationSHA256: DiskGrowthIO.digest(originalConfiguration),
        replacementConfigurationSHA256: DiskGrowthIO.digest(replacementConfiguration))
      try DiskGrowthIO.exclusive(originalConfiguration, name: record.backupFile, at: anchor)
      try DiskGrowthIO.checkpoint(.afterBackup, fault: diskGrowthFault)
      try DiskGrowthIO.exclusive(replacementConfiguration, name: record.targetFile, at: anchor)
      guard fsync(anchor) == 0 else { throw diskGrowthError(.storage) }
      try DiskGrowthIO.checkpoint(.afterSidecarsFlush, fault: diskGrowthFault)
      _ = try DiskGrowthIO.sidecars(record, at: anchor)
      guard try DiskGrowthIO.configuration(at: anchor) == originalConfiguration else {
        throw diskGrowthError(.corruptMetadata)
      }
      _ = try DiskGrowthIO.verifyDisk(record, fd: disk, at: anchor, allowed: [oldBytes])
      if let previous = try DiskGrowthIO.readBytes(at: anchor) {
        guard try DiskGrowthIO.decode(previous).state == .completed else {
          throw diskGrowthError(.busy)
        }
        let prior = try DiskGrowthIO.decode(previous)
        try DiskGrowthIO.archiveCompleted(
          previous, name: "disk-growth-\(prior.transactionID.uuidString)-completed.json", at: anchor
        )
        guard try DiskGrowthIO.readBytes(at: anchor) == previous else {
          throw diskGrowthError(.busy)
        }
        try DiskGrowthIO.checkpoint(.afterCompletedArchive, fault: diskGrowthFault)
      }
      try DiskGrowthIO.atomic(
        DiskGrowthIO.encode(record), name: DiskGrowthIntent.filename, at: anchor)
      guard try DiskGrowthIO.read(at: anchor) == record else { throw diskGrowthError(.storage) }
      try DiskGrowthIO.checkpoint(.afterPending, fault: diskGrowthFault)
      let openedIdentity = try DiskGrowthOpenedIdentity(directory: anchor, disk: disk)
      let copy = fcntl(anchor, F_DUPFD_CLOEXEC, 3)
      guard copy >= 0 else { throw diskGrowthError(.storage) }
      transferred = true
      return DiskGrowthPermit(
        owner: lock, directory: directory, anchor: copy, disk: disk, record: record,
        original: originalConfiguration, replacement: replacementConfiguration,
        current: originalConfiguration, openedIdentity: openedIdentity)
    }
  }

  package func openDiskGrowthRecovery(
    in directory: URL, vmID: UUID, expectedTransactionID: UUID
  ) throws -> DiskGrowthPermit {
    try Task.checkCancellation()
    let lock = try VMLock.diskGrowthRecovery(
      in: directory, vmID: vmID, transactionID: expectedTransactionID)
    _ = try lock.reserveDiskGrowth(forVMID: vmID, recovering: expectedTransactionID)
    return try lock.withRuntimeIntentDirectory { anchor in
      try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: vmID)
      try DiskGrowthIO.requireRecoveryAdmission(
        at: anchor, vmID: vmID, transactionID: expectedTransactionID)
      guard let record = try DiskGrowthIO.read(at: anchor) else { throw diskGrowthError(.busy) }
      let (original, replacement) = try DiskGrowthIO.sidecars(record, at: anchor)
      let current = try DiskGrowthIO.configuration(at: anchor)
      let disk = try DiskGrowthIO.openDisk(record.diskFile, at: anchor)
      var transferred = false
      defer { if !transferred { close(disk) } }
      _ = try DiskGrowthIO.verifyDisk(
        record, fd: disk, at: anchor, allowed: [record.oldBytes, record.targetBytes])
      let openedIdentity = try DiskGrowthOpenedIdentity(directory: anchor, disk: disk)
      let copy = fcntl(anchor, F_DUPFD_CLOEXEC, 3)
      guard copy >= 0 else { throw diskGrowthError(.storage) }
      transferred = true
      return DiskGrowthPermit(
        owner: lock, directory: directory, anchor: copy, disk: disk, record: record,
        original: original, replacement: replacement, current: current,
        openedIdentity: openedIdentity)
    }
  }

  package func commitDiskGrowth(_ permit: DiskGrowthPermit) throws -> DiskGrowthCompletion {
    try permit.reserve()
    try Task.checkCancellation()
    return try permit.withOwner {
      let record = permit.record
      let anchor = permit.anchor
      try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: record.vmID)
      guard try DiskGrowthIO.read(at: anchor) == record else { throw diskGrowthError(.busy) }
      let (original, replacement) = try DiskGrowthIO.sidecars(record, at: anchor)
      guard original == permit.originalConfiguration, replacement == permit.replacementConfiguration
      else { throw diskGrowthError(.corruptMetadata) }
      let current = try DiskGrowthIO.configuration(at: anchor)
      guard current == original || current == replacement else {
        throw diskGrowthError(.corruptMetadata)
      }
      let before = try DiskGrowthIO.verifyDisk(
        record, fd: permit.disk, at: anchor, allowed: [record.oldBytes, record.targetBytes])
      try DiskGrowthIO.requireFreeSpace(at: anchor)
      if UInt64(before.st_size) == record.oldBytes {
        guard current == original, ftruncate(permit.disk, off_t(record.targetBytes)) == 0 else {
          throw diskGrowthError(.storage)
        }
      }
      try DiskGrowthIO.checkpoint(.afterGrow, fault: diskGrowthFault)
      _ = try DiskGrowthIO.verifyDisk(
        record, fd: permit.disk, at: anchor, allowed: [record.targetBytes])
      guard fsync(permit.disk) == 0 else { throw diskGrowthError(.storage) }
      _ = try DiskGrowthIO.verifyDisk(
        record, fd: permit.disk, at: anchor, allowed: [record.targetBytes])
      try DiskGrowthIO.checkpoint(.afterDiskFlush, fault: diskGrowthFault)
      guard try DiskGrowthIO.read(at: anchor) == record,
        try DiskGrowthIO.configuration(at: anchor) == current
      else { throw diskGrowthError(.corruptMetadata) }
      if current != replacement {
        try DiskGrowthIO.atomic(
          replacement, name: DiskGrowthIO.configurationFile, at: anchor,
          afterRename: {
            try DiskGrowthIO.checkpoint(.afterConfigurationRename, fault: self.diskGrowthFault)
          })
      }
      guard try DiskGrowthIO.configuration(at: anchor) == replacement else {
        throw diskGrowthError(.storage)
      }
      try DiskGrowthIO.checkpoint(.afterConfigurationFlush, fault: diskGrowthFault)
      _ = try DiskGrowthIO.sidecars(record, at: anchor)
      _ = try DiskGrowthIO.verifyDisk(
        record, fd: permit.disk, at: anchor, allowed: [record.targetBytes])
      guard try DiskGrowthIO.read(at: anchor) == record else { throw diskGrowthError(.busy) }
      try DiskGrowthIO.atomic(
        DiskGrowthIO.encode(record.completed), name: DiskGrowthIntent.filename, at: anchor,
        afterRename: {
          try DiskGrowthIO.checkpoint(.afterCompletedRename, fault: self.diskGrowthFault)
        })
      guard try DiskGrowthIO.read(at: anchor) == record.completed else {
        throw diskGrowthError(.storage)
      }
      try DiskGrowthIO.checkpoint(.afterCompletedFlush, fault: diskGrowthFault)
      return DiskGrowthCompletion(
        oldBytes: record.oldBytes, targetBytes: record.targetBytes,
        backupFile: record.backupFile, transactionID: record.transactionID)
    }
  }
}

enum DiskGrowthIO {
  static let configurationFile = "configuration.json"
  static let configurationLimit = 65_536
  static let minimumFreeBytes: UInt64 = 1_073_741_824 + 3 * 65_536 + 2 * 4096

  static func freeSpaceSufficient(availableBlocks: UInt64, blockBytes: UInt64) -> Bool {
    guard blockBytes > 0 else { return false }
    let requiredBlocks =
      minimumFreeBytes / blockBytes + (minimumFreeBytes % blockBytes == 0 ? 0 : 1)
    return availableBlocks >= requiredBlocks
  }

  static func requireFreeSpace(at anchor: Int32) throws {
    var info = statfs()
    guard fstatfs(anchor, &info) == 0, info.f_bsize > 0,
      freeSpaceSufficient(availableBlocks: UInt64(info.f_bavail), blockBytes: UInt64(info.f_bsize))
    else { throw diskGrowthError(.storage) }
  }

  static func checkpoint(_ point: DiskGrowthFaultPoint, fault: DiskGrowthFaultPoint?) throws {
    guard point != fault else { throw diskGrowthError(.storage) }
  }

  static func openDirectory(_ directory: URL) throws -> Int32 {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), !directory.path.contains("\0")
    else { throw diskGrowthError(.invalidConfiguration) }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw diskGrowthError(.storage) }
    do { try RuntimeIntentIO.validateDirectory(fd) } catch {
      close(fd)
      throw error
    }
    return fd
  }

  static func requireAdmission(at anchor: Int32, expectedVMID: UUID?) throws {
    guard let record = try read(at: anchor) else { return }
    guard record.state == .completed, record.vmID == expectedVMID else {
      throw diskGrowthError(.busy)
    }
    try directoryMatches(record, at: anchor)
    _ = try sidecars(record, at: anchor)
    let current = try configuration(at: anchor)
    let config = try decodeConfiguration(current)
    guard config.id == record.vmID, config.diskFile == record.diskFile,
      config.diskBytes == record.targetBytes
    else { throw diskGrowthError(.busy) }
    let fd = try openDisk(record.diskFile, at: anchor, writable: false)
    defer { close(fd) }
    _ = try verifyDisk(record, fd: fd, at: anchor, allowed: [record.targetBytes])
  }

  static func requireRecoveryAdmission(at anchor: Int32, vmID: UUID, transactionID: UUID) throws {
    guard let record = try read(at: anchor), record.state == .pending,
      record.vmID == vmID, record.transactionID == transactionID
    else { throw diskGrowthError(.busy) }
    try directoryMatches(record, at: anchor)
    let (original, replacement) = try sidecars(record, at: anchor)
    let current = try configuration(at: anchor)
    guard current == original || current == replacement else {
      throw diskGrowthError(.corruptMetadata)
    }
    let fd = try openDisk(record.diskFile, at: anchor, writable: false)
    defer { close(fd) }
    let info = try verifyDisk(
      record, fd: fd, at: anchor, allowed: [record.oldBytes, record.targetBytes])
    guard UInt64(info.st_size) != record.oldBytes || current == original else {
      throw diskGrowthError(.corruptMetadata)
    }
  }

  static func directoryMatches(_ record: DiskGrowthIntent, at anchor: Int32) throws {
    var info = stat()
    try RuntimeIntentIO.validateDirectory(anchor)
    guard fstat(anchor, &info) == 0, info.st_ino == record.directoryInode else {
      throw diskGrowthError(.storage)
    }
    if record.schemaVersion == 1 {
      guard info.st_dev == record.directoryDevice else { throw diskGrowthError(.storage) }
    } else {
      guard let expected = record.directoryVolumeUUID,
        try DiskGrowthVolumeIdentity.read(from: anchor) == expected
      else { throw diskGrowthError(.storage) }
    }
  }

  static func safe(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
      && info.st_mode & 0o7777 == 0o600 && info.st_size >= 0
  }

  static func stable(_ first: stat, _ second: stat) -> Bool {
    safe(second) && first.st_dev == second.st_dev && first.st_ino == second.st_ino
      && first.st_mode == second.st_mode && first.st_uid == second.st_uid
      && first.st_nlink == second.st_nlink && first.st_size == second.st_size
      && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
      && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
      && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
      && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
  }

  static func openDisk(_ name: String, at anchor: Int32, writable: Bool = true) throws -> Int32 {
    guard safeDiskName(name) else { throw diskGrowthError(.invalidConfiguration) }
    let fd = openat(
      anchor, name, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw diskGrowthError(.storage) }
    do { _ = try diskInfo(fd, name: name, at: anchor) } catch {
      close(fd)
      throw error
    }
    return fd
  }

  static func diskInfo(_ fd: Int32, name: String, at anchor: Int32) throws -> stat {
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0, safe(opened),
      fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0, stable(opened, named)
    else { throw diskGrowthError(.storage) }
    return opened
  }

  static func verifyDisk(_ record: DiskGrowthIntent, fd: Int32, at anchor: Int32, allowed: [UInt64])
    throws -> stat
  {
    try directoryMatches(record, at: anchor)
    let info = try diskInfo(fd, name: record.diskFile, at: anchor)
    guard info.st_ino == record.diskInode, allowed.contains(UInt64(info.st_size)) else {
      throw diskGrowthError(.corruptMetadata)
    }
    if record.schemaVersion == 1 {
      guard info.st_dev == record.diskDevice else { throw diskGrowthError(.corruptMetadata) }
    } else {
      var parent = stat()
      guard fstat(anchor, &parent) == 0, parent.st_dev == info.st_dev,
        let expected = record.diskVolumeUUID, expected == record.directoryVolumeUUID,
        try DiskGrowthVolumeIdentity.read(from: fd) == expected
      else { throw diskGrowthError(.corruptMetadata) }
      let after = try diskInfo(fd, name: record.diskFile, at: anchor)
      guard stable(info, after) else { throw diskGrowthError(.storage) }
    }
    return info
  }

  static func safeDiskName(_ name: String) -> Bool {
    let folded = name.lowercased()
    return ConfigurationValidator.isSafeComponent(name)
      && ![
        configurationFile, "writer.lock", "runtime.json", RuntimeIntent.filename,
        DiskGrowthIntent.filename, "machine-identity.bin", "efi-variables.bin",
      ].contains(folded)
      && !folded.hasPrefix("disk-growth-") && !folded.hasPrefix(".disk-growth-")
      && !folded.hasPrefix(".metadata-") && !folded.hasPrefix(".runtime-intent-")
      && !folded.hasPrefix("configuration-media-backup-")
      && !folded.hasPrefix("configuration-boot-backup-")
      && !folded.hasPrefix("configuration-hardware-backup-")
      && !folded.hasPrefix("configuration-network-backup-")
  }

  static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  static func readFile(_ name: String, at anchor: Int32, limit: Int) throws -> Data {
    let fd = openat(anchor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw diskGrowthError(.storage) }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, safe(before), before.st_size > 0, before.st_size <= limit else {
      throw diskGrowthError(.storage)
    }
    var result = Data()
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    while let bytes = try handle.read(upToCount: limit - result.count + 1), !bytes.isEmpty {
      result.append(bytes)
      guard result.count <= limit else { throw diskGrowthError(.corruptMetadata) }
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, named), result.count == before.st_size
    else { throw diskGrowthError(.storage) }
    return result
  }

  static func readBytes(at anchor: Int32) throws -> Data? {
    var info = stat()
    guard fstatat(anchor, DiskGrowthIntent.filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw diskGrowthError(.storage)
    }
    return try readFile(DiskGrowthIntent.filename, at: anchor, limit: DiskGrowthIntent.maximumBytes)
  }

  static func read(at anchor: Int32) throws -> DiskGrowthIntent? {
    try readBytes(at: anchor).map(decode)
  }

  static func configuration(at anchor: Int32) throws -> Data {
    let bytes = try readFile(configurationFile, at: anchor, limit: configurationLimit)
    _ = try decodeConfiguration(bytes)
    return bytes
  }

  static func decodeConfiguration(_ bytes: Data) throws -> VMConfiguration {
    guard !bytes.isEmpty, bytes.count <= configurationLimit else {
      throw diskGrowthError(.corruptMetadata)
    }
    var parser = GrowthFlatParser(bytes: Array(bytes), maximumKeys: 32, configurationBOM: true)
    let object = try parser.parse()
    let allowed: Set<String> = [
      "schemaVersion", "id", "name", "guest", "architecture", "backend", "cpuCount", "memoryBytes",
      "diskBytes", "diskFile", "boot", "installationMedia", "kernel", "initialRamdisk",
      "kernelArguments", "network", "macAddress", "supportMedia",
    ]
    guard Set(object.values.keys).isSubset(of: allowed),
      object.values["schemaVersion"] == .number("1")
    else {
      throw diskGrowthError(.corruptMetadata)
    }
    do {
      let typedBytes = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(bytes.dropFirst(3)) : bytes
      let configuration = try JSONDecoder().decode(VMConfiguration.self, from: typedBytes)
      guard configuration.schemaVersion == 1, safeDiskName(configuration.diskFile) else {
        throw diskGrowthError(.corruptMetadata)
      }
      return configuration
    } catch { throw diskGrowthError(.corruptMetadata) }
  }

  static func validateConfigurations(
    _ original: Data, _ replacement: Data, vmID: UUID, diskFile: String,
    oldBytes: UInt64, targetBytes: UInt64
  ) throws {
    guard safeDiskName(diskFile), oldBytes >= 1_073_741_824, oldBytes % 512 == 0,
      targetBytes > oldBytes, targetBytes <= 2_199_023_255_552, targetBytes % 512 == 0
    else { throw diskGrowthError(.invalidConfiguration) }
    let before = try decodeConfiguration(original)
    let after = try decodeConfiguration(replacement)
    var expected = before
    expected.diskBytes = targetBytes
    guard before.id == vmID, before.diskFile == diskFile, before.diskBytes == oldBytes,
      after == expected
    else { throw diskGrowthError(.corruptMetadata) }
    var parser = GrowthFlatParser(bytes: Array(original), maximumKeys: 32, configurationBOM: true)
    let object = try parser.parse()
    guard object.values["diskBytes"] == .number(String(oldBytes)),
      let range = object.ranges["diskBytes"]
    else {
      throw diskGrowthError(.corruptMetadata)
    }
    let source = Array(original)
    var exact = Data(source[..<range.lowerBound])
    exact.append(Data(String(targetBytes).utf8))
    exact.append(contentsOf: source[range.upperBound...])
    guard exact == replacement else { throw diskGrowthError(.corruptMetadata) }
  }

  static func sidecars(_ record: DiskGrowthIntent, at anchor: Int32) throws -> (Data, Data) {
    let original = try readFile(record.backupFile, at: anchor, limit: configurationLimit)
    let target = try readFile(record.targetFile, at: anchor, limit: configurationLimit)
    guard digest(original) == record.originalConfigurationSHA256,
      digest(target) == record.replacementConfigurationSHA256
    else { throw diskGrowthError(.corruptMetadata) }
    try validateConfigurations(
      original, target, vmID: record.vmID, diskFile: record.diskFile,
      oldBytes: record.oldBytes, targetBytes: record.targetBytes)
    return (original, target)
  }

  /// Preserve registration bytes except the existing CPU and memory numeric tokens.
  static func replacingHardware(
    _ original: Data, cpuCount: Int, memoryBytes: UInt64, host: HostResources
  ) throws -> Data {
    let before = try decodeConfiguration(original)
    var expected = before
    expected.cpuCount = cpuCount
    expected.memoryBytes = memoryBytes
    try ConfigurationValidator.validate(expected, host: host)
    var parser = GrowthFlatParser(bytes: Array(original), maximumKeys: 32, configurationBOM: true)
    let object = try parser.parse()
    let values = ["cpuCount": String(cpuCount), "memoryBytes": String(memoryBytes)]
    let changes = try values.map { key, value -> (Range<Int>, String) in
      guard case .number? = object.values[key], let span = object.ranges[key] else {
        throw diskGrowthError(.corruptMetadata)
      }
      return (span, value)
    }.sorted { $0.0.lowerBound > $1.0.lowerBound }
    var replacement = original
    for (span, token) in changes {
      let range = (original.startIndex + span.lowerBound)..<(original.startIndex + span.upperBound)
      replacement.replaceSubrange(range, with: token.utf8)
    }
    guard try decodeConfiguration(replacement) == expected else {
      throw diskGrowthError(.corruptMetadata)
    }
    return replacement
  }

  /// Replace only the admitted existing network string, including escaped keys.
  static func replacingNetwork(
    _ original: Data, mode: NetworkMode, host: HostResources,
    sharedPermission: SharedNetworkConfigurationPermission? = nil
  ) throws
    -> Data
  {
    let before = try decodeConfiguration(original)
    guard
      mode != .shared || before.guest == .linux && before.backend == .appleVz
        || sharedPermission?.allowsSharedConfiguration(before) == true
    else {
      throw diskGrowthError(.unsupported)
    }
    var expected = before
    expected.network = mode
    try ConfigurationValidator.validate(expected, host: host)
    if before.network == mode { return original }
    var parser = GrowthFlatParser(bytes: Array(original), maximumKeys: 32, configurationBOM: true)
    let object = try parser.parse()
    guard case .string? = object.values["network"], let span = object.ranges["network"] else {
      throw diskGrowthError(.corruptMetadata)
    }
    var replacement = original
    let range = (original.startIndex + span.lowerBound)..<(original.startIndex + span.upperBound)
    replacement.replaceSubrange(range, with: try JSONEncoder().encode(mode.rawValue))
    guard try decodeConfiguration(replacement) == expected else {
      throw diskGrowthError(.corruptMetadata)
    }
    return replacement
  }

  static func validateKernelArgumentReplacement(
    _ original: Data, _ replacement: Data, vmID: UUID
  ) throws -> Bool {
    let before = try decodeConfiguration(original)
    let after = try decodeConfiguration(replacement)
    guard before.id == vmID, before.guest == .linux, before.backend == .appleVz,
      before.boot == .linuxKernel, before.kernel != nil,
      after.kernelArguments.utf8.count <= 4096, !after.kernelArguments.contains("\0")
    else { throw diskGrowthError(.invalidConfiguration) }
    var expected = before
    expected.kernelArguments = after.kernelArguments
    var parser = GrowthFlatParser(bytes: Array(original), maximumKeys: 32, configurationBOM: true)
    let object = try parser.parse()
    func replacing(_ values: [String: String]) throws -> Data {
      let tokens = try values.map { key, value -> (Range<Int>, Data) in
        guard case .string? = object.values[key], let range = object.ranges[key] else {
          throw diskGrowthError(.corruptMetadata)
        }
        return (range, try JSONEncoder().encode(value))
      }.sorted { $0.0.lowerBound > $1.0.lowerBound }
      var exact = original
      for (range, token) in tokens {
        let span =
          (original.startIndex + range.lowerBound)..<(original.startIndex + range.upperBound)
        exact.replaceSubrange(span, with: token)
      }
      return exact
    }
    if after == expected,
      try replacing(["kernelArguments": after.kernelArguments]) == replacement
    {
      return false
    }
    guard let kernel = after.kernel, let initialRamdisk = after.initialRamdisk,
      before.kernel != nil, before.initialRamdisk != nil,
      [kernel, initialRamdisk].allSatisfy({
        $0.hasPrefix("/") && $0.utf8.count <= 4096
          && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      })
    else { throw diskGrowthError(.corruptMetadata) }
    expected.kernel = kernel
    expected.initialRamdisk = initialRamdisk
    guard after == expected,
      try replacing([
        "kernel": kernel, "initialRamdisk": initialRamdisk,
        "kernelArguments": after.kernelArguments,
      ]) == replacement
    else { throw diskGrowthError(.corruptMetadata) }
    return true
  }

  static func exclusive(_ bytes: Data, name: String, at anchor: Int32) throws {
    let fd = openat(anchor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw diskGrowthError(errno == EEXIST ? .busy : .storage) }
    defer { close(fd) }
    guard fchmod(fd, 0o600) == 0 else { throw diskGrowthError(.storage) }
    try write(bytes, fd: fd)
    guard fsync(fd) == 0 else { throw diskGrowthError(.storage) }
  }

  /// An earlier attempt may have committed this exact archive before failing to publish
  /// its new pending intent. Reuse preserves the actual safe inode; conflicts are never replaced.
  static func archiveCompleted(_ bytes: Data, name: String, at anchor: Int32) throws {
    guard !bytes.isEmpty, bytes.count <= DiskGrowthIntent.maximumBytes else {
      throw diskGrowthError(.corruptMetadata)
    }
    var fd = openat(
      anchor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    if fd >= 0 {
      do {
        guard fchmod(fd, 0o600) == 0 else { throw diskGrowthError(.storage) }
        try write(bytes, fd: fd)
      } catch {
        close(fd)
        throw error
      }
    } else {
      guard errno == EEXIST else { throw diskGrowthError(.storage) }
      fd = openat(anchor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { throw diskGrowthError(.storage) }
    }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, safe(before), before.st_size == bytes.count else {
      throw diskGrowthError(.storage)
    }
    try verifyArchive(fd, expected: before, bytes: bytes, name: name, at: anchor)
    guard fsync(fd) == 0, fsync(anchor) == 0 else { throw diskGrowthError(.storage) }
    try verifyArchive(fd, expected: before, bytes: bytes, name: name, at: anchor)
  }

  private static func verifyArchive(
    _ fd: Int32, expected: stat, bytes: Data, name: String, at anchor: Int32
  ) throws {
    var actual = Data(count: bytes.count)
    try actual.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = pread(
          fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset, off_t(offset))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw diskGrowthError(.storage) }
        offset += count
      }
    }
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0, fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      stable(expected, opened), stable(opened, named)
    else { throw diskGrowthError(.storage) }
    guard actual == bytes else { throw diskGrowthError(.corruptMetadata) }
  }

  static func atomic(
    _ bytes: Data, name: String, at anchor: Int32, afterRename: (() throws -> Void)? = nil
  ) throws {
    let temporary = ".disk-growth-\(UUID().uuidString).tmp"
    defer { unlinkat(anchor, temporary, 0) }
    try exclusive(bytes, name: temporary, at: anchor)
    guard renameat(anchor, temporary, anchor, name) == 0 else { throw diskGrowthError(.storage) }
    try afterRename?()
    guard fsync(anchor) == 0 else { throw diskGrowthError(.storage) }
    guard try readFile(name, at: anchor, limit: configurationLimit) == bytes else {
      throw diskGrowthError(.storage)
    }
  }

  private static func write(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw diskGrowthError(.storage) }
        offset += count
      }
    }
  }

  static func encode(_ record: DiskGrowthIntent) throws -> Data {
    func quoted(_ value: String) throws -> String {
      String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    var fields: [(String, String)] = [
      ("schemaVersion", String(record.schemaVersion)), ("vmID", try quoted(record.vmID.uuidString)),
      ("transactionID", try quoted(record.transactionID.uuidString)),
      ("state", try quoted(record.state.rawValue)),
      ("diskFile", try quoted(record.diskFile)),
      ("directoryDevice", String(record.directoryDevice)),
      ("directoryInode", String(record.directoryInode)), ("diskDevice", String(record.diskDevice)),
      ("diskInode", String(record.diskInode)), ("oldBytes", String(record.oldBytes)),
      ("targetBytes", String(record.targetBytes)),
      ("originalConfigurationSHA256", try quoted(record.originalConfigurationSHA256)),
      ("replacementConfigurationSHA256", try quoted(record.replacementConfigurationSHA256)),
      ("backupFile", try quoted(record.backupFile)), ("targetFile", try quoted(record.targetFile)),
    ]
    if record.schemaVersion == 2 {
      guard let directoryUUID = record.directoryVolumeUUID,
        let diskUUID = record.diskVolumeUUID, directoryUUID == diskUUID,
        directoryUUID.uuidString != "00000000-0000-0000-0000-000000000000",
        record.directoryDevice == record.diskDevice,
        record.directoryInode != 0, record.diskInode != 0
      else { throw diskGrowthError(.corruptMetadata) }
      fields.append(("directoryVolumeUUID", try quoted(directoryUUID.uuidString)))
      fields.append(("diskVolumeUUID", try quoted(diskUUID.uuidString)))
    } else {
      guard record.schemaVersion == 1, record.directoryVolumeUUID == nil,
        record.diskVolumeUUID == nil
      else { throw diskGrowthError(.corruptMetadata) }
    }
    let bytes = Data(
      ("{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}\n").utf8)
    guard bytes.count <= DiskGrowthIntent.maximumBytes else {
      throw diskGrowthError(.corruptMetadata)
    }
    return bytes
  }

  static func decode(_ bytes: Data) throws -> DiskGrowthIntent {
    guard !bytes.isEmpty, bytes.count <= DiskGrowthIntent.maximumBytes else {
      throw diskGrowthError(.corruptMetadata)
    }
    var parser = GrowthFlatParser(bytes: Array(bytes), maximumKeys: 17)
    let object = try parser.parse().values
    let legacyKeys: Set<String> = [
      "schemaVersion", "vmID", "transactionID", "state", "diskFile", "directoryDevice",
      "directoryInode", "diskDevice", "diskInode", "oldBytes", "targetBytes",
      "originalConfigurationSHA256", "replacementConfigurationSHA256", "backupFile", "targetFile",
    ]
    let schemaVersion: Int
    switch object["schemaVersion"] {
    case .number("1"):
      schemaVersion = 1
      guard Set(object.keys) == legacyKeys else { throw diskGrowthError(.corruptMetadata) }
    case .number("2"):
      schemaVersion = 2
      guard Set(object.keys) == legacyKeys.union(["directoryVolumeUUID", "diskVolumeUUID"]) else {
        throw diskGrowthError(.corruptMetadata)
      }
    default: throw diskGrowthError(.corruptMetadata)
    }
    func string(_ key: String) throws -> String {
      guard case .string(let value)? = object[key] else { throw diskGrowthError(.corruptMetadata) }
      return value
    }
    func unsigned(_ key: String) throws -> UInt64 {
      guard case .number(let text)? = object[key], let value = UInt64(text), String(value) == text
      else {
        throw diskGrowthError(.corruptMetadata)
      }
      return value
    }
    func device(_ key: String) throws -> Int32 {
      guard case .number(let text)? = object[key], let value = Int32(text), String(value) == text
      else {
        throw diskGrowthError(.corruptMetadata)
      }
      return value
    }
    let vmText = try string("vmID")
    let transactionText = try string("transactionID")
    guard let vmID = UUID(uuidString: vmText), vmID.uuidString == vmText,
      let transactionID = UUID(uuidString: transactionText),
      transactionID.uuidString == transactionText,
      let state = DiskGrowthIntent.State(rawValue: try string("state"))
    else { throw diskGrowthError(.corruptMetadata) }
    let originalHash = try string("originalConfigurationSHA256")
    let targetHash = try string("replacementConfigurationSHA256")
    guard
      [originalHash, targetHash].allSatisfy({
        $0.utf8.count == 64
          && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      })
    else {
      throw diskGrowthError(.corruptMetadata)
    }
    func volumeUUID(_ key: String) throws -> UUID? {
      guard schemaVersion == 2 else { return nil }
      let text = try string(key)
      guard let value = UUID(uuidString: text), value.uuidString == text,
        text != "00000000-0000-0000-0000-000000000000"
      else { throw diskGrowthError(.corruptMetadata) }
      return value
    }
    let record = try DiskGrowthIntent(
      schemaVersion: schemaVersion, vmID: vmID, transactionID: transactionID,
      state: state, diskFile: string("diskFile"),
      directoryVolumeUUID: volumeUUID("directoryVolumeUUID"),
      diskVolumeUUID: volumeUUID("diskVolumeUUID"),
      directoryDevice: device("directoryDevice"), directoryInode: unsigned("directoryInode"),
      diskDevice: device("diskDevice"), diskInode: unsigned("diskInode"),
      oldBytes: unsigned("oldBytes"), targetBytes: unsigned("targetBytes"),
      originalConfigurationSHA256: originalHash, replacementConfigurationSHA256: targetHash)
    guard safeDiskName(record.diskFile), record.oldBytes >= 1_073_741_824,
      record.oldBytes % 512 == 0,
      record.targetBytes > record.oldBytes, record.targetBytes <= 2_199_023_255_552,
      record.targetBytes % 512 == 0, try string("backupFile") == record.backupFile,
      try string("targetFile") == record.targetFile
    else { throw diskGrowthError(.corruptMetadata) }
    if schemaVersion == 2 {
      guard record.directoryVolumeUUID == record.diskVolumeUUID,
        record.directoryDevice == record.diskDevice,
        record.directoryInode != 0, record.diskInode != 0
      else { throw diskGrowthError(.corruptMetadata) }
    }
    return record
  }
}

/// Bounded flat scalar lexer with decoded duplicate-key rejection, including escaped aliases.
/// String decoding uses JSONDecoder on one bounded token, never an object graph.
private struct GrowthFlatParser {
  enum Value: Equatable {
    case string(String)
    case number(String)
    case null
  }
  struct Object {
    let values: [String: Value]
    let ranges: [String: Range<Int>]
  }
  let bytes: [UInt8]
  let maximumKeys: Int
  private var index = 0
  init(bytes: [UInt8], maximumKeys: Int, configurationBOM: Bool = false) {
    self.bytes = bytes
    self.maximumKeys = maximumKeys
    if configurationBOM, bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
  }

  mutating func parse() throws -> Object {
    var values: [String: Value] = [:]
    var ranges: [String: Range<Int>] = [:]
    try consume(123)
    repeat {
      guard values.count < maximumKeys else { throw diskGrowthError(.corruptMetadata) }
      let key = try string()
      guard values[key] == nil else { throw diskGrowthError(.corruptMetadata) }
      try consume(58)
      whitespace()
      let start = index
      let value: Value
      if index < bytes.count, bytes[index] == 34 {
        value = .string(try string())
      } else if index + 4 <= bytes.count, Array(bytes[index..<index + 4]) == Array("null".utf8) {
        index += 4
        value = .null
      } else {
        if index < bytes.count, bytes[index] == 45 { index += 1 }
        let digits = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        guard index > digits else { throw diskGrowthError(.corruptMetadata) }
        value = .number(String(decoding: bytes[start..<index], as: UTF8.self))
      }
      values[key] = value
      ranges[key] = start..<index
      whitespace()
      guard index < bytes.count else { throw diskGrowthError(.corruptMetadata) }
      if bytes[index] == 125 {
        index += 1
        whitespace()
        guard index == bytes.count else { throw diskGrowthError(.corruptMetadata) }
        return Object(values: values, ranges: ranges)
      }
      try consume(44)
    } while true
  }

  private mutating func string() throws -> String {
    whitespace()
    let start = index
    try consume(34)
    var escaped = false
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      guard byte >= 32 else { throw diskGrowthError(.corruptMetadata) }
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) } catch
        { throw diskGrowthError(.corruptMetadata) }
      }
    }
    throw diskGrowthError(.corruptMetadata)
  }

  private mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard index < bytes.count, bytes[index] == byte else { throw diskGrowthError(.corruptMetadata) }
    index += 1
  }
  private mutating func whitespace() {
    while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
}

func diskGrowthError(_ code: VMError.Code) -> VMError {
  VMError(
    code, "Disk growth could not be confirmed.",
    recovery:
      "Preserve disk, configuration and transaction files. Use explicit validated recovery; never shrink, retry or roll back an uncertain attempt automatically."
  )
}
