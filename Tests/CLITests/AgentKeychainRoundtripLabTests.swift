// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Security
import Testing

@testable import AgentProtocol
@testable import MacOpenVMCLI

/// Memory and scripted replies only; no native Security-framework operations.
private actor RoundtripKeychainBackend: AgentKeychainBackend {
  private var items: [String: Data] = [:]
  private var calls: [(AgentKeychainQuery, Data?)] = []
  private let replies: [Int: AgentKeychainBackendReply]
  private let cancelOnCall: Int?
  init(replies: [Int: AgentKeychainBackendReply] = [:], cancelOnCall: Int? = nil) {
    self.replies = replies
    self.cancelOnCall = cancelOnCall
  }
  func perform(_ query: AgentKeychainQuery, data: Data?) -> AgentKeychainBackendReply {
    calls.append((query, data))
    if calls.count == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
    if let reply = replies[calls.count] { return reply }
    let identifier = query.service + "/" + query.account
    switch query.operation {
    case .load:
      guard let value = items[identifier] else {
        return .init(status: errSecItemNotFound, data: nil)
      }
      return .init(status: errSecSuccess, data: value)
    case .add:
      guard items[identifier] == nil else {
        return .init(status: errSecDuplicateItem, data: nil)
      }
      guard let data else { return .init(status: errSecParam, data: nil) }
      items[identifier] = data
      return .init(status: errSecSuccess, data: nil)
    }
  }
  func observed() -> [(AgentKeychainQuery, Data?)] { calls }
  func itemCount() -> Int { items.count }
}

private struct RoundtripIdentifiers {
  let serviceID = UUID(), vmID = UUID(), enrollmentID = UUID()
  func observe(
    _ action: String = "create", backend: RoundtripKeychainBackend,
    marker: String = AgentKeychainRoundtripLab.publicFixtureMarker
  ) async throws -> AgentKeychainRoundtripLab.Observation {
    try await AgentKeychainRoundtripLab.observe(
      action: action, serviceID: serviceID, vmID: vmID, enrollmentID: enrollmentID,
      publicFixture: marker, backend: backend)
  }
}

struct AgentKeychainRoundtripLabTests {
  @Test func invalidActionMarkerZeroOrRepeatedIdentityNeverSubmitAQuery() async throws {
    let ids = RoundtripIdentifiers()
    let backend = RoundtripKeychainBackend()
    for action in ["", "CREATE", "delete", "verify "] {
      await #expect(throws: VMError.self) { _ = try await ids.observe(action, backend: backend) }
    }
    for marker in ["", "real-key", AgentKeychainRoundtripLab.publicFixtureMarker + " "] {
      await #expect(throws: VMError.self) {
        _ = try await ids.observe(backend: backend, marker: marker)
      }
    }
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    for (service, vm, enrollment) in [
      (zero, ids.vmID, ids.enrollmentID), (ids.serviceID, zero, ids.enrollmentID),
      (ids.serviceID, ids.vmID, zero), (ids.serviceID, ids.serviceID, ids.enrollmentID),
      (ids.serviceID, ids.vmID, ids.serviceID), (ids.serviceID, ids.vmID, ids.vmID),
    ] {
      await #expect(throws: VMError.self) {
        _ = try await AgentKeychainRoundtripLab.observe(
          action: "create", serviceID: service, vmID: vm, enrollmentID: enrollment,
          publicFixture: AgentKeychainRoundtripLab.publicFixtureMarker, backend: backend)
      }
    }
    #expect(await backend.observed().isEmpty)
  }

  @Test func createRequiresMissingThenExactReadbackAndDuplicatePreservation() async throws {
    let ids = RoundtripIdentifiers()
    let backend = RoundtripKeychainBackend()
    let result = try await ids.observe(backend: backend)
    #expect(result.outcome == .createdAndDuplicatePreserved && result.step == .preservedReadback)
    #expect(result.addMayHaveCommitted && result.exactPublicFixtureVerified)
    #expect(
      result.duplicatePreservationVerified && !result.readOnly && !result.authenticationUIAllowed)
    let calls = await backend.observed()
    #expect(calls.map { $0.0.operation } == [.load, .add, .load, .add, .load])
    #expect(calls.filter { $0.0.operation == .load }.allSatisfy { $0.1 == nil })
    #expect(
      calls.allSatisfy {
        $0.0.service == AgentKeychainStore.developmentService + ".test."
          + ids.serviceID.uuidString.lowercased()
          && $0.0.account == ids.vmID.uuidString && $0.0.dataProtectionKeychain
          && !$0.0.synchronizable && $0.0.interactionNotAllowed
          && $0.0.accessibleWhenUnlockedThisDeviceOnly
      })
    #expect(calls[1].1 != nil && calls[1].1 != calls[3].1)
    #expect(await backend.itemCount() == 1)
    let addedBytes = try #require(calls[1].1)
    let fields = try #require(
      try PropertyListSerialization.propertyList(
        from: addedBytes, options: [], format: nil) as? [String: Any])
    #expect(fields["privateKeyDER"] as? Data == Data("PUBLIC-SYNTHETIC-NOT-A-KEY-ORIGINAL".utf8))
    #expect(fields["expectedDNSName"] as? String == "public-fixture-original.invalid")
    let verification = try await ids.observe("verify", backend: backend)
    #expect(verification.outcome == .verifiedPublicFixture && verification.readOnly)
    #expect(verification.exactPublicFixtureVerified && !verification.duplicatePreservationVerified)
    #expect(!verification.addMayHaveCommitted && !verification.authenticationUIAllowed)
    #expect(
      await backend.observed().map { $0.0.operation } == [.load, .add, .load, .add, .load, .load])
  }

  @Test func existingExactFixtureIsACollisionAndNeverAdmitsAnotherAdd() async throws {
    let ids = RoundtripIdentifiers()
    let backend = RoundtripKeychainBackend()
    _ = try await ids.observe(backend: backend)
    let collision = try await ids.observe(backend: backend)
    #expect(
      collision.outcome == .unexpectedItemWithoutDisclosure && collision.step == .absenceCheck)
    #expect(!collision.addMayHaveCommitted && !collision.exactPublicFixtureVerified)
    #expect(
      await backend.observed().map { $0.0.operation } == [.load, .add, .load, .add, .load, .load])
    #expect(await backend.itemCount() == 1)
  }

  @Test func absenceFailuresAndMalformedUnexpectedReadsCannotAdmitAnyWrite() async throws {
    let cases: [(OSStatus, Data?, AgentKeychainRoundtripLab.Outcome, Int32?)] = [
      (errSecInteractionNotAllowed, nil, .interactionNotAllowed, nil),
      (errSecAuthFailed, nil, .denied, nil), (errSecUserCanceled, nil, .denied, nil),
      (errSecMissingEntitlement, nil, .missingEntitlement, nil),
      (errSecNotAvailable, nil, .unavailable, nil),
      (errSecDuplicateItem, nil, .duplicate, nil),
      (errSecParam, nil, .unexpectedStatus, errSecParam),
      (errSecSuccess, nil, .invalidMaterial, nil),
      (errSecSuccess, Data("DO-NOT-DISCLOSE-FOREIGN-MATERIAL".utf8), .invalidMaterial, nil),
    ]
    for (status, data, expected, code) in cases {
      let backend = RoundtripKeychainBackend(replies: [1: .init(status: status, data: data)])
      let result = try await RoundtripIdentifiers().observe(backend: backend)
      #expect(result.outcome == expected && result.unknownStatus == code)
      #expect(result.step == .absenceCheck && !result.addMayHaveCommitted)
      let calls = await backend.observed()
      #expect(calls.count == 1 && calls[0].0.operation == .load && calls[0].1 == nil)
    }
  }

  @Test func errorsAfterAdmissionStopAtTheExactStepWithoutRetryOrCleanup() async throws {
    let cases:
      [(Int, OSStatus, AgentKeychainRoundtripLab.Step, AgentKeychainRoundtripLab.Outcome)] = [
        (2, errSecDuplicateItem, .initialAdd, .duplicate),
        (2, errSecMissingEntitlement, .initialAdd, .missingEntitlement),
        (3, errSecItemNotFound, .initialReadback, .notFound),
        (3, errSecInteractionNotAllowed, .initialReadback, .interactionNotAllowed),
        (4, errSecAuthFailed, .duplicateAdd, .denied),
        (5, errSecNotAvailable, .preservedReadback, .unavailable),
      ]
    for (index, status, step, outcome) in cases {
      let backend = RoundtripKeychainBackend(replies: [index: .init(status: status, data: nil)])
      let result = try await RoundtripIdentifiers().observe(backend: backend)
      #expect(result.outcome == outcome && result.step == step && result.addMayHaveCommitted)
      #expect(!result.exactPublicFixtureVerified && !result.duplicatePreservationVerified)
      #expect(await backend.observed().count == index)
    }
    let acceptedDuplicate = RoundtripKeychainBackend(replies: [
      4: .init(status: errSecSuccess, data: nil)
    ])
    let result = try await RoundtripIdentifiers().observe(backend: acceptedDuplicate)
    #expect(result.outcome == .duplicateWasNotRejected && result.step == .duplicateAdd)
    #expect(await acceptedDuplicate.observed().count == 4)
  }

  @Test func verifyMissingOrChangedFixtureIsReadOnlyAndDoesNotReportSuccess() async throws {
    let ids = RoundtripIdentifiers()
    let backend = RoundtripKeychainBackend()
    let missing = try await ids.observe("verify", backend: backend)
    #expect(missing.outcome == .notFound && missing.step == .verification && missing.readOnly)
    _ = try await ids.observe(backend: backend)
    let changed = try await AgentKeychainRoundtripLab.observe(
      action: "verify", serviceID: ids.serviceID, vmID: ids.vmID, enrollmentID: UUID(),
      publicFixture: AgentKeychainRoundtripLab.publicFixtureMarker, backend: backend)
    #expect(changed.outcome == .fixtureMismatchWithoutDisclosure && changed.readOnly)
    #expect(!changed.addMayHaveCommitted && !changed.exactPublicFixtureVerified)
    #expect(
      await backend.observed().map { $0.0.operation } == [
        .load, .load, .add, .load, .add, .load, .load,
      ])
  }

  @Test func cancellationBeforeAdmissionOrAfterAnAdmittedAddNeverRetriesOrClaimsRollback()
    async throws
  {
    let ids = RoundtripIdentifiers()
    let before = RoundtripKeychainBackend()
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ids.observe(backend: before)
    }
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(await before.observed().isEmpty)
    for index in 1...5 {
      let backend = RoundtripKeychainBackend(cancelOnCall: index)
      let task = Task { try await ids.observe(backend: backend) }
      await #expect(throws: CancellationError.self) { _ = try await task.value }
      #expect(await backend.observed().count == index)
      #expect(await backend.itemCount() == (index >= 2 ? 1 : 0))
    }
  }

  @Test func everyCredentialAndTrustFieldIsComparedWithoutDisclosingMismatch() async throws {
    let ids = RoundtripIdentifiers()
    let originalBackend = RoundtripKeychainBackend()
    _ = try await ids.observe(backend: originalBackend)
    let originalCalls = await originalBackend.observed()
    let bytes = try #require(originalCalls[1].1)
    let original = try #require(
      try PropertyListSerialization.propertyList(
        from: bytes, options: [], format: nil) as? [String: Any])
    let changes: [(String, Any)] = [
      ("enrollmentID", UUID().uuidString),
      ("certificateDER", Data("FOREIGN-CERT-NOT-FOR-OUTPUT".utf8)),
      ("privateKeyDER", Data("FOREIGN-KEY-NOT-FOR-OUTPUT".utf8)),
      ("certificateAuthoritiesDER", [Data("FOREIGN-CA-NOT-FOR-OUTPUT".utf8)]),
      ("expectedCertificateDER", Data("FOREIGN-PEER-NOT-FOR-OUTPUT".utf8)),
      ("expectedDNSName", "foreign-name-do-not-output.invalid"),
    ]
    for (field, value) in changes {
      var changed = original
      changed[field] = value
      let data = try PropertyListSerialization.data(
        fromPropertyList: changed, format: .binary, options: 0)
      let backend = RoundtripKeychainBackend(replies: [1: .init(status: errSecSuccess, data: data)])
      let result = try await ids.observe("verify", backend: backend)
      #expect(
        result.outcome == .fixtureMismatchWithoutDisclosure && !result.exactPublicFixtureVerified)
      #expect(await backend.observed().count == 1)
      let output = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
      #expect(!output.contains("FOREIGN-") && !output.contains("foreign-name-do-not-output"))
    }
    for index in [3, 5] {
      var changed = original
      changed["privateKeyDER"] = Data("FOREIGN-KEY-NOT-FOR-OUTPUT".utf8)
      let data = try PropertyListSerialization.data(
        fromPropertyList: changed, format: .binary, options: 0)
      let backend = RoundtripKeychainBackend(replies: [
        index: .init(status: errSecSuccess, data: data)
      ])
      let result = try await ids.observe(backend: backend)
      #expect(
        result.outcome == .fixtureMismatchWithoutDisclosure && !result.exactPublicFixtureVerified)
      #expect(result.step == (index == 3 ? .initialReadback : .preservedReadback))
      #expect(await backend.observed().count == index)
    }
  }

  @Test func observationExportsOnlyClosedMetadataAndPublicIdentifiers() async throws {
    let ids = RoundtripIdentifiers()
    let backend = RoundtripKeychainBackend()
    let result = try await ids.observe(backend: backend)
    let encoded = try JSONEncoder().encode(result)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("PUBLIC-SYNTHETIC") && !text.contains("public-fixture-original.invalid"))
    #expect(
      !text.contains("certificateDER") && !text.contains("privateKeyDER") && !text.contains("hash"))
    #expect(!text.contains(AgentKeychainStore.developmentService) && !text.contains("keychainpath"))
    let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(
      Set(fields.keys) == [
        "schemaVersion", "scope", "serviceID", "vmID", "enrollmentID", "action", "step", "outcome",
        "publicFixture", "readOnly", "authenticationUIAllowed", "addMayHaveCommitted",
        "exactPublicFixtureVerified", "duplicatePreservationVerified",
      ])
  }
}
