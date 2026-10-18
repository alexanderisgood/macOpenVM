// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Testing

@testable import MacOpenVMApp

@Suite struct GuestBackingGeometryTests {
  @Test func dimensionsComeFromActualBackingRectangle() {
    for scale in [1.0, 1.25, 2.0, 3.0] {
      let backing = CGRect(x: 0, y: 0, width: 900 * scale, height: 600 * scale)
      #expect(
        GuestBackingGeometry.pixels(forBackingBounds: backing)
          == PixelSize(width: Int(900 * scale), height: Int(600 * scale)))
    }
    #expect(
      GuestBackingGeometry.pixels(
        forBackingBounds: CGRect(x: 0, y: 0, width: 900.5, height: 600.25))
        == PixelSize(width: 901, height: 601))
  }

  @Test func invalidAndOversizedRectanglesAreRefused() {
    for bounds in [
      CGRect.zero, CGRect.null, CGRect.infinite,
      CGRect(x: 0, y: 0, width: 8193, height: 600),
      CGRect(x: 0, y: 0, width: 8192, height: 8192),
      CGRect(x: 0, y: 0, width: CGFloat.nan, height: 600),
    ] {
      #expect(GuestBackingGeometry.pixels(forBackingBounds: bounds) == nil)
    }
  }
}
