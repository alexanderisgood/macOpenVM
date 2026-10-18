// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMCLI

@Suite struct RegisteredProducerCaptureTests {
  @Test func separateCanonicalBootstrapPinsBindingSocketCapabilityAndRuntime() throws {
    let binding = CaptureBinding(vmID: UUID(), sessionID: UUID(), monitorEpoch: UUID())
    let socket = URL(fileURLWithPath: "/private/tmp/mvo-qemu-0123456789abcdef/worker.sock")
    let record = RegisteredWorkerCaptureRecord(binding: binding, socket: socket.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let decoded = try RegisteredWorkerCaptureRecord.decode(
      data, vmID: binding.vmID,
      sessionID: binding.sessionID, monitorEpoch: binding.monitorEpoch, socket: socket)
    #expect(decoded == record)
    let text = String(decoding: data, as: UTF8.self)
    let invalid = [
      String(text.dropLast()) + ",\"unexpected\":0}",
      String(text.dropLast()) + ",\"schemaVersion\":1}",
      text.replacingOccurrences(
        of: RegisteredWorkerCaptureRecord.expectedRuntimeSHA256,
        with: String(repeating: "0", count: 64)),
      text.replacingOccurrences(of: "\"capability\":1", with: "\"capability\":2"),
      text.replacingOccurrences(of: "worker.sock", with: "qmp.sock"),
    ]
    for value in invalid {
      var rejected = false
      do {
        _ = try RegisteredWorkerCaptureRecord.decode(
          Data(value.utf8), vmID: binding.vmID,
          sessionID: binding.sessionID, monitorEpoch: binding.monitorEpoch, socket: socket)
      } catch { rejected = true }
      #expect(rejected)
    }
    let foreign = RegisteredWorkerCaptureRecord(
      binding: CaptureBinding(
        vmID: binding.vmID,
        sessionID: binding.sessionID, monitorEpoch: UUID()), socket: socket.path)
    let foreignBytes = try encoder.encode(foreign)
    #expect(throws: CaptureFault.identity) {
      try RegisteredWorkerCaptureRecord.decode(
        foreignBytes, vmID: binding.vmID,
        sessionID: binding.sessionID, monitorEpoch: binding.monitorEpoch, socket: socket)
    }
    #expect(throws: CaptureFault.malformed) {
      try RegisteredWorkerCaptureRecord.decode(
        Data(repeating: 0, count: 4097), vmID: binding.vmID,
        sessionID: binding.sessionID, monitorEpoch: binding.monitorEpoch, socket: socket)
    }
  }

  @Test func privateCommandAllowlistNeverAdmitsMonitorEndpointOrDefaultProfile() throws {
    try RegisteredWindowsCaptureLab.requireProfile("bounded-producer-v1-signed")
    for value in [nil, "", "bounded-producer-v1", "/arbitrary/runtime"] as [String?] {
      #expect(throws: CaptureFault.unavailable) {
        try RegisteredWindowsCaptureLab.requireProfile(value)
      }
    }
    for command in [
      "registered-windows-producer-capture-lab", "windows-producer-capture-worker-lab",
    ] {
      var rejected = false
      do { try MacOpenVMCLI.validateOptions(["socket": "/arbitrary/qmp"], command: command) } catch
      { rejected = true }
      #expect(rejected)
    }
    for command in ["windows-worker", "windows-gpu-worker-lab", "status", "stop"] {
      var rejected = false
      do {
        try MacOpenVMCLI.validateOptions(
          ["capture-profile": "bounded-producer-v1-signed"], command: command)
      } catch { rejected = true }
      #expect(rejected)
    }
  }
}
