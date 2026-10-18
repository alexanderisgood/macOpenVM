// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

public enum RuntimeOutcome: String, Codable, Sendable {
  case pending, guestStopped, forcedStopped, failed
}

/// Fixed fields only: no VM name, path, MAC, credential, diagnostic text or guest content.
public struct RuntimeSnapshot: Codable, Equatable, Sendable {
  public let state: VMState
  public let operation: LifecycleOperation?
  public let backendActive: Bool
  public let outcome: RuntimeOutcome
  public init(
    state: VMState, operation: LifecycleOperation?, backendActive: Bool, outcome: RuntimeOutcome
  ) {
    self.state = state
    self.operation = operation
    self.backendActive = backendActive
    self.outcome = outcome
  }
}

public struct RuntimeRecord: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sessionID: UUID
  public let sequence: UInt64
  public let recordedAt: Double
  public let snapshot: RuntimeSnapshot
  public init(
    sessionID: UUID, sequence: UInt64, recordedAt: Double, snapshot: RuntimeSnapshot,
    schemaVersion: Int = 1
  ) {
    self.schemaVersion = schemaVersion
    self.sessionID = sessionID
    self.sequence = sequence
    self.recordedAt = recordedAt
    self.snapshot = snapshot
  }
}

public enum RuntimeHistoryStatus: String, Codable, Sendable {
  case notRecorded, writerHeld, guestStopRecorded, forcedStopRecorded, failureRecorded
  case interruptedOrUnreconciled, invalid
}

public enum RuntimeHistoryCodec {
  public static let maximumBytes = 4096
  public static func encode(_ record: RuntimeRecord) throws -> Data {
    try validate(record)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    guard data.count <= maximumBytes else { throw invalidHistory() }
    return data
  }
  public static func decode(_ data: Data) throws -> RuntimeRecord {
    guard data.count <= maximumBytes else { throw invalidHistory() }
    do {
      let record = try JSONDecoder().decode(RuntimeRecord.self, from: data)
      try validate(record)
      return record
    } catch { throw invalidHistory() }
  }
  private static func validate(_ record: RuntimeRecord) throws {
    guard record.schemaVersion == 1, record.sequence > 0,
      record.recordedAt.isFinite, record.recordedAt >= 0
    else { throw invalidHistory() }
    switch record.snapshot.outcome {
    case .guestStopped, .forcedStopped:
      guard record.snapshot.state == .stopped, !record.snapshot.backendActive,
        record.snapshot.operation == nil
      else { throw invalidHistory() }
    case .pending:
      guard record.snapshot.state != .stopped else { throw invalidHistory() }
    case .failed:
      guard record.snapshot.state == .failed else { throw invalidHistory() }
    }
  }
  public static func status(_ record: RuntimeRecord, writer: WriterStatus) -> RuntimeHistoryStatus {
    if writer == .held { return .writerHeld }
    switch record.snapshot.outcome {
    case .guestStopped: return .guestStopRecorded
    case .forcedStopped: return .forcedStopRecorded
    case .failed: return .failureRecorded
    case .pending: return .interruptedOrUnreconciled
    }
  }
}

@MainActor public protocol LifecycleHistory: AnyObject {
  func persist(_ snapshot: RuntimeSnapshot) async throws
}

/// Bounded runtime-history storage boundary; guest disks and platform mutation are excluded.
public protocol RuntimeHistoryStore: Sendable {
  func status(at url: URL) async -> VMFileStatus
  func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent?
  func inspectWritableFile(at url: URL) async throws -> DiskUsage
  func readMetadata(at url: URL, limit: Int) async throws -> Data
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws
  func writeNewMetadata(_ data: Data, at url: URL) async throws
  func atomicWrite(_ data: Data, at url: URL) async throws
}

extension RuntimeHistoryStore {
  /// Older injected stores can support legacy fixtures with absent intent. A present
  /// record requires a strict reader; never decode ownership authority in Core.
  public func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    let status = await status(at: directory.appendingPathComponent(RuntimeIntent.filename))
    guard status.kind == .missing else { throw invalidHistory() }
    return nil
  }
}

extension VMFiles: RuntimeHistoryStore {
  public func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    try readRuntimeIntent(in: directory)
  }
}

/// One recorded run, held under the same lifetime writer lock as its backend.
/// Calls must be ordered by the controller; overlapping direct callers fail safely.
@MainActor public final class VMRuntimeHistory: LifecycleHistory, RuntimeHistoryReceiptSource {
  public let previousStatus: RuntimeHistoryStatus
  private let directory: URL
  private let files: any RuntimeHistoryStore
  private let lock: VMLock
  private let permit: RuntimeSessionPermit?
  private let intent: RuntimeIntent?
  private let sessionID: UUID
  private let previous: (RuntimeRecord, Data)?
  private let now: @Sendable () -> Date
  private var sequence: UInt64 = 0
  private var archived = false
  private var writing = false
  private var persistenceFaulted = false
  private var sealAttempted = false
  private var committed: (record: RuntimeRecord, bytes: Data)?

  private init(
    directory: URL, files: any RuntimeHistoryStore, lock: VMLock,
    permit: RuntimeSessionPermit?, intent: RuntimeIntent?, previous: (RuntimeRecord, Data)?,
    now: @escaping @Sendable () -> Date
  ) {
    self.directory = directory
    self.files = files
    self.lock = lock
    self.permit = permit
    self.intent = intent
    self.previous = previous
    self.now = now
    sessionID = permit?.sessionID ?? UUID()
    previousStatus =
      previous.map { RuntimeHistoryCodec.status($0.0, writer: .available) } ?? .notRecorded
  }

  public static func open(
    in directory: URL, files: any RuntimeHistoryStore = VMFiles(), lock: VMLock,
    permit: RuntimeSessionPermit? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) async throws -> VMRuntimeHistory {
    let intent = try await validateOwner(in: directory, files: files, lock: lock, permit: permit)
    // Reserve before further suspension. Even a failed open must not create another
    // independent sequence writer under aliases of this launch permit.
    if let permit { try permit.reserveHistoryBinding() }
    let url = directory.appendingPathComponent("runtime.json")
    let status = await files.status(at: url)
    let previous: (RuntimeRecord, Data)?
    if status.kind == .missing {
      previous = nil
    } else {
      guard lock.owns(directory) else { throw invalidHistory() }
      _ = try await files.inspectWritableFile(at: url)
      guard lock.owns(directory) else { throw invalidHistory() }
      let bytes = try await files.readMetadata(at: url, limit: RuntimeHistoryCodec.maximumBytes)
      previous = (try RuntimeHistoryCodec.decode(bytes), bytes)
    }
    if let permit, previous?.0.sessionID == permit.sessionID { throw invalidHistory() }
    guard
      try await validateOwner(in: directory, files: files, lock: lock, permit: permit) == intent
    else { throw invalidHistory() }
    return VMRuntimeHistory(
      directory: directory, files: files, lock: lock, permit: permit, intent: intent,
      previous: previous, now: now)
  }

  private static func validateOwner(
    in directory: URL, files: any RuntimeHistoryStore, lock: VMLock,
    permit: RuntimeSessionPermit?
  ) async throws -> RuntimeIntent? {
    guard lock.owns(directory), permit == nil || permit?.owns(lock) == true else {
      throw invalidHistory()
    }
    let current = try await files.readOwnershipIntent(in: directory)
    guard lock.owns(directory) else { throw invalidHistory() }
    if let permit {
      guard let current, current.schemaVersion == 1, current.state == .unsettled,
        current.vmID == permit.vmID, current.sessionID == permit.sessionID
      else { throw invalidHistory() }
    } else {
      guard current == nil else { throw invalidHistory() }
    }
    return current
  }

  private func revalidateOwner() async throws {
    guard
      try await Self.validateOwner(in: directory, files: files, lock: lock, permit: permit)
        == intent
    else { throw invalidHistory() }
  }

  public func persist(_ snapshot: RuntimeSnapshot) async throws {
    guard !sealAttempted else { throw invalidHistoryReceipt() }
    guard !persistenceFaulted else {
      throw VMError(
        .storage, "This runtime history session is frozen after a persistence failure.",
        recovery:
          "Preserve the current history bytes. Review read-only diagnostics before opening another session."
      )
    }
    guard !writing else { throw invalidHistory() }
    writing = true
    defer { writing = false }
    do {
      try await revalidateOwner()
      try await persistRecord(snapshot)
    } catch {
      // A rename may have committed even if its following directory flush failed.
      // Freeze this session rather than overwrite possible committed bytes or reuse a sequence.
      persistenceFaulted = true
      throw error
    }
  }

  private func persistRecord(_ snapshot: RuntimeSnapshot) async throws {
    if sequence == 0 {
      try await files.checkFreeSpace(at: directory, reserveBytes: 1_048_576)
      try await revalidateOwner()
    }
    if !archived, let previous {
      let archive = directory.appendingPathComponent(
        "runtime-\(previous.0.sessionID.uuidString.lowercased()).json")
      let status = await files.status(at: archive)
      guard lock.owns(directory) else { throw invalidHistory() }
      if status.kind == .missing {
        try await revalidateOwner()
        try await files.writeNewMetadata(previous.1, at: archive)
        try await revalidateOwner()
      } else {
        guard status.kind == .regular else { throw invalidHistory() }
        _ = try await files.inspectWritableFile(at: archive)
        guard lock.owns(directory) else { throw invalidHistory() }
        guard
          try await files.readMetadata(at: archive, limit: RuntimeHistoryCodec.maximumBytes)
            == previous.1
        else { throw invalidHistory() }
        try await revalidateOwner()
      }
      archived = true
    }
    let (next, overflow) = sequence.addingReportingOverflow(1)
    guard !overflow else { throw invalidHistory() }
    let record = RuntimeRecord(
      sessionID: sessionID, sequence: next,
      recordedAt: now().timeIntervalSince1970, snapshot: snapshot)
    let bytes = try RuntimeHistoryCodec.encode(record)
    let url = directory.appendingPathComponent("runtime.json")
    let status = await files.status(at: url)
    guard lock.owns(directory) else { throw invalidHistory() }
    if status.kind != .missing { _ = try await files.inspectWritableFile(at: url) }
    try await revalidateOwner()
    try await files.atomicWrite(bytes, at: url)
    try await revalidateOwner()
    sequence = next
    committed = (record, bytes)
  }

  /// Seals this actual history writer after the controller drains its ordered writes.
  /// A failed or cancelled attempt is permanent. This receipt does not settle intent
  /// or establish backend terminal/drain evidence; those remain separate requirements.
  package func sealCommittedHistory(for expectedPermit: RuntimeSessionPermit) async throws
    -> RuntimeHistoryCommitReceipt
  {
    guard !sealAttempted else { throw invalidHistoryReceipt() }
    guard !writing else {
      throw VMError(
        .busy, "Runtime history writes are still pending.",
        recovery: "Drain the ordered writes before attempting the final history seal.")
    }
    sealAttempted = true
    try Task.checkCancellation()
    guard !writing, !persistenceFaulted, let permit, permit === expectedPermit,
      let committed, committed.record.sessionID == permit.sessionID,
      committed.record.sequence == sequence, sequence > 0,
      !committed.record.snapshot.backendActive, committed.record.snapshot.operation == nil
    else { throw invalidHistoryReceipt() }
    switch committed.record.snapshot.outcome {
    case .guestStopped, .forcedStopped:
      guard committed.record.snapshot.state == .stopped else { throw invalidHistoryReceipt() }
    case .failed:
      guard committed.record.snapshot.state == .failed else { throw invalidHistoryReceipt() }
    case .pending: throw invalidHistoryReceipt()
    }

    try await revalidateOwner()
    let url = directory.appendingPathComponent("runtime.json")
    _ = try await files.inspectWritableFile(at: url)
    guard lock.owns(directory) else { throw invalidHistoryReceipt() }
    let actual = try await files.readMetadata(at: url, limit: RuntimeHistoryCodec.maximumBytes)
    guard actual == committed.bytes,
      try RuntimeHistoryCodec.decode(actual) == committed.record
    else { throw invalidHistoryReceipt() }
    try await revalidateOwner()
    try Task.checkCancellation()
    return try RuntimeHistoryCommitReceipt(
      source: self, permit: permit, sequence: sequence,
      finalBytes: committed.bytes)
  }
}

private func invalidHistoryReceipt() -> VMError {
  VMError(
    .storage, "This runtime history cannot issue or accept further writes after its seal attempt.",
    recovery:
      "Retain runtime ownership and preserve history and unsettled intent for read-only review.")
}

private func invalidHistory() -> VMError {
  VMError(
    .corruptMetadata, "Runtime history is unsafe, inconsistent or has an unknown schema.",
    recovery: "Preserve runtime history and VM files. Use read-only diagnostics before retrying.")
}
