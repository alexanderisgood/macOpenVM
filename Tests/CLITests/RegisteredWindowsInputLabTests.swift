// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Foundation
import RuntimeIPC
import Testing
import VMCore

@testable import MacOpenVMCLI
@testable import Qemu

private func inputFrame(epoch: UUID, sequence: UInt64 = 1, data: Data? = nil) -> RFBFrame {
  RFBFrame(
    connectionEpoch: epoch, sequence: sequence, size: PixelSize(width: 2, height: 2),
    rgbaData: data ?? Data([1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255]))
}
private func inputStatus(
  vm: UUID, session: UUID, revision: UInt64 = 7, state: UInt8 = 2,
  ownership: UInt8 = 0, active: Bool = true, pending: Bool = false,
  error: WorkerReplyCode = .none
) -> RegisteredWindowsControl.Result {
  .init(
    action: .status,
    response: .init(
      vmID: vm, sessionID: session, requestID: 1, revision: revision,
      state: state, ownership: ownership, backendActive: active, operationPending: pending,
      error: error))
}

struct RegisteredWindowsInputLabTests {
  @Test func recoveryNavigationRequiresSameActiveOwnedQuiescentSession() throws {
    let vm = UUID()
    let session = UUID()
    for state: UInt8 in [3, 6] {
      let status = inputStatus(vm: vm, session: session, state: state)
      #expect(throws: VMError.self) {
        try RegisteredWindowsInputLab.healthy(status, reference: status)
      }
      try RegisteredWindowsInputLab.healthy(status, reference: status, recovery: true)
      for unsafe in [
        inputStatus(vm: vm, session: session, state: state, ownership: 1),
        inputStatus(vm: vm, session: session, state: state, active: false),
        inputStatus(vm: vm, session: session, state: state, pending: true),
        inputStatus(vm: vm, session: session, state: state, error: .operationFailed),
        inputStatus(vm: UUID(), session: session, state: state),
      ] {
        #expect(throws: VMError.self) {
          try RegisteredWindowsInputLab.healthy(unsafe, reference: status, recovery: true)
        }
      }
    }
    for raw in ["shell", "type", "forceStop", "restart", "click"] {
      #expect(RegisteredWindowsInputLab.RecoveryAction(rawValue: raw) == nil)
    }
  }

  @Test func readOnlyObservationRejectsUnboundedOrLifecycleRequestsBeforeIO() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp/never-created-observe-\(UUID().uuidString)")
    let run = directory.appendingPathComponent(".runtime/run-0123456789abcdef0000000000000000")
    for (action, count) in [
      (RegisteredWindowsControl.Action.pause, 1), (.status, 0), (.status, 121),
    ] {
      let request = try RegisteredWindowsControl.Request(
        action: action, directory: directory, runDirectory: run, expectedSession: UUID())
      do {
        _ = try await RegisteredWindowsInputLab.observe(request: request, frames: count)
        Issue.record("An invalid observation entered directory or peer I/O.")
      } catch let error as VMError { #expect(error.code == .staleOperation) }
    }
    let result = RegisteredWindowsInputLab.Observation(
      vmID: UUID(), sessionID: UUID(), frameCount: 120, width: 800, height: 600,
      elapsedMilliseconds: 1000, receiveIntervalsMilliseconds: [16.5],
      frameWaitMilliseconds: [2.0, 16.0], connectionEpoch: UUID(), completed: true,
      endedAt: "complete")
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    #expect(
      Set(object.keys)
        == Set([
          "scope", "vmID", "sessionID", "frameCount", "width", "height",
          "elapsedMilliseconds", "receiveIntervalsMilliseconds", "frameWaitMilliseconds",
          "connectionEpoch", "completed", "endedAt",
        ]))
  }

  @Test func transportIntervalsPreserveFractionalMilliseconds() {
    #expect(RegisteredWindowsInputLab.milliseconds(.microseconds(16_500)) == 16.5)
    #expect(RegisteredWindowsInputLab.milliseconds(.seconds(2)) == 2000)
  }

  @Test func lifecycleRequestIsRefusedBeforeAnyDirectoryOrPeerRead() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp/never-created-input-\(UUID().uuidString)")
    let run = directory.appendingPathComponent(".runtime/run-0123456789abcdef0000000000000000")
    let request = try RegisteredWindowsControl.Request(
      action: .pause, directory: directory, runDirectory: run, expectedSession: UUID())
    do {
      _ = try await RegisteredWindowsInputLab.run(
        request: request, action: "snapshot", expectedFrame: nil, x: nil, y: nil, key: nil)
      Issue.record("A lifecycle request entered the display evaluator.")
    } catch let error as VMError { #expect(error.code == .staleOperation) }
  }

  @Test func requestShapeHasOnlySnapshotBoundedClickAndClosedNavigationKeys() throws {
    _ = try RegisteredWindowsInputLab.input(
      action: "snapshot", expectedFrame: nil, x: nil, y: nil, key: nil)
    let hash = String(repeating: "a", count: 64)
    for key in [
      "tab", "return", "space", "escape", "up", "down", "home", "end", "pageup", "pagedown",
    ] {
      _ = try RegisteredWindowsInputLab.input(
        action: "key", expectedFrame: hash, x: nil, y: nil, key: key)
    }
    for (action, expected, x, y, key) in [
      ("snapshot", hash as String?, nil as Int?, nil as Int?, nil as String?),
      ("click", hash, -1, 0, nil), ("click", hash, 8192, 0, nil), ("click", nil, 0, 0, nil),
      ("key", hash, nil, nil, "text"), ("key", hash, nil, nil, "ctrl"),
      ("key", hash, 0, nil, "tab"),
      ("stop", hash, nil, nil, nil), ("key", "invalid", nil, nil, "return"),
    ] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsInputLab.input(
          action: action, expectedFrame: expected, x: x, y: y, key: key)
      }
    }
  }

  @Test func displayRouteRequiresRegisteredTenFieldShapeAndExactRunSessionEndpoints() throws {
    let vm = UUID()
    let session = UUID()
    let directory = URL(fileURLWithPath: "/private/tmp/input-shape")
    let run = directory.appendingPathComponent(".runtime/run-0123456789abcdef0000000000000000")
    let request = try RegisteredWindowsControl.Request(
      action: .status, directory: directory, runDirectory: run, expectedSession: session)
    let route = RegisteredWorkerDisplay(
      schemaVersion: 1, scope: "macopenvm-registered-qemu-display-route", vmID: vm,
      sessionID: session,
      controlSocket: "/private/tmp/mvo-qemu-0123456789abcdef/worker.sock",
      displaySocket: "/private/tmp/mvo-qemu-0123456789abcdef/vnc.sock",
      parentDevice: 1, parentInode: 2, socketDevice: 1, socketInode: 3)
    let bytes = try JSONEncoder().encode(route)
    #expect(
      try RegisteredWindowsInputLab.decodeRoute(bytes, request: request, vmID: vm).socketInode == 3)
    let original = String(decoding: bytes, as: UTF8.self)
    for changed in [
      original.replacingOccurrences(of: "0123456789abcdef", with: "fedcba9876543210"),
      original.replacingOccurrences(
        of: "macopenvm-registered-qemu-display-route",
        with: "approved-windows-installer-display-route"),
      original.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
      String(original.dropLast()) + ",\"unknown\":1}",
    ] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsInputLab.decodeRoute(Data(changed.utf8), request: request, vmID: vm)
      }
    }
    #expect(throws: VMError.self) {
      try RegisteredWindowsInputLab.decodeRoute(bytes, request: request, vmID: UUID())
    }
    let foreign = try RegisteredWindowsControl.Request(
      action: .status, directory: directory, runDirectory: run, expectedSession: UUID())
    #expect(throws: VMError.self) {
      try RegisteredWindowsInputLab.decodeRoute(bytes, request: foreign, vmID: vm)
    }
  }

  @Test func frameGuardRejectsStaleHashEpochSizeAndOutOfFrameCoordinates() throws {
    let epoch = UUID()
    let frame = inputFrame(epoch: epoch)
    let ppm = RegisteredWindowsInputLab.ppm(frame)
    #expect(ppm == Data("P6\n2 2\n255\n".utf8) + Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]))
    let expected = SHA256.hash(data: ppm).map { String(format: "%02x", $0) }.joined()
    let click = try RegisteredWindowsInputLab.input(
      action: "click", expectedFrame: expected, x: 1, y: 1, key: nil)
    #expect(try RegisteredWindowsInputLab.frameHash(frame, epoch: epoch, input: click) == expected)
    let outside = try RegisteredWindowsInputLab.input(
      action: "click", expectedFrame: expected, x: 2, y: 1, key: nil)
    let stale = try RegisteredWindowsInputLab.input(
      action: "key", expectedFrame: String(repeating: "0", count: 64), x: nil, y: nil, key: "return"
    )
    for input in [outside, stale] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsInputLab.frameHash(frame, epoch: epoch, input: input)
      }
    }
    #expect(throws: VMError.self) { try RegisteredWindowsInputLab.frameHash(frame, epoch: UUID()) }
    #expect(throws: VMError.self) {
      try RegisteredWindowsInputLab.frameHash(inputFrame(epoch: epoch, sequence: 0), epoch: epoch)
    }
    #expect(throws: VMError.self) {
      try RegisteredWindowsInputLab.frameHash(
        inputFrame(epoch: epoch, data: Data([1])), epoch: epoch)
    }
  }

  @Test func statusRevisionMustStayHealthyAndSnapshotBytesNeverEnterJSON() throws {
    let vm = UUID()
    let session = UUID()
    let reference = inputStatus(vm: vm, session: session)
    try RegisteredWindowsInputLab.healthy(reference, reference: reference)
    for status in [
      inputStatus(vm: vm, session: session, revision: 8), inputStatus(vm: UUID(), session: session),
      inputStatus(vm: vm, session: UUID()), inputStatus(vm: vm, session: session, state: 4),
      inputStatus(vm: vm, session: session, ownership: 3),
      inputStatus(vm: vm, session: session, active: false),
      inputStatus(vm: vm, session: session, pending: true),
      inputStatus(vm: vm, session: session, error: .recovery),
    ] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsInputLab.healthy(status, reference: reference)
      }
    }
    let value = RegisteredWindowsInputLab.Result(
      vmID: vm, sessionID: session, action: "snapshot", beforeSHA256: "before",
      afterSHA256: "after",
      width: 2, height: 2, frameData: Data("PIXELS-MUST-NOT-BE-LOGGED".utf8))
    let encoded = try JSONEncoder().encode(value)
    let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(
      fields["frameData"] == nil && !String(decoding: encoded, as: UTF8.self).contains("PIXELS"))
    #expect(
      Set(fields.keys) == [
        "scope", "vmID", "sessionID", "action", "beforeSHA256", "afterSHA256", "width", "height",
      ])
  }
}
