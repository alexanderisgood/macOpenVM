// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import BackendAPI
import Darwin
import Foundation
import VMStorage

enum AgentTLSLab {
  struct Result: Encodable {
    let tlsVersion = "TLS1.3"
    let nativePeerTrustVerified = true
    let health: AgentHealthObservation
    let scope =
      "temporary native TLS/schema health evaluation; no installation or driver-health claim"
  }

  static func run(socketPath: String, credentialDirectory: String, vmID: UUID) async throws
    -> Result
  {
    let credentials = try await credential(directory: credentialDirectory)
    let transport = try await NativeAgentTLS.connect(
      endpoint: .unix(path: socketPath), credential: credentials.0, peer: credentials.1)
    do {
      let identity = withUnsafeBytes(of: vmID.uuid) { Data($0) }
      let health = try await AgentHealthClient.probe(over: transport, vmID: identity)
      await transport.close()
      return Result(health: health)
    } catch {
      await transport.close()
      throw error
    }
  }

  static func credential(directory: String) async throws
    -> (NativeAgentTLSLabCredential, NativeAgentTLSPeerTrust)
  {
    let prefix = "/private/tmp/mvo-agent-tls-"
    guard directory.hasPrefix(prefix), directory.count == prefix.count + 32,
      directory.dropFirst(prefix.count).utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else {
      throw VMError(
        .invalidConfiguration, "The temporary credential folder selection is invalid.",
        recovery: "Use a fresh lab issuance folder.")
    }
    var info = stat()
    guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else {
      throw VMError(
        .invalidConfiguration, "The temporary credential folder permissions are invalid.",
        recovery: "Preserve owner-only access to the lab credentials.")
    }
    let files = VMFiles()
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    let certificate = try await files.readMetadata(
      at: url.appendingPathComponent("client.der"), limit: 65_536)
    let key = try await files.readMetadata(
      at: url.appendingPathComponent("client-key.der"), limit: 65_536)
    let anchor = try await files.readMetadata(
      at: url.appendingPathComponent("ca.der"), limit: 65_536)
    let guest = try await files.readMetadata(
      at: url.appendingPathComponent("guest.der"), limit: 65_536)
    return (
      .init(certificateDER: certificate, privateKeyDER: key),
      .init(
        certificateAuthoritiesDER: [anchor], expectedCertificateDER: guest,
        expectedDNSName: "macopenvm-agent.invalid")
    )
  }
}
