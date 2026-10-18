// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum WorkerCommand: UInt8, Sendable, CaseIterable {
  case status = 0
  case pause = 1
  case resume = 2
  case forceStop = 3
  /// Requests normal guest shutdown; its reply does not establish completion.
  /// Older private version-1 workers reject this new opcode without mutating the VM.
  case stop = 4
  /// Fixed pointer-device selection, admitted by the actual runtime owner.
  case relativeMouse = 5
  case absoluteMouse = 6
}

public enum WorkerReplyCode: UInt8, Sendable, CaseIterable {
  case none = 0
  case busy = 1
  case stale = 2
  case identity = 3
  case operationFailed = 4
  case recovery = 5
}

public struct WorkerRequest: Equatable, Sendable {
  public let vmID: UUID
  public let sessionID: UUID
  public let requestID: UInt64
  public let observedRevision: UInt64
  public let command: WorkerCommand

  public init(
    vmID: UUID, sessionID: UUID, requestID: UInt64, observedRevision: UInt64,
    command: WorkerCommand
  ) {
    self.vmID = vmID
    self.sessionID = sessionID
    self.requestID = requestID
    self.observedRevision = observedRevision
    self.command = command
  }
}

public struct WorkerResponse: Equatable, Sendable {
  public let vmID: UUID
  public let sessionID: UUID
  public let requestID: UInt64
  public let revision: UInt64
  public let state: UInt8
  public let ownership: UInt8
  public let backendActive: Bool
  public let operationPending: Bool
  public let error: WorkerReplyCode

  public init(
    vmID: UUID, sessionID: UUID, requestID: UInt64, revision: UInt64, state: UInt8,
    ownership: UInt8, backendActive: Bool, operationPending: Bool, error: WorkerReplyCode
  ) {
    self.vmID = vmID
    self.sessionID = sessionID
    self.requestID = requestID
    self.revision = revision
    self.state = state
    self.ownership = ownership
    self.backendActive = backendActive
    self.operationPending = operationPending
    self.error = error
  }
}

public enum WorkerIPCError: Error, Equatable, Sendable {
  case malformedFrame, limitExceeded, unexpectedReply, statusRequired, invalidTimeout
  case unsafeSocket, alreadyConnected, notConnected, closed, busy, deadlineExceeded, disconnected
  case posix(Int32)
}

/// Version 1 uses a four-byte big-endian length followed by a fixed binary payload.
/// Encoders return the entire frame; decoders accept only its payload. State and
/// ownership bytes belong to the coordinator's schema, not to the transport.
public enum WorkerFrameCodec {
  public static let maximumPayloadBytes = 128
  public static let requestPayloadBytes = 56
  public static let responsePayloadBytes = 64

  public static func encode(request: WorkerRequest) throws -> Data {
    guard request.requestID != 0 else { throw WorkerIPCError.malformedFrame }
    var bytes: [UInt8] = [1, 1, 0, 0]
    append(request.vmID, to: &bytes)
    append(request.sessionID, to: &bytes)
    append(request.requestID, to: &bytes)
    append(request.observedRevision, to: &bytes)
    bytes.append(request.command.rawValue)
    bytes.append(contentsOf: [0, 0, 0])
    return frame(bytes)
  }

  public static func encode(response: WorkerResponse) throws -> Data {
    guard response.requestID != 0, response.state <= 10, response.ownership <= 3 else {
      throw WorkerIPCError.malformedFrame
    }
    var bytes: [UInt8] = [1, 2, 0, 0]
    append(response.vmID, to: &bytes)
    append(response.sessionID, to: &bytes)
    append(response.requestID, to: &bytes)
    append(response.revision, to: &bytes)
    bytes.append(contentsOf: [
      response.state, response.ownership, response.backendActive ? 1 : 0,
      response.operationPending ? 1 : 0, response.error.rawValue,
    ])
    bytes.append(contentsOf: repeatElement(0, count: 7))
    return frame(bytes)
  }

  public static func decodeRequest(_ payload: Data) throws -> WorkerRequest {
    guard payload.count <= maximumPayloadBytes else { throw WorkerIPCError.limitExceeded }
    let bytes = Array(payload)
    try validate(bytes, count: requestPayloadBytes, tag: 1)
    guard bytes[53...55].allSatisfy({ $0 == 0 }),
      let command = WorkerCommand(rawValue: bytes[52]), integer(bytes, at: 36) != 0
    else { throw WorkerIPCError.malformedFrame }
    return WorkerRequest(
      vmID: uuid(bytes, at: 4), sessionID: uuid(bytes, at: 20),
      requestID: integer(bytes, at: 36), observedRevision: integer(bytes, at: 44), command: command)
  }

  public static func decodeResponse(_ payload: Data) throws -> WorkerResponse {
    guard payload.count <= maximumPayloadBytes else { throw WorkerIPCError.limitExceeded }
    let bytes = Array(payload)
    try validate(bytes, count: responsePayloadBytes, tag: 2)
    guard bytes[57...63].allSatisfy({ $0 == 0 }), bytes[52] <= 10, bytes[53] <= 3,
      bytes[54] <= 1, bytes[55] <= 1,
      let code = WorkerReplyCode(rawValue: bytes[56]), integer(bytes, at: 36) != 0
    else { throw WorkerIPCError.malformedFrame }
    return WorkerResponse(
      vmID: uuid(bytes, at: 4), sessionID: uuid(bytes, at: 20),
      requestID: integer(bytes, at: 36), revision: integer(bytes, at: 44), state: bytes[52],
      ownership: bytes[53], backendActive: bytes[54] == 1, operationPending: bytes[55] == 1,
      error: code)
  }

  private static func validate(_ bytes: [UInt8], count: Int, tag: UInt8) throws {
    guard bytes.count <= maximumPayloadBytes else { throw WorkerIPCError.limitExceeded }
    guard bytes.count == count, bytes[0] == 1, bytes[1] == tag, bytes[2] == 0, bytes[3] == 0 else {
      throw WorkerIPCError.malformedFrame
    }
  }

  private static func frame(_ payload: [UInt8]) -> Data {
    let length = UInt32(payload.count)
    return Data(
      [
        UInt8(length >> 24), UInt8((length >> 16) & 255),
        UInt8((length >> 8) & 255), UInt8(length & 255),
      ] + payload)
  }

  private static func append(_ value: UInt64, to bytes: inout [UInt8]) {
    for shift in stride(from: 56, through: 0, by: -8) {
      bytes.append(UInt8((value >> shift) & 255))
    }
  }

  private static func append(_ value: UUID, to bytes: inout [UInt8]) {
    var tuple = value.uuid
    withUnsafeBytes(of: &tuple) { bytes.append(contentsOf: $0) }
  }

  private static func integer(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    bytes[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) }
  }

  private static func uuid(_ bytes: [UInt8], at offset: Int) -> UUID {
    UUID(
      uuid: (
        bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
        bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
        bytes[offset + 8], bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
        bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15]
      ))
  }
}
