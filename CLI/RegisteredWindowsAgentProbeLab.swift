// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation

/// One fixed public-byte transport fixture. Never authentication, TLS or agent health.
enum RegisteredWindowsAgentProbeLab {
  static let challenge = Data("macOpenVM/vioser-transfer-lab/v1:challenge\n".utf8)
  static let reply = Data("macOpenVM/vioser-transfer-lab/v1:reply\n".utf8)
  static let maximumFragment = 7
  static let maximumBytes = 4096

  struct Result: Encodable, Sendable {
    let scope = "macopenvm-registered-windows-fixed-agent-transfer"
    let vmID: UUID, sessionID: UUID
    let sentBytes: Int, receivedBytes: Int, writeFragments: Int, readFragments: Int
    let completed: Bool, endedAt: String
    let authenticated = false
    let guestHealthVerified = false
  }

  struct Route: Codable, Sendable {
    let schemaVersion: Int, scope: String, vmID: UUID, sessionID: UUID
    let controlSocket: String, agentSocket: String
    let parentDevice: dev_t, parentInode: ino_t, socketDevice: dev_t, socketInode: ino_t
  }

  static func decodeRoute(
    _ bytes: Data, request: RegisteredWindowsControl.Request, vmID: UUID
  ) throws -> Route {
    guard !bytes.isEmpty, bytes.count <= 4096 else { throw failure() }
    let route: Route
    do { route = try JSONDecoder().decode(Route.self, from: bytes) } catch { throw failure() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let parent =
      "/private/tmp/mvo-qemu-" + request.runDirectory.lastPathComponent.dropFirst(4).prefix(16)
    guard try encoder.encode(route) == bytes, route.schemaVersion == 1,
      route.scope == "macopenvm-registered-qemu-agent-route", route.vmID == vmID,
      route.sessionID == request.expectedSession, route.controlSocket == parent + "/worker.sock",
      route.agentSocket == parent + "/agent.sock", route.parentInode > 0, route.socketInode > 0
    else { throw failure() }
    return route
  }

  static func healthy(
    _ observed: RegisteredWindowsControl.Result, reference: RegisteredWindowsControl.Result
  ) throws {
    guard observed.action == "status", observed.vmID == reference.vmID,
      observed.sessionID == reference.sessionID, observed.revision == reference.revision,
      observed.state == 2, observed.ownership == 0, observed.backendActive,
      !observed.operationPending, observed.error == 0
    else { throw failure() }
  }

  static func run(request: RegisteredWindowsControl.Request) async throws -> Result {
    guard request.action == .status else { throw failure() }
    try Task.checkCancellation()
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    let reference = try await statusWithin(request, deadline: deadline)
    try healthy(reference, reference: reference)
    try check(deadline)
    let path = request.runDirectory.appendingPathComponent("agent.json")
    let bytes = try WindowsExternalFileIO.readPrivate(path, maximum: 4096)
    let route = try decodeRoute(bytes, request: request, vmID: reference.vmID)
    let cancelled = Cancellation()
    return try await withTaskCancellationHandler {
      let transport = Transport(route: route, cancelled: cancelled, deadline: deadline)
      var phase = "connect"
      do {
        try await verify(
          request, reference: reference, path: path, bytes: bytes, deadline: deadline)
        try await transport.perform { try $0.connect() }
        phase = "challenge"
        var sent = 0
        var writes = 0
        while sent < challenge.count {
          try await verify(
            request, reference: reference, path: path, bytes: bytes, deadline: deadline)
          let offset = sent
          sent += try await transport.perform { try $0.sendFragment(offset: offset) }
          writes += 1
        }
        phase = "reply"
        var received = 0
        var reads = 0
        while received < reply.count {
          try await verify(
            request, reference: reference, path: path, bytes: bytes, deadline: deadline)
          let offset = received
          received += try await transport.perform { try $0.readFragment(offset: offset) }
          reads += 1
        }
        phase = "final-status-route"
        try await verify(
          request, reference: reference, path: path, bytes: bytes, deadline: deadline)
        try await transport.perform { try $0.rejectAvailableTrailingBytes() }
        await transport.close()
        try Task.checkCancellation()
        if cancelled.isCancelled { throw CancellationError() }
        try check(deadline)
        return Result(
          vmID: route.vmID, sessionID: route.sessionID, sentBytes: sent,
          receivedBytes: received, writeFragments: writes, readFragments: reads,
          completed: true, endedAt: "complete")
      } catch {
        let counts = await transport.countsAndClose()
        if Task.isCancelled || cancelled.isCancelled { throw CancellationError() }
        return Result(
          vmID: route.vmID, sessionID: route.sessionID, sentBytes: counts.sent,
          receivedBytes: counts.received, writeFragments: counts.writes,
          readFragments: counts.reads, completed: false, endedAt: phase)
      }
    } onCancel: {
      // No descriptor is closed from another thread; the utility worker notices
      // this flag within a bounded poll and closes only its own client afterward.
      cancelled.cancel()
    }
  }

  private static func verify(
    _ request: RegisteredWindowsControl.Request, reference: RegisteredWindowsControl.Result,
    path: URL, bytes: Data, deadline: ContinuousClock.Instant
  ) async throws {
    try Task.checkCancellation()
    try check(deadline)
    guard try WindowsExternalFileIO.readPrivate(path, maximum: 4096) == bytes else {
      throw failure()
    }
    try healthy(await statusWithin(request, deadline: deadline), reference: reference)
    try check(deadline)
    guard try WindowsExternalFileIO.readPrivate(path, maximum: 4096) == bytes else {
      throw failure()
    }
  }

  private static func check(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw failure() }
  }

  private static func statusWithin(
    _ request: RegisteredWindowsControl.Request, deadline: ContinuousClock.Instant
  ) async throws -> RegisteredWindowsControl.Result {
    try check(deadline)
    return try await withThrowingTaskGroup(of: RegisteredWindowsControl.Result.self) { group in
      group.addTask { try await RegisteredWindowsControl.run(request) }
      group.addTask {
        try await ContinuousClock().sleep(until: deadline)
        throw failure()
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw failure() }
      try check(deadline)
      return result
    }
  }

  final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
  }

  /// Descriptor and all syscall activity are confined to this utility queue.
  final class Transport: @unchecked Sendable {
    let route: Route, cancelled: Cancellation, deadline: ContinuousClock.Instant
    private let queue = DispatchQueue(label: "local.macOpenVM.fixed-agent-probe", qos: .utility)
    private var descriptor: Int32 = -1
    private var sent = 0
    private var received = 0
    private var writes = 0
    private var reads = 0

    init(route: Route, cancelled: Cancellation, deadline: ContinuousClock.Instant) {
      self.route = route
      self.cancelled = cancelled
      self.deadline = deadline
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func perform<T: Sendable>(_ body: @escaping @Sendable (Transport) throws -> T) async throws -> T
    {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do { continuation.resume(returning: try body(self)) } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    func close() async {
      _ = await countsAndClose()
    }

    func countsAndClose() async -> (sent: Int, received: Int, writes: Int, reads: Int) {
      await withCheckedContinuation { continuation in
        queue.async {
          if self.descriptor >= 0 {
            Darwin.close(self.descriptor)
            self.descriptor = -1
          }
          continuation.resume(returning: (self.sent, self.received, self.writes, self.reads))
        }
      }
    }

    func validateEndpoint() throws {
      try checkWindow()
      let url = URL(fileURLWithPath: route.agentSocket)
      guard WindowsExternalFileIO.lexical(url), route.agentSocket.utf8.count <= 103 else {
        throw failure()
      }
      try WindowsExternalFileIO.privateDirectory(url.deletingLastPathComponent())
      var parent = stat()
      var socket = stat()
      guard lstat(url.deletingLastPathComponent().path, &parent) == 0,
        parent.st_dev == route.parentDevice, parent.st_ino == route.parentInode,
        lstat(url.path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
        socket.st_uid == geteuid(), socket.st_nlink == 1, socket.st_mode & 0o077 == 0,
        socket.st_mode & 0o600 == 0o600, socket.st_mode & 0o7000 == 0,
        socket.st_dev == route.socketDevice, socket.st_ino == route.socketInode
      else { throw failure() }
    }

    func connect() throws {
      guard descriptor == -1 else { throw failure() }
      try validateEndpoint()
      let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw failure() }
      descriptor = fd
      guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
        throw failure()
      }
      var noSignal: Int32 = 1
      guard
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
          == 0
      else { throw failure() }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      withUnsafeMutableBytes(of: &address.sun_path) {
        $0.copyBytes(from: Array(route.agentSocket.utf8) + [0])
      }
      try validateEndpoint()
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      if result != 0 {
        guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else { throw failure() }
        try wait(events: Int16(POLLOUT))
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
          throw failure()
        }
      }
      var user: uid_t = 0
      var group: gid_t = 0
      guard getpeereid(fd, &user, &group) == 0, user == geteuid() else { throw failure() }
      try validateEndpoint()
    }

    func sendFragment(offset: Int) throws -> Int {
      guard descriptor >= 0, offset == sent, offset < challenge.count,
        challenge.count + reply.count <= maximumBytes
      else { throw failure() }
      while true {
        try validateEndpoint()
        let count = challenge.withUnsafeBytes {
          Darwin.send(
            descriptor, $0.baseAddress?.advanced(by: offset),
            min(maximumFragment, challenge.count - offset), 0)
        }
        if count > 0 {
          sent += count
          writes += 1
          try validateEndpoint()
          return count
        }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          try wait(events: Int16(POLLOUT))
          continue
        }
        throw failure()
      }
    }

    func readFragment(offset: Int) throws -> Int {
      guard descriptor >= 0, sent == challenge.count, offset == received, offset < reply.count
      else {
        throw failure()
      }
      var fragment = [UInt8](repeating: 0, count: min(maximumFragment, reply.count - offset))
      while true {
        try validateEndpoint()
        let count = fragment.withUnsafeMutableBytes {
          Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
        }
        if count > 0 {
          received += count
          reads += 1
          guard fragment.prefix(count).elementsEqual(reply[offset..<(offset + count)]) else {
            throw failure()
          }
          try validateEndpoint()
          return count
        }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          try wait(events: Int16(POLLIN))
          continue
        }
        throw failure()
      }
    }

    /// Reject bytes already available beyond the fixed reply. Future traffic is
    /// outside this one-shot fixture and is not treated as authenticated traffic.
    func rejectAvailableTrailingBytes() throws {
      try validateEndpoint()
      var byte: UInt8 = 0
      while true {
        let count = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count == 0 { return }
        if count < 0, errno == EINTR {
          try checkWindow()
          continue
        }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
        throw failure()
      }
    }

    private func checkWindow() throws {
      if cancelled.isCancelled { throw CancellationError() }
      try check(deadline)
    }

    private func wait(events: Int16) throws {
      while true {
        try validateEndpoint()
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&item, 1, 20)
        try validateEndpoint()
        if result < 0 {
          if errno == EINTR { continue }
          throw failure()
        }
        if result == 0 { continue }
        if item.revents & Int16(POLLNVAL) != 0 { throw failure() }
        if item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
      }
    }
  }

  private static func failure() -> VMError {
    VMError(
      .staleOperation, "The registered fixed-byte agent transfer is invalid, stale, or incomplete.",
      recovery:
        "Preserve the current VM and inspect its transport. No replay, reconnect or lifecycle action is automatic."
    )
  }
}
