// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import VMCore

/// UI binding only. The inspection and this weak request confer no writer or runtime authority.
@MainActor final class DesktopDiskMetadataUpgradeRequest {
  let id = UUID()
  weak var owner: NSWindow?
  let context: VMLibraryPickerContext
  let selectionGeneration: UUID
  let draftGeneration: UUID
  let modalGeneration: UUID
  init(owner: NSWindow, context: VMLibraryPickerContext, selection: UUID, draft: UUID, modal: UUID)
  {
    self.owner = owner
    self.context = context
    selectionGeneration = selection
    draftGeneration = draft
    modalGeneration = modal
  }
}

@MainActor protocol DesktopDiskMetadataUpgrading {
  func inspect(
    at registration: URL, expected: VMConfiguration, accepting: @MainActor () -> Bool
  ) async throws
    -> DiskGrowthIdentityUpgradeInspection
  func upgrade(
    at registration: URL, expected: VMConfiguration, inspectedVMID: UUID,
    transactionID: UUID, acknowledgement: DiskGrowthIdentityUpgradeAcknowledgement,
    accepting: @MainActor () -> Bool
  ) async throws -> DiskGrowthIdentityUpgradeResult
}

/// Lazy adapter: construction performs no file, app, catalog or device inspection.
/// Core alone acquires its existing writer and rechecks stopped/anchored file proofs.
struct NativeDesktopDiskMetadataUpgrade: DesktopDiskMetadataUpgrading {
  func inspect(
    at registration: URL, expected: VMConfiguration, accepting: @MainActor () -> Bool
  ) async throws
    -> DiskGrowthIdentityUpgradeInspection
  {
    guard accepting() else { throw Self.changedSelection() }
    try await requireConfiguration(at: registration, expected: expected)
    guard accepting() else { throw Self.changedSelection() }
    let result = await DiskGrowthIdentityUpgrade().inspect(
      in: registration.deletingLastPathComponent())
    guard accepting() else { throw Self.changedSelection() }
    try await requireConfiguration(at: registration, expected: expected)
    guard accepting() else { throw Self.changedSelection() }
    return result
  }

  func upgrade(
    at registration: URL, expected: VMConfiguration, inspectedVMID: UUID,
    transactionID: UUID, acknowledgement: DiskGrowthIdentityUpgradeAcknowledgement,
    accepting: @MainActor () -> Bool
  ) async throws -> DiskGrowthIdentityUpgradeResult {
    guard accepting(), inspectedVMID == expected.id else { throw Self.changedSelection() }
    try await requireConfiguration(at: registration, expected: expected)
    guard accepting() else { throw Self.changedSelection() }
    return try await DiskGrowthIdentityUpgrade().upgrade(
      in: registration.deletingLastPathComponent(), expectedVMID: inspectedVMID,
      expectedTransactionID: transactionID, acknowledgement: acknowledgement)
  }

  private func requireConfiguration(at registration: URL, expected: VMConfiguration) async throws {
    guard
      try await VMLibrarySelection.readForEditing(at: registration, expectedID: expected.id)
        == expected
    else { throw Self.changedSelection() }
  }

  private static func changedSelection() -> VMError {
    VMError(
      .staleOperation, "The saved VM changed. Cancel and reopen it before checking again.",
      recovery: "Preserve the VM and all of its files.")
  }
}

/// Bounded status copy only; no synthetic eligible inspection or successful result can be made here.
enum DiskMetadataUpgradeCopy {
  static let compatibility =
    "Older versions, including App79, cannot open this VM after the upgrade. Keep a compatible version of macOpenVM."
  static let archive =
    "An upgrade keeps the exact old record in the VM folder. That archive does not automatically undo the upgrade. The virtual disk and its contents are not repaired or resized."
  static func message(_ status: DiskGrowthIdentityUpgradeInspection.Status) -> String {
    switch status {
    case .eligibleAtCheck:
      "This completed disk expansion can use the newer compatibility record. The VM will be checked again when you confirm."
    case .alreadyStable: "This VM already uses the newer record. No upgrade is needed."
    case .notNeeded: "No disk expansion record needs this upgrade."
    case .pendingGrowth:
      "A disk expansion is unfinished. This action cannot finish it. Preserve the VM and its expansion records."
    case .busy: "Another session is using this VM. Close that session before checking again."
    case .legacyProofUnavailable:
      "The original disk location could not be confirmed. Preserve the VM and its records; this check cannot bypass that requirement."
    case .needsReview:
      "The VM could not be confirmed safe for this change. Preserve its files and review its saved state before trying again."
    }
  }
}
