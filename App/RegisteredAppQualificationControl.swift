// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation
import VMCore

/// A separate qualification endpoint. It has no guest input/display APIs and no
/// runtime authority: its driver admits the current actual App owner and nonce.
@MainActor final class RegisteredAppQualificationControl {
  enum Action: String, Codable, Sendable {
    case status
    case stop
    case forceStop = "force-stop"
    case quit
  }
  enum ReplyCode: String, Codable, Sendable { case ok, refused, failed }
  struct Request: Codable, Sendable {
    let requestID: UInt64
    let nonce: UUID
    let vmID: UUID
    let sessionID: UUID?
    let launchGeneration: UUID?
    let action: Action
    enum CodingKeys: String, CodingKey {
      case requestID, nonce, vmID, sessionID, launchGeneration, action
    }
    func encode(to encoder: any Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(requestID, forKey: .requestID)
      try c.encode(nonce, forKey: .nonce)
      try c.encode(vmID, forKey: .vmID)
      try c.encode(action, forKey: .action)
      if let sessionID {
        try c.encode(sessionID, forKey: .sessionID)
      } else {
        try c.encodeNil(forKey: .sessionID)
      }
      if let launchGeneration {
        try c.encode(launchGeneration, forKey: .launchGeneration)
      } else {
        try c.encodeNil(forKey: .launchGeneration)
      }
    }
  }
  struct Response: Codable, Sendable {
    let requestID: UInt64
    let nonce: UUID
    let vmID: UUID
    let sessionID: UUID?
    let launchGeneration: UUID?
    let replyCode: ReplyCode
    let state: VMState
    let busy: Bool
    let backendActive: Bool
    let displayReady: Bool
    let frameEpochPresent: Bool
    let settled: Bool
    let outcome: RuntimeOutcome?
    var qualificationFailed: Bool = false
  }
  typealias Handler = @MainActor @Sendable (Request) async -> Response
  typealias ResponseSent = @MainActor @Sendable (Request, Response) -> Void
  let nonce: UUID
  private let transport: QualificationControlTransport
  init(
    socketURL: URL, nonce: UUID = UUID(), handler: @escaping Handler,
    onResponseSent: ResponseSent? = nil
  ) {
    self.nonce = nonce
    transport = QualificationControlTransport(
      socketURL: socketURL, nonce: nonce,
      handler: handler, sent: onResponseSent)
  }
  func start() async throws { try await transport.start() }
  func close() async { await transport.close() }

  nonisolated static func decode(_ bytes: Data) throws -> Request {
    guard !bytes.isEmpty, bytes.count <= 2048 else { throw qualificationControlFailure() }
    let value = try JSONDecoder().decode(Request.self, from: bytes)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard value.requestID > 0, try encoder.encode(value) == bytes else {
      throw qualificationControlFailure()
    }
    return value
  }
}

/// All socket state is accessed on one serial queue. Accepted handler tasks are
/// retained through completion even if the peer closes or the endpoint closes.
private final class QualificationControlTransport: @unchecked Sendable {
  private final class Connection: @unchecked Sendable {
    let fd: Int32
    let id = UUID()
    var input = Data()
    var output = Data()
    var offset = 0
    var source: (any DispatchSourceRead)?
    var writer: (any DispatchSourceWrite)?
    var sourceHolders = 0
    var closing = false
    var request: RegisteredAppQualificationControl.Request?
    var response: RegisteredAppQualificationControl.Response?
    init(_ fd: Int32) { self.fd = fd }
  }
  private let socketURL: URL
  private let nonce: UUID
  private let handler: RegisteredAppQualificationControl.Handler
  private let sent: RegisteredAppQualificationControl.ResponseSent?
  private let queue = DispatchQueue(label: "local.macOpenVM.app-qualification")
  private var listener: Int32 = -1
  private var listenerSource: (any DispatchSourceRead)?
  private var connections: [UUID: Connection] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var socketIdentity: (dev_t, ino_t)?
  private var closed = false
  private var listenerClosePending = false
  private var closingConnections: Set<UUID> = []
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  init(
    socketURL: URL, nonce: UUID, handler: @escaping RegisteredAppQualificationControl.Handler,
    sent: RegisteredAppQualificationControl.ResponseSent?
  ) {
    self.socketURL = socketURL
    self.nonce = nonce
    self.handler = handler
    self.sent = sent
  }
  func start() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      queue.async { [self] in
        do {
          try listen()
          continuation.resume()
        } catch {
          stop()
          continuation.resume(throwing: error)
        }
      }
    }
  }
  func close() async {
    let pending: [Task<Void, Never>] = await withCheckedContinuation { continuation in
      queue.async { [self] in
        stop()
        continuation.resume(returning: Array(tasks.values))
      }
    }
    for task in pending { await task.value }
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if !listenerClosePending && closingConnections.isEmpty {
          continuation.resume()
        } else {
          closeWaiters.append(continuation)
        }
      }
    }
  }
  private func listen() throws {
    let parent = socketURL.deletingLastPathComponent()
    guard !closed, listener < 0, socketURL.isFileURL, socketURL.host == nil || socketURL.host == "",
      socketURL.user == nil, socketURL.password == nil, socketURL.query == nil,
      socketURL.fragment == nil,
      socketURL.path.range(
        of: "^/private/tmp/mvo-appqual-[0-9a-f]{16}/control[.]sock$", options: .regularExpression)
        != nil
    else { throw qualificationControlFailure() }
    var directory = stat()
    var existing = stat()
    guard lstat(parent.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
      directory.st_uid == geteuid(), directory.st_mode & 0o7777 == 0o700,
      lstat(socketURL.path, &existing) != 0, errno == ENOENT
    else { throw qualificationControlFailure() }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw qualificationControlFailure() }
    listener = fd
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
      throw qualificationControlFailure()
    }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw qualificationControlFailure() }
    var created = stat()
    var namedParent = stat()
    guard lstat(socketURL.path, &created) == 0, created.st_mode & S_IFMT == S_IFSOCK,
      created.st_uid == geteuid(), created.st_nlink == 1
    else { throw qualificationControlFailure() }
    socketIdentity = (created.st_dev, created.st_ino)
    guard chmod(socketURL.path, 0o600) == 0, Darwin.listen(fd, 8) == 0,
      lstat(parent.path, &namedParent) == 0, directory.st_dev == namedParent.st_dev,
      directory.st_ino == namedParent.st_ino, namedParent.st_mode == directory.st_mode,
      namedParent.st_uid == directory.st_uid
    else { throw qualificationControlFailure() }
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.accept() }
    source.setCancelHandler { [self] in
      Darwin.close(fd)
      listenerClosePending = false
      finishCloseWaiters()
    }
    listenerSource = source
    source.activate()
  }
  private func accept() {
    guard !closed else { return }
    for _ in 0..<8 {
      let fd = Darwin.accept(listener, nil, nil)
      if fd < 0 { return }
      var uid: uid_t = 0
      var gid: gid_t = 0
      var noPipe: Int32 = 1
      guard connections.count < 8, getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
        fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
      else {
        Darwin.close(fd)
        continue
      }
      let connection = Connection(fd)
      connections[connection.id] = connection
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      source.setEventHandler { [weak self, weak connection] in
        guard let self, let connection else { return }
        self.read(connection)
      }
      connection.sourceHolders += 1
      source.setCancelHandler { [self, connection] in sourceCancelled(connection) }
      connection.source = source
      source.activate()
    }
  }
  private func read(_ c: Connection) {
    guard !closed, connections[c.id] === c else { return }
    var buffer = [UInt8](repeating: 0, count: 512)
    for _ in 0..<5 {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.recv(c.fd, $0.baseAddress, $0.count, MSG_DONTWAIT)
      }
      if count < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        if errno == EINTR { continue }
        finish(c)
        return
      }
      if count == 0 {
        finish(c)
        return
      }
      c.input.append(contentsOf: buffer.prefix(count))
      guard c.input.count <= 2052 else {
        finish(c)
        return
      }
      guard c.input.count >= 4 else { continue }
      let length = c.input.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard length > 0, length <= 2048, c.input.count <= Int(length) + 4 else {
        finish(c)
        return
      }
      guard c.input.count == Int(length) + 4 else { continue }
      do {
        let request = try RegisteredAppQualificationControl.decode(c.input.dropFirst(4))
        guard request.action == .status || request.nonce == nonce else {
          finish(c)
          return
        }
        c.source?.cancel()
        c.source = nil
        c.request = request
        let handler = handler
        tasks[c.id] = Task { [self, c] in
          let response = await handler(request)
          do {
            guard response.requestID == request.requestID, response.nonce == nonce else {
              throw qualificationControlFailure()
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(response)
            guard bytes.count <= 2048 else { throw qualificationControlFailure() }
            queue.async { [self, c] in
              tasks.removeValue(forKey: c.id)
              guard !closed, connections[c.id] === c else { return }
              c.response = response
              var size = UInt32(bytes.count).bigEndian
              c.output = withUnsafeBytes(of: &size) { Data($0) }
              c.output.append(bytes)
              write(c)
            }
          } catch {
            queue.async { [self, c] in
              tasks.removeValue(forKey: c.id)
              finish(c)
            }
          }
        }
      } catch { finish(c) }
      return
    }
  }
  private func write(_ c: Connection) {
    guard !closed, connections[c.id] === c else { return }
    while c.offset < c.output.count {
      let count = c.output.withUnsafeBytes {
        Darwin.send(c.fd, $0.baseAddress?.advanced(by: c.offset), $0.count - c.offset, 0)
      }
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          if c.writer == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: c.fd, queue: queue)
            source.setEventHandler { [weak self, weak c] in
              guard let self, let c else { return }
              self.write(c)
            }
            c.sourceHolders += 1
            source.setCancelHandler { [self, c] in sourceCancelled(c) }
            c.writer = source
            source.activate()
          }
          return
        }
        finish(c)
        return
      }
      guard count > 0 else {
        finish(c)
        return
      }
      c.offset += count
    }
    let request = c.request
    let response = c.response
    let sent = sent
    finish(c)
    if let request, let response, let sent { Task { @MainActor in sent(request, response) } }
  }
  private func finish(_ c: Connection) {
    guard connections.removeValue(forKey: c.id) != nil else { return }
    c.closing = true
    closingConnections.insert(c.id)
    c.source?.cancel()
    c.writer?.cancel()
    c.source = nil
    c.writer = nil
    if c.sourceHolders == 0 { closeConnectionDescriptor(c) }
  }
  private func sourceCancelled(_ c: Connection) {
    c.sourceHolders -= 1
    if c.closing && c.sourceHolders == 0 { closeConnectionDescriptor(c) }
  }
  private func closeConnectionDescriptor(_ c: Connection) {
    guard closingConnections.remove(c.id) != nil else { return }
    Darwin.close(c.fd)
    finishCloseWaiters()
  }
  private func finishCloseWaiters() {
    guard closed, !listenerClosePending, closingConnections.isEmpty else { return }
    let pending = closeWaiters
    closeWaiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
  private func stop() {
    closed = true
    if let source = listenerSource {
      listenerClosePending = true
      listener = -1
      source.cancel()
      listenerSource = nil
    } else if listener >= 0 {
      Darwin.close(listener)
      listener = -1
    }
    for c in Array(connections.values) { finish(c) }
    if let identity = socketIdentity {
      var named = stat()
      if lstat(socketURL.path, &named) == 0, named.st_mode & S_IFMT == S_IFSOCK,
        named.st_uid == geteuid(), named.st_dev == identity.0, named.st_ino == identity.1
      {
        _ = unlink(socketURL.path)
      }
    }
  }
}

nonisolated private func qualificationControlFailure() -> VMError {
  VMError(
    .invalidConfiguration, "The private App qualification control could not be confirmed.",
    recovery:
      "Preserve the actual App and worker; no disconnect or control error stops either owner.")
}
