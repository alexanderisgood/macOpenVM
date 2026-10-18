// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CoreGraphics
import Foundation
import Testing
import VMCore

private struct ViewportFitCase: Sendable {
  let bounds: CGRect
  let pixels: PixelSize
  let expected: CGRect
}

@Suite struct GuestViewportTests {
  @Test(arguments: [
    ViewportFitCase(
      bounds: CGRect(x: 0, y: 0, width: 1000, height: 600),
      pixels: PixelSize(width: 800, height: 600),
      expected: CGRect(x: 100, y: 0, width: 800, height: 600)),
    ViewportFitCase(
      bounds: CGRect(x: 0, y: 0, width: 320, height: 900),
      pixels: PixelSize(width: 640, height: 480),
      expected: CGRect(x: 0, y: 330, width: 320, height: 240)),
    ViewportFitCase(
      bounds: CGRect(x: -20, y: 10, width: 300, height: 400),
      pixels: PixelSize(width: 640, height: 480),
      expected: CGRect(x: -20, y: 97.5, width: 300, height: 225)),
    ViewportFitCase(
      bounds: CGRect(x: 10.25, y: 20.75, width: 333.5, height: 500.5),
      pixels: PixelSize(width: 800, height: 600),
      expected: CGRect(x: 10.25, y: 145.9375, width: 333.5, height: 250.125)),
  ])
  private func aspectFitPreservesCenterAndGuestRatio(fixture: ViewportFitCase) throws {
    let viewport = try GuestViewport(viewBounds: fixture.bounds, guestPixels: fixture.pixels)
    let fit = viewport.fittedRect
    #expect(abs(fit.minX - fixture.expected.minX) < 0.000_000_001)
    #expect(abs(fit.minY - fixture.expected.minY) < 0.000_000_001)
    #expect(abs(fit.width - fixture.expected.width) < 0.000_000_001)
    #expect(abs(fit.height - fixture.expected.height) < 0.000_000_001)
    #expect(abs(fit.midX - fixture.bounds.midX) < 0.000_000_001)
    #expect(abs(fit.midY - fixture.bounds.midY) < 0.000_000_001)
    #expect(
      abs(fit.width / fit.height - CGFloat(fixture.pixels.width) / CGFloat(fixture.pixels.height))
        < 0.000_000_001)
  }

  @Test(arguments: [PixelSize(width: 640, height: 480), PixelSize(width: 800, height: 600)])
  func cornersAndMaximumExclusiveEdges(pixels: PixelSize) throws {
    let viewport = try GuestViewport(
      viewBounds: CGRect(x: 17, y: -31, width: 1000, height: 700), guestPixels: pixels)
    let fit = viewport.fittedRect
    let lastX = UInt16(pixels.width - 1)
    let lastY = UInt16(pixels.height - 1)
    #expect(viewport.map(viewPoint: fit.origin) == GuestPixelPoint(x: 0, y: 0))
    #expect(
      viewport.map(viewPoint: CGPoint(x: fit.maxX.nextDown, y: fit.minY))
        == GuestPixelPoint(x: lastX, y: 0))
    #expect(
      viewport.map(viewPoint: CGPoint(x: fit.minX, y: fit.maxY.nextDown))
        == GuestPixelPoint(x: 0, y: lastY))
    #expect(
      viewport.map(viewPoint: CGPoint(x: fit.maxX.nextDown, y: fit.maxY.nextDown))
        == GuestPixelPoint(x: lastX, y: lastY))
    #expect(viewport.map(viewPoint: CGPoint(x: fit.maxX, y: fit.midY)) == nil)
    #expect(viewport.map(viewPoint: CGPoint(x: fit.midX, y: fit.maxY)) == nil)
    #expect(viewport.map(viewPoint: CGPoint(x: fit.minX.nextDown, y: fit.midY)) == nil)
    #expect(viewport.map(viewPoint: CGPoint(x: fit.midX, y: fit.minY.nextDown)) == nil)
  }

  @Test func letterboxAndOutsideViewPointsAreNotClampedIntoTheGuest() throws {
    let wide = try GuestViewport(
      viewBounds: CGRect(x: 5, y: 9, width: 1000, height: 600),
      guestPixels: PixelSize(width: 800, height: 600))
    #expect(wide.map(viewPoint: CGPoint(x: 5, y: 309)) == nil)
    #expect(wide.map(viewPoint: CGPoint(x: 1004, y: 309)) == nil)
    #expect(wide.map(viewPoint: CGPoint(x: 4, y: 309)) == nil)
    #expect(wide.map(viewPoint: CGPoint(x: 505, y: 8)) == nil)
    let tall = try GuestViewport(
      viewBounds: CGRect(x: -10, y: -20, width: 320, height: 900),
      guestPixels: PixelSize(width: 640, height: 480))
    #expect(tall.map(viewPoint: CGPoint(x: 150, y: -20)) == nil)
    #expect(tall.map(viewPoint: CGPoint(x: 150, y: 879)) == nil)
    #expect(tall.map(viewPoint: CGPoint(x: 150, y: 880)) == nil)
  }

  @Test func logicalPointsMapToGuestPixelsWithoutHostBackingScale() throws {
    let viewport = try GuestViewport(
      viewBounds: CGRect(x: 0, y: 0, width: 320, height: 240),
      guestPixels: PixelSize(width: 640, height: 480))
    #expect(viewport.map(viewPoint: CGPoint(x: 160, y: 120)) == GuestPixelPoint(x: 320, y: 240))
    #expect(viewport.map(viewPoint: CGPoint(x: 0.5, y: 0.5)) == GuestPixelPoint(x: 1, y: 1))
  }

  @Test func integerScalingUsesActualBackingPixelsForPresentationAndInput() throws {
    let viewport = try GuestViewport(
      viewBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
      guestPixels: PixelSize(width: 640, height: 480),
      backingBounds: CGRect(x: 0, y: 0, width: 800, height: 600), scaling: .integer)
    #expect(viewport.fittedBackingRect == CGRect(x: 80, y: 60, width: 640, height: 480))
    #expect(viewport.fittedRect == CGRect(x: 40, y: 30, width: 320, height: 240))
    #expect(viewport.map(viewPoint: CGPoint(x: 40, y: 30)) == GuestPixelPoint(x: 0, y: 0))
    #expect(viewport.map(viewPoint: CGPoint(x: 200, y: 150)) == GuestPixelPoint(x: 320, y: 240))
    #expect(viewport.map(viewPoint: CGPoint(x: 39.9, y: 150)) == nil)
    #expect(viewport.map(viewPoint: CGPoint(x: 360, y: 150)) == nil)
    #expect(viewport.map(viewPoint: CGPoint(x: 200, y: 270)) == nil)
  }

  @Test func integerScalingCentersOddLetterboxingOnBackingPixelsWithFractionalOrigins() throws {
    let bounds = CGRect(x: -20.25, y: 31.75, width: 800.8, height: 640.8)
    let backing = CGRect(x: 17.5, y: -33.25, width: 1001, height: 801)
    let pixels = PixelSize(width: 320, height: 240)
    let viewport = try GuestViewport(
      viewBounds: bounds, guestPixels: pixels, backingBounds: backing, scaling: .integer)
    let physical = try #require(viewport.fittedBackingRect)
    #expect(physical == CGRect(x: 37.5, y: 6.75, width: 960, height: 720))
    #expect(abs(physical.midX - backing.midX) <= 0.5)
    #expect(abs(physical.midY - backing.midY) <= 0.5)
    #expect(physical.minX >= backing.minX && physical.maxX <= backing.maxX)
    #expect(physical.minY >= backing.minY && physical.maxY <= backing.maxY)
    let fit = viewport.fittedRect
    #expect(abs((fit.minX - bounds.minX) / bounds.width * backing.width - 20) < 1e-9)
    #expect(abs((fit.minY - bounds.minY) / bounds.height * backing.height - 40) < 1e-9)
    #expect(abs(fit.width / bounds.width * backing.width - 960) < 1e-9)
    #expect(abs(fit.height / bounds.height * backing.height - 720) < 1e-9)
    for x in [0, 1, 159, 318, 319] {
      for y in [0, 1, 119, 238, 239] {
        let center = CGPoint(
          x: fit.minX + (CGFloat(x) + 0.5) * fit.width / CGFloat(pixels.width),
          y: fit.minY + (CGFloat(y) + 0.5) * fit.height / CGFloat(pixels.height))
        #expect(viewport.map(viewPoint: center) == GuestPixelPoint(x: UInt16(x), y: UInt16(y)))
      }
    }
  }

  @Test func movingBetweenBackingScalesRecomputesTheIntegerMultiple() throws {
    let bounds = CGRect(x: 11.25, y: -5.5, width: 800, height: 600)
    for (scale, expectedWidth) in [(1.0, 640.0), (1.25, 640.0), (2.0, 1280.0), (3.0, 1920.0)] {
      let backing = CGRect(x: 7, y: 13, width: 800 * scale, height: 600 * scale)
      let viewport = try GuestViewport(
        viewBounds: bounds, guestPixels: PixelSize(width: 640, height: 480),
        backingBounds: backing, scaling: .integer)
      let fit = try #require(viewport.fittedBackingRect)
      #expect(fit.width == expectedWidth && fit.height == expectedWidth * 0.75)
      #expect((fit.minX - backing.minX).rounded(.down) == fit.minX - backing.minX)
      #expect((fit.minY - backing.minY).rounded(.down) == fit.minY - backing.minY)
      #expect(
        viewport.map(viewPoint: CGPoint(x: viewport.fittedRect.midX, y: viewport.fittedRect.midY))
          == GuestPixelPoint(x: 320, y: 240))
    }
  }

  @Test func fractionalBackingExtentStillCentersWithinHalfAPixel() throws {
    let backing = CGRect(x: 17.5, y: -33.25, width: 1001.5, height: 801.5)
    let viewport = try GuestViewport(
      viewBounds: CGRect(x: -20.25, y: 31.75, width: 800.8, height: 640.8),
      guestPixels: PixelSize(width: 320, height: 240), backingBounds: backing, scaling: .integer)
    let fit = try #require(viewport.fittedBackingRect)
    #expect(fit == CGRect(x: 38.5, y: 7.75, width: 960, height: 720))
    #expect(abs(fit.midX - backing.midX) <= 0.5)
    #expect(abs(fit.midY - backing.midY) <= 0.5)
    #expect(fit.minX >= backing.minX && fit.maxX <= backing.maxX)
    #expect(fit.minY >= backing.minY && fit.maxY <= backing.maxY)
  }

  @Test func integerScalingBelowOneFallsBackToUnclippedAspectFit() throws {
    let bounds = CGRect(x: -12.375, y: 43.625, width: 300, height: 200)
    let backing = CGRect(x: 13, y: -7, width: 600, height: 400)
    let pixels = PixelSize(width: 1920, height: 1080)
    let original = try GuestViewport(viewBounds: bounds, guestPixels: pixels)
    for scaling in GuestDisplayScaling.allCases {
      let viewport = try GuestViewport(
        viewBounds: bounds, guestPixels: pixels, backingBounds: backing, scaling: scaling)
      #expect(viewport.fittedRect == original.fittedRect)
      #expect(viewport.fittedBackingRect == CGRect(x: 13, y: 24.25, width: 600, height: 337.5))
      #expect(viewport.map(viewPoint: viewport.fittedRect.origin) == GuestPixelPoint(x: 0, y: 0))
      #expect(
        viewport.map(
          viewPoint: CGPoint(
            x: viewport.fittedRect.maxX.nextDown, y: viewport.fittedRect.maxY.nextDown)
        ) == GuestPixelPoint(x: 1919, y: 1079))
    }
  }

  @Test func backingAwareFitPreservesTheExistingLogicalGeometry() throws {
    let bounds = CGRect(x: -12.375, y: 43.625, width: 731.25, height: 1001.875)
    let pixels = PixelSize(width: 640, height: 480)
    let original = try GuestViewport(viewBounds: bounds, guestPixels: pixels)
    #expect(original.fittedBackingRect == nil)
    for scale in [1.0, 1.25, 2.0, 3.0] {
      let backing = CGRect(
        x: -8.5, y: 19.25, width: bounds.width * scale, height: bounds.height * scale)
      let viewport = try GuestViewport(
        viewBounds: bounds, guestPixels: pixels, backingBounds: backing, scaling: .fit)
      #expect(viewport.fittedRect == original.fittedRect)
      let fit = try #require(viewport.fittedBackingRect)
      #expect(abs(fit.width - original.fittedRect.width * scale) < 1e-9)
      #expect(abs(fit.height - original.fittedRect.height * scale) < 1e-9)
    }
  }

  @Test func invalidBackingGeometryIsRejectedBeforeIntegerArithmetic() {
    for backing in [
      CGRect.zero, CGRect.null, CGRect.infinite,
      CGRect(x: 0, y: 0, width: -1, height: 1),
      CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1),
      CGRect(x: 1e308, y: 0, width: 1, height: 1),
    ] {
      for scaling in GuestDisplayScaling.allCases {
        #expect(throws: VMError.self) {
          try GuestViewport(
            viewBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            guestPixels: PixelSize(width: 640, height: 480),
            backingBounds: backing, scaling: scaling)
        }
      }
    }
  }

  @Test func fractionalOffsetPixelCentersRoundTrip() throws {
    let viewport = try GuestViewport(
      viewBounds: CGRect(x: -12.375, y: 43.625, width: 731.25, height: 1001.875),
      guestPixels: PixelSize(width: 640, height: 480))
    let fit = viewport.fittedRect
    for x in [0, 1, 319, 638, 639] {
      for y in [0, 1, 239, 478, 479] {
        let point = CGPoint(
          x: fit.minX + (CGFloat(x) + 0.5) * fit.width / 640,
          y: fit.minY + (CGFloat(y) + 0.5) * fit.height / 480)
        #expect(
          viewport.map(viewPoint: point) == GuestPixelPoint(x: UInt16(x), y: UInt16(y)))
      }
    }
  }

  @Test(arguments: [
    PixelSize(width: 0, height: 480), PixelSize(width: 640, height: 0),
    PixelSize(width: -1, height: 480), PixelSize(width: 640, height: -1),
    PixelSize(width: 8193, height: 1), PixelSize(width: 1, height: 8193),
    PixelSize(width: 8192, height: 2049), PixelSize(width: 5000, height: 5000),
    PixelSize(width: Int.max, height: Int.max), PixelSize(width: Int.min, height: 1),
  ])
  func invalidGuestSizesAreRejectedBeforeArithmetic(pixels: PixelSize) {
    #expect(throws: VMError.self) {
      try GuestViewport(
        viewBounds: CGRect(x: 0, y: 0, width: 800, height: 600), guestPixels: pixels)
    }
  }

  @Test func maximumPixelAreaAndHugeFiniteBoundsRemainRepresentable() throws {
    let viewport = try GuestViewport(
      viewBounds: CGRect(x: 0, y: 0, width: 8192, height: 2048),
      guestPixels: PixelSize(width: 8192, height: 2048))
    #expect(
      viewport.map(viewPoint: CGPoint(x: CGFloat(8192).nextDown, y: CGFloat(2048).nextDown))
        == GuestPixelPoint(x: 8191, y: 2047))
    // This is a huge finite non-sentinel precision boundary, not a host viewport claim.
    let maximum = CGFloat.greatestFiniteMagnitude
    let huge = try GuestViewport(
      viewBounds: CGRect(x: -maximum / 4, y: -maximum / 4, width: maximum / 2, height: maximum / 2),
      guestPixels: PixelSize(width: 640, height: 480))
    let center = try #require(huge.map(viewPoint: .zero))
    #expect(center.x < 640 && center.y < 480)
    #expect(huge.map(viewPoint: huge.fittedRect.origin) == GuestPixelPoint(x: 0, y: 0))
    #expect(huge.map(viewPoint: CGPoint(x: huge.fittedRect.maxX, y: 0)) == nil)
    #expect(huge.map(viewPoint: CGPoint(x: 0, y: huge.fittedRect.maxY)) == nil)
    #expect(huge.map(viewPoint: CGPoint(x: huge.fittedRect.minX.nextDown, y: 0)) == nil)
  }

  @Test(arguments: [
    CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 1),
    CGRect(x: 0, y: 0, width: 1, height: -1), CGRect.null, CGRect.infinite,
    CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
    CGRect(x: 0, y: CGFloat.nan, width: 1, height: 1),
    CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1),
    CGRect(x: 0, y: 0, width: 1, height: CGFloat.infinity),
    CGRect(
      x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1),
    CGRect(x: 1e308, y: 1e308, width: 1, height: 1),
    CGRect(x: 0, y: 0, width: CGFloat.leastNonzeroMagnitude, height: 1),
  ])
  func invalidOrUnrepresentableViewBoundsAreRejected(bounds: CGRect) {
    #expect(throws: VMError.self) {
      try GuestViewport(viewBounds: bounds, guestPixels: PixelSize(width: 640, height: 480))
    }
  }

  @Test(arguments: [
    CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.nan),
    CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 0, y: -CGFloat.infinity),
  ])
  func nonfinitePointsAreRejected(point: CGPoint) throws {
    let viewport = try GuestViewport(
      viewBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
      guestPixels: PixelSize(width: 800, height: 600))
    #expect(viewport.map(viewPoint: point) == nil)
  }
}
