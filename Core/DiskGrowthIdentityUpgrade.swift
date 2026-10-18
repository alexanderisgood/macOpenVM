// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

/// This acknowledgment is required explicitly at the product boundary, with no default.
public enum DiskGrowthIdentityUpgradeAcknowledgement: Sendable {
  case schema1OnlyAppsCannotOpenSchema2
}

/// Dedicated operational output. IDs appear only for an eligible explicit confirmation;
/// no paths, filesystem UUIDs, sidecar contents, or configuration bytes are exported.
public struct DiskGrowthIdentityUpgradeInspection: Encodable, Sendable {
  public enum Status: String, Encodable, Sendable {
    case eligibleAtCheck, alreadyStable, notNeeded, pendingGrowth, busy
    case legacyProofUnavailable, needsReview
  }
  public let schemaVersion = 1
  public let readOnly = true
  public let sourceSchemaVersion: Int?
  public let targetSchemaVersion = 2
  public let status: Status
  public let eligibleAtCheck: Bool
  public let vmID: UUID?
  public let transactionID: UUID?
  public let compatibilityNotice: String
}

public struct DiskGrowthIdentityUpgradeResult: Encodable, Sendable {
  public let schemaVersion = 1
  public let changed = true
  public let sourceSchemaVersion = 1
  public let targetSchemaVersion = 2
  public let vmID: UUID
  public let transactionID: UUID
  public let archiveFile: String
  public let compatibilityNotice: String
}

package protocol DiskGrowthIdentityUpgradeStore: Sendable {
  func writerStatus(in directory: URL) async -> WriterStatus
  func inspectDiskGrowthIdentityUpgrade(in directory: URL) async throws
    -> DiskGrowthIdentityUpgradeObservation
  func upgradeCompletedDiskGrowthIdentity(
    in directory: URL, vmID: UUID, expectedTransactionID: UUID, lock: VMLock,
    observed: DiskGrowthIdentityUpgradeSnapshot?,
    validateStopped: (@Sendable (Data, Data?, RuntimeIntent?) throws -> Void)?
  ) async throws -> DiskGrowthIntent
}

extension VMFiles: DiskGrowthIdentityUpgradeStore {}

/// Explicit stopped-VM metadata migration. Inspection is a point-in-time diagnostic;
/// only a fresh real existing writer and synchronous anchored revalidation may commit.
public struct DiskGrowthIdentityUpgrade: Sendable {
  public static let compatibilityNotice =
    "App79 and other schema1-only versions cannot open this VM after the schema2 upgrade. "
    + "Keep a compatible app and preserve the VM and exact legacy archive; the archive is not an automatic rollback."
  private let files: any DiskGrowthIdentityUpgradeStore
  public init() { files = VMFiles() }
  package init(files: any DiskGrowthIdentityUpgradeStore) { self.files = files }

  public func inspect(in directory: URL) async -> DiskGrowthIdentityUpgradeInspection {
    do {
      try Self.location(directory)
      try Task.checkCancellation()
      let writer = await files.writerStatus(in: directory)
      if writer == .held { return Self.inspection(.busy) }
      let observed = try await files.inspectDiskGrowthIdentityUpgrade(in: directory)
      switch observed.kind {
      case .notNeeded: return Self.inspection(.notNeeded)
      case .pendingGrowth:
        return Self.inspection(.pendingGrowth, schema: observed.sourceSchemaVersion)
      case .legacyProofUnavailable: return Self.inspection(.legacyProofUnavailable, schema: 1)
      case .alreadyStable: return Self.inspection(.alreadyStable, schema: 2)
      case .eligibleAtCheck:
        guard writer == .available, let snapshot = observed.snapshot else {
          return Self.inspection(.needsReview, schema: 1)
        }
        try Self.validateStopped(snapshot: snapshot, expectedVMID: snapshot.record.vmID)
        guard await files.writerStatus(in: directory) == .available else {
          return Self.inspection(.busy, schema: 1)
        }
        return Self.inspection(.eligibleAtCheck, schema: 1, snapshot: snapshot)
      }
    } catch {
      return Self.inspection(.needsReview)
    }
  }

  public func upgrade(
    in directory: URL, expectedVMID: UUID, expectedTransactionID: UUID,
    acknowledgement: DiskGrowthIdentityUpgradeAcknowledgement
  ) async throws -> DiskGrowthIdentityUpgradeResult {
    do {
      try Self.location(directory)
      try Task.checkCancellation()
      switch acknowledgement {
      case .schema1OnlyAppsCannotOpenSchema2: break
      }
      let zero = "00000000-0000-0000-0000-000000000000"
      guard expectedVMID.uuidString != zero, expectedTransactionID.uuidString != zero else {
        throw Self.failure(.invalidConfiguration)
      }
      let observed = try await files.inspectDiskGrowthIdentityUpgrade(in: directory)
      guard case .eligibleAtCheck = observed.kind, let snapshot = observed.snapshot,
        snapshot.record.vmID == expectedVMID,
        snapshot.record.transactionID == expectedTransactionID
      else { throw Self.failure(.staleOperation) }
      try Self.validateStopped(snapshot: snapshot, expectedVMID: expectedVMID)
      // This constructor cannot create a missing permanent lock. It also retains all
      // existing runtime/growth admission checks, including the exact legacy device proof.
      let lock = try VMLock(existingDirectory: directory, expectedVMID: expectedVMID)
      defer { withExtendedLifetime(lock) {} }
      try Task.checkCancellation()
      let completed = try await files.upgradeCompletedDiskGrowthIdentity(
        in: directory, vmID: expectedVMID, expectedTransactionID: expectedTransactionID,
        lock: lock, observed: snapshot,
        validateStopped: { registration, history, intent in
          let current = try StrictConfigurationDocument(registration).configuration
          guard current.id == expectedVMID, registration == snapshot.configuration else {
            throw Self.failure(.staleOperation)
          }
          try VMTrash.validateStopped(history: history, intent: intent, vmID: expectedVMID)
        })
      guard completed.schemaVersion == 2, completed.state == .completed,
        completed.vmID == expectedVMID, completed.transactionID == expectedTransactionID
      else { throw Self.failure(.storage) }
      return .init(
        vmID: expectedVMID, transactionID: expectedTransactionID,
        archiveFile: "disk-growth-\(expectedTransactionID.uuidString)-schema1-completed.json",
        compatibilityNotice: Self.compatibilityNotice)
    } catch {
      if error is CancellationError { throw Self.failure(.cancelled) }
      throw Self.failure((error as? VMError)?.code ?? .storage)
    }
  }

  private static func validateStopped(
    snapshot: DiskGrowthIdentityUpgradeSnapshot, expectedVMID: UUID
  ) throws {
    let configuration = try StrictConfigurationDocument(snapshot.configuration).configuration
    guard configuration.id == expectedVMID, snapshot.record.vmID == expectedVMID else {
      throw failure(.staleOperation)
    }
    try VMTrash.validateStopped(
      history: snapshot.history, intent: snapshot.intent, vmID: expectedVMID)
  }

  private static func inspection(
    _ status: DiskGrowthIdentityUpgradeInspection.Status, schema: Int? = nil,
    snapshot: DiskGrowthIdentityUpgradeSnapshot? = nil
  ) -> DiskGrowthIdentityUpgradeInspection {
    .init(
      sourceSchemaVersion: schema, status: status, eligibleAtCheck: status == .eligibleAtCheck,
      vmID: status == .eligibleAtCheck ? snapshot?.record.vmID : nil,
      transactionID: status == .eligibleAtCheck ? snapshot?.record.transactionID : nil,
      compatibilityNotice: compatibilityNotice)
  }

  private static func location(_ directory: URL) throws {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), directory.path.utf8.count <= 4096,
      !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      directory.user == nil, directory.password == nil,
      directory.query == nil, directory.fragment == nil,
      directory.standardizedFileURL.path == directory.path
    else { throw failure(.invalidConfiguration) }
  }

  private static func failure(_ code: VMError.Code) -> VMError {
    VMError(
      code, "The stopped VM metadata could not be safely upgraded; preserve it and inspect again.",
      recovery: "Changed legacy device identity cannot be waived. " + compatibilityNotice)
  }
}
