// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Security
import Testing

@testable import AgentProtocol
@testable import MacOpenVMCLI

/// An injected reply source only; it has no native Security-framework operations.
private actor ProbeKeychainBackend: AgentKeychainBackend {
  let status: OSStatus, data: Data?
  private var calls: [(AgentKeychainQuery, Data?)] = []
  init(status: OSStatus = errSecItemNotFound, data: Data? = nil) {
    self.status = status
    self.data = data
  }
  func perform(_ query: AgentKeychainQuery, data: Data?) -> AgentKeychainBackendReply {
    calls.append((query, data))
    return .init(status: status, data: self.data)
  }
  func observed() -> [(AgentKeychainQuery, Data?)] { calls }
}

struct AgentKeychainProbeLabTests {
  @Test func zeroOrReusedIdentifiersNeverSubmitAQuery() async throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    let identifier = UUID()
    let backend = ProbeKeychainBackend()
    for (service, vm) in [(zero, identifier), (identifier, zero), (identifier, identifier)] {
      await #expect(throws: VMError.self) {
        _ = try await AgentKeychainProbeLab.observe(serviceID: service, vmID: vm, backend: backend)
      }
    }
    #expect(await backend.observed().isEmpty)
  }

  @Test func exactlyOneLocalNoUIReadUsesOnlyTheGeneratedServiceAndVMAccount() async throws {
    let service = UUID()
    let vm = UUID()
    let backend = ProbeKeychainBackend()
    let result = try await AgentKeychainProbeLab.observe(
      serviceID: service, vmID: vm, backend: backend)
    #expect(
      result.outcome == .notFound && result.readOnly && !result.persistenceVerified
        && !result.authenticationUIAllowed)
    let calls = await backend.observed()
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.0.operation == .load && call.1 == nil)
    #expect(
      call.0.service == AgentKeychainStore.developmentService + ".test."
        + service.uuidString.lowercased())
    #expect(call.0.account == vm.uuidString)
    #expect(call.0.dataProtectionKeychain && !call.0.synchronizable && call.0.interactionNotAllowed)
  }

  @Test func failuresAreBoundedObservationsWithoutRetriesOrWrites() async throws {
    let cases: [(OSStatus, AgentKeychainProbeLab.Outcome, Int32?)] = [
      (errSecInteractionNotAllowed, .interactionNotAllowed, nil), (errSecAuthFailed, .denied, nil),
      (errSecMissingEntitlement, .missingEntitlement, nil), (errSecNotAvailable, .unavailable, nil),
      (errSecParam, .unexpectedStatus, errSecParam),
      (errSecDuplicateItem, .unexpectedStatus, errSecDuplicateItem),
      (errSecSuccess, .invalidMaterial, nil),
    ]
    for (status, expected, code) in cases {
      let backend = ProbeKeychainBackend(status: status)
      let result = try await AgentKeychainProbeLab.observe(
        serviceID: UUID(), vmID: UUID(), backend: backend)
      #expect(result.outcome == expected && result.unknownStatus == code)
      let calls = await backend.observed()
      #expect(calls.count == 1 && calls.allSatisfy { $0.0.operation == .load && $0.1 == nil })
    }
  }

  @Test func unexpectedMaterialIsDiscardedWithoutExportOrDescription() async throws {
    let vm = UUID()
    let enrollment = UUID()
    let payload: [String: Any] = [
      "schemaVersion": 1, "vmID": vm.uuidString, "enrollmentID": enrollment.uuidString,
      "certificateDER": Data("DO-NOT-EXPORT-CERT".utf8),
      "privateKeyDER": Data("DO-NOT-EXPORT-KEY".utf8),
      "certificateAuthoritiesDER": [Data([0x30])], "expectedCertificateDER": Data([0x30, 1]),
      "expectedDNSName": "never.disclose.invalid",
    ]
    let bytes = try PropertyListSerialization.data(
      fromPropertyList: payload, format: .binary, options: 0)
    let backend = ProbeKeychainBackend(status: errSecSuccess, data: bytes)
    let result = try await AgentKeychainProbeLab.observe(
      serviceID: UUID(), vmID: vm, backend: backend)
    #expect(result.outcome == .unexpectedItemWithoutDisclosure)
    let encoded = try JSONEncoder().encode(result)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(
      !text.contains("DO-NOT-EXPORT") && !text.contains("never.disclose")
        && !text.contains(enrollment.uuidString))
    let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(
      Set(fields.keys) == [
        "schemaVersion", "scope", "serviceID", "vmID", "outcome", "readOnly",
        "authenticationUIAllowed", "persistenceVerified",
      ])
    #expect(await backend.observed().count == 1)
  }
}
