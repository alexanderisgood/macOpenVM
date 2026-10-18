// SPDX-License-Identifier: Apache-2.0
// Pure package-target source fixtures. No sockets, worker, QEMU or VM.
import BackendAPI
import Foundation
import RuntimeIPC
import Testing

private let frameBinding = CaptureBinding(
  vmID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
  sessionID: UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!,
  monitorEpoch: UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!)
private let frameCapture = UInt64(Int64.max)

// Complete independent literals: prefix, three UUIDs, IDs/revision and fields.
// They are deliberately not made by the codec's append/prefix helpers.
private let armFrame: [UInt8] =
  [0, 0, 0, 84, 2, 1, 0, 1]
  + [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255]
  + [16, 33, 50, 67, 84, 101, 118, 135, 152, 169, 186, 203, 220, 237, 254, 15]
  + [255, 238, 221, 204, 187, 170, 153, 136, 119, 102, 85, 68, 51, 34, 17, 0]
  + [0, 0, 0, 0, 0, 0, 0, 3, 1, 2, 3, 4, 5, 6, 7, 8]
  + [127, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0]
private let helloReplyFrame: [UInt8] =
  [0, 0, 0, 104, 2, 2, 0, 0]
  + [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255]
  + [16, 33, 50, 67, 84, 101, 118, 135, 152, 169, 186, 203, 220, 237, 254, 15]
  + [255, 238, 221, 204, 187, 170, 153, 136, 119, 102, 85, 68, 51, 34, 17, 0]
  + [0, 0, 0, 0, 0, 0, 0, 1, 255, 255, 255, 255, 255, 255, 255, 255]
  + [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ]
private let armReplyFrame: [UInt8] =
  [0, 0, 0, 104, 2, 2, 1, 1]
  + [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255]
  + [16, 33, 50, 67, 84, 101, 118, 135, 152, 169, 186, 203, 220, 237, 254, 15]
  + [255, 238, 221, 204, 187, 170, 153, 136, 119, 102, 85, 68, 51, 34, 17, 0]
  + [0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 9]
  + [
    0, 0, 0, 0, 127, 255, 255, 255, 255, 255, 255, 255,
    0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
  ]

private func frameRequest(
  _ operation: CaptureWorkerOperation = .arm,
  requestID: UInt64 = 3, revision: UInt64 = 0x0102_0304_0506_0708,
  capture: UInt64 = frameCapture, offset: UInt32 = 0,
  count: UInt16 = 0
) -> CaptureWorkerRequest {
  CaptureWorkerRequest(
    binding: frameBinding, requestID: requestID,
    observedRevision: revision, operation: operation, capture: capture,
    offset: offset, count: count)
}
private func frameStatus(
  _ phase: UInt32 = 6, records: UInt32 = 2,
  cursor: UInt32 = 0
) throws -> CaptureStatus {
  try CaptureStatus(
    capture: phase == 0 ? 0 : frameCapture, phase: phase,
    records: phase == 6 ? records : 0, reasons: phase == 6 ? 1 : 0,
    cursor: phase == 6 ? cursor : 0, terminal: phase == 6 ? 1 : 0)
}
private func frameRow(
  _ index: UInt64, records: UInt64 = 2,
  capture: UInt64 = frameCapture
) throws -> CaptureRow {
  var words = [UInt64](repeating: 0, count: 18)
  words[0] = index
  words[1] = index == 0 ? 1 : index == records - 1 ? 2 : 3
  words[3] = capture
  words[4] = index + 1
  return try CaptureRow(words)
}
private func frameReply(
  _ operation: CaptureWorkerOperation = .hello,
  binding: CaptureBinding = frameBinding, requestID: UInt64 = 1,
  revision: UInt64 = .max, code: CaptureWorkerCode = .ok,
  rejection: CaptureRejection? = nil, status: CaptureStatus? = nil,
  rows: [CaptureRow] = []
) -> CaptureWorkerReply {
  CaptureWorkerReply(
    binding: binding, requestID: requestID, revision: revision,
    operation: operation, code: code, rejection: rejection, status: status, rows: rows)
}

@Suite("WorkerCaptureFrameCodecTests")
struct WorkerCaptureFrameCodecTests {
  @Test func completeIndependentRequestFixture() throws {
    let request = frameRequest()
    #expect(armFrame.count == 88)
    #expect(try Array(WorkerCaptureFrameCodec.encode(request)) == armFrame)
    #expect(try WorkerCaptureFrameCodec.decodeRequest(Data(armFrame)) == request)
  }

  @Test func completeIndependentHelloReplyAndFullWidthRevision() throws {
    let reply = frameReply()
    #expect(helloReplyFrame.count == 108)
    #expect(try Array(WorkerCaptureFrameCodec.encode(reply)) == helloReplyFrame)
    #expect(try WorkerCaptureFrameCodec.decodeReply(Data(helloReplyFrame)) == reply)
  }

  @Test func completeIndependentSixFieldStatusReply() throws {
    let reply = frameReply(.arm, requestID: 3, revision: 9, status: try frameStatus(2))
    #expect(armReplyFrame.count == 108)
    #expect(try Array(WorkerCaptureFrameCodec.encode(reply)) == armReplyFrame)
    #expect(try WorkerCaptureFrameCodec.decodeReply(Data(armReplyFrame)) == reply)
  }

  @Test func exactLengthPrefixesRejectBeforePayloadUse() throws {
    #expect(try WorkerCaptureFrameCodec.payloadLength(Data([0, 0, 0, 84]), request: true) == 84)
    #expect(try WorkerCaptureFrameCodec.payloadLength(Data([0, 0, 0, 104]), request: false) == 104)
    #expect(
      try WorkerCaptureFrameCodec.payloadLength(Data([0, 0, 36, 104]), request: false) == 9320)
    for header in [Data(), Data([0, 0, 84]), Data([0, 0, 0, 84, 0])] {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.payloadLength(header, request: true)
      }
    }
    for value in [UInt8(0), 56, 83, 85, 104] {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.payloadLength(Data([0, 0, 0, value]), request: true)
      }
    }
    for value in [UInt8(0), 64, 103, 105] {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.payloadLength(Data([0, 0, 0, value]), request: false)
      }
    }
    for header in [Data([0, 0, 36, 105]), Data([255, 255, 255, 255])] {
      for request in [true, false] {
        #expect(throws: CaptureFault.limit) {
          try WorkerCaptureFrameCodec.payloadLength(header, request: request)
        }
      }
    }
  }

  @Test func wholeFramesRejectEveryTruncationTrailingAndCoalescedFrame() throws {
    for count in 0..<armFrame.count {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeRequest(Data(armFrame.prefix(count)))
      }
    }
    for count in 0..<helloReplyFrame.count {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeReply(Data(helloReplyFrame.prefix(count)))
      }
    }
    for suffix in [Data([0]), Data(armFrame)] {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeRequest(Data(armFrame) + suffix)
      }
    }
    for suffix in [Data([0]), Data(helloReplyFrame)] {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeReply(Data(helloReplyFrame) + suffix)
      }
    }
  }

  @Test func requestVersionKindFlagsOpcodeIDAndReservedBytesAreStrict() throws {
    let mutations: [(Int, UInt8)] = [(4, 1), (5, 2), (6, 1), (7, 5), (63, 0), (86, 1), (87, 1)]
    for (offset, value) in mutations {
      var bytes = armFrame
      bytes[offset] = value
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeRequest(Data(bytes))
      }
    }
  }

  @Test func operationShapesAndNumericLimitsRemainClosed() throws {
    for request in [
      frameRequest(requestID: 0), frameRequest(requestID: 97),
      frameRequest(capture: .max), frameRequest(.read, capture: 0, count: 1),
      frameRequest(.read, offset: 4096, count: 1),
      frameRequest(.read, count: 0), frameRequest(.read, count: 65),
    ] {
      #expect(throws: CaptureFault.limit) { try WorkerCaptureFrameCodec.encode(request) }
    }
    for request in [
      frameRequest(capture: 0), frameRequest(offset: 1), frameRequest(count: 1),
      frameRequest(.hello, revision: 1, capture: 0),
      frameRequest(.hello, revision: 0, capture: 1),
      frameRequest(.hello, revision: 0, capture: 0, offset: 1),
      frameRequest(.hello, revision: 0, capture: 0, count: 1),
      frameRequest(.status, offset: 1), frameRequest(.stop, count: 1),
    ] {
      #expect(throws: CaptureFault.malformed) { try WorkerCaptureFrameCodec.encode(request) }
    }
    let limit = frameRequest(.read, requestID: 96, revision: .max, offset: 4095, count: 64)
    #expect(
      try WorkerCaptureFrameCodec.decodeRequest(WorkerCaptureFrameCodec.encode(limit)) == limit)
  }

  @Test func receivedRequestsCannotBypassOperationShapeChecks() throws {
    var helloWithCapture = armFrame
    helloWithCapture[7] = 0
    var zeroArm = armFrame
    for index in 72..<80 { zeroArm[index] = 0 }
    for bytes in [helloWithCapture, zeroArm] {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeRequest(Data(bytes))
      }
    }
    for count in [UInt8(0), 65] {
      var read = armFrame
      read[7] = 4
      read[85] = count
      #expect(throws: CaptureFault.limit) {
        try WorkerCaptureFrameCodec.decodeRequest(Data(read))
      }
    }
    var pastStorage = armFrame
    pastStorage[7] = 4
    pastStorage[82] = 16
    pastStorage[85] = 1
    #expect(throws: CaptureFault.limit) {
      try WorkerCaptureFrameCodec.decodeRequest(Data(pastStorage))
    }
  }

  @Test func replyTagsCodesAbsentStatusReservedAndRowLengthAreStrict() throws {
    let mutations: [(Int, UInt8)] = [
      (4, 1), (5, 1), (6, 2), (7, 5), (63, 0),
      (73, 9), (75, 9), (76, 1), (105, 1), (106, 1), (107, 1),
    ]
    for (offset, value) in mutations {
      var bytes = helloReplyFrame
      bytes[offset] = value
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeReply(Data(bytes))
      }
    }
    var zeroRevision = helloReplyFrame
    for index in 64..<72 { zeroRevision[index] = 0 }
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.decodeReply(Data(zeroRevision))
    }
  }

  @Test func malformedStatusAndRowsRejectAtDomainAndCodecBoundaries() throws {
    let invalid: [(UInt64, UInt32, UInt32, UInt32, UInt32, UInt32)] = [
      (.max, 6, 2, 1, 0, 1), (frameCapture, 7, 2, 1, 0, 1),
      (frameCapture, 6, 4097, 1, 0, 1), (frameCapture, 6, 2, 128, 0, 1),
      (frameCapture, 6, 2, 1, 3, 1), (frameCapture, 6, 2, 1, 0, 2),
      (frameCapture, 2, 2, 0, 0, 0),
    ]
    for fields in invalid {
      #expect(throws: CaptureFault.malformed) {
        try CaptureStatus(
          capture: fields.0, phase: fields.1, records: fields.2,
          reasons: fields.3, cursor: fields.4, terminal: fields.5)
      }
    }
    #expect(throws: CaptureFault.malformed) { try CaptureRow([UInt64](repeating: 0, count: 17)) }
    let first = try frameRow(0)
    let last = try frameRow(1)
    for rows in [
      [last, first], [first, first], [first, try frameRow(1, capture: frameCapture - 1)],
    ] {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.encode(
          frameReply(
            .read,
            status: frameStatus(cursor: 2), rows: rows))
      }
    }
  }

  @Test func receivedStatusAndRowBytesUseTheSameStrictDomainValidation() throws {
    let mutations: [(Int, UInt8)] = [
      (76, 128), (87, 7), (91, 1), (95, 128),
      (99, 1), (103, 2), (6, 0),
    ]
    for (offset, value) in mutations {
      var bytes = armReplyFrame
      bytes[offset] = value
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeReply(Data(bytes))
      }
    }
    let page = try WorkerCaptureFrameCodec.encode(
      frameReply(
        .read,
        status: frameStatus(cursor: 2), rows: [frameRow(0), frameRow(1)]))
    let badWords: [(Int, UInt8)] = [(0, 2), (1, 11), (2, 8), (4, 0), (5, 1)]
    for (word, value) in badWords {
      var bytes = page
      bytes[4 + 104 + word * 8 + 7] = value
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.decodeReply(bytes)
      }
    }
  }

  @Test func replyOperationStatusRowsAndRejectionMustAgree() throws {
    for reply in [
      frameReply(status: try frameStatus(0)), frameReply(.arm),
      frameReply(.read, status: try frameStatus()),
      frameReply(code: .ok, rejection: .busy), frameReply(code: .rejected),
      frameReply(code: .busy, rows: [try frameRow(0)]),
    ] {
      #expect(throws: CaptureFault.malformed) { try WorkerCaptureFrameCodec.encode(reply) }
    }
    let tooMany = try (0..<65).map { try frameRow(UInt64($0), records: 4096) }
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.encode(
        frameReply(
          .read,
          status: frameStatus(records: 4096, cursor: 65), rows: tooMany))
    }
    for raw in UInt16(0)...8 {
      let code = try #require(CaptureWorkerCode(rawValue: raw))
      let reply = frameReply(code: code, rejection: code == .rejected ? .busy : nil)
      #expect(
        try WorkerCaptureFrameCodec.decodeReply(WorkerCaptureFrameCodec.encode(reply)) == reply)
    }
  }

  @Test func maximumPageHasExactBoundAndFullUInt64RowWords() throws {
    var rows = try (0..<64).map { try frameRow(UInt64($0), records: 4096) }
    var words = rows[1].words
    for index in 6..<18 { words[index] = UInt64.max }
    rows[1] = try CaptureRow(words)
    let reply = frameReply(.read, status: try frameStatus(records: 4096, cursor: 64), rows: rows)
    let encoded = try WorkerCaptureFrameCodec.encode(reply)
    #expect(encoded.count == 9324 && WorkerCaptureFrameCodec.maximumFrameBytes == 9324)
    #expect(Array(encoded.prefix(4)) == [0, 0, 36, 104])
    for word in 6..<18 {
      let offset = 4 + 104 + 144 + word * 8
      #expect(Array(encoded[offset..<(offset + 8)]) == [UInt8](repeating: 255, count: 8))
    }
    #expect(try WorkerCaptureFrameCodec.decodeReply(encoded) == reply)
  }

  @Test func everyBindingFieldIdentifierAndOperationMustEcho() throws {
    let foreign = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let request = frameRequest(.hello, requestID: 1, revision: 0, capture: 0)
    for binding in [
      CaptureBinding(
        vmID: foreign, sessionID: frameBinding.sessionID,
        monitorEpoch: frameBinding.monitorEpoch),
      CaptureBinding(
        vmID: frameBinding.vmID, sessionID: foreign,
        monitorEpoch: frameBinding.monitorEpoch),
      CaptureBinding(
        vmID: frameBinding.vmID, sessionID: frameBinding.sessionID,
        monitorEpoch: foreign),
    ] {
      let reply = try WorkerCaptureFrameCodec.decodeReply(
        WorkerCaptureFrameCodec.encode(frameReply(binding: binding)))
      #expect(throws: CaptureFault.identity) {
        try WorkerCaptureFrameCodec.validateEcho(reply, request: request)
      }
    }
    for reply in [frameReply(requestID: 2), frameReply(.status, status: try frameStatus(0))] {
      let decoded = try WorkerCaptureFrameCodec.decodeReply(WorkerCaptureFrameCodec.encode(reply))
      #expect(throws: CaptureFault.identity) {
        try WorkerCaptureFrameCodec.validateEcho(decoded, request: request)
      }
    }
  }

  @Test func existingV1LiteralPathRemainsDistinctAndRejectsV2() throws {
    let request = WorkerRequest(
      vmID: frameBinding.vmID, sessionID: frameBinding.monitorEpoch,
      requestID: 1, observedRevision: 0, command: .status)
    let literal: [UInt8] =
      [0, 0, 0, 56, 1, 1, 0, 0]
      + [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255]
      + [255, 238, 221, 204, 187, 170, 153, 136, 119, 102, 85, 68, 51, 34, 17, 0]
      + [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    #expect(try Array(WorkerFrameCodec.encode(request: request)) == literal)
    #expect(try WorkerFrameCodec.decodeRequest(Data(literal.dropFirst(4))) == request)
    #expect(
      WorkerFrameCodec.requestPayloadBytes == 56 && WorkerFrameCodec.responsePayloadBytes == 64)
    #expect(WorkerFrameCodec.maximumPayloadBytes == 128)
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.decodeRequest(Data(literal))
    }
    #expect(throws: WorkerIPCError.malformedFrame) {
      try WorkerFrameCodec.decodeRequest(Data(armFrame.dropFirst(4)))
    }
    #expect(throws: WorkerIPCError.malformedFrame) {
      try WorkerFrameCodec.decodeResponse(Data(helloReplyFrame.dropFirst(4)))
    }
  }
}

// SPDX-License-Identifier: Apache-2.0
// Unrun directed source regressions for R1 F1. No QMP/socket/runtime actions.

private let echoBinding = CaptureBinding(
  vmID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
  sessionID: UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!,
  monitorEpoch: UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!)
private let echoCapture = UInt64(Int64.max)

private func echoRequest(
  _ operation: CaptureWorkerOperation = .read,
  capture: UInt64 = echoCapture, offset: UInt32 = 0,
  count: UInt16 = 1
) -> CaptureWorkerRequest {
  CaptureWorkerRequest(
    binding: echoBinding, requestID: 5, observedRevision: 7,
    operation: operation, capture: capture, offset: offset,
    count: operation == .read ? count : 0)
}

private func echoRow(_ index: UInt64, capture: UInt64, records: UInt32) throws -> CaptureRow {
  var words = [UInt64](repeating: 0, count: 18)
  words[0] = index
  words[1] = index == 0 ? 1 : index == UInt64(records - 1) ? 2 : 3
  words[3] = capture
  words[4] = index + 1
  words[10] = 100 + index
  if index == UInt64(records - 1) {
    words[14] = UInt64(records)
    words[15] = records == 4096 ? 2 : 1
  }
  return try CaptureRow(words)
}

private func echoPage(
  capture: UInt64 = echoCapture, first: UInt32 = 0,
  returned: UInt32 = 1, records: UInt32 = 4096,
  cursor: UInt32? = nil, revision: UInt64 = 8
) throws -> CaptureWorkerReply {
  let status = try CaptureStatus(
    capture: capture, phase: 6, records: records,
    reasons: records == 4096 ? 2 : 1, cursor: cursor ?? (first + returned), terminal: 1)
  let rows = try (0..<returned).map {
    try echoRow(UInt64(first + $0), capture: capture, records: records)
  }
  return CaptureWorkerReply(
    binding: echoBinding, requestID: 5, revision: revision,
    operation: .read, code: .ok, rejection: nil, status: status, rows: rows)
}

private func decodedEcho(_ reply: CaptureWorkerReply) throws -> CaptureWorkerReply {
  // These F1 replies must pass real global codec validation first. Only the
  // actual request-aware validator can reject their request correlation.
  try WorkerCaptureFrameCodec.decodeReply(WorkerCaptureFrameCodec.encode(reply))
}

private func commandEcho(
  _ operation: CaptureWorkerOperation, capture: UInt64,
  phase: UInt32
) throws -> CaptureWorkerReply {
  let terminal = phase == 6
  let status = try CaptureStatus(
    capture: capture, phase: phase,
    records: terminal ? 2 : 0, reasons: terminal ? 1 : 0,
    cursor: 0, terminal: terminal ? 1 : 0)
  return CaptureWorkerReply(
    binding: echoBinding, requestID: 5, revision: 8,
    operation: operation, code: .ok, rejection: nil, status: status, rows: [])
}

@Suite("WorkerCaptureFrameEchoTests") struct WorkerCaptureFrameEchoTests {
  @Test func validIDWrongReadOffsetIsRejectedByActualValidator() throws {
    let reply = try decodedEcho(echoPage(first: 7, returned: 1))
    let request = echoRequest(offset: 0, count: 1)
    #expect(reply.requestID == request.requestID && reply.revision > request.observedRevision)
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.validateEcho(reply, request: request)
    }
  }

  @Test func validIDOversizedReadPagesAreRejectedByActualValidator() throws {
    let request = echoRequest(offset: 0, count: 1)
    let counts: [UInt32] = [2, 64]
    for returned in counts {
      let reply = try decodedEcho(
        echoPage(
          returned: returned,
          records: returned == 2 ? 2 : 4096))
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.validateEcho(reply, request: request)
      }
    }
  }

  @Test func validIDWrongReadCaptureIsRejectedByActualValidator() throws {
    let reply = try decodedEcho(echoPage(capture: echoCapture - 1, records: 2))
    #expect(throws: CaptureFault.identity) {
      try WorkerCaptureFrameCodec.validateEcho(reply, request: echoRequest())
    }
  }

  @Test func shortNonfinalPageIsRejectedEvenWithCorrectFirstRow() throws {
    let reply = try decodedEcho(echoPage(first: 0, returned: 1, records: 4096))
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.validateEcho(reply, request: echoRequest(count: 64))
    }
  }

  @Test func wrongPostCursorIsRejectedAtActualValidatorBoundary() throws {
    let reply = try echoPage(first: 0, returned: 1, records: 2, cursor: 2)
    // This case is internally inconsistent, unlike F1's decoded cases above.
    // Direct use of validateEcho must retain the global page checks as well.
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.validateEcho(reply, request: echoRequest())
    }
  }

  @Test func offsetsAtOrBeyondTerminalCountRejectBeforeSubtraction() throws {
    let reply = try decodedEcho(echoPage(first: 1, returned: 1, records: 2))
    let offsets: [UInt32] = [2, 4095]
    for offset in offsets {
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.validateEcho(
          reply, request: echoRequest(offset: offset, count: 64))
      }
    }
  }

  @Test func finalShortPage4095Of4096IsAccepted() throws {
    let request = echoRequest(offset: 4095, count: 64)
    let reply = try decodedEcho(echoPage(first: 4095, returned: 1, records: 4096))
    try WorkerCaptureFrameCodec.validateEcho(reply, request: request)
    #expect(reply.rows.count == 1 && reply.rows[0].words[0] == 4095)
    #expect(reply.rows[0].words[1] == 2 && reply.status?.cursor == 4096)
  }

  @Test func legitimateFullAndOneRowPagesAreAccepted() throws {
    let full = try decodedEcho(echoPage(returned: 64, records: 4096))
    try WorkerCaptureFrameCodec.validateEcho(full, request: echoRequest(count: 64))
    let first = try decodedEcho(echoPage(returned: 1, records: 2))
    try WorkerCaptureFrameCodec.validateEcho(first, request: echoRequest(count: 1))
    #expect(full.rows.count == 64 && full.status?.cursor == 64)
    #expect(first.rows.count == 1 && first.status?.cursor == 1)
  }

  @Test func armStatusAndStopRequireMatchingCaptureAndReachablePhase() throws {
    for operation in [CaptureWorkerOperation.arm, .status, .stop] {
      let request = echoRequest(operation)
      let phase: UInt32 = operation == .stop ? 6 : 2
      let good = try decodedEcho(commandEcho(operation, capture: echoCapture, phase: phase))
      try WorkerCaptureFrameCodec.validateEcho(good, request: request)
      let foreign = try decodedEcho(commandEcho(operation, capture: echoCapture - 1, phase: phase))
      #expect(throws: CaptureFault.identity) {
        try WorkerCaptureFrameCodec.validateEcho(foreign, request: request)
      }
    }
    for operation in [CaptureWorkerOperation.arm, .status] {
      let initializing = try decodedEcho(commandEcho(operation, capture: echoCapture, phase: 1))
      #expect(throws: CaptureFault.malformed) {
        try WorkerCaptureFrameCodec.validateEcho(initializing, request: echoRequest(operation))
      }
    }
    let armedStop = try decodedEcho(commandEcho(.stop, capture: echoCapture, phase: 2))
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.validateEcho(armedStop, request: echoRequest(.stop))
    }
    let zeroStatus = try decodedEcho(commandEcho(.status, capture: 0, phase: 0))
    try WorkerCaptureFrameCodec.validateEcho(zeroStatus, request: echoRequest(.status, capture: 0))
    let zeroStop = try decodedEcho(commandEcho(.stop, capture: 0, phase: 0))
    #expect(throws: CaptureFault.malformed) {
      try WorkerCaptureFrameCodec.validateEcho(zeroStop, request: echoRequest(.stop, capture: 0))
    }
  }

  @Test func knownRejectedReadRetainsItsTypedNonSuccessEchoPath() throws {
    let reply = try decodedEcho(
      CaptureWorkerReply(
        binding: echoBinding, requestID: 5,
        revision: 7, operation: .read, code: .rejected, rejection: .notReady,
        status: nil, rows: []))
    try WorkerCaptureFrameCodec.validateEcho(reply, request: echoRequest())
    #expect(reply.code == .rejected && reply.rejection == .notReady)
  }

  @Test func staleSuccessRevisionStillRejectsACorrectPage() throws {
    let reply = try decodedEcho(echoPage(records: 2, revision: 7))
    #expect(throws: CaptureFault.stale) {
      try WorkerCaptureFrameCodec.validateEcho(reply, request: echoRequest())
    }
  }
}
