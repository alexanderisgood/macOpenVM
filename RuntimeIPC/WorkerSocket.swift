// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation

enum WorkerCaptureIncoming: Sendable {
  case legacy(Data)
  case capture(Data)
}

/// I/O and actual close are confined to this queue. The lock only publishes the
/// descriptor and shutdown flag to cancellation callers. Queued work retains
/// this object, so close/deinit cannot race I/O or operate on a recycled descriptor.
final class WorkerSocket: @unchecked Sendable {
  private struct Identity {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) {
      device = info.st_dev
      inode = info.st_ino
    }
    func matches(_ info: stat) -> Bool { device == info.st_dev && inode == info.st_ino }
  }

  private let socketURL: URL?
  private let queue = DispatchQueue(label: "local.macOpenVM.worker-ipc", qos: .userInitiated)
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var closed = false
  private var parentIdentity: Identity?
  private var socketIdentity: Identity?
  private var ownsEndpoint = false
  private var readinessSource: (any DispatchSourceRead)?
  private var readinessWaiter: CheckedContinuation<Void, Error>?
  private var readinessID: UUID?
  private var pendingReadSources = 0
  private var closeRequested = false
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private let clock = ContinuousClock()

  init(socketURL: URL) { self.socketURL = socketURL }
  private init(descriptor: Int32) {
    socketURL = nil
    self.descriptor = descriptor
  }

  deinit {
    if descriptor >= 0 { Darwin.close(descriptor) }
    removeOwnedEndpoint()
  }

  func perform<T: Sendable>(
    _ operation: @escaping @Sendable (WorkerSocket) throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try operation(self)) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// One-shot, event-driven listener readiness. The callback only resumes its
  /// waiter; it never reads/reaps/closes a descriptor, including queued callbacks
  /// after cancellation. Actual accept and close remain on the same serial queue.
  func waitForConnection() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        do {
          let value = try self.fd()
          guard self.readinessWaiter == nil else { throw WorkerIPCError.busy }
          self.readinessWaiter = continuation
          let id = UUID()
          self.readinessID = id
          let source = DispatchSource.makeReadSource(fileDescriptor: value, queue: self.queue)
          self.readinessSource = source
          self.pendingReadSources += 1
          source.setCancelHandler { [self] in
            pendingReadSources -= 1
            finishCloseIfReady()
          }
          source.setEventHandler { [weak self] in
            guard let self, self.readinessID == id else { return }
            self.readinessSource?.cancel()
            self.readinessSource = nil
            self.readinessID = nil
            guard let waiter = self.readinessWaiter else { return }
            self.readinessWaiter = nil
            do {
              _ = try self.fd()
              waiter.resume()
            } catch { waiter.resume(throwing: error) }
          }
          source.activate()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  func signalClose() {
    lock.lock()
    closed = true
    if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    lock.unlock()
  }

  func close() async {
    signalClose()
    await withCheckedContinuation { continuation in
      queue.async {
        self.readinessID = nil
        self.readinessSource?.cancel()
        self.readinessSource = nil
        self.readinessWaiter?.resume(throwing: WorkerIPCError.closed)
        self.readinessWaiter = nil
        self.closeRequested = true
        self.closeWaiters.append(continuation)
        self.finishCloseIfReady()
      }
    }
  }

  /// Cancellation handlers run after all source callbacks. Keeping the published
  /// descriptor until every one-shot source drains prevents kernel notifications
  /// from being associated with a later socket that reuses its descriptor number.
  private func finishCloseIfReady() {
    guard closeRequested, pendingReadSources == 0 else { return }
    lock.lock()
    let old = descriptor
    descriptor = -1
    lock.unlock()
    if old >= 0 { Darwin.close(old) }
    removeOwnedEndpoint()
    let waiters = closeWaiters
    closeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func fd() throws -> Int32 {
    lock.lock()
    let value = descriptor
    let unavailable = closed
    lock.unlock()
    guard !unavailable, value >= 0 else { throw WorkerIPCError.closed }
    return value
  }

  private func install(_ value: Int32) throws {
    lock.lock()
    if closed {
      lock.unlock()
      Darwin.close(value)
      throw WorkerIPCError.closed
    }
    descriptor = value
    lock.unlock()
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    _ = try fd()
    if clock.now >= deadline { throw WorkerIPCError.deadlineExceeded }
  }

  private func poll(_ value: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
    while true {
      try check(deadline)
      let remaining = clock.now.duration(to: deadline).components
      let milliseconds =
        Double(remaining.seconds) * 1_000
        + Double(remaining.attoseconds) / 1_000_000_000_000_000
      var item = pollfd(fd: value, events: events, revents: 0)
      let result = Darwin.poll(&item, 1, Int32(max(1, min(20, milliseconds.rounded(.up)))))
      try check(deadline)
      if result < 0 {
        if errno == EINTR { continue }
        throw WorkerIPCError.posix(errno)
      }
      if result == 0 { continue }
      if item.revents & Int16(POLLNVAL) != 0 { throw WorkerIPCError.disconnected }
      if item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
    }
  }

  private func configure(_ value: Int32) throws {
    guard fcntl(value, F_SETFL, O_NONBLOCK) == 0, fcntl(value, F_SETFD, FD_CLOEXEC) == 0 else {
      throw WorkerIPCError.posix(errno)
    }
    var noSignal: Int32 = 1
    guard
      setsockopt(
        value, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw WorkerIPCError.posix(errno) }
  }

  private func sameUser(_ value: Int32) throws {
    var user: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(value, &user, &group) == 0, user == geteuid() else {
      throw WorkerIPCError.unsafeSocket
    }
  }

  private func address(_ path: String) -> sockaddr_un {
    var value = sockaddr_un()
    value.sun_family = sa_family_t(AF_UNIX)
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    return value
  }

  private func safePath() throws -> String {
    guard let socketURL else { throw WorkerIPCError.unsafeSocket }
    let path = socketURL.path
    guard socketURL.isFileURL, socketURL.host == nil || socketURL.host == "",
      socketURL.query == nil, socketURL.fragment == nil, path.hasPrefix("/"),
      !path.hasSuffix("/"), path.utf8.count <= 103,
      !path.utf8.contains(where: { $0 < 32 || $0 == 127 })
    else { throw WorkerIPCError.unsafeSocket }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw WorkerIPCError.unsafeSocket
    }
    var ancestor = ""
    for part in parts.dropFirst().dropLast() {
      ancestor += "/" + part
      var info = stat()
      guard Darwin.lstat(ancestor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw WorkerIPCError.unsafeSocket
      }
      let rootTemporary =
        ancestor == "/private/tmp" && info.st_uid == 0
        && info.st_mode & S_ISVTX != 0
      guard info.st_uid == 0 || info.st_uid == geteuid(),
        info.st_mode & 0o022 == 0 || rootTemporary
      else { throw WorkerIPCError.unsafeSocket }
    }
    var parent = stat()
    guard Darwin.lstat(socketURL.deletingLastPathComponent().path, &parent) == 0,
      parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(),
      parent.st_mode & 0o777 == 0o700
    else { throw WorkerIPCError.unsafeSocket }
    if let parentIdentity {
      guard parentIdentity.matches(parent) else { throw WorkerIPCError.unsafeSocket }
    } else {
      parentIdentity = Identity(parent)
    }
    return path
  }

  private func socketInfo(_ path: String) throws -> stat? {
    var info = stat()
    if Darwin.lstat(path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw WorkerIPCError.unsafeSocket
    }
    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_nlink == 1,
      info.st_mode & 0o777 == 0o600
    else { throw WorkerIPCError.unsafeSocket }
    return info
  }

  private func recheckEndpoint() throws {
    let path = try safePath()
    guard let socketIdentity, let current = try socketInfo(path), socketIdentity.matches(current)
    else { throw WorkerIPCError.unsafeSocket }
  }

  private func removeOwnedEndpoint() {
    guard ownsEndpoint, let socketURL, let socketIdentity, let path = try? safePath()
    else { return }
    var current = stat()
    guard Darwin.lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFSOCK,
      current.st_uid == geteuid(), current.st_nlink == 1, socketIdentity.matches(current)
    else { return }
    _ = Darwin.unlink(socketURL.path)
    ownsEndpoint = false
  }

  func listen() throws {
    let path = try safePath()
    var prior = stat()
    guard Darwin.lstat(path, &prior) != 0, errno == ENOENT else {
      throw WorkerIPCError.unsafeSocket
    }
    let value = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard value >= 0 else { throw WorkerIPCError.posix(errno) }
    try install(value)
    try configure(value)
    var location = address(path)
    let result = withUnsafePointer(to: &location) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw WorkerIPCError.posix(errno) }
    var bound = stat()
    guard Darwin.lstat(path, &bound) == 0, bound.st_mode & S_IFMT == S_IFSOCK,
      bound.st_uid == geteuid(), bound.st_nlink == 1
    else { throw WorkerIPCError.unsafeSocket }
    socketIdentity = Identity(bound)
    ownsEndpoint = true
    // The immediate parent is private before bind; no process-wide umask change.
    guard Darwin.chmod(path, 0o600) == 0, let info = try socketInfo(path) else {
      throw WorkerIPCError.unsafeSocket
    }
    guard socketIdentity?.matches(info) == true else { throw WorkerIPCError.unsafeSocket }
    try recheckEndpoint()
    guard Darwin.listen(value, 8) == 0 else { throw WorkerIPCError.posix(errno) }
    _ = try fd()
  }

  func accept() throws -> WorkerSocket? {
    try recheckEndpoint()
    let value = try fd()
    let accepted = Darwin.accept(value, nil, nil)
    if accepted < 0 {
      if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
      throw WorkerIPCError.posix(errno)
    }
    do {
      try configure(accepted)
      try sameUser(accepted)
      try recheckEndpoint()
      return WorkerSocket(descriptor: accepted)
    } catch {
      Darwin.close(accepted)
      throw error
    }
  }

  func connect(deadline: ContinuousClock.Instant) throws {
    let path = try safePath()
    guard let before = try socketInfo(path) else { throw WorkerIPCError.unsafeSocket }
    socketIdentity = Identity(before)
    let value = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard value >= 0 else { throw WorkerIPCError.posix(errno) }
    try install(value)
    try configure(value)
    try check(deadline)
    var location = address(path)
    let result = withUnsafePointer(to: &location) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result != 0 {
      guard errno == EINPROGRESS || errno == EAGAIN else { throw WorkerIPCError.posix(errno) }
      try poll(value, events: Int16(POLLOUT), deadline: deadline)
      var error: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(value, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
        throw WorkerIPCError.posix(error == 0 ? errno : error)
      }
    }
    try sameUser(value)
    try recheckEndpoint()
    try check(deadline)
  }

  func rejectPendingReply() throws {
    let value = try fd()
    try recheckEndpoint()
    var byte: UInt8 = 0
    let count = Darwin.recv(value, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    if count > 0 { throw WorkerIPCError.unexpectedReply }
    if count == 0 { throw WorkerIPCError.disconnected }
    if errno != EAGAIN && errno != EWOULDBLOCK { throw WorkerIPCError.posix(errno) }
  }

  func write(_ bytes: Data, deadline: ContinuousClock.Instant) throws {
    guard bytes.count <= WorkerFrameCodec.maximumPayloadBytes + 4 else {
      throw WorkerIPCError.limitExceeded
    }
    let value = try fd()
    var offset = 0
    while offset < bytes.count {
      try check(deadline)
      let count = bytes.withUnsafeBytes {
        Darwin.send(value, $0.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      }
      if count > 0 {
        offset += count
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try poll(value, events: Int16(POLLOUT), deadline: deadline)
        continue
      }
      throw WorkerIPCError.disconnected
    }
    try check(deadline)
  }

  func writeCaptureFrame(_ bytes: Data, deadline: ContinuousClock.Instant) throws {
    guard bytes.count <= WorkerCaptureFrameCodec.maximumFrameBytes else {
      throw WorkerIPCError.limitExceeded
    }
    guard bytes.count >= 4 else { throw CaptureFault.malformed }
    let payload = try WorkerCaptureFrameCodec.payloadLength(Data(bytes.prefix(4)), request: false)
    guard bytes.count == payload + 4 else { throw CaptureFault.malformed }
    let value = try fd()
    var offset = 0
    while offset < bytes.count {
      try check(deadline)
      let count = bytes.withUnsafeBytes {
        Darwin.send(value, $0.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      }
      if count > 0 {
        offset += count
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try poll(value, events: Int16(POLLOUT), deadline: deadline)
        continue
      }
      throw WorkerIPCError.disconnected
    }
    try check(deadline)
  }

  func writeCaptureRequest(_ bytes: Data, deadline: ContinuousClock.Instant) throws {
    guard bytes.count <= WorkerCaptureFrameCodec.requestBytes + 4 else {
      throw WorkerIPCError.limitExceeded
    }
    guard bytes.count == WorkerCaptureFrameCodec.requestBytes + 4 else {
      throw CaptureFault.malformed
    }
    _ = try WorkerCaptureFrameCodec.payloadLength(Data(bytes.prefix(4)), request: true)
    let value = try fd()
    var offset = 0
    while offset < bytes.count {
      try check(deadline)
      let count = bytes.withUnsafeBytes {
        Darwin.send(value, $0.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      }
      if count > 0 {
        offset += count
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try poll(value, events: Int16(POLLOUT), deadline: deadline)
        continue
      }
      throw WorkerIPCError.disconnected
    }
    try check(deadline)
  }

  // Only an explicitly opted-in server invokes negotiation. Its first v1
  // payload still delegates to the exact ordinary handler and32-request budget.
  func readCaptureNegotiation(deadline: ContinuousClock.Instant) throws -> WorkerCaptureIncoming {
    let header = try read(4, deadline: deadline)
    let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    if count == WorkerFrameCodec.requestPayloadBytes {
      return .legacy(try read(Int(count), deadline: deadline))
    }
    let length = try WorkerCaptureFrameCodec.payloadLength(header, request: true)
    return .capture(header + (try read(length, deadline: deadline)))
  }

  func readCaptureFrame(request: Bool, deadline: ContinuousClock.Instant) throws -> Data {
    let header = try read(4, deadline: deadline)
    let length = try WorkerCaptureFrameCodec.payloadLength(header, request: request)
    return header + (try read(length, deadline: deadline))
  }

  func readFrame(deadline: ContinuousClock.Instant) throws -> Data {
    let header = try read(4, deadline: deadline)
    let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard size <= WorkerFrameCodec.maximumPayloadBytes else { throw WorkerIPCError.limitExceeded }
    guard
      size == WorkerFrameCodec.requestPayloadBytes || size == WorkerFrameCodec.responsePayloadBytes
    else { throw WorkerIPCError.malformedFrame }
    return try read(Int(size), deadline: deadline)
  }

  private func read(_ count: Int, deadline: ContinuousClock.Instant) throws -> Data {
    let value = try fd()
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      try check(deadline)
      let received = bytes.withUnsafeMutableBytes {
        Darwin.recv(value, $0.baseAddress?.advanced(by: offset), count - offset, 0)
      }
      if received > 0 {
        offset += received
        continue
      }
      if received == 0 { throw WorkerIPCError.disconnected }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        try poll(value, events: Int16(POLLIN), deadline: deadline)
        continue
      }
      throw WorkerIPCError.posix(errno)
    }
    try check(deadline)
    return Data(bytes)
  }
}
