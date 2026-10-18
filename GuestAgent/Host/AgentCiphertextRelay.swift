// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

public enum AgentCiphertextRelayError: Error, Equatable, Sendable {
  case invalidEndpoint, transportFailed, deadlineExpired
}

/// One local client and one borrowed guest descriptor. Only ciphertext crosses this
/// relay; neither the local endpoint nor its owner establishes authenticated health.
public enum AgentCiphertextRelay {
  public static func run(
    borrowedGuestDescriptor: Int32, socketPath: String, deadlineSeconds: Int = 30,
    onReady: @escaping @Sendable () -> Void
  ) async throws {
    guard borrowedGuestDescriptor >= 0, (1...60).contains(deadlineSeconds) else {
      throw AgentCiphertextRelayError.invalidEndpoint
    }
    let operation = Task.detached {
      try pump(
        guest: borrowedGuestDescriptor, path: socketPath, seconds: deadlineSeconds, onReady: onReady
      )
    }
    try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    try Task.checkCancellation()
  }

  private static func pump(
    guest: Int32, path: String, seconds: Int, onReady: @Sendable () -> Void
  ) throws {
    guard path.hasPrefix("/"), path.utf8.count <= 103,
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { throw AgentCiphertextRelayError.invalidEndpoint }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    var parentInfo = stat()
    guard lstat(parent, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR,
      parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o7777 == 0o700
    else { throw AgentCiphertextRelayError.invalidEndpoint }
    try Task.checkCancellation()
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw AgentCiphertextRelayError.transportFailed }
    defer { Darwin.close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let name = Array(path.utf8) + [UInt8(0)]
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
      storage.copyBytes(from: name)
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw AgentCiphertextRelayError.transportFailed }
    var node = stat()
    guard lstat(path, &node) == 0, node.st_mode & S_IFMT == S_IFSOCK else {
      throw AgentCiphertextRelayError.transportFailed
    }
    defer {
      var current = stat()
      if lstat(path, &current) == 0, current.st_dev == node.st_dev,
        current.st_ino == node.st_ino, current.st_mode & S_IFMT == S_IFSOCK
      {
        _ = unlink(path)
      }
    }
    guard chmod(path, 0o600) == 0, listen(listener, 1) == 0 else {
      throw AgentCiphertextRelayError.transportFailed
    }
    let end = ContinuousClock.now + .seconds(seconds)
    onReady()
    try wait(listener, event: Int16(POLLIN), end: end)
    let client = accept(listener, nil, nil)
    guard client >= 0 else { throw AgentCiphertextRelayError.transportFailed }
    defer { Darwin.close(client) }
    var peerUID = uid_t(0)
    var peerGID = gid_t(0)
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
      throw AgentCiphertextRelayError.transportFailed
    }
    let oldGuestFlags = fcntl(guest, F_GETFL)
    guard oldGuestFlags >= 0, fcntl(guest, F_SETFL, oldGuestFlags | O_NONBLOCK) == 0,
      fcntl(client, F_SETFL, O_NONBLOCK) == 0
    else { throw AgentCiphertextRelayError.transportFailed }
    defer { _ = fcntl(guest, F_SETFL, oldGuestFlags) }
    var noSignal: Int32 = 1
    guard
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0,
      setsockopt(guest, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else { throw AgentCiphertextRelayError.transportFailed }
    var toGuest = [UInt8]()
    var toClient = [UInt8]()
    var clientEnded = false
    var guestEnded = false
    var guestWriteEnded = false
    var clientWriteEnded = false
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < end else { throw AgentCiphertextRelayError.deadlineExpired }
      if clientEnded && toGuest.isEmpty && !guestWriteEnded {
        _ = shutdown(guest, SHUT_WR)
        guestWriteEnded = true
      }
      if guestEnded && toClient.isEmpty && !clientWriteEnded {
        _ = shutdown(client, SHUT_WR)
        clientWriteEnded = true
      }
      if clientEnded && guestEnded && toGuest.isEmpty && toClient.isEmpty { return }
      var items = [
        pollfd(
          fd: client,
          events: Int16(
            (clientEnded || !toGuest.isEmpty ? 0 : POLLIN) | (toClient.isEmpty ? 0 : POLLOUT)),
          revents: 0),
        pollfd(
          fd: guest,
          events: Int16(
            (guestEnded || !toClient.isEmpty ? 0 : POLLIN) | (toGuest.isEmpty ? 0 : POLLOUT)),
          revents: 0),
      ]
      let count = poll(&items, 2, 100)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw AgentCiphertextRelayError.transportFailed }
      if count == 0 { continue }
      for index in 0..<2 {
        guard Int32(items[index].revents) & POLLNVAL == 0 else {
          throw AgentCiphertextRelayError.transportFailed
        }
      }
      if Int32(items[0].revents) & POLLOUT != 0 { try flush(&toClient, to: client) }
      if Int32(items[1].revents) & POLLOUT != 0 { try flush(&toGuest, to: guest) }
      if !clientEnded, toGuest.isEmpty, Int32(items[0].revents) & (POLLIN | POLLHUP | POLLERR) != 0
      {
        clientEnded = try read(from: client, into: &toGuest)
      }
      if !guestEnded, toClient.isEmpty, Int32(items[1].revents) & (POLLIN | POLLHUP | POLLERR) != 0
      {
        guestEnded = try read(from: guest, into: &toClient)
      }
    }
  }

  private static func wait(_ descriptor: Int32, event: Int16, end: ContinuousClock.Instant) throws {
    while ContinuousClock.now < end {
      try Task.checkCancellation()
      var item = pollfd(fd: descriptor, events: event, revents: 0)
      let result = poll(&item, 1, 100)
      if result < 0 && errno == EINTR { continue }
      guard result >= 0 else { throw AgentCiphertextRelayError.transportFailed }
      if result > 0 && item.revents & event != 0 { return }
      if Int32(item.revents) & (POLLERR | POLLHUP | POLLNVAL) != 0 {
        throw AgentCiphertextRelayError.transportFailed
      }
    }
    throw AgentCiphertextRelayError.deadlineExpired
  }

  private static func read(from descriptor: Int32, into buffer: inout [UInt8]) throws -> Bool {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    let count = Darwin.read(descriptor, &bytes, bytes.count)
    if count == 0 { return true }
    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return false }
    guard count > 0 else { throw AgentCiphertextRelayError.transportFailed }
    buffer = Array(bytes.prefix(count))
    return false
  }

  private static func flush(_ buffer: inout [UInt8], to descriptor: Int32) throws {
    let count = buffer.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
    guard count > 0 else { throw AgentCiphertextRelayError.transportFailed }
    buffer.removeFirst(count)
  }
}
