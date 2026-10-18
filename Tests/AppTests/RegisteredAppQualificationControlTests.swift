// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite struct RegisteredAppQualificationControlTests {
  private func bytes(_ action: RegisteredAppQualificationControl.Action = .status) throws -> Data {
    let request = RegisteredAppQualificationControl.Request(
      requestID: 1, nonce: UUID(),
      vmID: UUID(), sessionID: nil, launchGeneration: nil, action: action)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(request)
  }
  @Test func bootstrapRequestIsCanonicalBoundedAndExplicitlyNull() throws {
    let data = try bytes()
    let value = try RegisteredAppQualificationControl.decode(data)
    #expect(value.requestID == 1 && value.action == .status)
    #expect(value.sessionID == nil && value.launchGeneration == nil)
    #expect(String(decoding: data, as: UTF8.self).contains("\"sessionID\":null"))
    for action in [RegisteredAppQualificationControl.Action.stop, .forceStop, .quit] {
      #expect(try RegisteredAppQualificationControl.decode(bytes(action)).action == action)
    }
  }
  @Test func duplicateUnknownNestedAliasAndBooleanIDRequestsRefuse() throws {
    let data = try bytes()
    let text = String(decoding: data, as: UTF8.self)
    for malformed in [
      String(text.dropLast()) + ",\"requestID\":1}",
      String(text.dropLast()) + ",\"path\":\"/private/unknown\"}",
      text.replacingOccurrences(of: "\"requestID\":1", with: "\"requestID\":true"),
      text.replacingOccurrences(of: "\"requestID\":1", with: "\"requestID\":0"),
      text.replacingOccurrences(of: "\"sessionID\":null", with: "\"sessionID\":{}"),
      " " + text,
    ] {
      #expect(throws: (any Error).self) {
        try RegisteredAppQualificationControl.decode(Data(malformed.utf8))
      }
    }
    #expect(throws: (any Error).self) {
      try RegisteredAppQualificationControl.decode(Data(repeating: 0, count: 2049))
    }
  }
}
