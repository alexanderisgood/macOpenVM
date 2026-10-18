// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

public struct DiskUsage: Codable, Equatable, Sendable {
  public let virtualBytes: UInt64
  public let allocatedBytes: UInt64
}

public enum WriterStatus: String, Codable, Sendable {
  case missing, available, held, unavailable
}

/// Metadata only; never includes a path, identity bytes or file contents.
public struct VMFileStatus: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case missing, regular, directory, symlink, other, unreadable
  }
  public let kind: Kind
  public let bytes: UInt64?
  public let links: UInt64?
  public let ownedByCurrentUser: Bool?
  public let otherWriteBits: Bool?
}

/// Lifetime lock for cooperating macOpenVM writers. Lockfiles are never unlinked.
public final class VMLock: Sendable {
  /// Owns a duplicate of the same locked open-file description, independently of VMLock.
  /// The descriptor is borrowed: never close, unlock or change its flags yourself.
  /// Retain this wrapper through an asynchronous spawn, with an explicit
  /// withExtendedLifetime use after the spawn returns, before releasing it.
  public final class InheritedLease: Sendable {
    public let descriptor: Int32

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

    // Closing one reference preserves the shared lock while other references remain.
    deinit { close(descriptor) }
  }

  private let descriptor: Int32
  private let directoryDescriptor: Int32
  private let directoryPath: String
  private let expectedVMID: UUID?
  private let growthRecoveryID: UUID?
  private let runtimeReservation = RuntimeIntentReservation()
  public convenience init(directory: URL, expectedVMID: UUID? = nil) throws {
    try self.init(directory: directory, expectedVMID: expectedVMID, growthRecoveryID: nil)
  }

  package convenience init(existingDirectory directory: URL, expectedVMID: UUID) throws {
    try self.init(
      directory: directory, expectedVMID: expectedVMID, growthRecoveryID: nil,
      requireExistingLock: true)
  }

  private init(
    directory: URL, expectedVMID: UUID?, growthRecoveryID: UUID?, requireExistingLock: Bool = false
  ) throws {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), !directory.path.contains("\0")
    else { throw storageError("Writer ownership requires a local absolute VM directory.") }
    directoryPath = directory.standardizedFileURL.path
    self.expectedVMID = expectedVMID
    self.growthRecoveryID = growthRecoveryID
    let parent = open(
      directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard parent >= 0 else { throw storageError("Cannot open the VM directory safely.") }
    var retainedParent = false
    defer { if !retainedParent { close(parent) } }
    var directoryInfo = stat()
    guard fstat(parent, &directoryInfo) == 0, isSafeWriterDirectory(directoryInfo)
    else {
      throw storageError("The VM directory must be owned by you and not writable by others.")
    }
    let fd = openat(
      parent, "writer.lock",
      O_RDWR | (requireExistingLock ? 0 : O_CREAT) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
      S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw storageError("Cannot open the VM writer lock.") }
    var info = stat()
    guard fstat(fd, &info) == 0, isSafeWriterLock(info)
    else {
      close(fd)
      throw storageError("The writer lock must be a private regular file without aliases.")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let failure = errno
      close(fd)
      guard failure == EWOULDBLOCK else { throw storageError("The VM writer lock failed.") }
      throw VMError(
        .busy, "This VM is already owned by another writer.",
        recovery: "Close its other session before trying again.")
    }
    do {
      try RuntimeIntentIO.requireAdmission(at: parent, expectedVMID: expectedVMID)
      if let growthRecoveryID, let expectedVMID {
        try DiskGrowthIO.requireRecoveryAdmission(
          at: parent, vmID: expectedVMID, transactionID: growthRecoveryID)
      } else {
        try DiskGrowthIO.requireAdmission(at: parent, expectedVMID: expectedVMID)
      }
    } catch {
      close(fd)
      throw error
    }
    descriptor = fd
    directoryDescriptor = parent
    retainedParent = true
  }

  func reserveRuntimeSession(forVMID vmID: UUID) throws -> UUID {
    guard growthRecoveryID == nil, expectedVMID == nil || expectedVMID == vmID else {
      throw storageError("The requested runtime does not match the admitted VM identity.")
    }
    return try runtimeReservation.reserve(preventsInheritance: false)
  }

  func reserveDiskGrowth(forVMID vmID: UUID, recovering transactionID: UUID? = nil) throws -> UUID {
    guard expectedVMID == nil || expectedVMID == vmID,
      growthRecoveryID == transactionID
    else { throw diskGrowthError(.busy) }
    return try runtimeReservation.reserve(preventsInheritance: true)
  }

  func reserveConfigurationChange(forVMID vmID: UUID) throws {
    guard growthRecoveryID == nil, expectedVMID == vmID else { throw diskGrowthError(.busy) }
    _ = try runtimeReservation.reserve(preventsInheritance: true)
  }

  /// A recoverable move holds this owner, but can never lend it to a new runtime.
  func reserveTrash(forVMID vmID: UUID) throws {
    guard growthRecoveryID == nil, expectedVMID == vmID else {
      throw storageError("The trash reservation does not match this VM writer.")
    }
    _ = try runtimeReservation.reserve(preventsInheritance: true)
  }

  static func diskGrowthRecovery(in directory: URL, vmID: UUID, transactionID: UUID) throws
    -> VMLock
  {
    try VMLock(directory: directory, expectedVMID: vmID, growthRecoveryID: transactionID)
  }

  /// The synchronous borrow retains this owner; commits stay on the opened directory anchor.
  func withRuntimeIntentDirectory<Result>(_ body: (Int32) throws -> Result) throws -> Result {
    try RuntimeIntentIO.validateDirectory(directoryDescriptor)
    guard retainedWriterIdentityMatches() else {
      throw storageError("The retained writer directory or lock identity changed.")
    }
    let result = try body(directoryDescriptor)
    try RuntimeIntentIO.validateDirectory(directoryDescriptor)
    guard retainedWriterIdentityMatches() else {
      throw storageError("Writer ownership changed during the anchored metadata operation.")
    }
    return result
  }

  private func retainedWriterIdentityMatches() -> Bool {
    var anchor = stat()
    var selected = stat()
    var held = stat()
    var named = stat()
    guard fstat(directoryDescriptor, &anchor) == 0, lstat(directoryPath, &selected) == 0,
      isSafeWriterDirectory(selected), anchor.st_dev == selected.st_dev,
      anchor.st_ino == selected.st_ino, fstat(descriptor, &held) == 0,
      fstatat(directoryDescriptor, "writer.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
      isSafeWriterLock(held), isSafeWriterLock(named),
      held.st_dev == named.st_dev, held.st_ino == named.st_ino
    else { return false }
    return true
  }

  /// Duplicates the owned lease atomically with CLOEXEC; the parent's flags are untouched.
  /// A public spawn file action can map this copy into a child. This alone does not establish
  /// that an executable retains the copy or that an orphaned runtime is safe to reuse.
  public func duplicateForInheritance() throws -> InheritedLease {
    guard growthRecoveryID == nil else { throw diskGrowthError(.busy) }
    return try runtimeReservation.withInheritanceAllowed { try duplicateOwnedLease() }
  }

  private func duplicateOwnedLease() throws -> InheritedLease {
    var original = stat()
    let parentFlags = fcntl(descriptor, F_GETFD)
    guard parentFlags >= 0, parentFlags & FD_CLOEXEC != 0,
      fstat(descriptor, &original) == 0, isSafeWriterLock(original)
    else { throw storageError("The writer lease cannot be duplicated safely.") }

    let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
    guard copy >= 0 else { throw storageError("Cannot duplicate the VM writer lease.") }
    var duplicate = stat()
    let copyFlags = fcntl(copy, F_GETFD)
    guard copy >= 3, copyFlags >= 0, copyFlags & FD_CLOEXEC != 0,
      fstat(copy, &duplicate) == 0, isSafeWriterLock(duplicate),
      duplicate.st_dev == original.st_dev, duplicate.st_ino == original.st_ino,
      fcntl(descriptor, F_GETFD) == parentFlags
    else {
      close(copy)
      throw storageError("The duplicated writer lease has unsafe metadata.")
    }
    return InheritedLease(descriptor: copy)
  }

  /// Associates advisory metadata with the same cooperating VM owner.
  public func owns(_ directory: URL) -> Bool {
    directory.isFileURL
      && (directory.host == nil || directory.host == "" || directory.host == "localhost")
      && !directory.path.contains("\0")
      && directory.standardizedFileURL.path == directoryPath
      && retainedWriterIdentityMatches()
  }
  deinit {
    close(descriptor)
    close(directoryDescriptor)
  }
}

/// The one-shot purpose is lock-protected. A bounded synchronous descriptor duplication
/// holds that same lock so it cannot cross a growth reservation; no actor suspension occurs.
private final class RuntimeIntentReservation: @unchecked Sendable {
  private let mutex = NSLock()
  private var attempted = false
  private var preventsInheritance = false
  private var inheritanceIssued = false

  func reserve(preventsInheritance: Bool) throws -> UUID {
    mutex.lock()
    defer { mutex.unlock() }
    guard !attempted, !preventsInheritance || !inheritanceIssued else {
      throw VMError(
        .busy, "An operation was already reserved or this writer lease was inherited.",
        recovery:
          "Preserve VM files and the current owner. Do not reuse a reserved writer or assume an inherited lease is closed."
      )
    }
    attempted = true
    self.preventsInheritance = preventsInheritance
    return UUID()
  }

  func withInheritanceAllowed<Result>(_ body: () throws -> Result) throws -> Result {
    mutex.lock()
    defer { mutex.unlock() }
    guard !preventsInheritance else { throw diskGrowthError(.busy) }
    let result = try body()
    inheritanceIssued = true
    return result
  }
}

/// POSIX I/O is kept off the UI actor. New files use exclusive creation and no-follow.
public actor VMFiles {
  var diskGrowthFault: DiskGrowthFaultPoint?
  public init() {}

  func injectDiskGrowthFault(_ point: DiskGrowthFaultPoint?) { diskGrowthFault = point }

  /// No-follow stat supports diagnostics even for FIFO/symlink inputs without opening them.
  public func status(at url: URL) -> VMFileStatus {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      return VMFileStatus(
        kind: errno == ENOENT ? .missing : .unreadable, bytes: nil, links: nil,
        ownedByCurrentUser: nil, otherWriteBits: nil)
    }
    let kind: VMFileStatus.Kind
    switch info.st_mode & S_IFMT {
    case S_IFREG: kind = .regular
    case S_IFDIR: kind = .directory
    case S_IFLNK: kind = .symlink
    default: kind = .other
    }
    return VMFileStatus(
      kind: kind, bytes: info.st_size >= 0 ? UInt64(info.st_size) : nil,
      links: UInt64(info.st_nlink), ownedByCurrentUser: info.st_uid == geteuid(),
      otherWriteBits: info.st_mode & (S_IWGRP | S_IWOTH) != 0)
  }

  /// Read-only point-in-time cooperating ownership probe. Never creates a missing lock.
  public func writerStatus(in directory: URL) -> WriterStatus {
    let parent = open(
      directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard parent >= 0 else { return .unavailable }
    defer { close(parent) }
    var directoryInfo = stat()
    guard fstat(parent, &directoryInfo) == 0, isSafeWriterDirectory(directoryInfo) else {
      return .unavailable
    }
    let fd = openat(parent, "writer.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return errno == ENOENT ? .missing : .unavailable }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, isSafeWriterLock(info) else { return .unavailable }
    guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
      return errno == EWOULDBLOCK ? .held : .unavailable
    }
    return .available
  }

  public func createDirectory(_ url: URL) throws {
    guard mkdir(url.path, S_IRWXU) == 0 else {
      throw storageError("The VM directory must be new and writable.")
    }
    try syncDirectory(url.deletingLastPathComponent())
  }

  /// Flush a regular, non-symlink identity file before committing its VM configuration.
  public func syncRegularFile(at url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw storageError("Cannot open a platform identity file for flush.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, isSafeWritableFile(info), fsync(fd) == 0 else {
      throw storageError("Platform identity flush failed; preserve the incomplete new VM.")
    }
  }

  public func createSparseDisk(at url: URL, bytes: UInt64) throws {
    guard bytes > 0, bytes <= UInt64(Int64.max) else { throw storageError("Invalid disk size.") }
    let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw storageError("Disk creation failed; existing disks are never truncated.")
    }
    var success = false
    defer {
      close(fd)
      if !success { unlink(url.path) }
    }
    guard ftruncate(fd, off_t(bytes)) == 0, fsync(fd) == 0 else {
      throw storageError("Disk allocation could not be committed.")
    }
    success = true
    try syncDirectory(url.deletingLastPathComponent())
  }

  public func inspectDisk(at url: URL) throws -> DiskUsage {
    try inspectFile(at: url, writable: false)
  }

  /// Point-in-time readability for a read-only data image. Aliases may be shared;
  /// this does not authenticate contents or retain identity through a later runtime.
  public func inspectReadOnlyImage(at url: URL) throws -> DiskUsage {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
      !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw storageError("Support media requires a bounded local image location.") }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw storageError("Cannot open read-only support media.") }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0, before.st_size <= 2_199_023_255_552, before.st_size % 512 == 0,
      before.st_blocks >= 0, UInt64(before.st_blocks) <= UInt64.max / 512
    else {
      throw storageError("Support media must be a nonempty regular image aligned to 512 bytes.")
    }
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
        && first.st_blocks == second.st_blocks
        && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
        && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
        && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
        && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    guard count == 1, fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
      unchanged(before, opened), unchanged(opened, named)
    else { throw storageError("Support-media readability or file identity changed.") }
    return DiskUsage(
      virtualBytes: UInt64(before.st_size), allocatedBytes: UInt64(before.st_blocks) * 512)
  }

  /// Preflight for disk/firmware paths a backend will write. Read-only media may have aliases.
  public func inspectWritableFile(at url: URL) throws -> DiskUsage {
    try inspectFile(at: url, writable: true)
  }

  private func inspectFile(at url: URL, writable: Bool) throws -> DiskUsage {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw storageError("Cannot inspect a regular VM disk.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
      throw storageError("Disk must be a regular file.")
    }
    guard !writable || isSafeWritableFile(info) else {
      throw storageError(
        "Writable VM files must be owned by you, unshared and not writable by others.")
    }
    return DiskUsage(
      virtualBytes: UInt64(info.st_size), allocatedBytes: UInt64(info.st_blocks) * 512)
  }

  public func readMetadata(at url: URL, limit: Int = 65_536) throws -> Data {
    guard limit >= 0 else { throw storageError("Metadata limit is invalid.") }
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw storageError("Cannot read VM metadata.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
      info.st_size <= limit
    else { throw storageError("Metadata exceeds its limit or is not a regular file.") }
    var data = Data(count: Int(info.st_size))
    let count = data.withUnsafeMutableBytes { buffer in
      guard let address = buffer.baseAddress else { return 0 }
      return Darwin.read(fd, address, buffer.count)
    }
    guard count == data.count else {
      throw storageError("Metadata changed or could not be completely read.")
    }
    return data
  }

  /// Exclusive temp + flush + same-directory rename + directory flush. Failure after rename
  /// can be ambiguous; it does not establish that the original bytes were retained.
  public func atomicWrite(_ data: Data, at url: URL) throws {
    guard data.count <= 65_536 else { throw storageError("Metadata exceeds its limit.") }
    let temp = url.deletingLastPathComponent().appendingPathComponent(
      ".metadata-\(UUID().uuidString)")
    let fd = open(
      temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw storageError("Cannot create metadata transaction.") }
    defer {
      close(fd)
      unlink(temp.path)
    }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        guard let base = buffer.baseAddress else { throw storageError("Invalid metadata buffer.") }
        let result = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else {
          throw storageError("Metadata write failed; old metadata retained.")
        }
        offset += result
      }
    }
    guard fsync(fd) == 0 else {
      throw storageError("Metadata flush failed; old metadata retained.")
    }
    guard rename(temp.path, url.path) == 0 else {
      throw storageError("Metadata commit failed; old metadata retained.")
    }
    try syncDirectory(url.deletingLastPathComponent())
  }

  /// Immutable bounded history archive. Never replaces an existing file or alias.
  public func writeNewMetadata(_ data: Data, at url: URL) throws {
    guard data.count <= 65_536 else { throw storageError("Metadata exceeds its limit.") }
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw storageError("History archive already exists or cannot be created.")
    }
    defer { close(fd) }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        guard let base = buffer.baseAddress else { throw storageError("Invalid metadata buffer.") }
        let result = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else {
          throw storageError("History archive write failed; preserve partial files.")
        }
        offset += result
      }
    }
    guard fsync(fd) == 0 else {
      throw storageError("History archive flush failed; preserve its files.")
    }
    try syncDirectory(url.deletingLastPathComponent())
  }

  /// Currently available filesystem bytes. This read-only sample reserves no
  /// space and does not establish destination write or ACL authorization.
  public func availableStorageCapacity(at directory: URL) throws -> UInt64 {
    try DestinationStorageCapacity.availableBytes(at: directory)
  }

  public func checkFreeSpace(at directory: URL, reserveBytes: UInt64 = 1_073_741_824) throws {
    guard try availableStorageCapacity(at: directory) >= reserveBytes else {
      throw storageError("Insufficient free space for safe creation.")
    }
  }

  private func syncDirectory(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
    guard fd >= 0 else { throw storageError("Cannot open metadata directory for flush.") }
    defer { close(fd) }
    guard fsync(fd) == 0 else {
      throw storageError("Directory flush failed; inspect before retrying.")
    }
  }
}

private func isSafeWritableFile(_ info: stat) -> Bool {
  (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
    && info.st_mode & (S_IWGRP | S_IWOTH) == 0
}

private func isSafeWriterDirectory(_ info: stat) -> Bool {
  (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
    && info.st_mode & (S_IWGRP | S_IWOTH) == 0
}

private func isSafeWriterLock(_ info: stat) -> Bool {
  isSafeWritableFile(info) && info.st_mode & (S_IRWXG | S_IRWXO) == 0
}

private func storageError(_ message: String) -> VMError {
  VMError(
    .storage, message,
    recovery: "Check storage permissions and free space. Preserve existing VM files.")
}
