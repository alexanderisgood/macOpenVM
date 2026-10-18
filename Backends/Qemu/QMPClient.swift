// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation

/// The observed QEMU run state; this does not establish process exit or guest readiness.
public struct QMPStatus: Equatable, Sendable {
  public let running: Bool
  public let status: String
}

public enum QMPShutdownReason: String, Equatable, Sendable {
  case none
  case hostError = "host-error"
  case hostQMPQuit = "host-qmp-quit"
  case hostQMPSystemReset = "host-qmp-system-reset"
  case hostSignal = "host-signal"
  case hostUI = "host-ui"
  case guestShutdown = "guest-shutdown"
  case guestReset = "guest-reset"
  case guestPanic = "guest-panic"
  case subsystemReset = "subsystem-reset"
  case snapshotLoad = "snapshot-load"
}

public struct QMPShutdownEvent: Equatable, Sendable {
  public let guest: Bool
  public let reason: QMPShutdownReason
}

/// Connection evidence only. Neither an ACK nor this snapshot establishes child exit,
/// output drain completion, writer release or guest filesystem integrity.
public struct QMPMonitorObservation: Equatable, Sendable {
  public let sequence: UInt64
  public let connectionEpoch: UUID
  public let shutdown: QMPShutdownEvent?
  public let naturalEOF: Bool
  public let readerDrained: Bool
  public let intentionalClose: Bool
  public let failure: QMPClientError?
  public var guestShutdownObserved: Bool {
    shutdown?.guest == true && shutdown?.reason == .guestShutdown
  }
}

public enum QMPClientError: Error, Equatable, Sendable {
  case invalidTimeout, unsafeSocket, alreadyConnected, notConnected, closed, busy
  case connectionFailed(Int32)
  case ioFailure(Int32)
  case disconnected, deadlineExceeded
  case malformedMessage, unexpectedReply, unsupportedVersion, limitExceeded, identifierExhausted
  case commandRejected(String)
}

/// One private QEMU 11.1.0 monitor connection. Any interrupted or invalid exchange
/// closes the connection, so a late reply can never complete a subsequent command.
public actor QMPClient {
  public nonisolated let connectionEpoch: UUID
  private enum State { case idle, connecting, ready, closed }
  private let transport: QMPTransport
  private let timeout: Duration
  private let captureCapability: CaptureCapability?
  private var state: State = .idle
  private var busy = false
  private var nextIdentifier: UInt64 = 1
  private var settlement: Task<QMPMonitorObservation, Never>?

  public init(
    socketURL: URL, timeout: Duration = .seconds(3),
    onObservation: (@MainActor @Sendable (QMPMonitorObservation) -> Void)? = nil
  ) {
    self.timeout = timeout
    captureCapability = nil
    let epoch = UUID()
    connectionEpoch = epoch
    transport = QMPTransport(socketURL: socketURL, epoch: epoch, onObservation: onObservation)
  }

  /// Only a future reviewed package resource/backend may select this capability.
  /// The public initializer and all existing callers remain capture-unavailable.
  package init(
    socketURL: URL, timeout: Duration = .seconds(3),
    producerCaptureCapability: CaptureCapability,
    onObservation: (@MainActor @Sendable (QMPMonitorObservation) -> Void)? = nil
  ) {
    self.timeout = timeout
    captureCapability = producerCaptureCapability
    let epoch = UUID()
    connectionEpoch = epoch
    transport = QMPTransport(socketURL: socketURL, epoch: epoch, onObservation: onObservation)
  }

  /// Actual bytes received by calls begun with a typed capture pending.
  /// Includes coalesced suffixes; excludes handshake/idle/lifecycle receive calls.
  package func producerCaptureRawReadBytes() async -> UInt64 {
    await transport.captureBytesRead()
  }

  deinit { transport.dispose() }

  public func connect() async throws {
    guard state != .closed else { throw QMPClientError.closed }
    guard !busy else { throw QMPClientError.busy }
    guard state == .idle else { throw QMPClientError.alreadyConnected }
    try validateTimeout()
    busy = true
    state = .connecting
    defer { busy = false }
    let identifier = try allocateIdentifier()
    let transport = transport
    let deadline = ContinuousClock().now.advanced(by: timeout)
    do {
      try Task.checkCancellation()
      try await withTaskCancellationHandler {
        try await transport.perform { worker in
          try worker.connect(deadline: deadline, capabilityIdentifier: identifier)
        }
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard state != .closed else { throw QMPClientError.closed }
      state = .ready
    } catch {
      state = .closed
      await transport.close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  public func queryStatus() async throws -> QMPStatus {
    let value = try await command("query-status")
    guard case .object(let object) = value, Set(object.keys) == ["running", "status"],
      case .bool(let running) = object["running"], case .string(let status) = object["status"],
      QMPTransport.runStates.contains(status), running == (status == "running")
    else {
      state = .closed
      await transport.failValidation(.malformedMessage)
      throw QMPClientError.malformedMessage
    }
    return QMPStatus(running: running, status: status)
  }

  public func stop() async throws { try await emptyCommand("stop") }
  public func cont() async throws { try await emptyCommand("cont") }

  package func producerCaptureArm(_ capture: UInt64) async throws -> CaptureReply {
    try await captureCommand(.arm(capture))
  }

  package func producerCaptureStatus(expectedCapture: UInt64) async throws -> CaptureReply {
    try await captureCommand(.status(expectedCapture: expectedCapture))
  }

  package func producerCaptureStop(expectedCapture: UInt64) async throws -> CaptureReply {
    try await captureCommand(.stop(expectedCapture: expectedCapture))
  }

  /// Expected terminal facts are immutable local metadata, never extra QMP args.
  package func producerCaptureRead(terminalStatus: CaptureStatus, count: UInt16) async throws
    -> CaptureReply
  {
    try await captureCommand(.read(terminalStatus: terminalStatus, count: count))
  }

  /// QEMU exposes device selection through its documented HMP mouse_set command.
  /// The command line is built only from a bounded index returned by query-mice.
  /// No caller-supplied monitor text is accepted. A second query verifies selection.
  public func selectRelativeMouse(_ relative: Bool) async throws {
    let before = try await mice()
    let candidates = before.filter { $0.absolute != relative }
    guard candidates.count == 1, let selected = candidates.first else {
      throw QMPClientError.commandRejected("PointerDeviceUnavailable")
    }
    if !selected.current {
      let value = try await command("human-monitor-command", mouseIndex: selected.index)
      guard case .string(let output) = value, output.isEmpty else {
        throw QMPClientError.commandRejected("PointerSelectionFailed")
      }
    }
    let after = try await mice()
    guard after.filter({ $0.current }).count == 1,
      after.contains(where: { $0.index == selected.index && $0.current && $0.absolute != relative })
    else { throw QMPClientError.commandRejected("PointerSelectionUnconfirmed") }
  }

  private func mice() async throws -> [(index: UInt64, absolute: Bool, current: Bool)] {
    let value = try await command("query-mice")
    guard case .array(let entries) = value, !entries.isEmpty, entries.count <= 16 else {
      throw QMPClientError.malformedMessage
    }
    var result: [(index: UInt64, absolute: Bool, current: Bool)] = []
    for entry in entries {
      guard case .object(let fields) = entry,
        Set(fields.keys) == ["name", "index", "absolute", "current"],
        case .string(let name) = fields["name"], name.utf8.count <= 128,
        let index = fields["index"]?.identifier, index <= 65_535,
        case .bool(let absolute) = fields["absolute"], case .bool(let current) = fields["current"],
        !result.contains(where: { $0.index == index })
      else { throw QMPClientError.malformedMessage }
      result.append((index, absolute, current))
    }
    return result
  }

  /// The empty reply acknowledges the request only; guests may ignore it or show a prompt.
  public func powerdown() async throws { try await emptyCommand("system_powerdown") }

  public func observation() async -> QMPMonitorObservation { await transport.observation() }

  /// Drain currently available frames on the same reader, without waiting for future data.
  public func drainObservation() async throws -> QMPMonitorObservation {
    if state == .closed { return await transport.observation() }
    guard state == .ready else { throw QMPClientError.notConnected }
    return try await transport.drainObservation()
  }

  /// One shared waiter for actual reader/descriptor closure. Cancelling a waiter never
  /// changes this connection's terminal evidence or requests guest/runtime termination.
  public func settledObservation() async -> QMPMonitorObservation {
    if settlement == nil {
      let transport = transport
      settlement = Task { await transport.settledObservation() }
    }
    guard let settlement else { return await transport.observation() }
    return await settlement.value
  }

  /// A successful reply acknowledges quit; the process owner must still observe exit.
  public func quit() async throws {
    try await emptyCommand("quit")
    await close()
  }

  /// Interrupts pending I/O and waits until this connection's descriptor is closed.
  public func close() async {
    state = .closed
    await transport.close()
  }

  private func validateTimeout() throws {
    guard timeout > .zero, timeout <= .seconds(30) else { throw QMPClientError.invalidTimeout }
  }

  private func allocateIdentifier() throws -> UInt64 {
    guard nextIdentifier <= 9_007_199_254_740_991 else { throw QMPClientError.identifierExhausted }
    let value = nextIdentifier
    nextIdentifier += 1
    return value
  }

  private func emptyCommand(_ name: String) async throws {
    let value = try await command(name)
    guard case .object(let object) = value, object.isEmpty else {
      state = .closed
      await transport.failValidation(.malformedMessage)
      throw QMPClientError.malformedMessage
    }
  }

  private func command(_ name: String, mouseIndex: UInt64? = nil) async throws -> QMPJSON {
    guard state != .closed else { throw QMPClientError.closed }
    guard state == .ready else { throw QMPClientError.notConnected }
    guard !busy else { throw QMPClientError.busy }
    busy = true
    defer { busy = false }
    let identifier = try allocateIdentifier()
    let transport = transport
    let deadline = ContinuousClock().now.advanced(by: timeout)
    do {
      try Task.checkCancellation()
      let result = try await withTaskCancellationHandler {
        try await transport.exchange(
          .ordinary(name, mouseIndex: mouseIndex), identifier: identifier, deadline: deadline)
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard state != .closed else { throw QMPClientError.closed }
      guard case .ordinary(let value) = result else { throw QMPClientError.malformedMessage }
      return value
    } catch {
      state = .closed
      await transport.close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  private func captureCommand(_ request: QMPProducerCaptureRequest) async throws -> CaptureReply {
    guard captureCapability == .boundedProducerV1 else { throw CaptureFault.unavailable }
    guard state != .closed else { throw QMPClientError.closed }
    guard state == .ready else { throw QMPClientError.notConnected }
    guard !busy else { throw QMPClientError.busy }
    try QMPProducerCaptureCodec.validate(request)
    busy = true
    defer { busy = false }
    let identifier = try allocateIdentifier()
    let transport = transport
    let deadline = ContinuousClock().now.advanced(by: timeout)
    do {
      try Task.checkCancellation()
      let result = try await withTaskCancellationHandler {
        try await transport.exchange(.capture(request), identifier: identifier, deadline: deadline)
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard state != .closed else { throw QMPClientError.closed }
      guard case .capture(let value) = result else { throw QMPClientError.malformedMessage }
      return value
    } catch {
      state = .closed
      await transport.close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }
}

/// Queue-confined buffer/I/O, with a lock only for published descriptor and close state.
/// Cancellation may shutdown under that lock; actual close occurs only on the queue.
/// Queued work retains this object, so deinit cannot race a descriptor operation.
private final class QMPTransport: @unchecked Sendable {
  static let runStates: Set<String> = [
    "debug", "finish-migrate", "inmigrate", "internal-error", "io-error", "paused",
    "postmigrate", "prelaunch", "restore-vm", "running", "save-vm", "shutdown",
    "suspended", "watchdog", "guest-panicked", "colo", "preconfig",
  ]
  private let socketURL: URL
  private let queue = DispatchQueue(label: "local.macOpenVM.qmp", qos: .userInitiated)
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var closed = false
  private var buffer = Data()
  private let clock = ContinuousClock()
  private let lineLimit = 65_536
  private let aggregateLimit = 262_144
  private let eventLimit = 64
  private let epoch: UUID
  private let onObservation: (@MainActor @Sendable (QMPMonitorObservation) -> Void)?
  private var idleReader: DispatchSourceRead?
  private var writer: DispatchSourceWrite?
  private var writerCancelling = false
  private var commandTimer: DispatchSourceTimer?
  private struct PendingExchange {
    let command: QMPExchangeCommand
    let identifier: UInt64
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<QMPExchangeReply, any Error>
    var earlyPrefix: Bool
    var bytes: [UInt8]
    var offset = 0
    var aggregate = 0
    var events = 0
  }
  private var pending: PendingExchange?
  private var captureRawBytes = 0
  private let captureRawLimit = 8_388_608
  private var finishing = false
  private var readerDrained = false
  private var terminalWaiter: CheckedContinuation<QMPMonitorObservation, Never>?
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var sequence: UInt64 = 0
  private var shutdownEvent: QMPShutdownEvent?
  private var firstFailure: QMPClientError?
  // These close markers share the descriptor lock with cancellation publication.
  private var closeCommitted = false
  private var intentionalClose = false
  private var naturalEOF = false

  init(
    socketURL: URL, epoch: UUID,
    onObservation: (@MainActor @Sendable (QMPMonitorObservation) -> Void)?
  ) {
    self.socketURL = socketURL
    self.epoch = epoch
    self.onObservation = onObservation
  }

  deinit {
    if descriptor >= 0 { Darwin.close(descriptor) }
  }

  func captureBytesRead() async -> UInt64 {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: UInt64(self.captureRawBytes)) }
    }
  }

  /// Exactly one charge at positive recv, before buffer accumulation. Ownership
  /// is the pending typed exchange at call entry, not reconstructed JSON size or
  /// event causality. A whole coalesced suffix belongs to this receive window.
  private func receive(_ descriptor: Int32, into bytes: inout [UInt8]) throws -> Int {
    let capture: Bool
    if let pending, case .capture = pending.command { capture = true } else { capture = false }
    let capacity: Int
    if capture {
      let remaining = captureRawLimit - captureRawBytes
      guard remaining > 0 else { throw QMPClientError.limitExceeded }
      capacity = min(bytes.count, remaining)
    } else {
      capacity = bytes.count
    }
    let count = Darwin.recv(descriptor, &bytes, capacity, 0)
    if capture, count > 0 { captureRawBytes += count }
    return count
  }

  func perform<T: Sendable>(
    _ operation: @escaping @Sendable (QMPTransport) throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try operation(self)) } catch {
          self.recordFailure(error)
          self.beginClose(natural: false)
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func dispose() {
    signalClose()
    queue.async { self.beginClose(natural: false) }
  }

  func signalClose() {
    lock.lock()
    if !closeCommitted { intentionalClose = true }
    closed = true
    if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    lock.unlock()
  }

  func close() async {
    signalClose()
    await withCheckedContinuation { continuation in
      queue.async {
        if self.readerDrained {
          continuation.resume()
        } else {
          self.closeWaiters.append(continuation)
          self.beginClose(natural: false)
        }
      }
    }
  }

  func failValidation(_ failure: QMPClientError) async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.recordFailure(failure)
        if self.readerDrained {
          continuation.resume()
        } else {
          self.closeWaiters.append(continuation)
          self.beginClose(natural: false)
        }
      }
    }
  }

  private func closeDescriptor() {
    lock.lock()
    let old = descriptor
    descriptor = -1
    closed = true
    lock.unlock()
    if old >= 0 { Darwin.close(old) }
    buffer.removeAll(keepingCapacity: false)
  }

  func observation() async -> QMPMonitorObservation {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: self.snapshot()) }
    }
  }

  func settledObservation() async -> QMPMonitorObservation {
    await withCheckedContinuation { continuation in
      queue.async {
        if self.readerDrained {
          continuation.resume(returning: self.snapshot())
        } else {
          self.terminalWaiter = continuation
        }
      }
    }
  }

  private func snapshot() -> QMPMonitorObservation {
    lock.lock()
    let natural = naturalEOF
    let intentional = intentionalClose
    lock.unlock()
    return QMPMonitorObservation(
      sequence: sequence, connectionEpoch: epoch, shutdown: shutdownEvent,
      naturalEOF: natural, readerDrained: readerDrained, intentionalClose: intentional,
      failure: firstFailure)
  }

  private func publish() {
    sequence += 1
    let value = snapshot()
    if let onObservation { Task { @MainActor in onObservation(value) } }
  }

  private func recordFailure(_ error: any Error) {
    guard !readerDrained, firstFailure == nil else { return }
    let failure = (error as? QMPClientError) ?? .ioFailure(EIO)
    lock.lock()
    let intentional = intentionalClose
    let natural = naturalEOF
    lock.unlock()
    guard !(intentional && failure == .closed),
      !(natural && (failure == .disconnected || failure == .closed))
    else { return }
    firstFailure = failure
    publish()
  }

  private func beginClose(natural: Bool) {
    guard !finishing else { return }
    finishing = true
    lock.lock()
    if natural && !intentionalClose && firstFailure == nil { naturalEOF = true }
    closeCommitted = true
    closed = true
    lock.unlock()
    cancelCommandTimer()
    if let request = pending {
      pending = nil
      request.continuation.resume(
        throwing: natural ? QMPClientError.disconnected : firstFailure ?? .closed)
    }
    cancelWriter()
    if let idleReader { idleReader.cancel() } else { maybeFinishClose() }
  }

  private func maybeFinishClose() {
    if idleReader == nil && writer == nil && !writerCancelling { finishClose() }
  }

  private func finishClose() {
    guard !readerDrained else { return }
    closeDescriptor()
    idleReader = nil
    readerDrained = true
    publish()
    terminalWaiter?.resume(returning: snapshot())
    terminalWaiter = nil
    let waiters = closeWaiters
    closeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func startIdleReader() throws {
    let source = DispatchSource.makeReadSource(fileDescriptor: try fd(), queue: queue)
    idleReader = source
    source.setEventHandler { [self] in
      guard !finishing else { return }
      do { try drainIdle() } catch {
        recordFailure(error)
        beginClose(natural: false)
      }
    }
    source.setCancelHandler { [self] in
      idleReader = nil
      maybeFinishClose()
    }
    source.resume()
    publish()
    try drainIdle()
  }

  /// The same queue and parser drain buffered/post-reply events while idle. Readiness
  /// invokes this handler; an idle connection has no polling timer or deadline wake loop.
  private func drainIdle() throws {
    guard !finishing else { return }
    lock.lock()
    let intentional = intentionalClose
    lock.unlock()
    if intentional {
      beginClose(natural: false)
      return
    }
    let descriptor = try fd()
    var aggregate = 0
    var events = 0
    while true {
      while let newline = buffer.firstIndex(of: 10) {
        let count = buffer.distance(from: buffer.startIndex, to: newline) + 1
        guard count <= lineLimit, count >= 2, buffer[buffer.index(before: newline)] == 13 else {
          throw QMPClientError.malformedMessage
        }
        guard aggregate <= aggregateLimit - count else { throw QMPClientError.limitExceeded }
        aggregate += count
        if let request = pending {
          guard request.aggregate <= aggregateLimit - count else {
            throw QMPClientError.limitExceeded
          }
          pending?.aggregate += count
        }
        let data = Data(buffer.prefix(count - 2))
        buffer.removeFirst(count)
        var decoder = QMPJSONDecoder(data)
        let value = try decoder.decode()
        guard case .object(let object) = value else { throw QMPClientError.malformedMessage }
        if object["event"] != nil {
          guard events < eventLimit else { throw QMPClientError.limitExceeded }
          if let request = pending {
            guard request.events < eventLimit else { throw QMPClientError.limitExceeded }
            pending?.events += 1
          }
          try validateEvent(object)
          events += 1
          if pending != nil { pending?.earlyPrefix = false }
        } else {
          try receiveReply(object)
        }
      }
      guard buffer.count < lineLimit else { throw QMPClientError.limitExceeded }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = try receive(descriptor, into: &bytes)
      if count > 0 {
        guard aggregate <= aggregateLimit - count, buffer.count <= aggregateLimit - count else {
          throw QMPClientError.limitExceeded
        }
        buffer.append(contentsOf: bytes.prefix(count))
        continue
      }
      if count == 0 {
        lock.lock()
        let intentional = intentionalClose
        lock.unlock()
        if intentional {
          beginClose(natural: false)
          return
        }
        guard buffer.isEmpty else { throw QMPClientError.malformedMessage }
        beginClose(natural: true)
        return
      }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return }
      throw QMPClientError.ioFailure(errno)
    }
  }

  func drainObservation() async throws -> QMPMonitorObservation {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          if !self.finishing { try self.drainIdle() }
          continuation.resume(returning: self.snapshot())
        } catch {
          self.recordFailure(error)
          self.beginClose(natural: false)
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func exchange(
    _ command: QMPExchangeCommand, identifier: UInt64, deadline: ContinuousClock.Instant
  )
    async throws -> QMPExchangeReply
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        var registered = false
        do {
          try self.checkDeadline(deadline)
          guard self.pending == nil else { throw QMPClientError.busy }
          try self.drainIdle()
          try self.checkOpen()
          self.pending = PendingExchange(
            command: command, identifier: identifier, deadline: deadline,
            continuation: continuation,
            earlyPrefix: !self.buffer.isEmpty,
            bytes: try command.bytes(identifier: identifier))
          registered = true
          self.startCommandTimer(deadline)
          try self.flushCommand()
        } catch {
          self.recordFailure(error)
          if !registered { continuation.resume(throwing: error) }
          self.beginClose(natural: false)
        }
      }
    }
  }

  private func startCommandTimer(_ deadline: ContinuousClock.Instant) {
    let duration = clock.now.duration(to: deadline).components
    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    let timer = DispatchSource.makeTimerSource(queue: queue)
    commandTimer = timer
    timer.schedule(deadline: .now() + max(0, seconds))
    timer.setEventHandler { [self] in
      guard pending != nil, !finishing else { return }
      recordFailure(QMPClientError.deadlineExceeded)
      beginClose(natural: false)
    }
    timer.resume()
  }

  private func cancelCommandTimer() {
    commandTimer?.cancel()
    commandTimer = nil
  }

  private func flushCommand() throws {
    guard !finishing else { return }
    let descriptor = try fd()
    while var request = pending, request.offset < request.bytes.count {
      try checkDeadline(request.deadline)
      let count = request.bytes.withUnsafeBytes { bytes in
        Darwin.send(
          descriptor, bytes.baseAddress?.advanced(by: request.offset),
          request.bytes.count - request.offset, 0)
      }
      if count > 0 {
        request.offset += count
        pending = request
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        if writer == nil && !writerCancelling {
          let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
          writer = source
          source.setEventHandler { [self] in
            do { try flushCommand() } catch {
              recordFailure(error)
              beginClose(natural: false)
            }
          }
          source.setCancelHandler { [self] in
            writerCancelling = false
            if finishing {
              maybeFinishClose()
            } else if pending != nil {
              do { try flushCommand() } catch {
                recordFailure(error)
                beginClose(natural: false)
              }
            }
          }
          source.resume()
        }
        return
      }
      throw QMPClientError.disconnected
    }
    cancelWriter()
  }

  private func cancelWriter() {
    if let writer {
      self.writer = nil
      writerCancelling = true
      writer.cancel()
    }
  }

  private func receiveReply(_ object: [String: QMPJSON]) throws {
    guard let request = pending, !request.earlyPrefix, request.offset == request.bytes.count,
      object["id"]?.identifier == request.identifier
    else { throw QMPClientError.unexpectedReply }
    try checkDeadline(request.deadline)
    if let result = object["return"], Set(object.keys) == ["return", "id"] {
      let reply: QMPExchangeReply
      if case .capture(let capture) = request.command {
        reply = .capture(try QMPProducerCaptureCodec.result(result, for: capture))
      } else if request.command.name == "query-status" {
        guard case .object(let value) = result, Set(value.keys) == ["running", "status"],
          case .bool(let running) = value["running"], case .string(let status) = value["status"],
          Self.runStates.contains(status), running == (status == "running")
        else { throw QMPClientError.malformedMessage }
        reply = .ordinary(result)
      } else if request.command.name == "query-mice" {
        guard case .array(let entries) = result, entries.count <= 16 else {
          throw QMPClientError.malformedMessage
        }
        reply = .ordinary(result)
      } else if request.command.name == "human-monitor-command" {
        guard case .string(let output) = result, output.utf8.count <= 4096 else {
          throw QMPClientError.malformedMessage
        }
        reply = .ordinary(result)
      } else {
        guard case .object(let value) = result, value.isEmpty else {
          throw QMPClientError.malformedMessage
        }
        reply = .ordinary(result)
      }
      pending = nil
      cancelCommandTimer()
      request.continuation.resume(returning: reply)
      return
    }
    guard Set(object.keys) == ["error", "id"], case .object(let error) = object["error"],
      Set(error.keys) == ["class", "desc"], case .string(let name) = error["class"],
      !name.isEmpty, name.utf8.count <= 64,
      name.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
      }),
      case .string(let description) = error["desc"], description.utf8.count <= 4096
    else { throw QMPClientError.malformedMessage }
    if case .capture = request.command, name == "GenericError",
      let rejection = QMPProducerCaptureCodec.rejection(description)
    {
      pending = nil
      cancelCommandTimer()
      request.continuation.resume(returning: .capture(.rejected(rejection)))
      return
    }
    throw QMPClientError.commandRejected(name)
  }

  private func checkOpen() throws {
    lock.lock()
    let unavailable = closed
    lock.unlock()
    if unavailable { throw QMPClientError.closed }
  }

  private func install(_ value: Int32) throws {
    lock.lock()
    if closed {
      lock.unlock()
      Darwin.close(value)
      throw QMPClientError.closed
    }
    descriptor = value
    lock.unlock()
  }

  private func fd() throws -> Int32 {
    lock.lock()
    let value = descriptor
    let unavailable = closed
    lock.unlock()
    guard !unavailable, value >= 0 else { throw QMPClientError.closed }
    return value
  }

  private func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    try checkOpen()
    if clock.now >= deadline { throw QMPClientError.deadlineExceeded }
  }

  private func pollUntil(
    _ descriptor: Int32, events: Int16, deadline: ContinuousClock.Instant
  ) throws {
    while true {
      try checkDeadline(deadline)
      let remaining = clock.now.duration(to: deadline).components
      let milliseconds =
        Double(remaining.seconds) * 1_000
        + Double(remaining.attoseconds) / 1_000_000_000_000_000
      let wait = Int32(max(1, min(10, milliseconds.rounded(.up))))
      var item = pollfd(fd: descriptor, events: events, revents: 0)
      let result = Darwin.poll(&item, 1, wait)
      try checkDeadline(deadline)
      if result < 0 {
        if errno == EINTR { continue }
        throw QMPClientError.ioFailure(errno)
      }
      if result == 0 { continue }
      if item.revents & Int16(POLLNVAL) != 0 { throw QMPClientError.disconnected }
      if item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
    }
  }

  private func socketPath() throws -> String {
    let path = socketURL.path
    guard socketURL.isFileURL, socketURL.host == nil || socketURL.host == "",
      socketURL.query == nil, socketURL.fragment == nil, path.hasPrefix("/"),
      !path.hasSuffix("/"),
      !path.utf8.contains(where: { $0 < 32 || $0 == 127 }), path.utf8.count <= 103
    else { throw QMPClientError.unsafeSocket }
    // Validate lexically: Foundation standardization can rewrite an existing
    // /private/tmp path to /tmp, which is itself a symlink on macOS.
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw QMPClientError.unsafeSocket
    }
    var ancestor = ""
    for component in components.dropFirst().dropLast() {
      ancestor += "/" + component
      var info = stat()
      guard Darwin.lstat(ancestor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw QMPClientError.unsafeSocket
      }
    }
    var parent = stat()
    let parentPath = socketURL.deletingLastPathComponent().path
    guard Darwin.lstat(parentPath, &parent) == 0, parent.st_uid == getuid(),
      parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o777 == 0o700
    else { throw QMPClientError.unsafeSocket }
    return path
  }

  private func socketInfo(_ path: String) throws -> stat? {
    var info = stat()
    if Darwin.lstat(path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw QMPClientError.unsafeSocket
    }
    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_nlink == 1,
      info.st_mode & 0o077 == 0, info.st_mode & 0o600 == 0o600
    else { throw QMPClientError.unsafeSocket }
    return info
  }

  func connect(deadline: ContinuousClock.Instant, capabilityIdentifier: UInt64) throws {
    let path = try socketPath()
    var prior: stat?
    while prior == nil {
      try checkDeadline(deadline)
      prior = try socketInfo(path)
      if prior == nil { _ = Darwin.poll(nil, 0, 10) }
    }
    let created = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard created >= 0 else { throw QMPClientError.connectionFailed(errno) }
    try install(created)
    guard fcntl(created, F_SETFL, O_NONBLOCK) == 0,
      fcntl(created, F_SETFD, FD_CLOEXEC) == 0
    else { throw QMPClientError.connectionFailed(errno) }
    var noSignal: Int32 = 1
    guard
      setsockopt(created, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else {
      throw QMPClientError.connectionFailed(errno)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: Array(path.utf8) + [0])
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(created, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result != 0 {
      guard errno == EINPROGRESS || errno == EAGAIN else {
        throw QMPClientError.connectionFailed(errno)
      }
      try pollUntil(created, events: Int16(POLLOUT), deadline: deadline)
      var error: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(created, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
        throw QMPClientError.connectionFailed(error == 0 ? errno : error)
      }
    }
    try checkDeadline(deadline)
    guard let current = try socketInfo(path), let prior,
      current.st_dev == prior.st_dev, current.st_ino == prior.st_ino
    else { throw QMPClientError.unsafeSocket }
    var owner: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(created, &owner, &group) == 0, owner == getuid() else {
      throw QMPClientError.unsafeSocket
    }
    var aggregate = 0
    let greeting = try line(deadline: deadline, aggregate: &aggregate)
    try validateGreeting(greeting)
    var events = 0
    let prefixPredatesCommand = try drainUnsolicited(
      deadline: deadline, aggregate: &aggregate, events: &events)
    try send("qmp_capabilities", identifier: capabilityIdentifier, deadline: deadline)
    let reply = try response(
      identifier: capabilityIdentifier, deadline: deadline, aggregate: &aggregate, events: &events,
      prefixPredatesCommand: prefixPredatesCommand)
    guard case .object(let object) = reply, object.isEmpty else {
      throw QMPClientError.malformedMessage
    }
    try startIdleReader()
  }

  private func send(_ command: String, identifier: UInt64, deadline: ContinuousClock.Instant) throws
  {
    let bytes = Array("{\"execute\":\"\(command)\",\"id\":\(identifier)}\r\n".utf8)
    var offset = 0
    let descriptor = try fd()
    while offset < bytes.count {
      try checkDeadline(deadline)
      let written = bytes.withUnsafeBytes { pointer in
        Darwin.send(descriptor, pointer.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      }
      if written > 0 {
        offset += written
        continue
      }
      if written < 0, errno == EINTR { continue }
      if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try pollUntil(descriptor, events: Int16(POLLOUT), deadline: deadline)
        continue
      }
      throw QMPClientError.disconnected
    }
  }

  private func line(deadline: ContinuousClock.Instant, aggregate: inout Int) throws -> QMPJSON {
    let descriptor = try fd()
    while true {
      try checkDeadline(deadline)
      if let newline = buffer.firstIndex(of: 10) {
        let count = buffer.distance(from: buffer.startIndex, to: newline) + 1
        guard count <= lineLimit, count >= 2, buffer[buffer.index(before: newline)] == 13 else {
          throw QMPClientError.malformedMessage
        }
        guard aggregate <= aggregateLimit - count else { throw QMPClientError.limitExceeded }
        aggregate += count
        let contents = Data(buffer.prefix(count - 2))
        buffer.removeFirst(count)
        var decoder = QMPJSONDecoder(contents)
        let decoded = try decoder.decode()
        try checkDeadline(deadline)
        return decoded
      }
      guard buffer.count < lineLimit else { throw QMPClientError.limitExceeded }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let received = try receive(descriptor, into: &bytes)
      if received > 0 {
        guard buffer.count <= aggregateLimit - received else { throw QMPClientError.limitExceeded }
        buffer.append(contentsOf: bytes.prefix(received))
        continue
      }
      if received == 0 {
        if buffer.isEmpty { beginClose(natural: true) }
        throw QMPClientError.disconnected
      }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        try pollUntil(descriptor, events: Int16(POLLIN), deadline: deadline)
        continue
      }
      throw QMPClientError.ioFailure(errno)
    }
  }

  private func validateGreeting(_ value: QMPJSON) throws {
    guard case .object(let root) = value, Set(root.keys) == ["QMP"],
      case .object(let qmp) = root["QMP"], Set(qmp.keys) == ["version", "capabilities"],
      case .object(let version) = qmp["version"], Set(version.keys) == ["qemu", "package"],
      case .object(let triple) = version["qemu"], Set(triple.keys) == ["major", "minor", "micro"],
      case .string(let package) = version["package"], package.utf8.count <= 256,
      case .array(let capabilities) = qmp["capabilities"], capabilities.count <= 16,
      capabilities.allSatisfy({
        if case .string(let name) = $0 { return !name.isEmpty && name.utf8.count <= 64 }
        return false
      })
    else { throw QMPClientError.malformedMessage }
    guard triple["major"]?.identifier == 11, triple["minor"]?.identifier == 1,
      triple["micro"]?.identifier == 0
    else { throw QMPClientError.unsupportedVersion }
  }

  private func response(
    identifier: UInt64, deadline: ContinuousClock.Instant, aggregate: inout Int,
    events: inout Int, prefixPredatesCommand: Bool
  ) throws -> QMPJSON {
    var earlyPrefix = prefixPredatesCommand
    while true {
      let value = try line(deadline: deadline, aggregate: &aggregate)
      guard case .object(let object) = value else { throw QMPClientError.malformedMessage }
      if object["event"] != nil {
        guard events < eventLimit else { throw QMPClientError.limitExceeded }
        try validateEvent(object)
        events += 1
        earlyPrefix = false
        continue
      }
      guard !earlyPrefix else { throw QMPClientError.unexpectedReply }
      guard object["id"]?.identifier == identifier else { throw QMPClientError.unexpectedReply }
      if let result = object["return"], Set(object.keys) == ["return", "id"] {
        try checkDeadline(deadline)
        return result
      }
      guard Set(object.keys) == ["error", "id"], case .object(let error) = object["error"],
        Set(error.keys) == ["class", "desc"], case .string(let name) = error["class"],
        !name.isEmpty, name.utf8.count <= 64,
        name.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }),
        case .string(let description) = error["desc"], description.utf8.count <= 4096
      else { throw QMPClientError.malformedMessage }
      throw QMPClientError.commandRejected(name)
    }
  }

  /// Reject replies already queued before issuing their command. A partial old
  /// frame may finish as an event, but cannot satisfy the new request identifier.
  private func drainUnsolicited(
    deadline: ContinuousClock.Instant, aggregate: inout Int, events: inout Int
  ) throws -> Bool {
    let descriptor = try fd()
    while true {
      try checkDeadline(deadline)
      while buffer.firstIndex(of: 10) != nil {
        let value = try line(deadline: deadline, aggregate: &aggregate)
        guard case .object(let event) = value, event["event"] != nil else {
          throw QMPClientError.unexpectedReply
        }
        guard events < eventLimit else { throw QMPClientError.limitExceeded }
        try validateEvent(event)
        events += 1
      }
      guard buffer.count < lineLimit else { throw QMPClientError.limitExceeded }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = try receive(descriptor, into: &bytes)
      if count > 0 {
        guard buffer.count <= aggregateLimit - count else { throw QMPClientError.limitExceeded }
        buffer.append(contentsOf: bytes.prefix(count))
        continue
      }
      if count == 0 { throw QMPClientError.disconnected }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return !buffer.isEmpty }
      throw QMPClientError.ioFailure(errno)
    }
  }

  private func validateEvent(_ object: [String: QMPJSON]) throws {
    guard Set(object.keys).isSubset(of: ["event", "data", "timestamp"]),
      case .string(let name) = object["event"], !name.isEmpty, name.utf8.count <= 128,
      case .object(let timestamp) = object["timestamp"],
      Set(timestamp.keys) == ["seconds", "microseconds"],
      let seconds = timestamp["seconds"]?.signedInteger,
      let microseconds = timestamp["microseconds"]?.signedInteger,
      (seconds == -1 && microseconds == -1)
        || (seconds >= 0 && (0..<1_000_000).contains(microseconds))
    else { throw QMPClientError.malformedMessage }
    if let data = object["data"], case .object = data {
    } else if object["data"] != nil {
      throw QMPClientError.malformedMessage
    }
    if name == "SHUTDOWN" {
      guard shutdownEvent == nil else { throw QMPClientError.unexpectedReply }
      guard case .object(let data) = object["data"], Set(data.keys) == ["guest", "reason"],
        case .bool(let guest) = data["guest"], case .string(let raw) = data["reason"],
        let reason = QMPShutdownReason(rawValue: raw)
      else { throw QMPClientError.malformedMessage }
      shutdownEvent = QMPShutdownEvent(guest: guest, reason: reason)
      publish()
    }
  }
}

private enum QMPProducerCaptureRequest: Sendable {
  case arm(UInt64)
  case status(expectedCapture: UInt64)
  case stop(expectedCapture: UInt64)
  case read(terminalStatus: CaptureStatus, count: UInt16)

  var capture: UInt64 {
    switch self {
    case .arm(let value), .status(let value), .stop(let value): value
    case .read(let status, _): status.capture
    }
  }
  var wireCommand: CaptureCommand {
    switch self {
    case .arm(let value): .arm(value)
    case .status: .status
    case .stop: .stop
    case .read(let status, let count): .read(offset: status.cursor, count: count)
    }
  }
}

private enum QMPExchangeReply: Sendable {
  case ordinary(QMPJSON)
  case capture(CaptureReply)
}

private enum QMPExchangeCommand: Sendable {
  case ordinary(String, mouseIndex: UInt64?)
  case capture(QMPProducerCaptureRequest)

  var name: String {
    switch self {
    case .ordinary(let name, _): name
    case .capture(let request): QMPProducerCaptureCodec.name(request.wireCommand)
    }
  }
  func bytes(identifier: UInt64) throws -> [UInt8] {
    switch self {
    case .capture(let request):
      return try QMPProducerCaptureCodec.bytes(request, identifier: identifier)
    case .ordinary(let command, let mouseIndex):
      let arguments: String
      if let mouseIndex {
        guard command == "human-monitor-command", mouseIndex <= 65_535 else {
          throw QMPClientError.malformedMessage
        }
        arguments = ",\"arguments\":{\"command-line\":\"mouse_set \(mouseIndex)\"}"
      } else {
        arguments = ""
      }
      return Array("{\"execute\":\"\(command)\"\(arguments),\"id\":\(identifier)}\r\n".utf8)
    }
  }
}

/// Same-file adapter over the original strict decoder's private values. No
/// Foundation JSON conversion, second parser, public command string or visibility
/// widening of QMPJSON is introduced.
private enum QMPProducerCaptureCodec {
  static func validate(_ request: QMPProducerCaptureRequest) throws {
    guard request.capture <= UInt64(Int64.max) else { throw CaptureFault.limit }
    switch request {
    case .arm, .stop:
      guard request.capture > 0 else { throw CaptureFault.limit }
    case .status: break
    case .read(let status, let count):
      guard (1...64).contains(count) else { throw CaptureFault.limit }
      guard status.terminal, status.cursor < status.records else { throw CaptureFault.notReady }
    }
  }
  static func name(_ command: CaptureCommand) -> String {
    switch command {
    case .arm: "x-mvo-producer-capture-arm"
    case .status: "x-mvo-producer-capture-status"
    case .stop: "x-mvo-producer-capture-stop"
    case .read: "x-mvo-producer-capture-read"
    }
  }
  static func bytes(_ request: QMPProducerCaptureRequest, identifier: UInt64) throws -> [UInt8] {
    try validate(request)
    guard (1...9_007_199_254_740_991).contains(identifier) else {
      throw QMPClientError.identifierExhausted
    }
    let arguments: String
    switch request.wireCommand {
    case .arm(let capture): arguments = ",\"arguments\":{\"capture\":\(capture)}"
    case .status, .stop: arguments = ""
    case .read(let offset, let count):
      arguments = ",\"arguments\":{\"offset\":\(offset),\"count\":\(count)}"
    }
    return Array(
      "{\"execute\":\"\(name(request.wireCommand))\"\(arguments),\"id\":\(identifier)}\r\n".utf8)
  }
  private static func unsigned(_ value: QMPJSON?) throws -> UInt64 {
    guard case .number(let spelling) = value, !spelling.isEmpty,
      spelling.utf8.count <= 20, spelling == "0" || spelling.first != "0",
      spelling.utf8.allSatisfy({ (48...57).contains($0) }), let result = UInt64(spelling)
    else { throw QMPClientError.malformedMessage }
    return result
  }
  private static func status(_ value: QMPJSON) throws -> CaptureStatus {
    guard case .object(let fields) = value,
      Set(fields.keys) == ["capture", "phase", "records", "reasons", "cursor", "terminal"]
    else { throw QMPClientError.malformedMessage }
    func u32(_ key: String) throws -> UInt32 {
      guard let exact = UInt32(exactly: try unsigned(fields[key])) else {
        throw QMPClientError.malformedMessage
      }
      return exact
    }
    return try CaptureStatus(
      capture: unsigned(fields["capture"]), phase: u32("phase"),
      records: u32("records"), reasons: u32("reasons"), cursor: u32("cursor"),
      terminal: u32("terminal"))
  }
  static func result(_ value: QMPJSON, for request: QMPProducerCaptureRequest) throws
    -> CaptureReply
  {
    do {
      switch request {
      case .arm, .status, .stop:
        let snapshot = try status(value)
        guard snapshot.capture == request.capture else { throw QMPClientError.malformedMessage }
        switch request {
        case .arm:
          guard snapshot.phase.rawValue >= CapturePhase.armed.rawValue else {
            throw QMPClientError.malformedMessage
          }
        case .status:
          guard
            request.capture == 0
              ? snapshot.phase == .disarmed
              : snapshot.phase.rawValue >= CapturePhase.armed.rawValue
          else { throw QMPClientError.malformedMessage }
        case .stop:
          guard snapshot.phase.rawValue >= CapturePhase.stopping.rawValue else {
            throw QMPClientError.malformedMessage
          }
        case .read: throw QMPClientError.malformedMessage
        }
        return .status(snapshot)
      case .read(let terminal, let count):
        guard terminal.terminal, terminal.cursor < terminal.records,
          case .array(let entries) = value
        else { throw QMPClientError.malformedMessage }
        let expected = min(UInt32(count), terminal.records - terminal.cursor)
        let (postCursor, overflow) = terminal.cursor.addingReportingOverflow(expected)
        guard !overflow, postCursor <= terminal.records, entries.count == Int(expected),
          entries.count <= 64
        else { throw QMPClientError.malformedMessage }
        var rows: [CaptureRow] = []
        for (position, entry) in entries.enumerated() {
          guard case .object(let fields) = entry, Set(fields.keys) == Set(CaptureRow.keys) else {
            throw QMPClientError.malformedMessage
          }
          let row = try CaptureRow(CaptureRow.keys.map { try unsigned(fields[$0]) })
          let index = UInt64(terminal.cursor) + UInt64(position)
          guard row.words[0] == index, row.words[3] == terminal.capture else {
            throw QMPClientError.malformedMessage
          }
          if index == 0 {
            guard row.words[1] == 1, row.words[14] == 4096, row.words[15] == 144 else {
              throw QMPClientError.malformedMessage
            }
          } else if index == UInt64(terminal.records - 1) {
            guard row.words[1] == 2, row.words[14] == UInt64(terminal.records),
              row.words[15] == UInt64(terminal.reasons)
            else { throw QMPClientError.malformedMessage }
          } else {
            guard row.words[1] >= 3 else { throw QMPClientError.malformedMessage }
          }
          rows.append(row)
        }
        return .rows(rows)
      }
    } catch {
      // Invalid server data uses the original terminal transport error type.
      throw QMPClientError.malformedMessage
    }
  }
  static func rejection(_ description: String) -> CaptureRejection? {
    switch description {
    case "Producer capture rejected (numeric code 1)": .invalid
    case "Producer capture rejected (numeric code 2)": .busy
    case "Producer capture rejected (numeric code 3)": .alreadyUsed
    case "Producer capture rejected (numeric code 4)": .notReady
    case "Producer capture rejected (numeric code 5)": .notLockFree
    case "Producer capture owner/lock-free admission failed": .ownerAdmission
    case "Producer capture ID is outside the numeric range": .captureRange
    case "Producer capture read is outside the numeric range": .readRange
    default: nil
    }
  }
}

private indirect enum QMPJSON: Sendable {
  case object([String: QMPJSON])
  case array([QMPJSON])
  case string(String)
  case number(String)
  case bool(Bool)
  case null

  var identifier: UInt64? {
    guard case .number(let raw) = self, !raw.isEmpty,
      raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(raw),
      value <= 9_007_199_254_740_991
    else { return nil }
    return value
  }
  var signedInteger: Int64? {
    guard case .number(let raw) = self,
      raw.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 })
    else { return nil }
    return Int64(raw)
  }
}

/// Strict JSON grammar with decoded duplicate-key detection, depth and node bounds.
private struct QMPJSONDecoder {
  private let bytes: [UInt8]
  private var position = 0
  private var nodes = 0

  init(_ data: Data) { bytes = Array(data) }

  mutating func decode() throws -> QMPJSON {
    let result = try value(depth: 0)
    whitespace()
    guard position == bytes.count else { throw QMPClientError.malformedMessage }
    return result
  }

  private mutating func whitespace() {
    while position < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[position]) { position += 1 }
  }

  private mutating func take(_ byte: UInt8) -> Bool {
    whitespace()
    guard position < bytes.count, bytes[position] == byte else { return false }
    position += 1
    return true
  }

  private mutating func value(depth: Int) throws -> QMPJSON {
    guard depth <= 32, nodes < 4096 else { throw QMPClientError.limitExceeded }
    nodes += 1
    whitespace()
    guard position < bytes.count else { throw QMPClientError.malformedMessage }
    switch bytes[position] {
    case 123:
      position += 1
      var object: [String: QMPJSON] = [:]
      if take(125) { return .object(object) }
      while true {
        whitespace()
        let key = try string()
        guard object[key] == nil, take(58) else { throw QMPClientError.malformedMessage }
        object[key] = try value(depth: depth + 1)
        if take(125) { return .object(object) }
        guard take(44) else { throw QMPClientError.malformedMessage }
      }
    case 91:
      position += 1
      var array: [QMPJSON] = []
      if take(93) { return .array(array) }
      while true {
        array.append(try value(depth: depth + 1))
        if take(93) { return .array(array) }
        guard take(44) else { throw QMPClientError.malformedMessage }
      }
    case 34: return .string(try string())
    case 116:
      try literal("true")
      return .bool(true)
    case 102:
      try literal("false")
      return .bool(false)
    case 110:
      try literal("null")
      return .null
    case 45, 48...57: return .number(try number())
    default: throw QMPClientError.malformedMessage
    }
  }

  private mutating func literal(_ text: String) throws {
    let expected = Array(text.utf8)
    guard position <= bytes.count - expected.count,
      Array(bytes[position..<position + expected.count]) == expected
    else { throw QMPClientError.malformedMessage }
    position += expected.count
  }

  private mutating func string() throws -> String {
    guard position < bytes.count, bytes[position] == 34 else {
      throw QMPClientError.malformedMessage
    }
    let start = position
    position += 1
    while position < bytes.count {
      let byte = bytes[position]
      position += 1
      if byte == 34 {
        do {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position]))
        } catch { throw QMPClientError.malformedMessage }
      }
      guard byte >= 32 else { throw QMPClientError.malformedMessage }
      if byte == 92 {
        guard position < bytes.count else { throw QMPClientError.malformedMessage }
        position += 1
      }
    }
    throw QMPClientError.malformedMessage
  }

  private mutating func number() throws -> String {
    let start = position
    if bytes[position] == 45 { position += 1 }
    guard position < bytes.count else { throw QMPClientError.malformedMessage }
    if bytes[position] == 48 {
      position += 1
    } else {
      guard (49...57).contains(bytes[position]) else { throw QMPClientError.malformedMessage }
      digits()
    }
    if position < bytes.count, bytes[position] == 46 {
      position += 1
      let before = position
      digits()
      guard position > before else { throw QMPClientError.malformedMessage }
    }
    if position < bytes.count, bytes[position] == 101 || bytes[position] == 69 {
      position += 1
      if position < bytes.count, bytes[position] == 43 || bytes[position] == 45 { position += 1 }
      let before = position
      digits()
      guard position > before else { throw QMPClientError.malformedMessage }
    }
    return String(decoding: bytes[start..<position], as: UTF8.self)
  }

  private mutating func digits() {
    while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
  }
}
