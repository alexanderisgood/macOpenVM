// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// Correlation metadata only. A decoded route never supplies writer or launch authority;
/// callers still validate real ancestry, peers and the actual worker/session/endpoint.
public struct DisplayWorkerRoute: Equatable, Sendable {
  public let schemaVersion: Int
  public let scope: String
  public let vmID: UUID
  public let sessionID: UUID
  public let controlSocket: String
  public let displaySocket: String
  public let parentDevice: Int32
  public let parentInode: UInt64
  public let socketDevice: Int32
  public let socketInode: UInt64

  fileprivate init(
    scope: String, vmID: UUID, sessionID: UUID, controlSocket: String, displaySocket: String,
    parentDevice: Int32, parentInode: UInt64, socketDevice: Int32, socketInode: UInt64
  ) {
    schemaVersion = 1
    self.scope = scope
    self.vmID = vmID
    self.sessionID = sessionID
    self.controlSocket = controlSocket
    self.displaySocket = displaySocket
    self.parentDevice = parentDevice
    self.parentInode = parentInode
    self.socketDevice = socketDevice
    self.socketInode = socketInode
  }
}

/// Exactly ten scalar fields, depth <= 1 and nodes <= 11, in bounded UTF-8 JSON.
/// The route deliberately has no Codable/Decodable bypass around this parser.
public enum FlatDisplayRouteCodec {
  public enum Profile: Sendable {
    case existing, windowsNetworkContinuation, windowsExternalContinuation, registeredQemu
    case registeredSharedFrame
  }
  public static let maximumBytes = 4096
  public static let maximumSocketBytes = 103

  public static func decode(_ data: Data, profile: Profile = .existing) throws -> DisplayWorkerRoute
  {
    guard !data.isEmpty, data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil
    else { throw invalidDisplayRoute() }
    var parser = DisplayRouteScalarParser(bytes: Array(data))
    let fields = try parser.parse()
    let scopes: [String]
    switch profile {
    case .existing:
      scopes = ["original-diskless-display-route", "approved-windows-installer-display-route"]
    case .windowsNetworkContinuation:
      scopes = ["approved-windows-network-continuation-display-route"]
    case .windowsExternalContinuation:
      scopes = ["approved-windows-external-continuation-display-route"]
    case .registeredQemu:
      scopes = ["macopenvm-registered-qemu-display-route"]
    case .registeredSharedFrame:
      scopes = ["macopenvm-registered-qemu-shared-frame-route"]
    }
    guard
      Set(fields.keys) == [
        "schemaVersion", "scope", "vmID", "sessionID", "controlSocket", "displaySocket",
        "parentDevice", "parentInode", "socketDevice", "socketInode",
      ], fields["schemaVersion"] == .integer("1"),
      case .string(let scope)? = fields["scope"],
      scopes.contains(scope),
      case .string(let vmString)? = fields["vmID"],
      case .string(let sessionString)? = fields["sessionID"],
      let vmID = canonicalUUID(vmString), let sessionID = canonicalUUID(sessionString),
      case .string(let controlSocket)? = fields["controlSocket"],
      case .string(let displaySocket)? = fields["displaySocket"],
      canonicalSocket(controlSocket), canonicalSocket(displaySocket),
      case .integer(let parentDeviceToken)? = fields["parentDevice"],
      let parentDevice = Int32(parentDeviceToken),
      case .integer(let parentInodeToken)? = fields["parentInode"],
      !parentInodeToken.hasPrefix("-"), let parentInode = UInt64(parentInodeToken),
      case .integer(let socketDeviceToken)? = fields["socketDevice"],
      let socketDevice = Int32(socketDeviceToken),
      case .integer(let socketInodeToken)? = fields["socketInode"],
      !socketInodeToken.hasPrefix("-"), let socketInode = UInt64(socketInodeToken)
    else { throw invalidDisplayRoute() }
    return DisplayWorkerRoute(
      scope: scope, vmID: vmID, sessionID: sessionID, controlSocket: controlSocket,
      displaySocket: displaySocket, parentDevice: parentDevice, parentInode: parentInode,
      socketDevice: socketDevice, socketInode: socketInode)
  }

  private static func canonicalUUID(_ value: String) -> UUID? {
    guard value.utf8.count == 36, let uuid = UUID(uuidString: value),
      uuid.uuidString.lowercased() == value.lowercased()
    else { return nil }
    return uuid
  }

  private static func canonicalSocket(_ value: String) -> Bool {
    guard value.hasPrefix("/"), value.utf8.count <= maximumSocketBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return false }
    return value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

/// Original bounded flat-parser pattern shared by project-owned metadata. JSONDecoder
/// handles individual string tokens only; it never receives an object/array graph.
private struct DisplayRouteScalarParser {
  enum Value: Equatable {
    case string(String)
    case integer(String)
  }
  let bytes: [UInt8]
  private var index = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func parse() throws -> [String: Value] {
    var result: [String: Value] = [:]
    try consume(123)
    repeat {
      guard result.count < 10 else { throw invalidDisplayRoute() }
      let key = try string()
      guard result[key] == nil else { throw invalidDisplayRoute() }
      try consume(58)
      whitespace()
      guard index < bytes.count else { throw invalidDisplayRoute() }
      let value: Value
      if bytes[index] == 34 {
        value = .string(try string())
      } else {
        value = .integer(try integer())
      }
      result[key] = value
      whitespace()
      guard index < bytes.count else { throw invalidDisplayRoute() }
      if bytes[index] == 125 {
        index += 1
        whitespace()
        guard index == bytes.count else { throw invalidDisplayRoute() }
        return result
      }
      try consume(44)
    } while true
  }

  private mutating func integer() throws -> String {
    let start = index
    if bytes[index] == 45 { index += 1 }
    guard index < bytes.count else { throw invalidDisplayRoute() }
    if bytes[index] == 48 {
      index += 1
    } else {
      guard (49...57).contains(bytes[index]) else { throw invalidDisplayRoute() }
      repeat { index += 1 } while index < bytes.count && (48...57).contains(bytes[index])
    }
    return String(decoding: bytes[start..<index], as: UTF8.self)
  }

  private mutating func string() throws -> String {
    whitespace()
    let start = index
    try consume(34)
    var escaped = false
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      guard byte >= 32 else { throw invalidDisplayRoute() }
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) } catch
        {
          throw invalidDisplayRoute()
        }
      }
    }
    throw invalidDisplayRoute()
  }

  private mutating func consume(_ expected: UInt8) throws {
    whitespace()
    guard index < bytes.count, bytes[index] == expected else { throw invalidDisplayRoute() }
    index += 1
  }

  private mutating func whitespace() {
    while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
}

private func invalidDisplayRoute() -> VMError {
  VMError(
    .corruptMetadata, "Display worker route is invalid or exceeds its bounds.",
    recovery: "Preserve the private route and inspect the actual worker before reconnecting.")
}
