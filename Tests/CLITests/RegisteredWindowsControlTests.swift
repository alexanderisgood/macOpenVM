// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMCLI

private actor ControlPeer {
  let state: UInt8, ownership: UInt8, active: Bool, pending: Bool, error: WorkerReplyCode
  let refusal: WorkerReplyCode?
  private var requests: [WorkerRequest] = []
  init(
    state: UInt8 = 2, ownership: UInt8 = 0, active: Bool = true, pending: Bool = false,
    error: WorkerReplyCode = .none, refusal: WorkerReplyCode? = nil
  ) {
    self.state = state
    self.ownership = ownership
    self.active = active
    self.pending = pending
    self.error = error
    self.refusal = refusal
  }
  func handle(_ request: WorkerRequest) -> WorkerResponse {
    requests.append(request)
    return WorkerResponse(
      vmID: request.vmID, sessionID: request.sessionID, requestID: request.requestID,
      revision: request.command == .status ? 17 : 18,
      state: state, ownership: ownership, backendActive: active, operationPending: pending,
      error: request.command == .status ? error : (refusal ?? .none))
  }
  func observed() -> [WorkerRequest] { requests }
}

/// Actual private files, real kernel writer and local IPC only; no child or VM.
@MainActor private final class ControlFixture {
  let directory: URL, run: URL, endpoints: URL, configuration: VMConfiguration, session: UUID
  let server: WorkerIPCServer, peer: ControlPeer
  private var lock: VMLock?
  private var permit: RuntimeSessionPermit?
  init(peer: ControlPeer = ControlPeer()) async throws {
    let files = VMFiles()
    directory = URL(fileURLWithPath: "/private/tmp/mvo-control-test-\(UUID().uuidString)")
    try await files.createDirectory(directory)
    let runtime = directory.appendingPathComponent(".runtime")
    try await files.createDirectory(runtime)
    run = runtime.appendingPathComponent(
      "run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    try await files.createDirectory(run)
    endpoints = URL(
      fileURLWithPath: "/private/tmp/mvo-qemu-"
        + run.lastPathComponent.dropFirst(4).prefix(16))
    try await files.createDirectory(endpoints)
    configuration = VMConfiguration(
      name: "Control fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    try await files.writeNewMetadata(
      try ConfigurationCodec.encode(configuration),
      at: directory.appendingPathComponent("configuration.json"))
    let writer = try VMLock(directory: directory, expectedVMID: configuration.id)
    let admitted = try await files.beginRuntimeSession(
      in: directory, forVMID: configuration.id, lock: writer)
    lock = writer
    permit = admitted
    session = admitted.sessionID
    self.peer = peer
    let route = RegisteredWorkerRoute(
      schemaVersion: 1, scope: "macopenvm-registered-qemu-worker-route",
      vmID: configuration.id, sessionID: session,
      socket: endpoints.appendingPathComponent("worker.sock").path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try await files.writeNewMetadata(
      try encoder.encode(route), at: run.appendingPathComponent("worker.json"))
    server = WorkerIPCServer(socketURL: endpoints.appendingPathComponent("worker.sock")) {
      await peer.handle($0)
    }
    try await server.start()
  }
  func request(_ action: RegisteredWindowsControl.Action, session expected: UUID? = nil) throws
    -> RegisteredWindowsControl.Request
  {
    try .init(
      action: action, directory: directory, runDirectory: run, expectedSession: expected ?? session,
      confirmDataLoss: action == .forceStop ? "yes" : nil)
  }
  func releaseWriter() {
    permit = nil
    lock = nil
  }
  func close() async {
    await server.close()
    releaseWriter()
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: endpoints)
  }
}

@Suite(.serialized) @MainActor struct RegisteredWindowsControlTests {
  @Test func forceConsentAndURLAdmissionPrecedeAnyFileOrSocketAccess() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/mvo-control-absent-\(UUID().uuidString)")
    let run = directory.appendingPathComponent(".runtime/run-" + String(repeating: "a", count: 32))
    for confirmation in [nil, "no", "YES"] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsControl.Request(
          action: .forceStop, directory: directory, runDirectory: run, expectedSession: UUID(),
          confirmDataLoss: confirmation)
      }
    }
    for action in RegisteredWindowsControl.Action.allCases where action != .forceStop {
      #expect(throws: VMError.self) {
        try RegisteredWindowsControl.Request(
          action: action, directory: directory, runDirectory: run, expectedSession: UUID(),
          confirmDataLoss: "yes")
      }
    }
    _ = try RegisteredWindowsControl.Request(
      action: .forceStop, directory: directory, runDirectory: run, expectedSession: UUID(),
      confirmDataLoss: "yes")
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    for path in ["file:///private/tmp/encoded%00", "file:///private/tmp/encoded%2Fcomponent"] {
      let encoded = try #require(URL(string: path))
      #expect(throws: VMError.self) {
        try RegisteredWindowsControl.Request(
          action: .status, directory: encoded, runDirectory: run, expectedSession: UUID())
      }
    }
  }

  @Test func onlyCanonicalRegisteredFiveFieldRoutesAreAccepted() throws {
    let vmID = UUID()
    let session = UUID()
    let run = URL(
      fileURLWithPath: "/private/tmp/route-fixture/.runtime/run-0123456789abcdef0000000000000000")
    let route = RegisteredWorkerRoute(
      schemaVersion: 1, scope: "macopenvm-registered-qemu-worker-route", vmID: vmID,
      sessionID: session,
      socket: "/private/tmp/mvo-qemu-0123456789abcdef/worker.sock")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(route)
    #expect(
      try RegisteredWindowsControl.decodeRoute(
        bytes, vmID: vmID, sessionID: session, expectedRun: run
      )
      .lastPathComponent == "worker.sock")
    let text = String(decoding: bytes, as: UTF8.self)
    let malformed = [
      text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
      text.replacingOccurrences(of: "\"scope\"", with: "\"sc\\u006fpe\""),
      String(text.dropLast()) + ",\"schemaVersion\":1}",
      String(text.dropLast()) + ",\"PID\":123}",
      text.replacingOccurrences(
        of: "macopenvm-registered-qemu-worker-route", with: "original-diskless-worker-route"),
      text.replacingOccurrences(of: "worker.sock", with: "qmp.sock"),
      text.replacingOccurrences(of: "0123456789abcdef", with: "fedcba9876543210"),
    ]
    for value in malformed {
      #expect(throws: (any Error).self) {
        try RegisteredWindowsControl.decodeRoute(
          Data(value.utf8), vmID: vmID, sessionID: session, expectedRun: run)
      }
    }
    #expect(throws: VMError.self) {
      try RegisteredWindowsControl.decodeRoute(
        bytes, vmID: UUID(), sessionID: session, expectedRun: run)
    }
    #expect(throws: VMError.self) {
      try RegisteredWindowsControl.decodeRoute(
        bytes, vmID: vmID, sessionID: UUID(), expectedRun: run)
    }
  }

  @Test(arguments: [RegisteredWindowsControl.Action.pause, .resume, .stop, .forceStop])
  func freshStatusAndCommandShareOneClientAndAckDoesNotSettle(
    _ action: RegisteredWindowsControl.Action
  ) async throws {
    let f = try await ControlFixture(peer: ControlPeer(state: action == .resume ? 4 : 2))
    do {
      let before = try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json"))
      let result = try await RegisteredWindowsControl.run(f.request(action))
      #expect(result.requestAcknowledged && result.revision == 18 && result.backendActive)
      let requests = await f.peer.observed()
      #expect(requests.map(\.command) == [.status, action.command])
      #expect(requests.map(\.requestID) == [1, 2])
      #expect(requests.last?.observedRevision == 17)
      #expect(
        try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json")) == before)
      #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
      await f.close()
    } catch {
      await f.close()
      throw error
    }
  }

  @Test func statusReportsRecoveryWhileBusyRecoveryAndPausedNormalStopRefuseMutation() async throws
  {
    for peer in [
      ControlPeer(pending: true),
      ControlPeer(state: 10, ownership: 3, active: false, error: .recovery), ControlPeer(state: 4),
    ] {
      let f = try await ControlFixture(peer: peer)
      do {
        let status = try await RegisteredWindowsControl.run(f.request(.status))
        #expect(!status.requestAcknowledged)
        await #expect(throws: VMError.self) {
          try await RegisteredWindowsControl.run(f.request(.stop))
        }
        #expect(await peer.observed().map(\.command) == [.status, .status])
        await f.close()
      } catch {
        await f.close()
        throw error
      }
    }
  }

  @Test func staleServerRefusalIsReturnedWithoutReplayAndActiveFailureAllowsExplicitForce()
    async throws
  {
    let f = try await ControlFixture(peer: ControlPeer(refusal: .stale))
    do {
      let result = try await RegisteredWindowsControl.run(f.request(.stop))
      #expect(!result.requestAcknowledged && result.error == WorkerReplyCode.stale.rawValue)
      #expect(await f.peer.observed().count == 2)
      await f.close()
    } catch {
      await f.close()
      throw error
    }
    let failed = try await ControlFixture(peer: ControlPeer(state: 10, error: .operationFailed))
    do {
      let result = try await RegisteredWindowsControl.run(failed.request(.forceStop))
      #expect(result.requestAcknowledged)
      #expect(await failed.peer.observed().map(\.command) == [.status, .forceStop])
      await failed.close()
    } catch {
      await failed.close()
      throw error
    }
  }

  @Test func wrongSessionAbsentWriterAndSymlinkRunNeverReachThePeer() async throws {
    let f = try await ControlFixture()
    do {
      await #expect(throws: VMError.self) {
        try await RegisteredWindowsControl.run(f.request(.status, session: UUID()))
      }
      let alias = f.run.deletingLastPathComponent().appendingPathComponent(
        "run-" + String(repeating: "b", count: 32))
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.run)
      let request = try RegisteredWindowsControl.Request(
        action: .status, directory: f.directory, runDirectory: alias, expectedSession: f.session)
      await #expect(throws: VMError.self) { try await RegisteredWindowsControl.run(request) }
      f.releaseWriter()
      await #expect(throws: VMError.self) {
        try await RegisteredWindowsControl.run(f.request(.status))
      }
      #expect(await f.peer.observed().isEmpty)
      await f.close()
    } catch {
      await f.close()
      throw error
    }
  }
}
