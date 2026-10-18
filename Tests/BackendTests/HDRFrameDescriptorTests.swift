// SPDX-License-Identifier: Apache-2.0
import Foundation
import SharedFrameWire
import Testing

@testable import Qemu

struct HDRFrameDescriptorTests {
  @Test func limitsUseTheActualCContract() throws {
    for page in [UInt32(4096), 16384, 65536] {
      for alignment in [UInt32(256), 512, 1024, 2048, 4096] {
        let limits = try HDRFrameLimits(pageBytes: page, rowAlignment: alignment)
        #expect(limits.pageBytes == page && limits.rowAlignment == alignment)
        #expect(limits.maximumMappingBytes == UInt32(MVO_HDR_MAX_MAPPING_BYTES))
      }
    }
    for page in [UInt32(0), 1, 4095, 8193, 131072, UInt32.max] {
      #expect(throws: HDRFrameValidationError.self) { try HDRFrameLimits(pageBytes: page) }
    }
    for alignment in [UInt32(0), 1, 64, 255, 300, 8192, UInt32.max] {
      #expect(throws: HDRFrameValidationError.self) {
        try HDRFrameLimits(pageBytes: 4096, rowAlignment: alignment)
      }
    }
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameLimits(pageBytes: 4096, maximumMappingBytes: 67_108_865)
    }
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameLimits(pageBytes: 65536, maximumMappingBytes: 4096)
    }
  }

  @Test func exactIdentityAndAbsoluteMeaningSurviveAdmission() throws {
    let limits = try HDRFrameLimits(pageBytes: 4096)
    var raw = descriptor()
    raw.resource_id = UInt32.max
    raw.resource_incarnation = UInt64.max
    raw.color_generation = UInt64.max
    raw.scanout_generation = UInt64.max
    raw.source_id = UInt32.max
    let value = try HDRFrameDescriptor(validating: raw, limits: limits)
    #expect(value.resourceID == UInt32.max && value.resourceIncarnation == UInt64.max)
    #expect(value.colorGeneration == UInt64.max && value.scanoutGeneration == UInt64.max)
    #expect(value.sourceID == UInt32.max && value.targetID == 0 && value.scanoutID == 0)
    #expect(value.pixelFormat == .rgba16FloatLittleEndian)
    #expect(value.pixelFormat.bytesPerPixel == 8 && value.pixelRowBytes == 256)
    #expect(value.colorEncoding == .linear709D65Absolute80)
    #expect(value.colorEncoding.opticalScaleMillinits == UInt32(MVO_HDR_OPTICAL_SCALE_MILLINIT))
    #expect(value.colorEncoding.opticalOutputScaleNits == 80)
    #expect(value.size.width == 32 && value.size.height == 2)
    try value.validateMappedByteCount(4096)
    for count in [-1, 0, 4095, 4097, Int.max] {
      #expect(throws: HDRFrameValidationError.self) { try value.validateMappedByteCount(count) }
    }
  }

  @Test func highPrecisionFormatsDoNotImplyTheSupportedColorEncoding() throws {
    let limits = try HDRFrameLimits(pageBytes: 4096)
    for format in [UInt32(0), 1, 3, 10, 24, UInt32.max] {
      var raw = descriptor()
      raw.pixel_format = format
      #expect(throws: HDRFrameValidationError.self) {
        try HDRFrameDescriptor(validating: raw, limits: limits)
      }
    }
    // Driver semantic5 is deliberately a different namespace from wire1.
    for encoding in [UInt32(0), 2, 5, UInt32.max] {
      var raw = descriptor()
      raw.color_encoding = encoding
      #expect(throws: HDRFrameValidationError.self) {
        try HDRFrameDescriptor(validating: raw, limits: limits)
      }
    }
    for scale in [UInt32(0), 80, 79999, 80001, 100000, UInt32.max] {
      var raw = descriptor()
      raw.optical_scale_millinit = scale
      #expect(throws: HDRFrameValidationError.self) {
        try HDRFrameDescriptor(validating: raw, limits: limits)
      }
    }
  }

  @Test func dimensionsAndMappingBoundsMatchTheCValidator() throws {
    let limits = try HDRFrameLimits(pageBytes: 4096)
    var raw = descriptor()
    raw.width = 3840
    raw.height = 2160
    raw.row_bytes = 30720
    raw.mapped_bytes = 66_355_200
    #expect(try HDRFrameDescriptor(validating: raw, limits: limits).mappingBytes == 66_355_200)
    raw.width = 4096
    raw.row_bytes = 32768
    raw.mapped_bytes = 70_778_880
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameDescriptor(validating: raw, limits: limits)
    }
    raw = descriptor()
    raw.width = UInt32.max
    raw.height = UInt32.max
    raw.row_bytes = UInt32.max
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameDescriptor(validating: raw, limits: limits)
    }
    for mapping in [UInt32(0), 4095, 8192, UInt32.max] {
      raw = descriptor()
      raw.mapped_bytes = mapping
      #expect(throws: HDRFrameValidationError.self) {
        try HDRFrameDescriptor(validating: raw, limits: limits)
      }
    }
    raw = descriptor()
    raw.resource_incarnation = 0
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameDescriptor(validating: raw, limits: limits)
    }
  }

  @Test func canonicalAcknowledgementPreservesEveryAdmittedByte() throws {
    let limits = try HDRFrameLimits(pageBytes: 4096)
    for kind in [UInt32(MVO_HDR_ATTACH), UInt32(MVO_HDR_FRAME)] {
      let packet = try packet(kind: kind)
      let original = packet
      let message = try HDRFrameMessage(admitting: packet, limits: limits)
      var expected = packet
      expected[6] = UInt8(MVO_HDR_ACK)
      #expect(message.canonicalAcknowledgement == expected)
      #expect(packet == original)
      #expect(message.descriptor.resourceID == 10 && message.descriptor.resourceIncarnation == 20)
      #expect(
        message.descriptor.colorGeneration == 30 && message.descriptor.scanoutGeneration == 40)
      #expect(message.kind == (kind == UInt32(MVO_HDR_ATTACH) ? .attachment : .frame))
      #expect(message.sequence == (kind == UInt32(MVO_HDR_ATTACH) ? 0 : 7))
      #expect(message.slot == (kind == UInt32(MVO_HDR_ATTACH) ? 2 : 0))
      #expect(message.sentNanoseconds == (kind == UInt32(MVO_HDR_ATTACH) ? 0 : 100))
      // The returned Data has value semantics; an external edit cannot alter
      // the immutable descriptor or the next canonical ACK read.
      var edited = message.canonicalAcknowledgement
      edited[48] ^= 1
      #expect(message.canonicalAcknowledgement == expected && edited != expected)
    }
  }

  @Test func onlyStrictProducerSnapshotMessagesAreAdmitted() throws {
    let limits = try HDRFrameLimits(pageBytes: 4096)
    let valid = try packet()
    for count in [0, 79, 80, 127, 129] {
      var bytes = Data(valid.prefix(count))
      if count > valid.count { bytes.append(0) }
      #expect(throws: HDRFrameValidationError.self) {
        try HDRFrameMessage(admitting: bytes, limits: limits)
      }
    }
    for offset in [4, 88, 92, 96, 100, 120, 127] {
      var bad = valid
      bad[offset] ^= 1
      #expect(throws: HDRFrameValidationError.self) {
        try HDRFrameMessage(admitting: bad, limits: limits)
      }
    }
    var zeroEpoch = valid
    zeroEpoch.replaceSubrange(8..<24, with: repeatElement(UInt8(0), count: 16))
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameMessage(admitting: zeroEpoch, limits: limits)
    }
    var ack = valid
    ack[6] = UInt8(MVO_HDR_ACK)
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameMessage(admitting: ack, limits: limits)
    }
    var request = Data(repeating: 0, count: 128)
    request.replaceSubrange(0..<24, with: valid.prefix(24))
    request[6] = UInt8(MVO_HDR_REQUEST)
    #expect(throws: HDRFrameValidationError.self) {
      try HDRFrameMessage(admitting: request, limits: limits)
    }
  }

  @Test func poolMeaningAndFrameIdentityRemainSeparate() throws {
    let limits = try HDRFrameLimits(pageBytes: 4096)
    let first = try HDRFrameMessage(admitting: packet(), limits: limits)
    var rotation = descriptor()
    rotation.resource_id = 11
    rotation.resource_incarnation = 21
    rotation.scanout_generation = 41
    let rotated = try HDRFrameMessage(admitting: packet(descriptor: rotation), limits: limits)
    #expect(first.descriptor != rotated.descriptor)
    #expect(first.surfaceToken == rotated.surfaceToken)
    var colorChange = rotation
    colorChange.color_generation += 1
    let changed = try HDRFrameMessage(admitting: packet(descriptor: colorChange), limits: limits)
    #expect(first.surfaceToken != changed.surfaceToken)
    let reconnected = try HDRFrameMessage(admitting: packet(epochByte: 2), limits: limits)
    #expect(
      first.descriptor == reconnected.descriptor && first.surfaceToken != reconnected.surfaceToken)
  }

  private func descriptor() -> MVOHDRDescriptor {
    var value = MVOHDRDescriptor()
    value.resource_id = 10
    value.resource_incarnation = 20
    value.color_generation = 30
    value.scanout_generation = 40
    value.width = 32
    value.height = 2
    value.row_bytes = 256
    value.mapped_bytes = 4096
    value.pixel_format = UInt32(MVO_HDR_RGBA16_FLOAT_LE)
    value.color_encoding = UInt32(MVO_HDR_LINEAR_709_D65_ABSOLUTE_80)
    value.optical_scale_millinit = UInt32(MVO_HDR_OPTICAL_SCALE_MILLINIT)
    return value
  }

  private func packet(
    kind: UInt32 = UInt32(MVO_HDR_FRAME), descriptor supplied: MVOHDRDescriptor? = nil,
    epochByte: UInt8 = 1
  ) throws -> Data {
    var header = MVOHDRHeader()
    withUnsafeMutableBytes(of: &header.epoch) { raw in
      _ = raw.initializeMemory(as: UInt8.self, repeating: epochByte)
    }
    header.kind = kind
    header.descriptor = supplied ?? descriptor()
    header.sequence = kind == UInt32(MVO_HDR_ATTACH) ? 0 : 7
    header.content_generation = kind == UInt32(MVO_HDR_ATTACH) ? 0 : 9
    header.sent_ns = kind == UInt32(MVO_HDR_ATTACH) ? 0 : 100
    header.slot = kind == UInt32(MVO_HDR_ATTACH) ? 2 : 0
    var limits = MVOHDRLimits()
    limits.page_bytes = 4096
    limits.row_alignment = 256
    limits.maximum_mapping_bytes = UInt32(MVO_HDR_MAX_MAPPING_BYTES)
    var bytes = Data(count: Int(MVO_HDR_PACKET_BYTES))
    let result = bytes.withUnsafeMutableBytes {
      mvo_hdr_encode(&header, &limits, $0.baseAddress, $0.count)
    }
    try #require(result == MVO_HDR_OK)
    return bytes
  }
}
