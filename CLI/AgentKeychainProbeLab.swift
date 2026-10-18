// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import BackendAPI
import Foundation
import Security

/// One explicit, isolated read. It never persists an item or discloses loaded material.
enum AgentKeychainProbeLab {
  enum Outcome: String, Codable, Sendable {
    case notFound, interactionNotAllowed, denied, missingEntitlement, unavailable
    case unexpectedStatus, invalidMaterial, unexpectedItemWithoutDisclosure
  }
  struct Observation: Codable, Sendable {
    let schemaVersion: Int
    let scope: String
    let serviceID: UUID, vmID: UUID
    let outcome: Outcome
    let unknownStatus: Int32?
    let readOnly: Bool, authenticationUIAllowed: Bool, persistenceVerified: Bool
    fileprivate init(serviceID: UUID, vmID: UUID, outcome: Outcome, unknownStatus: Int32? = nil) {
      schemaVersion = 1
      scope = "read-only-native-development-isolated-item-lookup"
      self.serviceID = serviceID
      self.vmID = vmID
      self.outcome = outcome
      self.unknownStatus = unknownStatus
      readOnly = true
      authenticationUIAllowed = false
      persistenceVerified = false
    }
  }
  static func run(serviceID: UUID, vmID: UUID) async throws -> Observation {
    try await observe(serviceID: serviceID, vmID: vmID, backend: nil)
  }
  /// The injected backend is available to source tests only, never a CLI option.
  static func observe(serviceID: UUID, vmID: UUID, backend: (any AgentKeychainBackend)?)
    async throws -> Observation
  {
    guard nonzero(serviceID), nonzero(vmID), serviceID != vmID else {
      throw VMError(
        .invalidConfiguration,
        "Provide two distinct, nonzero identifiers for an isolated Keychain read.",
        recovery:
          "Use newly generated service and VM identifiers. Existing items are never enumerated or changed."
      )
    }
    let service =
      AgentKeychainStore.developmentService + ".test." + serviceID.uuidString.lowercased()
    let store = try AgentKeychainStore(service: service, backend: backend)
    var outcome = Outcome.unexpectedItemWithoutDisclosure
    var status: Int32?
    do { _ = try await store.load(vmID: vmID) } catch let error as AgentKeychainError {
      switch error {
      case .notFound: outcome = .notFound
      case .interactionNotAllowed: outcome = .interactionNotAllowed
      case .denied: outcome = .denied
      case .missingEntitlement: outcome = .missingEntitlement
      case .unavailable: outcome = .unavailable
      case .invalidMaterial: outcome = .invalidMaterial
      case .unexpectedStatus(let value):
        outcome = .unexpectedStatus
        status = value
      case .duplicate:
        outcome = .unexpectedStatus
        status = errSecDuplicateItem
      }
    }
    return Observation(serviceID: serviceID, vmID: vmID, outcome: outcome, unknownStatus: status)
  }
  private static func nonzero(_ id: UUID) -> Bool {
    withUnsafeBytes(of: id.uuid) { $0.contains { $0 != 0 } }
  }
}
