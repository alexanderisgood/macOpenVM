// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import BackendAPI
import Foundation
import Security

/// An isolated public fixture only. It cannot enroll or authenticate an agent.
enum AgentKeychainRoundtripLab {
  static let publicFixtureMarker = "public-synthetic-not-for-authentication-v1"
  enum Action: String, Codable, Sendable { case create, verify }
  enum Step: String, Codable, Sendable {
    case absenceCheck, initialAdd, initialReadback, duplicateAdd, preservedReadback, verification
  }
  enum Outcome: String, Codable, Sendable {
    case createdAndDuplicatePreserved, verifiedPublicFixture, unexpectedItemWithoutDisclosure
    case fixtureMismatchWithoutDisclosure, duplicateWasNotRejected
    case notFound, duplicate, interactionNotAllowed, denied, missingEntitlement, unavailable
    case invalidMaterial, unexpectedStatus
  }
  struct Observation: Codable, Sendable {
    let schemaVersion: Int
    let scope: String
    let serviceID: UUID, vmID: UUID, enrollmentID: UUID
    let action: Action, step: Step, outcome: Outcome
    let unknownStatus: Int32?
    let publicFixture: String
    let readOnly: Bool, authenticationUIAllowed: Bool, addMayHaveCommitted: Bool
    let exactPublicFixtureVerified: Bool, duplicatePreservationVerified: Bool
    fileprivate init(
      serviceID: UUID, vmID: UUID, enrollmentID: UUID, action: Action, step: Step,
      outcome: Outcome, unknownStatus: Int32? = nil, addMayHaveCommitted: Bool = false
    ) {
      schemaVersion = 1
      scope = "isolated-development-keychain-public-fixture-only"
      self.serviceID = serviceID
      self.vmID = vmID
      self.enrollmentID = enrollmentID
      self.action = action
      self.step = step
      self.outcome = outcome
      self.unknownStatus = unknownStatus
      publicFixture = publicFixtureMarker
      readOnly = action == .verify
      authenticationUIAllowed = false
      self.addMayHaveCommitted = addMayHaveCommitted
      exactPublicFixtureVerified =
        outcome == .createdAndDuplicatePreserved || outcome == .verifiedPublicFixture
      duplicatePreservationVerified = outcome == .createdAndDuplicatePreserved
    }
  }

  static func run(
    action: String, serviceID: UUID, vmID: UUID, enrollmentID: UUID, publicFixture: String
  ) async throws -> Observation {
    try await observe(
      action: action, serviceID: serviceID, vmID: vmID, enrollmentID: enrollmentID,
      publicFixture: publicFixture, backend: nil)
  }

  /// Injection belongs to source tests; it is never selected by a CLI option.
  static func observe(
    action: String, serviceID: UUID, vmID: UUID, enrollmentID: UUID, publicFixture: String,
    backend: (any AgentKeychainBackend)?
  ) async throws -> Observation {
    guard let action = Action(rawValue: action), publicFixture == publicFixtureMarker,
      [serviceID, vmID, enrollmentID].allSatisfy(nonzero),
      Set([serviceID, vmID, enrollmentID]).count == 3
    else {
      throw VMError(
        .invalidConfiguration,
        "Provide create or verify, the public-fixture marker, and three distinct nonzero identifiers.",
        recovery:
          "Use fresh identifiers for creation. This evaluator accepts no supplied credential material."
      )
    }
    try Task.checkCancellation()
    let store = try AgentKeychainStore(
      service: AgentKeychainStore.developmentService + ".test." + serviceID.uuidString.lowercased(),
      backend: backend)
    let expected = try fixture(vmID: vmID, enrollmentID: enrollmentID, alternate: false)
    var step: Step = action == .create ? .absenceCheck : .verification
    var addMayHaveCommitted = false
    func observation(_ outcome: Outcome, unknownStatus: Int32? = nil) -> Observation {
      Observation(
        serviceID: serviceID, vmID: vmID, enrollmentID: enrollmentID, action: action,
        step: step, outcome: outcome, unknownStatus: unknownStatus,
        addMayHaveCommitted: addMayHaveCommitted)
    }
    do {
      if action == .verify {
        let loaded = try await store.load(vmID: vmID)
        try Task.checkCancellation()
        return observation(
          loaded.hasSameMaterial(as: expected)
            ? .verifiedPublicFixture : .fixtureMismatchWithoutDisclosure)
      }
      // Any successful or unexpected read is a collision; only exact not-found admits an add.
      do {
        _ = try await store.load(vmID: vmID)
        try Task.checkCancellation()
        return observation(.unexpectedItemWithoutDisclosure)
      } catch AgentKeychainError.notFound {}
      try Task.checkCancellation()
      step = .initialAdd
      addMayHaveCommitted = true
      try await store.addIfAbsent(expected)
      try Task.checkCancellation()
      step = .initialReadback
      let loaded = try await store.load(vmID: vmID)
      try Task.checkCancellation()
      guard loaded.hasSameMaterial(as: expected) else {
        return observation(.fixtureMismatchWithoutDisclosure)
      }
      step = .duplicateAdd
      let alternate = try fixture(vmID: vmID, enrollmentID: enrollmentID, alternate: true)
      do {
        try await store.addIfAbsent(alternate)
        try Task.checkCancellation()
        return observation(.duplicateWasNotRejected)
      } catch AgentKeychainError.duplicate {}
      try Task.checkCancellation()
      step = .preservedReadback
      let preserved = try await store.load(vmID: vmID)
      try Task.checkCancellation()
      return observation(
        preserved.hasSameMaterial(as: expected)
          ? .createdAndDuplicatePreserved : .fixtureMismatchWithoutDisclosure)
    } catch let error as AgentKeychainError {
      switch error {
      case .notFound: return observation(.notFound)
      case .duplicate: return observation(.duplicate)
      case .interactionNotAllowed: return observation(.interactionNotAllowed)
      case .denied: return observation(.denied)
      case .missingEntitlement: return observation(.missingEntitlement)
      case .unavailable: return observation(.unavailable)
      case .invalidMaterial: return observation(.invalidMaterial)
      case .unexpectedStatus(let status):
        return observation(.unexpectedStatus, unknownStatus: status)
      }
    }
  }

  private static func fixture(vmID: UUID, enrollmentID: UUID, alternate: Bool) throws
    -> AgentKeychainMaterial
  {
    let variant = alternate ? "ALTERNATE" : "ORIGINAL"
    // These are deliberately invalid DER and cannot serve as certificates or private keys.
    return try AgentKeychainMaterial(
      vmID: vmID, enrollmentID: enrollmentID,
      credential: .init(
        certificateDER: Data("PUBLIC-SYNTHETIC-CERT-\(variant)".utf8),
        privateKeyDER: Data("PUBLIC-SYNTHETIC-NOT-A-KEY-\(variant)".utf8)),
      peer: .init(
        certificateAuthoritiesDER: [Data("PUBLIC-SYNTHETIC-NOT-A-CA-\(variant)".utf8)],
        expectedCertificateDER: Data("PUBLIC-SYNTHETIC-PEER-\(variant)".utf8),
        expectedDNSName: "public-fixture-\(variant.lowercased()).invalid"))
  }
  private static func nonzero(_ id: UUID) -> Bool {
    withUnsafeBytes(of: id.uuid) { $0.contains { $0 != 0 } }
  }
}
