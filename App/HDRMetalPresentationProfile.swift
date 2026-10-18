// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import Metal
import Qemu
import QuartzCore

/// A configuration value for a future negotiated MVH2 consumer. Nothing calls
/// this from the live renderer: no device, texture, layer or drawable is created.
struct HDRMetalPresentationProfile: Equatable, Sendable {
  enum Failure: Error, Equatable {
    case incompatibleSurface, textureFormat, mappingLength, linearAlignment
    case bufferCapacity, systemToneMappingUnavailable, colorSpaceUnavailable
  }
  enum ColorSpace: Equatable, Sendable { case extendedLinearSRGB }
  enum ShaderPolicy: Equatable, Sendable { case preserveLinearRGB }

  let surfaceToken: HDRFrameSurfaceToken
  let sourcePixelFormat: MTLPixelFormat = .rgba16Float
  let cachePixelFormat: MTLPixelFormat = .rgba16Float
  let outputPixelFormat: MTLPixelFormat = .rgba16Float
  let colorSpace: ColorSpace = .extendedLinearSRGB
  let shaderPolicy: ShaderPolicy = .preserveLinearRGB
  let isOpaque = true
  let wantsExtendedDynamicRangeContent = true
  let permitsSDRSharpening = false

  init(message: HDRFrameMessage) { surfaceToken = message.surfaceToken }

  var opticalOutputScaleNits: Float {
    surfaceToken.surface.colorEncoding.opticalOutputScaleNits
  }

  /// Resource/backbuffer rotation may share a drawable. A color generation,
  /// layout, target or stream change cannot reuse the old presentation profile.
  func matches(_ message: HDRFrameMessage) -> Bool { surfaceToken == message.surfaceToken }

  /// Validate before importing the readonly mapping or constructing a texture.
  /// Alignment/capacity must come from the actual chosen Metal device. This
  /// does not replace FD admission, producer fences or consumer GPU completion.
  func validateImport(
    message: HDRFrameMessage, mappedByteCount: Int, actualPixelFormat: MTLPixelFormat,
    minimumLinearTextureAlignment: Int, maximumBufferLength: Int
  ) throws {
    guard matches(message) else { throw Failure.incompatibleSurface }
    guard actualPixelFormat == sourcePixelFormat else { throw Failure.textureFormat }
    guard mappedByteCount == message.descriptor.mappingBytes else { throw Failure.mappingLength }
    guard minimumLinearTextureAlignment > 0,
      minimumLinearTextureAlignment & (minimumLinearTextureAlignment - 1) == 0,
      message.descriptor.rowBytes % minimumLinearTextureAlignment == 0
    else { throw Failure.linearAlignment }
    guard maximumBufferLength >= mappedByteCount else { throw Failure.bufferCapacity }
  }

  func validateTextureFormats(
    source: MTLPixelFormat, cache: MTLPixelFormat, output: MTLPixelFormat
  ) throws {
    guard source == sourcePixelFormat, cache == cachePixelFormat, output == outputPixelFormat else {
      throw Failure.textureFormat
    }
  }

  func validateSystemToneMappingAvailability(_ available: Bool) throws {
    guard available else { throw Failure.systemToneMappingUnavailable }
  }

  /// Native configuration objects stay on MainActor. The future caller must
  /// install all properties BEFORE requesting a drawable, and discard a pending
  /// drawable when its surface token no longer matches the latest frame.
  struct LayerConfiguration {
    let pixelFormat: MTLPixelFormat
    let colorSpace: CGColorSpace
    let edrMetadata: CAEDRMetadata
    let wantsExtendedDynamicRangeContent: Bool
    let isOpaque: Bool
  }

  @MainActor func makeLayerConfiguration() throws -> LayerConfiguration {
    try validateSystemToneMappingAvailability(CAEDRMetadata.isAvailable)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
      throw Failure.colorSpaceUnavailable
    }
    // Apple's optical relation is C = scale * linearValue. Absolute scRGB
    // already carries Windows' SDR-white adjustment: no0.8 or80/Wguest factor.
    // Nil mastering/content metadata uses documented system defaults; do not
    // invent a1000-nit mastering display for a composed Windows desktop.
    let metadata = CAEDRMetadata.hdr10(
      displayInfo: nil, contentInfo: nil, opticalOutputScale: opticalOutputScaleNits)
    return LayerConfiguration(
      pixelFormat: outputPixelFormat, colorSpace: colorSpace, edrMetadata: metadata,
      wantsExtendedDynamicRangeContent: wantsExtendedDynamicRangeContent, isOpaque: isOpaque)
  }
}
