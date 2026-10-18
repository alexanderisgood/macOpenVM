// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

public struct GuestPointerSample: Equatable, Sendable {
  public let point: GuestPixelPoint
  public let buttons: UInt8
  public let pixels: PixelSize
  public let epoch: UUID

  public init(point: GuestPixelPoint, buttons: UInt8, pixels: PixelSize, epoch: UUID) {
    self.point = point
    self.buttons = buttons
    self.pixels = pixels
    self.epoch = epoch
  }
}

/// Adjacent unsent positions may share one queue slot. Button changes, display
/// generations and explicit keyboard/scroll/release barriers preserve ordering.
@MainActor public final class GuestPointerCoalescer {
  @MainActor public final class Batch {
    private var sample: GuestPointerSample?
    private let replaceable: Bool
    fileprivate init(_ sample: GuestPointerSample, replaceable: Bool) {
      self.sample = sample
      self.replaceable = replaceable
    }

    /// Seal before awaiting transmission; later motion needs a new queue slot.
    public func take() -> GuestPointerSample? {
      defer { sample = nil }
      return sample
    }

    fileprivate func replace(with next: GuestPointerSample) -> Bool {
      guard replaceable, let sample, sample.buttons == next.buttons, sample.pixels == next.pixels,
        sample.epoch == next.epoch
      else { return false }
      self.sample = next
      return true
    }
  }

  private var pending: Batch?
  private var last: GuestPointerSample?
  public init() {}

  /// Nil means an existing unsent slot already contains the newest position.
  public func enqueue(_ sample: GuestPointerSample) -> Batch? {
    let isMotion =
      last.map {
        $0.buttons == sample.buttons && $0.epoch == sample.epoch && $0.pixels == sample.pixels
      } ?? (sample.buttons == 0)
    defer { last = sample }
    if pending?.replace(with: sample) == true { return nil }
    // The coordinate of a down/up edge is immutable. Only later motion can
    // merge, otherwise a drag would start or finish at the wrong guest target.
    let batch = Batch(sample, replaceable: isMotion)
    pending = batch
    return batch
  }

  /// Freeze the previous slot before another input kind or a capture boundary.
  public func barrier() { pending = nil }

  public func reset() {
    pending = nil
    last = nil
  }
}
