// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMCLI

private actor AgentProbeStatusPeer {
  private var commands: [WorkerCommand] = []
  private var revision: UInt64 = 17
  private var changeAtRequest: Int?
  func handle(_ request: WorkerRequest) -> WorkerResponse {
    commands.append(request.command)
    if commands.count == changeAtRequest { revision += 1 }
    return .init(
      vmID: request.vmID, sessionID: request.sessionID, requestID: request.requestID,
      revision: revision, state: 2, ownership: 0, backendActive: true,
      operationPending: false, error: .none)
  }
  func changeRevision() { revision += 1 }
  func changeRevision(atRequest count: Int) { changeAtRequest = count }
  func observed() -> [WorkerCommand] { commands }
}

/// Original owned Unix peer; no Windows process, VM, guest disk or device.
final class FixedAgentPeer: @unchecked Sendable {
  enum Behavior: Sendable {
    case success, wrongReply, partialReply, trailingReply, stall
  }
  struct Observation: Sendable {
    let received: Data, largestRead: Int, writes: Int, connected: Bool, reachedEOF: Bool
  }
  let socketURL: URL
  private let descriptor: Int32
  private let behavior: Behavior
  private let queue = DispatchQueue(label: "local.macOpenVM.test.fixed-agent", qos: .utility)
  private let lock = NSLock()
  private var finished = false
  private var observation = Observation(
    received: Data(), largestRead: 0, writes: 0, connected: false, reachedEOF: false)
  private var waiters: [CheckedContinuation<Observation, Never>] = []

  init(socketURL: URL, behavior: Behavior) throws {
    self.socketURL = socketURL
    self.behavior = behavior
    descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(socketURL.path, 0o600) == 0,
      fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0, Darwin.listen(descriptor, 1) == 0
    else {
      Darwin.close(descriptor)
      throw CocoaError(.fileWriteUnknown)
    }
  }

  func start() { queue.async { self.serve() } }

  func finish() async -> Observation {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if finished {
          continuation.resume(returning: observation)
        } else {
          waiters.append(continuation)
        }
      }
    }
  }

  private func ready(_ fd: Int32, _ events: Int16, deadline: ContinuousClock.Instant) -> Bool {
    while ContinuousClock.now < deadline {
      var item = pollfd(fd: fd, events: events, revents: 0)
      let result = Darwin.poll(&item, 1, 20)
      if result < 0 {
        if errno == EINTR { continue }
        return false
      }
      if result > 0 {
        return item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0
      }
    }
    return false
  }

  private func serve() {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var bytes = Data()
    var largest = 0
    var writes = 0
    var connected = false
    var eof = false
    var client: Int32 = -1
    defer {
      if client >= 0 { Darwin.close(client) }
      Darwin.close(descriptor)
      let value = Observation(
        received: bytes, largestRead: largest, writes: writes, connected: connected,
        reachedEOF: eof)
      let pending = lock.withLock {
        observation = value
        finished = true
        let pending = waiters
        waiters = []
        return pending
      }
      for waiter in pending { waiter.resume(returning: value) }
    }
    guard ready(descriptor, Int16(POLLIN), deadline: deadline) else { return }
    client = Darwin.accept(descriptor, nil, nil)
    guard client >= 0 else { return }
    connected = true
    guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { return }
    var noSignal: Int32 = 1
    guard
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else { return }
    while bytes.count < RegisteredWindowsAgentProbeLab.challenge.count {
      guard ready(client, Int16(POLLIN), deadline: deadline) else { return }
      var fragment = [UInt8](repeating: 0, count: 3)
      let count = fragment.withUnsafeMutableBytes {
        Darwin.recv(client, $0.baseAddress, $0.count, 0)
      }
      if count == 0 {
        eof = true
        return
      }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return
      }
      largest = max(largest, count)
      bytes.append(contentsOf: fragment.prefix(count))
    }
    guard bytes == RegisteredWindowsAgentProbeLab.challenge else { return }
    if behavior == .stall {
      while ready(client, Int16(POLLIN), deadline: deadline) {
        var byte: UInt8 = 0
        let count = Darwin.recv(client, &byte, 1, 0)
        if count == 0 {
          eof = true
          return
        }
        if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return
      }
      return
    }
    var response = RegisteredWindowsAgentProbeLab.reply
    if behavior == .wrongReply { response[0] ^= 1 }
    if behavior == .partialReply { response = Data(response.prefix(5)) }
    if behavior == .trailingReply { response.append(0xff) }
    var offset = 0
    while offset < response.count {
      guard ready(client, Int16(POLLOUT), deadline: deadline) else { return }
      // Enqueue the final reply byte and extra byte together so this case does
      // not race the host's explicitly available-only trailing check.
      let requested = behavior == .trailingReply ? response.count : min(2, response.count - offset)
      let count = response.withUnsafeBytes {
        Darwin.send(client, $0.baseAddress?.advanced(by: offset), requested, 0)
      }
      if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      guard count > 0 else { return }
      if behavior == .trailingReply, count != requested {
        Issue.record("The owned trailing-reply fixture did not enqueue its complete bounded write.")
        return
      }
      offset += count
      writes += 1
    }
    if behavior == .partialReply { return }
    while ready(client, Int16(POLLIN), deadline: deadline) {
      var byte: UInt8 = 0
      let count = Darwin.recv(client, &byte, 1, 0)
      if count == 0 {
        eof = true
        return
      }
      if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      return
    }
  }
}

@MainActor private final class AgentProbeFixture {
  let directory: URL, run: URL, endpoints: URL, configuration: VMConfiguration, session: UUID
  let server: WorkerIPCServer, peer: AgentProbeStatusPeer, agent: FixedAgentPeer
  let route: RegisteredWindowsAgentProbeLab.Route
  private var lock: VMLock?
  private var permit: RuntimeSessionPermit?

  init(behavior: FixedAgentPeer.Behavior = .success) async throws {
    let files = VMFiles()
    directory = URL(fileURLWithPath: "/private/tmp/mvo-agent-probe-test-\(UUID().uuidString)")
    try await files.createDirectory(directory)
    let runtime = directory.appendingPathComponent(".runtime")
    try await files.createDirectory(runtime)
    run = runtime.appendingPathComponent(
      "run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    try await files.createDirectory(run)
    endpoints = URL(
      fileURLWithPath: "/private/tmp/mvo-qemu-" + run.lastPathComponent.dropFirst(4).prefix(16))
    try await files.createDirectory(endpoints)
    configuration = VMConfiguration(
      name: "Fixed transfer fixture", guest: .windows11, backend: .qemuHVF,
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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try await files.writeNewMetadata(
      try encoder.encode(
        RegisteredWorkerRoute(
          schemaVersion: 1, scope: "macopenvm-registered-qemu-worker-route",
          vmID: configuration.id, sessionID: session,
          socket: endpoints.appendingPathComponent("worker.sock").path)),
      at: run.appendingPathComponent("worker.json"))
    peer = AgentProbeStatusPeer()
    let statusPeer = peer
    server = WorkerIPCServer(socketURL: endpoints.appendingPathComponent("worker.sock")) {
      await statusPeer.handle($0)
    }
    try await server.start()
    agent = try FixedAgentPeer(
      socketURL: endpoints.appendingPathComponent("agent.sock"), behavior: behavior)
    var parent = stat()
    var socket = stat()
    guard lstat(endpoints.path, &parent) == 0, lstat(agent.socketURL.path, &socket) == 0 else {
      throw CocoaError(.fileReadUnknown)
    }
    route = .init(
      schemaVersion: 1, scope: "macopenvm-registered-qemu-agent-route", vmID: configuration.id,
      sessionID: session, controlSocket: endpoints.appendingPathComponent("worker.sock").path,
      agentSocket: agent.socketURL.path, parentDevice: parent.st_dev, parentInode: parent.st_ino,
      socketDevice: socket.st_dev, socketInode: socket.st_ino)
    try await files.writeNewMetadata(
      try encoder.encode(route), at: run.appendingPathComponent("agent.json"))
    agent.start()
  }

  func request(_ action: RegisteredWindowsControl.Action = .status) throws
    -> RegisteredWindowsControl.Request
  {
    try .init(action: action, directory: directory, runDirectory: run, expectedSession: session)
  }

  func releaseWriter() {
    permit = nil
    lock = nil
  }

  func close() async {
    _ = await agent.finish()
    await server.close()
    releaseWriter()
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: endpoints)
  }
}

@Suite(.serialized) @MainActor struct RegisteredWindowsAgentProbeLabTests {
  @Test func lifecycleRejectedBeforeFileOrPeerIO() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp/never-created-probe-\(UUID().uuidString)")
    let request = try RegisteredWindowsControl.Request(
      action: .pause, directory: directory,
      runDirectory: directory.appendingPathComponent(
        ".runtime/run-0123456789abcdef0000000000000000"), expectedSession: UUID())
    await #expect(throws: VMError.self) {
      try await RegisteredWindowsAgentProbeLab.run(request: request)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test func canonicalTenFieldRouteRejectsAlternateShapesAndSessionEndpoints() throws {
    let vm = UUID()
    let session = UUID()
    let directory = URL(fileURLWithPath: "/private/tmp/probe-shape")
    let request = try RegisteredWindowsControl.Request(
      action: .status, directory: directory,
      runDirectory: directory.appendingPathComponent(
        ".runtime/run-0123456789abcdef0000000000000000"), expectedSession: session)
    let route = RegisteredWindowsAgentProbeLab.Route(
      schemaVersion: 1, scope: "macopenvm-registered-qemu-agent-route", vmID: vm,
      sessionID: session, controlSocket: "/private/tmp/mvo-qemu-0123456789abcdef/worker.sock",
      agentSocket: "/private/tmp/mvo-qemu-0123456789abcdef/agent.sock", parentDevice: 1,
      parentInode: 2, socketDevice: 1, socketInode: 3)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(route)
    #expect(
      try RegisteredWindowsAgentProbeLab.decodeRoute(bytes, request: request, vmID: vm).socketInode
        == 3)
    let text = String(decoding: bytes, as: UTF8.self)
    for malformed in [
      text + "\n", String(text.dropLast()) + ",\"extra\":1}",
      String(text.dropLast()) + ",\"schemaVersion\":1}",
      text.replacingOccurrences(of: "\"scope\"", with: "\"sc\\u006fpe\""),
      text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
      text.replacingOccurrences(of: "agent.sock", with: "vnc.sock"),
      text.replacingOccurrences(of: "0123456789abcdef", with: "fedcba9876543210"),
    ] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsAgentProbeLab.decodeRoute(
          Data(malformed.utf8), request: request, vmID: vm)
      }
    }
    #expect(throws: VMError.self) {
      try RegisteredWindowsAgentProbeLab.decodeRoute(bytes, request: request, vmID: UUID())
    }
  }

  @Test(arguments: [mode_t(0o600), mode_t(0o700)])
  func realFragmentedExchangeHasOnlyStatusRequestsAndPreservesWriterIntent(_ mode: mode_t)
    async throws
  {
    let f = try await AgentProbeFixture()
    do {
      #expect(chmod(f.agent.socketURL.path, mode) == 0)
      let intent = try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json"))
      let result = try await RegisteredWindowsAgentProbeLab.run(request: f.request())
      let observed = await f.agent.finish()
      #expect(result.completed && result.endedAt == "complete")
      #expect(result.sentBytes == RegisteredWindowsAgentProbeLab.challenge.count)
      #expect(result.receivedBytes == RegisteredWindowsAgentProbeLab.reply.count)
      #expect(result.writeFragments >= 6 && result.readFragments >= 6)
      #expect(observed.connected && observed.received == RegisteredWindowsAgentProbeLab.challenge)
      #expect(observed.largestRead <= 3 && observed.writes >= 18 && observed.reachedEOF)
      #expect(await f.peer.observed().allSatisfy { $0 == .status })
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
      #expect(
        try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json")) == intent)
      let encoded = try JSONEncoder().encode(result)
      let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      #expect(
        Set(object.keys)
          == Set([
            "scope", "vmID", "sessionID", "sentBytes", "receivedBytes", "writeFragments",
            "readFragments", "completed", "endedAt", "authenticated", "guestHealthVerified",
          ]))
      #expect(!String(decoding: encoded, as: UTF8.self).contains("challenge"))
      #expect(!result.authenticated && !result.guestHealthVerified)
      await f.close()
    } catch {
      await f.close()
      throw error
    }
  }

  @Test(arguments: [FixedAgentPeer.Behavior.wrongReply, .partialReply, .trailingReply])
  func wrongPartialAndTrailingReplyCloseWithoutReconnect(_ behavior: FixedAgentPeer.Behavior)
    async throws
  {
    let f = try await AgentProbeFixture(behavior: behavior)
    do {
      let result = try await RegisteredWindowsAgentProbeLab.run(request: f.request())
      #expect(!result.completed)
      #expect(result.sentBytes == RegisteredWindowsAgentProbeLab.challenge.count)
      #expect(result.receivedBytes <= RegisteredWindowsAgentProbeLab.reply.count)
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
      await f.close()
    } catch {
      await f.close()
      throw error
    }
  }

  @Test func cancellationClosesOnlyClientAndPreservesOwner() async throws {
    let f = try await AgentProbeFixture(behavior: .stall)
    do {
      let request = try f.request()
      let task = Task { try await RegisteredWindowsAgentProbeLab.run(request: request) }
      try await Task.sleep(for: .milliseconds(150))
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      let observed = await f.agent.finish()
      #expect(observed.connected && observed.reachedEOF)
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
      #expect(await f.peer.observed().allSatisfy { $0 == .status })
      await f.close()
    } catch {
      await f.close()
      throw error
    }
  }

  @Test func socketIdentityAndReleasedWriterRejectBeforeAnyPublicChallenge() async throws {
    for release in [false, true] {
      let f = try await AgentProbeFixture()
      do {
        if release { f.releaseWriter() } else { #expect(chmod(f.agent.socketURL.path, 0o660) == 0) }
        if release {
          await #expect(throws: VMError.self) {
            try await RegisteredWindowsAgentProbeLab.run(request: f.request())
          }
        } else {
          let result = try await RegisteredWindowsAgentProbeLab.run(request: f.request())
          #expect(!result.completed && result.sentBytes == 0 && result.endedAt == "connect")
        }
        let observed = await f.agent.finish()
        #expect(!observed.connected && observed.received.isEmpty)
        await f.close()
      } catch {
        await f.close()
        throw error
      }
    }
  }

  @Test func workerRevisionChangeStopsBeforeTheNextFragmentWithoutReplay() async throws {
    let f = try await AgentProbeFixture()
    do {
      // Initial status, pre-connect status and first-fragment status remain
      // healthy. The fourth request changes the revision before fragment two.
      await f.peer.changeRevision(atRequest: 4)
      let result = try await RegisteredWindowsAgentProbeLab.run(request: f.request())
      #expect(!result.completed && result.endedAt == "challenge")
      #expect(result.sentBytes == 7 && result.writeFragments == 1 && result.receivedBytes == 0)
      let observed = await f.agent.finish()
      #expect(observed.received == Data(RegisteredWindowsAgentProbeLab.challenge.prefix(7)))
      #expect(observed.reachedEOF)
      #expect(await f.peer.observed() == [.status, .status, .status, .status])
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
      await f.close()
    } catch {
      await f.close()
      throw error
    }
  }

  @Test func pinnedEndpointRejectsReplacementAndExpiredAdmission() async throws {
    let f = try await AgentProbeFixture()
    var changed = f.route
    changed = .init(
      schemaVersion: changed.schemaVersion, scope: changed.scope, vmID: changed.vmID,
      sessionID: changed.sessionID, controlSocket: changed.controlSocket,
      agentSocket: changed.agentSocket, parentDevice: changed.parentDevice,
      parentInode: changed.parentInode, socketDevice: changed.socketDevice,
      socketInode: changed.socketInode + 1)
    for (route, deadline) in [
      (changed, ContinuousClock.now.advanced(by: .seconds(1))),
      (f.route, ContinuousClock.now.advanced(by: .seconds(-1))),
    ] {
      let transport = RegisteredWindowsAgentProbeLab.Transport(
        route: route, cancelled: .init(), deadline: deadline)
      await #expect(throws: VMError.self) { try await transport.perform { try $0.connect() } }
      let counts = await transport.countsAndClose()
      #expect(counts.sent == 0 && counts.received == 0)
    }
    await f.close()
  }
}
