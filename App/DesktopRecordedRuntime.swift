// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMCore
import VMStorage

/// The desktop's actual writer/recorded-owner lifetime. Preparation and durable
/// settlement failures keep custody even when the native VM is already inactive.
@MainActor
final class DesktopRecordedRuntime {
  enum Phase { case idle, preparing, prepared, settling, settled, recoveryRequired }
  private(set) var phase = Phase.idle
  private(set) var owner: RecordedRuntimeOwner?
  private(set) var lastFailure: VMError?
  var controller: VMController? { owner?.controller }
  var isBusy: Bool { backend?.isActive == true || (phase != .idle && phase != .settled) }
  var onStateChange: (@MainActor (VMState) -> Void)?
  var onError: (@MainActor (VMError) -> Void)?
  var onSettled: (@MainActor () -> Void)?

  private var lock: VMLock?
  private var backend: (any BackendSettlementSource)?
  private var retainedLifetime: DesktopRecordedRuntime?
  private var settlement: Task<Result<Void, VMError>, Never>?

  init(lock: VMLock, backend: any BackendSettlementSource) {
    self.lock = lock
    self.backend = backend
  }

  func prepare(
    in directory: URL, vmID: UUID, files: any RecordedRuntimeStore = VMFiles()
  ) async throws {
    guard phase == .idle, let lock, let backend else {
      throw Self.failure("This desktop runtime was already prepared.")
    }
    phase = .preparing
    retainedLifetime = self
    do {
      let prepared = try await RecordedRuntimeOwner.open(
        in: directory, vmID: vmID, lock: lock, backend: backend, files: files)
      owner = prepared
      prepared.controller.onStateChange = { [weak self, weak prepared] state in
        guard let self, let prepared, self.owner === prepared else { return }
        self.onStateChange?(state)
      }
      prepared.controller.onError = { [weak self, weak prepared] error in
        guard let self, let prepared, self.owner === prepared else { return }
        self.onError?(error)
      }
      prepared.controller.onQuiescent = { [weak self, weak prepared] in
        guard let self, let prepared, self.owner === prepared else { return }
        self.scheduleSettlement(for: prepared)
      }
      phase = .prepared
    } catch {
      let failure = (error as? VMError) ?? Self.failure("Recorded runtime preparation failed.")
      lastFailure = failure
      phase = .recoveryRequired
      onError?(failure)
      throw failure
    }
  }

  func perform(_ operation: LifecycleOperation) async throws {
    guard phase == .prepared, let owner else {
      throw Self.failure("This desktop runtime does not admit lifecycle operations.")
    }
    try await owner.perform(operation)
  }

  /// This never initiates settlement from a state snapshot. Only the exact
  /// controller's terminal/completion/history notification schedules the task.
  func waitForSettlement() async throws {
    if phase == .settled { return }
    if phase == .recoveryRequired {
      throw lastFailure ?? Self.failure("Recorded recovery is required.")
    }
    guard let settlement else {
      throw VMError(
        .busy, "Actual runtime cleanup has not completed.",
        recovery: "Keep this VM window open and wait for its native lifecycle completion.")
    }
    try await settlement.value.get()
  }

  private func scheduleSettlement(for prepared: RecordedRuntimeOwner) {
    guard owner === prepared, phase == .prepared, settlement == nil else { return }
    phase = .settling
    settlement = Task { @MainActor [self, prepared] in
      do {
        try await prepared.settleOwnership()
        guard owner === prepared else {
          throw Self.failure("Recorded desktop settlement does not match its actual owner.")
        }
        phase = .settled
        owner = nil
        backend = nil
        lock = nil
        onSettled?()
        retainedLifetime = nil
        settlement = nil
        return .success(())
      } catch {
        let failure = (error as? VMError) ?? Self.failure("Recorded desktop settlement failed.")
        lastFailure = failure
        phase = .recoveryRequired
        onError?(failure)
        // Keep this task/result, actual owner, backend and lock. No retry, metadata
        // repair, fake receipt or inactive-state shortcut can release custody.
        return .failure(failure)
      }
    }
  }

  private static func failure(_ message: String) -> VMError {
    VMError(
      .storage, message,
      recovery:
        "Keep the actual session and writer ownership; use read-only inspection before recovery.")
  }
}
