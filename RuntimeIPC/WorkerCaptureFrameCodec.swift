// SPDX-License-Identifier: Apache-2.0
// Package-only opt-in version2 values. No socket/server or capture authority.
// Whole-frame decoders are intentional; the version1 payload decoder stays exact.
import BackendAPI
import Foundation

package enum WorkerCaptureFrameCodec {
  package static let requestBytes = 84
  package static let replyHeaderBytes = 104
  package static let maximumPayloadBytes = 9320  // 104 + 64 * 18 * 8
  package static let maximumFrameBytes = maximumPayloadBytes + 4

  private static func append(_ value: UInt64, width: Int, to bytes: inout [UInt8]) {
    for shift in (0..<width).reversed() {
      bytes.append(UInt8(truncatingIfNeeded: value >> (shift * 8)))
    }
  }
  private static func integer(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
    bytes[offset..<(offset + width)].reduce(0) { ($0 << 8) | UInt64($1) }
  }
  private static func uuid(_ bytes: [UInt8], _ offset: Int) -> UUID {
    let b = Array(bytes[offset..<(offset + 16)])
    return UUID(
      uuid: (
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
      ))
  }
  private static func prefix(
    _ binding: CaptureBinding, kind: UInt8,
    operation: CaptureWorkerOperation, statusPresent: Bool = false,
    requestID: UInt64, revision: UInt64
  ) -> [UInt8] {
    var bytes: [UInt8] = [2, kind, statusPresent ? 1 : 0, operation.rawValue]
    for id in [binding.vmID, binding.sessionID, binding.monitorEpoch] {
      var raw = id.uuid
      withUnsafeBytes(of: &raw) { bytes.append(contentsOf: $0) }
    }
    append(requestID, width: 8, to: &bytes)
    append(revision, width: 8, to: &bytes)
    return bytes
  }
  private static func frame(_ payload: [UInt8]) throws -> Data {
    guard payload.count <= maximumPayloadBytes else { throw CaptureFault.limit }
    var framed: [UInt8] = []
    append(UInt64(payload.count), width: 4, to: &framed)
    framed.append(contentsOf: payload)
    return Data(framed)
  }
  // This check precedes any proposed WorkerSocket allocation/read of a payload.
  package static func payloadLength(_ header: Data, request: Bool) throws -> Int {
    guard header.count == 4 else { throw CaptureFault.malformed }
    let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard count <= maximumPayloadBytes else { throw CaptureFault.limit }
    if request {
      guard count == requestBytes else { throw CaptureFault.malformed }
    } else {
      guard count >= replyHeaderBytes, (count - UInt32(replyHeaderBytes)) % 144 == 0 else {
        throw CaptureFault.malformed
      }
    }
    return Int(count)
  }
  private static func payload(_ frame: Data, request: Bool) throws -> [UInt8] {
    guard frame.count >= 4 else { throw CaptureFault.malformed }
    let count = try payloadLength(Data(frame.prefix(4)), request: request)
    guard frame.count == count + 4 else { throw CaptureFault.malformed }
    return Array(frame.dropFirst(4))
  }
  private static func common(_ bytes: [UInt8], kind: UInt8) throws
    -> (CaptureBinding, UInt64, UInt64, CaptureWorkerOperation)
  {
    guard bytes[0] == 2, bytes[1] == kind, bytes[2] <= (kind == 1 ? 0 : 1),
      let operation = CaptureWorkerOperation(rawValue: bytes[3]),
      (1...96).contains(integer(bytes, 52, 8))
    else { throw CaptureFault.malformed }
    return (
      CaptureBinding(
        vmID: uuid(bytes, 4), sessionID: uuid(bytes, 20),
        monitorEpoch: uuid(bytes, 36)), integer(bytes, 52, 8), integer(bytes, 60, 8), operation
    )
  }
  package static func encode(_ request: CaptureWorkerRequest) throws -> Data {
    try request.validateShape()
    var bytes = prefix(
      request.binding, kind: 1, operation: request.operation,
      requestID: request.requestID, revision: request.observedRevision)
    append(request.capture, width: 8, to: &bytes)
    append(UInt64(request.offset), width: 4, to: &bytes)
    append(UInt64(request.count), width: 2, to: &bytes)
    bytes += [0, 0]
    return try frame(bytes)
  }
  package static func decodeRequest(_ frame: Data) throws -> CaptureWorkerRequest {
    let bytes = try payload(frame, request: true)
    let (binding, identifier, revision, operation) = try common(bytes, kind: 1)
    guard bytes[82] == 0, bytes[83] == 0 else { throw CaptureFault.malformed }
    let request = CaptureWorkerRequest(
      binding: binding, requestID: identifier,
      observedRevision: revision, operation: operation, capture: integer(bytes, 68, 8),
      offset: UInt32(integer(bytes, 76, 4)), count: UInt16(integer(bytes, 80, 2)))
    try request.validateShape()
    return request
  }
  private static func validate(_ reply: CaptureWorkerReply) throws {
    guard (1...96).contains(reply.requestID), reply.revision > 0, reply.rows.count <= 64,
      (reply.code == .rejected) == (reply.rejection != nil),
      reply.rows.isEmpty || (reply.code == .ok && reply.operation == .read)
    else { throw CaptureFault.malformed }
    if reply.code == .ok {
      switch reply.operation {
      case .hello:
        guard reply.status == nil, reply.rows.isEmpty else { throw CaptureFault.malformed }
      case .arm, .status, .stop:
        guard reply.status != nil, reply.rows.isEmpty else { throw CaptureFault.malformed }
      case .read:
        guard let status = reply.status, status.terminal, !reply.rows.isEmpty,
          status.cursor >= UInt32(reply.rows.count)
        else { throw CaptureFault.malformed }
        let first = UInt64(status.cursor) - UInt64(reply.rows.count)
        for (index, row) in reply.rows.enumerated() {
          guard row.words[0] == first + UInt64(index), row.words[3] == status.capture else {
            throw CaptureFault.malformed
          }
        }
      }
    }
  }
  package static func encode(_ reply: CaptureWorkerReply) throws -> Data {
    try validate(reply)
    var bytes = prefix(
      reply.binding, kind: 2, operation: reply.operation,
      statusPresent: reply.status != nil, requestID: reply.requestID, revision: reply.revision)
    append(UInt64(reply.code.rawValue), width: 2, to: &bytes)
    append(UInt64(reply.rejection?.rawValue ?? 0), width: 2, to: &bytes)
    if let status = reply.status {
      append(status.capture, width: 8, to: &bytes)
      for value in [
        status.phase.rawValue, status.records, status.reasons, status.cursor,
        status.terminal ? UInt32(1) : 0,
      ] { append(UInt64(value), width: 4, to: &bytes) }
    } else {
      bytes += Array(repeating: 0, count: 28)
    }
    append(UInt64(reply.rows.count), width: 2, to: &bytes)
    bytes += [0, 0]
    for row in reply.rows { for word in row.words { append(word, width: 8, to: &bytes) } }
    return try frame(bytes)
  }
  package static func decodeReply(_ frame: Data) throws -> CaptureWorkerReply {
    let bytes = try payload(frame, request: false)
    let (binding, identifier, revision, operation) = try common(bytes, kind: 2)
    guard let code = CaptureWorkerCode(rawValue: UInt16(integer(bytes, 68, 2))),
      bytes[102] == 0, bytes[103] == 0
    else { throw CaptureFault.malformed }
    let rejectionNumber = UInt16(integer(bytes, 70, 2))
    let rejection = rejectionNumber == 0 ? nil : CaptureRejection(rawValue: rejectionNumber)
    guard rejectionNumber == 0 || rejection != nil else { throw CaptureFault.malformed }
    let count = Int(integer(bytes, 100, 2))
    guard count <= 64, bytes.count == replyHeaderBytes + count * 144 else {
      throw CaptureFault.malformed
    }
    let status: CaptureStatus?
    if bytes[2] == 1 {
      status = try CaptureStatus(
        capture: integer(bytes, 72, 8), phase: UInt32(integer(bytes, 80, 4)),
        records: UInt32(integer(bytes, 84, 4)), reasons: UInt32(integer(bytes, 88, 4)),
        cursor: UInt32(integer(bytes, 92, 4)), terminal: UInt32(integer(bytes, 96, 4)))
    } else {
      guard bytes[72..<100].allSatisfy({ $0 == 0 }) else { throw CaptureFault.malformed }
      status = nil
    }
    var rows: [CaptureRow] = []
    for row in 0..<count {
      rows.append(try CaptureRow((0..<18).map { integer(bytes, 104 + row * 144 + $0 * 8, 8) }))
    }
    let reply = CaptureWorkerReply(
      binding: binding, requestID: identifier, revision: revision,
      operation: operation, code: code, rejection: rejection, status: status, rows: rows)
    try validate(reply)
    return reply
  }

  package static func validateEcho(_ reply: CaptureWorkerReply, request: CaptureWorkerRequest)
    throws
  {
    guard reply.binding == request.binding, reply.requestID == request.requestID,
      reply.operation == request.operation
    else { throw CaptureFault.identity }
    // Successful v2 responses carry a fresh coordinator observation. SessionID
    // remains the launch generation; revision is only this observation fence.
    guard reply.code != .ok || reply.revision > request.observedRevision else {
      throw CaptureFault.stale
    }
    try request.validateShape()
    try validate(reply)
    // A rejection may carry the last snapshot rather than a successful result.
    // Keep its existing typed-error path separate from success correlation.
    guard reply.code == .ok else { return }
    if request.operation == .hello { return }  // validate(reply) requires no snapshot.
    guard let status = reply.status else { throw CaptureFault.malformed }
    guard status.capture == request.capture else { throw CaptureFault.identity }
    switch request.operation {
    case .hello: return
    case .arm:
      guard status.phase.rawValue >= CapturePhase.armed.rawValue else {
        throw CaptureFault.malformed
      }
    case .status:
      guard
        request.capture == 0
          ? status.phase == .disarmed
          : status.phase.rawValue >= CapturePhase.armed.rawValue
      else { throw CaptureFault.malformed }
    case .stop:
      guard request.capture > 0, status.phase.rawValue >= CapturePhase.stopping.rawValue else {
        throw CaptureFault.malformed
      }
    case .read:
      guard status.terminal, request.offset < status.records else { throw CaptureFault.malformed }
      // Subtraction is guarded; remaining <=4096 and returned <=64. Still check
      // the addition explicitly, so this boundary never relies on wraparound.
      let remaining = status.records - request.offset
      let returned = min(UInt32(request.count), remaining)
      let (postCursor, overflow) = request.offset.addingReportingOverflow(returned)
      guard !overflow, reply.rows.count == Int(returned), status.cursor == postCursor else {
        throw CaptureFault.malformed
      }
    // validate(reply) already requires rows contiguous through status.cursor;
    // the exact count+post-cursor now bind their first index to request.offset.
    }
  }
}
