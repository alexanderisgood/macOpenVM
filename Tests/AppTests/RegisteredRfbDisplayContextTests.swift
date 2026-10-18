// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Foundation
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Private metadata fixtures and pure correlation. No worker, socket, frame or input is created.
@MainActor private final class RegisteredRfbFixture {
  let directory: URL
  let records: URL
  let ready: URL
  var configuration: VMConfiguration
  let session = UUID()
  let generation = UUID()
  var bytes: Data { routeBytes() }
  init() throws {
    directory = URL(
      fileURLWithPath: "/private/tmp/registered-rfb-\(UUID().uuidString)", isDirectory: true)
    records = directory.appendingPathComponent(
      ".runtime/run-00112233445566778899aabbccddeeff", isDirectory: true)
    ready = records.appendingPathComponent("display.json")
    configuration = VMConfiguration(
      name: "Registered Windows", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 * 1_073_741_824, diskBytes: 64 * 1_073_741_824)
    for path in [directory, directory.appendingPathComponent(".runtime"), records] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    try saveConfiguration(configuration)
    try save(bytes, at: ready)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
  func save(_ bytes: Data, at url: URL) throws {
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func saveConfiguration(_ value: VMConfiguration) throws {
    try save(
      ConfigurationCodec.encode(value), at: directory.appendingPathComponent("configuration.json"))
  }
  func routeBytes(
    vm: UUID? = nil, session: UUID? = nil, scope: String = RegisteredRfbDisplayContext.scope
  ) -> Data {
    Data(
      """
      {"schemaVersion":1,"scope":"\(scope)","vmID":"\((vm ?? configuration.id).uuidString)","sessionID":"\((session ?? self.session).uuidString)","controlSocket":"/private/tmp/mvo-qemu-0011223344556677/worker.sock","displaySocket":"/private/tmp/mvo-qemu-0011223344556677/vnc.sock","parentDevice":1,"parentInode":2,"socketDevice":1,"socketInode":3}
      """.utf8)
  }
  func context(
    configuration: VMConfiguration? = nil, session: UUID? = nil,
    records: URL? = nil, ready: URL? = nil, bytes: Data? = nil
  ) throws -> RegisteredRfbDisplayContext {
    let data = bytes ?? self.bytes
    return try RegisteredRfbDisplayContext(
      configuration: configuration ?? self.configuration,
      directory: directory, sessionID: session ?? self.session, launchGeneration: generation,
      readinessDirectory: records ?? self.records, readinessURL: ready ?? self.ready,
      readinessData: data, expectedReadinessSHA256: Self.hash(data),
      route: FlatDisplayRouteCodec.decode(data, profile: .registeredQemu))
  }
  static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  func status(
    vm: UUID? = nil, session: UUID? = nil, state: UInt8 = 2, ownership: UInt8 = 0,
    active: Bool = true, pending: Bool = false, error: WorkerReplyCode = .none
  ) -> WorkerResponse {
    WorkerResponse(
      vmID: vm ?? configuration.id, sessionID: session ?? self.session,
      requestID: 1, revision: 1, state: state, ownership: ownership,
      backendActive: active, operationPending: pending, error: error)
  }
  func intent(vm: UUID? = nil, session: UUID? = nil, settled: Bool = false) async throws
    -> RuntimeIntent
  {
    try save(
      Data(
        """
        {"schemaVersion":1,"vmID":"\((vm ?? configuration.id).uuidString)","sessionID":"\((session ?? self.session).uuidString)","state":"\(settled ? "settled" : "unsettled")"}
        """.utf8), at: directory.appendingPathComponent(RuntimeIntent.filename))
    return try #require(try await VMFiles().readRuntimeIntent(in: directory))
  }
}

@MainActor @Suite(.serialized) struct RegisteredRfbDisplayContextTests {
  @Test func callerBoundNormalContextReadsExactPrivateRegistrationAndReadiness() throws {
    let f = try RegisteredRfbFixture()
    defer { f.remove() }
    let context = try f.context()
    let admitted = try context.readAdmission(currentLaunchGeneration: f.generation)
    #expect(admitted.data == f.bytes && admitted.route == context.route)
    #expect(context.configuration.id == f.configuration.id && context.sessionID == f.session)
    for stale in [nil, UUID()] {
      #expect(throws: VMError.self) { try context.readAdmission(currentLaunchGeneration: stale) }
    }
  }

  @Test func constructorRejectsForeignConfigurationSessionAndRecordNamespace() throws {
    let f = try RegisteredRfbFixture()
    defer { f.remove() }
    for changed in [f.routeBytes(vm: UUID()), f.routeBytes(session: UUID())] {
      #expect(throws: VMError.self) { try f.context(bytes: changed) }
    }
    for field in ["guest", "backend", "boot", "architecture"] {
      var foreign = f.configuration
      if field == "guest" { foreign.guest = .linux }
      if field == "backend" { foreign.backend = .appleVz }
      if field == "boot" { foreign.boot = .linuxKernel }
      if field == "architecture" { foreign.architecture = .x8664 }
      #expect(throws: VMError.self) { try f.context(configuration: foreign) }
    }
    #expect(throws: VMError.self) { try f.context(session: UUID()) }
    #expect(throws: VMError.self) {
      try f.context(
        records: f.directory.appendingPathComponent("other/run-00112233445566778899aabbccddeeff"))
    }
    #expect(throws: VMError.self) {
      try f.context(ready: f.records.appendingPathComponent("other.json"))
    }
    let route = try FlatDisplayRouteCodec.decode(f.bytes, profile: .registeredQemu)
    #expect(throws: VMError.self) {
      try RegisteredRfbDisplayContext(
        configuration: f.configuration, directory: f.directory,
        sessionID: f.session, launchGeneration: f.generation, readinessDirectory: f.records,
        readinessURL: f.ready, readinessData: f.bytes,
        expectedReadinessSHA256: String(repeating: "0", count: 64), route: route)
    }
  }

  @Test func actualMetadataModeSymlinkHardlinkAndReplacementAreRejected() throws {
    for fault in ["mode", "symlink", "hardlink", "bytes", "ancestor", "configuration-link"] {
      let f = try RegisteredRfbFixture()
      defer { f.remove() }
      let context = try f.context()
      switch fault {
      case "mode":
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o644], ofItemAtPath: f.ready.path)
      case "symlink":
        let other = f.records.appendingPathComponent("other.json")
        try f.save(f.bytes, at: other)
        try FileManager.default.removeItem(at: f.ready)
        try FileManager.default.createSymbolicLink(at: f.ready, withDestinationURL: other)
      case "hardlink":
        try FileManager.default.linkItem(
          at: f.ready, to: f.records.appendingPathComponent("other.json"))
      case "bytes": try f.save(f.bytes + Data([32]), at: f.ready)
      case "ancestor":
        let runtime = f.directory.appendingPathComponent(".runtime")
        let relocated = f.directory.appendingPathComponent("retained-runtime")
        try FileManager.default.moveItem(at: runtime, to: relocated)
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: relocated)
      default:
        let config = f.directory.appendingPathComponent("configuration.json")
        let other = f.directory.appendingPathComponent("other.json")
        try FileManager.default.moveItem(at: config, to: other)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: other)
      }
      #expect(throws: VMError.self) {
        try context.readAdmission(currentLaunchGeneration: f.generation)
      }
    }
  }

  @Test func changedStoredNormalIdentityFailsBeforeDisplayAdmission() throws {
    for field in ["id", "guest", "backend", "boot", "architecture"] {
      let f = try RegisteredRfbFixture()
      defer { f.remove() }
      let context = try f.context()
      var changed = f.configuration
      if field == "id" { changed.id = UUID() }
      if field == "guest" { changed.guest = .linux }
      if field == "backend" { changed.backend = .appleVz }
      if field == "boot" { changed.boot = .linuxKernel }
      if field == "architecture" { changed.architecture = .x8664 }
      try f.saveConfiguration(changed)
      #expect(throws: VMError.self) {
        try context.readAdmission(currentLaunchGeneration: f.generation)
      }
    }
  }

  @Test func recoveryInputRetainsAllActualOwnerAndActiveBackendGuards() async throws {
    let f = try RegisteredRfbFixture()
    defer { f.remove() }
    let context = try f.context()
    let intent = try await f.intent()
    for state: UInt8 in [3, 6] {
      #expect(
        !context.allowsCapture(
          status: f.status(state: state), intent: intent,
          writerHeld: true, currentLaunchGeneration: f.generation))
      #expect(
        context.allowsCapture(
          status: f.status(state: state), intent: intent,
          writerHeld: true, currentLaunchGeneration: f.generation, allowRecoveryInput: true))
      for unsafe in [
        f.status(state: state, ownership: 1), f.status(state: state, active: false),
        f.status(state: state, pending: true), f.status(state: state, error: .operationFailed),
      ] {
        #expect(
          !context.allowsCapture(
            status: unsafe, intent: intent,
            writerHeld: true, currentLaunchGeneration: f.generation, allowRecoveryInput: true))
      }
    }
  }

  @Test func captureNeedsCurrentLaunchAndHealthySameOwnerFacts() async throws {
    let f = try RegisteredRfbFixture()
    defer { f.remove() }
    let context = try f.context()
    let current = try await f.intent()
    #expect(
      context.allowsCapture(
        status: f.status(), intent: current, writerHeld: true, currentLaunchGeneration: f.generation
      ))
    for status in [
      f.status(vm: UUID()), f.status(session: UUID()), f.status(state: 4),
      f.status(ownership: 1), f.status(active: false), f.status(pending: true),
      f.status(error: .operationFailed),
    ] {
      #expect(
        !context.allowsCapture(
          status: status, intent: current, writerHeld: true, currentLaunchGeneration: f.generation))
    }
    for intent in [
      nil, try await f.intent(vm: UUID()), try await f.intent(session: UUID()),
      try await f.intent(settled: true),
    ] {
      #expect(
        !context.allowsCapture(
          status: f.status(), intent: intent, writerHeld: true,
          currentLaunchGeneration: f.generation))
    }
    for generation in [nil, UUID()] {
      #expect(
        !context.allowsCapture(
          status: f.status(), intent: current, writerHeld: true, currentLaunchGeneration: generation
        ))
    }
    #expect(
      !context.allowsCapture(
        status: f.status(), intent: current, writerHeld: false,
        currentLaunchGeneration: f.generation))
  }

  @Test func registeredControllerNeverAdoptsLabModesAndStaleGenerationDisablesInput() throws {
    let f = try RegisteredRfbFixture()
    defer { f.remove() }
    let context = try f.context()
    for flag in [
      "--rfb-display-lab", "--windows-installer-display-lab",
      "--windows-network-continuation-display-lab", RfbLabInputPolicy.humanFlag,
      ExternalWindowsHumanInputPolicy.flag,
    ] {
      #expect(throws: VMError.self) {
        try RfbLabSession(
          registeredContext: context, currentLaunchGeneration: { f.generation },
          arguments: ["app", flag])
      }
    }
    let session = try RfbLabSession(
      registeredContext: context, currentLaunchGeneration: { f.generation }, arguments: ["app"])
    #expect(!session.selected && session.canCaptureInput && !session.canControlRuntime)
    #expect(!session.canSelectDisplayConsole)
    let displayTrial = try RfbLabSession(
      registeredContext: context, currentLaunchGeneration: { f.generation },
      displayConsoleSelection: true, arguments: ["app"])
    #expect(displayTrial.canSelectDisplayConsole && !displayTrial.canControlRuntime)
    let stale = try RfbLabSession(
      registeredContext: context, currentLaunchGeneration: { nil }, arguments: ["app"])
    #expect(!stale.canCaptureInput && !stale.canControlRuntime)
    let connection = UUID()
    let epoch = UUID()
    let capture = UUID()
    #expect(
      context.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connection,
        requestedEpoch: epoch, clientEpoch: epoch, frameEpoch: epoch, requestedCapture: capture,
        currentCapture: capture, currentLaunchGeneration: f.generation))
    #expect(
      !context.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connection,
        requestedEpoch: epoch, clientEpoch: epoch, frameEpoch: epoch, requestedCapture: capture,
        currentCapture: capture, currentLaunchGeneration: nil))
    #expect(
      !context.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connection,
        requestedEpoch: epoch, clientEpoch: UUID(), frameEpoch: epoch, requestedCapture: capture,
        currentCapture: capture, currentLaunchGeneration: f.generation))
  }
}
