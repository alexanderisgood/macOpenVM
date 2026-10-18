// SPDX-License-Identifier: Apache-2.0
/// Pure acquisition budget used by the actual HDR renderer. Content/geometry
/// notifications cannot restart a run of failed nextDrawable acquisitions.
struct HDRDrawableRetryBudget: Sendable {
  enum Event: Sendable {
    case content, redraw
    case activation(Bool)
    case presented, failedAcquisition
  }
  enum Action: Equatable, Sendable {
    case none
    case retry(milliseconds: Int)
    case exhausted
  }
  private(set) var active = false
  private(set) var failedAcquisitions = 0
  mutating func apply(_ event: Event) -> Action {
    switch event {
    case .content, .redraw: return .none
    case .activation(let next):
      guard next != active else { return .none }
      active = next
      failedAcquisitions = 0
      return .none
    case .presented:
      guard active else { return .none }
      failedAcquisitions = 0
      return .none
    case .failedAcquisition:
      guard active else { return .none }
      guard failedAcquisitions < 6 else { return .exhausted }
      let delay = min(16 << failedAcquisitions, 500)
      failedAcquisitions += 1
      return .retry(milliseconds: delay)
    }
  }
}
