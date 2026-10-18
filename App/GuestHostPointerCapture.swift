// SPDX-License-Identifier: Apache-2.0
import AppKit

/// Mouse association belongs to the process, rather than the lifetime of a view.
/// Retain one exact owner until reassociation actually succeeds.
@MainActor final class GuestHostPointerCapture {
  // The coordinator owns this closure and invokes it only on MainActor. It
  // never transfers the injected platform boundary to another executor.
  typealias Association = (Bool) -> CGError
  typealias Schedule = @MainActor (Int, @escaping @MainActor @Sendable () -> Void) -> Void
  static let shared = GuestHostPointerCapture(restored: { NSCursor.arrow.set() })
  private static let retryDelays = [16, 50, 150, 500, 1000]

  @MainActor private final class Lease {
    let owner: UUID
    let associate: Association
    var restorationRequested = false
    var generation: UInt64 = 0
    var retries = 0
    var scheduled = false
    init(owner: UUID, associate: @escaping Association) {
      self.owner = owner
      self.associate = associate
    }
  }

  private var current: Lease?
  private let schedule: Schedule
  private let restored: @MainActor () -> Void

  init(
    schedule: @escaping Schedule = { delay, action in
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(delay))
        action()
      }
    }, restored: @escaping @MainActor () -> Void = {}
  ) {
    self.schedule = schedule
    self.restored = restored
  }

  var restorationPending: Bool { current?.restorationRequested == true }
  func isCaptured(by owner: UUID) -> Bool { current?.owner == owner }
  func canAcquire(for owner: UUID) -> Bool {
    current == nil || (current?.owner == owner && !restorationPending)
  }

  func acquire(for owner: UUID, associate: @escaping Association) -> Bool {
    guard canAcquire(for: owner) else { return false }
    if current != nil { return true }
    guard associate(false) == .success else { return false }
    current = Lease(owner: owner, associate: associate)
    return true
  }

  func restore(for owner: UUID, retryPending: Bool = true) {
    guard let lease = current, lease.owner == owner else { return }
    if lease.restorationRequested && !retryPending { return }
    lease.restorationRequested = true
    lease.generation &+= 1
    lease.scheduled = false
    lease.retries = 0
    attemptRestoration(lease)
  }

  /// Recovery after a view has detached must never release a valid newer owner.
  func retryPendingRestoration() {
    guard let lease = current, lease.restorationRequested else { return }
    restore(for: lease.owner)
  }

  private func attemptRestoration(_ lease: Lease) {
    guard current === lease, lease.restorationRequested else { return }
    if lease.associate(true) == .success {
      lease.generation &+= 1
      current = nil
      restored()
      return
    }
    guard !lease.scheduled, lease.retries < Self.retryDelays.count else { return }
    let delay = Self.retryDelays[lease.retries]
    lease.retries += 1
    lease.scheduled = true
    let generation = lease.generation
    schedule(delay) { [weak self, weak lease] in
      guard let self, let lease, self.current === lease,
        lease.generation == generation, lease.restorationRequested
      else { return }
      lease.scheduled = false
      self.attemptRestoration(lease)
    }
  }
}
