// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Local presentation intent only. A console chord is not a guest acknowledgement;
/// no selection token can admit a route, worker, producer capture or VM operation.
struct GuestDisplayConsoleSelection {
  enum SharedAction: Equatable, Sendable {
    case disableForFirmware, retainActive, retryAdmittedRoute, rfbOnly

    var stopsShared: Bool { self != .retainActive }
  }
  struct Attempt: Equatable, Sendable {
    fileprivate let token: UUID
    let sharedAction: SharedAction
  }
  private var pending: Attempt?
  private var latest: Attempt?

  mutating func begin(
    _ console: WindowsDisplayConsole, sharedRouteAvailable: Bool, sharedActive: Bool
  ) -> Attempt? {
    guard pending == nil else { return nil }
    let action: SharedAction
    if console == .firmware {
      action = .disableForFirmware
    } else if !sharedRouteAvailable {
      action = .rfbOnly
    } else {
      action = sharedActive ? .retainActive : .retryAdmittedRoute
    }
    let attempt = Attempt(token: UUID(), sharedAction: action)
    latest = attempt
    pending = attempt
    return attempt
  }

  func ownsPending(_ attempt: Attempt) -> Bool { pending == attempt }

  mutating func finish(_ attempt: Attempt) -> Bool {
    guard pending == attempt else { return false }
    pending = nil
    return true
  }

  /// A deferred retry may run only after its input task completes, and never
  /// override a later selection or a closed/replaced display generation.
  func permitsDeferredReconnect(_ attempt: Attempt) -> Bool {
    latest == attempt && pending == nil && attempt.sharedAction == .retryAdmittedRoute
  }

  mutating func cancel() {
    pending = nil
    latest = nil
  }
}
