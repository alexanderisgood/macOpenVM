// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// A reconnect creates a new client and requires a new status observation. Closing
/// or cancelling this client affects only its connection, never the worker runtime.
public actor WorkerIPCClient {
  private let transport: WorkerSocket
  private let vmID: UUID
  private let sessionID: UUID
  private let timeout: Duration
  private var connected = false
  private var closed = false
  private var busy = false
  private var nextID: UInt64 = 1
  private var observedRevision: UInt64?

  public init(socketURL: URL, vmID: UUID, sessionID: UUID, timeout: Duration = .seconds(3)) {
    transport = WorkerSocket(socketURL: socketURL)
    self.vmID = vmID
    self.sessionID = sessionID
    self.timeout = timeout
  }

  public func connect() async throws {
    guard !closed else { throw WorkerIPCError.closed }
    guard !busy else { throw WorkerIPCError.busy }
    guard !connected else { throw WorkerIPCError.alreadyConnected }
    guard timeout > .zero, timeout <= .seconds(30) else { throw WorkerIPCError.invalidTimeout }
    busy = true
    defer { busy = false }
    let transport = transport
    let deadline = ContinuousClock().now.advanced(by: timeout)
    do {
      try Task.checkCancellation()
      try await withTaskCancellationHandler {
        try await transport.perform { try $0.connect(deadline: deadline) }
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard !closed else { throw WorkerIPCError.closed }
      connected = true
    } catch {
      await close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  public func request(
    _ command: WorkerCommand, observedRevision revision: UInt64 = 0
  ) async throws -> WorkerResponse {
    guard !closed else { throw WorkerIPCError.closed }
    guard connected else { throw WorkerIPCError.notConnected }
    guard !busy else { throw WorkerIPCError.busy }
    guard nextID <= 32 else { throw WorkerIPCError.limitExceeded }
    if command == .status {
      guard revision == 0 else { throw WorkerIPCError.statusRequired }
    } else {
      guard let observedRevision, observedRevision == revision else {
        throw WorkerIPCError.statusRequired
      }
    }
    let request = WorkerRequest(
      vmID: vmID, sessionID: sessionID, requestID: nextID, observedRevision: revision,
      command: command)
    nextID += 1
    observedRevision = nil
    busy = true
    defer { busy = false }
    let bytes = try WorkerFrameCodec.encode(request: request)
    let transport = transport
    let deadline = ContinuousClock().now.advanced(by: timeout)
    do {
      try Task.checkCancellation()
      let response = try await withTaskCancellationHandler {
        try await transport.perform {
          try $0.rejectPendingReply()
          try $0.write(bytes, deadline: deadline)
          return try WorkerFrameCodec.decodeResponse($0.readFrame(deadline: deadline))
        }
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard !closed else { throw WorkerIPCError.closed }
      guard response.vmID == vmID, response.sessionID == sessionID,
        response.requestID == request.requestID
      else { throw WorkerIPCError.unexpectedReply }
      if command == .status { observedRevision = response.revision }
      return response
    } catch {
      await close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  public func close() async {
    closed = true
    connected = false
    observedRevision = nil
    await transport.close()
  }
}

/// The server owns accepted callbacks through completion, including after EOF or
/// client cancellation. A transport shutdown never cancels a runtime operation.
public actor WorkerIPCServer {
  private enum State { case idle, starting, listening, finishing, closed }
  private let listener: WorkerSocket
  private let handler: @Sendable (WorkerRequest) async -> WorkerResponse
  private let captureCapability: CaptureCapability?
  private let captureHandler: (@Sendable (CaptureWorkerRequest, UUID) async -> CaptureWorkerReply)?
  private let captureDisconnected: (@Sendable (UUID, Bool) async -> Void)?
  private var state: State = .idle
  private var acceptTask: Task<Void, Never>?
  private var connections: [UUID: WorkerSocket] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]

  public init(
    socketURL: URL, handler: @escaping @Sendable (WorkerRequest) async -> WorkerResponse
  ) {
    listener = WorkerSocket(socketURL: socketURL)
    self.handler = handler
    captureCapability = nil
    captureHandler = nil
    captureDisconnected = nil
  }

  /// Explicit package seam only. Each connection chooses v1 or capture v2 on
  /// its first bounded frame; the server's actual UUID stays out of the wire.
  package init(
    socketURL: URL, producerCaptureCapability: CaptureCapability,
    handler: @escaping @Sendable (WorkerRequest) async -> WorkerResponse,
    producerCapture: @escaping @Sendable (CaptureWorkerRequest, UUID) async -> CaptureWorkerReply,
    captureDisconnected: @escaping @Sendable (UUID, Bool) async -> Void
  ) {
    listener = WorkerSocket(socketURL: socketURL)
    self.handler = handler
    captureCapability = producerCaptureCapability
    captureHandler = producerCapture
    self.captureDisconnected = captureDisconnected
  }

  public func start() async throws {
    guard state == .idle else { throw WorkerIPCError.alreadyConnected }
    state = .starting
    do {
      let listener = listener
      try await withTaskCancellationHandler {
        try await listener.perform { try $0.listen() }
      } onCancel: {
        listener.signalClose()
      }
      try Task.checkCancellation()
      guard state == .starting else { throw WorkerIPCError.closed }
      state = .listening
      acceptTask = Task { await self.acceptLoop() }
    } catch {
      await close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  /// Stops accepting. Existing reads have a three-second idle bound; an already
  /// accepted callback and its response finish before their connection closes.
  /// The callback's runtime deadline is the coordinator's responsibility.
  public func finishWhenIdle() async {
    if state != .closed { state = .finishing }
    await listener.close()
    await acceptTask?.value
    acceptTask = nil
    let pending = Array(tasks.values)
    for task in pending { await task.value }
    state = .closed
  }

  /// Closes descriptors immediately. Accepted callbacks remain owned until done.
  public func close() async {
    state = .closed
    await listener.close()
    let sockets = Array(connections.values)
    for socket in sockets { await socket.close() }
    await acceptTask?.value
    acceptTask = nil
  }

  private func acceptLoop() async {
    while state == .listening {
      do {
        let listener = listener
        try await listener.waitForConnection()
        guard let socket = try await listener.perform({ try $0.accept() }) else { continue }
        guard state == .listening, connections.count < 8 else {
          await socket.close()
          continue
        }
        let id = UUID()
        connections[id] = socket
        if captureCapability == .boundedProducerV1 {
          tasks[id] = Task { await self.serveOptIn(socket, id: id) }
        } else {
          tasks[id] = Task { await self.serve(socket, id: id) }
        }
      } catch {
        if state == .listening {
          state = .closed
          await listener.close()
          for socket in Array(connections.values) { await socket.close() }
        }
        break
      }
    }
  }

  private func serve(_ socket: WorkerSocket, id: UUID, firstPayload: Data? = nil) async {
    var lastID: UInt64 = 0
    var identity: (UUID, UUID)?
    var freshRevision: UInt64?
    var initial = firstPayload
    for _ in 0..<32 {
      guard state == .listening else { break }
      do {
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        let request: WorkerRequest
        if let payload = initial {
          initial = nil
          request = try WorkerFrameCodec.decodeRequest(payload)
        } else {
          request = try await socket.perform {
            try WorkerFrameCodec.decodeRequest($0.readFrame(deadline: deadline))
          }
        }
        // Finish/close can run while this idle connection awaits its next frame.
        // Admission occurs here, before the callback, with no intervening await.
        guard state == .listening else { break }
        guard request.requestID > lastID else { throw WorkerIPCError.malformedFrame }
        if let identity {
          guard identity.0 == request.vmID, identity.1 == request.sessionID else {
            throw WorkerIPCError.unexpectedReply
          }
        } else {
          guard request.command == .status else { throw WorkerIPCError.statusRequired }
          identity = (request.vmID, request.sessionID)
        }
        if request.command == .status {
          guard request.observedRevision == 0 else { throw WorkerIPCError.statusRequired }
        } else {
          guard freshRevision == request.observedRevision else {
            throw WorkerIPCError.statusRequired
          }
        }
        lastID = request.requestID
        freshRevision = nil
        // This owned task is never cancelled when the peer closes its socket.
        let response = await handler(request)
        guard response.vmID == request.vmID, response.sessionID == request.sessionID,
          response.requestID == request.requestID
        else { throw WorkerIPCError.unexpectedReply }
        if request.command == .status {
          freshRevision = response.revision
        }
        let bytes = try WorkerFrameCodec.encode(response: response)
        let writeDeadline = ContinuousClock().now.advanced(by: .seconds(3))
        try await socket.perform { try $0.write(bytes, deadline: writeDeadline) }
      } catch { break }
    }
    await socket.close()
    connections[id] = nil
    tasks[id] = nil
  }

  private func serveOptIn(_ socket: WorkerSocket, id: UUID) async {
    var pageReplyUncertain = false
    do {
      let deadline = ContinuousClock().now.advanced(by: .seconds(3))
      let first = try await socket.perform { try $0.readCaptureNegotiation(deadline: deadline) }
      if case .legacy(let payload) = first {
        await serve(socket, id: id, firstPayload: payload)
        return
      }
      guard case .capture(let frame) = first, let captureHandler else {
        throw CaptureFault.unavailable
      }
      var nextFrame: Data? = frame
      var binding: CaptureBinding?
      for index in 1...96 {
        guard state == .listening else { break }
        let request: CaptureWorkerRequest
        if let frame = nextFrame {
          nextFrame = nil
          request = try WorkerCaptureFrameCodec.decodeRequest(frame)
        } else {
          let deadline = ContinuousClock().now.advanced(by: .seconds(3))
          request = try await socket.perform {
            try WorkerCaptureFrameCodec.decodeRequest(
              $0.readCaptureFrame(request: true, deadline: deadline))
          }
        }
        guard state == .listening, request.requestID == UInt64(index) else {
          throw CaptureFault.stale
        }
        if let binding {
          guard request.binding == binding, request.operation != .hello else {
            throw CaptureFault.identity
          }
        } else {
          guard request.operation == .hello else { throw CaptureFault.notReady }
          binding = request.binding
        }
        // Task dictionary/self retain this callback through completion. Neither
        // EOF nor server.close cancels it or supplies a replacement connection.
        if request.operation == .read { pageReplyUncertain = true }
        let reply = await captureHandler(request, id)
        try WorkerCaptureFrameCodec.validateEcho(reply, request: request)
        let bytes = try WorkerCaptureFrameCodec.encode(reply)
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        try await socket.perform { try $0.writeCaptureFrame(bytes, deadline: deadline) }
        // A full write proves only local socket acceptance. This protocol has
        // no page ACK, so keep the uncertainty through every later request and
        // EOF; it must not be cleared by a status reply or ordinary teardown.
        if reply.code != .ok { break }
      }
    } catch {
      // Diagnostic transport loss has no guest/process/lifecycle cleanup action.
    }
    // Notification follows callback completion/cursor commit, including EPIPE.
    await captureDisconnected?(id, pageReplyUncertain)
    await socket.close()
    connections[id] = nil
    tasks[id] = nil
  }
}
