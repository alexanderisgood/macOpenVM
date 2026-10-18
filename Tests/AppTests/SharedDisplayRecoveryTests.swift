// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite struct SharedDisplayRecoveryTests {
  @Test func backsOffAndBoundsConsecutiveFailuresAtAnyRuntimeAge() {
    var recovery = SharedDisplayRecovery()
    let now = ContinuousClock.now + .seconds(3600)
    #expect(recovery.canAttempt(at: now))
    let delays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(3)]
    for delay in delays {
      let retry = recovery.transientFailure(at: now)
      #expect(retry)
      #expect(!recovery.canAttempt(at: now))
      #expect(!recovery.canAttempt(at: now + delay - .nanoseconds(1)))
      #expect(recovery.canAttempt(at: now + delay))
    }
    let exhausted = recovery.transientFailure(at: now + .seconds(100))
    #expect(!exhausted)
  }

  @Test func quietDisplayRecoverySchedulesOneFullRequestAtEachExistingBackoffDeadline() throws {
    var recovery = SharedDisplayRecovery()
    let initial = recovery.nextFrameRequest()
    #expect(initial.incremental)
    var failureTime = ContinuousClock.now
    for delay in [Duration.milliseconds(250), .seconds(1), .seconds(3)] {
      let retry = recovery.transientFailure(at: failureTime)
      #expect(retry)
      let request = recovery.nextFrameRequest()
      let deadline = try #require(request.retryDeadline)
      #expect(!request.incremental && deadline == failureTime + delay)
      #expect(!recovery.canAttempt(at: deadline - .nanoseconds(1)))
      #expect(recovery.canAttempt(at: deadline))
      let ordinary = recovery.nextFrameRequest()
      #expect(ordinary.incremental)
      failureTime = deadline
    }
    let retry = recovery.transientFailure(at: failureTime)
    #expect(!retry)
    let exhausted = recovery.nextFrameRequest()
    #expect(exhausted.incremental && exhausted.retryDeadline == nil)
  }

  @Test func sustainedRecoveryRetiresAnyPendingRefreshAndRestartsTheOriginalBudget() throws {
    var recovery = SharedDisplayRecovery()
    let now = ContinuousClock.now
    let initialRetry = recovery.transientFailure(at: now)
    #expect(initialRetry)
    for _ in 0..<120 { recovery.completedFrame() }
    let recovered = recovery.nextFrameRequest()
    #expect(recovered.incremental && recovered.retryDeadline == nil)
    #expect(recovery.canAttempt(at: now))
    let nextRetry = recovery.transientFailure(at: now)
    #expect(nextRetry)
    let fresh = recovery.nextFrameRequest()
    #expect(fresh.retryDeadline == now + .milliseconds(250) && !fresh.incremental)
  }

  @Test func requiresSustainedCompletedFramesBeforeReplenishingBudget() {
    var recovery = SharedDisplayRecovery()
    let now = ContinuousClock.now
    for _ in 0..<3 {
      let retry = recovery.transientFailure(at: now)
      #expect(retry)
    }
    for _ in 0..<119 { recovery.completedFrame() }
    let exhausted = recovery.transientFailure(at: now)
    #expect(!exhausted)
    for _ in 0..<120 { recovery.completedFrame() }
    #expect(recovery.canAttempt(at: now))
    let retry = recovery.transientFailure(at: now)
    #expect(retry)
    #expect(!recovery.canAttempt(at: now))
  }
}
