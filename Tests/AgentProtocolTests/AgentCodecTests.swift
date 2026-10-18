// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import Foundation
import Testing

private struct AgentVector: Decodable {
  let name: String
  let frameHex: String
}

private func vectors() throws -> [AgentVector] {
  let path = try #require(Bundle.module.url(forResource: "vectors", withExtension: "json"))
  return try JSONDecoder().decode([AgentVector].self, from: Data(contentsOf: path))
}

private func bytes(_ hex: String) throws -> Data {
  let text = Array(hex.utf8)
  #expect(text.count % 2 == 0)
  return try Data(
    stride(from: 0, to: text.count, by: 2).map {
      try #require(UInt8(String(decoding: text[$0..<($0 + 2)], as: UTF8.self), radix: 16))
    })
}

@Test func agentGoldenFramesRoundTripAndHeaderLengths() throws {
  let rows = try vectors()
  #expect(rows.count == 5)
  for row in rows {
    let frame = try bytes(row.frameHex)
    let decoded = try AgentV1Codec.decode(frame)
    #expect(decoded.minor == 0)
    #expect(try AgentV1Codec.encode(decoded.message) == frame)
    #expect(try AgentV1Codec.frameLength(header: frame.prefix(16)) == frame.count)
    // Data slices need not have a zero start index.
    let prefixed = Data(repeating: 0xff, count: 7) + frame
    #expect(try AgentV1Codec.decode(prefixed.dropFirst(7)) == decoded)
  }
}

@Test func agentRejectsEveryShortFrameAndTrailingBytes() throws {
  for row in try vectors() {
    let frame = try bytes(row.frameHex)
    for length in 0..<frame.count {
      #expect(throws: AgentV1CodecError.self) { try AgentV1Codec.decode(frame.prefix(length)) }
    }
    #expect(throws: AgentV1CodecError.self) { try AgentV1Codec.decode(frame + Data([0])) }
  }
  #expect(throws: AgentV1CodecError.self) {
    try AgentV1Codec.decode(Data(repeating: 0, count: AgentV1Codec.maximumFrameBytes + 1))
  }
}

@Test func agentHeaderConflictsAndUnknownKindsAreRejected() throws {
  let frame = try bytes(try #require(vectors().first).frameHex)
  for offset in [0, 4, 8, 10, 12, 15] {
    var changed = frame
    changed[offset] ^= 0xff
    #expect(throws: AgentV1CodecError.self) { try AgentV1Codec.decode(changed) }
  }
  #expect(throws: AgentV1CodecError.self) { try AgentV1Codec.frameLength(header: frame) }
}

@Test func agentPreservesOptionalMinorAndFullWidthSequences() throws {
  let identity = Data(repeating: 0x31, count: 16)
  let request = AgentHealthRequest(sessionID: identity, sequence: .max, requestID: identity)
  let frame = try AgentV1Codec.encode(.healthRequest(request), minor: 7)
  let result = try AgentV1Codec.decode(frame)
  #expect(result.minor == 7 && result.message == .healthRequest(request))
  #expect(frame.suffix(24).prefix(8).allSatisfy { $0 == 0xff })
  let invalid = AgentHealthRequest(sessionID: Data(), sequence: 0, requestID: identity)
  #expect(throws: AgentV1CodecError.self) { try AgentV1Codec.encode(.healthRequest(invalid)) }
}
