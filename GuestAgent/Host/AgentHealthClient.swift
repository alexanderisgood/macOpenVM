// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

public struct AgentHealthObservation: Equatable, Sendable, Encodable {
  public let protocolMajor: UInt16
  public let protocolMinor: UInt16
  public let agentMajor: UInt16
  public let agentMinor: UInt16
  public let agentPatch: UInt16
  public let architecture: UInt16
  public let healthConfirmed: Bool
}

public enum AgentHealthError: Error, Equatable, Sendable {
  case invalidIdentity, invalidReply, entropyUnavailable
}

/// A health-only v1 exchange over an already verified native TLS connection.
/// This establishes transport/message responsiveness, not installation or driver health.
public enum AgentHealthClient {
  /// An explicitly requested health exchange using per-VM Keychain credentials.
  /// This is independent of VM launch and does not infer installed component health.
  public static func probe(
    endpoint: NativeAgentTLSEndpoint, vmID: UUID, store: AgentKeychainStore,
    timeoutSeconds: Double = 10
  ) async throws -> AgentHealthObservation {
    let transport = try await NativeAgentTLS.connect(
      endpoint: endpoint, vmID: vmID, store: store, timeoutSeconds: timeoutSeconds)
    do {
      let identity = withUnsafeBytes(of: vmID.uuid) { Data($0) }
      let observation = try await probe(over: transport, vmID: identity)
      await transport.close()
      return observation
    } catch {
      await transport.close()
      throw error
    }
  }

  public static func probe(
    over transport: NativeAgentTLS, vmID: Data
  ) async throws -> AgentHealthObservation {
    guard vmID.count == 16 else { throw AgentHealthError.invalidIdentity }
    let session = try randomIdentifier()
    let helloID = try randomIdentifier()
    let requestID = try randomIdentifier()
    guard requestID != helloID else { throw AgentHealthError.entropyUnavailable }
    let hello = AgentHello(
      sessionID: session, sequence: 0, requestID: helloID, vmID: vmID,
      supportedFeatures: AgentV1Codec.healthFeature, requiredFeatures: AgentV1Codec.healthFeature)
    try await transport.send(AgentV1Codec.encode(.hello(hello)))
    let handshake = try await receive(over: transport)
    guard case .helloReply(let reply) = handshake.message,
      reply.sessionID == session, reply.sequence == 0, reply.requestID == helloID,
      reply.vmID == vmID, reply.selectedFeatures == AgentV1Codec.healthFeature,
      reply.architecture == 1
    else { throw AgentHealthError.invalidReply }
    let request = AgentHealthRequest(sessionID: session, sequence: 1, requestID: requestID)
    try await transport.send(AgentV1Codec.encode(.healthRequest(request)))
    let response = try await receive(over: transport)
    guard case .healthReply(let health) = response.message,
      health.sessionID == session, health.sequence == 1, health.requestID == requestID,
      health.agentMajor == reply.agentMajor, health.agentMinor == reply.agentMinor,
      health.agentPatch == reply.agentPatch, health.architecture == reply.architecture,
      health.status == 1
    else { throw AgentHealthError.invalidReply }
    return .init(
      protocolMajor: 1, protocolMinor: 0,
      agentMajor: health.agentMajor, agentMinor: health.agentMinor, agentPatch: health.agentPatch,
      architecture: health.architecture, healthConfirmed: true)
  }

  private static func receive(over transport: NativeAgentTLS) async throws -> AgentV1Decoded {
    let header = try await transport.receive(exactly: AgentV1Codec.headerBytes)
    let length = try AgentV1Codec.frameLength(header: header)
    let body = try await transport.receive(exactly: length - AgentV1Codec.headerBytes)
    return try AgentV1Codec.decode(header + body)
  }

  private static func randomIdentifier() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
      bytes.contains(where: { $0 != 0 })
    else { throw AgentHealthError.entropyUnavailable }
    return Data(bytes)
  }
}
