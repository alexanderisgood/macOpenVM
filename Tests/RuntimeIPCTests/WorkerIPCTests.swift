// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import RuntimeIPC
import Testing

private let wireVM = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
private let wireSession = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!

private func response(_ request: WorkerRequest, revision: UInt64 = 7) -> WorkerResponse {
  WorkerResponse(
    vmID: request.vmID, sessionID: request.sessionID, requestID: request.requestID,
    revision: revision, state: 3, ownership: 1, backendActive: true,
    operationPending: false, error: .none)
}

private struct SocketFixture {
  let directory: URL
  var socket: URL { directory.appendingPathComponent("worker.sock") }

  init() throws {
    directory = URL(fileURLWithPath: "/private/tmp/mvo-ipc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func withServer(
  handler: @escaping @Sendable (WorkerRequest) async -> WorkerResponse,
  body: @escaping @Sendable (WorkerIPCServer, URL) async throws -> Void
) async throws {
  let fixture = try SocketFixture()
  defer { fixture.remove() }
  let server = WorkerIPCServer(socketURL: fixture.socket, handler: handler)
  do {
    try await server.start()
    try await body(server, fixture.socket)
    await server.close()
  } catch {
    await server.close()
    throw error
  }
}

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
  let deadline = ContinuousClock().now.advanced(by: .seconds(2))
  while !(await predicate()) {
    if ContinuousClock().now >= deadline { throw WorkerIPCError.deadlineExceeded }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private actor CommandProbe {
  var commands: [WorkerCommand] = []
  var entered = false
  var completed = false
  private var release: CheckedContinuation<Void, Never>?
  private var released = false

  func handle(_ request: WorkerRequest) async -> WorkerResponse {
    commands.append(request.command)
    if request.command == .pause {
      entered = true
      if !released { await withCheckedContinuation { release = $0 } }
      completed = true
    }
    return response(request)
  }
  func allowCompletion() {
    released = true
    release?.resume()
    release = nil
  }
}

/// Blocking socket fixtures must not occupy Swift's cooperative executor: the
/// client/server tasks they await need that executor even on a one-core runner.
private func rawIO<T: Sendable>(
  _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue(label: "local.macOpenVM.test.raw-ipc", qos: .userInitiated).async {
      do { continuation.resume(returning: try operation()) } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

/// Independent wire fixture. Only its queued script touches/actually closes
/// descriptors; stop merely shuts down published descriptors under the lock.
private final class RawPeer: @unchecked Sendable {
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var connection: Int32 = -1
  private var stopping = false
  private var task: Task<Void, Error>?

  init(listeningAt url: URL, script: @escaping @Sendable (Int32) throws -> Void) throws {
    let value = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard value >= 0 else { throw WorkerIPCError.posix(errno) }
    listener = value
    var address = rawAddress(url)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(url.path, 0o600) == 0, Darwin.listen(value, 8) == 0 else {
      let failure = errno
      Darwin.close(value)
      listener = -1
      throw WorkerIPCError.posix(failure)
    }
    task = Task {
      try await rawIO {
        defer { self.finish() }
        var item = pollfd(fd: value, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&item, 1, 2_000) > 0 else { throw WorkerIPCError.deadlineExceeded }
        let accepted = Darwin.accept(value, nil, nil)
        guard accepted >= 0 else { throw WorkerIPCError.posix(errno) }
        try self.publish(accepted)
        try configureRaw(accepted)
        try script(accepted)
      }
    }
  }

  private func publish(_ value: Int32) throws {
    lock.lock()
    if stopping {
      lock.unlock()
      Darwin.close(value)
      throw WorkerIPCError.closed
    }
    connection = value
    lock.unlock()
  }

  private func finish() {
    lock.lock()
    let stream = connection
    let server = listener
    connection = -1
    listener = -1
    lock.unlock()
    if stream >= 0 { Darwin.close(stream) }
    if server >= 0 { Darwin.close(server) }
  }

  func wait() async throws { try await task?.value }
  func stop() async {
    lock.withLock {
      stopping = true
      if listener >= 0 { _ = Darwin.shutdown(listener, SHUT_RDWR) }
      if connection >= 0 { _ = Darwin.shutdown(connection, SHUT_RDWR) }
    }
    _ = try? await task?.value
  }
}

private func rawAddress(_ url: URL) -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
  return address
}

private func configureRaw(_ fd: Int32) throws {
  let flags = fcntl(fd, F_GETFL)
  guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
    throw WorkerIPCError.posix(errno)
  }
  var duration = timeval(tv_sec: 2, tv_usec: 0)
  var noSignal: Int32 = 1
  guard
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &duration, socklen_t(MemoryLayout<timeval>.size)) == 0,
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &duration, socklen_t(MemoryLayout<timeval>.size)) == 0,
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
  else { throw WorkerIPCError.posix(errno) }
}

private func rawConnect(_ url: URL) throws -> Int32 {
  let value = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard value >= 0 else { throw WorkerIPCError.posix(errno) }
  do {
    try configureRaw(value)
    var address = rawAddress(url)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw WorkerIPCError.posix(errno) }
    return value
  } catch {
    Darwin.close(value)
    throw error
  }
}

private func rawWrite(_ fd: Int32, _ bytes: [UInt8]) throws {
  var offset = 0
  while offset < bytes.count {
    let count = bytes.withUnsafeBytes {
      Darwin.send(fd, $0.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
    }
    guard count > 0 else { throw WorkerIPCError.disconnected }
    offset += count
  }
}

private func rawRead(_ fd: Int32, count: Int) throws -> [UInt8] {
  var result = [UInt8](repeating: 0, count: count)
  var offset = 0
  while offset < count {
    let received = result.withUnsafeMutableBytes {
      Darwin.recv(fd, $0.baseAddress?.advanced(by: offset), count - offset, 0)
    }
    if received > 0 {
      offset += received
      continue
    }
    if received == 0 { throw WorkerIPCError.disconnected }
    if errno == EINTR { continue }
    if errno == EAGAIN || errno == EWOULDBLOCK { throw WorkerIPCError.deadlineExceeded }
    if errno == ECONNRESET || errno == ENOTCONN { throw WorkerIPCError.disconnected }
    throw WorkerIPCError.posix(errno)
  }
  return result
}

// Literal, independent version-1 status fixtures, including big-endian prefix/IDs.
private let statusFrame: [UInt8] =
  [0, 0, 0, 56, 1, 1, 0, 0]
  + [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255]
  + [255, 238, 221, 204, 187, 170, 153, 136, 119, 102, 85, 68, 51, 34, 17, 0]
  + [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
private let statusReply: [UInt8] =
  [0, 0, 0, 64, 1, 2, 0, 0]
  + [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255]
  + [255, 238, 221, 204, 187, 170, 153, 136, 119, 102, 85, 68, 51, 34, 17, 0]
  + [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7, 3, 1, 1, 0, 0]
  + [0, 0, 0, 0, 0, 0, 0]

@Suite("Private worker IPC")
struct WorkerIPCTests {
  @Test func fixedWireFixturesAndStrictSchema() throws {
    let request = WorkerRequest(
      vmID: wireVM, sessionID: wireSession, requestID: 1, observedRevision: 0, command: .status)
    #expect(try Array(WorkerFrameCodec.encode(request: request)) == statusFrame)
    #expect(try WorkerFrameCodec.decodeRequest(Data(statusFrame.dropFirst(4))) == request)
    #expect(try Array(WorkerFrameCodec.encode(response: response(request))) == statusReply)
    #expect(
      try WorkerFrameCodec.decodeResponse(Data(statusReply.dropFirst(4))) == response(request))
    for (offset, value) in [(0, 2), (1, 2), (2, 1), (43, 0), (52, 7), (55, 1)] {
      var malformed = Array(statusFrame.dropFirst(4))
      malformed[offset] = UInt8(value)
      #expect(throws: WorkerIPCError.malformedFrame) {
        try WorkerFrameCodec.decodeRequest(Data(malformed))
      }
    }
    for (offset, value) in [
      (0, 2), (1, 1), (3, 1), (43, 0), (52, 11), (53, 4),
      (54, 2), (55, 2), (56, 6), (63, 1),
    ] {
      var malformed = Array(statusReply.dropFirst(4))
      malformed[offset] = UInt8(value)
      #expect(throws: WorkerIPCError.malformedFrame) {
        try WorkerFrameCodec.decodeResponse(Data(malformed))
      }
    }
    #expect(throws: WorkerIPCError.limitExceeded) {
      try WorkerFrameCodec.decodeRequest(Data(repeating: 0, count: 129))
    }
    #expect(throws: WorkerIPCError.limitExceeded) {
      try WorkerFrameCodec.decodeResponse(Data(repeating: 0, count: 129))
    }
    #expect(throws: WorkerIPCError.malformedFrame) {
      try WorkerFrameCodec.decodeRequest(Data(statusFrame.dropFirst(5)))
    }
  }

  @Test func normalStopOpcodePreservesOriginalWireCommandsAndReservedBytes() throws {
    #expect(WorkerCommand.status.rawValue == 0 && WorkerCommand.pause.rawValue == 1)
    #expect(WorkerCommand.resume.rawValue == 2 && WorkerCommand.forceStop.rawValue == 3)
    let request = WorkerRequest(
      vmID: wireVM, sessionID: wireSession, requestID: 1, observedRevision: 0, command: .stop)
    var expected = statusFrame
    expected[56] = 4
    #expect(try Array(WorkerFrameCodec.encode(request: request)) == expected)
    #expect(try WorkerFrameCodec.decodeRequest(Data(expected.dropFirst(4))) == request)
    for offset in 57...59 {
      var invalid = expected
      invalid[offset] = 1
      #expect(throws: WorkerIPCError.malformedFrame) {
        try WorkerFrameCodec.decodeRequest(Data(invalid.dropFirst(4)))
      }
    }
  }

  @Test(arguments: [WorkerCommand.relativeMouse, .absoluteMouse])
  func pointerSelectionKeepsFixedFrameAndReservedBytes(_ command: WorkerCommand) throws {
    let request = WorkerRequest(
      vmID: wireVM, sessionID: wireSession, requestID: 1,
      observedRevision: 7, command: command)
    let frame = try WorkerFrameCodec.encode(request: request)
    #expect(frame.count == statusFrame.count)
    #expect(frame[56] == command.rawValue && frame.suffix(3) == Data([0, 0, 0]))
    #expect(try WorkerFrameCodec.decodeRequest(Data(frame.dropFirst(4))) == request)
  }

  @Test func statusAdmissionAndConnectionBudget() async throws {
    let probe = CommandProbe()
    try await withServer {
      await probe.handle($0)
    } body: { server, url in
      let client = WorkerIPCClient(socketURL: url, vmID: wireVM, sessionID: wireSession)
      try await client.connect()
      await #expect(throws: WorkerIPCError.statusRequired) { try await client.request(.resume) }
      let status = try await client.request(.status)
      #expect(status.revision == 7)
      await #expect(throws: WorkerIPCError.statusRequired) {
        try await client.request(.resume, observedRevision: 6)
      }
      _ = try await client.request(.resume, observedRevision: status.revision)
      await #expect(throws: WorkerIPCError.statusRequired) {
        try await client.request(.resume, observedRevision: 7)
      }
      for _ in 0..<30 { _ = try await client.request(.status) }
      await #expect(throws: WorkerIPCError.limitExceeded) { try await client.request(.status) }
      #expect(await probe.commands.count == 32)
      await client.close()
      await server.finishWhenIdle()
    }
  }

  @Test func fragmentedReplyAndSemanticFailureRemainUsable() async throws {
    let fixture = try SocketFixture()
    defer { fixture.remove() }
    let peer = try RawPeer(listeningAt: fixture.socket) { fd in
      guard try rawRead(fd, count: 60) == statusFrame else { throw WorkerIPCError.malformedFrame }
      for byte in statusReply { try rawWrite(fd, [byte]) }
      let second = try rawRead(fd, count: 60)
      guard second[47] == 2, second[56] == 2 else { throw WorkerIPCError.malformedFrame }
      var rejected = statusReply
      rejected[47] = 2
      rejected[60] = 4  // operationFailed
      try rawWrite(fd, rejected)
      let third = try rawRead(fd, count: 60)
      guard third[47] == 3, third[56] == 0 else { throw WorkerIPCError.malformedFrame }
      var nextStatus = statusReply
      nextStatus[47] = 3
      try rawWrite(fd, nextStatus)
    }
    let client = WorkerIPCClient(socketURL: fixture.socket, vmID: wireVM, sessionID: wireSession)
    do {
      try await client.connect()
      #expect(try await client.request(.status).revision == 7)
      #expect(try await client.request(.resume, observedRevision: 7).error == .operationFailed)
      #expect(try await client.request(.status).error == .none)
      await client.close()
      try await peer.wait()
    } catch {
      await client.close()
      await peer.stop()
      throw error
    }
  }

  @Test func failedStatusStillAdmitsExplicitRecovery() async throws {
    let probe = CommandProbe()
    try await withServer { request in
      _ = await probe.handle(request)
      let value = response(request)
      return WorkerResponse(
        vmID: value.vmID, sessionID: value.sessionID, requestID: value.requestID,
        revision: value.revision, state: value.state, ownership: value.ownership,
        backendActive: true, operationPending: false,
        error: request.command == .status ? .operationFailed : .none)
    } body: { _, url in
      let client = WorkerIPCClient(socketURL: url, vmID: wireVM, sessionID: wireSession)
      try await client.connect()
      let status = try await client.request(.status)
      #expect(status.error == .operationFailed)
      #expect(
        try await client.request(.forceStop, observedRevision: status.revision).error == .none)
      #expect(await probe.commands == [.status, .forceStop])
      await client.close()
    }
  }

  @Test func normalStopUsesFreshStatusAndNeverReplaysOnSameConnection() async throws {
    let probe = CommandProbe()
    try await withServer { request in
      await probe.handle(request)
    } body: { _, url in
      let client = WorkerIPCClient(socketURL: url, vmID: wireVM, sessionID: wireSession)
      try await client.connect()
      do {
        await #expect(throws: WorkerIPCError.statusRequired) {
          try await client.request(.stop, observedRevision: 7)
        }
        #expect(await probe.commands.isEmpty)
        let status = try await client.request(.status)
        #expect(try await client.request(.stop, observedRevision: status.revision).error == .none)
        await #expect(throws: WorkerIPCError.statusRequired) {
          try await client.request(.stop, observedRevision: status.revision)
        }
        #expect(await probe.commands == [.status, .stop])
        await client.close()
      } catch {
        await client.close()
        throw error
      }
    }
  }

  @Test(arguments: ["wrongID", "oversize", "reserved", "deadline"])
  func invalidOrLateRepliesPoisonOnlyConnection(_ mode: String) async throws {
    let fixture = try SocketFixture()
    defer { fixture.remove() }
    let peer = try RawPeer(listeningAt: fixture.socket) { fd in
      _ = try rawRead(fd, count: 60)
      var bytes = statusReply
      switch mode {
      case "wrongID": bytes[47] = 2
      case "reserved": bytes[67] = 1
      case "oversize": bytes = [0, 0, 0, 129]
      default:
        _ = Darwin.poll(nil, 0, 300)
        return
      }
      try rawWrite(fd, bytes)
    }
    let client = WorkerIPCClient(
      socketURL: fixture.socket, vmID: wireVM, sessionID: wireSession,
      timeout: .milliseconds(150))
    do {
      try await client.connect()
      let error: WorkerIPCError =
        switch mode {
        case "wrongID": .unexpectedReply
        case "oversize": .limitExceeded
        case "reserved": .malformedFrame
        default: .deadlineExceeded
        }
      await #expect(throws: error) { try await client.request(.status) }
      await #expect(throws: WorkerIPCError.closed) { try await client.request(.status) }
      await client.close()
      try await peer.wait()
    } catch {
      await client.close()
      await peer.stop()
      throw error
    }
  }

  @Test(arguments: [true, false])
  func acceptedOperationOutlivesClientCancellationOrClose(_ cancel: Bool) async throws {
    let probe = CommandProbe()
    do {
      try await withServer {
        await probe.handle($0)
      } body: { _, url in
        let client = WorkerIPCClient(socketURL: url, vmID: wireVM, sessionID: wireSession)
        try await client.connect()
        _ = try await client.request(.status)
        let operation = Task { try await client.request(.pause, observedRevision: 7) }
        try await eventually { await probe.entered }
        if cancel { operation.cancel() } else { await client.close() }
        _ = try? await operation.value
        #expect(await !probe.completed)
        await probe.allowCompletion()
        try await eventually { await probe.completed }
        let reconnected = WorkerIPCClient(socketURL: url, vmID: wireVM, sessionID: wireSession)
        try await reconnected.connect()
        await #expect(throws: WorkerIPCError.statusRequired) {
          try await reconnected.request(.forceStop, observedRevision: 7)
        }
        _ = try await reconnected.request(.status)
        #expect(await probe.commands == [.status, .pause, .status])
        await reconnected.close()
        await client.close()
      }
    } catch {
      await probe.allowCompletion()
      throw error
    }
  }

  @Test func serverRejectsOrderingWithoutInvokingHandler() async throws {
    let probe = CommandProbe()
    try await withServer {
      await probe.handle($0)
    } body: { _, url in
      let mutationFirstRead = try await rawIO {
        let fd = try rawConnect(url)
        defer { Darwin.close(fd) }
        var mutationFirst = statusFrame
        mutationFirst[56] = 3
        try rawWrite(fd, mutationFirst)
        return Result { try rawRead(fd, count: 1) }
      }
      #expect(throws: WorkerIPCError.disconnected) { try mutationFirstRead.get() }
      #expect(await probe.commands.isEmpty)
      let repeatedIDRead = try await rawIO {
        let fd = try rawConnect(url)
        defer { Darwin.close(fd) }
        try rawWrite(fd, statusFrame)
        _ = try rawRead(fd, count: 68)
        try rawWrite(fd, statusFrame)  // repeated ID, not another operation
        return Result { try rawRead(fd, count: 1) }
      }
      #expect(throws: WorkerIPCError.disconnected) { try repeatedIDRead.get() }
      #expect(await probe.commands == [.status])
    }
  }

  @Test func eightClientsBoundAcceptedHandlerCustody() async throws {
    let probe = CommandProbe()
    try await withServer {
      await probe.handle($0)
    } body: { _, url in
      let excessRead = try await rawIO {
        var sockets: [Int32] = []
        defer { for fd in sockets { Darwin.close(fd) } }
        for _ in 0..<8 {
          let fd = try rawConnect(url)
          sockets.append(fd)
          try rawWrite(fd, statusFrame)
          _ = try rawRead(fd, count: 68)
        }
        let excess = try rawConnect(url)
        defer { Darwin.close(excess) }
        try? rawWrite(excess, statusFrame)
        return Result { try rawRead(excess, count: 1) }
      }
      #expect(throws: WorkerIPCError.disconnected) { try excessRead.get() }
      #expect(await probe.commands.count == 8)
    }
  }

  @Test func serverCloseKeepsAcceptedOperationOwned() async throws {
    let probe = CommandProbe()
    do {
      try await withServer {
        await probe.handle($0)
      } body: { server, url in
        let client = WorkerIPCClient(socketURL: url, vmID: wireVM, sessionID: wireSession)
        try await client.connect()
        _ = try await client.request(.status)
        let command = Task { try await client.request(.pause, observedRevision: 7) }
        try await eventually { await probe.entered }
        await server.close()
        #expect(await !probe.completed)
        _ = try? await command.value
        await probe.allowCompletion()
        try await eventually { await probe.completed }
        #expect(await probe.commands == [.status, .pause])
        await client.close()
      }
    } catch {
      await probe.allowCompletion()
      throw error
    }
  }

  @Test func finishPreservesAcceptedCallbackThenRemovesEndpoint() async throws {
    let fixture = try SocketFixture()
    defer { fixture.remove() }
    let probe = CommandProbe()
    let server = WorkerIPCServer(socketURL: fixture.socket, handler: { await probe.handle($0) })
    do {
      try await server.start()
      let client = WorkerIPCClient(socketURL: fixture.socket, vmID: wireVM, sessionID: wireSession)
      try await client.connect()
      _ = try await client.request(.status)
      let command = Task { try await client.request(.pause, observedRevision: 7) }
      try await eventually { await probe.entered }
      let finish = Task { await server.finishWhenIdle() }
      try await Task.sleep(for: .milliseconds(30))
      #expect(await !probe.completed)
      await probe.allowCompletion()
      #expect(try await command.value.error == .none)
      await finish.value
      #expect(!FileManager.default.fileExists(atPath: fixture.socket.path))
      await client.close()
    } catch {
      await probe.allowCompletion()
      await server.close()
      throw error
    }
  }

  @Test func finishRejectsAFrameArrivingOnAnExistingIdleConnection() async throws {
    let probe = CommandProbe()
    try await withServer {
      await probe.handle($0)
    } body: { server, url in
      let fd = try await rawIO {
        let fd = try rawConnect(url)
        do {
          try rawWrite(fd, statusFrame)
          _ = try rawRead(fd, count: 68)
          return fd
        } catch {
          Darwin.close(fd)
          throw error
        }
      }
      defer { Darwin.close(fd) }
      let finish = Task { await server.finishWhenIdle() }
      // Endpoint removal occurs after finishing has been set, while the existing
      // stream remains connected and its read may already be awaiting a frame.
      try await eventually { !FileManager.default.fileExists(atPath: url.path) }
      let lateMutationRead = try await rawIO {
        var lateMutation = statusFrame
        lateMutation[47] = 2
        lateMutation[55] = 7
        lateMutation[56] = 1
        try? rawWrite(fd, lateMutation)
        return Result { try rawRead(fd, count: 1) }
      }
      #expect(throws: WorkerIPCError.disconnected) { try lateMutationRead.get() }
      await finish.value
      #expect(await probe.commands == [.status])
    }
  }

  @Test func privateEndpointAndExistingFileArePreserved() async throws {
    let fixture = try SocketFixture()
    defer { fixture.remove() }
    let marker = Data("owned marker".utf8)
    try marker.write(to: fixture.socket, options: .withoutOverwriting)
    let server = WorkerIPCServer(socketURL: fixture.socket, handler: { response($0) })
    await #expect(throws: WorkerIPCError.unsafeSocket) { try await server.start() }
    await server.close()
    #expect(try Data(contentsOf: fixture.socket) == marker)
    let client = WorkerIPCClient(socketURL: fixture.socket, vmID: wireVM, sessionID: wireSession)
    await #expect(throws: WorkerIPCError.unsafeSocket) { try await client.connect() }
    await client.close()
    try FileManager.default.removeItem(at: fixture.socket)
    #expect(chmod(fixture.directory.path, 0o755) == 0)
    let publicParent = WorkerIPCServer(socketURL: fixture.socket, handler: { response($0) })
    await #expect(throws: WorkerIPCError.unsafeSocket) { try await publicParent.start() }
    await publicParent.close()
    #expect(!FileManager.default.fileExists(atPath: fixture.socket.path))
  }

  @Test func writableAncestorAndSymlinkAliasAreRejected() async throws {
    let fixture = try SocketFixture()
    defer { fixture.remove() }
    let parent = fixture.directory.appendingPathComponent("private", isDirectory: true)
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(chmod(fixture.directory.path, 0o777) == 0)
    let writable = WorkerIPCServer(
      socketURL: parent.appendingPathComponent("worker.sock"), handler: { response($0) })
    await #expect(throws: WorkerIPCError.unsafeSocket) { try await writable.start() }
    await writable.close()
    #expect(chmod(fixture.directory.path, 0o700) == 0)
    let alias = fixture.directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    let symlinked = WorkerIPCServer(
      socketURL: alias.appendingPathComponent("worker.sock"), handler: { response($0) })
    await #expect(throws: WorkerIPCError.unsafeSocket) { try await symlinked.start() }
    await symlinked.close()
  }

  @Test func endpointReplacementIsPreservedOnClose() async throws {
    let fixture = try SocketFixture()
    defer { fixture.remove() }
    let server = WorkerIPCServer(socketURL: fixture.socket, handler: { response($0) })
    try await server.start()
    try FileManager.default.removeItem(at: fixture.socket)
    let marker = Data("replacement marker".utf8)
    try marker.write(to: fixture.socket, options: .withoutOverwriting)
    await server.close()
    #expect(try Data(contentsOf: fixture.socket) == marker)
  }
}
