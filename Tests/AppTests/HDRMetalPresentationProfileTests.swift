// SPDX-License-Identifier: Apache-2.0
import CoreFoundation
import CoreGraphics
import Foundation
import Metal
import Qemu
import QuartzCore
import Testing

@testable import MacOpenVMApp

struct HDRMetalPresentationProfileTests {
  @Test func profileUsesFP16ThroughInputCacheAndOutputWithAbsolute80Units() throws {
    let message = try message()
    let profile = HDRMetalPresentationProfile(message: message)
    #expect(profile.sourcePixelFormat == .rgba16Float)
    #expect(profile.cachePixelFormat == .rgba16Float && profile.outputPixelFormat == .rgba16Float)
    #expect(profile.colorSpace == .extendedLinearSRGB && profile.shaderPolicy == .preserveLinearRGB)
    #expect(profile.opticalOutputScaleNits == 80)
    #expect(message.descriptor.colorEncoding.opticalScaleMillinits == 80_000)
    #expect(
      profile.isOpaque && profile.wantsExtendedDynamicRangeContent && !profile.permitsSDRSharpening)
    try profile.validateTextureFormats(
      source: .rgba16Float, cache: .rgba16Float, output: .rgba16Float)
    for unfit in [MTLPixelFormat.bgra8Unorm, .rgba16Unorm, .rgba32Float] {
      #expect(throws: HDRMetalPresentationProfile.Failure.self) {
        try profile.validateTextureFormats(source: unfit, cache: .rgba16Float, output: .rgba16Float)
      }
      #expect(throws: HDRMetalPresentationProfile.Failure.self) {
        try profile.validateTextureFormats(source: .rgba16Float, cache: unfit, output: .rgba16Float)
      }
      #expect(throws: HDRMetalPresentationProfile.Failure.self) {
        try profile.validateTextureFormats(source: .rgba16Float, cache: .rgba16Float, output: unfit)
      }
    }
  }

  @Test func importRequiresActualDeviceAlignmentCapacityAndExactMappingLength() throws {
    let message = try message()
    let profile = HDRMetalPresentationProfile(message: message)
    for alignment in [64, 128, 256] {
      try profile.validateImport(
        message: message, mappedByteCount: 4096, actualPixelFormat: .rgba16Float,
        minimumLinearTextureAlignment: alignment, maximumBufferLength: 4096)
    }
    for alignment in [Int.min, -1, 0, 3, 512] {
      #expect(throws: HDRMetalPresentationProfile.Failure.self) {
        try profile.validateImport(
          message: message, mappedByteCount: 4096, actualPixelFormat: .rgba16Float,
          minimumLinearTextureAlignment: alignment, maximumBufferLength: 4096)
      }
    }
    for count in [-1, 0, 4095, 4097, Int.max] {
      #expect(throws: HDRMetalPresentationProfile.Failure.self) {
        try profile.validateImport(
          message: message, mappedByteCount: count, actualPixelFormat: .rgba16Float,
          minimumLinearTextureAlignment: 256, maximumBufferLength: Int.max)
      }
    }
    #expect(throws: HDRMetalPresentationProfile.Failure.self) {
      try profile.validateImport(
        message: message, mappedByteCount: 4096, actualPixelFormat: .rgba16Float,
        minimumLinearTextureAlignment: 256, maximumBufferLength: 4095)
    }
    #expect(throws: HDRMetalPresentationProfile.Failure.self) {
      try profile.validateImport(
        message: message, mappedByteCount: 4096, actualPixelFormat: .bgra8Unorm,
        minimumLinearTextureAlignment: 256, maximumBufferLength: 4096)
    }
  }

  @Test func colorLayoutTargetAndStreamChangesInvalidateTheOldProfile() throws {
    let original = try message()
    let profile = HDRMetalPresentationProfile(message: original)
    let rotation = try message(resourceID: 11, incarnation: 21, selection: 41)
    #expect(profile.matches(rotation))
    for change in [
      try message(color: 31), try message(target: 1), try message(source: 1),
      try message(scanout: 1), try message(rowBytes: 512), try message(epochByte: 2),
    ] {
      #expect(!profile.matches(change))
      #expect(throws: HDRMetalPresentationProfile.Failure.self) {
        try profile.validateImport(
          message: change, mappedByteCount: change.descriptor.mappingBytes,
          actualPixelFormat: .rgba16Float,
          minimumLinearTextureAlignment: 256, maximumBufferLength: 4096)
      }
    }
  }

  @Test func unsupportedColorAndOpticalScaleCannotReachTheProfile() throws {
    for bad in [packet(pixelFormat: 1), packet(encoding: 5), packet(opticalScale: 100_000)] {
      #expect(throws: HDRFrameValidationError.self) {
        let invalid = try HDRFrameMessage(admitting: bad, limits: HDRFrameLimits(pageBytes: 4096))
        _ = HDRMetalPresentationProfile(message: invalid)
      }
    }
    let profile = HDRMetalPresentationProfile(message: try message())
    try profile.validateSystemToneMappingAvailability(true)
    #expect(throws: HDRMetalPresentationProfile.Failure.self) {
      try profile.validateSystemToneMappingAvailability(false)
    }
  }

  @Test @MainActor func nativeConfigurationUsesDocumentedAbsoluteColorTagWithoutCreatingALayer()
    throws
  {
    let profile = HDRMetalPresentationProfile(message: try message())
    if CAEDRMetadata.isAvailable {
      let configuration = try profile.makeLayerConfiguration()
      let name = try #require(configuration.colorSpace.name)
      #expect(CFEqual(name, CGColorSpace.extendedLinearSRGB))
      #expect(configuration.pixelFormat == .rgba16Float)
      #expect(configuration.wantsExtendedDynamicRangeContent && configuration.isOpaque)
      #expect(profile.opticalOutputScaleNits == 80)
    } else {
      #expect(throws: HDRMetalPresentationProfile.Failure.self) {
        try profile.makeLayerConfiguration()
      }
    }
  }

  private func message(
    resourceID: UInt32 = 10, incarnation: UInt64 = 20, color: UInt64 = 30,
    selection: UInt64 = 40, source: UInt32 = 0, target: UInt32 = 0,
    scanout: UInt32 = 0, rowBytes: UInt32 = 256, epochByte: UInt8 = 1
  ) throws -> HDRFrameMessage {
    try HDRFrameMessage(
      admitting: packet(
        resourceID: resourceID, incarnation: incarnation, color: color, selection: selection,
        source: source, target: target, scanout: scanout, rowBytes: rowBytes, epochByte: epochByte),
      limits: HDRFrameLimits(pageBytes: 4096))
  }

  // Independent generated MVH2 bytes exercise the actual C-backed Swift parser.
  private func packet(
    resourceID: UInt32 = 10, incarnation: UInt64 = 20, color: UInt64 = 30,
    selection: UInt64 = 40, source: UInt32 = 0, target: UInt32 = 0,
    scanout: UInt32 = 0, rowBytes: UInt32 = 256, epochByte: UInt8 = 1,
    pixelFormat: UInt32 = 2, encoding: UInt32 = 1, opticalScale: UInt32 = 80_000
  ) -> Data {
    var bytes = Data(repeating: 0, count: 128)
    func put(_ value: UInt64, _ offset: Int, _ count: Int) {
      for index in 0..<count {
        bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
      }
    }
    put(0x3248_564d, 0, 4)
    put(2, 4, 2)
    put(3, 6, 2)
    bytes.replaceSubrange(8..<24, with: repeatElement(epochByte, count: 16))
    put(1, 24, 8)
    put(1, 32, 8)
    put(incarnation, 40, 8)
    put(color, 48, 8)
    put(selection, 56, 8)
    put(UInt64(resourceID), 64, 4)
    put(UInt64(scanout), 68, 4)
    put(32, 72, 4)
    put(2, 76, 4)
    put(UInt64(rowBytes), 80, 4)
    put(4096, 84, 4)
    put(UInt64(pixelFormat), 92, 4)
    put(UInt64(encoding), 96, 4)
    put(UInt64(opticalScale), 100, 4)
    put(1, 104, 8)
    put(UInt64(source), 112, 4)
    put(UInt64(target), 116, 4)
    return bytes
  }
}
