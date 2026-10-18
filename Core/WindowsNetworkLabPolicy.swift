// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum WindowsNetworkLabPolicyError: Error, Equatable, Sendable {
  case invalidApproval, contextMismatch, invalidControl, unreviewedFrame
}

/// Reviewed private-lab input only. This supplies no launch authority, writer lease,
/// terminal observation or guest-cleanliness evidence. Raw JSON enters through validate.
public struct WindowsNetworkLabApproval: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let scope: String
  public let directory: String
  public let vmID: UUID
  public let previousSessionID: UUID
  public let planSHA256: String
  public let macAddress: String
  public let candidateSHA256: String
  public let driverISOSHA256: String
  public let networkAuthorized: Bool
  public let driverInstallationAuthorized: Bool
  public let normalShutdownAuthorized: Bool
  public let resumeAuthorized: Bool
  public let credentialsAuthorized: Bool
  public let consoleReviewedSHA256: String?

  private static let requiredKeys: Set<String> = [
    "schemaVersion", "scope", "directory", "vmID", "previousSessionID", "planSHA256",
    "macAddress", "candidateSHA256", "driverISOSHA256", "networkAuthorized",
    "driverInstallationAuthorized", "normalShutdownAuthorized", "resumeAuthorized",
    "credentialsAuthorized",
  ]
  private static let candidatePin =
    "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745"
  private static let driverISOPin =
    "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394"

  public static func validate(
    data: Data, directory: String, vmID: UUID, sessionID: UUID,
    planSHA256: String, macAddress: String
  ) throws -> Self {
    guard !data.isEmpty, data.count <= 8192, String(data: data, encoding: .utf8) != nil else {
      throw WindowsNetworkLabPolicyError.invalidApproval
    }
    var parser = WindowsApprovalFields(bytes: Array(data))
    let keys = try parser.parse()
    try checkKeys(keys)
    let result: Self
    do { result = try JSONDecoder().decode(Self.self, from: data) } catch {
      throw WindowsNetworkLabPolicyError.invalidApproval
    }
    guard result.directory == directory, result.vmID == vmID,
      result.previousSessionID == sessionID, result.planSHA256 == planSHA256,
      result.macAddress == macAddress
    else { throw WindowsNetworkLabPolicyError.contextMismatch }
    return result
  }

  public func requireControl(action: String, expectedFrame: String) throws {
    try checkValues()
    guard ["open-console", "normal-shutdown"].contains(action), Self.hash(expectedFrame) else {
      throw WindowsNetworkLabPolicyError.invalidControl
    }
    if action == "normal-shutdown", consoleReviewedSHA256 != expectedFrame {
      throw WindowsNetworkLabPolicyError.unreviewedFrame
    }
  }

  public init(from decoder: any Decoder) throws {
    do {
      let c = try decoder.container(keyedBy: WindowsApprovalKey.self)
      try Self.checkKeys(Set(c.allKeys.map(\.stringValue)))
      schemaVersion = try c.decode(Int.self, forKey: .init("schemaVersion"))
      scope = try c.decode(String.self, forKey: .init("scope"))
      directory = try c.decode(String.self, forKey: .init("directory"))
      vmID = try Self.uuid(c.decode(String.self, forKey: .init("vmID")))
      previousSessionID = try Self.uuid(c.decode(String.self, forKey: .init("previousSessionID")))
      planSHA256 = try c.decode(String.self, forKey: .init("planSHA256"))
      macAddress = try c.decode(String.self, forKey: .init("macAddress"))
      candidateSHA256 = try c.decode(String.self, forKey: .init("candidateSHA256"))
      driverISOSHA256 = try c.decode(String.self, forKey: .init("driverISOSHA256"))
      networkAuthorized = try c.decode(Bool.self, forKey: .init("networkAuthorized"))
      driverInstallationAuthorized = try c.decode(
        Bool.self, forKey: .init("driverInstallationAuthorized"))
      normalShutdownAuthorized = try c.decode(Bool.self, forKey: .init("normalShutdownAuthorized"))
      resumeAuthorized = try c.decode(Bool.self, forKey: .init("resumeAuthorized"))
      credentialsAuthorized = try c.decode(Bool.self, forKey: .init("credentialsAuthorized"))
      consoleReviewedSHA256 = try c.decodeIfPresent(
        String.self, forKey: .init("consoleReviewedSHA256"))
      try checkValues()
    } catch { throw WindowsNetworkLabPolicyError.invalidApproval }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: WindowsApprovalKey.self)
    try c.encode(schemaVersion, forKey: .init("schemaVersion"))
    try c.encode(scope, forKey: .init("scope"))
    try c.encode(directory, forKey: .init("directory"))
    try c.encode(vmID.uuidString, forKey: .init("vmID"))
    try c.encode(previousSessionID.uuidString, forKey: .init("previousSessionID"))
    try c.encode(planSHA256, forKey: .init("planSHA256"))
    try c.encode(macAddress, forKey: .init("macAddress"))
    try c.encode(candidateSHA256, forKey: .init("candidateSHA256"))
    try c.encode(driverISOSHA256, forKey: .init("driverISOSHA256"))
    try c.encode(networkAuthorized, forKey: .init("networkAuthorized"))
    try c.encode(driverInstallationAuthorized, forKey: .init("driverInstallationAuthorized"))
    try c.encode(normalShutdownAuthorized, forKey: .init("normalShutdownAuthorized"))
    try c.encode(resumeAuthorized, forKey: .init("resumeAuthorized"))
    try c.encode(credentialsAuthorized, forKey: .init("credentialsAuthorized"))
    if let consoleReviewedSHA256 {
      try c.encode(consoleReviewedSHA256, forKey: .init("consoleReviewedSHA256"))
    } else {
      try c.encodeNil(forKey: .init("consoleReviewedSHA256"))
    }
  }

  private static func checkKeys(_ keys: Set<String>) throws {
    guard requiredKeys.isSubset(of: keys),
      keys.isSubset(of: requiredKeys.union(["consoleReviewedSHA256"]))
    else { throw WindowsNetworkLabPolicyError.invalidApproval }
  }

  private func checkValues() throws {
    guard schemaVersion == 1, scope == "approved-same-vm-windows-network-lab",
      Self.path(directory), Self.hash(planSHA256), Self.mac(macAddress),
      candidateSHA256 == Self.candidatePin, driverISOSHA256 == Self.driverISOPin,
      networkAuthorized, driverInstallationAuthorized, normalShutdownAuthorized,
      resumeAuthorized, !credentialsAuthorized,
      consoleReviewedSHA256.map(Self.hash) ?? true
    else { throw WindowsNetworkLabPolicyError.invalidApproval }
  }

  private static func uuid(_ text: String) throws -> UUID {
    guard text.utf8.count == 36, let value = UUID(uuidString: text),
      value.uuidString.lowercased() == text.lowercased()
    else { throw WindowsNetworkLabPolicyError.invalidApproval }
    return value
  }

  private static func hash(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func path(_ text: String) -> Bool {
    text.hasPrefix("/") && text.utf8.count <= 4096
      && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && text.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  private static func mac(_ text: String) -> Bool {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6,
      parts.allSatisfy({
        $0.utf8.count == 2
          && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      })
    else { return false }
    let bytes = parts.compactMap { UInt8($0, radix: 16) }
    return bytes.count == 6 && bytes[0] & 1 == 0 && bytes.contains(where: { $0 != 0 })
  }
}

private struct WindowsApprovalKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}

/// Bounded flat lexical pass before Codable; decoded escaped keys cannot hide duplicates.
private struct WindowsApprovalFields {
  let bytes: [UInt8]
  var index = 0
  var current: UInt8? { index < bytes.count ? bytes[index] : nil }

  mutating func parse() throws -> Set<String> {
    var fields: Set<String> = []
    try consume(123)
    while true {
      guard fields.count < 15 else { throw WindowsNetworkLabPolicyError.invalidApproval }
      let span = try string()
      let key: String
      do { key = try JSONDecoder().decode(String.self, from: Data(bytes[span])) } catch {
        throw WindowsNetworkLabPolicyError.invalidApproval
      }
      guard fields.insert(key).inserted else { throw WindowsNetworkLabPolicyError.invalidApproval }
      try consume(58)
      whitespace()
      if current == 34 {
        _ = try string()
      } else {
        let start = index
        while let byte = current, ![44, 125, 9, 10, 13, 32].contains(byte) { index += 1 }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard ["1", "true", "false", "null"].contains(token) else {
          throw WindowsNetworkLabPolicyError.invalidApproval
        }
      }
      whitespace()
      if current == 125 {
        index += 1
        whitespace()
        guard index == bytes.count else { throw WindowsNetworkLabPolicyError.invalidApproval }
        return fields
      }
      try consume(44)
    }
  }

  mutating func string() throws -> Range<Int> {
    whitespace()
    let start = index
    try consume(34)
    var escaped = false
    while let byte = current {
      index += 1
      guard byte >= 32 else { throw WindowsNetworkLabPolicyError.invalidApproval }
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        return start..<index
      }
    }
    throw WindowsNetworkLabPolicyError.invalidApproval
  }

  mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard current == byte else { throw WindowsNetworkLabPolicyError.invalidApproval }
    index += 1
  }

  mutating func whitespace() {
    while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 }
  }
}
