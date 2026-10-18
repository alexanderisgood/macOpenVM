// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import VMCore
import VMStorage

actor RegisteredWindowsRuntimeStore: RecordedRuntimeStore {
  private let configuration: VMConfiguration
  private let lock: VMLock
  private let files = VMFiles()
  private let synchronize: @Sendable (Int32) throws -> Void
  private var permit: RuntimeSessionPermit?
  private var attempted = false

  init(
    configuration: VMConfiguration, lock: VMLock,
    synchronize: @escaping @Sendable (Int32) throws -> Void = RegisteredWindowsPlatformFlush.sync
  ) throws {
    try ConfigurationValidator.validate(configuration, host: .current)
    try VMFiles.validateCloneDiskName(configuration.diskFile)
    guard configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi,
      !["uefi-vars.json", "qemu-platform.json", "tpm-state"].contains(
        configuration.diskFile.lowercased())
    else { throw RegisteredWindowsPlatformFlush.failure() }
    self.configuration = configuration
    self.lock = lock
    self.synchronize = synchronize
  }

  func beginOwnership(in directory: URL, vmID: UUID, lock: VMLock) async throws
    -> RuntimeSessionPermit
  {
    guard !attempted, self.lock === lock, vmID == configuration.id, lock.owns(directory)
    else { throw RegisteredWindowsPlatformFlush.failure() }
    attempted = true
    let actual = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: lock)
    permit = actual
    try actual.withSettlementDirectory(in: directory) {
      try RegisteredWindowsPlatformFlush.verifyConfiguration(configuration, at: $0)
    }
    return actual
  }
  func commitOwnership(in directory: URL, receipt: RuntimeSettlementReceipt) async throws {
    guard let permit, receipt.permit === permit, permit.owns(lock), lock.owns(directory)
    else { throw RegisteredWindowsPlatformFlush.failure() }
    try permit.withSettlementDirectory(in: directory) {
      try RegisteredWindowsPlatformFlush.flush(
        configuration, at: $0,
        launchDisposition: receipt.backend.launchDisposition, synchronize: synchronize)
    }
    try await files.commitRuntimeSettlement(in: directory, receipt: receipt)
  }
  func status(at url: URL) async -> VMFileStatus { await files.status(at: url) }
  func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    try await files.readRuntimeIntent(in: directory)
  }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    try await files.writeNewMetadata(data, at: url)
  }
  func atomicWrite(_ data: Data, at url: URL) async throws {
    try await files.atomicWrite(data, at: url)
  }
}

enum RegisteredWindowsPlatformFlush {
  private struct File {
    let name: String, parent: Int32, fd: Int32
    let before: stat
    func verify() throws {
      var opened = stat()
      var named = stat()
      guard fstat(fd, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
        RegisteredWindowsPlatformFlush.stable(before, opened),
        RegisteredWindowsPlatformFlush.stable(opened, named)
      else { throw RegisteredWindowsPlatformFlush.failure() }
    }
  }
  static func verifyConfiguration(_ configuration: VMConfiguration, at anchor: Int32) throws {
    let file = try openFile("configuration.json", at: anchor, bytes: 1...65_536)
    defer { close(file.fd) }
    let bytes =
      try FileHandle(fileDescriptor: file.fd, closeOnDealloc: false).read(upToCount: 65_537)
      ?? Data()
    guard bytes.count == file.before.st_size, try ConfigurationCodec.decode(bytes) == configuration
    else { throw failure() }
    try file.verify()
  }
  static func flush(
    _ configuration: VMConfiguration, at anchor: Int32, launchDisposition: BackendLaunchDisposition,
    synchronize: (Int32) throws -> Void = sync
  ) throws {
    try verifyConfiguration(configuration, at: anchor)
    var opened: [File] = []
    defer { for file in opened { close(file.fd) } }
    opened.append(
      try openFile(
        configuration.diskFile, at: anchor, bytes: configuration.diskBytes...configuration.diskBytes
      ))
    opened.append(try openFile("uefi-vars.json", at: anchor, bytes: 0...1_048_576))
    let tpm = openat(
      anchor, "tpm-state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard tpm >= 0 else { throw failure() }
    defer { close(tpm) }
    var before = stat()
    var named = stat()
    var after = stat()
    guard fstat(tpm, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
      before.st_uid == geteuid(), before.st_mode & 0o7777 == 0o700
    else { throw failure() }
    let names = try members(tpm)
    let fullTPM = names == Set([".lock", "tpm2-00.permall"])
    switch launchDisposition {
    case .neverInvoked: guard names.isEmpty else { throw failure() }
    case .failedAttempt: guard names.isEmpty || fullTPM else { throw failure() }
    case .completedAttempt: guard fullTPM else { throw failure() }
    }
    for name in names.sorted() {
      opened.append(try openFile(name, at: tpm, bytes: name == ".lock" ? 0...0 : 0...16_777_216))
    }
    for file in opened {
      try file.verify()
      try synchronize(file.fd)
      try file.verify()
    }
    try synchronize(tpm)
    try synchronize(anchor)
    guard fstat(tpm, &after) == 0, fstatat(anchor, "tpm-state", &named, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, named), try members(tpm) == names
    else { throw failure() }
    for file in opened { try file.verify() }
    try verifyConfiguration(configuration, at: anchor)
  }
  private static func openFile(_ name: String, at anchor: Int32, bytes: ClosedRange<UInt64>) throws
    -> File
  {
    let fd = openat(anchor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw failure() }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
      before.st_size >= 0, bytes.contains(UInt64(before.st_size))
    else {
      close(fd)
      throw failure()
    }
    let result = File(name: name, parent: anchor, fd: fd, before: before)
    do {
      try result.verify()
      return result
    } catch {
      close(fd)
      throw error
    }
  }
  private static func members(_ fd: Int32) throws -> Set<String> {
    let copy = fcntl(fd, F_DUPFD_CLOEXEC, 3)
    guard copy >= 0 else { throw failure() }
    guard let entries = fdopendir(copy) else {
      close(copy)
      throw failure()
    }
    defer { closedir(entries) }
    rewinddir(entries)
    var result: Set<String> = []
    while true {
      errno = 0
      guard let entry = readdir(entries) else {
        guard errno == 0 else { throw failure() }
        return result
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      guard result.count < 2, [".lock", "tpm2-00.permall"].contains(name),
        result.insert(name).inserted
      else { throw failure() }
    }
  }
  private static func stable(_ first: stat, _ last: stat) -> Bool {
    first.st_dev == last.st_dev && first.st_ino == last.st_ino && first.st_mode == last.st_mode
      && first.st_uid == last.st_uid && first.st_nlink == last.st_nlink
      && first.st_size == last.st_size
      && first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec
      && first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec
      && first.st_ctimespec.tv_sec == last.st_ctimespec.tv_sec
      && first.st_ctimespec.tv_nsec == last.st_ctimespec.tv_nsec
  }
  static func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw failure() } }
  static func failure() -> VMError {
    VMError(
      .storage, "Registered Windows files could not be flushed safely.",
      recovery:
        "Retain the actual owner, writer and unsettled intent; preserve all files for inspection.")
  }
}
