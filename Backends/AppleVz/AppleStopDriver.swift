// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// The same main-actor ledger drives the public VZ adapter and synthetic ordering
/// tests. Pending means the actual native completion has not arrived, even when
/// its awaiting task is cancelled. No state alone establishes guest shutdown.
@MainActor
final class AppleStopDriver {
  typealias NativeCompletion = @MainActor (Result<Void, any Error>) -> Void
  typealias NativeOperation = @MainActor (@escaping NativeCompletion) -> Void

  struct FrozenSettlement {
    let launchDisposition: BackendLaunchDisposition
    let terminationObservation: BackendTerminationObservation
  }

  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  private(set) var lastFailure: VMError?
  private(set) var terminationObservation = BackendTerminationObservation.notObserved
  var isActive: Bool { pending != nil || awaitingTerminalCallback || nativeIsActive() }
  var isOperationPending: Bool { pending != nil }

  private let nativeIdentity: ObjectIdentifier?
  private let nativeIsActive: @MainActor () -> Bool
  private let nativeIsError: @MainActor () -> Bool
  private let canStart: @MainActor () -> Bool
  private let canStop: @MainActor () -> Bool
  private let canPause: @MainActor () -> Bool
  private let canResume: @MainActor () -> Bool
  private let nativeStart: NativeOperation
  private let nativeStop: NativeOperation
  private let nativePause: NativeOperation
  private let nativeResume: NativeOperation
  private let nativeRequestStop: @MainActor () throws -> Void
  private var pending: UUID?
  private var recordedSessionID: UUID?
  private var operationAttempted = false
  private var startAttempted = false
  private var nativeStartInvoked = false
  private var awaitingTerminalCallback = false
  private var startCompleted = false
  private var sealed = false
  private var nativeErrorObserved = false
  private var stoppedNotified = false
  private var failureNotified = false

  init(
    nativeIdentity: ObjectIdentifier,
    isActive: @escaping @MainActor () -> Bool,
    isError: @escaping @MainActor () -> Bool = { false },
    canStart: @escaping @MainActor () -> Bool = { true },
    canStop: @escaping @MainActor () -> Bool,
    canPause: @escaping @MainActor () -> Bool = { true },
    canResume: @escaping @MainActor () -> Bool = { true },
    start: @escaping NativeOperation, stop: @escaping NativeOperation,
    pause: @escaping NativeOperation, resume: @escaping NativeOperation,
    requestStop: @escaping @MainActor () throws -> Void,
    onGuestStopped: (@MainActor () -> Void)? = nil,
    onFailure: (@MainActor (VMError) -> Void)? = nil
  ) {
    self.nativeIdentity = nativeIdentity
    nativeIsActive = isActive
    nativeIsError = isError
    self.canStart = canStart
    self.canStop = canStop
    self.canPause = canPause
    self.canResume = canResume
    nativeStart = start
    nativeStop = stop
    nativePause = pause
    nativeResume = resume
    nativeRequestStop = requestStop
    self.onGuestStopped = onGuestStopped
    self.onFailure = onFailure
  }

  /// Preserved unbound fixture API; its owned task is not cancelled with a waiter.
  init(
    isActive: @escaping @MainActor () -> Bool,
    canStop: @escaping @MainActor () -> Bool,
    stop: @escaping @MainActor () async throws -> Void
  ) {
    nativeIdentity = nil
    nativeIsActive = isActive
    nativeIsError = { false }
    canStart = { true }
    self.canStop = canStop
    canPause = { true }
    canResume = { true }
    let unavailable: NativeOperation = { completion in completion(.failure(Self.invalid())) }
    nativeStart = unavailable
    nativePause = unavailable
    nativeResume = unavailable
    nativeRequestStop = { throw Self.invalid() }
    nativeStop = { completion in
      Task { @MainActor in
        do {
          try await stop()
          completion(.success(()))
        } catch { completion(.failure(error)) }
      }
    }
  }

  /// Exposure before recording can hide direct legacy native operations. After
  /// binding this handle is for rendering/socket access, never lifecycle control.
  func markUnboundNativeExposure() {
    guard recordedSessionID == nil, !sealed else { return }
    operationAttempted = true
  }

  func bindRecordedSession(sessionID: UUID) throws {
    guard recordedSessionID == nil, !sealed, !operationAttempted,
      !startAttempted, pending == nil, !nativeIsActive(), !nativeIsError()
    else { throw Self.invalid() }
    recordedSessionID = sessionID
  }

  func freezeForSettlement(sessionID: UUID) throws -> FrozenSettlement {
    guard recordedSessionID == sessionID, !sealed, pending == nil, !awaitingTerminalCallback,
      !nativeStartInvoked || startCompleted, !nativeIsActive()
    else { throw Self.invalid() }
    try Task.checkCancellation()
    observeNativeErrorState()
    finishIfInactive()
    guard pending == nil, !awaitingTerminalCallback, !nativeIsActive() else { throw Self.invalid() }
    sealed = true
    return FrozenSettlement(
      launchDisposition: nativeStartInvoked ? .completedAttempt : .neverInvoked,
      terminationObservation: terminationObservation)
  }

  func resetForStart() throws {
    guard recordedSessionID == nil, !sealed, pending == nil, !awaitingTerminalCallback else {
      throw Self.busy()
    }
    operationAttempted = true
    resetLegacyObservation()
  }

  func start() async throws {
    operationAttempted = true
    guard !sealed, pending == nil, !awaitingTerminalCallback,
      recordedSessionID == nil || (!startAttempted && !nativeIsActive() && lastFailure == nil)
    else { throw Self.invalid() }
    startAttempted = true
    if recordedSessionID == nil { resetLegacyObservation() }
    do { try Task.checkCancellation() } catch {
      startCompleted = true
      throw error
    }
    guard canStart() else {
      startCompleted = true
      throw Self.invalid()
    }
    try await perform(.start, native: nativeStart)
  }

  func forceStop() async throws {
    operationAttempted = true
    guard !sealed else { throw Self.invalid() }
    guard pending == nil else { throw Self.busy() }
    // Inactivity is not evidence that this force request terminated anything.
    guard nativeIsActive() else { return }
    guard canStop() else { throw Self.invalid() }
    try Task.checkCancellation()
    try await perform(.forceStop, native: nativeStop)
  }

  func requestStop() throws {
    operationAttempted = true
    guard !sealed, pending == nil, nativeIsActive() else { throw Self.invalid() }
    let token = UUID()
    pending = token
    defer {
      pending = nil
      finishIfInactive()
    }
    do { try nativeRequestStop() } catch {
      latchRecordedFailure(error, operation: .stop)
      throw error
    }
    // A successful request is only a request, never a terminal observation.
  }

  func pause() async throws {
    operationAttempted = true
    guard !sealed, pending == nil, nativeIsActive(), canPause() else { throw Self.invalid() }
    try Task.checkCancellation()
    try await perform(.pause, native: nativePause)
  }

  func resume() async throws {
    operationAttempted = true
    guard !sealed, pending == nil, nativeIsActive(), canResume() else { throw Self.invalid() }
    try Task.checkCancellation()
    try await perform(.resume, native: nativeResume)
  }

  private func perform(_ operation: LifecycleOperation, native: NativeOperation) async throws {
    let token = UUID()
    pending = token
    // CheckedContinuation has no cancellation handler that can consume a native
    // completion. The SDK-held callback retains this ledger until actual return.
    try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
      if operation == .start {
        nativeStartInvoked = true
        awaitingTerminalCallback = true
      }
      native { [self] result in
        guard !sealed, pending == token else { return }
        pending = nil
        if operation == .start { startCompleted = true }
        observeNativeErrorState()
        var completion = result
        switch result {
        case .failure(let error):
          if operation == .start && !nativeIsActive() { awaitingTerminalCallback = false }
          latchRecordedFailure(error, operation: operation)
        case .success:
          if operation == .forceStop {
            if nativeIsActive() {
              let failure = Self.failure("Native stop completed while the VM remains active.")
              latchRecordedFailure(failure, operation: operation)
              completion = .failure(failure)
            } else {
              awaitingTerminalCallback = false
              terminationObservation =
                nativeErrorObserved ? .runtimeExited : .explicitForcedTermination
            }
          }
        }
        finishIfInactive()
        waiter.resume(with: completion)
      }
    }
    try Task.checkCancellation()
  }

  func guestDidStop(from identity: ObjectIdentifier) {
    guard admitCallback(identity) else { return }
    awaitingTerminalCallback = false
    if recordedSessionID != nil && !nativeStartInvoked {
      nativeErrorObserved = true
      lastFailure = lastFailure ?? Self.failure("A native callback preceded this recorded launch.")
      terminationObservation = .runtimeExited
      finishIfInactive()
      return
    }
    observeNativeErrorState()
    if !nativeErrorObserved, terminationObservation != .explicitForcedTermination {
      terminationObservation = .guestStopObserved
    }
    finishIfInactive()
  }

  func didStopWithError(_ error: VMError, from identity: ObjectIdentifier) {
    guard admitCallback(identity) else { return }
    awaitingTerminalCallback = false
    nativeErrorObserved = true
    if lastFailure == nil { lastFailure = error }
    terminationObservation = .runtimeExited
    finishIfInactive()
  }

  /// Existing unbound event-order fixtures cannot supply a real native identity.
  func guestDidStop() {
    guard recordedSessionID == nil, !sealed else { return }
    operationAttempted = true
    awaitingTerminalCallback = false
    if !nativeErrorObserved, terminationObservation != .explicitForcedTermination {
      terminationObservation = .guestStopObserved
    }
    finishIfInactive()
  }

  func didStopWithError() {
    guard recordedSessionID == nil, !sealed else { return }
    operationAttempted = true
    awaitingTerminalCallback = false
    nativeErrorObserved = true
    lastFailure = lastFailure ?? Self.failure("The native VM stopped with an error.")
    terminationObservation = .runtimeExited
    finishIfInactive()
  }

  func nativeStateChanged() {
    guard !sealed else { return }
    operationAttempted = true
    observeNativeErrorState()
    finishIfInactive()
  }

  private func admitCallback(_ identity: ObjectIdentifier) -> Bool {
    guard !sealed, nativeIdentity == identity else { return false }
    operationAttempted = true
    return true
  }

  private func observeNativeErrorState() {
    guard nativeIsError() else { return }
    nativeErrorObserved = true
    lastFailure = lastFailure ?? Self.failure("The native VM is in an error state.")
    terminationObservation = .runtimeExited
  }

  private func latchRecordedFailure(_ error: any Error, operation: LifecycleOperation) {
    guard recordedSessionID != nil else { return }
    nativeErrorObserved = true
    lastFailure =
      lastFailure ?? (error as? VMError)
      ?? Self.failure("The native VM \(operation.rawValue) operation failed.")
    terminationObservation = .runtimeExited
  }

  private func finishIfInactive() {
    guard !sealed, pending == nil, !awaitingTerminalCallback, !nativeIsActive() else { return }
    if let lastFailure, !failureNotified {
      failureNotified = true
      onFailure?(lastFailure)
    } else if terminationObservation == .guestStopObserved
      || terminationObservation == .explicitForcedTermination, !stoppedNotified
    {
      stoppedNotified = true
      onGuestStopped?()
    }
  }

  private func resetLegacyObservation() {
    nativeErrorObserved = false
    lastFailure = nil
    terminationObservation = .notObserved
    stoppedNotified = false
    failureNotified = false
  }

  private static func invalid() -> VMError {
    VMError(
      .invalidTransition, "The native VM operation does not match its current ownership state.",
      recovery: "Retain this runtime and inspect its actual native completion before recovery.")
  }

  private static func busy() -> VMError {
    VMError(
      .busy, "A native operation is still pending.",
      recovery: "Wait for its actual native completion before another operation.")
  }

  private static func failure(_ message: String) -> VMError {
    VMError(
      .backendFailure, message,
      recovery: "Retain writer ownership and inspect the original native VM before recovery.")
  }
}
