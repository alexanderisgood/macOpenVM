// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore

@testable import AppleVz

enum AppleNativeOperation: String, CaseIterable, Sendable, Hashable {
  case start, forceStop, pause, resume
}

private enum AppleNativeFixtureError: Error { case operationFailed }

/// Actual completion gates for the production driver; no VZ object or guest is created.
@MainActor private final class AppleNativeCompletionFixture {
  let identity = NSObject()
  var active = false
  var errorState = false
  var startable = true
  var stoppable = true
  var completeUnexpectedCalls = false
  private(set) var calls: [AppleNativeOperation] = []
  private(set) var stopRequests = 0
  private var completions: [AppleNativeOperation: AppleStopDriver.NativeCompletion] = [:]
  private var entered: [AppleNativeOperation: CheckedContinuation<Void, Never>] = [:]

  func makeDriver() -> AppleStopDriver {
    AppleStopDriver(
      nativeIdentity: ObjectIdentifier(identity), isActive: { self.active },
      isError: { self.errorState }, canStart: { self.startable }, canStop: { self.stoppable },
      start: { self.submit(.start, completion: $0) },
      stop: { self.submit(.forceStop, completion: $0) },
      pause: { self.submit(.pause, completion: $0) },
      resume: { self.submit(.resume, completion: $0) },
      requestStop: { self.stopRequests += 1 })
  }

  private func submit(
    _ operation: AppleNativeOperation, completion: @escaping AppleStopDriver.NativeCompletion
  ) {
    calls.append(operation)
    if completeUnexpectedCalls {
      active = false
      completion(.success(()))
      return
    }
    completions[operation] = completion
    entered.removeValue(forKey: operation)?.resume()
  }

  func waitFor(_ operation: AppleNativeOperation) async {
    if completions[operation] == nil {
      await withCheckedContinuation { entered[operation] = $0 }
    }
  }

  func complete(
    _ operation: AppleNativeOperation, result: Result<Void, any Error> = .success(()),
    active: Bool, error: Bool = false
  ) {
    self.active = active
    errorState = error
    completions.removeValue(forKey: operation)?(result)
  }
}

/// Only the typed receipt wrapper is synthetic; admission and sealing use the real driver.
@MainActor private final class AppleSettlementFixtureSource: BackendSettlementSource {
  let capabilities = BackendCapabilities(
    id: .appleVz, operations: [.start, .stop, .forceStop, .pause, .resume], limitations: [])
  let native = AppleNativeCompletionFixture()
  lazy var driver = native.makeDriver()
  var onGuestStopped: (@MainActor () -> Void)? {
    didSet { driver.onGuestStopped = onGuestStopped }
  }
  var onFailure: (@MainActor (VMError) -> Void)? {
    didSet { driver.onFailure = onFailure }
  }
  var isActive: Bool { driver.isActive }
  var terminationObservation: BackendTerminationObservation { driver.terminationObservation }

  func start() async throws { try await driver.start() }
  func requestStop() throws { try driver.requestStop() }
  func forceStop() async throws { try await driver.forceStop() }
  func pause() async throws { try await driver.pause() }
  func resume() async throws { try await driver.resume() }
  func bindRecordedSession(sessionID: UUID) throws {
    try driver.bindRecordedSession(sessionID: sessionID)
  }
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    let frozen = try driver.freezeForSettlement(sessionID: sessionID)
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID, launchDisposition: frozen.launchDisposition,
      terminationObservation: frozen.terminationObservation)
  }
}

@MainActor private final class WeakAppleSettlementSource {
  weak var value: AppleSettlementFixtureSource?
}

@MainActor private final class AppleOrderingHistory: LifecycleHistory {
  private(set) var snapshots: [RuntimeSnapshot] = []
  func persist(_ snapshot: RuntimeSnapshot) async throws { snapshots.append(snapshot) }
}

@MainActor private func invoke(
  _ operation: AppleNativeOperation, driver: AppleStopDriver
) async throws {
  switch operation {
  case .start: try await driver.start()
  case .forceStop: try await driver.forceStop()
  case .pause: try await driver.pause()
  case .resume: try await driver.resume()
  }
}

@MainActor private func startFixture(
  _ native: AppleNativeCompletionFixture, driver: AppleStopDriver
) async throws {
  let task = Task { try await driver.start() }
  await native.waitFor(.start)
  native.complete(.start, active: true)
  try await task.value
}

@Suite("AppleSettlementTests", .serialized)
@MainActor
struct AppleSettlementTests {
  @Test func unusedBoundSourceReceiptRetainsActualSourceAndPermanentlySealsIt() async throws {
    let session = UUID()
    let weakSource = WeakAppleSettlementSource()
    var receipt: BackendQuiescenceReceipt?
    do {
      let source = AppleSettlementFixtureSource()
      weakSource.value = source
      try source.bindRecordedSession(sessionID: session)
      receipt = try await source.freezeForSettlement(sessionID: session)
      #expect(receipt?.sourceID == ObjectIdentifier(source) && receipt?.sessionID == session)
      #expect(receipt?.launchDisposition == .neverInvoked)
      #expect(receipt?.terminationObservation == .notObserved && !source.isActive)
      source.native.completeUnexpectedCalls = true
      await #expect(throws: VMError.self) { try await source.start() }
      await #expect(throws: VMError.self) { try await source.forceStop() }
      await #expect(throws: VMError.self) { try await source.pause() }
      await #expect(throws: VMError.self) { try await source.resume() }
      #expect(throws: VMError.self) { try source.requestStop() }
      await #expect(throws: VMError.self) {
        try await source.freezeForSettlement(sessionID: session)
      }
      #expect(throws: VMError.self) { try source.bindRecordedSession(sessionID: UUID()) }
      #expect(source.native.calls.isEmpty && source.native.stopRequests == 0)
    }
    #expect(weakSource.value != nil)
    withExtendedLifetime(receipt) {}
    receipt = nil
    #expect(weakSource.value == nil)
  }

  @Test func wrongOrRepeatedBindingAndWrongSessionCannotProduceReceipt() throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: UUID()) }
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    #expect(throws: VMError.self) { try driver.bindRecordedSession(sessionID: session) }
    #expect(throws: VMError.self) { try driver.bindRecordedSession(sessionID: UUID()) }
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: UUID()) }
    #expect(!driver.isActive && native.calls.isEmpty)
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(
      frozen.launchDisposition == .neverInvoked && frozen.terminationObservation == .notObserved)
  }

  @Test(arguments: AppleNativeOperation.allCases)
  func nativeCompletionPendingBlocksReceiptAndCallbackDelivery(
    operation: AppleNativeOperation
  ) async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    if operation != .start { try await startFixture(native, driver: driver) }
    var stops = 0
    driver.onGuestStopped = { stops += 1 }
    let task = Task { try await invoke(operation, driver: driver) }
    await native.waitFor(operation)
    native.active = false
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    #expect(driver.isActive && driver.isOperationPending && stops == 0)
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: session) }
    native.complete(operation, active: false)
    try await task.value
    #expect(!driver.isActive && !driver.isOperationPending && stops == 1)
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.launchDisposition == .completedAttempt)
    #expect(
      frozen.terminationObservation
        == (operation == .forceStop ? .explicitForcedTermination : .guestStopObserved))
  }

  @Test(arguments: AppleNativeOperation.allCases)
  func cancellingWaiterRetainsNativeOperationUntilItsActualCompletion(
    operation: AppleNativeOperation
  ) async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    if operation != .start { try await startFixture(native, driver: driver) }
    let task = Task { try await invoke(operation, driver: driver) }
    await native.waitFor(operation)
    native.active = false
    task.cancel()
    await Task.yield()
    #expect(driver.isActive && driver.isOperationPending)
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: session) }
    #expect(native.calls.filter { $0 == operation }.count == 1)
    native.complete(operation, active: false)
    do {
      try await task.value
      Issue.record("Expected the cancelled waiter to reject after the actual native completion")
    } catch { #expect(error is CancellationError) }
    #expect(!driver.isOperationPending)
    if operation == .forceStop {
      #expect(!driver.isActive && driver.terminationObservation == .explicitForcedTermination)
    } else {
      // Completing start/pause/resume is not a terminal notification, including
      // when the requester was cancelled and the native state is already stopped.
      #expect(driver.isActive && driver.terminationObservation == .notObserved)
      #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: session) }
      driver.guestDidStop(from: ObjectIdentifier(native.identity))
      #expect(!driver.isActive)
    }
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.launchDisposition == .completedAttempt)
    #expect(
      frozen.terminationObservation
        == (operation == .forceStop ? .explicitForcedTermination : .guestStopObserved))
  }

  @Test func foreignAndLateCallbacksCannotSupplyOrChangeTerminationEvidence() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    try await startFixture(native, driver: driver)
    var stops = 0
    var failures = 0
    driver.onGuestStopped = { stops += 1 }
    driver.onFailure = { _ in failures += 1 }
    let foreign = NSObject()
    driver.guestDidStop(from: ObjectIdentifier(foreign))
    driver.didStopWithError(appleFixtureFailure(), from: ObjectIdentifier(foreign))
    #expect(driver.isActive && driver.terminationObservation == .notObserved)
    #expect(driver.lastFailure == nil && stops == 0 && failures == 0)
    native.active = false
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    #expect(stops == 1 && failures == 0)
    let frozen = try driver.freezeForSettlement(sessionID: session)
    driver.didStopWithError(appleFixtureFailure(), from: ObjectIdentifier(native.identity))
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    driver.nativeStateChanged()
    #expect(frozen.terminationObservation == .guestStopObserved)
    #expect(driver.terminationObservation == frozen.terminationObservation)
    #expect(stops == 1 && failures == 0 && driver.lastFailure == nil)
  }

  @Test func forceCompletionWaitsAndNativeErrorCannotBecomeGuestShutdown() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    try await startFixture(native, driver: driver)
    var stops = 0
    var failures = 0
    driver.onGuestStopped = { stops += 1 }
    driver.onFailure = { _ in failures += 1 }
    let task = Task { try await driver.forceStop() }
    await native.waitFor(.forceStop)
    native.active = false
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    driver.didStopWithError(appleFixtureFailure(), from: ObjectIdentifier(native.identity))
    #expect(driver.isActive && stops == 0 && failures == 0)
    native.complete(.forceStop, active: false, error: true)
    do { try await task.value } catch { #expect(error is VMError) }
    #expect(!driver.isActive && failures == 1 && driver.lastFailure != nil)
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.terminationObservation == .runtimeExited)
    #expect(driver.terminationObservation == .runtimeExited && failures == 1)
  }

  @Test func confirmedForceCannotBeDowngradedByQueuedGuestCallback() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    try await startFixture(native, driver: driver)
    let task = Task { try await driver.forceStop() }
    await native.waitFor(.forceStop)
    native.complete(.forceStop, active: false)
    try await task.value
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    #expect(driver.terminationObservation == .explicitForcedTermination)
    #expect(
      try driver.freezeForSettlement(sessionID: session).terminationObservation
        == .explicitForcedTermination)
  }

  @Test func boundBackendAdmitsOneStartAttemptEvenAfterTerminalObservation() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    try driver.bindRecordedSession(sessionID: UUID())
    try await startFixture(native, driver: driver)
    native.active = false
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    native.completeUnexpectedCalls = true
    await #expect(throws: VMError.self) { try await driver.start() }
    #expect(throws: VMError.self) { try driver.resetForStart() }
    #expect(native.calls == [.start])
  }

  @Test func failedStartWithoutNativeRunKeepsAttemptAndCannotBecomeGuestStop() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    let task = Task { try await driver.start() }
    await native.waitFor(.start)
    native.complete(
      .start, result: .failure(AppleNativeFixtureError.operationFailed), active: false)
    do {
      try await task.value
      Issue.record("Expected native start completion failure")
    } catch {}
    #expect(!driver.isActive)
    native.completeUnexpectedCalls = true
    await #expect(throws: VMError.self) { try await driver.start() }
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.launchDisposition == .completedAttempt)
    #expect(frozen.terminationObservation != .guestStopObserved)
  }

  @Test func legacyRunOrControlCannotBeAdoptedAsRecordedSession() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    try await startFixture(native, driver: driver)
    native.active = false
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    #expect(throws: VMError.self) { try driver.bindRecordedSession(sessionID: UUID()) }
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: UUID()) }

    let controlled = AppleNativeCompletionFixture()
    let controlDriver = controlled.makeDriver()
    controlled.active = true
    try controlDriver.requestStop()
    #expect(controlled.stopRequests == 1)
    controlled.active = false
    #expect(throws: VMError.self) { try controlDriver.bindRecordedSession(sessionID: UUID()) }
  }

  @Test func inactiveNativeStateOrErrorWithoutGuestDelegateNeverProvesGuestStop() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    try await startFixture(native, driver: driver)
    native.active = false
    native.errorState = true
    driver.nativeStateChanged()
    #expect(driver.isActive && driver.lastFailure != nil)
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: session) }
    driver.didStopWithError(appleFixtureFailure(), from: ObjectIdentifier(native.identity))
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.launchDisposition == .completedAttempt)
    #expect(frozen.terminationObservation == .runtimeExited)
  }

  @Test func preCancelledStartIsAdmittedOnceButNeverInvokesNativeStart() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    let task = Task { try await driver.start() }
    task.cancel()
    do {
      try await task.value
      Issue.record("Expected pre-cancelled start to reject before native invocation")
    } catch { #expect(error is CancellationError || error is VMError) }
    #expect(native.calls.isEmpty && !driver.isActive && !driver.isOperationPending)
    native.completeUnexpectedCalls = true
    await #expect(throws: VMError.self) { try await driver.start() }
    #expect(native.calls.isEmpty)
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.launchDisposition == .neverInvoked)
    #expect(frozen.terminationObservation != .guestStopObserved)
  }

  @Test func rejectedCanStartConsumesAdmissionButHasNoNativeInvocationEvidence() async throws {
    let native = AppleNativeCompletionFixture()
    native.startable = false
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    await #expect(throws: VMError.self) { try await driver.start() }
    #expect(native.calls.isEmpty && !driver.isActive)
    native.startable = true
    native.completeUnexpectedCalls = true
    await #expect(throws: VMError.self) { try await driver.start() }
    #expect(native.calls.isEmpty)
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.launchDisposition == .neverInvoked)
    #expect(frozen.terminationObservation != .guestStopObserved)
  }

  @Test func ownDelegateWithoutActualNativeStartCannotFabricateGuestStop() throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    var stops = 0
    driver.onGuestStopped = { stops += 1 }
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    #expect(stops == 0 && native.calls.isEmpty)
    do {
      let frozen = try driver.freezeForSettlement(sessionID: session)
      #expect(frozen.launchDisposition == .neverInvoked)
      #expect(frozen.terminationObservation != .guestStopObserved)
    } catch { #expect(error is VMError) }
  }

  @Test func normalStopAcknowledgementRetainsActivityUntilActualGuestDelegate() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    try await startFixture(native, driver: driver)
    var stops = 0
    driver.onGuestStopped = { stops += 1 }
    try driver.requestStop()
    #expect(native.stopRequests == 1 && driver.isActive && stops == 0)
    #expect(driver.terminationObservation == .notObserved)
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: session) }
    native.active = false
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    #expect(!driver.isActive && stops == 1 && native.calls == [.start])
    #expect(
      try driver.freezeForSettlement(sessionID: session).terminationObservation
        == .guestStopObserved)
  }

  @Test func priorOwnLegacyCallbackRefusesAdoptionButForeignCallbackDoesNot() throws {
    let legacy = AppleNativeCompletionFixture()
    let legacyDriver = legacy.makeDriver()
    legacyDriver.guestDidStop(from: ObjectIdentifier(legacy.identity))
    #expect(throws: VMError.self) { try legacyDriver.bindRecordedSession(sessionID: UUID()) }

    let fresh = AppleNativeCompletionFixture()
    let freshDriver = fresh.makeDriver()
    let foreign = NSObject()
    freshDriver.guestDidStop(from: ObjectIdentifier(foreign))
    freshDriver.didStopWithError(appleFixtureFailure(), from: ObjectIdentifier(foreign))
    let session = UUID()
    try freshDriver.bindRecordedSession(sessionID: session)
    let frozen = try freshDriver.freezeForSettlement(sessionID: session)
    #expect(
      frozen.launchDisposition == .neverInvoked && frozen.terminationObservation == .notObserved)
  }

  @Test func unboundNativeExposureCannotLaterAcquireRecordedAuthority() throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    driver.markUnboundNativeExposure()
    #expect(throws: VMError.self) { try driver.bindRecordedSession(sessionID: UUID()) }
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: UUID()) }
    #expect(native.calls.isEmpty && !driver.isActive)
  }

  @Test func boundNativeExposureDoesNotChangeReceiptOrReopenSealedOperations() async throws {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    driver.markUnboundNativeExposure()
    try await startFixture(native, driver: driver)
    driver.markUnboundNativeExposure()
    native.active = false
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(
      frozen.launchDisposition == .completedAttempt
        && frozen.terminationObservation == .guestStopObserved)
    driver.markUnboundNativeExposure()
    native.completeUnexpectedCalls = true
    await #expect(throws: VMError.self) { try await driver.start() }
    #expect(throws: VMError.self) { try driver.bindRecordedSession(sessionID: UUID()) }
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: session) }
    #expect(native.calls == [.start] && driver.lastFailure == nil)
    #expect(driver.terminationObservation == frozen.terminationObservation)
  }

  @Test func stoppedNativeBeforeOwnTerminalDelegateRetainsRecordedActivityAndReceipt()
    async throws
  {
    let native = AppleNativeCompletionFixture()
    let driver = native.makeDriver()
    let session = UUID()
    try driver.bindRecordedSession(sessionID: session)
    try await startFixture(native, driver: driver)
    native.active = false
    #expect(driver.isActive && !driver.isOperationPending)
    #expect(driver.terminationObservation == .notObserved && driver.lastFailure == nil)
    #expect(throws: VMError.self) { try driver.freezeForSettlement(sessionID: session) }
    let foreign = NSObject()
    driver.guestDidStop(from: ObjectIdentifier(foreign))
    driver.didStopWithError(appleFixtureFailure(), from: ObjectIdentifier(foreign))
    #expect(driver.isActive && driver.lastFailure == nil)
    #expect(driver.terminationObservation == .notObserved)
    driver.guestDidStop(from: ObjectIdentifier(native.identity))
    #expect(!driver.isActive && native.calls == [.start])
    let frozen = try driver.freezeForSettlement(sessionID: session)
    #expect(frozen.launchDisposition == .completedAttempt)
    #expect(frozen.terminationObservation == .guestStopObserved)
  }

  @Test(.timeLimit(.minutes(1)))
  func controllerWaitsForOwnDelegateAfterNativeInactivity() async throws {
    try await checkControllerPendingTerminal(cancelWaiter: false)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelledControllerSettlementStillWaitsForOwnDelegateAfterNativeInactivity() async throws {
    try await checkControllerPendingTerminal(cancelWaiter: true)
  }

  private func checkControllerPendingTerminal(cancelWaiter: Bool) async throws {
    let source = AppleSettlementFixtureSource()
    try source.bindRecordedSession(sessionID: UUID())
    let history = AppleOrderingHistory()
    let controller = VMController(backend: source, history: history)
    var quiescent = false
    controller.onQuiescent = { quiescent = true }
    let launch = Task { try await controller.perform(.start) }
    await source.native.waitFor(.start)
    source.native.complete(.start, active: true)
    try await launch.value
    await controller.finishPersistence()
    source.native.active = false
    var settled = false
    let settlement = Task { @MainActor () -> VMError? in
      defer { settled = true }
      do {
        try await controller.settleRuntime()
        return nil
      } catch { return error as? VMError }
    }
    if cancelWaiter { settlement.cancel() }
    // Give the controller's owned polling task a full poll interval. This delay
    // tests non-release only; the following exact delegate supplies stop evidence.
    try await Task.sleep(for: .milliseconds(300))
    #expect(source.isActive && !source.native.active && !source.driver.isOperationPending)
    #expect(!settled && !quiescent && controller.runtimeError == nil)
    #expect(!history.snapshots.contains { $0.outcome == .failed || $0.outcome == .guestStopped })
    let foreign = NSObject()
    source.driver.guestDidStop(from: ObjectIdentifier(foreign))
    #expect(source.isActive && !quiescent && controller.runtimeError == nil)
    source.driver.guestDidStop(from: ObjectIdentifier(source.native.identity))
    #expect(await settlement.value == nil)
    #expect(settled && quiescent && controller.state == .stopped)
    #expect(controller.runtimeError == nil && source.native.calls == [.start])
    #expect(history.snapshots.last?.outcome == .guestStopped)
    #expect(history.snapshots.last?.backendActive == false)
  }

  @Test func successfulNativeStartWithStoppedStateWaitsForRealGuestDelegate() async throws {
    let source = AppleSettlementFixtureSource()
    try source.bindRecordedSession(sessionID: UUID())
    let history = AppleOrderingHistory()
    let controller = VMController(backend: source, history: history)
    let launch = Task { try await controller.perform(.start) }
    await source.native.waitFor(.start)
    source.native.complete(.start, active: false)
    try await launch.value
    await controller.finishPersistence()
    #expect(source.isActive && !source.native.active)
    #expect(controller.runtimeError == nil && source.terminationObservation == .notObserved)
    #expect(!history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .failed })
    source.driver.guestDidStop(from: ObjectIdentifier(source.native.identity))
    try await controller.settleRuntime()
    #expect(!source.isActive && controller.state == .stopped)
    #expect(history.snapshots.last?.outcome == .guestStopped)
  }

  @Test func nativeErrorDelegateAfterStoppedStateCannotBePromotedByLateGuestDelegate()
    async throws
  {
    let source = AppleSettlementFixtureSource()
    let session = UUID()
    try source.bindRecordedSession(sessionID: session)
    let history = AppleOrderingHistory()
    let controller = VMController(backend: source, history: history)
    let launch = Task { try await controller.perform(.start) }
    await source.native.waitFor(.start)
    source.native.complete(.start, active: true)
    try await launch.value
    source.native.active = false
    #expect(source.isActive && controller.runtimeError == nil)
    let failure = appleFixtureFailure()
    source.driver.didStopWithError(failure, from: ObjectIdentifier(source.native.identity))
    source.driver.guestDidStop(from: ObjectIdentifier(source.native.identity))
    await #expect(throws: VMError.self) { try await controller.settleRuntime() }
    #expect(!source.isActive && controller.runtimeError == failure && controller.state == .failed)
    #expect(history.snapshots.last?.outcome == .failed)
    #expect(
      !history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .forcedStopped })
    let frozen = try source.driver.freezeForSettlement(sessionID: session)
    #expect(frozen.terminationObservation == .runtimeExited)
  }

  @Test func forceRequestAfterNativeInactivityCannotInventForceCompletion() async throws {
    let source = AppleSettlementFixtureSource()
    try source.bindRecordedSession(sessionID: UUID())
    let history = AppleOrderingHistory()
    let controller = VMController(backend: source, history: history)
    let launch = Task { try await controller.perform(.start) }
    await source.native.waitFor(.start)
    source.native.complete(.start, active: true)
    try await launch.value
    source.native.active = false
    await #expect(throws: VMError.self) { try await controller.perform(.forceStop) }
    #expect(source.isActive && source.native.calls == [.start])
    #expect(source.terminationObservation == .notObserved)
    source.driver.guestDidStop(from: ObjectIdentifier(source.native.identity))
    await #expect(throws: VMError.self) { try await controller.settleRuntime() }
    #expect(controller.state == .failed && history.snapshots.last?.outcome == .failed)
    #expect(
      !history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .forcedStopped })
  }

  @Test func activePauseFailureRetainsTerminalPendingAndRealGuestCallbackDrainsFailedHistory()
    async throws
  {
    let source = AppleSettlementFixtureSource()
    let session = UUID()
    try source.bindRecordedSession(sessionID: session)
    let history = AppleOrderingHistory()
    let controller = VMController(backend: source, history: history)
    var quiescent = false
    controller.onQuiescent = { quiescent = true }
    let launch = Task { try await controller.perform(.start) }
    await source.native.waitFor(.start)
    source.native.complete(.start, active: true)
    try await launch.value
    let pause = Task { try await controller.perform(.pause) }
    await source.native.waitFor(.pause)
    source.native.complete(
      .pause, result: .failure(AppleNativeFixtureError.operationFailed),
      active: true)
    await #expect(throws: AppleNativeFixtureError.self) { try await pause.value }
    await controller.finishPersistence()
    let firstFailure = controller.runtimeError
    #expect(firstFailure?.code == .backendFailure && !quiescent)
    source.native.active = false
    #expect(source.isActive && !source.driver.isOperationPending)
    #expect(throws: VMError.self) { try source.driver.freezeForSettlement(sessionID: session) }
    #expect(!quiescent)
    source.driver.guestDidStop(from: ObjectIdentifier(source.native.identity))
    await #expect(throws: VMError.self) { try await controller.settleRuntime() }
    #expect(quiescent && !source.isActive && controller.runtimeError == firstFailure)
    #expect(controller.state == .failed && history.snapshots.last?.outcome == .failed)
    #expect(source.native.calls == [.start, .pause])
    #expect(
      !history.snapshots.contains { $0.outcome == .guestStopped || $0.outcome == .forcedStopped })
    let frozen = try source.driver.freezeForSettlement(sessionID: session)
    #expect(frozen.terminationObservation == .runtimeExited)
  }
}

@MainActor private func appleFixtureFailure() -> VMError {
  VMError(.backendFailure, "Synthetic native event failure.", recovery: "Fixture only.")
}
