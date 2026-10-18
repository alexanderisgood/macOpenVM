// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import Darwin
import Foundation
import Testing

private enum RelayFixtureError: Error {
  case systemCall, ioDeadline, unexpectedEOF, tooManyBytes, notReady
}

private struct RelayFixture: Sendable {
  let directory: String
  let path: String
  let borrowed: Int32
  let guestPeer: Int32
  let originalFlags: Int32
  let originalDescriptorFlags: Int32
}

private typealias RelayTask = Task<Void, any Error>

/// Local transport fixtures only: these bytes and endpoints establish no TLS or agent health.
private func withRelayFixture(
  initiallyNonblocking: Bool = false, _ body: (RelayFixture) async throws -> Void
) async throws {
  let directory = "/private/tmp/mvo-relay-\(UUID().uuidString)"
  let url = URL(fileURLWithPath: directory, isDirectory: true)
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: url) }
  var descriptors: [Int32] = [-1, -1]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
    throw RelayFixtureError.systemCall
  }
  defer {
    for descriptor in descriptors { _ = Darwin.close(descriptor) }
  }
  for descriptor in descriptors { try suppressBrokenPipeSignal(descriptor) }
  let oldFlags = fcntl(descriptors[0], F_GETFL)
  guard oldFlags >= 0 else { throw RelayFixtureError.systemCall }
  if initiallyNonblocking {
    guard fcntl(descriptors[0], F_SETFL, oldFlags | O_NONBLOCK) == 0 else {
      throw RelayFixtureError.systemCall
    }
  }
  try makeNonblocking(descriptors[1])
  let fixture = RelayFixture(
    directory: directory, path: directory + "/s.sock", borrowed: descriptors[0],
    guestPeer: descriptors[1], originalFlags: fcntl(descriptors[0], F_GETFL),
    originalDescriptorFlags: fcntl(descriptors[0], F_GETFD))
  try await body(fixture)
}

private func withRunningRelay(
  _ fixture: RelayFixture, deadlineSeconds: Int = 5,
  _ body: (RelayTask) async throws -> Void
) async throws {
  let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let operation = Task {
    defer { signal.finish() }
    try await AgentCiphertextRelay.run(
      borrowedGuestDescriptor: fixture.borrowed, socketPath: fixture.path,
      deadlineSeconds: deadlineSeconds,
      onReady: {
        signal.yield(())
        signal.finish()
      })
  }
  do {
    var iterator = ready.makeAsyncIterator()
    guard await iterator.next() != nil else {
      try await operation.value
      throw RelayFixtureError.notReady
    }
    try await body(operation)
  } catch {
    operation.cancel()
    _ = try? await operation.value
    throw error
  }
  operation.cancel()
  _ = try? await operation.value
}

private func suppressBrokenPipeSignal(_ descriptor: Int32) throws {
  var enabled: Int32 = 1
  guard
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
      == 0
  else { throw RelayFixtureError.systemCall }
}

private func makeNonblocking(_ descriptor: Int32) throws {
  let flags = fcntl(descriptor, F_GETFL)
  guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
    throw RelayFixtureError.systemCall
  }
}

private func unixAddress(_ path: String) -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &address.sun_path) {
    $0.copyBytes(from: Array(path.utf8) + [0])
  }
  return address
}

private func createLocalSocket(path: String, asListener: Bool = false) throws -> Int32 {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw RelayFixtureError.systemCall }
  do {
    var address = unixAddress(path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        if asListener {
          return Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        return Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw RelayFixtureError.systemCall }
    if asListener {
      guard listen(descriptor, 1) == 0 else { throw RelayFixtureError.systemCall }
    }
    try makeNonblocking(descriptor)
    try suppressBrokenPipeSignal(descriptor)
  } catch {
    Darwin.close(descriptor)
    throw error
  }
  return descriptor
}

private func node(at path: String) throws -> stat {
  var information = stat()
  guard lstat(path, &information) == 0 else { throw RelayFixtureError.systemCall }
  return information
}

private func expectBorrowedDescriptorPreserved(_ fixture: RelayFixture) {
  // Darwin also reports kernel write-history bits. Compare public access/status flags instead.
  let statusMask = O_ACCMODE | O_NONBLOCK | O_APPEND | O_ASYNC | O_SYNC | O_DSYNC
  let current = fcntl(fixture.borrowed, F_GETFL)
  #expect(current >= 0)
  #expect(current & statusMask == fixture.originalFlags & statusMask)
  #expect(fcntl(fixture.borrowed, F_GETFD) == fixture.originalDescriptorFlags)
}

private func waitForIO(
  _ descriptor: Int32, event: Int16, until deadline: ContinuousClock.Instant
) throws {
  while ContinuousClock.now < deadline {
    try Task.checkCancellation()
    var item = pollfd(fd: descriptor, events: event, revents: 0)
    let result = poll(&item, 1, 50)
    if result < 0 && errno == EINTR { continue }
    guard result >= 0, Int32(item.revents) & POLLNVAL == 0 else {
      throw RelayFixtureError.systemCall
    }
    if result > 0 && Int32(item.revents) & (Int32(event) | POLLHUP | POLLERR) != 0 { return }
  }
  throw RelayFixtureError.ioDeadline
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
  let deadline = ContinuousClock.now + .seconds(4)
  var offset = 0
  while offset < data.count {
    try waitForIO(descriptor, event: Int16(POLLOUT), until: deadline)
    let count = data.withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
    }
    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
    guard count > 0 else { throw RelayFixtureError.systemCall }
    offset += count
  }
}

private func readBytes(from descriptor: Int32, count: Int? = nil) throws -> Data {
  let deadline = ContinuousClock.now + .seconds(4)
  var received = Data()
  while count == nil || received.count < count! {
    try waitForIO(descriptor, event: Int16(POLLIN), until: deadline)
    let size = min(4096, count.map { $0 - received.count } ?? 4096)
    var buffer = [UInt8](repeating: 0, count: size)
    let result = Darwin.read(descriptor, &buffer, buffer.count)
    if result < 0 && (errno == EAGAIN || errno == EINTR) { continue }
    guard result >= 0 else { throw RelayFixtureError.systemCall }
    if result == 0 {
      guard count == nil else { throw RelayFixtureError.unexpectedEOF }
      return received
    }
    guard received.count + result <= 65_536 else { throw RelayFixtureError.tooManyBytes }
    received.append(contentsOf: buffer.prefix(result))
  }
  return received
}

private func finishWriting(_ descriptor: Int32) throws {
  guard shutdown(descriptor, SHUT_WR) == 0 else { throw RelayFixtureError.systemCall }
}

@Suite(.serialized)
struct AgentCiphertextRelayTests {
  @Test(arguments: [false, true])
  func forwardsExactBinaryBytesInBothDirectionsAndBothEOFs(initiallyNonblocking: Bool) async throws
  {
    try await withRelayFixture(initiallyNonblocking: initiallyNonblocking) { fixture in
      try await withRunningRelay(fixture) { relay in
        let parent = try node(at: fixture.directory)
        let endpoint = try node(at: fixture.path)
        #expect(parent.st_uid == geteuid() && parent.st_mode & 0o7777 == 0o700)
        #expect(endpoint.st_uid == geteuid() && endpoint.st_mode & 0o7777 == 0o600)
        #expect(endpoint.st_mode & S_IFMT == S_IFSOCK)
        let client = try createLocalSocket(path: fixture.path)
        defer { Darwin.close(client) }
        let fromClient = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) })
        let fromGuest = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) })
        async let clientWrite: Void = Task.detached {
          try writeAll(fromClient, to: client)
          try finishWriting(client)
        }.value
        async let guestWrite: Void = Task.detached {
          try writeAll(fromGuest, to: fixture.guestPeer)
          try finishWriting(fixture.guestPeer)
        }.value
        async let clientRead = Task.detached { try readBytes(from: client) }.value
        async let guestRead = Task.detached { try readBytes(from: fixture.guestPeer) }.value
        let received = try await (clientRead, guestRead)
        try await clientWrite
        try await guestWrite
        #expect(received.0 == fromGuest && received.1 == fromClient)
        try await relay.value
        expectBorrowedDescriptorPreserved(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
      }
    }
  }

  @Test func halfClosePreservesReverseDirectionUntilItsEOF() async throws {
    try await withRelayFixture { fixture in
      try await withRunningRelay(fixture) { relay in
        let client = try createLocalSocket(path: fixture.path)
        defer { Darwin.close(client) }
        let request = Data([0, 1, 0xff, 2, 0])
        let response = Data([0xfe, 0, 3, 4, 0xff])
        try writeAll(request, to: client)
        try finishWriting(client)
        #expect(try readBytes(from: fixture.guestPeer) == request)
        try writeAll(response, to: fixture.guestPeer)
        try finishWriting(fixture.guestPeer)
        #expect(try readBytes(from: client) == response)
        try await relay.value
        expectBorrowedDescriptorPreserved(fixture)
      }
    }
  }

  @Test func cancellationBeforeAcceptRemovesOnlyRelayPathAndKeepsBorrowedFD() async throws {
    try await withRelayFixture { fixture in
      try await withRunningRelay(fixture) { relay in
        relay.cancel()
        await #expect(throws: CancellationError.self) { try await relay.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        expectBorrowedDescriptorPreserved(fixture)
        let marker = Data([0x41, 0, 0x42])
        try writeAll(marker, to: fixture.guestPeer)
        #expect(try readBytes(from: fixture.borrowed, count: marker.count) == marker)
      }
    }
  }

  @Test(arguments: [false, true])
  func cancellationWhileConnectedRestoresBorrowedFlags(initiallyNonblocking: Bool) async throws {
    try await withRelayFixture(initiallyNonblocking: initiallyNonblocking) { fixture in
      try await withRunningRelay(fixture) { relay in
        let client = try createLocalSocket(path: fixture.path)
        defer { Darwin.close(client) }
        let forwarded = Data([0, 0xff, 0x43])
        try writeAll(forwarded, to: client)
        #expect(try readBytes(from: fixture.guestPeer, count: forwarded.count) == forwarded)
        relay.cancel()
        await #expect(throws: CancellationError.self) { try await relay.value }
        expectBorrowedDescriptorPreserved(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        #expect(try readBytes(from: client).isEmpty)
        let marker = Data([0x44, 0, 0x45])
        try writeAll(marker, to: fixture.guestPeer)
        #expect(try readBytes(from: fixture.borrowed, count: marker.count) == marker)
      }
    }
  }

  @Test func noClientExpiresAndPreservesBorrowedDescriptor() async throws {
    try await withRelayFixture { fixture in
      try await withRunningRelay(fixture, deadlineSeconds: 1) { relay in
        await #expect(throws: AgentCiphertextRelayError.deadlineExpired) { try await relay.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        expectBorrowedDescriptorPreserved(fixture)
      }
    }
  }

  @Test func preexistingFileIsPreservedOnBindFailure() async throws {
    try await withRelayFixture { fixture in
      let contents = Data([0, 0xff, 0x46, 0])
      let url = URL(fileURLWithPath: fixture.path)
      try contents.write(to: url, options: .withoutOverwriting)
      let before = try node(at: fixture.path)
      await #expect(throws: AgentCiphertextRelayError.transportFailed) {
        try await AgentCiphertextRelay.run(
          borrowedGuestDescriptor: fixture.borrowed, socketPath: fixture.path, onReady: {})
      }
      let after = try node(at: fixture.path)
      #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
      #expect(try Data(contentsOf: url) == contents)
      expectBorrowedDescriptorPreserved(fixture)
    }
  }

  @Test func secondRelayCannotReplaceBusySocketPath() async throws {
    try await withRelayFixture { fixture in
      try await withRunningRelay(fixture) { first in
        let before = try node(at: fixture.path)
        await #expect(throws: AgentCiphertextRelayError.transportFailed) {
          try await AgentCiphertextRelay.run(
            borrowedGuestDescriptor: fixture.borrowed, socketPath: fixture.path, onReady: {})
        }
        let after = try node(at: fixture.path)
        #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
        #expect(after.st_mode & S_IFMT == S_IFSOCK)
        expectBorrowedDescriptorPreserved(fixture)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
      }
    }
  }

  @Test func cleanupPreservesUnrelatedReplacementSocket() async throws {
    try await withRelayFixture { fixture in
      try await withRunningRelay(fixture) { relay in
        let original = try node(at: fixture.path)
        #expect(unlink(fixture.path) == 0)
        let replacement = try createLocalSocket(path: fixture.path, asListener: true)
        defer { Darwin.close(replacement) }
        let before = try node(at: fixture.path)
        #expect(original.st_dev != before.st_dev || original.st_ino != before.st_ino)
        relay.cancel()
        await #expect(throws: CancellationError.self) { try await relay.value }
        let after = try node(at: fixture.path)
        #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
        #expect(after.st_mode & S_IFMT == S_IFSOCK)
        expectBorrowedDescriptorPreserved(fixture)
      }
    }
  }
}
