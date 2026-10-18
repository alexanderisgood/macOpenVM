// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMStorage

@testable import VMCore

private func trashCoreIntent(vmID: UUID, sessionID: UUID, state: String = "settled") async throws
  -> RuntimeIntent
{
  let directory = URL(fileURLWithPath: "/private/tmp/macOpenVM-trash-core-\(UUID())")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try await VMFiles().writeNewMetadata(
    Data(
      "{\"schemaVersion\":1,\"vmID\":\"\(vmID)\",\"sessionID\":\"\(sessionID)\",\"state\":\"\(state)\"}"
        .utf8),
    at: directory.appendingPathComponent(RuntimeIntent.filename))
  return try #require(try await VMFiles().readRuntimeIntent(in: directory))
}

@Test func trashCoreAdmitsAbsentRuntimeRecordsOrMatchedSettledTerminalHistory() async throws {
  let vmID = UUID()
  try VMTrash.validateStopped(history: nil, intent: nil, vmID: vmID)
  for outcome in [RuntimeOutcome.guestStopped, .forcedStopped, .failed] {
    let sessionID = UUID()
    let record = RuntimeRecord(
      sessionID: sessionID, sequence: 1, recordedAt: 10,
      snapshot: .init(
        state: outcome == .failed ? .failed : .stopped, operation: nil,
        backendActive: false, outcome: outcome))
    let history = try RuntimeHistoryCodec.encode(record)
    let intent = try await trashCoreIntent(vmID: vmID, sessionID: sessionID)
    try VMTrash.validateStopped(history: history, intent: intent, vmID: vmID)
    #expect(throws: VMError.self) {
      try VMTrash.validateStopped(history: history, intent: nil, vmID: vmID)
    }
    #expect(throws: VMError.self) {
      try VMTrash.validateStopped(history: history, intent: intent, vmID: UUID())
    }
    #expect(throws: VMError.self) {
      try VMTrash.validateStopped(history: nil, intent: intent, vmID: vmID)
    }
    let otherSession = try await trashCoreIntent(vmID: vmID, sessionID: UUID())
    #expect(throws: VMError.self) {
      try VMTrash.validateStopped(history: history, intent: otherSession, vmID: vmID)
    }
  }
}

@Test func trashCoreRejectsForeignOrUnsupportedRegistrationAndUnsafeNames() throws {
  let original = VMConfiguration(name: "selected VM", guest: .linux, backend: .appleVz)
  let bytes = try ConfigurationCodec.encode(original)
  try VMTrash.validateRegistration(bytes, expected: original)
  var foreign = original
  foreign.id = UUID()
  #expect(throws: VMError.self) { try VMTrash.validateRegistration(bytes, expected: foreign) }
  var stale = original
  stale.name = "old selection"
  #expect(throws: VMError.self) { try VMTrash.validateRegistration(bytes, expected: stale) }
  for name in ["", "\n", String(repeating: "x", count: 129)] {
    var unsafe = original
    unsafe.name = name
    let data = try ConfigurationCodec.encode(unsafe)
    #expect(throws: VMError.self) { try VMTrash.validateRegistration(data, expected: unsafe) }
  }
  let unknown = Data(
    String(decoding: bytes, as: UTF8.self).replacingOccurrences(
      of: "{", with: "{\"unknown\":true,", options: [], range: nil
    ).utf8)
  #expect(throws: VMError.self) { try VMTrash.validateRegistration(unknown, expected: original) }
}

@Test func trashCoreRejectsAmbiguousOrNoncanonicalHistory() async throws {
  let vmID = UUID()
  let sessionID = UUID()
  let intent = try await trashCoreIntent(vmID: vmID, sessionID: sessionID)
  let record = RuntimeRecord(
    sessionID: sessionID, sequence: 1, recordedAt: 1,
    snapshot: .init(state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped))
  let canonical = try RuntimeHistoryCodec.encode(record)
  let noncanonical = canonical + Data("\n".utf8)
  #expect(throws: VMError.self) {
    try VMTrash.validateStopped(history: noncanonical, intent: intent, vmID: vmID)
  }
}

@Test(arguments: ["unsettled", "active", "operation", "pending", "malformed"])
func trashCoreRejectsUncertainHistory(_ condition: String) async throws {
  let vmID = UUID()
  let sessionID = UUID()
  let intent = try await trashCoreIntent(
    vmID: vmID, sessionID: sessionID, state: condition == "unsettled" ? "unsettled" : "settled")
  let record = RuntimeRecord(
    sessionID: sessionID, sequence: 1, recordedAt: 10,
    snapshot: .init(
      state: .failed, operation: condition == "operation" ? .stop : nil,
      backendActive: condition == "active", outcome: condition == "pending" ? .pending : .failed))
  let history = condition == "malformed" ? Data("{}".utf8) : try RuntimeHistoryCodec.encode(record)
  #expect(throws: VMError.self) {
    try VMTrash.validateStopped(history: history, intent: intent, vmID: vmID)
  }
}
