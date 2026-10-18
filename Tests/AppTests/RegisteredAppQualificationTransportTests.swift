// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing

@testable import MacOpenVMApp

/// Actual private local socket exchange and cancellation drain; no App, VM or
/// lifecycle operation is constructed by this transport qualification.
@MainActor @Suite(.serialized) struct RegisteredAppQualificationTransportTests {
  @Test func actualReplyAndClosedSourcesPermitFreshEndpointReuse() async throws {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
    let directory = URL(fileURLWithPath: "/private/tmp/mvo-appqual-" + token, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let socket = directory.appendingPathComponent("control.sock")
    let vm = UUID()
    let nonce = UUID()
    for _ in 0..<2 {
      let server = RegisteredAppQualificationControl(socketURL: socket, nonce: nonce) { request in
        RegisteredAppQualificationControl.Response(
          requestID: request.requestID, nonce: nonce, vmID: vm,
          sessionID: nil, launchGeneration: nil, replyCode: .ok,
          state: .stopped, busy: false, backendActive: false,
          displayReady: false, frameEpochPresent: false, settled: false, outcome: nil)
      }
      try await server.start()
      let request = RegisteredAppQualificationControl.Request(
        requestID: 1, nonce: nonce, vmID: vm, sessionID: nil,
        launchGeneration: nil, action: .status)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let bytes = try encoder.encode(request)
      let reply = try await Task.detached {
        try qualificationSocketExchange(socket, request: bytes)
      }.value
      let decoded = try JSONDecoder().decode(
        RegisteredAppQualificationControl.Response.self, from: reply)
      #expect(decoded.requestID == 1 && decoded.nonce == nonce && decoded.vmID == vm)
      #expect(decoded.replyCode == .ok && !decoded.busy && !decoded.settled)
      await server.close()
      #expect(!FileManager.default.fileExists(atPath: socket.path))
    }
    try FileManager.default.removeItem(at: directory)
  }
}

private func qualificationSocketExchange(_ url: URL, request: Data) throws -> Data {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
  defer { Darwin.close(fd) }
  var timeout = timeval(tv_sec: 3, tv_usec: 0)
  var noPipe: Int32 = 1
  guard
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
  else { throw CocoaError(.fileReadUnknown) }
  var address = sockaddr_un()
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) {
    $0.copyBytes(from: Array(url.path.utf8) + [0])
  }
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
  var length = UInt32(request.count).bigEndian
  var packet = withUnsafeBytes(of: &length) { Data($0) }
  packet.append(request)
  try packet.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let sent = Darwin.send(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      if sent < 0 && errno == EINTR { continue }
      guard sent > 0 else { throw CocoaError(.fileWriteUnknown) }
      offset += sent
    }
  }
  func receive(_ count: Int) throws -> Data {
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < count {
        let read = Darwin.recv(fd, bytes.baseAddress?.advanced(by: offset), count - offset, 0)
        if read < 0 && errno == EINTR { continue }
        guard read > 0 else { throw CocoaError(.fileReadUnknown) }
        offset += read
      }
    }
    return result
  }
  let header = try receive(4)
  let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  guard count > 0, count <= 2048 else { throw CocoaError(.fileReadCorruptFile) }
  return try receive(Int(count))
}
