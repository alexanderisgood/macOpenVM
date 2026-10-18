// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Caller binding and display correlation only. No external VM, socket, input or credential access.
@Suite(.serialized) struct ExternalWindowsHumanInputPolicyTests {
  private let vmID = RfbLabInputPolicy.humanVMID
  private let sessionID = UUID(uuid: (0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15))
  private var run: String {
    ExternalWindowsHumanInputPolicy.runParentPath + "/run-00112233445566778899aabbccddeeff"
  }

  private func data(
    vm: UUID? = nil, session: UUID? = nil, endpoint: String = "mvo-win-external-0011223344556677",
    displayName: String = "vnc.sock", scope: String = ExternalWindowsHumanInputPolicy.scope
  ) -> Data {
    Data(
      """
      {"schemaVersion":1,"scope":"\(scope)","vmID":"\((vm ?? vmID).uuidString)","sessionID":"\((session ?? sessionID).uuidString)","controlSocket":"/private/tmp/\(endpoint)/worker.sock","displaySocket":"/private/tmp/\(endpoint)/\(displayName)","parentDevice":1,"parentInode":2,"socketDevice":1,"socketInode":3}
      """.utf8)
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func policy(for data: Data) -> ExternalWindowsHumanInputPolicy {
    ExternalWindowsHumanInputPolicy(
      arguments: [
        "app", ExternalWindowsHumanInputPolicy.flag, run, sessionID.uuidString, digest(data),
      ])
  }

  private func status(
    vm: UUID? = nil, session: UUID? = nil, state: UInt8 = 2,
    ownership: UInt8 = 0, active: Bool = true, pending: Bool = false,
    error: WorkerReplyCode = .none
  ) -> WorkerResponse {
    WorkerResponse(
      vmID: vm ?? vmID, sessionID: session ?? sessionID, requestID: 1, revision: 1,
      state: state, ownership: ownership, backendActive: active,
      operationPending: pending, error: error)
  }

  private func intent(vm: UUID? = nil, session: UUID? = nil, settled: Bool = false) async throws
    -> RuntimeIntent
  {
    let directory = URL(
      fileURLWithPath: "/private/tmp/input-external-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent(RuntimeIntent.filename)
    try Data(
      """
      {"schemaVersion":1,"vmID":"\((vm ?? vmID).uuidString)","sessionID":"\((session ?? sessionID).uuidString)","state":"\(settled ? "settled" : "unsettled")"}
      """.utf8
    ).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    return try #require(try await VMFiles().readRuntimeIntent(in: directory))
  }

  @Test func exactExternalRunAndIndependentFreshSessionAreRequired() {
    let bytes = data()
    let admitted = policy(for: bytes)
    #expect(admitted.selected && admitted.canCaptureInput && !admitted.canControlRuntime)
    #expect(admitted.directoryPath == run && admitted.binding?.sessionID == sessionID)
    #expect(ExternalWindowsHumanInputPolicy(arguments: ["app"]).binding == nil)
    for path in [
      run + "/", run + "/../" + String(run.split(separator: "/").last ?? ""),
      run.replacingOccurrences(of: "continuation-runs", with: "other-runs"),
      run.replacingOccurrences(of: "00112233445566778899aabbccddeeff", with: "001122"),
      "/private/tmp/run-00112233445566778899aabbccddeeff",
    ] {
      let refused = ExternalWindowsHumanInputPolicy(
        arguments: [
          "app", ExternalWindowsHumanInputPolicy.flag, path, sessionID.uuidString, digest(bytes),
        ])
      #expect(refused.selected && !refused.canCaptureInput && !refused.canControlRuntime)
    }
    for text in [
      RfbLabInputPolicy.humanSessionID.uuidString, "33333333-3333-4333-8333-333333333333",
      "invalid",
    ] {
      #expect(
        !ExternalWindowsHumanInputPolicy(
          arguments: ["app", ExternalWindowsHumanInputPolicy.flag, run, text, digest(bytes)])
          .canCaptureInput)
    }
    for arguments in [
      ["app", ExternalWindowsHumanInputPolicy.flag, run],
      [
        "app", ExternalWindowsHumanInputPolicy.flag, run, sessionID.uuidString,
        "A" + String(digest(bytes).dropFirst()),
      ],
      [
        "app", ExternalWindowsHumanInputPolicy.flag, run, sessionID.uuidString, digest(bytes),
        ExternalWindowsHumanInputPolicy.flag, run,
      ],
      [
        "app", ExternalWindowsHumanInputPolicy.flag, run, sessionID.uuidString, digest(bytes),
        "--windows-network-human-input-display-lab", run,
      ],
      [
        "app", "--windows-installer-display-lab", run, ExternalWindowsHumanInputPolicy.flag, run,
        sessionID.uuidString, digest(bytes),
      ],
    ] {
      let refused = ExternalWindowsHumanInputPolicy(arguments: arguments)
      #expect(refused.selected && !refused.canCaptureInput && !refused.canControlRuntime)
    }
  }

  @Test func savedRouteCannotRetargetCallerSessionDigestOrEndpoint() throws {
    let bytes = data()
    let admitted = policy(for: bytes)
    let route = try FlatDisplayRouteCodec.decode(bytes, profile: .windowsExternalContinuation)
    #expect(admitted.validateRoute(route, data: bytes))
    #expect(!admitted.validateRoute(route, data: bytes + Data([32])))
    for changed in [
      data(vm: UUID()), data(session: UUID()), data(endpoint: "mvo-win-net-0011223344556677"),
      data(displayName: "other.sock"),
    ] {
      let decoded = try FlatDisplayRouteCodec.decode(changed, profile: .windowsExternalContinuation)
      #expect(!admitted.validateRoute(decoded, data: changed))
      #expect(!policy(for: changed).validateRoute(decoded, data: changed))
    }
    let old = data(scope: "approved-windows-network-continuation-display-route")
    let oldRoute = try FlatDisplayRouteCodec.decode(old, profile: .windowsNetworkContinuation)
    #expect(!policy(for: old).validateRoute(oldRoute, data: old))
    #expect(!admitted.canControlRuntime)
  }

  @Test func captureNeedsSameHealthyWorkerAndUnsettledOwnedVM() async throws {
    let bytes = data()
    let admitted = policy(for: bytes)
    let route = try FlatDisplayRouteCodec.decode(bytes, profile: .windowsExternalContinuation)
    let current = try await intent()
    #expect(
      admitted.allowsHumanCapture(
        route: route, data: bytes, status: status(), intent: current, writerHeld: true))
    for reply in [
      status(vm: UUID()), status(session: UUID()), status(state: 4), status(state: 0),
      status(ownership: 1), status(active: false), status(pending: true),
      status(error: .operationFailed),
    ] {
      #expect(
        !admitted.allowsHumanCapture(
          route: route, data: bytes, status: reply, intent: current, writerHeld: true))
    }
    for prior in [
      nil, try await intent(vm: UUID()), try await intent(session: UUID()),
      try await intent(settled: true),
    ] {
      #expect(
        !admitted.allowsHumanCapture(
          route: route, data: bytes, status: status(), intent: prior, writerHeld: true))
    }
    #expect(
      !admitted.allowsHumanCapture(
        route: route, data: bytes, status: status(), intent: current, writerHeld: false))
  }

  @Test func reconnectReleaseAndStaleFrameInvalidateCapture() {
    let admitted = policy(for: data())
    let connection = UUID()
    let epoch = UUID()
    let capture = UUID()
    #expect(
      admitted.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connection, requestedEpoch: epoch,
        clientEpoch: epoch, frameEpoch: epoch, requestedCapture: capture, currentCapture: capture))
    #expect(
      !admitted.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: UUID(), requestedEpoch: epoch,
        clientEpoch: epoch, frameEpoch: epoch, requestedCapture: capture, currentCapture: capture))
    for stale in [nil, UUID()] {
      #expect(
        !admitted.permitsCaptureEpoch(
          requestedConnection: connection, currentConnection: connection, requestedEpoch: epoch,
          clientEpoch: stale, frameEpoch: epoch, requestedCapture: capture, currentCapture: capture)
      )
      #expect(
        !admitted.permitsCaptureEpoch(
          requestedConnection: connection, currentConnection: connection, requestedEpoch: epoch,
          clientEpoch: epoch, frameEpoch: stale, requestedCapture: capture, currentCapture: capture)
      )
      #expect(
        !admitted.permitsCaptureEpoch(
          requestedConnection: connection, currentConnection: connection, requestedEpoch: epoch,
          clientEpoch: epoch, frameEpoch: epoch, requestedCapture: capture, currentCapture: stale))
    }
  }
}
