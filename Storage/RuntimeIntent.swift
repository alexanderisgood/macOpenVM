// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// A bounded ownership latch, separate from advisory runtime.json history.
public struct RuntimeIntent: Equatable, Sendable {
  public enum State: String, Sendable { case unsettled, settled }
  public static let filename = "runtime-intent.json"
  public static let maximumBytes = 4096
  public let schemaVersion: Int
  public let vmID: UUID
  public let sessionID: UUID
  public let state: State

  fileprivate init(vmID: UUID, sessionID: UUID, state: State) {
    schemaVersion = 1
    self.vmID = vmID
    self.sessionID = sessionID
    self.state = state
  }
}

/// Launch authority exists only in memory after the unsettled record is flushed.
/// Disk UUIDs cannot reconstruct this permit. Retaining it retains the actual writer lease.
public final class RuntimeSessionPermit: Sendable {
  public let vmID: UUID
  public let sessionID: UUID
  private let owner: VMLock
  private let historyBinding = RuntimePermitHistoryBinding()
  private let settlementClaim = RuntimePermitHistoryBinding()

  fileprivate init(owner: VMLock, vmID: UUID, sessionID: UUID) {
    self.owner = owner
    self.vmID = vmID
    self.sessionID = sessionID
  }

  public func owns(_ lock: VMLock) -> Bool { owner === lock }

  /// A live permit can bind one ordered history writer. Failure never reopens this claim.
  /// Calling this does not settle intent or authorize reconstructing a permit from disk.
  public func reserveHistoryBinding() throws { try historyBinding.reserve() }

  /// Package settlement is one-shot even after an incomplete or ambiguous commit.
  package func reserveSettlement() throws { try settlementClaim.reserve() }

  package func withSettlementDirectory<Result>(
    in directory: URL, _ body: (Int32) throws -> Result
  ) throws -> Result {
    guard owner.owns(directory) else { throw intentError(.invalidConfiguration) }
    return try owner.withRuntimeIntentDirectory(body)
  }
}

/// Only the attachment claim is mutable; every access is protected by the private lock.
/// This helper performs no filesystem work or suspension while holding that lock.
private final class RuntimePermitHistoryBinding: @unchecked Sendable {
  private let mutex = NSLock()
  private var reserved = false

  func reserve() throws {
    mutex.lock()
    defer { mutex.unlock() }
    guard !reserved else { throw intentError(.busy) }
    reserved = true
  }
}

extension VMFiles {
  /// The reservation is one-shot even if persistence fails after rename. No permit is returned
  /// for incomplete/ambiguous commits, and this API never settles or retries a prior session.
  public func beginRuntimeSession(in directory: URL, forVMID vmID: UUID, lock: VMLock) throws
    -> RuntimeSessionPermit
  {
    try Task.checkCancellation()
    guard lock.owns(directory) else { throw intentError(.invalidConfiguration) }
    let sessionID = try lock.reserveRuntimeSession(forVMID: vmID)
    try lock.withRuntimeIntentDirectory { anchor in
      try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: vmID)
      try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: vmID)
      let record = RuntimeIntent(vmID: vmID, sessionID: sessionID, state: .unsettled)
      try RuntimeIntentIO.commit(record, at: anchor)
    }
    return RuntimeSessionPermit(owner: lock, vmID: vmID, sessionID: sessionID)
  }

  /// Read-only diagnostics never supply launch authority or clear an unsettled record.
  public func readRuntimeIntent(in directory: URL) throws -> RuntimeIntent? {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), !directory.path.contains("\0")
    else { throw intentError(.invalidConfiguration) }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw intentError(.storage) }
    defer { close(fd) }
    try RuntimeIntentIO.validateDirectory(fd)
    return try RuntimeIntentIO.read(at: fd)
  }
}

enum RuntimeIntentIO {
  static func validateDirectory(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o022 == 0
    else { throw intentError(.storage) }
  }

  static func requireAdmission(at directory: Int32, expectedVMID: UUID?) throws {
    guard let record = try read(at: directory) else { return }
    guard record.state == .settled, let expectedVMID, record.vmID == expectedVMID else {
      throw intentError(.busy)
    }
  }

  static func read(at directory: Int32) throws -> RuntimeIntent? {
    let fd = openat(
      directory, RuntimeIntent.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { return nil }
      throw intentError(.storage)
    }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, safeFile(before), before.st_size > 0,
      before.st_size <= RuntimeIntent.maximumBytes
    else { throw intentError(.storage) }
    var bytes = Data()
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    do {
      while let chunk = try handle.read(upToCount: RuntimeIntent.maximumBytes - bytes.count + 1),
        !chunk.isEmpty
      {
        bytes.append(chunk)
        guard bytes.count <= RuntimeIntent.maximumBytes else { throw intentError(.corruptMetadata) }
      }
    } catch let error as VMError {
      throw error
    } catch {
      throw intentError(.storage)
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0,
      fstatat(directory, RuntimeIntent.filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, named), bytes.count == before.st_size
    else { throw intentError(.storage) }
    return try decode(bytes)
  }

  static func commit(_ record: RuntimeIntent, at directory: Int32) throws {
    guard record.state == .unsettled else { throw intentError(.invalidConfiguration) }
    try commitRecord(record, at: directory)
  }

  static func commitSettlement(for permit: RuntimeSessionPermit, at directory: Int32) throws {
    guard let current = try read(at: directory), current.state == .unsettled,
      current.vmID == permit.vmID, current.sessionID == permit.sessionID
    else { throw intentError(.busy) }
    try commitRecord(
      RuntimeIntent(vmID: permit.vmID, sessionID: permit.sessionID, state: .settled), at: directory)
  }

  /// Separate explicit operator recovery policy; never mints/reconstructs a launch permit.
  /// Only the purpose-only lease can supply the actual anchor and one-shot recovery identity.
  static func commitOperatorInterruption(
    _ lease: RuntimeInterruptionLease, settled: Bool
  ) throws {
    let directory = try lease.checkedAnchor()
    guard let current = try read(at: directory), current.vmID == lease.vmID,
      current.state == .unsettled,
      current.sessionID == (settled ? lease.recoveryID : lease.interruptedSessionID)
    else { throw intentError(.busy) }
    try commitRecord(
      RuntimeIntent(
        vmID: lease.vmID, sessionID: lease.recoveryID,
        state: settled ? .settled : .unsettled), at: directory)
    _ = try lease.checkedAnchor()
  }

  private static func commitRecord(_ record: RuntimeIntent, at directory: Int32) throws {
    let data = Data(
      ("{\"schemaVersion\":1,\"vmID\":\"\(record.vmID.uuidString)\","
        + "\"sessionID\":\"\(record.sessionID.uuidString)\",\"state\":\"\(record.state.rawValue)\"}\n")
        .utf8)
    guard data.count <= RuntimeIntent.maximumBytes else {
      throw intentError(.invalidConfiguration)
    }
    let name = ".runtime-intent-\(UUID().uuidString)"
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw intentError(.storage) }
    defer {
      close(fd)
      unlinkat(directory, name, 0)
    }
    guard fchmod(fd, 0o600) == 0 else { throw intentError(.storage) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw intentError(.storage) }
        offset += count
      }
    }
    guard fsync(fd) == 0,
      renameat(directory, name, directory, RuntimeIntent.filename) == 0,
      fsync(directory) == 0
    else { throw intentError(.storage) }
    guard try read(at: directory) == record else { throw intentError(.storage) }
  }

  private static func safeFile(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
      && info.st_mode & 0o7777 == 0o600
  }

  private static func stable(_ first: stat, _ second: stat) -> Bool {
    safeFile(second) && first.st_dev == second.st_dev && first.st_ino == second.st_ino
      && first.st_size == second.st_size
      && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
      && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
      && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
      && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
  }

  private static func decode(_ data: Data) throws -> RuntimeIntent {
    var parser = FlatIntentParser(bytes: Array(data))
    let object = try parser.parse()
    guard Set(object.keys) == ["schemaVersion", "vmID", "sessionID", "state"],
      object["schemaVersion"] == .number("1"),
      case .string(let vmString)? = object["vmID"],
      case .string(let sessionString)? = object["sessionID"],
      case .string(let stateString)? = object["state"],
      vmString.utf8.count == 36, sessionString.utf8.count == 36,
      let vmID = UUID(uuidString: vmString), let sessionID = UUID(uuidString: sessionString),
      vmID.uuidString.lowercased() == vmString.lowercased(),
      sessionID.uuidString.lowercased() == sessionString.lowercased(),
      let state = RuntimeIntent.State(rawValue: stateString)
    else { throw intentError(.corruptMetadata) }
    return RuntimeIntent(vmID: vmID, sessionID: sessionID, state: state)
  }
}

/// Exactly one object and four scalar fields: depth <= 1, nodes <= 5, no arrays/nesting.
/// JSONDecoder is used only for bounded string tokens, never for an unbounded object graph.
private struct FlatIntentParser {
  enum Value: Equatable {
    case string(String)
    case number(String)
  }
  let bytes: [UInt8]
  private var index = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func parse() throws -> [String: Value] {
    var values: [String: Value] = [:]
    try consume(123)
    repeat {
      guard values.count < 4 else { throw intentError(.corruptMetadata) }
      let key = try string()
      guard values[key] == nil else { throw intentError(.corruptMetadata) }
      try consume(58)
      whitespace()
      let value: Value
      if index < bytes.count, bytes[index] == 34 {
        value = .string(try string())
      } else {
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        guard index > start else { throw intentError(.corruptMetadata) }
        value = .number(String(decoding: bytes[start..<index], as: UTF8.self))
      }
      values[key] = value
      whitespace()
      guard index < bytes.count else { throw intentError(.corruptMetadata) }
      if bytes[index] == 125 {
        index += 1
        whitespace()
        guard index == bytes.count else { throw intentError(.corruptMetadata) }
        return values
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
      guard byte >= 32 else { throw intentError(.corruptMetadata) }
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) } catch
        { throw intentError(.corruptMetadata) }
      }
    }
    throw intentError(.corruptMetadata)
  }

  private mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard index < bytes.count, bytes[index] == byte else { throw intentError(.corruptMetadata) }
    index += 1
  }

  private mutating func whitespace() {
    while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
}

private func intentError(_ code: VMError.Code) -> VMError {
  VMError(
    code, "Runtime ownership intent does not permit this operation.",
    recovery:
      "Preserve VM files and use read-only inspection. Unsettled or uncertain intent is never cleared automatically."
  )
}
