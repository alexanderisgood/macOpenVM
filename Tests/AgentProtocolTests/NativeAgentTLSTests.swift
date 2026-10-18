// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import Darwin
import Foundation
import Testing

private let unavailableCredential = NativeAgentTLSLabCredential(
  certificateDER: Data(), privateKeyDER: Data())
private let unavailablePeer = NativeAgentTLSPeerTrust(
  certificateAuthoritiesDER: [], expectedCertificateDER: Data(), expectedDNSName: "guest.invalid")

@Test func nativeAgentTLSRejectsInvalidDeadlinesBeforeConnection() async {
  for timeout in [Double.nan, Double.infinity, -Double.infinity, 0, 0.9, 30.1] {
    await #expect(throws: NativeAgentTLSError.invalidConfiguration) {
      _ = try await NativeAgentTLS.connect(
        endpoint: .loopback(port: 1), credential: unavailableCredential,
        peer: unavailablePeer, timeoutSeconds: timeout)
    }
  }
}

@Test func nativeAgentTLSRejectsUnsafeLocalEndpointsBeforeConnection() async {
  let endpoints: [NativeAgentTLSEndpoint] = [
    .loopback(port: 0), .unix(path: "relative.sock"), .unix(path: "/private/tmp/../agent.sock"),
    .unix(path: "/private/tmp/agent\n.sock"), .unix(path: "/" + String(repeating: "a", count: 103)),
    .unix(path: "/"), .unix(path: "/private//tmp/agent.sock"),
    .unix(path: "/private/tmp/./agent.sock"), .unix(path: "/private/tmp/agent.sock/"),
  ]
  for endpoint in endpoints {
    await #expect(throws: NativeAgentTLSError.invalidConfiguration) {
      _ = try await NativeAgentTLS.connect(
        endpoint: endpoint, credential: unavailableCredential, peer: unavailablePeer)
    }
  }
}

@Test func nativeAgentTLSAdmitsExistingPrivateTemporaryUnixSocket() async throws {
  let directory = "/private/tmp/mvo-tls-admission-\(UUID().uuidString)"
  let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
  try FileManager.default.createDirectory(
    at: directoryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directoryURL) }
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(descriptor >= 0)
  guard descriptor >= 0 else { return }
  defer { Darwin.close(descriptor) }
  let path = directory + "/s.sock"
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: Array(path.utf8) + [0])
  }
  let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  #expect(bound == 0)
  guard bound == 0 else { return }
  await #expect(throws: NativeAgentTLSError.invalidCredential) {
    _ = try await NativeAgentTLS.connect(
      endpoint: .unix(path: path), credential: unavailableCredential, peer: unavailablePeer)
  }
}

@Test func nativeAgentTLSRejectsAbsentOrMalformedCredentialsBeforeConnection() async {
  let credentials = [
    unavailableCredential,
    NativeAgentTLSLabCredential(certificateDER: Data([0x30]), privateKeyDER: Data([0x30])),
    NativeAgentTLSLabCredential(
      certificateDER: Data(repeating: 0, count: 65_537), privateKeyDER: Data([0x30])),
  ]
  for credential in credentials {
    await #expect(throws: NativeAgentTLSError.invalidCredential) {
      _ = try await NativeAgentTLS.connect(
        endpoint: .loopback(port: 1), credential: credential, peer: unavailablePeer)
    }
  }
}
