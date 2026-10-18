// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CoreGraphics
import Foundation

/// A coordinate in the validated guest framebuffer, independent of host backing scale.
public struct GuestPixelPoint: Equatable, Sendable {
  public let x: UInt16
  public let y: UInt16
  public init(x: UInt16, y: UInt16) {
    self.x = x
    self.y = y
  }
}

/// Host presentation only; these choices never change the guest framebuffer.
public enum GuestDisplayScaling: String, CaseIterable, Hashable, Sendable {
  case fit, integer
}

/// Centers a guest framebuffer inside logical view bounds. Points use a top-left
/// origin, as in an AppKit view with isFlipped == true. Host presentation never
/// changes the guest framebuffer's pixel coordinates.
public struct GuestViewport: Sendable {
  public let fittedRect: CGRect
  /// Actual backing-pixel geometry when constructed with backing bounds. Metal
  /// can use this directly without a points-to-pixels round trip.
  public let fittedBackingRect: CGRect?
  private let viewBounds: CGRect
  private let guestWidth: Int
  private let guestHeight: Int

  public init(viewBounds: CGRect, guestPixels: PixelSize) throws {
    let width = viewBounds.size.width
    let height = viewBounds.size.height
    guard Self.validBounds(viewBounds),
      (1...8192).contains(guestPixels.width), (1...8192).contains(guestPixels.height),
      guestPixels.width * guestPixels.height <= 16_777_216
    else { throw Self.invalidGeometry() }

    let scale = min(width / CGFloat(guestPixels.width), height / CGFloat(guestPixels.height))
    let scaledWidth = CGFloat(guestPixels.width) * scale
    let scaledHeight = CGFloat(guestPixels.height) * scale
    guard scale.isFinite, scale > 0,
      scaledWidth.isFinite, scaledHeight.isFinite, scaledWidth > 0, scaledHeight > 0
    else { throw Self.invalidGeometry() }
    // Division/multiplication may round one edge outward by an ulp. Keep the
    // drawing rectangle inside the original bounds before centering it.
    let fittedWidth = min(width, scaledWidth)
    let fittedHeight = min(height, scaledHeight)
    let rect = CGRect(
      x: viewBounds.origin.x + (width - fittedWidth) / 2,
      y: viewBounds.origin.y + (height - fittedHeight) / 2,
      width: fittedWidth, height: fittedHeight)
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
      rect.maxX.isFinite, rect.maxY.isFinite,
      rect.maxX > rect.minX, rect.maxY > rect.minY,
      rect.minX >= viewBounds.minX, rect.minY >= viewBounds.minY,
      rect.maxX <= viewBounds.maxX, rect.maxY <= viewBounds.maxY
    else { throw Self.invalidGeometry() }
    self.viewBounds = viewBounds
    fittedRect = rect
    fittedBackingRect = nil
    guestWidth = guestPixels.width
    guestHeight = guestPixels.height
  }

  /// Integer scaling uses the native view's actual backing rectangle, rather
  /// than a guessed monitor scale. Whole guest-pixel multiples are centered on
  /// backing pixels, with at most one pixel of asymmetry in the letterboxing.
  /// If one guest pixel cannot fit, ordinary aspect fit keeps the whole guest
  /// visible instead of clipping it or producing a zero-sized viewport.
  public init(
    viewBounds: CGRect, guestPixels: PixelSize, backingBounds: CGRect,
    scaling: GuestDisplayScaling
  ) throws {
    let fit = try Self(viewBounds: viewBounds, guestPixels: guestPixels)
    guard Self.validBounds(backingBounds) else { throw Self.invalidGeometry() }

    let scale = min(
      backingBounds.width / CGFloat(guestPixels.width),
      backingBounds.height / CGFloat(guestPixels.height))
    let logical: CGRect
    let backing: CGRect
    if scaling == .integer, scale >= 1 {
      let wholeScale = scale.rounded(.down)
      let pixelWidth = CGFloat(guestPixels.width) * wholeScale
      let pixelHeight = CGFloat(guestPixels.height) * wholeScale
      guard pixelWidth.isFinite, pixelHeight.isFinite,
        pixelWidth > 0, pixelHeight > 0,
        pixelWidth <= backingBounds.width, pixelHeight <= backingBounds.height
      else { throw Self.invalidGeometry() }
      backing = CGRect(
        x: backingBounds.minX + ((backingBounds.width - pixelWidth) / 2).rounded(.toNearestOrEven),
        y: backingBounds.minY
          + ((backingBounds.height - pixelHeight) / 2).rounded(.toNearestOrEven),
        width: pixelWidth, height: pixelHeight)
      guard Self.validRect(backing, inside: backingBounds) else { throw Self.invalidGeometry() }
      logical = try Self.mapRect(backing, from: backingBounds, to: viewBounds)
    } else {
      logical = fit.fittedRect
      backing = try Self.mapRect(logical, from: viewBounds, to: backingBounds)
    }
    self.viewBounds = viewBounds
    fittedRect = logical
    fittedBackingRect = backing
    guestWidth = guestPixels.width
    guestHeight = guestPixels.height
  }

  /// Minimum edges are included; maximum edges and letterbox space are excluded.
  /// Rounding at an inside edge cannot produce a pixel outside the framebuffer.
  public func map(viewPoint: CGPoint) -> GuestPixelPoint? {
    guard viewPoint.x.isFinite, viewPoint.y.isFinite,
      Self.contains(viewPoint, in: viewBounds), Self.contains(viewPoint, in: fittedRect)
    else { return nil }
    let x = (viewPoint.x - fittedRect.minX) / fittedRect.width * CGFloat(guestWidth)
    let y = (viewPoint.y - fittedRect.minY) / fittedRect.height * CGFloat(guestHeight)
    guard x.isFinite, y.isFinite, x >= 0, y >= 0 else { return nil }
    // Clamp before converting to an integer. Rounding near the exclusive edge
    // must not discard a valid point or produce a pixel outside the framebuffer.
    return GuestPixelPoint(
      x: UInt16(min(CGFloat(guestWidth - 1), x.rounded(.down))),
      y: UInt16(min(CGFloat(guestHeight - 1), y.rounded(.down))))
  }

  private static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
    point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
  }

  private static func validBounds(_ bounds: CGRect) -> Bool {
    !bounds.isInfinite && !bounds.isNull
      && bounds.origin.x.isFinite && bounds.origin.y.isFinite
      && bounds.size.width.isFinite && bounds.size.height.isFinite
      && bounds.size.width > 0 && bounds.size.height > 0
      && bounds.maxX.isFinite && bounds.maxY.isFinite
      && bounds.maxX > bounds.minX && bounds.maxY > bounds.minY
  }

  private static func validRect(_ rect: CGRect, inside bounds: CGRect) -> Bool {
    validBounds(rect)
      && rect.minX >= bounds.minX && rect.minY >= bounds.minY
      && rect.maxX <= bounds.maxX && rect.maxY <= bounds.maxY
  }

  /// Normalize before multiplying so large finite coordinate spaces do not
  /// overflow merely because the two bounds use different units.
  private static func mapRect(_ rect: CGRect, from source: CGRect, to target: CGRect) throws
    -> CGRect
  {
    let x = target.minX + (rect.minX - source.minX) / source.width * target.width
    let y = target.minY + (rect.minY - source.minY) / source.height * target.height
    // Keep a rounding ulp at the far edge inside the available rectangle.
    let width = min(rect.width / source.width * target.width, target.maxX - x)
    let height = min(rect.height / source.height * target.height, target.maxY - y)
    let mapped = CGRect(x: x, y: y, width: width, height: height)
    guard validRect(mapped, inside: target) else { throw invalidGeometry() }
    return mapped
  }

  private static func invalidGeometry() -> VMError {
    VMError(
      .invalidConfiguration, "Guest display geometry is invalid or exceeds its bounds.",
      recovery: "Use finite positive view bounds and supported framebuffer dimensions.")
  }
}
