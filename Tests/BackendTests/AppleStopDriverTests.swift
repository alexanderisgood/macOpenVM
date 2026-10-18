import BackendAPI
import Foundation
import Testing

// SPDX-License-Identifier: Apache-2.0
@testable import AppleVz

private enum SyntheticStopError: Error { case nativeStopFailed }

/// An event-order fixture for the production driver, not native VZ qualification.
@MainActor
private final class SyntheticAppleStop {
  var active = true
  var stoppable = true
  private(set) var stopCalls = 0
  private var completion: CheckedContinuation<Void, any Error>?
  private var entered: CheckedContinuation<Void, Never>?

  func makeDriver() -> AppleStopDriver {
    AppleStopDriver(
      isActive: { self.active }, canStop: { self.stoppable }, stop: { try await self.stop() })
  }

  private func stop() async throws {
    stopCalls += 1
    try await withCheckedThrowingContinuation { continuation in
      completion = continuation
      entered?.resume()
      entered = nil
    }
  }

  func waitForStop() async {
    if completion == nil { await withCheckedContinuation { entered = $0 } }
  }

  func finish(_ result: Result<Void, any Error>, active: Bool) {
    self.active = active
    let pending = completion
    completion = nil
    pending?.resume(with: result)
  }
}

@Suite(.serialized)
@MainActor
struct AppleStopDriverTests {
  @Test func cancelledLegacyStopKeepsNativeCompletionPendingUntilItActuallyReturns() async throws {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    let operation = Task { try await driver.forceStop() }
    await native.waitForStop()
    operation.cancel()
    native.active = false
    driver.guestDidStop()
    await Task.yield()
    #expect(driver.isActive && driver.isOperationPending)
    #expect(throws: VMError.self) { try driver.resetForStart() }
    #expect(native.stopCalls == 1)
    native.finish(.success(()), active: false)
    do { try await operation.value } catch { #expect(error is CancellationError) }
    #expect(!driver.isActive && !driver.isOperationPending)
    #expect(driver.terminationObservation == .explicitForcedTermination)
    try driver.resetForStart()
    #expect(driver.terminationObservation == .notObserved)
  }

  @Test(arguments: [BackendTerminationObservation.notObserved, .guestStopObserved, .runtimeExited])
  func alreadyInactivePreservesActualObservationWithoutStop(
    observation: BackendTerminationObservation
  ) async throws {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    native.active = false
    switch observation {
    case .guestStopObserved: driver.guestDidStop()
    case .runtimeExited: driver.didStopWithError()
    case .notObserved: break
    case .explicitForcedTermination: Issue.record("Unexpected fixture observation")
    }
    try await driver.forceStop()
    #expect(native.stopCalls == 0 && driver.terminationObservation == observation)
  }

  @Test func nativeCanStopAndPendingOperationAreCheckedBeforeInvocation() async throws {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    native.stoppable = false
    do {
      try await driver.forceStop()
      Issue.record("An active but non-stoppable native state must reject stop")
    } catch let error as VMError { #expect(error.code == .invalidTransition) }
    #expect(native.stopCalls == 0 && driver.terminationObservation == .notObserved)

    native.stoppable = true
    let operation = Task { try await driver.forceStop() }
    await native.waitForStop()
    defer { native.finish(.failure(SyntheticStopError.nativeStopFailed), active: false) }
    do {
      try await driver.forceStop()
      Issue.record("A second stop must not overlap the pending native operation")
    } catch let error as VMError { #expect(error.code == .busy) }
    #expect(throws: VMError.self) { try driver.resetForStart() }
    #expect(native.stopCalls == 1 && driver.terminationObservation == .notObserved)
    native.finish(.success(()), active: false)
    try await operation.value
    #expect(driver.terminationObservation == .explicitForcedTermination)
    try await driver.forceStop()
    #expect(native.stopCalls == 1 && driver.terminationObservation == .explicitForcedTermination)
    try driver.resetForStart()
    #expect(driver.terminationObservation == .notObserved)
  }

  @Test(arguments: [false, true])
  func delegateBeforeNativeFailureNeverBecomesForced(errorDelegate: Bool) async throws {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    let operation = Task { try await driver.forceStop() }
    await native.waitForStop()
    defer { native.finish(.failure(SyntheticStopError.nativeStopFailed), active: false) }
    native.active = false
    if errorDelegate { driver.didStopWithError() } else { driver.guestDidStop() }
    let actual: BackendTerminationObservation = errorDelegate ? .runtimeExited : .guestStopObserved
    #expect(driver.terminationObservation == actual)
    native.finish(.failure(SyntheticStopError.nativeStopFailed), active: false)
    do {
      try await operation.value
      Issue.record("Expected the synthetic native stop failure")
    } catch { #expect(error is SyntheticStopError) }
    #expect(native.stopCalls == 1 && driver.terminationObservation == actual)
    try await driver.forceStop()
    #expect(native.stopCalls == 1 && driver.terminationObservation == actual)
    try driver.resetForStart()  // Failure cleared pending state before this new attempt.
    #expect(driver.terminationObservation == .notObserved)
  }

  @Test(arguments: [false, true])
  func successfulNativeCompletionConfirmsForceAndPreservesError(errorBeforeGuest: Bool) async throws
  {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    let operation = Task { try await driver.forceStop() }
    await native.waitForStop()
    defer { native.finish(.failure(SyntheticStopError.nativeStopFailed), active: false) }
    native.active = false
    if errorBeforeGuest { driver.didStopWithError() }
    driver.guestDidStop()
    #expect(
      driver.terminationObservation == (errorBeforeGuest ? .runtimeExited : .guestStopObserved))
    native.finish(.success(()), active: false)
    try await operation.value
    #expect(
      driver.terminationObservation
        == (errorBeforeGuest ? .runtimeExited : .explicitForcedTermination))
    #expect(native.stopCalls == 1)
    try driver.resetForStart()
    #expect(driver.terminationObservation == .notObserved)
  }

  @Test func queuedGuestCallbackCannotDowngradeConfirmedForceOrNativeError() async throws {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    let operation = Task { try await driver.forceStop() }
    await native.waitForStop()
    defer { native.finish(.failure(SyntheticStopError.nativeStopFailed), active: false) }
    native.finish(.success(()), active: false)
    try await operation.value
    #expect(driver.terminationObservation == .explicitForcedTermination)
    driver.guestDidStop()
    #expect(driver.terminationObservation == .explicitForcedTermination)
    driver.didStopWithError()
    #expect(driver.terminationObservation == .runtimeExited)
    driver.guestDidStop()
    #expect(driver.terminationObservation == .runtimeExited && native.stopCalls == 1)
    try driver.resetForStart()
    driver.guestDidStop()
    #expect(driver.terminationObservation == .guestStopObserved)
  }

  @Test func failedStopWhileActiveDoesNotTaintLaterGuestStop() async throws {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    let operation = Task { try await driver.forceStop() }
    await native.waitForStop()
    defer { native.finish(.failure(SyntheticStopError.nativeStopFailed), active: false) }
    native.finish(.failure(SyntheticStopError.nativeStopFailed), active: true)
    do {
      try await operation.value
      Issue.record("Expected the synthetic native stop failure")
    } catch { #expect(error is SyntheticStopError) }
    #expect(native.active && driver.terminationObservation == .notObserved)
    native.active = false
    driver.guestDidStop()
    #expect(driver.terminationObservation == .guestStopObserved)
    try driver.resetForStart()
  }

  @Test func successfulCompletionWhileStillActiveCannotFabricateTermination() async throws {
    let native = SyntheticAppleStop()
    let driver = native.makeDriver()
    let operation = Task { try await driver.forceStop() }
    await native.waitForStop()
    defer { native.finish(.failure(SyntheticStopError.nativeStopFailed), active: false) }
    native.finish(.success(()), active: true)
    do {
      try await operation.value
      Issue.record("An active native machine cannot confirm termination")
    } catch let error as VMError { #expect(error.code == .backendFailure) }
    #expect(native.stopCalls == 1 && driver.terminationObservation == .notObserved)
    try driver.resetForStart()
  }
}
