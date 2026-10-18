// SPDX-License-Identifier: Apache-2.0
import Foundation
import LocalAuthentication
import Security

/// Bounded pairing material, not certificate issuance or cryptographic validation.
public struct AgentKeychainMaterial: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let vmID: UUID, enrollmentID: UUID
  let credential: NativeAgentTLSLabCredential
  let peer: NativeAgentTLSPeerTrust
  public var description: String { "Agent pairing material (redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["vmID": vmID, "enrollmentID": enrollmentID])
  }
  public init(
    vmID: UUID, enrollmentID: UUID, credential: NativeAgentTLSLabCredential,
    peer: NativeAgentTLSPeerTrust
  ) throws {
    guard Self.nonzero(vmID), Self.nonzero(enrollmentID),
      [credential.certificateDER, credential.privateKeyDER, peer.expectedCertificateDER].allSatisfy(
        Self.bounded),
      (1...8).contains(peer.certificateAuthoritiesDER.count),
      peer.certificateAuthoritiesDER.allSatisfy(Self.bounded),
      !peer.expectedDNSName.isEmpty, peer.expectedDNSName.utf8.count <= 253,
      peer.expectedDNSName.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-"
          && $0.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          }
      })
    else { throw AgentKeychainError.invalidMaterial }
    let total =
      credential.certificateDER.count + credential.privateKeyDER.count
      + peer.expectedCertificateDER.count
      + peer.certificateAuthoritiesDER.reduce(0) { $0 + $1.count } + peer.expectedDNSName.utf8.count
    guard total <= Self.maximumBytes else { throw AgentKeychainError.invalidMaterial }
    self.vmID = vmID
    self.enrollmentID = enrollmentID
    self.credential = credential
    self.peer = peer
    _ = try encoded()
  }
  /// Package-only equality for custody qualification without exporting record fields.
  package func hasSameMaterial(as other: AgentKeychainMaterial) -> Bool {
    vmID == other.vmID && enrollmentID == other.enrollmentID
      && credential.certificateDER == other.credential.certificateDER
      && credential.privateKeyDER == other.credential.privateKeyDER
      && peer.certificateAuthoritiesDER == other.peer.certificateAuthoritiesDER
      && peer.expectedCertificateDER == other.peer.expectedCertificateDER
      && peer.expectedDNSName == other.peer.expectedDNSName
  }
  private static func bounded(_ data: Data) -> Bool { (1...65_536).contains(data.count) }
  fileprivate static func nonzero(_ id: UUID) -> Bool {
    withUnsafeBytes(of: id.uuid) { $0.contains { $0 != 0 } }
  }
  fileprivate static let maximumBytes = 262_144
  private struct Record: Codable {
    let schemaVersion: Int, vmID: UUID, enrollmentID: UUID
    let certificateDER: Data, privateKeyDER: Data, certificateAuthoritiesDER: [Data],
      expectedCertificateDER: Data
    let expectedDNSName: String
  }
  fileprivate func encoded() throws -> Data {
    let record = Record(
      schemaVersion: 1, vmID: vmID, enrollmentID: enrollmentID,
      certificateDER: credential.certificateDER, privateKeyDER: credential.privateKeyDER,
      certificateAuthoritiesDER: peer.certificateAuthoritiesDER,
      expectedCertificateDER: peer.expectedCertificateDER,
      expectedDNSName: peer.expectedDNSName)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(record)
    guard data.count <= Self.maximumBytes else { throw AgentKeychainError.invalidMaterial }
    return data
  }
  fileprivate static func decode(_ data: Data, vmID: UUID) throws -> AgentKeychainMaterial {
    guard !data.isEmpty, data.count <= maximumBytes else {
      throw AgentKeychainError.invalidMaterial
    }
    do {
      guard
        let fields = try PropertyListSerialization.propertyList(
          from: data, options: [], format: nil) as? [String: Any],
        Set(fields.keys) == [
          "schemaVersion", "vmID", "enrollmentID", "certificateDER", "privateKeyDER",
          "certificateAuthoritiesDER", "expectedCertificateDER", "expectedDNSName",
        ],
        let schema = fields["schemaVersion"] as? NSNumber,
        CFGetTypeID(schema) != CFBooleanGetTypeID(),
        ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(
          String(cString: schema.objCType)), schema.intValue == 1,
        fields["vmID"] is String, fields["enrollmentID"] is String,
        fields["certificateDER"] is Data,
        fields["privateKeyDER"] is Data, fields["certificateAuthoritiesDER"] is [Data],
        fields["expectedCertificateDER"] is Data, fields["expectedDNSName"] is String
      else { throw AgentKeychainError.invalidMaterial }
      let record = try PropertyListDecoder().decode(Record.self, from: data)
      guard record.schemaVersion == 1, record.vmID == vmID else {
        throw AgentKeychainError.invalidMaterial
      }
      return try AgentKeychainMaterial(
        vmID: record.vmID, enrollmentID: record.enrollmentID,
        credential: .init(
          certificateDER: record.certificateDER, privateKeyDER: record.privateKeyDER),
        peer: .init(
          certificateAuthoritiesDER: record.certificateAuthoritiesDER,
          expectedCertificateDER: record.expectedCertificateDER,
          expectedDNSName: record.expectedDNSName))
    } catch { throw AgentKeychainError.invalidMaterial }
  }
}

public enum AgentKeychainError: Error, Equatable, Sendable, LocalizedError {
  case invalidMaterial, notFound, duplicate, interactionNotAllowed, denied, missingEntitlement,
    unavailable
  case unexpectedStatus(Int32)
  public var errorDescription: String? {
    switch self {
    case .invalidMaterial: "Agent pairing material is malformed or belongs to another VM."
    case .notFound:
      "This VM's agent pairing identity was not found in the authorized Keychain scope."
    case .duplicate: "This VM already has an agent pairing identity; it was not replaced."
    case .interactionNotAllowed:
      "Agent pairing identity requires unavailable authentication or an unlocked Keychain."
    case .denied: "Access to this VM's agent pairing identity was denied."
    case .missingEntitlement: "This application lacks the required Keychain authorization."
    case .unavailable: "The agent Keychain store is unavailable."
    case .unexpectedStatus: "The agent Keychain operation failed."
    }
  }
  fileprivate static func check(_ status: OSStatus) throws {
    switch status {
    case errSecSuccess: return
    case errSecItemNotFound: throw Self.notFound
    case errSecDuplicateItem: throw Self.duplicate
    case errSecInteractionNotAllowed: throw Self.interactionNotAllowed
    case errSecAuthFailed, errSecUserCanceled: throw Self.denied
    case errSecMissingEntitlement: throw Self.missingEntitlement
    case errSecNotAvailable: throw Self.unavailable
    default: throw Self.unexpectedStatus(status)
    }
  }
}

package struct AgentKeychainQuery: Equatable, Sendable {
  package enum Operation: Equatable, Sendable { case add, load }
  package let operation: Operation, service: String, account: String
  package var dataProtectionKeychain: Bool { true }
  package var synchronizable: Bool { false }
  package var interactionNotAllowed: Bool { true }
  package var accessibleWhenUnlockedThisDeviceOnly: Bool { true }
}
package struct AgentKeychainBackendReply: Sendable {
  package let status: OSStatus, data: Data?
}
package protocol AgentKeychainBackend: Sendable {
  func perform(_ query: AgentKeychainQuery, data: Data?) async -> AgentKeychainBackendReply
}

/// Experimental per-VM bucket. Failure never resets, unlocks, rotates, or falls back.
public actor AgentKeychainStore {
  package static let developmentService = "local.macOpenVM.experimental.agent-pairing.v1"
  private let service: String, backend: any AgentKeychainBackend
  public init() {
    service = Self.developmentService
    backend = NativeAgentKeychainBackend()
  }
  package init(service: String, backend: (any AgentKeychainBackend)? = nil) throws {
    let suffix = String(service.dropFirst((Self.developmentService + ".test.").count))
    guard
      service == Self.developmentService
        || (service.hasPrefix(Self.developmentService + ".test.")
          && UUID(uuidString: suffix)?.uuidString.lowercased() == suffix)
    else { throw AgentKeychainError.invalidMaterial }
    self.service = service
    self.backend = backend ?? NativeAgentKeychainBackend()
  }
  public func addIfAbsent(_ material: AgentKeychainMaterial) async throws {
    try Task.checkCancellation()
    let reply = await backend.perform(query(.add, material.vmID), data: try material.encoded())
    try AgentKeychainError.check(reply.status)
  }
  public func load(vmID: UUID) async throws -> AgentKeychainMaterial {
    try Task.checkCancellation()
    guard AgentKeychainMaterial.nonzero(vmID) else { throw AgentKeychainError.invalidMaterial }
    let reply = await backend.perform(query(.load, vmID), data: nil)
    try AgentKeychainError.check(reply.status)
    guard let data = reply.data else { throw AgentKeychainError.invalidMaterial }
    return try AgentKeychainMaterial.decode(data, vmID: vmID)
  }
  private func query(_ operation: AgentKeychainQuery.Operation, _ vmID: UUID) -> AgentKeychainQuery
  {
    AgentKeychainQuery(operation: operation, service: service, account: vmID.uuidString)
  }
}

/// CF dictionaries and authentication contexts stay on this utility queue, never
/// across the Sendable backend boundary. No operation may display authentication UI.
private final class NativeAgentKeychainBackend: AgentKeychainBackend, @unchecked Sendable {
  private let queue = DispatchQueue(label: "local.macOpenVM.agent.keychain", qos: .utility)
  func perform(_ query: AgentKeychainQuery, data: Data?) async -> AgentKeychainBackendReply {
    await withCheckedContinuation { continuation in
      queue.async {
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        var attributes: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: query.service, kSecAttrAccount as String: query.account,
          kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
          kSecUseAuthenticationContext as String: context,
        ]
        let reply: AgentKeychainBackendReply
        switch query.operation {
        case .add:
          attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
          attributes[kSecValueData as String] = data
          reply = .init(status: SecItemAdd(attributes as CFDictionary, nil), data: nil)
        case .load:
          attributes[kSecReturnData as String] = true
          attributes[kSecMatchLimit as String] = kSecMatchLimitOne
          var result: CFTypeRef?
          let status = SecItemCopyMatching(attributes as CFDictionary, &result)
          reply = .init(status: status, data: result as? Data)
        }
        continuation.resume(returning: reply)
      }
    }
  }
}
