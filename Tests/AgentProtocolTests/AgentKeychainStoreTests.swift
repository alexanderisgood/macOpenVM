// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import Testing

@testable import AgentProtocol

/// Opaque dummy bytes only. This suite never calls the native Keychain backend.
private func material(
  vmID: UUID = UUID(), enrollmentID: UUID = UUID(), certificate: Data = Data("PUBLIC-DUMMY".utf8),
  key: Data = Data("PRIVATE-DUMMY".utf8), authorities: [Data] = [Data([0x30])],
  name: String = "guest.vm.test"
) throws -> AgentKeychainMaterial {
  try AgentKeychainMaterial(
    vmID: vmID, enrollmentID: enrollmentID,
    credential: .init(certificateDER: certificate, privateKeyDER: key),
    peer: .init(
      certificateAuthoritiesDER: authorities, expectedCertificateDER: Data([0x30, 1]),
      expectedDNSName: name))
}
private actor MemoryKeychain: AgentKeychainBackend {
  private var items: [String: Data] = [:]
  private var queries: [AgentKeychainQuery] = []
  private var nextReply: AgentKeychainBackendReply?
  func perform(_ query: AgentKeychainQuery, data: Data?) -> AgentKeychainBackendReply {
    queries.append(query)
    if let nextReply {
      self.nextReply = nil
      return nextReply
    }
    let key = query.service + "/" + query.account
    switch query.operation {
    case .add:
      guard items[key] == nil else { return .init(status: errSecDuplicateItem, data: nil) }
      guard let data else { return .init(status: errSecParam, data: nil) }
      items[key] = data
      return .init(status: errSecSuccess, data: nil)
    case .load:
      guard let data = items[key] else { return .init(status: errSecItemNotFound, data: nil) }
      return .init(status: errSecSuccess, data: data)
    }
  }
  func override(status: OSStatus, data: Data? = nil) {
    nextReply = .init(status: status, data: data)
  }
  func observed() -> [AgentKeychainQuery] { queries }
  func bytes(vmID: UUID, service: String = AgentKeychainStore.developmentService) -> Data? {
    items[service + "/" + vmID.uuidString]
  }
}

struct AgentKeychainStoreTests {
  @Test func roundtripPreservesExactIdentityAndTrustWithLocalNoUIPolicy() async throws {
    let backend = MemoryKeychain()
    let store = try AgentKeychainStore(
      service: AgentKeychainStore.developmentService, backend: backend)
    let original = try material()
    try await store.addIfAbsent(original)
    let loaded = try await store.load(vmID: original.vmID)
    #expect(loaded.vmID == original.vmID && loaded.enrollmentID == original.enrollmentID)
    #expect(loaded.credential.certificateDER == original.credential.certificateDER)
    #expect(loaded.credential.privateKeyDER == original.credential.privateKeyDER)
    #expect(loaded.peer.certificateAuthoritiesDER == original.peer.certificateAuthoritiesDER)
    #expect(loaded.peer.expectedCertificateDER == original.peer.expectedCertificateDER)
    #expect(loaded.peer.expectedDNSName == original.peer.expectedDNSName)
    let queries = await backend.observed()
    #expect(queries.map(\.operation) == [.add, .load])
    #expect(
      queries.allSatisfy {
        $0.service == AgentKeychainStore.developmentService
          && $0.account == original.vmID.uuidString
      })
    #expect(
      queries.allSatisfy {
        $0.dataProtectionKeychain && !$0.synchronizable && $0.interactionNotAllowed
          && $0.accessibleWhenUnlockedThisDeviceOnly
      })
    let bytes = try #require(await backend.bytes(vmID: original.vmID))
    #expect(bytes.starts(with: Data("bplist00".utf8)))
  }

  @Test func duplicateNeverReplacesPriorEnrollmentOrCredential() async throws {
    let backend = MemoryKeychain()
    let store = try AgentKeychainStore(
      service: AgentKeychainStore.developmentService, backend: backend)
    let original = try material()
    try await store.addIfAbsent(original)
    let before = await backend.bytes(vmID: original.vmID)
    let replacement = try material(vmID: original.vmID, key: Data("DIFFERENT-DUMMY".utf8))
    await #expect(throws: AgentKeychainError.duplicate) { try await store.addIfAbsent(replacement) }
    #expect(await backend.bytes(vmID: original.vmID) == before)
    let loaded = try await store.load(vmID: original.vmID)
    #expect(
      loaded.enrollmentID == original.enrollmentID
        && loaded.credential.privateKeyDER == original.credential.privateKeyDER)
    #expect(await backend.observed().map(\.operation) == [.add, .add, .load])
  }

  @Test func absentLockedDeniedEntitlementAndUnavailableAreTypedWithoutRetry() async throws {
    let cases: [(OSStatus, AgentKeychainError)] = [
      (errSecItemNotFound, .notFound), (errSecInteractionNotAllowed, .interactionNotAllowed),
      (errSecAuthFailed, .denied), (errSecUserCanceled, .denied),
      (errSecMissingEntitlement, .missingEntitlement), (errSecNotAvailable, .unavailable),
      (errSecParam, .unexpectedStatus(errSecParam)),
    ]
    for (status, expected) in cases {
      let backend = MemoryKeychain()
      let store = try AgentKeychainStore(
        service: AgentKeychainStore.developmentService, backend: backend)
      await backend.override(status: status)
      await #expect(throws: expected) { _ = try await store.load(vmID: UUID()) }
      #expect(await backend.observed().count == 1)
      #expect(await backend.observed().first?.operation == .load)
    }
  }

  @Test func foreignVMUnknownFieldsWrongSchemaAndMalformedPayloadRefuse() async throws {
    let backend = MemoryKeychain()
    let store = try AgentKeychainStore(
      service: AgentKeychainStore.developmentService, backend: backend)
    let original = try material()
    try await store.addIfAbsent(original)
    let bytes = try #require(await backend.bytes(vmID: original.vmID))
    let fields = try #require(
      try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        as? [String: Any])
    for (key, value) in [
      ("vmID", UUID().uuidString as Any), ("schemaVersion", true as Any),
      ("schemaVersion", 1.0 as Any), ("schemaVersion", 2 as Any),
      ("extra", "ignored-field" as Any), ("privateKeyDER", Data() as Any),
      ("certificateAuthoritiesDER", [] as [Data]), ("expectedDNSName", "bad\nname" as Any),
    ] {
      var changed = fields
      changed[key] = value
      let data = try PropertyListSerialization.data(
        fromPropertyList: changed, format: .binary, options: 0)
      await backend.override(status: errSecSuccess, data: data)
      await #expect(throws: AgentKeychainError.invalidMaterial) {
        _ = try await store.load(vmID: original.vmID)
      }
    }
    for data in [Data(), Data("not a plist".utf8), Data(repeating: 0, count: 262_145)] {
      await backend.override(status: errSecSuccess, data: data)
      await #expect(throws: AgentKeychainError.invalidMaterial) {
        _ = try await store.load(vmID: original.vmID)
      }
    }
    await backend.override(status: errSecSuccess)
    await #expect(throws: AgentKeychainError.invalidMaterial) {
      _ = try await store.load(vmID: original.vmID)
    }
  }

  @Test func fieldAndAggregateBoundsCannotHideBehindPlistDeduplication() throws {
    _ = try material(
      key: Data(repeating: 1, count: 65_536), authorities: Array(repeating: Data([1]), count: 8))
    #expect(throws: AgentKeychainError.invalidMaterial) {
      try material(key: Data(repeating: 1, count: 65_537))
    }
    #expect(throws: AgentKeychainError.invalidMaterial) { try material(certificate: Data()) }
    #expect(throws: AgentKeychainError.invalidMaterial) { try material(authorities: []) }
    #expect(throws: AgentKeychainError.invalidMaterial) {
      try material(authorities: Array(repeating: Data([1]), count: 9))
    }
    #expect(throws: AgentKeychainError.invalidMaterial) {
      try material(authorities: Array(repeating: Data(repeating: 7, count: 40_000), count: 8))
    }
    for name in [
      "", "-bad.test", "bad-.test", "bad..test", "a b.test", String(repeating: "a", count: 64),
    ] {
      #expect(throws: AgentKeychainError.invalidMaterial) { try material(name: name) }
    }
  }

  @Test func perVMBucketsAndZeroIdentityRefusalDoNotInspectOtherItems() async throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    #expect(throws: AgentKeychainError.invalidMaterial) { try material(vmID: zero) }
    #expect(throws: AgentKeychainError.invalidMaterial) { try material(enrollmentID: zero) }
    let backend = MemoryKeychain()
    let service = AgentKeychainStore.developmentService + ".test." + UUID().uuidString.lowercased()
    let store = try AgentKeychainStore(service: service, backend: backend)
    await #expect(throws: AgentKeychainError.invalidMaterial) {
      _ = try await store.load(vmID: zero)
    }
    #expect(await backend.observed().isEmpty)
    let first = try material()
    try await store.addIfAbsent(first)
    let secondVM = UUID()
    await #expect(throws: AgentKeychainError.notFound) { _ = try await store.load(vmID: secondVM) }
    #expect(
      await backend.observed().map(\.account) == [first.vmID.uuidString, secondVM.uuidString])
    #expect(await backend.observed().allSatisfy { $0.service == service })
    #expect(throws: AgentKeychainError.invalidMaterial) {
      try AgentKeychainStore(service: "other-user-service", backend: backend)
    }
  }

  @Test func descriptionsReflectionAndProtocolSurfaceAreRedacted() throws {
    let value = try material()
    let erased: Any = value
    #expect(!(erased is any Encodable))
    let rendered = String(describing: value) + String(reflecting: value)
    #expect(rendered.contains("redacted"))
    #expect(
      !rendered.contains("PRIVATE-DUMMY") && !rendered.contains("PUBLIC-DUMMY")
        && !rendered.contains("guest.vm.test"))
    #expect(
      Set(Mirror(reflecting: value).children.compactMap(\.label)) == ["vmID", "enrollmentID"])
    var dumpText = ""
    dump(value, to: &dumpText)
    #expect(
      !dumpText.contains("PRIVATE-DUMMY") && !dumpText.contains("certificateDER")
        && !dumpText.contains("privateKeyDER"))
  }

  @Test func cancellationBeforeAdmissionDoesNotSubmitAKeychainQuery() async throws {
    let backend = MemoryKeychain()
    let store = try AgentKeychainStore(
      service: AgentKeychainStore.developmentService, backend: backend)
    let attempt = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await store.load(vmID: UUID())
    }
    await #expect(throws: CancellationError.self) { _ = try await attempt.value }
    #expect(await backend.observed().isEmpty)
  }

  @Test func tlsAndHealthFailWithTheRequestedVMStoreErrorBeforeOpeningAChannel() async throws {
    for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed] {
      let backend = MemoryKeychain()
      let store = try AgentKeychainStore(
        service: AgentKeychainStore.developmentService, backend: backend)
      let vmID = UUID()
      let expected: AgentKeychainError =
        status == errSecItemNotFound
        ? .notFound
        : status == errSecInteractionNotAllowed ? .interactionNotAllowed : .denied
      await backend.override(status: status)
      await #expect(throws: expected) {
        _ = try await NativeAgentTLS.connect(endpoint: .loopback(port: 1), vmID: vmID, store: store)
      }
      await backend.override(status: status)
      await #expect(throws: expected) {
        _ = try await AgentHealthClient.probe(
          endpoint: .loopback(port: 1), vmID: vmID, store: store)
      }
      #expect(await backend.observed().map(\.account) == [vmID.uuidString, vmID.uuidString])
      #expect(await backend.observed().allSatisfy { $0.operation == .load })
    }
  }

  @Test func storedOpaqueBytesStillRequireCryptographicValidationBeforeConnection() async throws {
    let backend = MemoryKeychain()
    let store = try AgentKeychainStore(
      service: AgentKeychainStore.developmentService, backend: backend)
    let opaque = try material()
    try await store.addIfAbsent(opaque)
    await #expect(throws: NativeAgentTLSError.invalidCredential) {
      _ = try await NativeAgentTLS.connect(
        endpoint: .loopback(port: 1), vmID: opaque.vmID, store: store)
    }
    #expect(await backend.observed().map(\.operation) == [.add, .load])
  }

  @Test func invalidTLSDeadlineDoesNotInspectStoredIdentity() async throws {
    let backend = MemoryKeychain()
    let store = try AgentKeychainStore(
      service: AgentKeychainStore.developmentService, backend: backend)
    for timeout in [Double.nan, Double.infinity, 0, 31] {
      await #expect(throws: NativeAgentTLSError.invalidConfiguration) {
        _ = try await NativeAgentTLS.connect(
          endpoint: .loopback(port: 1), vmID: UUID(), store: store, timeoutSeconds: timeout)
      }
    }
    #expect(await backend.observed().isEmpty)
  }
}
