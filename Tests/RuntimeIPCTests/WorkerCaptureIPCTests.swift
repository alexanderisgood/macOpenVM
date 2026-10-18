// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import RuntimeIPC
import Testing

private actor CaptureIPCProbe {
  var calls: [CaptureWorkerOperation] = []
  var connections: [UUID] = []
  var ended: [UUID] = []
  var lostReplies: [UUID] = []
  var capture: UInt64 = 0
  var spent = false
  var cursor: UInt32 = 0
  var records: UInt32 = 2
  var gateRead = false
  var entered = false
  var committedReads = 0
  private var released = false
  private var gate: CheckedContinuation<Void, Never>?
  func blockRead() { gateRead = true }
  func useMaximumRecords() { records = 4096 }
  func release() {
    released = true
    gate?.resume()
    gate = nil
  }
  func recordEnded(_ id: UUID, lostReply: Bool) {
    ended.append(id)
    if lostReply { lostReplies.append(id) }
  }
  func handle(_ request: CaptureWorkerRequest, id: UUID) async -> CaptureWorkerReply {
    calls.append(request.operation)
    connections.append(id)
    if request.operation == .read, gateRead {
      entered = true
      if !released { await withCheckedContinuation { gate = $0 } }
    }
    let first = cursor
    switch request.operation {
    case .arm: capture = request.capture
    case .stop: spent = true
    case .read:
      cursor += min(UInt32(request.count), records - cursor)
      committedReads += 1
    default: break
    }
    let status: CaptureStatus?
    if request.operation == .hello {
      status = nil
    } else {
      status = try? CaptureStatus(
        capture: capture,
        phase: spent ? 6 : capture == 0 ? 0 : 2, records: spent ? records : 0,
        reasons: spent ? 1 : 0, cursor: cursor, terminal: spent ? 1 : 0)
    }
    var rows: [CaptureRow] = []
    if request.operation == .read {
      rows = (first..<cursor).compactMap { index in
        var words = [UInt64](repeating: 0, count: 18)
        words[0] = UInt64(index)
        words[1] = index == 0 ? 1 : index == records - 1 ? 2 : 3
        words[3] = capture
        words[4] = UInt64(index) + 1
        if index == 0 {
          words[14] = 4096
          words[15] = 144
        }
        if index == records - 1 {
          words[14] = UInt64(records)
          words[15] = 1
        }
        return try? CaptureRow(words)
      }
    }
    return CaptureWorkerReply(
      binding: request.binding, requestID: request.requestID,
      revision: request.observedRevision + 1, operation: request.operation, code: .ok,
      rejection: nil, status: status, rows: rows)
  }
}

private func captureIPCUntil(_ body: @Sendable () async -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !(await body()) {
    guard ContinuousClock.now < deadline else { throw CaptureFault.notReady }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func withCaptureIPCServer(
  optedIn: Bool = true,
  body: @Sendable (WorkerIPCServer, CaptureIPCProbe, URL, CaptureBinding) async throws -> Void
) async throws {
  let directory = URL(fileURLWithPath: "/private/tmp/mvo-cap-ipc-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let socket = directory.appendingPathComponent("worker.sock")
  let binding = CaptureBinding(vmID: UUID(), sessionID: UUID(), monitorEpoch: UUID())
  let probe = CaptureIPCProbe()
  let ordinary: @Sendable (WorkerRequest) async -> WorkerResponse = { request in
    WorkerResponse(
      vmID: request.vmID, sessionID: request.sessionID, requestID: request.requestID,
      revision: 7, state: 2, ownership: 0, backendActive: true, operationPending: false,
      error: .none)
  }
  let server =
    optedIn
    ? WorkerIPCServer(
      socketURL: socket, producerCaptureCapability: .boundedProducerV1, handler: ordinary,
      producerCapture: { await probe.handle($0, id: $1) },
      captureDisconnected: { await probe.recordEnded($0, lostReply: $1) })
    : WorkerIPCServer(socketURL: socket, handler: ordinary)
  let result: Result<Void, Error>
  do {
    try await server.start()
    try await body(server, probe, socket, binding)
    result = .success(())
  } catch { result = .failure(error) }
  await probe.release()
  await server.close()
  // close never cancels accepted callbacks; retain and join them before removal.
  await server.finishWhenIdle()
  let cleanup: Result<Void, Error>
  do {
    try FileManager.default.removeItem(at: directory)
    cleanup = .success(())
  } catch { cleanup = .failure(error) }
  try result.get()
  try cleanup.get()
}

@Suite(.serialized) struct WorkerCaptureIPCTests {
  @Test func defaultV1ServerRejectsV2WithoutDispatchAndKeepsOrdinaryStatus() async throws {
    try await withCaptureIPCServer(optedIn: false) { _, probe, socket, binding in
      let capture = WorkerCaptureIPCClient(socketURL: socket, binding: binding)
      do {
        try await capture.connect()
        var rejected = false
        do { _ = try await capture.hello() } catch { rejected = true }
        #expect(rejected)
        await capture.close()
      } catch {
        await capture.close()
        throw error
      }
      let ordinary = WorkerIPCClient(
        socketURL: socket, vmID: binding.vmID, sessionID: binding.sessionID)
      do {
        try await ordinary.connect()
        let status = try await ordinary.request(.status)
        #expect(status.state == 2 && status.error == .none)
        await ordinary.close()
      } catch {
        await ordinary.close()
        throw error
      }
      #expect(await probe.calls.isEmpty)
    }
  }

  @Test func optedInServerKeepsV1AndUsesOneActualUUIDForTheV2Connection() async throws {
    try await withCaptureIPCServer { _, probe, socket, binding in
      let ordinary = WorkerIPCClient(
        socketURL: socket, vmID: binding.vmID, sessionID: binding.sessionID)
      do {
        try await ordinary.connect()
        _ = try await ordinary.request(.status)
        await ordinary.close()
      } catch {
        await ordinary.close()
        throw error
      }
      let capture = WorkerCaptureIPCClient(socketURL: socket, binding: binding)
      do {
        try await capture.connect()
        _ = try await capture.hello()
        _ = try await capture.status()
        _ = try await capture.arm(19)
        _ = try await capture.stop()
        let page = try await capture.read()
        #expect(page.rows.count == 2 && page.status?.cursor == 2)
        await capture.close()
      } catch {
        await capture.close()
        throw error
      }
      try await captureIPCUntil { await probe.ended.count == 1 }
      let ids = await probe.connections
      let ended = await probe.ended
      #expect(ids.count == 5 && Set(ids).count == 1 && ended == [ids[0]])
    }
  }

  @Test func cancelledReaderDoesNotCancelAcceptedCallbackOrItsPageCommit() async throws {
    try await withCaptureIPCServer { _, probe, socket, binding in
      let capture = WorkerCaptureIPCClient(socketURL: socket, binding: binding)
      do {
        try await capture.connect()
        _ = try await capture.hello()
        _ = try await capture.status()
        _ = try await capture.arm(19)
        _ = try await capture.stop()
        await probe.blockRead()
        let pending = Task { try await capture.read() }
        do {
          try await captureIPCUntil { await probe.entered }
          pending.cancel()
          await capture.close()
          _ = await pending.result
          let before = await probe.committedReads
          let ended = await probe.ended
          #expect(before == 0 && ended.isEmpty)
          await probe.release()
          try await captureIPCUntil { await probe.ended.count == 1 }
          #expect(await probe.committedReads == 1)
          #expect(await probe.lostReplies.count == 1)
          #expect(await capture.diagnosticLost)
        } catch {
          pending.cancel()
          await probe.release()
          await capture.close()
          _ = await pending.result
          throw error
        }
      } catch {
        await probe.release()
        await capture.close()
        throw error
      }
    }
  }

  @Test func fullPageWriteAndLaterStatusNeverProvePeerReceiptAtDisconnect() async throws {
    try await withCaptureIPCServer { _, probe, socket, binding in
      let capture = WorkerCaptureIPCClient(socketURL: socket, binding: binding)
      do {
        try await capture.connect()
        _ = try await capture.hello()
        _ = try await capture.status()
        _ = try await capture.arm(19)
        _ = try await capture.stop()
        let page = try await capture.read()
        #expect(page.rows.count == 2 && page.status?.cursor == 2)
        // The fixture sees the page, but the server has no receipt ACK. Even a
        // later valid status cannot turn its local send into delivery evidence.
        let status = try await capture.status()
        #expect(status.status?.cursor == 2)
        #expect(!(await capture.diagnosticLost))
        await capture.close()
      } catch {
        await capture.close()
        throw error
      }
      try await captureIPCUntil { await probe.ended.count == 1 }
      let ids = await probe.connections
      #expect(await probe.committedReads == 1)
      #expect(await probe.lostReplies == [ids[0]])
    }
  }

  @Test func actualOptInSocketTransfersTheMaximumSixtyFourRowFrame() async throws {
    try await withCaptureIPCServer { _, probe, socket, binding in
      await probe.useMaximumRecords()
      let capture = WorkerCaptureIPCClient(socketURL: socket, binding: binding)
      do {
        try await capture.connect()
        _ = try await capture.hello()
        _ = try await capture.status()
        _ = try await capture.arm(19)
        _ = try await capture.stop()
        let page = try await capture.read()
        #expect(page.rows.count == 64 && page.status?.cursor == 64)
        let bytes = try WorkerCaptureFrameCodec.encode(page)
        #expect(bytes.count == 9324)
        await capture.close()
      } catch {
        await capture.close()
        throw error
      }
    }
  }

  @Test func optedInListenerRetainsTheOrdinaryThirtyTwoRequestBudget() async throws {
    try await withCaptureIPCServer { _, _, socket, binding in
      let ordinary = WorkerIPCClient(
        socketURL: socket, vmID: binding.vmID, sessionID: binding.sessionID)
      do {
        try await ordinary.connect()
        for _ in 0..<32 {
          let status = try await ordinary.request(.status)
          #expect(status.error == .none)
        }
        var rejected = false
        do { _ = try await ordinary.request(.status) } catch WorkerIPCError.limitExceeded {
          rejected = true
        }
        #expect(rejected)
        await ordinary.close()
      } catch {
        await ordinary.close()
        throw error
      }
    }
  }
}
