// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

package enum RecordedOwnershipState: String, Sendable {
  case unsettled, settling, settled, recoveryRequired
}

/// Distinct injected names avoid shadowing Storage's actor-isolated strict operations.
package protocol RecordedRuntimeStore: RuntimeHistoryStore {
  func beginOwnership(in directory: URL, vmID: UUID, lock: VMLock) async throws
    -> RuntimeSessionPermit
  func commitOwnership(in directory: URL, receipt: RuntimeSettlementReceipt) async throws
}

extension VMFiles: RecordedRuntimeStore {
  package func beginOwnership(in directory: URL, vmID: UUID, lock: VMLock) async throws
    -> RuntimeSessionPermit
  {
    try beginRuntimeSession(in: directory, forVMID: vmID, lock: lock)
  }
  package func commitOwnership(in directory: URL, receipt: RuntimeSettlementReceipt) async throws {
    try commitRuntimeSettlement(in: directory, receipt: receipt)
  }
}

/// One concrete recorded session. Kernel custody and its permit remain retained until
/// successful intent settlement; failure has an explicit retained recovery lifetime.
@MainActor
package final class RecordedRuntimeOwner: RuntimeSettlementReceiptSource {
  package let controller: VMController
  package let vmID: UUID
  package let sessionID: UUID
  package private(set) var ownershipState = RecordedOwnershipState.unsettled
  package private(set) var ownershipError: VMError?
  package var onOwnershipSettled: (@MainActor () -> Void)?
  private let backend: any BackendSettlementSource
  private let history: VMRuntimeHistory
  private let permit: RuntimeSessionPermit
  private let directory: URL
  private let files: any RecordedRuntimeStore
  private var retainedLifetime: RecordedRuntimeOwner?
  private var settlement: Task<Result<Void, VMError>, Never>?

  private init(
    directory: URL, files: any RecordedRuntimeStore, backend: any BackendSettlementSource,
    history: VMRuntimeHistory, permit: RuntimeSessionPermit
  ) {
    self.directory = directory
    self.files = files
    self.backend = backend
    self.history = history
    self.permit = permit
    vmID = permit.vmID
    sessionID = permit.sessionID
    controller = VMController(backend: backend, history: history)
  }

  /// This preparation precedes launch. No receipt or disk identifier can substitute for
  /// the actual live writer and newly minted permit. Failed preparation leaves intent.
  package static func open(
    in directory: URL, vmID: UUID, lock: VMLock,
    backend: any BackendSettlementSource, files: any RecordedRuntimeStore = VMFiles()
  ) async throws -> RecordedRuntimeOwner {
    guard lock.owns(directory), !backend.isActive else {
      throw failure("Runtime preparation is not quiescent.")
    }
    let permit = try await files.beginOwnership(in: directory, vmID: vmID, lock: lock)
    guard permit.vmID == vmID, permit.owns(lock) else {
      throw failure("Runtime permit does not match its actual writer.")
    }
    try backend.bindRecordedSession(sessionID: permit.sessionID)
    let history = try await VMRuntimeHistory.open(
      in: directory, files: files, lock: lock, permit: permit)
    let owner = RecordedRuntimeOwner(
      directory: directory, files: files, backend: backend, history: history, permit: permit)
    owner.retainedLifetime = owner
    return owner
  }

  package func perform(_ operation: LifecycleOperation) async throws {
    guard ownershipState == .unsettled else {
      throw Self.failure("This recorded owner no longer admits lifecycle operations.")
    }
    try await controller.perform(operation)
  }

  /// An owned transaction survives cancellation of a waiter. It never requests shutdown
  /// or signals a child; live runtimes require explicit caller recovery first.
  package func settleOwnership() async throws {
    if settlement == nil {
      guard !backend.isActive, ownershipState == .unsettled else {
        throw Self.failure("Actual runtime cleanup must finish before ownership settlement.")
      }
      try controller.sealOperationsForOwnership()
      ownershipState = .settling
      settlement = Task { @MainActor [self] in
        do {
          let backendReceipt = try await backend.freezeForSettlement(sessionID: sessionID)
          let historyReceipt = try await controller.sealRecordedHistory(
            history: history, permit: permit, backendReceipt: backendReceipt)
          let receipt = try RuntimeSettlementReceipt(
            source: self, permit: permit, backend: backendReceipt, history: historyReceipt)
          try await files.commitOwnership(in: directory, receipt: receipt)
          ownershipState = .settled
          onOwnershipSettled?()
          retainedLifetime = nil
          return .success(())
        } catch {
          let error =
            (error as? VMError) ?? Self.failure("Recorded ownership could not be settled.")
          ownershipState = .recoveryRequired
          ownershipError = error
          // This is intentional recovery custody: no implicit lease release, rollback,
          // orphan adoption or second transaction after an uncertain commit.
          return .failure(error)
        }
      }
    }
    guard let settlement else { throw Self.failure("Ownership settlement was not created.") }
    try await settlement.value.get()
  }

  private static func failure(_ message: String) -> VMError {
    VMError(
      .storage, message,
      recovery:
        "Preserve runtime intent, history and writer ownership; use read-only inspection before recovery."
    )
  }
}
