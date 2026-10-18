// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

/// A committed raw-image capacity transaction. This neither resizes a guest
/// partition/filesystem nor establishes guest shutdown or storage integrity.
public struct DiskGrowthResult: Encodable, Sendable {
  public let configuration: VMConfiguration
  public let changed: Bool
  public let recovered: Bool
  public let oldBytes: UInt64
  public let targetBytes: UInt64
  public let backupFile: String
  public let transactionID: UUID
}

/// The real Storage factories alone create permits. Tests can inject a failed
/// boundary while forwarding all ownership, journal and disk operations to them.
package protocol DiskGrowthStore: Sendable {
  func readMetadata(at url: URL, limit: Int) async throws -> Data
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage
  func inspectWritableFile(at url: URL) async throws -> DiskUsage
  func readDiskGrowthIntent(in directory: URL) async throws -> DiskGrowthIntent?
  func beginDiskGrowth(
    in directory: URL, vmID: UUID, diskFile: String, oldBytes: UInt64, targetBytes: UInt64,
    originalConfiguration: Data, replacementConfiguration: Data, lock: VMLock
  ) async throws -> DiskGrowthPermit
  func openDiskGrowthRecovery(in directory: URL, vmID: UUID, expectedTransactionID: UUID)
    async throws -> DiskGrowthPermit
  func commitDiskGrowth(_ permit: DiskGrowthPermit) async throws -> DiskGrowthCompletion
}

extension VMFiles: DiskGrowthStore {}

/// Offline grow only. Each new operation acquires a fresh matching writer lease;
/// uncertain failures preserve Storage's actual journal/sidecars without rollback.
public struct DiskGrowth: Sendable {
  private let files: any DiskGrowthStore

  public init() { files = VMFiles() }
  package init(files: any DiskGrowthStore) { self.files = files }

  public func grow(
    in directory: URL, toBytes targetBytes: UInt64,
    expected: VMConfiguration? = nil, host: HostResources = .current
  ) async throws -> DiskGrowthResult {
    do {
      return try await growOwned(
        in: directory, toBytes: targetBytes, expected: expected, host: host)
    } catch {
      throw Self.publicFailure(error)
    }
  }

  private func growOwned(
    in directory: URL, toBytes targetBytes: UInt64,
    expected: VMConfiguration?, host: HostResources
  ) async throws -> DiskGrowthResult {
    try Self.location(directory)
    try Task.checkCancellation()
    let registration = directory.appendingPathComponent("configuration.json")
    let observed = try StrictConfigurationDocument(
      await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes))
    let baseline = expected ?? observed.configuration
    guard baseline == observed.configuration else { throw Self.staleSelection() }
    try Self.validateGrowth(baseline, targetBytes: targetBytes, host: host)
    let expectedID = baseline.id
    let lock = try VMLock(directory: directory, expectedVMID: expectedID)
    defer { withExtendedLifetime(lock) {} }
    _ = try await files.inspectWritableConfiguration(at: registration)
    let original = try StrictConfigurationDocument(
      await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes))
    guard original.configuration.id == expectedID, lock.owns(directory) else {
      throw Self.failure(.busy, "The saved VM identity changed before disk-growth admission.")
    }
    guard original.configuration == baseline else { throw Self.staleSelection() }
    try Self.validateGrowth(original.configuration, targetBytes: targetBytes, host: host)
    let disk = try await files.inspectWritableFile(
      at: directory.appendingPathComponent(original.configuration.diskFile))
    guard disk.virtualBytes == original.configuration.diskBytes else {
      throw Self.failure(.corruptMetadata, "Disk length differs from its saved configuration.")
    }
    let target = try original.replacingDiskBytes(with: targetBytes)
    try ConfigurationValidator.validate(target.configuration, host: host)
    try Task.checkCancellation()
    let permit = try await files.beginDiskGrowth(
      in: directory, vmID: expectedID, diskFile: original.configuration.diskFile,
      oldBytes: original.configuration.diskBytes, targetBytes: targetBytes,
      originalConfiguration: original.bytes, replacementConfiguration: target.bytes, lock: lock)
    defer { withExtendedLifetime((lock, permit)) {} }
    let admittedTarget = try Self.validatePermit(permit, expectedVMID: expectedID, host: host)
    guard permit.originalConfiguration == original.bytes,
      permit.replacementConfiguration == target.bytes,
      permit.currentConfiguration == original.bytes
    else {
      throw Self.failure(.busy, "Configuration changed before the disk transaction was sealed.")
    }
    try Task.checkCancellation()
    let completion = try await files.commitDiskGrowth(permit)
    return try Self.result(completion, permit: permit, target: admittedTarget, recovered: false)
  }

  /// Explicitly finish the one recorded pending plan. No target/path override,
  /// runtime permit reconstruction, automatic retry or shrink exists here.
  public func finish(in directory: URL, host: HostResources = .current) async throws
    -> DiskGrowthResult
  {
    do { return try await finishOwned(in: directory, host: host) } catch {
      throw Self.publicFailure(error)
    }
  }

  private func finishOwned(in directory: URL, host: HostResources) async throws -> DiskGrowthResult
  {
    try Self.location(directory)
    try Task.checkCancellation()
    let observed = try StrictConfigurationDocument(
      await files.readMetadata(
        at: directory.appendingPathComponent("configuration.json"),
        limit: ConfigurationCodec.maximumBytes))
    guard let intent = try await files.readDiskGrowthIntent(in: directory),
      intent.state == .pending,
      intent.vmID == observed.configuration.id
    else {
      throw Self.failure(
        .invalidTransition, "No matching pending disk-growth transaction can be finished.")
    }
    let permit = try await files.openDiskGrowthRecovery(
      in: directory, vmID: observed.configuration.id, expectedTransactionID: intent.transactionID)
    defer { withExtendedLifetime(permit) {} }
    let target = try Self.validatePermit(
      permit, expectedVMID: observed.configuration.id, host: host)
    guard permit.transactionID == intent.transactionID else {
      throw Self.failure(.busy, "The pending disk-growth transaction changed before recovery.")
    }
    try Task.checkCancellation()
    let completion = try await files.commitDiskGrowth(permit)
    return try Self.result(completion, permit: permit, target: target, recovered: true)
  }

  private static func validateGrowth(
    _ configuration: VMConfiguration, targetBytes: UInt64,
    host: HostResources
  ) throws {
    try ConfigurationValidator.validate(configuration, host: host)
    guard configuration.diskBytes % 512 == 0, targetBytes % 512 == 0,
      targetBytes > configuration.diskBytes, targetBytes >= 1_073_741_824,
      targetBytes <= 2 * 1_099_511_627_776
    else {
      throw failure(
        .invalidConfiguration,
        "Disk growth requires a larger 512-byte-aligned capacity between 1 GiB and 2 TiB.")
    }
  }

  private static func validatePermit(
    _ permit: DiskGrowthPermit, expectedVMID: UUID,
    host: HostResources
  ) throws -> VMConfiguration {
    let original = try StrictConfigurationDocument(permit.originalConfiguration)
    let replacement = try StrictConfigurationDocument(permit.replacementConfiguration)
    let current = try StrictConfigurationDocument(permit.currentConfiguration)
    guard permit.vmID == expectedVMID, original.configuration.id == expectedVMID,
      replacement.configuration.id == expectedVMID, current.configuration.id == expectedVMID,
      original.configuration.diskFile == permit.diskFile,
      replacement.configuration.diskFile == permit.diskFile,
      current.configuration.diskFile == permit.diskFile,
      original.configuration.diskBytes == permit.oldBytes,
      replacement.configuration.diskBytes == permit.targetBytes,
      current.bytes == original.bytes || current.bytes == replacement.bytes
    else {
      throw failure(
        .corruptMetadata, "The disk-growth plan and captured configuration do not match.")
    }
    try validateGrowth(original.configuration, targetBytes: permit.targetBytes, host: host)
    try ConfigurationValidator.validate(replacement.configuration, host: host)
    let expected = try original.replacingDiskBytes(with: permit.targetBytes)
    guard replacement.bytes == expected.bytes else {
      throw failure(
        .corruptMetadata, "The disk-growth plan changes settings other than disk capacity.")
    }
    return replacement.configuration
  }

  private static func result(
    _ completion: DiskGrowthCompletion, permit: DiskGrowthPermit,
    target: VMConfiguration, recovered: Bool
  ) throws -> DiskGrowthResult {
    guard completion.transactionID == permit.transactionID, completion.oldBytes == permit.oldBytes,
      completion.targetBytes == permit.targetBytes, completion.backupFile == permit.backupFile
    else {
      throw failure(
        .storage, "The disk-growth completion could not be associated with this transaction.")
    }
    return .init(
      configuration: target, changed: true, recovered: recovered,
      oldBytes: completion.oldBytes, targetBytes: completion.targetBytes,
      backupFile: completion.backupFile, transactionID: completion.transactionID)
  }

  private static func location(_ directory: URL) throws {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), directory.path.utf8.count <= 4096,
      !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      directory.query == nil, directory.fragment == nil
    else {
      throw failure(.invalidConfiguration, "Disk growth requires a bounded local VM directory.")
    }
  }

  private static func staleSelection() -> VMError {
    VMError(
      .staleOperation, "The saved VM settings changed while disk capacity was being edited.",
      recovery: "Cancel and reopen the stopped VM before expanding its disk.")
  }

  private static func failure(_ code: VMError.Code, _ message: String) -> VMError {
    VMError(
      code, message,
      recovery:
        "Preserve the VM, journal and configuration sidecars. Use read-only inspection; finish a pending plan explicitly. Never shrink or roll back the disk automatically."
    )
  }

  private static func publicFailure(_ error: any Error) -> any Error {
    if error is CancellationError { return CancellationError() }
    if let error = error as? VMError { return error }
    return failure(.storage, "The disk-growth transaction could not be confirmed.")
  }
}
