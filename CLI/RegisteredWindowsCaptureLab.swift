// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import RuntimeIPC

/// Separate canonical publication by the actual bound owner. This locates a
/// capability; it does not replace server-side owner/connection admission.
struct RegisteredWorkerCaptureRecord: Codable, Equatable, Sendable {
  static let expectedRuntimeSHA256 =
    "3975e5d2199bafb5ee82b40e5d79507a0a4b7adbdee7b570f2b06be0e492ed0e"
  let schemaVersion: UInt32
  let scope: String
  let capability: UInt8
  let vmID: UUID
  let sessionID: UUID
  let monitorEpoch: UUID
  let socket: String
  let runtimeSHA256: String

  init(binding: CaptureBinding, socket: String) {
    schemaVersion = 1
    scope = "macopenvm-registered-qemu-producer-capture-route"
    capability = CaptureCapability.boundedProducerV1.rawValue
    vmID = binding.vmID
    sessionID = binding.sessionID
    monitorEpoch = binding.monitorEpoch
    self.socket = socket
    runtimeSHA256 = Self.expectedRuntimeSHA256
  }
  var binding: CaptureBinding {
    CaptureBinding(vmID: vmID, sessionID: sessionID, monitorEpoch: monitorEpoch)
  }
  static func decode(
    _ data: Data, vmID: UUID, sessionID: UUID, monitorEpoch: UUID,
    socket: URL
  ) throws -> Self {
    guard !data.isEmpty, data.count <= 4096 else { throw CaptureFault.malformed }
    let record = try JSONDecoder().decode(Self.self, from: data)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let expected = Self(
      binding: CaptureBinding(
        vmID: vmID, sessionID: sessionID,
        monitorEpoch: monitorEpoch), socket: socket.path)
    guard record == expected, try encoder.encode(record) == data else {
      throw CaptureFault.identity
    }
    return record
  }
}

enum RegisteredWindowsCaptureLab {
  static func requireProfile(_ value: String?) throws {
    guard value == "bounded-producer-v1-signed" else { throw CaptureFault.unavailable }
  }
  struct Result: Encodable, Sendable {
    let schemaVersion: UInt32 = 1
    let vmID: UUID, sessionID: UUID, monitorEpoch: UUID
    let capture: UInt64
    let completed: Bool
    let diagnosticLost: Bool
    let records: UInt32
    let reasons: UInt32
    let rows: [[UInt64]]
  }
  struct Admission: Sendable {
    let ordinary: RegisteredWindowsControl.Admission
    let record: RegisteredWorkerCaptureRecord
    let bytes: Data
    init(request: RegisteredWindowsControl.Request, monitorEpoch: UUID) async throws {
      guard request.action == .status else { throw CaptureFault.unavailable }
      ordinary = try await RegisteredWindowsControl.Admission(request)
      bytes = try WindowsExternalFileIO.readPrivate(
        request.runDirectory.appendingPathComponent("capture.json"), maximum: 4096)
      record = try RegisteredWorkerCaptureRecord.decode(
        bytes, vmID: ordinary.vmID,
        sessionID: request.expectedSession, monitorEpoch: monitorEpoch, socket: ordinary.socket)
      try await revalidate()
    }
    func revalidate() async throws {
      try await ordinary.revalidate()
      guard
        try WindowsExternalFileIO.readPrivate(
          ordinary.request.runDirectory.appendingPathComponent("capture.json"), maximum: 4096)
          == bytes
      else { throw CaptureFault.identity }
    }
  }

  /// One attachment, one arm, one optional stop and bounded one-pass readout.
  /// Failure closes only the diagnostic connection. No cleanup stop/quit exists.
  static func run(
    request: RegisteredWindowsControl.Request, monitorEpoch: UUID,
    capture: UInt64, milliseconds: Int = 250
  ) async throws -> Result {
    guard capture > 0, capture <= UInt64(Int64.max), (1...1000).contains(milliseconds) else {
      throw CaptureFault.limit
    }
    let admission = try await Admission(request: request, monitorEpoch: monitorEpoch)
    let client = WorkerCaptureIPCClient(
      socketURL: admission.ordinary.socket,
      binding: admission.record.binding)
    var rows: [[UInt64]] = []
    var terminal: CaptureStatus?
    do {
      try await admission.revalidate()
      try await client.connect()
      try requireOK(try await client.hello())
      let before = try status(try await client.status())
      guard before.phase == .disarmed else { throw CaptureFault.alreadyUsed }
      try await admission.revalidate()
      var current = try status(try await client.arm(capture))
      if !current.terminal {
        try await Task.sleep(for: .milliseconds(Int64(milliseconds)))
        try await admission.revalidate()
        current = try status(try await client.status())
        if !current.terminal { current = try status(try await client.stop()) }
        // Initial disarmed+post-window statuses consume2; at most14 remain.
        for _ in 0..<14 {
          if current.terminal { break }
          try await Task.sleep(for: .milliseconds(20))
          try await admission.revalidate()
          current = try status(try await client.status())
        }
      }
      guard current.terminal else { throw CaptureFault.notReady }
      terminal = current
      for _ in 0..<64 {
        if current.cursor == current.records { break }
        try await admission.revalidate()
        let page = try await client.read()
        current = try status(page)
        guard rows.count <= 4096 - page.rows.count else { throw CaptureFault.limit }
        rows.append(contentsOf: page.rows.map(\.words))
      }
      guard current.cursor == current.records, rows.count == Int(current.records) else {
        throw CaptureFault.malformed
      }
      try await admission.revalidate()
      await client.close()
      return Result(
        vmID: admission.record.vmID, sessionID: admission.record.sessionID,
        monitorEpoch: monitorEpoch, capture: capture, completed: true, diagnosticLost: false,
        records: current.records, reasons: current.reasons, rows: rows)
    } catch {
      let lost = await client.diagnosticLost
      await client.close()
      // Earlier complete pages remain numeric evidence; missing pages stay lost.
      return Result(
        vmID: admission.record.vmID, sessionID: admission.record.sessionID,
        monitorEpoch: monitorEpoch, capture: capture, completed: false, diagnosticLost: lost,
        records: terminal?.records ?? 0, reasons: terminal?.reasons ?? 0, rows: rows)
    }
  }
  private static func requireOK(_ reply: CaptureWorkerReply) throws {
    guard reply.code == .ok else { throw CaptureFault.unavailable }
  }
  private static func status(_ reply: CaptureWorkerReply) throws -> CaptureStatus {
    try requireOK(reply)
    guard let status = reply.status else { throw CaptureFault.malformed }
    return status
  }
}
