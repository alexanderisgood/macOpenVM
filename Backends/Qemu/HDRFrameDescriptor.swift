// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import SharedFrameWire

/// These types describe an explicitly negotiated MVH2 snapshot. They neither
/// negotiate HDR nor prove source color authority, FD custody or GPU completion.
public enum HDRFrameValidationError: Error, Equatable, Sendable {
  case invalidLimits, invalidDescriptor, unsupportedInterpretation, outOfBounds
  case malformedPacket, unexpectedMessageKind, mappingLength
}

public enum HDRFramePixelFormat: UInt32, Hashable, Sendable {
  case rgba16FloatLittleEndian = 2
  public var bytesPerPixel: Int { 8 }
}

public enum HDRFrameColorEncoding: UInt32, Hashable, Sendable {
  /// Linear Rec.709/sRGB primaries, D65, with RGB(1,1,1) encoding80 cd/m².
  /// This is an explicit producer assertion, never inferred from pixel format.
  case linear709D65Absolute80 = 1
  public var opticalScaleMillinits: UInt32 { 80_000 }
  public var opticalOutputScaleNits: Float { 80 }
}

public struct HDRFrameLimits: Hashable, Sendable {
  public let pageBytes: UInt32
  public let rowAlignment: UInt32
  public let maximumMappingBytes: UInt32

  public init(
    pageBytes: UInt32, rowAlignment: UInt32 = 256,
    maximumMappingBytes: UInt32 = 67_108_864
  ) throws {
    self.pageBytes = pageBytes
    self.rowAlignment = rowAlignment
    self.maximumMappingBytes = maximumMappingBytes
    // Exercise the actual C limit validator with a minimal, valid descriptor;
    // do not maintain a second interpretation of its alignment/size limits.
    var probe = MVOHDRDescriptor()
    probe.resource_id = 1
    probe.resource_incarnation = 1
    probe.color_generation = 1
    probe.scanout_generation = 1
    probe.width = 1
    probe.height = 1
    probe.row_bytes = rowAlignment
    probe.mapped_bytes = pageBytes
    probe.pixel_format = UInt32(MVO_HDR_RGBA16_FLOAT_LE)
    probe.color_encoding = UInt32(MVO_HDR_LINEAR_709_D65_ABSOLUTE_80)
    probe.optical_scale_millinit = UInt32(MVO_HDR_OPTICAL_SCALE_MILLINIT)
    var limits = wireValue
    guard mvo_hdr_validate_descriptor(&probe, &limits) == MVO_HDR_OK else {
      throw HDRFrameValidationError.invalidLimits
    }
  }

  fileprivate var wireValue: MVOHDRLimits {
    var value = MVOHDRLimits()
    value.page_bytes = pageBytes
    value.row_alignment = rowAlignment
    value.maximum_mapping_bytes = maximumMappingBytes
    return value
  }
}

/// Pool/cache meaning. Rotating source resources and scanout selection
/// generations deliberately do not force a new pool or obsolete a drawable.
public struct HDRFrameSurfaceIdentity: Hashable, Sendable {
  public let width: Int
  public let height: Int
  public let rowBytes: Int
  public let mappingBytes: Int
  public let pixelFormat: HDRFramePixelFormat
  public let colorEncoding: HDRFrameColorEncoding
  public let colorGeneration: UInt64
  public let scanoutID: UInt32
  public let sourceID: UInt32
  public let targetID: UInt32
}

/// Immutable facts admitted by the shared C contract. No pixel payload is
/// copied, converted, clamped, normalized or inspected by this value type.
public struct HDRFrameDescriptor: Hashable, Sendable {
  public let resourceID: UInt32
  public let resourceIncarnation: UInt64
  public let colorGeneration: UInt64
  public let scanoutGeneration: UInt64
  public let scanoutID: UInt32
  public let sourceID: UInt32
  public let targetID: UInt32
  public let width: Int
  public let height: Int
  public let rowBytes: Int
  public let mappingBytes: Int
  public let pixelFormat: HDRFramePixelFormat
  public let colorEncoding: HDRFrameColorEncoding

  public init(validating input: MVOHDRDescriptor, limits: HDRFrameLimits) throws {
    var descriptor = input
    var wireLimits = limits.wireValue
    let result = mvo_hdr_validate_descriptor(&descriptor, &wireLimits)
    guard result == MVO_HDR_OK else { throw hdrValidationError(result) }
    guard let format = HDRFramePixelFormat(rawValue: descriptor.pixel_format),
      let encoding = HDRFrameColorEncoding(rawValue: descriptor.color_encoding)
    else { throw HDRFrameValidationError.unsupportedInterpretation }
    resourceID = descriptor.resource_id
    resourceIncarnation = descriptor.resource_incarnation
    colorGeneration = descriptor.color_generation
    scanoutGeneration = descriptor.scanout_generation
    scanoutID = descriptor.scanout_id
    sourceID = descriptor.source_id
    targetID = descriptor.target_id
    width = Int(descriptor.width)
    height = Int(descriptor.height)
    rowBytes = Int(descriptor.row_bytes)
    mappingBytes = Int(descriptor.mapped_bytes)
    pixelFormat = format
    colorEncoding = encoding
  }

  public var size: PixelSize { PixelSize(width: width, height: height) }
  public var pixelRowBytes: Int { width * pixelFormat.bytesPerPixel }
  public var surfaceIdentity: HDRFrameSurfaceIdentity {
    HDRFrameSurfaceIdentity(
      width: width, height: height, rowBytes: rowBytes, mappingBytes: mappingBytes,
      pixelFormat: pixelFormat, colorEncoding: colorEncoding,
      colorGeneration: colorGeneration, scanoutID: scanoutID,
      sourceID: sourceID, targetID: targetID)
  }

  /// A length check only. Actual readonly/shared-memory FD admission and its
  /// independent lifetime remain the mapping owner's responsibility.
  public func validateMappedByteCount(_ count: Int) throws {
    guard count == mappingBytes else { throw HDRFrameValidationError.mappingLength }
  }
}

/// A surface can have identical dimensions/meaning in two retired streams.
/// Keep the stream epoch in any future cache/drawable compatibility token.
public struct HDRFrameSurfaceToken: Hashable, Sendable {
  public let streamEpoch: UUID
  public let surface: HDRFrameSurfaceIdentity
}

/// ATTACH and FRAME are the only producer snapshots admitted here. The actual
/// C parser validates every header field; this wrapper preserves all identities.
/// Stateful sequence admission and endpoint negotiation remain separate work.
public struct HDRFrameMessage: Equatable, Sendable {
  public enum Kind: UInt32, Sendable {
    case attachment = 2
    case frame = 3
  }
  public let kind: Kind
  public let streamEpoch: UUID
  public let sequence: UInt64
  public let contentGeneration: UInt64
  public let sentNanoseconds: UInt64
  public let slot: Int
  public let descriptor: HDRFrameDescriptor
  /// Canonical bytes are not permission to send an ACK. FRAME ACK may only be
  /// sent after the real consumer GPU copy finishes, never on decode/cancel.
  public let canonicalAcknowledgement: Data

  public init(admitting bytes: Data, limits: HDRFrameLimits) throws {
    var header = MVOHDRHeader()
    var wireLimits = limits.wireValue
    let decoded = bytes.withUnsafeBytes { input in
      mvo_hdr_decode(input.baseAddress, input.count, &wireLimits, &header)
    }
    guard decoded == MVO_HDR_OK else { throw hdrValidationError(decoded) }
    guard let kind = Kind(rawValue: header.kind) else {
      throw HDRFrameValidationError.unexpectedMessageKind
    }
    let descriptor = try HDRFrameDescriptor(validating: header.descriptor, limits: limits)
    var acknowledgement = Data(count: Int(MVO_HDR_PACKET_BYTES))
    let acknowledged = acknowledgement.withUnsafeMutableBytes { output in
      bytes.withUnsafeBytes { input in
        mvo_hdr_make_ack(
          input.baseAddress, input.count, &wireLimits, output.baseAddress, output.count)
      }
    }
    guard acknowledged == MVO_HDR_OK else { throw hdrValidationError(acknowledged) }
    self.kind = kind
    streamEpoch = withUnsafeBytes(of: header.epoch) { UUID(uuid: $0.load(as: uuid_t.self)) }
    sequence = header.sequence
    contentGeneration = header.content_generation
    sentNanoseconds = header.sent_ns
    slot = Int(header.slot)
    self.descriptor = descriptor
    canonicalAcknowledgement = acknowledgement
  }

  public var surfaceToken: HDRFrameSurfaceToken {
    HDRFrameSurfaceToken(streamEpoch: streamEpoch, surface: descriptor.surfaceIdentity)
  }
}

private func hdrValidationError(_ result: MVOHDRResult) -> HDRFrameValidationError {
  switch result {
  case MVO_HDR_UNSUPPORTED: return .unsupportedInterpretation
  case MVO_HDR_BOUNDS: return .outOfBounds
  case MVO_HDR_WIRE: return .malformedPacket
  default: return .invalidDescriptor
  }
}
