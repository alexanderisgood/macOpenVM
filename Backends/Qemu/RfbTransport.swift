// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation

/// All parsing, event callbacks, writes and actual close stay on one queue.
/// The lock only publishes fd/closed for cancellation's shutdown. Sources retain
/// this owner until cancellation handlers drain; a recycled fd is never observed.
final class RfbTransport: @unchecked Sendable {
  private struct Write {
    let bytes: Data
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, Error>?
    var offset = 0
  }
  private let socketURL: URL
  private let expectedIdentity: RFBEndpointIdentity?
  private let timeout: Duration
  private let queue = DispatchQueue(label: "local.macOpenVM.rfb", qos: .userInitiated)
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var closed = false
  private var failure: RFBClientError?
  private var identity: RFBEndpointIdentity?
  private var decoder = RfbDecoder()
  private let epoch: UUID
  private var sequence: UInt64 = 0
  private var connected = false
  // FIFO entries identify requests issued for prefetch. Only early mode can
  // hold two; the default and after-frame mode still permit exactly one.
  private var requests: [Bool] = []
  private var requestPending: Bool { !requests.isEmpty }
  private var pendingWasPrefetch: Bool { requests.first == true }
  private let prefetchFrames: Bool
  private let prefetchAfterHeader: Bool
  private var prefetchStarted = false
  private var discardPendingPrefetch = false
  private var readyFrame: RFBFrame?
  private var incrementalRequest = true
  private var incompleteUpdates = 0
  private var connectWaiter: CheckedContinuation<Void, Error>?
  private var frameWaiter: CheckedContinuation<RFBFrame, Error>?
  private var writes: [Write] = []
  private var queuedBytes = 0
  private var readSource: (any DispatchSourceRead)?
  private var writeSource: (any DispatchSourceWrite)?
  private var readToken: UUID?
  private var writeToken: UUID?
  private var messageTimer: (any DispatchSourceTimer)?
  private var messageToken: UUID?
  private var messageDeadline: ContinuousClock.Instant?
  private var outputTimer: (any DispatchSourceTimer)?
  private var outputToken: UUID?
  private var sourceCount = 0
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var receiveBuffer = [UInt8](repeating: 0, count: 65_536)

  init(
    socketURL: URL, expectedIdentity: RFBEndpointIdentity?, timeout: Duration, epoch: UUID,
    prefetchFrames: Bool = false, prefetchAfterHeader: Bool = false
  ) {
    self.socketURL = socketURL
    self.expectedIdentity = expectedIdentity
    self.timeout = timeout
    self.epoch = epoch
    self.prefetchFrames = prefetchFrames
    self.prefetchAfterHeader = prefetchFrames && prefetchAfterHeader
  }
  deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

  func connect() async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        var installed = false
        do {
          if let failure = self.failure {
            continuation.resume(throwing: failure)
            return
          }
          guard self.connectWaiter == nil, !self.connected else {
            throw RFBClientError.alreadyConnected
          }
          self.connectWaiter = continuation
          installed = true
          try self.open(deadline: deadline)
          self.armMessageDeadline(deadline)
          self.startReadSource()
        } catch {
          if !installed { continuation.resume(throwing: error) }
          self.fail(error)
        }
      }
    }
  }

  func nextFrame(incremental: Bool) async throws -> RFBFrame {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        var installed = false
        do {
          _ = try self.fd()
          guard self.connected else { throw RFBClientError.notConnected }
          guard self.frameWaiter == nil else { throw RFBClientError.busy }
          if !incremental { self.readyFrame = nil }
          if let frame = self.readyFrame {
            self.readyFrame = nil
            self.incompleteUpdates = 0
            // Resume neither decoding nor another request while a ready frame
            // is unconsumed. Removing it permits exactly one next wire request.
            try self.requestFrame(incremental: true, prefetched: true)
            continuation.resume(returning: frame)
            return
          }
          self.frameWaiter = continuation
          installed = true
          self.incompleteUpdates = 0
          self.incrementalRequest = incremental
          if self.requestPending {
            guard self.prefetchFrames, self.pendingWasPrefetch else { throw RFBClientError.busy }
            self.discardPendingPrefetch = !incremental
          } else {
            try self.requestFrame()
          }
        } catch {
          if !installed { continuation.resume(throwing: error) }
          self.fail(error)
        }
      }
    }
  }

  func requestDesktopSize(_ size: PixelSize) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        var enqueued = false
        do {
          _ = try self.fd()
          guard self.connected else { throw RFBClientError.notConnected }
          let bytes = try self.decoder.desktopSizeRequest(size)
          try self.enqueue(bytes, deadline: deadline, continuation: continuation)
          enqueued = true
          try self.flushWrites()
        } catch {
          if !enqueued { continuation.resume(throwing: error) }
          self.fail(error)
        }
      }
    }
  }

  func sendKey(_ key: UInt32, down: Bool, deadline: ContinuousClock.Instant? = nil) async throws {
    let deadline = deadline ?? ContinuousClock.now.advanced(by: timeout)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        var enqueued = false
        do {
          _ = try self.fd()
          guard self.connected else { throw RFBClientError.notConnected }
          guard RFBKeySymbol.isSupported(key) else { throw RFBClientError.unsupportedKey }
          let bytes = Data([
            4, down ? 1 : 0, 0, 0, UInt8(truncatingIfNeeded: key >> 24),
            UInt8(truncatingIfNeeded: key >> 16), UInt8(truncatingIfNeeded: key >> 8),
            UInt8(truncatingIfNeeded: key),
          ])
          try self.enqueue(bytes, deadline: deadline, continuation: continuation)
          enqueued = true
          try self.flushWrites()
        } catch {
          if !enqueued { continuation.resume(throwing: error) }
          self.fail(error)
        }
      }
    }
  }

  func pointerIsRelative() async -> Bool? {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: self.decoder.relativePointer) }
    }
  }

  func sendPointer(
    x: UInt16, y: UInt16, buttons: UInt8, deadline: ContinuousClock.Instant, relative: Bool = false
  )
    async throws
  {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        var enqueued = false
        do {
          _ = try self.fd()
          guard self.connected else { throw RFBClientError.notConnected }
          guard
            self.decoder.relativePointer == relative
              || (!relative && self.decoder.relativePointer == nil)
          else {
            throw RFBClientError.pointerModeChanged
          }
          let bytes = Data([
            5, buttons, UInt8(x >> 8), UInt8(truncatingIfNeeded: x),
            UInt8(y >> 8), UInt8(truncatingIfNeeded: y),
          ])
          try self.enqueue(bytes, deadline: deadline, continuation: continuation)
          enqueued = true
          try self.flushWrites()
        } catch {
          if !enqueued { continuation.resume(throwing: error) }
          if error as? RFBClientError == .pointerModeChanged { return }
          self.fail(error)
        }
      }
    }
  }

  func signalClose() {
    lock.lock()
    closed = true
    if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    lock.unlock()
    queue.async { self.fail(RFBClientError.closed) }
  }

  func close() async {
    signalClose()
    await withCheckedContinuation { continuation in
      queue.async {
        self.closeWaiters.append(continuation)
        self.finishClose()
      }
    }
  }

  private func fd() throws -> Int32 {
    lock.lock()
    let value = descriptor
    let unavailable = closed
    lock.unlock()
    guard !unavailable, value >= 0 else { throw failure ?? RFBClientError.closed }
    return value
  }

  private func open(deadline: ContinuousClock.Instant) throws {
    let captured = try endpoint()
    guard expectedIdentity == nil || expectedIdentity == captured else {
      throw RFBClientError.unsafeSocket
    }
    let value = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard value >= 0 else { throw RFBClientError.posix(errno) }
    lock.lock()
    if closed {
      lock.unlock()
      Darwin.close(value)
      throw RFBClientError.closed
    }
    descriptor = value
    lock.unlock()
    guard fcntl(value, F_SETFL, O_NONBLOCK) == 0, fcntl(value, F_SETFD, FD_CLOEXEC) == 0 else {
      throw RFBClientError.posix(errno)
    }
    var noSignal: Int32 = 1
    guard
      setsockopt(value, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else {
      throw RFBClientError.posix(errno)
    }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
    }
    guard ContinuousClock.now < deadline else { throw RFBClientError.deadlineExceeded }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result != 0 {
      guard errno == EINPROGRESS || errno == EAGAIN else { throw RFBClientError.posix(errno) }
      while true {
        _ = try fd()
        guard ContinuousClock.now < deadline else { throw RFBClientError.deadlineExceeded }
        var item = pollfd(fd: value, events: Int16(POLLOUT), revents: 0)
        let polled = Darwin.poll(&item, 1, 10)
        if polled < 0 {
          if errno == EINTR { continue }
          throw RFBClientError.posix(errno)
        }
        if polled > 0 { break }
      }
      var error: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(value, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
        throw RFBClientError.posix(error == 0 ? errno : error)
      }
    }
    var user: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(value, &user, &group) == 0, user == geteuid(), try endpoint() == captured,
      ContinuousClock.now < deadline
    else { throw RFBClientError.unsafeSocket }
    // Darwin's small default local-socket receive queue fragments native raw
    // frames into thousands of wakeups. This is a bounded performance hint
    // after peer/endpoint verification; parser and per-callback limits stay
    // unchanged, and hosts that decline it retain the ordinary connection.
    var receiveCapacity: Int32 = 262_144
    _ = setsockopt(
      value, SOL_SOCKET, SO_RCVBUF, &receiveCapacity, socklen_t(MemoryLayout<Int32>.size))
    identity = captured
  }

  private func endpoint() throws -> RFBEndpointIdentity {
    let path = socketURL.path
    guard socketURL.isFileURL, socketURL.host == nil || socketURL.host == "",
      socketURL.query == nil,
      socketURL.fragment == nil, path.hasPrefix("/"), path.utf8.count <= 103,
      !path.utf8.contains(where: { $0 < 32 || $0 == 127 })
    else { throw RFBClientError.unsafeSocket }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw RFBClientError.unsafeSocket
    }
    var ancestor = ""
    for part in parts.dropFirst().dropLast() {
      ancestor += "/" + part
      var info = stat()
      guard lstat(ancestor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == 0 || info.st_uid == geteuid(),
        info.st_mode & 0o022 == 0
          || (ancestor == "/private/tmp" && info.st_uid == 0 && info.st_mode & S_ISVTX != 0)
      else { throw RFBClientError.unsafeSocket }
    }
    var parent = stat()
    var info = stat()
    guard lstat(socketURL.deletingLastPathComponent().path, &parent) == 0,
      parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(),
      parent.st_mode & 0o777 == 0o700,
      lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(),
      info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_mode & 0o600 == 0o600,
      info.st_mode & 0o7000 == 0
    else { throw RFBClientError.unsafeSocket }
    return RFBEndpointIdentity(
      parentDevice: parent.st_dev, parentInode: parent.st_ino,
      socketDevice: info.st_dev, socketInode: info.st_ino)
  }

  private func startReadSource() {
    let token = UUID()
    readToken = token
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    readSource = source
    sourceCount += 1
    source.setCancelHandler { [self] in
      sourceCount -= 1
      finishClose()
    }
    source.setEventHandler { [weak self] in
      guard let self, self.readToken == token else { return }
      do { try self.readAvailable() } catch { self.fail(error) }
    }
    source.activate()
  }

  private func readAvailable() throws {
    let value = try fd()
    // Bound each callback so duplex writes/cancellation cannot starve behind frames.
    for _ in 0..<4 {
      let count = receiveBuffer.withUnsafeMutableBytes {
        Darwin.recv(value, $0.baseAddress, $0.count, 0)
      }
      if count == 0 { throw RFBClientError.disconnected }
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        throw RFBClientError.posix(errno)
      }
      if connected, messageTimer == nil {
        armMessageDeadline(ContinuousClock.now.advanced(by: timeout))
      }
      try checkMessageDeadline()
      var actions = try receiveBuffer.withUnsafeBytes {
        try decoder.feedBorrowed(UnsafeRawBufferPointer(rebasing: $0.prefix(count)))
      }
      var actionCount = 0
      while !actions.isEmpty {
        actionCount += actions.count
        guard actionCount <= 256 else { throw RFBClientError.limitExceeded }
        for action in actions {
          switch action {
          case .send(let data): try enqueue(data)
          case .ready:
            try checkMessageDeadline()
            connected = true
            clearMessageDeadline()
            let waiter = connectWaiter
            connectWaiter = nil
            waiter?.resume()
          case .messageComplete:
            try checkMessageDeadline()
            clearMessageDeadline()
          case .messageStarted:
            if messageTimer == nil {
              armMessageDeadline(ContinuousClock.now.advanced(by: timeout))
            }
          case .updateStarted:
            if prefetchAfterHeader, prefetchStarted, decoder.initialized,
              frameWaiter != nil, readyFrame == nil, requests.count == 1,
              pendingWasPrefetch, !discardPendingPrefetch
            {
              // Overlap server encoding/transfer with this response's body.
              // No early request without an active consumer or while a ready
              // frame is waiting. requestFrame checks the same pinned endpoint.
              try requestFrame(incremental: true, prefetched: true, early: true)
            }
          case .updateComplete(let resized):
            try checkMessageDeadline()
            clearMessageDeadline()
            if resized { readyFrame = nil }
            if !requestPending {
              guard resized else { throw RFBClientError.unexpectedMessage }
              continue
            }
            let wasPrefetch = requests.removeFirst()
            if discardPendingPrefetch {
              // A nonincremental consumer request arrived after the old
              // prefetch went out. Complete and discard that response before
              // issuing one fresh request; never overlap wire requests.
              discardPendingPrefetch = false
              guard requests.isEmpty else { throw RFBClientError.unexpectedMessage }
              try requestFrame(incremental: false)
            } else if resized || !decoder.initialized {
              incompleteUpdates += 1
              guard incompleteUpdates <= 16 else { throw RFBClientError.limitExceeded }
              // A resize can overtake an already issued request for the old
              // geometry. Drain it before requesting full new coverage.
              if requests.isEmpty {
                try requestFrame(prefetched: wasPrefetch && frameWaiter == nil)
              }
            } else {
              guard sequence < UInt64.max else { throw RFBClientError.identifierExhausted }
              sequence += 1
              let frame = RFBFrame(
                connectionEpoch: epoch, sequence: sequence,
                size: PixelSize(width: decoder.width, height: decoder.height),
                rgbaData: decoder.pixels)
              if let waiter = frameWaiter {
                if prefetchFrames && requests.isEmpty {
                  prefetchStarted = true
                  incompleteUpdates = 0
                  // The completed frame is immutable. Request the next one
                  // on this transport queue before MainActor presentation.
                  // Keep the waiter installed until a write failure can no
                  // longer strand it; fail() still owns its error completion.
                  try requestFrame(incremental: true, prefetched: true)
                }
                frameWaiter = nil
                waiter.resume(returning: frame)
              } else {
                guard prefetchFrames, wasPrefetch, readyFrame == nil else {
                  throw RFBClientError.unexpectedMessage
                }
                readyFrame = frame
              }
            }
          }
        }
        actions = try decoder.feed(Data())
      }
      if decoder.messageInProgress, messageTimer == nil {
        armMessageDeadline(ContinuousClock.now.advanced(by: timeout))
      } else if !decoder.messageInProgress {
        clearMessageDeadline()
      }
      try flushWrites()
    }
  }

  private func requestFrame(
    incremental: Bool? = nil, prefetched: Bool = false, early: Bool = false
  ) throws {
    let maximum = early && prefetchAfterHeader ? 2 : 1
    guard requests.count < maximum, readyFrame == nil,
      frameWaiter != nil || (prefetched && prefetchFrames && prefetchStarted)
    else { throw RFBClientError.busy }
    guard let identity, try endpoint() == identity else { throw RFBClientError.unsafeSocket }
    if let incremental { incrementalRequest = incremental }
    requests.append(prefetched)
    let width = decoder.width
    let height = decoder.height
    try enqueue(
      Data([
        3, decoder.initialized && incrementalRequest ? 1 : 0, 0, 0, 0, 0,
        UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255),
      ]))
    try flushWrites()
  }

  private func enqueue(
    _ bytes: Data, deadline: ContinuousClock.Instant? = nil,
    continuation: CheckedContinuation<Void, Error>? = nil
  ) throws {
    guard writes.count < 64, bytes.count <= 4096 - queuedBytes else {
      throw RFBClientError.limitExceeded
    }
    writes.append(
      Write(
        bytes: bytes, deadline: deadline ?? ContinuousClock.now.advanced(by: timeout),
        continuation: continuation))
    queuedBytes += bytes.count
    armOutputDeadline()
  }

  private func flushWrites() throws {
    let value = try fd()
    while !writes.isEmpty {
      guard ContinuousClock.now < writes[0].deadline else { throw RFBClientError.deadlineExceeded }
      let pending = writes[0]
      let count = pending.bytes.withUnsafeBytes {
        Darwin.send(
          value, $0.baseAddress?.advanced(by: pending.offset), pending.bytes.count - pending.offset,
          0)
      }
      if count > 0 {
        writes[0].offset += count
        if writes[0].offset == writes[0].bytes.count {
          let completed = writes.removeFirst()
          queuedBytes -= completed.bytes.count
          completed.continuation?.resume()
          armOutputDeadline()
        }
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        startWriteSource()
        return
      }
      throw RFBClientError.disconnected
    }
    writeToken = nil
    writeSource?.cancel()
    writeSource = nil
  }

  private func startWriteSource() {
    guard writeSource == nil else { return }
    let token = UUID()
    writeToken = token
    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
    writeSource = source
    sourceCount += 1
    source.setCancelHandler { [self] in
      sourceCount -= 1
      finishClose()
    }
    source.setEventHandler { [weak self] in
      guard let self, self.writeToken == token else { return }
      do { try self.flushWrites() } catch { self.fail(error) }
    }
    source.activate()
  }

  private func armMessageDeadline(_ deadline: ContinuousClock.Instant) {
    clearMessageDeadline()
    let token = UUID()
    messageToken = token
    messageDeadline = deadline
    let timer = DispatchSource.makeTimerSource(queue: queue)
    messageTimer = timer
    schedule(timer, deadline: deadline)
    sourceCount += 1
    timer.setCancelHandler { [self] in
      sourceCount -= 1
      finishClose()
    }
    timer.setEventHandler { [weak self] in
      guard let self, self.messageToken == token else { return }
      self.fail(RFBClientError.deadlineExceeded)
    }
    timer.activate()
  }

  private func clearMessageDeadline() {
    messageToken = nil
    messageDeadline = nil
    messageTimer?.cancel()
    messageTimer = nil
  }

  private func checkMessageDeadline() throws {
    if let messageDeadline, ContinuousClock.now >= messageDeadline {
      throw RFBClientError.deadlineExceeded
    }
  }

  private func armOutputDeadline() {
    outputToken = nil
    outputTimer?.cancel()
    outputTimer = nil
    guard let first = writes.first else { return }
    let token = UUID()
    outputToken = token
    let timer = DispatchSource.makeTimerSource(queue: queue)
    outputTimer = timer
    schedule(timer, deadline: first.deadline)
    sourceCount += 1
    timer.setCancelHandler { [self] in
      sourceCount -= 1
      finishClose()
    }
    timer.setEventHandler { [weak self] in
      guard let self, self.outputToken == token else { return }
      self.fail(RFBClientError.deadlineExceeded)
    }
    timer.activate()
  }

  private func schedule(_ timer: any DispatchSourceTimer, deadline: ContinuousClock.Instant) {
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    timer.schedule(deadline: .now() + max(0, seconds), leeway: .milliseconds(1))
  }

  private func fail(_ error: Error) {
    guard failure == nil else {
      finishClose()
      return
    }
    failure = error as? RFBClientError ?? .malformedMessage
    lock.lock()
    closed = true
    if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    lock.unlock()
    readToken = nil
    writeToken = nil
    readSource?.cancel()
    writeSource?.cancel()
    readSource = nil
    writeSource = nil
    clearMessageDeadline()
    outputToken = nil
    outputTimer?.cancel()
    outputTimer = nil
    connectWaiter?.resume(throwing: failure!)
    connectWaiter = nil
    frameWaiter?.resume(throwing: failure!)
    frameWaiter = nil
    readyFrame = nil
    prefetchStarted = false
    requests.removeAll()
    discardPendingPrefetch = false
    for write in writes { write.continuation?.resume(throwing: failure!) }
    writes.removeAll()
    queuedBytes = 0
    finishClose()
  }

  private func finishClose() {
    guard failure != nil, sourceCount == 0 else { return }
    lock.lock()
    let old = descriptor
    descriptor = -1
    lock.unlock()
    if old >= 0 { Darwin.close(old) }
    decoder = RfbDecoder()
    let waiters = closeWaiters
    closeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}
