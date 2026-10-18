// SPDX-License-Identifier: Apache-2.0
// Unrun local numeric scripted-peer source; no QEMU/worker/Metal/VM fixture.
import BackendAPI
import Darwin
import Dispatch
import Foundation
import Qemu
import Testing

private enum CapturePeerFault: Error { case setup, io, timeout, command, script }

private enum CapturePeerFinishWindow {
  case normal, heldOpenControl
  var deadline: DispatchTime {
    switch self {
    case .normal: .now() + 4
    case .heldOpenControl: .now() + .milliseconds(50)
    }
  }
}

private struct CapturePeerFinishFacts {
  let stickyFailure: Bool
  let fallbackStarted: Bool
  let eofBeforeFallback: Bool
}

/// One queue owns the listener/accepted descriptor through natural join.
/// Shared facts/shutdown publication are locked; setup rollback precedes the queue.
private final class CaptureQMPPeer: @unchecked Sendable {
  let directory: URL
  let socketURL: URL
  let reached = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "local.macOpenVM.capture-qmp-fixture")
  private let group = DispatchGroup()
  private var listener: Int32 = -1
  private var connection: Int32 = -1
  private var stopped = false
  private var removed = false
  private var scriptFailed = false
  private var eof = false
  private var finishFailed = false
  private var fallbackStarted = false
  private var eofBeforeFallback = false

  init(_ script: @escaping @Sendable (CapturePeerWire, CaptureQMPPeer) throws -> Void) throws {
    directory = URL(fileURLWithPath: "/private/tmp/mvo-cap-qmp-\(UUID().uuidString)")
    socketURL = directory.appendingPathComponent("qmp.sock")
    var started = false
    var directoryCreated = false
    defer {
      if !started {
        closeDescriptors()
        if directoryCreated { try? FileManager.default.removeItem(at: directory) }
      }
    }
    guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw CapturePeerFault.setup }
    directoryCreated = true
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CapturePeerFault.setup }
    listener = descriptor
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(socketURL.path, 0o600) == 0,
      Darwin.listen(descriptor, 1) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
    else {
      throw CapturePeerFault.setup
    }
    group.enter()
    started = true
    queue.async {
      defer {
        self.closeDescriptors()
        self.group.leave()
      }
      do {
        let accepted = try self.accept(descriptor)
        let flags = fcntl(accepted, F_GETFL)
        guard flags >= 0, fcntl(accepted, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
          throw CapturePeerFault.setup
        }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        guard
          setsockopt(
            accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout<Int32>.size)) == 0,
          setsockopt(
            accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(
            accepted, SOL_SOCKET, SO_SNDTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)) == 0
        else { throw CapturePeerFault.setup }
        try script(CapturePeerWire(descriptor: accepted), self)
      } catch {
        self.lock.lock()
        self.scriptFailed = true
        self.lock.unlock()
      }
    }
  }
  private func accept(_ descriptor: Int32) throws -> Int32 {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      lock.lock()
      let unavailable = stopped
      lock.unlock()
      if unavailable { throw CapturePeerFault.timeout }
      let accepted = Darwin.accept(descriptor, nil, nil)
      if accepted >= 0 {
        lock.lock()
        connection = accepted
        if stopped { _ = Darwin.shutdown(accepted, SHUT_RDWR) }
        lock.unlock()
        return accepted
      }
      guard errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK else {
        throw CapturePeerFault.io
      }
      var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      _ = Darwin.poll(&item, 1, 10)
    }
    throw CapturePeerFault.timeout
  }
  private func closeDescriptors() {
    lock.lock()
    let first = connection
    let second = listener
    connection = -1
    listener = -1
    lock.unlock()
    if first >= 0 { Darwin.close(first) }
    if second >= 0 { Darwin.close(second) }
  }
  func observedEOF() {
    lock.lock()
    eof = true
    if !fallbackStarted { eofBeforeFallback = true }
    lock.unlock()
  }
  func finishFacts() -> CapturePeerFinishFacts {
    lock.lock()
    defer { lock.unlock() }
    return CapturePeerFinishFacts(
      stickyFailure: finishFailed,
      fallbackStarted: fallbackStarted, eofBeforeFallback: eofBeforeFallback)
  }
  func reachedCommand() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: self.reached.wait(timeout: .now() + 2) == .success)
      }
    }
  }
  func finish(window: CapturePeerFinishWindow = .normal) throws {
    lock.lock()
    let alreadyFailed = finishFailed
    lock.unlock()
    if !alreadyFailed {
      // Normal acceptance cannot cause the EOF it is about to inspect: do not
      // stop, shutdown, or release until the script has completed independently.
      let joined = group.wait(timeout: window.deadline) == .success
      lock.lock()
      if !joined || scriptFailed || !eof { finishFailed = true }
      let failed = finishFailed
      lock.unlock()
      if !failed {
        do { try removeDirectoryAfterJoin() } catch {
          lock.lock()
          finishFailed = true
          lock.unlock()
          throw error
        }
        return
      }
    }
    try failedCleanup()
    throw CapturePeerFault.script
  }
  func finishAfterFailure() {
    // Preserve the body's original failure; cleanup is never a new success path.
    do { try failedCleanup() } catch { Issue.record("Failed scripted peer directory cleanup") }
  }
  private func failedCleanup() throws {
    lock.lock()
    // This latch precedes every operation capable of manufacturing EOF. It is
    // never cleared, including by late script completion or repeated finish.
    finishFailed = true
    fallbackStarted = true
    stopped = true
    if connection >= 0 { _ = Darwin.shutdown(connection, SHUT_RDWR) }
    if listener >= 0 { _ = Darwin.shutdown(listener, SHUT_RDWR) }
    lock.unlock()
    release.signal()
    // Sticky failure is never permission to abandon an actually started queue.
    group.wait()
    try removeDirectoryAfterJoin()
  }
  private func removeDirectoryAfterJoin() throws {
    lock.lock()
    let shouldRemove = !removed
    lock.unlock()
    if shouldRemove {
      try FileManager.default.removeItem(at: directory)
      lock.lock()
      removed = true
      lock.unlock()
    }
  }
}

/// These controls use a real connected Unix socket. The owner retains its raw
/// descriptor through failed peer.finish; the peer cannot call client.close.
private final class CaptureRawClient {
  private(set) var descriptor: Int32 = -1
  init(socketURL: URL) throws {
    let opened = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard opened >= 0 else { throw CapturePeerFault.setup }
    var ready = false
    defer { if !ready { Darwin.close(opened) } }
    var noSignal: Int32 = 1
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    guard fcntl(opened, F_SETFD, FD_CLOEXEC) == 0,
      setsockopt(
        opened, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout<Int32>.size)) == 0,
      setsockopt(
        opened, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0,
      setsockopt(
        opened, SOL_SOCKET, SO_SNDTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0
    else { throw CapturePeerFault.setup }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(socketURL.path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw CapturePeerFault.setup
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(opened, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw CapturePeerFault.setup }
    descriptor = opened
    ready = true
  }
  deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
  func close() throws {
    let owned = descriptor
    descriptor = -1
    if owned >= 0, Darwin.close(owned) != 0 { throw CapturePeerFault.io }
  }
  func exchangeControlBytes() throws {
    let wire = CapturePeerWire(descriptor: descriptor)
    try wire.send("raw-control\n")
    try wire.expect("raw-ready\n")
  }
}

private struct CapturePeerWire: Sendable {
  let descriptor: Int32
  func send(_ text: String, fragment: Int = .max) throws {
    let bytes = Array(text.utf8)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var offset = 0
    while offset < bytes.count {
      guard ContinuousClock.now < deadline else { throw CapturePeerFault.timeout }
      let sent = bytes.withUnsafeBytes {
        Darwin.send(
          descriptor, $0.baseAddress?.advanced(by: offset), min(fragment, bytes.count - offset), 0)
      }
      if sent < 0, errno == EINTR { continue }
      guard sent > 0 else { throw CapturePeerFault.io }
      offset += sent
    }
  }
  func expect(_ literal: String) throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var bytes: [UInt8] = []
    while bytes.count < 512 {
      guard ContinuousClock.now < deadline else { throw CapturePeerFault.timeout }
      var byte: UInt8 = 0
      let count = Darwin.recv(descriptor, &byte, 1, 0)
      if count < 0, errno == EINTR { continue }
      guard count == 1 else { throw CapturePeerFault.io }
      bytes.append(byte)
      if byte == 10 {
        guard bytes == Array(literal.utf8) else { throw CapturePeerFault.command }
        return
      }
    }
    throw CapturePeerFault.command
  }
  func handshake() throws {
    try send(
      "{\"QMP\":{\"version\":{\"qemu\":{\"major\":11,\"minor\":1,\"micro\":0},\"package\":\"capture-fixture\"},\"capabilities\":[\"oob\"]}}\r\n",
      fragment: 7)
    try expect("{\"execute\":\"qmp_capabilities\",\"id\":1}\r\n")
    try send("{\"return\":{},\"id\":1}\r\n", fragment: 5)
  }
  func waitEOF(_ peer: CaptureQMPPeer) throws {
    var byte: UInt8 = 0
    guard Darwin.recv(descriptor, &byte, 1, 0) == 0 else { throw CapturePeerFault.command }
    peer.observedEOF()
  }
}

private let qmpCaptureID = UInt64(Int64.max)
private func captureSnapshot(
  _ phase: UInt32 = 6, records: UInt32 = 2,
  cursor: UInt32 = 0, reasons: UInt32 = 1,
  capture: UInt64 = qmpCaptureID
) throws -> CaptureStatus {
  try CaptureStatus(
    capture: capture, phase: phase, records: phase == 6 ? records : 0,
    reasons: phase == 6 ? reasons : 0, cursor: phase == 6 ? cursor : 0,
    terminal: phase == 6 ? 1 : 0)
}
private func statusJSON(
  capture: UInt64 = qmpCaptureID, phase: UInt32 = 2,
  records: UInt32 = 0, reasons: UInt32 = 0, cursor: UInt32 = 0
) -> String {
  "{\"capture\":\(capture),\"phase\":\(phase),\"records\":\(records),\"reasons\":\(reasons),\"cursor\":\(cursor),\"terminal\":\(phase == 6 ? 1 : 0)}"
}
private func rowJSON(
  _ index: UInt32, records: UInt32 = 2, reasons: UInt32 = 1,
  capture: UInt64 = qmpCaptureID, wide: Bool = false
) -> String {
  var words = [UInt64](repeating: 0, count: 18)
  words[0] = UInt64(index)
  words[1] = index == 0 ? 1 : index == records - 1 ? 2 : 3
  words[3] = capture
  words[4] = UInt64(index) + 1
  words[10] = UInt64(index) + 100
  if index == 0 {
    words[14] = 4096
    words[15] = 144
  }
  if index == records - 1 {
    words[14] = UInt64(records)
    words[15] = UInt64(reasons)
  }
  if wide {
    words[6] = UInt64.max
    words[12] = UInt64.max
    words[17] = UInt64.max
  }
  return "{" + zip(CaptureRow.keys, words).map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
    + "}"
}
private func withCapturePeer(
  optedIn: Bool = true,
  timeout: Duration = .seconds(3),
  script: @escaping @Sendable (CapturePeerWire, CaptureQMPPeer) throws -> Void,
  body: (QMPClient, CaptureQMPPeer) async throws -> Void
) async throws {
  let peer = try CaptureQMPPeer(script)
  let client =
    optedIn
    ? QMPClient(
      socketURL: peer.socketURL, timeout: timeout, producerCaptureCapability: .boundedProducerV1)
    : QMPClient(socketURL: peer.socketURL, timeout: timeout)
  do {
    try await client.connect()
    try await body(client, peer)
    await client.close()
    try peer.finish()
  } catch {
    let original = error
    await client.close()
    peer.finishAfterFailure()
    throw original
  }
}
private func qmpError(_ expected: QMPClientError, _ body: () async throws -> Void) async {
  do {
    try await body()
    Issue.record("Expected typed QMP failure")
  } catch { #expect((error as? QMPClientError) == expected) }
}

@Suite("QMPProducerCaptureTests", .serialized)
struct QMPProducerCaptureTests {
  @Test func publicInitializerRefusesAllCaptureCallsBeforeSending() async throws {
    try await withCapturePeer(optedIn: false) { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"query-status\",\"id\":2}\r\n")
      try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":2}\r\n")
      try wire.waitEOF(peer)
    } body: { client, _ in
      let terminal = try captureSnapshot()
      for operation in 0..<4 {
        do {
          switch operation {
          case 0: _ = try await client.producerCaptureArm(qmpCaptureID)
          case 1: _ = try await client.producerCaptureStatus(expectedCapture: 0)
          case 2: _ = try await client.producerCaptureStop(expectedCapture: qmpCaptureID)
          default: _ = try await client.producerCaptureRead(terminalStatus: terminal, count: 64)
          }
          Issue.record("Default client admitted capture")
        } catch { #expect((error as? CaptureFault) == .unavailable) }
      }
      #expect(try await client.queryStatus().running)
      let observation = await client.observation()
      #expect(observation.connectionEpoch == client.connectionEpoch && observation.failure == nil)
    }
  }

  @Test func invalidLocalLimitsSendNothingAndDoNotConsumeAnIdentifier() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"query-status\",\"id\":2}\r\n")
      try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":2}\r\n")
      try wire.waitEOF(peer)
    } body: { client, _ in
      let terminal = try captureSnapshot()
      let nonterminal = try captureSnapshot(2)
      let exhausted = try captureSnapshot(cursor: 2)
      for operation in 0..<8 {
        do {
          switch operation {
          case 0: _ = try await client.producerCaptureArm(0)
          case 1: _ = try await client.producerCaptureArm(UInt64.max)
          case 2: _ = try await client.producerCaptureStatus(expectedCapture: UInt64.max)
          case 3: _ = try await client.producerCaptureStop(expectedCapture: 0)
          case 4: _ = try await client.producerCaptureRead(terminalStatus: terminal, count: 0)
          case 5: _ = try await client.producerCaptureRead(terminalStatus: terminal, count: 65)
          case 6: _ = try await client.producerCaptureRead(terminalStatus: nonterminal, count: 64)
          default: _ = try await client.producerCaptureRead(terminalStatus: exhausted, count: 64)
          }
          Issue.record("Invalid local request was admitted")
        } catch { #expect((error as? CaptureFault) == (operation >= 6 ? .notReady : .limit)) }
      }
      #expect(try await client.queryStatus().running)
      #expect(await client.observation().failure == nil)
    }
  }

  @Test func fourTypedCommandsAndLifecycleShareIdentifiersAndEpoch() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":2}\r\n")
      try wire.send("{\"return\":\(statusJSON(capture: 0, phase: 0)),\"id\":2}\r\n")
      try wire.expect(
        "{\"execute\":\"x-mvo-producer-capture-arm\",\"arguments\":{\"capture\":9223372036854775807},\"id\":3}\r\n"
      )
      try wire.send("{\"return\":\(statusJSON()),\"id\":3}\r\n")
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":4}\r\n")
      try wire.send("{\"return\":\(statusJSON()),\"id\":4}\r\n")
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-stop\",\"id\":5}\r\n")
      try wire.send("{\"return\":\(statusJSON(phase: 6, records: 2, reasons: 1)),\"id\":5}\r\n")
      try wire.expect(
        "{\"execute\":\"x-mvo-producer-capture-read\",\"arguments\":{\"offset\":0,\"count\":64},\"id\":6}\r\n"
      )
      try wire.send("{\"return\":[\(rowJSON(0)),\(rowJSON(1))],\"id\":6}\r\n", fragment: 17)
      try wire.expect("{\"execute\":\"query-status\",\"id\":7}\r\n")
      try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":7}\r\n")
      try wire.waitEOF(peer)
    } body: { client, _ in
      let epoch = client.connectionEpoch
      #expect(
        try await client.producerCaptureStatus(expectedCapture: 0)
          == .status(
            CaptureStatus(capture: 0, phase: 0, records: 0, reasons: 0, cursor: 0, terminal: 0)))
      #expect(try await client.producerCaptureArm(qmpCaptureID) == .status(captureSnapshot(2)))
      #expect(
        try await client.producerCaptureStatus(expectedCapture: qmpCaptureID)
          == .status(captureSnapshot(2)))
      let terminal = try captureSnapshot()
      #expect(
        try await client.producerCaptureStop(expectedCapture: qmpCaptureID) == .status(terminal))
      guard
        case .rows(let rows) = try await client.producerCaptureRead(
          terminalStatus: terminal, count: 64)
      else {
        Issue.record("Expected typed numeric rows")
        return
      }
      #expect(rows.count == 2 && rows[0].words[1] == 1 && rows[1].words[1] == 2)
      #expect(terminal.cursor == 0 && terminal.reasons == 1 && terminal.records == 2)
      #expect(try await client.queryStatus().running)
      let observation = await client.observation()
      #expect(client.connectionEpoch == epoch && observation.connectionEpoch == epoch)
      #expect(
        !observation.readerDrained && observation.failure == nil && observation.shutdown == nil)
    }
  }

  @Test func everyExactKnownCaptureRejectionAllowsSameMonitorLifecycleQuery() async throws {
    let cases: [(String, CaptureRejection)] = [
      ("Producer capture rejected (numeric code 1)", .invalid),
      ("Producer capture rejected (numeric code 2)", .busy),
      ("Producer capture rejected (numeric code 3)", .alreadyUsed),
      ("Producer capture rejected (numeric code 4)", .notReady),
      ("Producer capture rejected (numeric code 5)", .notLockFree),
      ("Producer capture owner/lock-free admission failed", .ownerAdmission),
      ("Producer capture ID is outside the numeric range", .captureRange),
      ("Producer capture read is outside the numeric range", .readRange),
    ]
    for (description, expected) in cases {
      try await withCapturePeer { wire, peer in
        try wire.handshake()
        try wire.expect(
          "{\"execute\":\"x-mvo-producer-capture-arm\",\"arguments\":{\"capture\":9223372036854775807},\"id\":2}\r\n"
        )
        try wire.send(
          "{\"error\":{\"class\":\"GenericError\",\"desc\":\"\(description)\"},\"id\":2}\r\n",
          fragment: 11)
        try wire.expect("{\"execute\":\"query-status\",\"id\":3}\r\n")
        try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":3}\r\n")
        try wire.waitEOF(peer)
      } body: { client, _ in
        let epoch = client.connectionEpoch
        let rejection = try await client.producerCaptureArm(qmpCaptureID)
        #expect(rejection == .rejected(expected))
        let status = try await client.queryStatus()
        #expect(status.running)
        let observation = await client.observation()
        #expect(observation.connectionEpoch == epoch && !observation.readerDrained)
        #expect(
          observation.failure == nil && !observation.intentionalClose && observation.shutdown == nil
        )
      }
    }
  }

  @Test func maximumPageRetainsExactFullUInt64Words() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect(
        "{\"execute\":\"x-mvo-producer-capture-read\",\"arguments\":{\"offset\":0,\"count\":64},\"id\":2}\r\n"
      )
      let rows = (0..<64).map { rowJSON(UInt32($0), records: 4096, reasons: 2, wide: $0 == 1) }
      try wire.send("{\"return\":[\(rows.joined(separator: ","))],\"id\":2}\r\n", fragment: 97)
      try wire.waitEOF(peer)
    } body: { client, _ in
      let terminal = try captureSnapshot(records: 4096, reasons: 2)
      guard
        case .rows(let rows) = try await client.producerCaptureRead(
          terminalStatus: terminal, count: 64)
      else {
        Issue.record("Expected max numeric page")
        return
      }
      #expect(rows.count == 64 && rows[63].words[0] == 63)
      #expect(
        rows[1].words[6] == UInt64.max && rows[1].words[12] == UInt64.max
          && rows[1].words[17] == UInt64.max)
      #expect(await client.observation().failure == nil)
    }
  }

  @Test func fixedProducerGpuDiagnosticKindsKeepTheSameMonitorUsable() async throws {
    for kind in UInt64(1)...3 {
      let flags = (kind << 16) | 1
      let diagnostic = rowJSON(1, records: 3)
        .replacingOccurrences(of: "\"event\":3", with: "\"event\":10")
        .replacingOccurrences(of: "\"flags\":0", with: "\"flags\":\(flags)")
      try await withCapturePeer { wire, peer in
        try wire.handshake()
        try wire.expect(
          "{\"execute\":\"x-mvo-producer-capture-read\",\"arguments\":{\"offset\":0,\"count\":64},\"id\":2}\r\n"
        )
        let rows = rowJSON(0, records: 3) + "," + diagnostic + "," + rowJSON(2, records: 3)
        try wire.send("{\"return\":[\(rows)],\"id\":2}\r\n", fragment: 17)
        try wire.expect("{\"execute\":\"query-status\",\"id\":3}\r\n")
        try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":3}\r\n")
        try wire.waitEOF(peer)
      } body: { client, _ in
        let epoch = client.connectionEpoch
        let terminal = try captureSnapshot(records: 3)
        guard
          case .rows(let rows) = try await client.producerCaptureRead(
            terminalStatus: terminal, count: 64)
        else {
          Issue.record("Expected complete START/GPU_DIAGNOSTIC/END page")
          return
        }
        #expect(rows.count == 3 && rows[1].words[1] == 10 && rows[1].words[2] == flags)
        #expect(rows[0].words[14] == 4096 && rows[2].words[14] == 3)
        #expect(try await client.queryStatus().running)
        #expect(await client.observation().failure == nil && client.connectionEpoch == epoch)
      }
    }
  }

  @Test func undocumentedGpuDiagnosticFlagsStillCloseTheMonitor() async throws {
    for flags in [UInt64(0), 7, 0x0004_0001, 0x0001_0009, .max] {
      let diagnostic = rowJSON(1, records: 3)
        .replacingOccurrences(of: "\"event\":3", with: "\"event\":10")
        .replacingOccurrences(of: "\"flags\":0", with: "\"flags\":\(flags)")
      try await withCapturePeer { wire, peer in
        try wire.handshake()
        try wire.expect(
          "{\"execute\":\"x-mvo-producer-capture-read\",\"arguments\":{\"offset\":0,\"count\":64},\"id\":2}\r\n"
        )
        let rows = rowJSON(0, records: 3) + "," + diagnostic + "," + rowJSON(2, records: 3)
        try wire.send("{\"return\":[\(rows)],\"id\":2}\r\n")
        try wire.waitEOF(peer)
      } body: { client, _ in
        let terminal = try captureSnapshot(records: 3)
        await qmpError(.malformedMessage) {
          _ = try await client.producerCaptureRead(terminalStatus: terminal, count: 64)
        }
        await qmpError(.closed) { _ = try await client.queryStatus() }
        #expect(await client.settledObservation().failure == .malformedMessage)
      }
    }
  }

  @Test func finalShortPageCorrelatesImmutableTerminalFacts() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect(
        "{\"execute\":\"x-mvo-producer-capture-read\",\"arguments\":{\"offset\":4095,\"count\":64},\"id\":2}\r\n"
      )
      try wire.send("{\"return\":[\(rowJSON(4095, records: 4096, reasons: 2))],\"id\":2}\r\n")
      try wire.waitEOF(peer)
    } body: { client, _ in
      let terminal = try captureSnapshot(records: 4096, cursor: 4095, reasons: 2)
      guard
        case .rows(let rows) = try await client.producerCaptureRead(
          terminalStatus: terminal, count: 64)
      else {
        Issue.record("Expected final short page")
        return
      }
      #expect(rows.count == 1 && rows[0].words[0] == 4095 && rows[0].words[1] == 2)
      #expect(rows[0].words[14] == 4096 && rows[0].words[15] == 2)
      #expect(terminal.cursor == 4095 && terminal.records == 4096 && terminal.reasons == 2)
    }
  }

  @Test func sameIDWrongCaptureOffsetCountAndEndFactsCloseTheMonitor() async throws {
    for kind in ["capture", "offset", "oversize", "short", "end", "maxoversize"] {
      let large = kind == "offset" || kind == "short" || kind == "maxoversize"
      let count: UInt16 = kind == "short" || kind == "end" || kind == "maxoversize" ? 64 : 1
      let records: UInt32 = large ? 4096 : 2
      try await withCapturePeer { wire, peer in
        try wire.handshake()
        try wire.expect(
          "{\"execute\":\"x-mvo-producer-capture-read\",\"arguments\":{\"offset\":0,\"count\":\(count)},\"id\":2}\r\n"
        )
        let rows: String
        switch kind {
        case "capture": rows = rowJSON(0, capture: qmpCaptureID - 1)
        case "offset": rows = rowJSON(7, records: 4096, reasons: 2)
        case "oversize": rows = rowJSON(0) + "," + rowJSON(1)
        case "short": rows = rowJSON(0, records: 4096, reasons: 2)
        case "maxoversize":
          rows = (0..<65).map { rowJSON(UInt32($0), records: 4096, reasons: 2) }.joined(
            separator: ",")
        default: rows = rowJSON(0) + "," + rowJSON(1, reasons: 0)
        }
        try wire.send("{\"return\":[\(rows)],\"id\":2}\r\n")
        try wire.waitEOF(peer)
      } body: { client, _ in
        let terminal = try captureSnapshot(records: records, reasons: large ? 2 : 1)
        await qmpError(.malformedMessage) {
          _ = try await client.producerCaptureRead(terminalStatus: terminal, count: count)
        }
        await qmpError(.closed) { _ = try await client.queryStatus() }
        #expect(await client.settledObservation().failure == .malformedMessage)
      }
    }
  }

  @Test func malformedStatusNumericAliasesDuplicatesAndFieldsAreTerminal() async throws {
    let base = statusJSON()
    let cases = [
      base.replacingOccurrences(of: "9223372036854775807", with: "true"),
      base.replacingOccurrences(of: "9223372036854775807", with: "9223372036854775807.0"),
      base.replacingOccurrences(of: "9223372036854775807", with: "18446744073709551616"),
      base.replacingOccurrences(of: "9223372036854775807", with: "9223372036854775806"),
      base.replacingOccurrences(of: "\"phase\":2", with: "\"phase\":1"),
      base.replacingOccurrences(of: "\"terminal\":0", with: "\"terminal\":false"),
      base.replacingOccurrences(of: "\"terminal\":0", with: "\"terminal\":0,\"terminal\":0"),
      base.replacingOccurrences(of: "\"terminal\":0", with: "\"terminal\":0,\"extra\":0"),
    ]
    for value in cases {
      try await withCapturePeer { wire, peer in
        try wire.handshake()
        try wire.expect(
          "{\"execute\":\"x-mvo-producer-capture-arm\",\"arguments\":{\"capture\":9223372036854775807},\"id\":2}\r\n"
        )
        try wire.send("{\"return\":\(value),\"id\":2}\r\n")
        try wire.waitEOF(peer)
      } body: { client, _ in
        await qmpError(.malformedMessage) { _ = try await client.producerCaptureArm(qmpCaptureID) }
        await qmpError(.closed) { _ = try await client.queryStatus() }
      }
    }
  }

  @Test func unknownCaptureErrorsAndWrongClassesRemainTerminal() async throws {
    for name in ["GenericError", "CommandNotFound"] {
      try await withCapturePeer { wire, peer in
        try wire.handshake()
        try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":2}\r\n")
        let desc =
          name == "GenericError"
          ? "unknown bounded fixture" : "Producer capture rejected (numeric code 2)"
        try wire.send("{\"error\":{\"class\":\"\(name)\",\"desc\":\"\(desc)\"},\"id\":2}\r\n")
        try wire.waitEOF(peer)
      } body: { client, _ in
        await qmpError(.commandRejected(name)) {
          _ = try await client.producerCaptureStatus(expectedCapture: 0)
        }
        await qmpError(.closed) { _ = try await client.queryStatus() }
      }
    }
  }

  @Test func ordinaryLifecycleRejectionCannotEnterCaptureExceptionPath() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"query-status\",\"id\":2}\r\n")
      try wire.send(
        "{\"error\":{\"class\":\"GenericError\",\"desc\":\"Producer capture rejected (numeric code 2)\"},\"id\":2}\r\n"
      )
      try wire.waitEOF(peer)
    } body: { client, _ in
      await qmpError(.commandRejected("GenericError")) { _ = try await client.queryStatus() }
      await qmpError(.closed) { _ = try await client.producerCaptureStatus(expectedCapture: 0) }
    }
  }

  @Test func malformedKnownErrorEnvelopesCannotEnterCaptureExceptionPath() async throws {
    let errors = [
      "{\"class\":\"GenericError\",\"desc\":\"Producer capture rejected (numeric code 2)\",\"extra\":0}",
      "{\"class\":\"GenericError\",\"desc\":false}",
      "{\"class\":\"GenericError\",\"class\":\"GenericError\",\"desc\":\"Producer capture rejected (numeric code 2)\"}",
    ]
    for value in errors {
      try await withCapturePeer { wire, peer in
        try wire.handshake()
        try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":2}\r\n")
        try wire.send("{\"error\":\(value),\"id\":2}\r\n")
        try wire.waitEOF(peer)
      } body: { client, _ in
        await qmpError(.malformedMessage) {
          _ = try await client.producerCaptureStatus(expectedCapture: 0)
        }
        await qmpError(.closed) { _ = try await client.queryStatus() }
      }
    }
  }

  @Test func captureReplyStillRequiresTheExactActiveIdentifier() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":2}\r\n")
      try wire.send("{\"return\":\(statusJSON(capture: 0, phase: 0)),\"id\":3}\r\n")
      try wire.waitEOF(peer)
    } body: { client, _ in
      await qmpError(.unexpectedReply) {
        _ = try await client.producerCaptureStatus(expectedCapture: 0)
      }
      await qmpError(.closed) { _ = try await client.queryStatus() }
    }
  }

  @Test func pendingCaptureMakesLifecycleAndCaptureBusyWithoutSpendingIds() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":2}\r\n")
      peer.reached.signal()
      guard peer.release.wait(timeout: .now() + 2) == .success else {
        throw CapturePeerFault.timeout
      }
      try wire.send("{\"return\":\(statusJSON(capture: 0, phase: 0)),\"id\":2}\r\n")
      try wire.expect("{\"execute\":\"query-status\",\"id\":3}\r\n")
      try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":3}\r\n")
      try wire.waitEOF(peer)
    } body: { client, peer in
      let pending = Task { try await client.producerCaptureStatus(expectedCapture: 0) }
      do {
        guard await peer.reachedCommand() else { throw CapturePeerFault.timeout }
        await qmpError(.busy) { _ = try await client.queryStatus() }
        await qmpError(.busy) { _ = try await client.producerCaptureStatus(expectedCapture: 0) }
        peer.release.signal()
        _ = try await pending.value
        #expect(try await client.queryStatus().running)
      } catch {
        pending.cancel()
        peer.release.signal()
        await client.close()
        _ = await pending.result
        throw error
      }
    }
  }

  @Test func pendingLifecycleMakesCaptureBusyWithoutPoisoningConnection() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"query-status\",\"id\":2}\r\n")
      peer.reached.signal()
      guard peer.release.wait(timeout: .now() + 2) == .success else {
        throw CapturePeerFault.timeout
      }
      try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":2}\r\n")
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":3}\r\n")
      try wire.send("{\"return\":\(statusJSON(capture: 0, phase: 0)),\"id\":3}\r\n")
      try wire.waitEOF(peer)
    } body: { client, peer in
      let pending = Task { try await client.queryStatus() }
      do {
        guard await peer.reachedCommand() else { throw CapturePeerFault.timeout }
        await qmpError(.busy) { _ = try await client.producerCaptureStatus(expectedCapture: 0) }
        peer.release.signal()
        #expect(try await pending.value.running)
        _ = try await client.producerCaptureStatus(expectedCapture: 0)
      } catch {
        pending.cancel()
        peer.release.signal()
        await client.close()
        _ = await pending.result
        throw error
      }
    }
  }

  @Test func cancellationOfPartialCaptureSettlesOnlyTheExistingMonitor() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect(
        "{\"execute\":\"x-mvo-producer-capture-arm\",\"arguments\":{\"capture\":9223372036854775807},\"id\":2}\r\n"
      )
      try wire.send("{\"return\":")
      peer.reached.signal()
      try wire.waitEOF(peer)
    } body: { client, peer in
      let epoch = client.connectionEpoch
      let pending = Task { try await client.producerCaptureArm(qmpCaptureID) }
      do {
        guard await peer.reachedCommand() else { throw CapturePeerFault.timeout }
        pending.cancel()
        do {
          _ = try await pending.value
          Issue.record("Cancelled capture completed")
        } catch { #expect(error is CancellationError) }
      } catch {
        pending.cancel()
        await client.close()
        _ = await pending.result
        throw error
      }
      let observation = await client.settledObservation()
      #expect(
        observation.connectionEpoch == epoch && observation.intentionalClose
          && observation.readerDrained)
      #expect(observation.shutdown == nil && !observation.naturalEOF)
      await qmpError(.closed) { _ = try await client.queryStatus() }
    }
  }

  @Test func explicitCloseDuringCaptureDrainsTheSameEpoch() async throws {
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":2}\r\n")
      peer.reached.signal()
      try wire.waitEOF(peer)
    } body: { client, peer in
      let pending = Task { try await client.producerCaptureStatus(expectedCapture: 0) }
      do {
        guard await peer.reachedCommand() else { throw CapturePeerFault.timeout }
        await client.close()
        await qmpError(.closed) { _ = try await pending.value }
      } catch {
        await client.close()
        _ = await pending.result
        throw error
      }
      let observation = await client.settledObservation()
      #expect(observation.connectionEpoch == client.connectionEpoch && observation.readerDrained)
      #expect(observation.intentionalClose && observation.shutdown == nil)
    }
  }

  @Test func captureUsesTheExistingCommandDeadlineAndTerminalFailure() async throws {
    try await withCapturePeer(timeout: .milliseconds(100)) { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":2}\r\n")
      try wire.waitEOF(peer)
    } body: { client, _ in
      await qmpError(.deadlineExceeded) {
        _ = try await client.producerCaptureStatus(expectedCapture: 0)
      }
      let observation = await client.settledObservation()
      #expect(observation.failure == .deadlineExceeded && observation.readerDrained)
      #expect(observation.shutdown == nil && !observation.naturalEOF)
      await qmpError(.closed) { _ = try await client.queryStatus() }
    }
  }

  @Test func heldOpenRawClientCannotSatisfyNormalFinishThroughCleanupEOF() throws {
    let peer = try CaptureQMPPeer { wire, peer in
      try wire.expect("raw-control\n")
      try wire.send("raw-ready\n")
      peer.reached.signal()
      try wire.waitEOF(peer)
    }
    var retained: CaptureRawClient?
    do {
      let client = try CaptureRawClient(socketURL: peer.socketURL)
      retained = client
      try client.exchangeControlBytes()
      guard peer.reached.wait(timeout: .now() + 2) == .success else {
        throw CapturePeerFault.timeout
      }
      // No client close/shutdown has occurred. Keep this real FD live while
      // finish reaches its failed cleanup and naturally joins the script.
      #expect(fcntl(client.descriptor, F_GETFD) >= 0)
      var rejected = false
      do { try peer.finish(window: .heldOpenControl) } catch CapturePeerFault.script {
        rejected = true
      }
      try #require(rejected)
      let facts = peer.finishFacts()
      #expect(facts.stickyFailure && facts.fallbackStarted)
      #expect(fcntl(client.descriptor, F_GETFD) >= 0)
      try client.close()
      // A later actual close or cleanup-induced EOF cannot rescue acceptance.
      var repeatedRejection = false
      do { try peer.finish() } catch CapturePeerFault.script { repeatedRejection = true }
      #expect(repeatedRejection)
      #expect(peer.finishFacts().stickyFailure)
    } catch {
      let original = error
      do { try retained?.close() } catch { Issue.record("Raw control client cleanup failed") }
      peer.finishAfterFailure()
      throw original
    }
  }

  @Test func explicitRawClientCloseProvidesIndependentEOFFinishControl() throws {
    let peer = try CaptureQMPPeer { wire, peer in
      try wire.expect("raw-control\n")
      try wire.send("raw-ready\n")
      peer.reached.signal()
      try wire.waitEOF(peer)
    }
    var retained: CaptureRawClient?
    do {
      let client = try CaptureRawClient(socketURL: peer.socketURL)
      retained = client
      try client.exchangeControlBytes()
      guard peer.reached.wait(timeout: .now() + 2) == .success else {
        throw CapturePeerFault.timeout
      }
      try client.close()
      try peer.finish()
      let facts = peer.finishFacts()
      #expect(!facts.stickyFailure && !facts.fallbackStarted && facts.eofBeforeFallback)
      // Normal finish is repeatable only after independently established EOF.
      try peer.finish()
    } catch {
      let original = error
      do { try retained?.close() } catch { Issue.record("Raw control client cleanup failed") }
      peer.finishAfterFailure()
      throw original
    }
  }

  @Test func rawReceiveMeterChargesFragmentedCaptureAndExcludesOrdinaryReplies() async throws {
    let reply =
      "{\"return\":{\"capture\":0,\"phase\":0,\"records\":0,\"reasons\":0,\"cursor\":0,\"terminal\":0},\"id\":3}\r\n"
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      try wire.expect("{\"execute\":\"query-status\",\"id\":2}\r\n")
      try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":2}\r\n")
      try wire.expect("{\"execute\":\"x-mvo-producer-capture-status\",\"id\":3}\r\n")
      try wire.send(reply, fragment: 3)
      try wire.expect("{\"execute\":\"query-status\",\"id\":4}\r\n")
      try wire.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":4}\r\n")
      try wire.waitEOF(peer)
    } body: { client, _ in
      _ = try await client.queryStatus()
      let before = await client.producerCaptureRawReadBytes()
      #expect(before == 0)
      _ = try await client.producerCaptureStatus(expectedCapture: 0)
      let captured = await client.producerCaptureRawReadBytes()
      #expect(captured == UInt64(reply.utf8.count))
      _ = try await client.queryStatus()
      let afterOrdinary = await client.producerCaptureRawReadBytes()
      #expect(afterOrdinary == captured)
    }
  }

  @Test func actualRawCaptureReadsStopAtEightMiBEvenWhenValidatedStatusIsTiny() async throws {
    // Generated event bytes precede each tiny status reply. They must count at
    // actual recv, although neither the typed status nor its reencoding contains
    // them. Each exchange remains below original aggregate/event/line limits.
    let event =
      "{\"event\":\"CAPTURE_FIXTURE\",\"data\":{\"padding\":\""
      + String(repeating: "x", count: 4000)
      + "\"},\"timestamp\":{\"seconds\":0,\"microseconds\":0}}\r\n"
    let events = String(repeating: event, count: 60)
    try await withCapturePeer { wire, peer in
      try wire.handshake()
      do {
        for index in 0..<36 {
          let identifier = index + 2
          try wire.expect(
            "{\"execute\":\"x-mvo-producer-capture-status\",\"id\":\(identifier)}\r\n")
          let reply =
            "{\"return\":{\"capture\":0,\"phase\":0,\"records\":0,\"reasons\":0,\"cursor\":0,\"terminal\":0},\"id\":\(identifier)}\r\n"
          try wire.send(events + reply)
        }
        throw CapturePeerFault.command  // a missing raw budget cannot pass
      } catch CapturePeerFault.io {
        try wire.waitEOF(peer)
      }
    } body: { client, _ in
      var exhausted = false
      for _ in 0..<36 {
        do { _ = try await client.producerCaptureStatus(expectedCapture: 0) } catch {
          #expect((error as? QMPClientError) == .limitExceeded)
          exhausted = true
          break
        }
      }
      #expect(exhausted)
      let actual = await client.producerCaptureRawReadBytes()
      #expect(actual == 8_388_608)
      await qmpError(.closed) { _ = try await client.queryStatus() }
    }
  }
}
