// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Combine
import Foundation
import VMStorage

/// Owns lifecycle decisions and ordered advisory history. Stop requests are not stop evidence.
@MainActor public final class VMController: ObservableObject {
  @Published public private(set) var state = VMState.stopped
  @Published public private(set) var lastError: VMError?
  @Published public private(set) var isSettling = false
  public private(set) var historyError: VMError?
  /// Sticky failure for this runtime session, including failures followed by a guest shutdown.
  public private(set) var runtimeError: VMError?
  public var onQuiescent: (@MainActor () -> Void)?
  public var onStateChange: (@MainActor (VMState) -> Void)?
  public var onError: (@MainActor (VMError) -> Void)?
  private var model = VMStateMachine()
  private let backend: any MachineBackend
  private let history: (any LifecycleHistory)?
  private var historyTail: Task<Result<Void, VMError>, Never>?
  private var pendingRecords = 0
  private var notifiedQuiescent = false
  private var recordedRunEnded = false
  private var pendingOperations = 0
  private var settlementTask: Task<Void, Never>?
  private var ownershipSealed = false
  public var isActive: Bool { backend.isActive }

  public init(backend: any MachineBackend, history: (any LifecycleHistory)? = nil) {
    self.backend = backend
    self.history = history
    backend.onGuestStopped = { [weak self] in self?.observedStop() }
    backend.onFailure = { [weak self] error in
      guard let self else { return }
      self.lastError = error
      self.runtimeError = self.runtimeError ?? error
      if let id = self.model.operationID {
        try? self.model.fail(id: id)
      } else {
        self.model = VMStateMachine(state: .failed)
      }
      self.publish()
      self.enqueue(.failed)
      self.onError?(error)
      self.notifyWhenSafe()
    }
  }

  public func perform(_ operation: LifecycleOperation) async throws {
    guard !ownershipSealed else {
      throw VMError(
        .invalidTransition, "This recorded runtime is sealed for ownership settlement.",
        recovery: "Inspect its settlement result before opening another runtime session.")
    }
    guard backend.capabilities.operations.contains(operation) else {
      throw VMError(
        .unsupported, "Backend does not implement that operation.",
        recovery: "Review this backend's capabilities.")
    }
    guard operation != .start || (!isSettling && !recordedRunEnded && pendingOperations == 0) else {
      throw VMError(
        .invalidTransition, "The recorded run is still settling or has ended.",
        recovery: "Wait for history persistence and open a new recorded session.")
    }
    guard pendingRecords < 64 || operation == .forceStop else {
      throw VMError(
        .busy, "Lifecycle history is still being saved.", recovery: "Wait before another operation."
      )
    }
    let id = try model.begin(operation)
    pendingOperations += 1
    defer {
      pendingOperations -= 1
      notifyWhenSafe()
    }
    var invokedBackend = false
    var launchIntentSaved = false
    lastError = nil
    if operation == .start {
      notifiedQuiescent = false
    }
    publish()
    do {
      if operation == .start, let intent = enqueue(.pending) {
        try await intent.value.get()
        launchIntentSaved = true
        try Task.checkCancellation()
        guard model.operationID == id else {
          throw VMError(
            .staleOperation, "Launch intent was superseded.",
            recovery: "Inspect the current state before retrying.")
        }
      } else if operation != .start {
        enqueue(.pending)
      }
      try Task.checkCancellation()
      invokedBackend = true
      switch operation {
      case .start: try await backend.start()
      case .stop:
        try backend.requestStop()
        return  // Only observed stop completes this operation.
      case .forceStop:
        try await backend.forceStop()
        guard !backend.isActive else {
          throw VMError(
            .backendFailure, "Backend completed force stop while still active.",
            recovery: "Writer ownership is retained; inspect the backend.")
        }
      case .pause: try await backend.pause()
      case .resume: try await backend.resume()
      case .suspend, .restore:
        throw VMError(
          .unsupported, "Suspend/restore is not implemented.", recovery: "Use clean shutdown.")
      }
      if model.operationID == id {
        try Task.checkCancellation()
        if operation == .start, !backend.isActive {
          throw VMError(
            .backendFailure, "Backend completed start while inactive.",
            recovery: "The VM is not running. Preserve its files and inspect the backend.")
        }
        try model.complete(id: id)
        if operation == .forceStop {
          observedStop()
        } else {
          publish()
          enqueue(.pending)
        }
      }
      notifyWhenSafe()
    } catch {
      let canRecordFailure = model.operationID == id || model.operationID == nil
      if model.operationID == id {
        try model.fail(id: id)
      } else if model.operationID == nil {
        // A delegate may have completed stop while its initiating native call still
        // awaited. If that call then fails, the final advisory outcome is failure.
        model = VMStateMachine(state: .failed)
      }
      let failure =
        (error as? VMError)
        ?? (error is CancellationError
          ? VMError(
            .cancelled, "The VM operation was cancelled.",
            recovery:
              "Any active guest still owns its disk. Shut down in the guest or explicitly confirm Force Stop."
          )
          : VMError(
            .backendFailure, "The VM operation failed.",
            recovery: "Inspect the current backend state before retrying."))
      lastError = failure
      runtimeError = runtimeError ?? failure
      publish()
      if canRecordFailure && (invokedBackend || launchIntentSaved) { enqueue(.failed) }
      onError?(failure)
      notifyWhenSafe()
      throw error
    }
  }

  /// Drain controller-owned ordered writes before releasing the runtime owner.
  public func finishPersistence() async {
    while pendingRecords > 0 {
      guard let tail = historyTail else { return }
      _ = await tail.value
    }
  }

  /// Retain the runtime owner until the actual backend is inactive and ordered history has
  /// settled, then report any session failure. This never requests shutdown or force stop.
  /// The owned task does not inherit caller cancellation: cancelling a waiter must not drop
  /// an active guest's ownership or repeatedly retry an already-cancelled sleep.
  public func settleRuntime() async throws {
    if settlementTask == nil {
      settlementTask = Task { @MainActor [self] in
        while backend.isActive || pendingOperations > 0 {
          try? await Task.sleep(for: .milliseconds(250))
        }
        reconcileMissingCompletion()
        await finishPersistence()
        notifyWhenSafe()
      }
    }
    await settlementTask?.value
    settlementTask = nil
    if let failure = runtimeError ?? historyError { throw failure }
  }

  private func reconcileMissingCompletion() {
    guard !backend.isActive, pendingOperations == 0,
      model.operationID != nil || (model.state != .stopped && model.state != .failed)
    else { return }
    let failure = VMError(
      .backendFailure, "Backend became inactive without a matching lifecycle completion.",
      recovery:
        "Preserve the VM files and review guest recovery. No guest shutdown or disk consistency is inferred."
    )
    model = VMStateMachine(state: .failed)
    lastError = failure
    runtimeError = runtimeError ?? failure
    publish()
    enqueue(.failed)
    onError?(failure)
  }

  private func observedStop() {
    // The recorded owner has gated operations and will classify its frozen receipt.
    // A duplicated delegate notification cannot append to already sealed history.
    guard !ownershipSealed else { return }
    guard !backend.isActive else {
      let error = VMError(
        .backendFailure, "Backend signaled stop while still active.",
        recovery: "Writer ownership is retained; inspect the backend.")
      lastError = error
      runtimeError = runtimeError ?? error
      model = VMStateMachine(state: .failed)
      publish()
      enqueue(.failed)
      onError?(error)
      return
    }
    let observation = backend.terminationObservation
    if runtimeError != nil
      || (observation != .guestStopObserved
        && observation != .explicitForcedTermination)
    {
      let failure =
        runtimeError
        ?? VMError(
          .backendFailure, "The runtime exited without a verified guest shutdown.",
          recovery:
            "Preserve the VM and review guest recovery; process exit is not a clean guest stop.")
      runtimeError = failure
      lastError = failure
      model = VMStateMachine(state: .failed)
      publish()
      enqueue(.failed)
      onError?(failure)
    } else {
      model.backendStopped()
      publish()
      enqueue(observation == .explicitForcedTermination ? .forcedStopped : .guestStopped)
    }
    notifyWhenSafe()
  }

  /// Gates this actual controller before another suspension can allow a new lifecycle call.
  /// Live or in-flight runtimes remain controllable for explicit recovery and cannot seal.
  package func sealOperationsForOwnership() throws {
    guard !ownershipSealed, !backend.isActive, pendingOperations == 0,
      model.operationID == nil
    else {
      throw VMError(
        .busy, "Runtime operations have not become quiescent.",
        recovery: "Retain the owner and finish actual runtime recovery before settlement.")
    }
    ownershipSealed = true
  }

  /// Produces history evidence only from this controller's exact retained backend/history.
  /// Runtime failure is recorded honestly; only history failure prevents a durable receipt.
  package func sealRecordedHistory(
    history expectedHistory: VMRuntimeHistory, permit: RuntimeSessionPermit,
    backendReceipt: BackendQuiescenceReceipt
  ) async throws -> RuntimeHistoryCommitReceipt {
    guard ownershipSealed, !backend.isActive, pendingOperations == 0,
      model.operationID == nil, let history, history === expectedHistory,
      backendReceipt.sessionID == permit.sessionID,
      backendReceipt.sourceID == ObjectIdentifier(backend)
    else {
      throw VMError(
        .invalidTransition, "Recorded runtime evidence does not match its owner.",
        recovery:
          "Preserve the unsettled session; evidence cannot be reconstructed from identifiers.")
    }
    await finishPersistence()
    guard historyError == nil else { throw historyError ?? Self.settlementHistoryFailure() }
    let outcome: RuntimeOutcome
    if runtimeError != nil || backendReceipt.launchDisposition == .neverInvoked
      || (backendReceipt.terminationObservation != .guestStopObserved
        && backendReceipt.terminationObservation != .explicitForcedTermination)
    {
      outcome = .failed
      model = VMStateMachine(state: .failed)
    } else {
      outcome =
        backendReceipt.terminationObservation == .explicitForcedTermination
        ? .forcedStopped : .guestStopped
      model = VMStateMachine(state: .stopped)
    }
    publish()
    guard let finalWrite = enqueue(outcome) else { throw Self.settlementHistoryFailure() }
    try await finalWrite.value.get()
    await finishPersistence()
    guard !backend.isActive, pendingOperations == 0, pendingRecords == 0,
      historyError == nil
    else { throw Self.settlementHistoryFailure() }
    return try await expectedHistory.sealCommittedHistory(for: permit)
  }

  private static func settlementHistoryFailure() -> VMError {
    VMError(
      .storage, "Final recorded history is not durably settled.",
      recovery:
        "Retain runtime intent and writer ownership; no automatic repair or retry is performed.")
  }

  @discardableResult private func enqueue(_ outcome: RuntimeOutcome) -> Task<
    Result<Void, VMError>, Never
  >? {
    guard let history else { return nil }
    let snapshot = RuntimeSnapshot(
      state: model.state, operation: model.operation,
      backendActive: backend.isActive, outcome: outcome)
    let previous = historyTail
    pendingRecords += 1
    isSettling = true
    // Native delegate callbacks are synchronous. This owned chain serializes their
    // off-main storage writes; active ownership and finishPersistence bound its lifetime.
    let task = Task { @MainActor [self, history] in
      if let previous { _ = await previous.value }
      let result: Result<Void, VMError>
      do {
        try await history.persist(snapshot)
        result = .success(())
      } catch {
        let failure = VMError(
          .storage, "Lifecycle history could not be saved.",
          recovery:
            "Preserve VM files. Active ownership is retained until the backend stops; review history afterward."
        )
        historyError = failure
        lastError = failure
        onError?(failure)
        result = .failure(failure)
      }
      pendingRecords -= 1
      isSettling = pendingRecords > 0
      notifyWhenSafe()
      return result
    }
    historyTail = task
    return task
  }

  private func notifyWhenSafe() {
    guard !backend.isActive, model.operationID == nil, pendingOperations == 0,
      model.state == .stopped || model.state == .failed,
      pendingRecords == 0, !notifiedQuiescent
    else { return }
    notifiedQuiescent = true
    if history != nil { recordedRunEnded = true }
    onQuiescent?()
  }
  private func publish() {
    state = model.state
    onStateChange?(state)
  }
}
