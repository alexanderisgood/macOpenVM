// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation
import Metal
import SharedFrameWire

#if MVO_HDR_STANDALONE
  import Qemu
#endif

public struct HDRFrameConsumerCapabilities: Sendable {
  let deviceID: UInt64
  let minimumAlignment: UInt32
  let maximumBufferBytes: UInt64
  public init(device: any MTLDevice) throws {
    let alignment = device.minimumLinearTextureAlignment(for: .rgba16Float)
    guard device.hasUnifiedMemory, alignment > 0, alignment <= 4096,
      alignment & (alignment - 1) == 0, device.maxBufferLength >= getpagesize()
    else { throw RFBClientError.unsafeSocket }
    deviceID = device.registryID
    minimumAlignment = UInt32(alignment)
    maximumBufferBytes = UInt64(device.maxBufferLength)
  }
}

/// An independently owned, read-only dedicated HOST snapshot, never a guest
/// resource FD. Its real mapping remains retained through GPU completion.
public final class HDRFrameMapping: @unchecked Sendable {
  public let byteCount: Int
  fileprivate let identity: HDRMappingIdentity
  private let address: UnsafeMutableRawPointer
  private let descriptor: Int32
  fileprivate init(taking descriptor: Int32, byteCount: Int) throws {
    var kept = false
    defer { if !kept { Darwin.close(descriptor) } }
    var info = stat()
    guard byteCount > 0, byteCount <= 67_108_864, byteCount % Int(getpagesize()) == 0,
      fstat(descriptor, &info) == 0, info.st_size == byteCount,
      info.st_mode & S_IFMT == 0, info.st_mode & 0o777 == 0o600,
      info.st_uid == geteuid(), info.st_nlink == 0,
      mvo_sf_is_readonly_shared_memory(descriptor, UInt64(byteCount)) == 1
    else { throw RFBClientError.unsafeSocket }
    guard let mapped = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0),
      mapped != MAP_FAILED
    else {
      throw RFBClientError.posix(errno)
    }
    address = mapped
    self.descriptor = descriptor
    self.byteCount = byteCount
    identity = HDRMappingIdentity(ownerID: UUID(), byteCount: byteCount)
    kept = true
  }
  deinit {
    munmap(address, byteCount)
    Darwin.close(descriptor)
  }
  public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
    try body(UnsafeRawBufferPointer(start: address, count: byteCount))
  }
  fileprivate func hasDistinctBacking(from other: HDRFrameMapping) -> Bool {
    byteCount == other.byteCount
      && mvo_hdr_readonly_slots_distinct(descriptor, other.descriptor, UInt64(byteCount)) == 1
  }
}

public struct HDRFrameCopyTiming: Sendable { public let gpuMilliseconds: Double? }
public struct HDRSharedFrame: Sendable {
  public let inputConnectionEpoch: UUID
  public let transportConnectionEpoch: UUID
  public let message: HDRFrameMessage
  public let mapping: HDRFrameMapping
  private let copy:
    @Sendable (any MTLTexture, any MTLCommandQueue) async throws -> HDRFrameCopyTiming
  fileprivate init(
    input: UUID, transport: UUID, message: HDRFrameMessage, mapping: HDRFrameMapping,
    copy:
      @escaping @Sendable (any MTLTexture, any MTLCommandQueue) async throws -> HDRFrameCopyTiming
  ) {
    inputConnectionEpoch = input
    transportConnectionEpoch = transport
    self.message = message
    self.mapping = mapping
    self.copy = copy
  }
  /// Encodes and commits the real FP16 import->private GPU cache blit. There is
  /// deliberately NO public acknowledge(Boolean/message/frame) operation.
  /// ACK is emitted only by this actual command's successful completion.
  /// The caller reserves destination for this copy until the awaited result;
  /// presentation may read it after success and must not mutate it in flight.
  public func copyToPrivateCache(_ destination: any MTLTexture, commands: any MTLCommandQueue)
    async throws -> HDRFrameCopyTiming
  { try await copy(destination, commands) }
}

/// Opt-in HDR-only socket. No existing SDR socket, launch route or monitor
/// capability is selected by constructing this client. The owner must admit
/// this separate endpoint through its current runtime/launch route first.
public final class HDRFrameClient: @unchecked Sendable {
  /// Immutable references transferred to the serial copy executor. Metal's
  /// imported protocols do not carry Sendable, so this narrow owner records
  /// the actual discipline: encoding happens only on queue, the destination
  /// is reserved to this copy until its awaited completion, and the submitted
  /// command retains this owner through the real native completion callback.
  private final class CopyResources: @unchecked Sendable {
    let destination: any MTLTexture
    let commands: any MTLCommandQueue
    init(destination: any MTLTexture, commands: any MTLCommandQueue) {
      self.destination = destination
      self.commands = commands
    }
  }
  public let inputConnectionEpoch: UUID
  public let transportConnectionEpoch = UUID()
  private enum Stage { case offer, ready, records }
  private let socketURL: URL
  private let expectedIdentity: RFBEndpointIdentity
  private let capabilities: HDRFrameConsumerCapabilities
  private let queue = DispatchQueue(label: "local.macOpenVM.hdr-frame", qos: .userInitiated)
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var closed = false
  private var source: (any DispatchSourceRead)?
  private var sourceDrained = true
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var receiver = MVOHDRReceive()
  private var stage = Stage.offer
  private var selection: MVOHDRControl?
  private var reducer: HDRFrameConsumerState?
  private var mappings: [HDRFrameMapping] = []
  private var connectWaiter: CheckedContinuation<Void, Error>?
  private var frameWaiter: CheckedContinuation<HDRSharedFrame, Error>?
  private var copyWaiter: CheckedContinuation<HDRFrameCopyTiming, Error>?
  private var copyStarted: HDRBorrow?
  private var terminalError: (any Error)?
  private var deadline: ContinuousClock.Instant?
  private var timer: (any DispatchSourceTimer)?

  public init(
    socketURL: URL, expectedIdentity: RFBEndpointIdentity, inputConnectionEpoch: UUID,
    capabilities: HDRFrameConsumerCapabilities
  ) {
    self.socketURL = socketURL
    self.expectedIdentity = expectedIdentity
    self.inputConnectionEpoch = inputConnectionEpoch
    self.capabilities = capabilities
    mvo_hdr_receive_init(&receiver, Int(MVO_HDR_CONTROL_BYTES), false)
  }
  deinit {
    mvo_hdr_receive_clear(&receiver)
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

  public func nextFrame() async throws -> HDRSharedFrame {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { waiter in
        queue.async { [self] in
          guard !isClosed, connectWaiter == nil, reducer?.phase == .idle else {
            waiter.resume(throwing: terminalError ?? RFBClientError.busy)
            return
          }
          guard frameWaiter == nil else {
            waiter.resume(throwing: RFBClientError.busy)
            return
          }
          frameWaiter = waiter
          do {
            guard let action = try reducer?.requestFrame(), case .send(let send) = action else {
              throw RFBClientError.unexpectedMessage
            }
            try transmit(send.bytes)
            // Applied synchronously before the read handler can deliver a fast
            // peer response; no async continuation reorders these state events.
            try reducer?.sendCompleted(send)
          } catch { fail(error) }
        }
      }
    } onCancel: {
      signalClose()
    }
  }

  private func copyFrame(
    _ borrow: HDRBorrow, mapping: HDRFrameMapping,
    to destination: any MTLTexture, commands: any MTLCommandQueue
  ) async throws -> HDRFrameCopyTiming {
    let resources = CopyResources(destination: destination, commands: commands)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { waiter in
        queue.async { [self] in
          guard !isClosed else {
            waiter.resume(throwing: terminalError ?? RFBClientError.closed)
            return
          }
          guard reducer?.phase == .borrowed, reducer?.outstandingBorrow == borrow,
            copyStarted == nil, copyWaiter == nil, mapping.identity == borrow.mapping
          else {
            waiter.resume(throwing: RFBClientError.unexpectedMessage)
            return
          }
          copyStarted = borrow
          copyWaiter = waiter
          do {
            let destination = resources.destination
            let commands = resources.commands
            let d = borrow.message.descriptor
            let alignment = commands.device.minimumLinearTextureAlignment(for: .rgba16Float)
            guard commands.device.registryID == capabilities.deviceID,
              destination.device.registryID == capabilities.deviceID,
              destination.pixelFormat == .rgba16Float, destination.storageMode == .private,
              destination.textureType == .type2D, destination.sampleCount == 1,
              destination.width == d.width, destination.height == d.height,
              alignment > 0, alignment <= 4096, d.rowBytes % alignment == 0,
              mapping.byteCount == d.mappingBytes,
              mapping.byteCount <= commands.device.maxBufferLength
            else { throw RFBClientError.malformedMessage }
            let buffer = mapping.withUnsafeBytes { bytes -> (any MTLBuffer)? in
              guard let base = bytes.baseAddress else { return nil }
              return commands.device.makeBuffer(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: base), length: bytes.count,
                options: .storageModeShared, deallocator: { _, _ in _ = mapping })
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
              pixelFormat: .rgba16Float, width: d.width, height: d.height, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = .shaderRead
            guard let buffer,
              let texture = buffer.makeTexture(
                descriptor: desc, offset: 0, bytesPerRow: d.rowBytes),
              let command = commands.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder()
            else { throw RFBClientError.disconnected }
            blit.copy(
              from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
              sourceSize: MTLSize(width: d.width, height: d.height, depth: 1),
              to: destination, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin())
            blit.endEncoding()
            command.addCompletedHandler { [self, mapping, resources] completed in
              _ = resources
              let ok = completed.status == .completed
              let milliseconds =
                completed.gpuStartTime > 0 && completed.gpuEndTime >= completed.gpuStartTime
                ? (completed.gpuEndTime - completed.gpuStartTime) * 1000 : nil
              queue.async { [self, mapping] in
                _ = mapping
                guard !isClosed else { return }
                do {
                  guard ok else {
                    try reducer?.consumerGPUCopyFailed(borrow)
                    throw RFBClientError.disconnected
                  }
                  guard let action = try reducer?.consumerGPUCopyCompleted(borrow),
                    case .send(let send) = action
                  else {
                    throw RFBClientError.unexpectedMessage
                  }
                  try transmit(send.bytes)
                  try reducer?.sendCompleted(send)
                  clearDeadline()
                  copyStarted = nil
                  let continuation = copyWaiter
                  copyWaiter = nil
                  continuation?.resume(returning: HDRFrameCopyTiming(gpuMilliseconds: milliseconds))
                } catch { fail(error) }
              }
            }
            command.commit()
          } catch { fail(error) }
        }
      }
    } onCancel: {
      signalClose()
    }
  }

  private func readAvailable() throws {
    guard !isClosed else { throw RFBClientError.closed }
    for _ in 0..<8 {
      let result = mvo_hdr_receive(descriptor, &receiver)
      if result < 0 { throw RFBClientError.posix(-result) }
      if result == 0, receiver.used > 0 { armDeadline() }
      if let deadline, ContinuousClock.now >= deadline { throw RFBClientError.deadlineExceeded }
      if result == 0 { return }
      let bytes = withUnsafeBytes(of: receiver.bytes) {
        Data($0.prefix(Int(receiver.expected_bytes)))
      }
      if stage == .records { try handleData(bytes) } else { try handleControl(bytes) }
      mvo_hdr_receive_clear(&receiver)
    }
  }
  private func handleControl(_ bytes: Data) throws {
    guard receiver.descriptor_count == 0 else { throw RFBClientError.malformedMessage }
    var control = MVOHDRControl()
    guard
      bytes.withUnsafeBytes({ mvo_hdr_control_decode($0.baseAddress, $0.count, &control) })
        == MVO_HDR_OK
    else {
      throw RFBClientError.malformedMessage
    }
    if stage == .offer {
      var accept = MVOHDRControl()
      guard
        mvo_hdr_control_select(
          &control, UInt32(getpagesize()), capabilities.minimumAlignment,
          capabilities.maximumBufferBytes, &accept) == MVO_HDR_OK
      else { throw RFBClientError.malformedMessage }
      var out = Data(count: Int(MVO_HDR_CONTROL_BYTES))
      guard
        out.withUnsafeMutableBytes({ mvo_hdr_control_encode(&accept, $0.baseAddress, $0.count) })
          == MVO_HDR_OK
      else {
        throw RFBClientError.malformedMessage
      }
      try transmit(out)
      selection = accept
      stage = .ready
    } else {
      guard var accept = selection, mvo_hdr_control_validate_ready(&accept, &control) == MVO_HDR_OK
      else {
        throw RFBClientError.unexpectedMessage
      }
      let id = withUnsafeBytes(of: control.negotiation_id) { UUID(uuid: $0.load(as: uuid_t.self)) }
      let limits = try HDRFrameLimits(
        pageBytes: control.limits.page_bytes,
        rowAlignment: control.limits.row_alignment,
        maximumMappingBytes: control.limits.maximum_mapping_bytes)
      reducer = HDRFrameConsumerState(
        afterNegotiation: try HDRNegotiatedSession(
          negotiationID: id, transportConnectionEpoch: transportConnectionEpoch,
          inputConnectionEpoch: inputConnectionEpoch, limits: limits))
      stage = .records
      mvo_hdr_receive_clear(&receiver)
      mvo_hdr_receive_init(&receiver, Int(MVO_HDR_PACKET_BYTES), true)
    }
  }
  private func handleData(_ bytes: Data) throws {
    guard let limits = reducer?.session.limits else { throw RFBClientError.unexpectedMessage }
    let message = try HDRFrameMessage(admitting: bytes, limits: limits)
    guard
      let action = try reducer?.receive(message, descriptorCount: Int(receiver.descriptor_count))
    else {
      throw RFBClientError.unexpectedMessage
    }
    switch action {
    case .admitMappings(let ticket):
      var pool: [HDRFrameMapping] = []
      for i in 0..<2 {
        let fd = mvo_hdr_receive_take_descriptor(&receiver, i)
        guard fd >= 0 else { throw RFBClientError.malformedMessage }
        pool.append(try HDRFrameMapping(taking: fd, byteCount: message.descriptor.mappingBytes))
      }
      guard pool[0].hasDistinctBacking(from: pool[1]) else { throw RFBClientError.unsafeSocket }
      guard
        let admitted = try reducer?.mappingsAdmitted(
          for: ticket, first: pool[0].identity, second: pool[1].identity),
        case .send(let send) = admitted
      else { throw RFBClientError.unexpectedMessage }
      try transmit(send.bytes)
      try reducer?.sendCompleted(send)
      mappings = pool
      clearDeadline()
      let waiter = connectWaiter
      connectWaiter = nil
      waiter?.resume()
    case .copyBorrowedSnapshot(let borrow):
      guard let waiter = frameWaiter, mappings.count == 2 else {
        throw RFBClientError.unexpectedMessage
      }
      frameWaiter = nil
      let mapping = mappings[message.slot]
      armDeadline()
      waiter.resume(
        returning: HDRSharedFrame(
          input: inputConnectionEpoch, transport: transportConnectionEpoch,
          message: message, mapping: mapping,
          copy: { [self, mapping] destination, commands in
            try await copyFrame(borrow, mapping: mapping, to: destination, commands: commands)
          }))
    case .send: throw RFBClientError.unexpectedMessage
    }
  }

  private func transmit(_ bytes: Data) throws {
    guard !isClosed, try endpoint() == expectedIdentity else { throw RFBClientError.unsafeSocket }
    let sent = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    // Safe bounded failure on short/EAGAIN: never apply sendCompleted or reuse
    // the borrow after a partially transmitted ACK. The peer abandons its pool.
    guard sent == bytes.count else { throw RFBClientError.disconnected }
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
  private func clearDeadline() {
    timer?.cancel()
    timer = nil
    deadline = nil
  }
  private var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }
  private func signalClose() {
    lock.lock()
    closed = true
    if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    lock.unlock()
    queue.async { [self] in fail(RFBClientError.closed) }
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
  private func fail(_ error: any Error) {
    let cause = terminalError ?? error
    terminalError = cause
    lock.lock()
    closed = true
    lock.unlock()
    reducer?.detach()
    clearDeadline()
    source?.cancel()
    source = nil
    mvo_hdr_receive_clear(&receiver)
    mappings.removeAll()
    connectWaiter?.resume(throwing: cause)
    connectWaiter = nil
    frameWaiter?.resume(throwing: cause)
    frameWaiter = nil
    copyWaiter?.resume(throwing: cause)
    copyWaiter = nil
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
    else {
      throw RFBClientError.posix(errno)
    }
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
    else {
      throw RFBClientError.unsafeSocket
    }
  }
  private func endpoint() throws -> RFBEndpointIdentity {
    let path = socketURL.path
    guard socketURL.isFileURL, socketURL.host == nil || socketURL.host == "",
      socketURL.query == nil, socketURL.fragment == nil, path.hasPrefix("/"),
      path.utf8.count <= 103,
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
