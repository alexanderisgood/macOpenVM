// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite(.serialized) struct SharedFrameFilteringTests {
  @Test @MainActor func onlyAlignedWholePixelScalingUsesNearest() {
    let source = CGSize(width: 64, height: 64)
    for (rect, expected) in [
      (CGRect(x: 0, y: 0, width: 64, height: 64), true),
      (CGRect(x: 4, y: 8, width: 128, height: 128), true),
      (CGRect(x: 0.5, y: 0, width: 64, height: 64), false),
      (CGRect(x: 0, y: 0, width: 32, height: 32), false),
      (CGRect(x: 0, y: 0, width: 96, height: 96), false),
      (CGRect(x: 0, y: 0, width: 128, height: 64), false),
    ] {
      #expect(
        SharedFrameMetalRenderer.hasAlignedWholePixels(source: source, viewport: rect) == expected)
    }
    #expect(!SharedFrameMetalRenderer.hasAlignedWholePixels(source: .zero, viewport: .zero))
  }

  /// Actual production pipelines render a public generated checkerboard.
  /// A half-size image must average it instead of aliasing to black or white.
  @Test(arguments: [32, 64, 96, 128]) @MainActor
  func nativeIntegerAndFractionalPixels(side: Int) async throws {
    let size = CGSize(width: side + 8, height: side + 8)
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    defer { renderer.close() }
    try await renderer.configureDrawableRetryValidation(
      acquire: { true }, drawableSize: { size }, checkerboard: true)
    renderer.redraw(
      drawableSize: size, viewport: CGRect(x: 4, y: 4, width: side, height: side))
    let deadline = ContinuousClock.now + .seconds(5)
    while await renderer.drawableRetryStateForValidation().draws == 0,
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(5)) }
    let bytes = try #require(await renderer.generatedDrawableBytesForValidation())
    var intermediate = 0
    for y in 0..<(side + 8) {
      for x in 0..<(side + 8) {
        let offset = (y * (side + 8) + x) * 4
        let value = bytes[offset]
        try #require(bytes[offset + 3] == 255)
        try #require(bytes[offset + 1] == value && bytes[offset + 2] == value)
        if x < 4 || y < 4 || x >= side + 4 || y >= side + 4 {
          try #require(value == 0)
        } else if side == 32 {
          try #require((127...128).contains(value))
        } else if side == 64 || side == 128 {
          let scale = side / 64
          let expected: UInt8 = ((x - 4) / scale + (y - 4) / scale).isMultiple(of: 2) ? 0 : 255
          try #require(value == expected)
        } else if value > 0 && value < 255 {
          intermediate += 1
        }
      }
    }
    if side == 96 { #expect(intermediate > side * side / 2) }
  }
}
