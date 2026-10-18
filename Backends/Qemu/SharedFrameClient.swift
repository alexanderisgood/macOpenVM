// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation
import SharedFrameWire

/// Dedicated host output, never guest memory. Retain this object until every
/// GPU operation borrowing its mapping has actually completed.
public final class SharedFrameMapping: @unchecked Sendable {
  public let byteCount: Int
  private let address: UnsafeMutableRawPointer
  private let descriptor: Int32

  fileprivate init(taking descriptor: Int32, byteCount: Int) throws {
    var keep = false
    defer { if !keep { Darwin.close(descriptor) } }
    var info = stat()
    guard byteCount > 0, byteCount <= 67_108_864,
      byteCount % Int(getpagesize()) == 0,
      fstat(descriptor, &info) == 0, info.st_size == byteCount,
      info.st_mode & S_IFMT == 0, info.st_mode & 0o777 == 0o600,
      info.st_uid == geteuid(), info.st_nlink == 0,
      mvo_sf_is_readonly_shared_memory(descriptor, UInt64(byteCount)) == 1
    else { throw RFBClientError.unsafeSocket }
    guard let pointer = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0),
      pointer != MAP_FAILED
    else { throw RFBClientError.posix(errno) }
    self.descriptor = descriptor
    self.byteCount = byteCount
    address = pointer
    keep = true
  }
  deinit {
    munmap(address, byteCount)
    Darwin.close(descriptor)
  }
  /// The pointer belongs to this mapping. GPU imports must retain the mapping
  /// through their deallocator/completion lifetime; it must never be written.
  public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
    try body(UnsafeRawBufferPointer(start: address, count: byteCount))
  }
}

public struct SharedFrame: Sendable {
  public let connectionEpoch: UUID
  public let streamEpoch: UUID
  public let sequence: UInt64
  public let generation: UInt64
  public let size: PixelSize
  public let rowBytes: Int
  public let sentNanoseconds: UInt64
  public let mapping: SharedFrameMapping
  fileprivate let token: UUID
}

/// One admitted endpoint and one outstanding frame. Acknowledgement is explicit
/// after actual consumer GPU completion, never on cancellation or deinit.
public final class SharedFrameClient: @unchecked Sendable {
  public let connectionEpoch: UUID
  private let socketURL: URL
  private let expectedIdentity: RFBEndpointIdentity
  private let queue = DispatchQueue(label: "local.macOpenVM.shared-frame", qos: .userInitiated)
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var closed = false
  private var source: (any DispatchSourceRead)?
  private var sourceDrained = true
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var receive = MVOSharedFrameReceive()
  private var deadline: ContinuousClock.Instant?
  private var timer: (any DispatchSourceTimer)?
  private var connectWaiter: CheckedContinuation<Void, Error>?
  private var frameWaiter: CheckedContinuation<SharedFrame, Error>?
  private var ready = false
  // A surface can retire while the consumer is copying its last frame. Keep
  // that terminal cause for the later ACK instead of mislabelling it as a
  // protocol violation after fail() has cleared the outstanding token.
  private var terminalError: (any Error)?
  private var streamEpoch: UUID?
  private var mappings: [SharedFrameMapping] = []
  private var geometry: (size: PixelSize, stride: Int, bytes: Int)?
  private var sequence: UInt64 = 0
  private var generation: UInt64 = 0
  private var outstanding: UUID?

  public init(socketURL: URL, expectedIdentity: RFBEndpointIdentity, connectionEpoch: UUID) {
    self.socketURL = socketURL
    self.expectedIdentity = expectedIdentity
    self.connectionEpoch = connectionEpoch
    mvo_sf_receive_init(&receive)
  }
  deinit {
    mvo_sf_receive_clear(&receive)
    if descriptor >= 0 { Darwin.close(descriptor) }
  }

  public func connect() async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
        queue.async { [self] in
          guard connectWaiter == nil, descriptor < 0, !isClosed else {
            waiter.resume(throwing: RFBClientError.alreadyConnected)
            return
          }
          connectWaiter = waiter
          do {
            try open()
            armDeadline()
            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source = reader
            sourceDrained = false
            reader.setEventHandler { [weak self] in
              guard let self else { return }
              do { try self.readAvailable() } catch { self.fail(error) }
            }
            reader.setCancelHandler { [self] in
              sourceDrained = true
              finishClose()
            }
            reader.activate()
          } catch { fail(error) }
        }
      }
    } onCancel: {
      signalClose()
    }
  }

  public func nextFrame() async throws -> SharedFrame {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { waiter in
        queue.async { [self] in
          guard ready, !isClosed else {
            waiter.resume(throwing: terminalError ?? RFBClientError.closed)
            return
          }
          guard frameWaiter == nil, outstanding == nil else {
            waiter.resume(throwing: RFBClientError.busy)
            return
          }
          frameWaiter = waiter
          do {
            var header = MVOSharedFrameHeader()
            header.kind = UInt32(MVO_SF_REQUEST)
            setEpoch(&header, streamEpoch)
            try send(header)
          } catch { fail(error) }
        }
      }
    } onCancel: {
      signalClose()
    }
  }

  public func acknowledge(_ frame: SharedFrame) async throws {
    try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        guard !isClosed else {
          waiter.resume(throwing: terminalError ?? RFBClientError.closed)
          return
        }
        guard outstanding == frame.token,
          frame.connectionEpoch == connectionEpoch, frame.streamEpoch == streamEpoch,
          frame.sequence == sequence
        else {
          waiter.resume(throwing: RFBClientError.unexpectedMessage)
          return
        }
        do {
          var header = MVOSharedFrameHeader()
          // Every field was admitted before this file-private immutable frame
          // was constructed. Rebuild the same canonical ACK without retaining
          // and decoding another copy of its already validated wire header.
          header.kind = UInt32(MVO_SF_ACK)
          setEpoch(&header, frame.streamEpoch)
          header.sequence = frame.sequence
          header.generation = frame.generation
          header.width = UInt32(frame.size.width)
          header.height = UInt32(frame.size.height)
          header.row_bytes = UInt32(frame.rowBytes)
          header.mapped_bytes = UInt32(frame.mapping.byteCount)
          header.slot = UInt32((frame.sequence - 1) % 2)
          header.format = 1
          header.sent_ns = frame.sentNanoseconds
          try send(header)
          outstanding = nil
          waiter.resume()
        } catch {
          fail(error)
          waiter.resume(throwing: error)
        }
      }
    }
  }

  public func close() async {
    signalClose()
    await withCheckedContinuation { waiter in
      queue.async { [self] in
        closeWaiters.append(waiter)
        finishClose()
      }
    }
  }
  private var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }
  private func signalClose() {
    lock.lock()
    if !closed {
      closed = true
      if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    }
    lock.unlock()
    queue.async { [self] in fail(RFBClientError.closed) }
  }
  private func fail(_ error: Error) {
    let cause = terminalError ?? error
    terminalError = cause
    lock.lock()
    closed = true
    lock.unlock()
    ready = false
    connectWaiter?.resume(throwing: cause)
    connectWaiter = nil
    frameWaiter?.resume(throwing: cause)
    frameWaiter = nil
    timer?.cancel()
    timer = nil
    deadline = nil
    source?.cancel()
    source = nil
    mvo_sf_receive_clear(&receive)
    mappings.removeAll()
    geometry = nil
    outstanding = nil
    finishClose()
  }
  private func finishClose() {
    guard isClosed, sourceDrained else { return }
    lock.lock()
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
    lock.unlock()
    let waiters = closeWaiters
    closeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
  private func armDeadline() {
    guard deadline == nil else { return }
    let end = ContinuousClock.now + .seconds(3)
    deadline = end
    let clock = DispatchSource.makeTimerSource(queue: queue)
    timer = clock
    clock.schedule(deadline: .now() + 3)
    clock.setEventHandler { [weak self] in
      guard let self, self.deadline == end else { return }
      self.fail(RFBClientError.deadlineExceeded)
    }
    clock.activate()
  }
  #if DEBUG
    /// Numeric state only, for generated packet/deadline regression fixtures.
    func receiveAssemblyStateForValidation() async
      -> (receivedBytes: Int, deadline: ContinuousClock.Instant?)
    {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          continuation.resume(returning: (Int(receive.used), deadline))
        }
      }
    }
  #endif

  private func readAvailable() throws {
    guard !isClosed else { throw RFBClientError.closed }
    for _ in 0..<8 {
      let result = mvo_sf_receive(descriptor, &receive)
      if result < 0 { throw RFBClientError.posix(-result) }
      // Complete headers are consumed in this callback. Only partial packets
      // need a new assembly timer; an existing absolute deadline still applies
      // when this read completes a previously partial header.
      if result == 0, receive.used > 0 { armDeadline() }
      if let deadline, ContinuousClock.now >= deadline { throw RFBClientError.deadlineExceeded }
      if result == 0 { return }
      var header = MVOSharedFrameHeader()
      let decoded = withUnsafeBytes(of: receive.bytes) {
        mvo_sf_decode($0.bindMemory(to: UInt8.self).baseAddress, &header)
      }
      guard decoded == 1 else { throw RFBClientError.malformedMessage }
      try handle(header)
      mvo_sf_receive_clear(&receive)
      timer?.cancel()
      timer = nil
      deadline = nil
    }
  }
  private func handle(_ h: MVOSharedFrameHeader) throws {
    let epoch = withUnsafeBytes(of: h.epoch) { UUID(uuid: $0.load(as: uuid_t.self)) }
    guard epoch != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
      throw RFBClientError.malformedMessage
    }
    switch Int(h.kind) {
    case MVO_SF_READY:
      guard !ready, connectWaiter != nil, receive.descriptor_count == 0,
        h.sequence == 0, h.generation == 0, h.width == 0, h.height == 0,
        h.row_bytes == 0, h.mapped_bytes == 0, h.slot == 0, h.format == 0, h.sent_ns == 0
      else { throw RFBClientError.unexpectedMessage }
      streamEpoch = epoch
      ready = true
      connectWaiter?.resume()
      connectWaiter = nil
    case MVO_SF_ATTACH:
      guard ready, frameWaiter != nil, outstanding == nil, receive.descriptor_count == 2,
        h.sequence == 0, h.generation == 0, h.slot == 2, h.format == 1, h.sent_ns == 0,
        (1...8192).contains(h.width), (1...8192).contains(h.height),
        UInt64(h.width) * UInt64(h.height) <= 16_777_216,
        h.row_bytes >= h.width * 4, h.row_bytes <= h.width * 4 + 4096, h.row_bytes % 256 == 0,
        UInt64(h.mapped_bytes) >= UInt64(h.row_bytes) * UInt64(h.height),
        UInt64(h.mapped_bytes) < UInt64(h.row_bytes) * UInt64(h.height) + UInt64(getpagesize()),
        mappings.isEmpty ? epoch == streamEpoch : epoch != streamEpoch
      else { throw RFBClientError.malformedMessage }
      var pool: [SharedFrameMapping] = []
      for index in 0..<2 {
        let fd = mvo_sf_take_descriptor(&receive, index)
        guard fd >= 0 else { throw RFBClientError.malformedMessage }
        pool.append(try SharedFrameMapping(taking: fd, byteCount: Int(h.mapped_bytes)))
      }
      mappings = pool
      streamEpoch = epoch
      sequence = 0
      generation = 0
      geometry = (
        PixelSize(width: Int(h.width), height: Int(h.height)), Int(h.row_bytes), Int(h.mapped_bytes)
      )
      var ack = h
      ack.kind = UInt32(MVO_SF_ACK)
      try send(ack)
    case MVO_SF_FRAME:
      guard ready, let geometry, frameWaiter != nil, outstanding == nil,
        mappings.count == 2, receive.descriptor_count == 0, epoch == streamEpoch,
        sequence < UInt64.max, h.sequence == sequence + 1, h.generation > generation,
        h.slot == UInt32((h.sequence - 1) % 2), h.format == 1,
        Int(h.width) == geometry.size.width, Int(h.height) == geometry.size.height,
        Int(h.row_bytes) == geometry.stride, Int(h.mapped_bytes) == geometry.bytes, h.sent_ns > 0
      else { throw RFBClientError.unexpectedMessage }
      sequence = h.sequence
      generation = h.generation
      let token = UUID()
      outstanding = token
      let frame = SharedFrame(
        connectionEpoch: connectionEpoch, streamEpoch: epoch,
        sequence: sequence, generation: generation, size: geometry.size, rowBytes: geometry.stride,
        sentNanoseconds: h.sent_ns, mapping: mappings[Int(h.slot)], token: token)
      let waiter = frameWaiter
      frameWaiter = nil
      waiter?.resume(returning: frame)
    default: throw RFBClientError.unexpectedMessage
    }
  }
  private func setEpoch(_ h: inout MVOSharedFrameHeader, _ epoch: UUID?) {
    guard let epoch else { return }
    var bytes = epoch.uuid
    withUnsafeBytes(of: &bytes) { b in
      withUnsafeMutableBytes(of: &h.epoch) { $0.copyMemory(from: b) }
    }
  }
  private func send(_ h: MVOSharedFrameHeader) throws {
    guard !isClosed, try endpoint() == expectedIdentity else { throw RFBClientError.unsafeSocket }
    var header = h
    var bytes = [UInt8](repeating: 0, count: Int(MVO_SF_BYTES))
    mvo_sf_encode(&header, &bytes)
    let count = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    guard count == bytes.count else { throw RFBClientError.disconnected }
  }
  private func open() throws {
    guard try endpoint() == expectedIdentity else { throw RFBClientError.unsafeSocket }
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
    else { throw RFBClientError.posix(errno) }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
    }
    let result = withUnsafePointer(to: &address) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw RFBClientError.posix(errno) }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(value, &uid, &gid) == 0, uid == geteuid(), try endpoint() == expectedIdentity
    else { throw RFBClientError.unsafeSocket }
  }
  private func endpoint() throws -> RFBEndpointIdentity {
    let path = socketURL.path
    guard socketURL.isFileURL, socketURL.host == nil || socketURL.host == "",
      socketURL.query == nil, socketURL.fragment == nil, path.hasPrefix("/"),
      path.utf8.count <= 103, !path.utf8.contains(where: { $0 < 32 || $0 == 127 })
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
    var socket = stat()
    guard lstat(socketURL.deletingLastPathComponent().path, &parent) == 0,
      parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(),
      parent.st_mode & 0o777 == 0o700,
      lstat(path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
      socket.st_uid == geteuid(), socket.st_nlink == 1, socket.st_mode & 0o077 == 0,
      socket.st_mode & 0o600 == 0o600, socket.st_mode & 0o7000 == 0
    else { throw RFBClientError.unsafeSocket }
    return RFBEndpointIdentity(
      parentDevice: parent.st_dev, parentInode: parent.st_ino,
      socketDevice: socket.st_dev, socketInode: socket.st_ino)
  }
}
