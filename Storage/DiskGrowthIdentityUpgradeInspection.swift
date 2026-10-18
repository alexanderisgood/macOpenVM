// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// A point-in-time observation, never a writer lease or a serialized upgrade permit.
package struct DiskGrowthIdentityUpgradeObservation: Sendable {
  package enum Kind: Sendable {
    case notNeeded, pendingGrowth, alreadyStable, eligibleAtCheck, legacyProofUnavailable
  }
  package let kind: Kind
  package let snapshot: DiskGrowthIdentityUpgradeSnapshot?
  package let sourceSchemaVersion: Int?
  package init(
    kind: Kind, snapshot: DiskGrowthIdentityUpgradeSnapshot?, sourceSchemaVersion: Int? = nil
  ) {
    self.kind = kind
    self.snapshot = snapshot
    self.sourceSchemaVersion = sourceSchemaVersion
  }
}

/// Exact stopped-state bytes and file bindings captured from one read-only directory anchor.
/// Core must interpret runtime history; Storage does not infer stopped state from a free lock.
package struct DiskGrowthIdentityUpgradeSnapshot: Equatable, Sendable {
  package let configuration: Data
  package let journal: Data
  package let record: DiskGrowthIntent
  package let history: Data?
  package let intent: RuntimeIntent?
  private let entries: [DiskGrowthUpgradeEntry]
  private let disk: DiskGrowthUpgradeFact
  private let directoryDevice: Int32
  private let directoryInode: UInt64
  private let directoryMode: UInt16
  private let directoryOwner: UInt32
  private let directoryGroup: UInt32
  private let volumeUUID: UUID

  fileprivate init(at anchor: Int32, record: DiskGrowthIntent) throws {
    try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: record.vmID)
    let names = [
      ("configuration.json", 65_536), (DiskGrowthIntent.filename, DiskGrowthIntent.maximumBytes),
      (record.backupFile, 65_536), (record.targetFile, 65_536),
      ("runtime.json", 4096), (RuntimeIntent.filename, 4096),
    ]
    entries = try names.map { try DiskGrowthIdentityUpgradeIO.entry($0.0, at: anchor, limit: $0.1) }
    guard let configuration = entries[0].bytes, let journal = entries[1].bytes,
      try DiskGrowthIO.decode(journal) == record
    else { throw diskGrowthError(.corruptMetadata) }
    self.configuration = configuration
    self.journal = journal
    self.record = record
    history = entries[4].bytes
    intent = try RuntimeIntentIO.read(at: anchor)
    // Bind the independently decoded intent to the exact bytes in this observation.
    guard
      try DiskGrowthIdentityUpgradeIO.entry(RuntimeIntent.filename, at: anchor, limit: 4096)
        == entries[5]
    else { throw diskGrowthError(.busy) }
    let fd = try DiskGrowthIO.openDisk(record.diskFile, at: anchor, writable: false)
    defer { close(fd) }
    let raw = try DiskGrowthIO.verifyDisk(record, fd: fd, at: anchor, allowed: [record.targetBytes])
    disk = DiskGrowthUpgradeFact(raw)
    let directoryUUID = try DiskGrowthVolumeIdentity.read(from: anchor)
    let diskUUID = try DiskGrowthVolumeIdentity.read(from: fd)
    var parent = stat()
    guard fstat(anchor, &parent) == 0, parent.st_dev == raw.st_dev,
      directoryUUID == diskUUID
    else { throw diskGrowthError(.storage) }
    directoryDevice = parent.st_dev
    directoryInode = parent.st_ino
    directoryMode = parent.st_mode
    directoryOwner = parent.st_uid
    directoryGroup = parent.st_gid
    volumeUUID = directoryUUID
    // File bytes, bindings and timestamps must remain stable across the whole capture.
    guard
      try names.map({ try DiskGrowthIdentityUpgradeIO.entry($0.0, at: anchor, limit: $0.1) })
        == entries,
      DiskGrowthUpgradeFact(try DiskGrowthIO.diskInfo(fd, name: record.diskFile, at: anchor))
        == disk
    else { throw diskGrowthError(.busy) }
    try DiskGrowthIdentityUpgradeIO.requireSafeExistingWriter(at: anchor)
    writer = try DiskGrowthIdentityUpgradeIO.writerFact(at: anchor)
    let archive = "disk-growth-\(record.transactionID.uuidString)-schema1-completed.json"
    if record.schemaVersion == 1,
      let prior = try DiskGrowthIdentityUpgradeIO.entry(
        archive, at: anchor, limit: DiskGrowthIntent.maximumBytes
      ).bytes
    {
      guard prior == journal else { throw diskGrowthError(.corruptMetadata) }
    }
  }

  private let writer: DiskGrowthUpgradeFact

  /// Journal replacement is the sole intended metadata change. Directory timestamps
  /// can change when this transaction creates its durable archive and temporary file.
  func preservesStoppedState(of prior: Self) -> Bool {
    configuration == prior.configuration && history == prior.history && intent == prior.intent
      && entries.enumerated().allSatisfy {
        $0.offset == 1 || $0.element == prior.entries[$0.offset]
      }
      && disk == prior.disk && writer == prior.writer
      && directoryDevice == prior.directoryDevice && directoryInode == prior.directoryInode
      && directoryMode == prior.directoryMode && directoryOwner == prior.directoryOwner
      && directoryGroup == prior.directoryGroup && volumeUUID == prior.volumeUUID
  }
}

extension VMFiles {
  /// No lock creation, exclusive acquisition, archive, file mutation, or runtime authority.
  package func inspectDiskGrowthIdentityUpgrade(in directory: URL) throws
    -> DiskGrowthIdentityUpgradeObservation
  {
    let anchor = try DiskGrowthIO.openDirectory(directory)
    defer { close(anchor) }
    guard let record = try DiskGrowthIO.read(at: anchor) else {
      return .init(kind: .notNeeded, snapshot: nil)
    }
    guard record.state == .completed else {
      return .init(kind: .pendingGrowth, snapshot: nil, sourceSchemaVersion: record.schemaVersion)
    }
    if record.schemaVersion == 1 {
      // A changed mount number has no legacy same-volume proof. Never waive it.
      var parent = stat()
      let fd = try DiskGrowthIO.openDisk(record.diskFile, at: anchor, writable: false)
      defer { close(fd) }
      let raw = try DiskGrowthIO.diskInfo(fd, name: record.diskFile, at: anchor)
      guard fstat(anchor, &parent) == 0 else { throw diskGrowthError(.storage) }
      guard parent.st_dev == record.directoryDevice, parent.st_ino == record.directoryInode,
        raw.st_dev == record.diskDevice, raw.st_ino == record.diskInode
      else { return .init(kind: .legacyProofUnavailable, snapshot: nil) }
    }
    let snapshot = try DiskGrowthIdentityUpgradeIO.snapshot(at: anchor, record: record)
    return .init(
      kind: record.schemaVersion == 1 ? .eligibleAtCheck : .alreadyStable, snapshot: snapshot)
  }
}

enum DiskGrowthIdentityUpgradeIO {
  static func snapshot(at anchor: Int32, record: DiskGrowthIntent) throws
    -> DiskGrowthIdentityUpgradeSnapshot
  {
    try DiskGrowthIdentityUpgradeSnapshot(at: anchor, record: record)
  }

  fileprivate static func entry(_ name: String, at anchor: Int32, limit: Int) throws
    -> DiskGrowthUpgradeEntry
  {
    var before = stat()
    guard fstatat(anchor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
      guard errno == ENOENT else { throw diskGrowthError(.storage) }
      return .init(bytes: nil, fact: nil)
    }
    let bytes = try DiskGrowthIO.readFile(name, at: anchor, limit: limit)
    var after = stat()
    guard fstatat(anchor, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
      DiskGrowthIO.stable(before, after)
    else { throw diskGrowthError(.busy) }
    return .init(bytes: bytes, fact: DiskGrowthUpgradeFact(after))
  }

  static func requireSafeExistingWriter(at anchor: Int32) throws {
    _ = try writerFact(at: anchor)
  }

  fileprivate static func writerFact(at anchor: Int32) throws -> DiskGrowthUpgradeFact {
    let fd = openat(anchor, "writer.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw diskGrowthError(.storage) }
    defer { close(fd) }
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == geteuid(), opened.st_nlink == 1,
      opened.st_mode & (S_IRWXG | S_IRWXO) == 0,
      fstatat(anchor, "writer.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
      DiskGrowthUpgradeFact(opened) == DiskGrowthUpgradeFact(named)
    else { throw diskGrowthError(.storage) }
    return DiskGrowthUpgradeFact(opened)
  }
}

private struct DiskGrowthUpgradeEntry: Equatable, Sendable {
  let bytes: Data?
  let fact: DiskGrowthUpgradeFact?
}

private struct DiskGrowthUpgradeFact: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let mode: UInt16
  let owner: UInt32
  let group: UInt32
  let links: UInt16
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
    mode = info.st_mode
    owner = info.st_uid
    group = info.st_gid
    links = info.st_nlink
    size = info.st_size
    modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    changedSeconds = Int64(info.st_ctimespec.tv_sec)
    changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
  }
}
