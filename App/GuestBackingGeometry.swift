// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI

/// Use the guest view's actual backing rectangle, excluding native window chrome.
/// Desired dimensions do not assert that the guest has applied a display mode.
enum GuestBackingGeometry {
  static func pixels(forBackingBounds bounds: CGRect) -> PixelSize? {
    guard !bounds.isNull, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite,
      bounds.width > 0, bounds.height > 0,
      bounds.width <= 8192, bounds.height <= 8192
    else { return nil }
    let width = Int(bounds.width.rounded(.up))
    let height = Int(bounds.height.rounded(.up))
    guard width * height <= 16_777_216 else { return nil }
    return PixelSize(width: width, height: height)
  }
}
