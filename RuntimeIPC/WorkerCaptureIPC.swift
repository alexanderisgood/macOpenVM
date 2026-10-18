// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// One opt-in connection to the existing worker endpoint, never a QMP endpoint.
/// Any uncertain response ends this diagnostic; there is no reconnect/replay API.
package actor WorkerCaptureIPCClient {
  private let transport: WorkerSocket
  private let binding: CaptureBinding
  private let timeout: Duration
  private var connected = false
  private var closed = false
  private var busy = false
  private var nextID: UInt64 = 1
  private var revision: UInt64 = 0
  private var attached = false
  private var armAttempted = false
  private var stopAttempted = false
  private var capture: UInt64 = 0
  private var statuses = 0
  private var pages = 0
  private var snapshot: CaptureStatus?
  package private(set) var diagnosticLost = false

  package init(socketURL: URL, binding: CaptureBinding, timeout: Duration = .seconds(3)) {
    transport = WorkerSocket(socketURL: socketURL)
    self.binding = binding
    self.timeout = timeout
  }

  package func connect() async throws {
    guard !closed, !connected, !busy else { throw CaptureFault.closed }
    guard timeout > .zero, timeout <= .seconds(30) else { throw WorkerIPCError.invalidTimeout }
    busy = true
    defer { busy = false }
    let deadline = ContinuousClock().now.advanced(by: timeout)
    let transport = transport
    do {
      try Task.checkCancellation()
      try await withTaskCancellationHandler {
        try await transport.perform { try $0.connect(deadline: deadline) }
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard !closed else { throw CaptureFault.closed }
      connected = true
    } catch {
      await close()
      throw error
    }
  }

  package func hello() async throws -> CaptureWorkerReply { try await exchange(.hello) }
  package func status() async throws -> CaptureWorkerReply { try await exchange(.status) }
  package func arm(_ id: UInt64) async throws -> CaptureWorkerReply {
    guard !armAttempted, snapshot?.phase == .disarmed, id > 0,
      id <= UInt64(Int64.max)
    else { throw CaptureFault.alreadyUsed }
    return try await exchange(.arm, newCapture: id)
  }
  package func stop() async throws -> CaptureWorkerReply {
    guard armAttempted, !stopAttempted else { throw CaptureFault.alreadyUsed }
    return try await exchange(.stop)
  }
  package func read(count: UInt16 = 64) async throws -> CaptureWorkerReply {
    guard let snapshot, snapshot.terminal, snapshot.cursor < snapshot.records,
      pages < 64
    else { throw CaptureFault.notReady }
    return try await exchange(.read, offset: snapshot.cursor, count: count)
  }

  private func exchange(
    _ operation: CaptureWorkerOperation, newCapture: UInt64? = nil,
    offset: UInt32 = 0, count: UInt16 = 0
  ) async throws -> CaptureWorkerReply {
    guard connected, !closed else { throw CaptureFault.closed }
    guard !busy else { throw CaptureFault.busy }
    guard nextID <= 96, operation != .status || statuses < 16 else { throw CaptureFault.limit }
    guard attached ? operation != .hello : operation == .hello else { throw CaptureFault.notReady }
    let request = CaptureWorkerRequest(
      binding: binding, requestID: nextID,
      observedRevision: operation == .hello ? 0 : revision, operation: operation,
      capture: newCapture ?? capture, offset: offset, count: count)
    let bytes = try WorkerCaptureFrameCodec.encode(request)
    nextID += 1
    switch operation {
    case .arm:
      armAttempted = true
      capture = request.capture
    case .stop: stopAttempted = true
    case .status: statuses += 1
    case .read: pages += 1
    case .hello: break
    }
    busy = true
    defer { busy = false }
    let transport = transport
    let deadline = ContinuousClock().now.advanced(by: timeout)
    do {
      try Task.checkCancellation()
      // Conservative unknown-outcome marker precedes every potentially sent
      // mutation/page. Only a complete validated reply can clear it.
      if operation == .arm || operation == .stop || operation == .read { diagnosticLost = true }
      let reply = try await withTaskCancellationHandler {
        try await transport.perform {
          try $0.rejectPendingReply()
          try $0.writeCaptureRequest(bytes, deadline: deadline)
          return try WorkerCaptureFrameCodec.decodeReply(
            $0.readCaptureFrame(request: false, deadline: deadline))
        }
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard !closed else { throw CaptureFault.closed }
      try WorkerCaptureFrameCodec.validateEcho(reply, request: request)
      if let old = snapshot, old.terminal, let status = reply.status {
        guard status.terminal, status.capture == old.capture, status.records == old.records,
          status.reasons == old.reasons, status.cursor >= old.cursor
        else {
          throw CaptureFault.malformed
        }
      } else if let old = snapshot, let status = reply.status, old.capture == status.capture {
        guard status.phase.rawValue >= old.phase.rawValue else { throw CaptureFault.malformed }
      }
      if operation == .read, let status = reply.status {
        for row in reply.rows {
          let index = row.words[0]
          if index == 0 {
            guard row.words[1] == 1, row.words[14] == 4096, row.words[15] == 144 else {
              throw CaptureFault.malformed
            }
          } else if index == UInt64(status.records - 1) {
            guard row.words[1] == 2, row.words[14] == UInt64(status.records),
              row.words[15] == UInt64(status.reasons)
            else { throw CaptureFault.malformed }
          } else {
            guard (3...10).contains(row.words[1]) else { throw CaptureFault.malformed }
          }
        }
      }
      if reply.code != .ok {
        await close()
        return reply
      }
      attached = true
      revision = reply.revision
      snapshot = reply.status ?? snapshot
      diagnosticLost = false
      return reply
    } catch {
      await close()
      throw error
    }
  }

  package func close() async {
    closed = true
    connected = false
    await transport.close()
  }
}
