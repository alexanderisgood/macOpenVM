// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Relative motion adds; replacing a pending sample would lose camera movement.
/// Button edges and explicit barriers retain their original ordering.
@MainActor public final class GuestRelativePointerCoalescer {
  @MainActor public final class Batch {
    private var value: (dx: Int, dy: Int, buttons: UInt8)?
    private let replaceable: Bool
    fileprivate init(dx: Int, dy: Int, buttons: UInt8, replaceable: Bool) {
      value = (dx, dy, buttons)
      self.replaceable = replaceable
    }
    public func take() -> (dx: Int, dy: Int, buttons: UInt8)? {
      defer { value = nil }
      return value
    }
    fileprivate func add(dx: Int, dy: Int, buttons: UInt8) -> Bool {
      guard replaceable, let current = value, current.buttons == buttons,
        (-32767...32767).contains(current.dx + dx),
        (-32767...32767).contains(current.dy + dy)
      else { return false }
      value = (current.dx + dx, current.dy + dy, buttons)
      return true
    }
  }
  private var pending: Batch?
  private var buttons: UInt8 = 0
  public init() {}
  public func enqueue(dx: Int, dy: Int, buttons: UInt8) -> Batch? {
    let motion = self.buttons == buttons
    defer { self.buttons = buttons }
    if motion, pending?.add(dx: dx, dy: dy, buttons: buttons) == true { return nil }
    let batch = Batch(dx: dx, dy: dy, buttons: buttons, replaceable: motion)
    pending = batch
    return batch
  }
  public func barrier() { pending = nil }
  public func reset() {
    pending = nil
    buttons = 0
  }
}
