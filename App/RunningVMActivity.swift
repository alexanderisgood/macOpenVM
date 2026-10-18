// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A running VM continues producing frames when its window loses focus. Scope
/// the process activity to the actual runtime, rather than window visibility.
@MainActor final class RunningVMActivity {
  private var token: Token?

  func update(active: Bool) {
    if active, token == nil { token = Token() }
    if !active { token = nil }
  }

  /// Exclusive ownership makes teardown safe even when the containing runtime
  /// is released off actor. Foundation's activity API is thread safe.
  private final class Token: @unchecked Sendable {
    private let value: any NSObjectProtocol
    init() {
      value = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "Running an interactive virtual machine")
    }
    deinit { ProcessInfo.processInfo.endActivity(value) }
  }
}
