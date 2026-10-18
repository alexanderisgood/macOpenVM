// SPDX-License-Identifier: Apache-2.0
import Foundation
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Pure mode/correlation gates; no display, socket, worker, frame or credential action.
@Suite(.serialized) struct RfbLabInputPolicyTests {
  private let project = URL(fileURLWithPath: "/private/tmp/policy-project", isDirectory: true)
  private let vmID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let oldSession = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  private var run: String {
    project.path
      + "/.lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0/run-4805dfc7548144148c98a3ff9870e30e"
  }
  private var human: RfbLabInputPolicy {
    RfbLabInputPolicy(
      arguments: ["app", "--windows-network-human-input-display-lab", run], projectRoot: project)
  }

  private func route(vm: UUID? = nil, session: UUID? = nil, legacy: Bool = false) throws
    -> DisplayWorkerRoute
  {
    let scope =
      legacy
      ? "approved-windows-installer-display-route"
      : "approved-windows-network-continuation-display-route"
    let bytes = Data(
      """
      {"schemaVersion":1,"scope":"\(scope)","vmID":"\((vm ?? vmID).uuidString)","sessionID":"\((session ?? sessionID).uuidString)","controlSocket":"/private/tmp/mvo-win-net-0011223344556677/worker.sock","displaySocket":"/private/tmp/mvo-win-net-0011223344556677/vnc.sock","parentDevice":1,"parentInode":2,"socketDevice":1,"socketInode":3}
      """.utf8)
    return try FlatDisplayRouteCodec.decode(
      bytes, profile: legacy ? .existing : .windowsNetworkContinuation)
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
    // RuntimeIntent cannot be minted by a public initializer. Read only a private
    // metadata fixture through the actual bounded reader; it grants no permit.
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("macOpenVM-input-policy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("runtime-intent.json")
    let bytes = Data(
      """
      {"schemaVersion":1,"vmID":"\((vm ?? vmID).uuidString.lowercased())","sessionID":"\((session ?? sessionID).uuidString.lowercased())","state":"\(settled ? "settled" : "unsettled")"}
      """.utf8)
    try bytes.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    return try #require(try await VMFiles().readRuntimeIntent(in: directory))
  }

  @Test func modeSelectionPreservesLegacyBehaviorAndRejectsMixedOrIncompleteRequests() {
    let none = RfbLabInputPolicy(arguments: ["app"], projectRoot: project)
    #expect(!none.selected && !none.canCaptureInput && !none.canControlRuntime)
    for flag in ["--rfb-display-lab", "--windows-installer-display-lab"] {
      let legacy = RfbLabInputPolicy(
        arguments: ["app", flag, "/private/tmp/legacy-fixture"], projectRoot: project)
      #expect(legacy.selected && legacy.canCaptureInput && legacy.canControlRuntime)
      #expect(!legacy.humanInput && !legacy.networkContinuation)
    }
    let observer = RfbLabInputPolicy(
      arguments: ["app", "--windows-network-continuation-display-lab", run], projectRoot: project)
    #expect(observer.selected && observer.networkContinuation && observer.observationOnly)
    #expect(!observer.canCaptureInput && !observer.canControlRuntime && !observer.humanInput)
    #expect(
      human.selected && human.humanInput && human.networkContinuation && human.windowsInstaller)
    #expect(human.canCaptureInput && !human.canControlRuntime && !human.observationOnly)
    for arguments in [
      ["app", "--windows-network-human-input-display-lab"],
      [
        "app", "--windows-network-human-input-display-lab", run,
        "--windows-network-human-input-display-lab", run,
      ],
      [
        "app", "--rfb-display-lab", "/private/tmp/fixture", "--windows-installer-display-lab",
        "/private/tmp/fixture",
      ],
      [
        "app", "--windows-network-continuation-display-lab", run,
        "--windows-network-human-input-display-lab", run,
      ],
      ["app", "--windows-network-human-input-display-lab", "--unknown"],
    ] {
      let invalid = RfbLabInputPolicy(arguments: arguments, projectRoot: project)
      #expect(invalid.selected && invalid.directoryPath == nil && invalid.mode == .invalid)
      #expect(!invalid.canCaptureInput && !invalid.canControlRuntime && !invalid.humanInput)
    }
  }

  @Test func humanModeBindsExactRunVMAndFullSessionWithRuntimeControlAlwaysDisabled() throws {
    #expect(human.validateHumanRoute(try route()))
    #expect(!human.canControlRuntime)
    #expect(!human.validateHumanRoute(try route(vm: UUID())))
    #expect(!human.validateHumanRoute(try route(session: oldSession)))
    #expect(!human.validateHumanRoute(try route(session: UUID())))
    #expect(!human.validateHumanRoute(try route(legacy: true)))
    for path in [
      run + "/", run + "/../" + String(run.split(separator: "/").last!),
      run.replacingOccurrences(
        of: "4805dfc7548144148c98a3ff9870e30e", with: "4805dfc7548144148c98a3ff9870e30f"),
      "/private/tmp/other-project/" + RfbLabInputPolicy.humanRun,
    ] {
      let wrong = RfbLabInputPolicy(
        arguments: ["app", "--windows-network-human-input-display-lab", path], projectRoot: project)
      #expect(wrong.selected && !wrong.canCaptureInput && !wrong.canControlRuntime)
      #expect(!wrong.validateHumanRoute(try route()))
    }
  }

  @Test func liveCorrelationRequiresExactWorkerIntentAndHeldWriter() async throws {
    let admitted = try route()
    let current = try await intent()
    #expect(
      human.allowsHumanCapture(route: admitted, status: status(), intent: current, writerHeld: true)
    )
    for response in [
      status(vm: UUID()), status(session: oldSession), status(session: UUID()),
      status(state: 0), status(state: 4), status(ownership: 1), status(ownership: 2),
      status(active: false), status(pending: true), status(error: .operationFailed),
    ] {
      #expect(
        !human.allowsHumanCapture(
          route: admitted, status: response, intent: current, writerHeld: true))
    }
    for prior in [
      nil, try await intent(vm: UUID()), try await intent(session: oldSession),
      try await intent(session: UUID()), try await intent(settled: true),
    ] {
      #expect(
        !human.allowsHumanCapture(
          route: admitted, status: status(), intent: prior, writerHeld: true))
    }
    #expect(
      !human.allowsHumanCapture(
        route: admitted, status: status(), intent: current, writerHeld: false))
    let observer = RfbLabInputPolicy(
      arguments: ["app", "--windows-network-continuation-display-lab", run], projectRoot: project)
    #expect(
      !observer.allowsHumanCapture(
        route: admitted, status: status(), intent: current, writerHeld: true))
  }

  @Test func captureEpochRejectsReconnectReleaseOrStaleFrameEvenInManualMode() {
    let connection = UUID()
    let epoch = UUID()
    let capture = UUID()
    #expect(
      human.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connection,
        requestedEpoch: epoch, clientEpoch: epoch, frameEpoch: epoch,
        requestedCapture: capture, currentCapture: capture))
    #expect(
      !human.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: UUID(),
        requestedEpoch: epoch, clientEpoch: epoch, frameEpoch: epoch,
        requestedCapture: capture, currentCapture: capture))
    for stale in [nil, UUID()] {
      #expect(
        !human.permitsCaptureEpoch(
          requestedConnection: connection, currentConnection: connection,
          requestedEpoch: epoch, clientEpoch: stale, frameEpoch: epoch,
          requestedCapture: capture, currentCapture: capture))
      #expect(
        !human.permitsCaptureEpoch(
          requestedConnection: connection, currentConnection: connection,
          requestedEpoch: epoch, clientEpoch: epoch, frameEpoch: stale,
          requestedCapture: capture, currentCapture: capture))
      #expect(
        !human.permitsCaptureEpoch(
          requestedConnection: connection, currentConnection: connection,
          requestedEpoch: epoch, clientEpoch: epoch, frameEpoch: epoch,
          requestedCapture: capture, currentCapture: stale))
    }
    let observer = RfbLabInputPolicy(
      arguments: ["app", "--windows-network-continuation-display-lab", run], projectRoot: project)
    #expect(
      !observer.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connection,
        requestedEpoch: epoch, clientEpoch: epoch, frameEpoch: epoch,
        requestedCapture: capture, currentCapture: capture))
  }
}
