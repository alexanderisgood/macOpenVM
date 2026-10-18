// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import Qemu
import Testing

private enum PeerFailure: Error {
  case posix(Int32)
  case setup(String, Int32)
  case commandShape(String)
  case unexpectedCommand, timeout
}

private struct PeerCommand {
  let name: String
  let identifier: Int
}

/// Independent tiny wire peer. Its script uses real AF_UNIX reads/writes;
/// descriptor publication/shutdown is locked, and close stays on the worker.
private final class QMPFakePeer: @unchecked Sendable {
  let directory: URL
  let socketURL: URL
  let reachedCommand = DispatchSemaphore(value: 0)
  let releaseReply = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let worker = DispatchQueue(label: "local.macOpenVM.qmp-test-peer")
  private let group = DispatchGroup()
  private var listener: Int32 = -1
  private var connection: Int32 = -1
  private var stopped = false
  private var removedDirectory = false
  private var failure: String?
  private var didObserveEOF = false

  init(script: @escaping @Sendable (PeerConnection, QMPFakePeer) throws -> Void) throws {
    directory = URL(fileURLWithPath: "/private/tmp/mvo-qmp-\(UUID().uuidString)", isDirectory: true)
    socketURL = directory.appendingPathComponent("qmp.sock")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let created = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard created >= 0 else { throw PeerFailure.posix(errno) }
    listener = created
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(created, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    var setupFailure: (String, Int32)?
    if bound != 0 {
      setupFailure = ("bind", errno)
    } else if chmod(socketURL.path, 0o600) != 0 {
      setupFailure = ("chmod", errno)
    } else if Darwin.listen(created, 1) != 0 {
      setupFailure = ("listen", errno)
    } else if fcntl(created, F_SETFL, O_NONBLOCK) != 0 {
      setupFailure = ("nonblocking", errno)
    }
    if let (operation, code) = setupFailure {
      Darwin.close(created)
      listener = -1
      try? FileManager.default.removeItem(at: directory)
      throw PeerFailure.setup(operation, code)
    }
    group.enter()
    worker.async {
      defer {
        self.finishDescriptors()
        self.group.leave()
      }
      do {
        let accepted = try self.accept(created)
        // Darwin accepts inherit O_NONBLOCK; this independent peer uses bounded
        // blocking reads on its dedicated worker instead.
        let flags = fcntl(accepted, F_GETFL)
        guard flags >= 0, fcntl(accepted, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
          throw PeerFailure.posix(errno)
        }
        var noSignal: Int32 = 1
        _ = setsockopt(
          accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
          accepted, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(
          accepted, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        try script(PeerConnection(descriptor: accepted), self)
      } catch {
        self.lock.lock()
        if !self.stopped { self.failure = String(describing: error) }
        self.lock.unlock()
      }
    }
  }

  private func accept(_ listener: Int32) throws -> Int32 {
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      lock.lock()
      let unavailable = stopped
      lock.unlock()
      if unavailable { throw PeerFailure.timeout }
      let value = Darwin.accept(listener, nil, nil)
      if value >= 0 {
        lock.lock()
        connection = value
        if stopped { _ = Darwin.shutdown(value, SHUT_RDWR) }
        lock.unlock()
        return value
      }
      if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        throw PeerFailure.posix(errno)
      }
      var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      _ = Darwin.poll(&item, 1, 10)
    }
    throw PeerFailure.timeout
  }

  private func finishDescriptors() {
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
    didObserveEOF = true
    lock.unlock()
  }

  var sawEOF: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didObserveEOF
  }

  var scriptFailure: String? {
    lock.lock()
    defer { lock.unlock() }
    return failure
  }

  func waitForCommand() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: self.reachedCommand.wait(timeout: .now() + 1) == .success)
      }
    }
  }

  func finish(requireCleanScript: Bool = true) throws {
    lock.lock()
    stopped = true
    if connection >= 0 { _ = Darwin.shutdown(connection, SHUT_RDWR) }
    if listener >= 0 { _ = Darwin.shutdown(listener, SHUT_RDWR) }
    lock.unlock()
    releaseReply.signal()
    guard group.wait(timeout: .now() + 4) == .success else { throw PeerFailure.timeout }
    lock.lock()
    let error = failure
    let removeDirectory = !removedDirectory
    removedDirectory = true
    lock.unlock()
    if removeDirectory { try FileManager.default.removeItem(at: directory) }
    if requireCleanScript, error != nil { throw PeerFailure.unexpectedCommand }
  }
}

private struct PeerConnection: Sendable {
  let descriptor: Int32
  static let greeting =
    "{\"QMP\":{\"version\":{\"qemu\":{\"major\":11,\"minor\":1,\"micro\":0},\"package\":\"test\"},\"capabilities\":[\"oob\"]}}\r\n"
  static let event = "{\"event\":\"STOP\",\"timestamp\":{\"seconds\":1,\"microseconds\":2}}\r\n"
  static let guestShutdown =
    "{\"event\":\"SHUTDOWN\",\"data\":{\"guest\":true,\"reason\":\"guest-shutdown\"},\"timestamp\":{\"seconds\":1,\"microseconds\":2}}\r\n"

  func send(_ text: String, fragment: Int = .max) throws {
    let data = Array(text.utf8)
    var offset = 0
    while offset < data.count {
      let count = min(fragment, data.count - offset)
      let written = data.withUnsafeBytes {
        Darwin.send(descriptor, $0.baseAddress?.advanced(by: offset), count, 0)
      }
      guard written > 0 else { throw PeerFailure.posix(errno) }
      offset += written
      if fragment < data.count { usleep(500) }
    }
  }

  func command(_ expected: String, id: Int, mouseIndex: Int? = nil) throws -> PeerCommand {
    var data = Data()
    while data.count < 512 {
      var byte: UInt8 = 0
      let count = Darwin.recv(descriptor, &byte, 1, 0)
      guard count == 1 else { throw PeerFailure.posix(errno) }
      data.append(byte)
      if byte == 10 {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys)
            == (mouseIndex == nil ? ["execute", "id"] : ["execute", "id", "arguments"]),
          mouseIndex == nil
            || (object["arguments"] as? [String: String]) == [
              "command-line": "mouse_set \(mouseIndex ?? 0)"
            ],
          let name = object["execute"] as? String,
          let identifier = object["id"] as? Int, name == expected, identifier == id
        else { throw PeerFailure.commandShape(String(decoding: data.prefix(512), as: UTF8.self)) }
        return PeerCommand(name: name, identifier: identifier)
      }
    }
    throw PeerFailure.unexpectedCommand
  }

  func handshake(fragment: Int = .max, eventBeforeAck: Bool = false) throws {
    try send(Self.greeting, fragment: fragment)
    _ = try command("qmp_capabilities", id: 1)
    try send(
      (eventBeforeAck ? Self.event : "") + "{\"return\":{},\"id\":1}\r\n", fragment: fragment)
  }

  func waitForEOF(_ peer: QMPFakePeer) throws {
    var byte: UInt8 = 0
    guard Darwin.recv(descriptor, &byte, 1, 0) == 0 else { throw PeerFailure.unexpectedCommand }
    peer.observedEOF()
  }
}

private func monitorFinished(_ client: QMPClient) async throws -> QMPMonitorObservation {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while ContinuousClock.now < deadline {
    if await client.observation().readerDrained { return await client.settledObservation() }
    try await Task.sleep(for: .milliseconds(5))
  }
  await client.close()
  throw PeerFailure.timeout
}

private func expectError<T>(_ expected: QMPClientError, _ operation: () async throws -> T) async {
  do {
    _ = try await operation()
    Issue.record("Expected QMP failure: \(expected)")
  } catch let error as QMPClientError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Suite("QMPClientTests", .serialized)
struct QMPClientTests {
  @Test func relativeSelectionUsesOnlyQueriedIndexAndVerifiesActualDevice() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("query-mice", id: 2)
      try connection.send(
        "{\"return\":[{\"name\":\"USB mouse\",\"index\":7,\"absolute\":false,\"current\":false},{\"name\":\"USB tablet\",\"index\":9,\"absolute\":true,\"current\":true}],\"id\":2}\r\n"
      )
      _ = try connection.command("human-monitor-command", id: 3, mouseIndex: 7)
      try connection.send("{\"return\":\"\",\"id\":3}\r\n")
      _ = try connection.command("query-mice", id: 4)
      try connection.send(
        "{\"return\":[{\"name\":\"USB mouse\",\"index\":7,\"absolute\":false,\"current\":true},{\"name\":\"USB tablet\",\"index\":9,\"absolute\":true,\"current\":false}],\"id\":4}\r\n"
      )
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    try await client.selectRelativeMouse(true)
    await client.close()
    try peer.finish()
  }

  @Test func powerdownAckOnlyRetainsLiveConnectionAndIsNotShutdown() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("system_powerdown", id: 2)
      try connection.send("{\"return\":{},\"id\":2}\r\n")
      _ = try connection.command("query-status", id: 3)
      try connection.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":3}\r\n")
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    try await client.powerdown()
    #expect(try await client.queryStatus().running)
    let open = try await client.drainObservation()
    #expect(open.connectionEpoch == client.connectionEpoch && open.shutdown == nil)
    #expect(!open.naturalEOF && !open.readerDrained && open.failure == nil)
    await client.close()
    let closed = await client.settledObservation()
    #expect(closed.intentionalClose && !closed.naturalEOF && closed.readerDrained)
    try peer.finish()
  }

  @Test(arguments: [true, false])
  func shutdownBeforeOrAfterAckRetainsFinalSameConnectionEvidence(_ before: Bool) async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.handshake()
      _ = try connection.command("system_powerdown", id: 2)
      let ack = "{\"return\":{},\"id\":2}\r\n"
      try connection.send(
        before ? PeerConnection.guestShutdown + ack : ack + PeerConnection.guestShutdown)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    try await client.powerdown()
    let observation = try await monitorFinished(client)
    #expect(
      observation.connectionEpoch == client.connectionEpoch && observation.guestShutdownObserved)
    #expect(observation.naturalEOF && observation.readerDrained && !observation.intentionalClose)
    #expect(observation.failure == nil)
    await client.close()
    #expect(await client.settledObservation() == observation)
    try peer.finish()
  }

  @Test func idleFragmentedShutdownIsReadWithoutAnotherCommand() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      guard peer.releaseReply.wait(timeout: .now() + 1) == .success else {
        throw PeerFailure.timeout
      }
      try connection.send(PeerConnection.guestShutdown, fragment: 1)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    peer.releaseReply.signal()
    let observation = try await monitorFinished(client)
    #expect(
      observation.guestShutdownObserved && observation.naturalEOF && observation.failure == nil)
    try peer.finish()
  }

  @Test func finalShutdownAndEOFPreserveEvidenceWithoutCommandAck() async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.handshake()
      _ = try connection.command("system_powerdown", id: 2)
      try connection.send(PeerConnection.guestShutdown)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    await expectError(.disconnected) { try await client.powerdown() }
    let observation = try await monitorFinished(client)
    #expect(
      observation.guestShutdownObserved && observation.naturalEOF && observation.readerDrained)
    #expect(!observation.intentionalClose && observation.failure == nil)
    #expect(try await client.drainObservation() == observation)
    try peer.finish()
  }

  @Test(arguments: ["host-qmp-quit", "host-signal", "host-error", "guest-reset", "guest-panic"])
  func otherShutdownReasonsAreTypedButNeverGuestShutdown(_ reason: String) async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      guard peer.releaseReply.wait(timeout: .now() + 1) == .success else {
        throw PeerFailure.timeout
      }
      let data = PeerConnection.guestShutdown.replacingOccurrences(
        of: "guest-shutdown", with: reason
      )
      .replacingOccurrences(
        of: "\"guest\":true", with: "\"guest\":\(reason.hasPrefix("guest-") ? "true" : "false")")
      try connection.send(data)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    peer.releaseReply.signal()
    let observation = try await monitorFinished(client)
    #expect(!observation.guestShutdownObserved && observation.shutdown?.reason.rawValue == reason)
    #expect(observation.naturalEOF && observation.failure == nil)
    try peer.finish()
  }

  @Test(arguments: ["wrong-type", "unknown-reason", "partial", "repeated", "invalid-return"])
  func malformedOrContradictoryTerminalInputHasStickyFailure(_ kind: String) async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("system_powerdown", id: 2)
      let ack = "{\"return\":{},\"id\":2}\r\n"
      switch kind {
      case "wrong-type":
        try connection.send(
          ack
            + PeerConnection.guestShutdown.replacingOccurrences(
              of: "\"guest\":true", with: "\"guest\":\"true\""))
      case "unknown-reason":
        try connection.send(
          ack
            + PeerConnection.guestShutdown.replacingOccurrences(
              of: "guest-shutdown", with: "future-reason"))
      case "partial": try connection.send(ack + "{\"event\":\"SHUTDOWN\"")
      case "invalid-return":
        try connection.send("{\"return\":true,\"id\":2}\r\n" + PeerConnection.guestShutdown)
      default:
        try connection.send(
          ack
            + PeerConnection.guestShutdown.replacingOccurrences(
              of: "guest-shutdown", with: "host-qmp-quit"
            ).replacingOccurrences(of: "\"guest\":true", with: "\"guest\":false")
            + PeerConnection.guestShutdown)
      }
      peer.reachedCommand.signal()
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    do { try await client.powerdown() } catch {
      #expect(error as? QMPClientError == .malformedMessage)
    }
    let observation = try await monitorFinished(client)
    #expect(observation.failure != nil && !observation.naturalEOF)
    #expect(!observation.guestShutdownObserved)
    await client.close()
    #expect(await client.settledObservation() == observation)
    try peer.finish()
  }

  @Test func availableFrameBarrierDoesNotWaitForFutureReplyOrShutdown() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("query-status", id: 2)
      peer.reachedCommand.signal()
      guard peer.releaseReply.wait(timeout: .now() + 1) == .success else {
        throw PeerFailure.timeout
      }
      try connection.send(
        PeerConnection.guestShutdown
          + "{\"return\":{\"running\":false,\"status\":\"shutdown\"},\"id\":2}\r\n")
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    let pending = Task { try await client.queryStatus() }
    #expect(await peer.waitForCommand())
    let began = ContinuousClock.now
    let boundary = try await client.drainObservation()
    #expect(began.duration(to: .now) < .milliseconds(500))
    #expect(boundary.shutdown == nil && !boundary.naturalEOF && boundary.failure == nil)
    peer.releaseReply.signal()
    #expect(try await pending.value.status == "shutdown")
    #expect(try await monitorFinished(client).guestShutdownObserved)
    try peer.finish()
  }

  @Test func droppingConnectedClientClosesOwnedDescriptorWithoutPeerExit() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    do {
      let client = QMPClient(socketURL: peer.socketURL)
      try await client.connect()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !peer.sawEOF && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(peer.sawEOF)
    try peer.finish()
  }

  @Test(arguments: [true, false])
  func interruptingPartialEventIsIntentionalClosureNotNaturalEOF(_ cancel: Bool) async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("system_powerdown", id: 2)
      try connection.send("{\"event\":\"SHUTDOWN\"")
      peer.reachedCommand.signal()
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    let pending = Task { try await client.powerdown() }
    #expect(await peer.waitForCommand())
    if cancel {
      pending.cancel()
      do {
        try await pending.value
        Issue.record("Cancelled QMP request completed.")
      } catch { #expect(error is CancellationError) }
    } else {
      await client.close()
      await expectError(.closed) { try await pending.value }
    }
    let observation = await client.settledObservation()
    #expect(observation.intentionalClose && !observation.naturalEOF && observation.readerDrained)
    #expect(observation.shutdown == nil && observation.failure == nil)
    try peer.finish()
  }

  @Test func fragmentedHandshakeEventsAndLifecycleIDs() async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.handshake(fragment: 7, eventBeforeAck: true)
      _ = try connection.command("query-status", id: 2)
      try connection.send(
        PeerConnection.event
          + "{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":2}\r\n", fragment: 5)
      _ = try connection.command("stop", id: 3)
      try connection.send("{\"return\":{},\"id\":3}\r\n")
      _ = try connection.command("cont", id: 4)
      try connection.send("{\"return\":{},\"id\":4}\r\n")
      _ = try connection.command("quit", id: 5)
      try connection.send("{\"return\":{},\"id\":5}\r\n")
    }
    defer {
      if let failure = peer.scriptFailure { Issue.record("Independent peer failure: \(failure)") }
      try? peer.finish(requireCleanScript: false)
    }
    let client = QMPClient(socketURL: peer.socketURL)
    do { try await client.connect() } catch {
      Issue.record("Independent peer failure: \(peer.scriptFailure ?? "none")")
      throw error
    }
    let status = try await client.queryStatus()
    #expect(status.running && status.status == "running")
    try await client.stop()
    try await client.cont()
    try await client.quit()
    await expectError(.closed) { try await client.queryStatus() }
    try peer.finish()
  }

  @Test func rejectionPoisonsConnectionWithoutExportingDescription() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("stop", id: 2)
      try connection.send(
        "{\"error\":{\"class\":\"GenericError\",\"desc\":\"private guest and host content\"},\"id\":2}\r\n"
      )
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    await expectError(.commandRejected("GenericError")) { try await client.stop() }
    await expectError(.closed) { try await client.queryStatus() }
    try peer.finish()
  }

  @Test(arguments: [
    "{\"return\":{},\"id\":3}\r\n",
    "{\"return\":{},\"id\":true}\r\n",
    "{\"return\":{},\"id\":2.0}\r\n",
  ]) func wrongOrNonintegerIDsFail(_ reply: String) async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.handshake()
      _ = try connection.command("stop", id: 2)
      try connection.send(reply)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    await expectError(.unexpectedReply) { try await client.stop() }
    try peer.finish()
  }

  @Test func unsolicitedFutureResponseCannotCompleteNextCommand() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      try connection.send("{\"return\":{\"running\":true,\"status\":\"running\"},\"id\":2}\r\n")
      peer.reachedCommand.signal()
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    do {
      try await client.connect()
      #expect(await peer.waitForCommand())
      do {
        _ = try await client.queryStatus()
        Issue.record("An unsolicited future reply completed a query.")
      } catch {
        #expect(error as? QMPClientError == .unexpectedReply || error as? QMPClientError == .closed)
      }
    } catch { #expect(error as? QMPClientError == .unexpectedReply) }
    let observation = try await monitorFinished(client)
    #expect(observation.failure == .unexpectedReply && !observation.naturalEOF)
    try peer.finish()
  }

  @Test func partialUnsolicitedResponseCannotCompleteNextCommand() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      try connection.send("{\"return\":")
      peer.reachedCommand.signal()
      _ = try connection.command("query-status", id: 2)
      try connection.send("{\"running\":true,\"status\":\"running\"},\"id\":2}\r\n")
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    #expect(await peer.waitForCommand())
    await expectError(.unexpectedReply) { try await client.queryStatus() }
    try peer.finish()
  }

  @Test func partialUnsolicitedEventCanFinishBeforeCurrentReply() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      try connection.send("{\"event\":")
      peer.reachedCommand.signal()
      _ = try connection.command("query-status", id: 2)
      try connection.send("\"STOP\",\"timestamp\":{\"seconds\":1,\"microseconds\":2}}\r\n")
      try connection.send("{\"return\":{\"running\":false,\"status\":\"paused\"},\"id\":2}\r\n")
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    #expect(await peer.waitForCommand())
    let status = try await client.queryStatus()
    #expect(!status.running && status.status == "paused")
    await client.close()
    try peer.finish()
  }

  @Test func escapedDuplicateKeyIsRejected() async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.handshake()
      _ = try connection.command("stop", id: 2)
      try connection.send("{\"return\":{},\"id\":2,\"\\u0069d\":2}\r\n")
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    await expectError(.malformedMessage) { try await client.stop() }
    try peer.finish()
  }

  @Test func pinnedGreetingVersionIsRequired() async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.send(
        PeerConnection.greeting.replacingOccurrences(of: "\"micro\":0", with: "\"micro\":1"))
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    await expectError(.unsupportedVersion) { try await client.connect() }
    try peer.finish()
  }

  @Test func stalledReplyHasOneDeadlineAndCloses() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("query-status", id: 2)
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL, timeout: .milliseconds(100))
    try await client.connect()
    let started = ContinuousClock().now
    await expectError(.deadlineExceeded) { try await client.queryStatus() }
    let terminal = await client.settledObservation()
    #expect(terminal.failure == .deadlineExceeded && !terminal.naturalEOF && terminal.readerDrained)
    #expect(started.duration(to: ContinuousClock().now) < .seconds(2))
    await expectError(.closed) { try await client.queryStatus() }
    try peer.finish()
    #expect(peer.sawEOF)
  }

  @Test func cancellationSettlesDescriptorAndLeavesOtherFDsUsable() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("query-status", id: 2)
      peer.reachedCommand.signal()
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    let pending = Task { try await client.queryStatus() }
    #expect(await peer.waitForCommand())
    pending.cancel()
    do {
      _ = try await pending.value
      Issue.record("Cancelled request succeeded")
    } catch { #expect(error is CancellationError) }
    await client.close()
    let descriptors = (0..<16).map { _ in Darwin.open("/dev/null", O_RDONLY) }
    #expect(descriptors.allSatisfy { $0 >= 0 && fcntl($0, F_GETFD) >= 0 })
    for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
    await expectError(.closed) { try await client.queryStatus() }
    try peer.finish()
    #expect(peer.sawEOF)
  }

  @Test func explicitCloseInterruptsPendingCommand() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("query-status", id: 2)
      peer.reachedCommand.signal()
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    let pending = Task { try await client.queryStatus() }
    #expect(await peer.waitForCommand())
    let started = ContinuousClock().now
    await client.close()
    #expect(started.duration(to: ContinuousClock().now) < .seconds(2))
    await expectError(.closed) { try await pending.value }
    try peer.finish()
    #expect(peer.sawEOF)
  }

  @Test func concurrentCallIsBusyWithoutPoisoningActiveCommand() async throws {
    let peer = try QMPFakePeer { connection, peer in
      try connection.handshake()
      _ = try connection.command("query-status", id: 2)
      peer.reachedCommand.signal()
      guard peer.releaseReply.wait(timeout: .now() + 2) == .success else {
        throw PeerFailure.timeout
      }
      try connection.send("{\"return\":{\"running\":false,\"status\":\"paused\"},\"id\":2}\r\n")
      try connection.waitForEOF(peer)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    let pending = Task { try await client.queryStatus() }
    #expect(await peer.waitForCommand())
    await expectError(.busy) { try await client.stop() }
    peer.releaseReply.signal()
    let status = try await pending.value
    #expect(!status.running && status.status == "paused")
    await client.close()
    try peer.finish()
  }

  @Test func peerEOFBeforeCapabilityReplyFails() async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.send(PeerConnection.greeting)
      _ = try connection.command("qmp_capabilities", id: 1)
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    await expectError(.disconnected) { try await client.connect() }
    try peer.finish()
  }

  @Test(arguments: ["line", "aggregate", "events", "depth", "nodes"])
  func maliciousFrameBudgetsAreBounded(_ kind: String) async throws {
    let peer = try QMPFakePeer { connection, _ in
      try connection.handshake()
      _ = try connection.command("stop", id: 2)
      switch kind {
      case "line": try connection.send(String(repeating: " ", count: 70_000))
      case "aggregate":
        let event =
          "{\"event\":\"NOTE\",\"data\":{\"text\":\"\(String(repeating: "x", count: 58_000))\"},\"timestamp\":{\"seconds\":1,\"microseconds\":2}}\r\n"
        for _ in 0..<5 { try connection.send(event) }
      case "events": try connection.send(String(repeating: PeerConnection.event, count: 65))
      case "depth":
        try connection.send(
          "{\"event\":\"NOTE\",\"data\":{\"x\":\(String(repeating: "[", count: 34))0\(String(repeating: "]", count: 34))},\"timestamp\":{\"seconds\":1,\"microseconds\":2}}\r\n"
        )
      default:
        try connection.send(
          "{\"event\":\"NOTE\",\"data\":{\"x\":[\(Array(repeating: "0", count: 4100).joined(separator: ","))]},\"timestamp\":{\"seconds\":1,\"microseconds\":2}}\r\n"
        )
      }
    }
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    try await client.connect()
    await expectError(.limitExceeded) { try await client.stop() }
    try peer.finish(requireCleanScript: false)
  }

  @Test func socketPermissionsAndSymlinkParentFailClosed() async throws {
    let peer = try QMPFakePeer { _, _ in }
    #expect(chmod(peer.socketURL.path, 0o644) == 0)
    defer { try? peer.finish(requireCleanScript: false) }
    let client = QMPClient(socketURL: peer.socketURL)
    await expectError(.unsafeSocket) { try await client.connect() }
    let alias = peer.directory.appendingPathComponent("alias")
    #expect(symlink(peer.directory.path, alias.path) == 0)
    let linked = QMPClient(socketURL: alias.appendingPathComponent("qmp.sock"))
    await expectError(.unsafeSocket) { try await linked.connect() }
    try peer.finish(requireCleanScript: false)
  }

  @Test func closeBeforeSocketPublicationPreventsLaterConnection() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/mvo-qmp-wait-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let client = QMPClient(socketURL: directory.appendingPathComponent("not-created.sock"))
    let pending = Task { try await client.connect() }
    try await Task.sleep(for: .milliseconds(20))
    await client.close()
    await expectError(.closed) { try await pending.value }
    await expectError(.closed) { try await client.connect() }
    try FileManager.default.removeItem(at: directory)
  }
}
