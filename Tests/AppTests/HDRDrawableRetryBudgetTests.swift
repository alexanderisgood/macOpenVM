// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import MacOpenVMApp

struct HDRDrawableRetryBudgetTests {
  @Test func newFramesRedrawAndNoopActivationCannotRenewFailedAcquisitions() {
    var budget = HDRDrawableRetryBudget()
    let activated = budget.apply(.activation(true))
    #expect(activated == .none)
    for delay in [16, 32, 64, 128, 256, 500] {
      for _ in 0..<100 {
        let content = budget.apply(.content)
        let redraw = budget.apply(.redraw)
        let noOpActivation = budget.apply(.activation(true))
        #expect(content == .none)
        #expect(redraw == .none)
        #expect(noOpActivation == .none)
      }
      let failure = budget.apply(.failedAcquisition)
      #expect(failure == .retry(milliseconds: delay))
    }
    let exhausted = budget.apply(.failedAcquisition)
    let noOpActivation = budget.apply(.activation(true))
    let stillExhausted = budget.apply(.failedAcquisition)
    let presented = budget.apply(.presented)
    let resetFailure = budget.apply(.failedAcquisition)
    let deactivated = budget.apply(.activation(false))
    let inactiveFailure = budget.apply(.failedAcquisition)
    let reactivated = budget.apply(.activation(true))
    let newFailure = budget.apply(.failedAcquisition)
    #expect(exhausted == .exhausted)
    #expect(noOpActivation == .none)
    #expect(stillExhausted == .exhausted)
    #expect(presented == .none)
    #expect(resetFailure == .retry(milliseconds: 16))
    #expect(deactivated == .none)
    #expect(inactiveFailure == .none)
    #expect(reactivated == .none)
    #expect(newFailure == .retry(milliseconds: 16))
  }
}
