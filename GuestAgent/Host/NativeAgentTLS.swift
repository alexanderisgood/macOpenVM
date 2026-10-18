// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Security

public enum NativeAgentTLSEndpoint: Sendable {
  /// The caller owns the local socket path and its private parent directory.
  case unix(path: String)
  /// An explicit local ciphertext relay; never a silent transport fallback.
  case loopback(port: UInt16)
}

/// Injected, memory-only lab credentials. This type does not read or persist credentials.
public struct NativeAgentTLSLabCredential: Sendable {
  public let certificateDER: Data
  public let privateKeyDER: Data
  public let label = "labcredential"

  public init(certificateDER: Data, privateKeyDER: Data) {
    self.certificateDER = certificateDER
    self.privateKeyDER = privateKeyDER
  }
}

public struct NativeAgentTLSPeerTrust: Sendable {
  public let certificateAuthoritiesDER: [Data]
  /// The exact approved leaf certificate, in addition to standard TLS trust evaluation.
  public let expectedCertificateDER: Data
  public let expectedDNSName: String

  public init(
    certificateAuthoritiesDER: [Data], expectedCertificateDER: Data, expectedDNSName: String
  ) {
    self.certificateAuthoritiesDER = certificateAuthoritiesDER
    self.expectedCertificateDER = expectedCertificateDER
    self.expectedDNSName = expectedDNSName
  }
}

public enum NativeAgentTLSError: Error, Equatable, Sendable, LocalizedError {
  case invalidConfiguration, invalidCredential, invalidTrust, handshakeFailed
  case transportFailed, timedOut, closed, busy, truncatedFrame

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The agent transport settings are invalid."
    case .invalidCredential: "The lab agent credential is unavailable or invalid."
    case .invalidTrust: "The approved agent trust settings are invalid."
    case .handshakeFailed: "The authenticated agent handshake failed."
    case .transportFailed: "The agent transport failed."
    case .timedOut: "The agent transport deadline expired."
    case .closed: "The agent transport is closed."
    case .busy: "An agent transport operation is already pending."
    case .truncatedFrame: "The agent transport ended before the bounded frame was complete."
    }
  }
}

private final class NativeAgentTLSVerification: @unchecked Sendable {
  private let lock = NSLock()
  private var passed = false

  func record(_ value: Bool) {
    lock.withLock { passed = value }
  }

  var didPass: Bool { lock.withLock { passed } }
}

/// Native TLS over a caller-owned local endpoint. A relay carries ciphertext to the
/// guest socket; its local address grants no trust. Stored credentials are loaded
/// only by the explicit per-VM store overload, before creating the connection.
public actor NativeAgentTLS {
  public static let maximumTransferBytes = 4096
  private static let maximumCredentialBytes = 65_536
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "local.macOpenVM.agent.tls")
  private let verification: NativeAgentTLSVerification
  private let timeoutSeconds: Double
  private var ready = false
  private var closed = false
  private var opening: (UUID, CheckedContinuation<Void, any Error>)?
  private var sending: (UUID, CheckedContinuation<Void, any Error>)?
  private var receiving: (UUID, Int, CheckedContinuation<Data, any Error>)?
  private var deadlines: [UUID: Task<Void, Never>] = [:]

  private init(
    endpoint: NativeAgentTLSEndpoint, credential: NativeAgentTLSLabCredential,
    peer: NativeAgentTLSPeerTrust, timeoutSeconds: Double
  ) throws {
    guard timeoutSeconds.isFinite, (1...30).contains(timeoutSeconds) else {
      throw NativeAgentTLSError.invalidConfiguration
    }
    self.timeoutSeconds = timeoutSeconds
    let verification = NativeAgentTLSVerification()
    self.verification = verification
    connection = try Self.makeConnection(
      endpoint: endpoint, credential: credential, peer: peer, verification: verification)
  }

  deinit {
    connection.stateUpdateHandler = nil
    connection.forceCancel()
    for task in deadlines.values { task.cancel() }
  }

  public static func connect(
    endpoint: NativeAgentTLSEndpoint, credential: NativeAgentTLSLabCredential,
    peer: NativeAgentTLSPeerTrust, timeoutSeconds: Double = 10
  ) async throws -> NativeAgentTLS {
    let transport = try NativeAgentTLS(
      endpoint: endpoint, credential: credential, peer: peer, timeoutSeconds: timeoutSeconds)
    try await transport.open()
    return transport
  }

  /// Uses only the requested VM's stored enrollment. Missing or denied Keychain
  /// access fails integration without prompting, resetting or changing VM boot.
  public static func connect(
    endpoint: NativeAgentTLSEndpoint, vmID: UUID, store: AgentKeychainStore,
    timeoutSeconds: Double = 10
  ) async throws -> NativeAgentTLS {
    guard timeoutSeconds.isFinite, (1...30).contains(timeoutSeconds) else {
      throw NativeAgentTLSError.invalidConfiguration
    }
    let material = try await store.load(vmID: vmID)
    try Task.checkCancellation()
    return try await connect(
      endpoint: endpoint, credential: material.credential, peer: material.peer,
      timeoutSeconds: timeoutSeconds)
  }

  public func send(_ data: Data) async throws {
    guard !data.isEmpty, data.count <= Self.maximumTransferBytes else {
      throw NativeAgentTLSError.invalidConfiguration
    }
    guard ready, !closed else { throw NativeAgentTLSError.closed }
    guard sending == nil else { throw NativeAgentTLSError.busy }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          terminate(CancellationError())
          continuation.resume(throwing: CancellationError())
          return
        }
        let id = UUID()
        sending = (id, continuation)
        startDeadline(id)
        connection.send(
          content: data,
          completion: .contentProcessed { [weak self] error in
            Task { await self?.sent(id, failed: error != nil) }
          })
      }
    } onCancel: {
      Task { await self.terminate(CancellationError()) }
    }
  }

  public func receive(exactly count: Int) async throws -> Data {
    guard (1...Self.maximumTransferBytes).contains(count) else {
      throw NativeAgentTLSError.invalidConfiguration
    }
    guard ready, !closed else { throw NativeAgentTLSError.closed }
    guard receiving == nil else { throw NativeAgentTLSError.busy }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, any Error>) in
        guard !Task.isCancelled else {
          terminate(CancellationError())
          continuation.resume(throwing: CancellationError())
          return
        }
        let id = UUID()
        receiving = (id, count, continuation)
        startDeadline(id)
        connection.receive(minimumIncompleteLength: count, maximumLength: count) {
          [weak self] data, _, complete, error in
          Task { await self?.received(id, data: data, complete: complete, failed: error != nil) }
        }
      }
    } onCancel: {
      Task { await self.terminate(CancellationError()) }
    }
  }

  public func close() { terminate(NativeAgentTLSError.closed) }

  private func open() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          terminate(CancellationError())
          continuation.resume(throwing: CancellationError())
          return
        }
        let id = UUID()
        opening = (id, continuation)
        startDeadline(id)
        connection.stateUpdateHandler = { [weak self] state in
          Task { await self?.changed(state) }
        }
        connection.start(queue: queue)
      }
    } onCancel: {
      Task { await self.terminate(CancellationError()) }
    }
  }

  private func changed(_ state: NWConnection.State) {
    guard !closed else { return }
    switch state {
    case .ready:
      guard verification.didPass,
        let metadata = connection.metadata(definition: NWProtocolTLS.definition)
          as? NWProtocolTLS.Metadata,
        sec_protocol_metadata_get_negotiated_tls_protocol_version(
          metadata.securityProtocolMetadata) == .TLSv13
      else {
        terminate(NativeAgentTLSError.handshakeFailed)
        return
      }
      if ready { return }
      guard let (id, continuation) = opening else {
        terminate(NativeAgentTLSError.handshakeFailed)
        return
      }
      opening = nil
      finishDeadline(id)
      ready = true
      continuation.resume()
    case .failed:
      terminate(ready ? NativeAgentTLSError.transportFailed : NativeAgentTLSError.handshakeFailed)
    case .waiting(let error):
      if case .tls = error {
        terminate(ready ? NativeAgentTLSError.transportFailed : NativeAgentTLSError.handshakeFailed)
      }
    case .cancelled:
      terminate(NativeAgentTLSError.closed)
    default: break
    }
  }

  private func sent(_ id: UUID, failed: Bool) {
    guard let (pendingID, continuation) = sending, pendingID == id else { return }
    guard !failed else {
      terminate(NativeAgentTLSError.transportFailed)
      return
    }
    sending = nil
    finishDeadline(id)
    continuation.resume()
  }

  private func received(_ id: UUID, data: Data?, complete: Bool, failed: Bool) {
    guard let (pendingID, count, continuation) = receiving, pendingID == id else { return }
    guard !failed else {
      terminate(NativeAgentTLSError.transportFailed)
      return
    }
    guard let data, data.count == count else {
      terminate(NativeAgentTLSError.truncatedFrame)
      return
    }
    receiving = nil
    finishDeadline(id)
    continuation.resume(returning: data)
    if complete { terminate(NativeAgentTLSError.closed) }
  }

  private func startDeadline(_ id: UUID) {
    let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
    deadlines[id] = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
      await self?.deadlineExpired(id)
    }
  }

  private func finishDeadline(_ id: UUID) {
    deadlines.removeValue(forKey: id)?.cancel()
  }

  private func deadlineExpired(_ id: UUID) {
    guard deadlines[id] != nil else { return }
    terminate(NativeAgentTLSError.timedOut)
  }

  private func terminate(_ error: any Error) {
    guard !closed else { return }
    closed = true
    ready = false
    connection.stateUpdateHandler = nil
    connection.forceCancel()
    for task in deadlines.values { task.cancel() }
    deadlines.removeAll()
    let connectContinuation = opening?.1
    let sendContinuation = sending?.1
    let receiveContinuation = receiving?.2
    opening = nil
    sending = nil
    receiving = nil
    connectContinuation?.resume(throwing: error)
    sendContinuation?.resume(throwing: error)
    receiveContinuation?.resume(throwing: error)
  }

  private static func makeConnection(
    endpoint: NativeAgentTLSEndpoint, credential: NativeAgentTLSLabCredential,
    peer: NativeAgentTLSPeerTrust, verification: NativeAgentTLSVerification
  ) throws -> NWConnection {
    let remote: NWEndpoint
    switch endpoint {
    case .unix(let path):
      guard isUnixPath(path) else { throw NativeAgentTLSError.invalidConfiguration }
      remote = .unix(path: path)
    case .loopback(let port):
      guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
        throw NativeAgentTLSError.invalidConfiguration
      }
      remote = .hostPort(host: "127.0.0.1", port: endpointPort)
    }
    guard isBounded(credential.certificateDER), isBounded(credential.privateKeyDER),
      let certificate = SecCertificateCreateWithData(nil, credential.certificateDER as CFData),
      let privateKey = SecKeyCreateWithData(
        credential.privateKeyDER as CFData,
        [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
          as CFDictionary, nil),
      (256...1024).contains(SecKeyGetBlockSize(privateKey)),
      let identity = SecIdentityCreate(nil, certificate, privateKey),
      let localIdentity = sec_identity_create(identity)
    else { throw NativeAgentTLSError.invalidCredential }
    guard (1...8).contains(peer.certificateAuthoritiesDER.count),
      peer.certificateAuthoritiesDER.allSatisfy(isBounded),
      isBounded(peer.expectedCertificateDER), isDNSName(peer.expectedDNSName),
      SecCertificateCreateWithData(nil, peer.expectedCertificateDER as CFData) != nil,
      peer.certificateAuthoritiesDER.allSatisfy({
        SecCertificateCreateWithData(nil, $0 as CFData) != nil
      })
    else { throw NativeAgentTLSError.invalidTrust }
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_peer_authentication_required(options, true)
    sec_protocol_options_set_local_identity(options, localIdentity)
    sec_protocol_options_set_tls_server_name(options, peer.expectedDNSName)
    sec_protocol_options_set_tls_resumption_enabled(options, false)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    sec_protocol_options_set_verify_block(
      options,
      { _, wrappedTrust, complete in
        let trust = sec_trust_copy_ref(wrappedTrust).takeRetainedValue()
        let passed = evaluate(trust, peer: peer)
        verification.record(passed)
        complete(passed)
      }, DispatchQueue(label: "local.macOpenVM.agent.tls.verify"))
    return NWConnection(to: remote, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
  }

  private static func evaluate(_ trust: SecTrust, peer: NativeAgentTLSPeerTrust) -> Bool {
    let authorities = peer.certificateAuthoritiesDER.compactMap {
      SecCertificateCreateWithData(nil, $0 as CFData)
    }
    guard authorities.count == peer.certificateAuthoritiesDER.count,
      SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, peer.expectedDNSName as CFString))
        == errSecSuccess,
      SecTrustSetAnchorCertificates(trust, authorities as CFArray) == errSecSuccess,
      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
      SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
      SecTrustEvaluateWithError(trust, nil),
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let certificate = chain.first
    else { return false }
    return SecCertificateCopyData(certificate) as Data == peer.expectedCertificateDER
  }

  private static func isBounded(_ data: Data) -> Bool {
    !data.isEmpty && data.count <= maximumCredentialBytes
  }

  private static func isUnixPath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path.utf8.count <= 103,
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return false }
    // Foundation standardization may rewrite an existing /private/tmp socket to
    // its /tmp alias. Validate lexical components without resolving the endpoint.
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty
      && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  private static func isDNSName(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 253 else { return false }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { label in
      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
        && label.utf8.allSatisfy {
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
  }
}
