// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore

private let displayRouteLiteral = """
  {"schemaVersion":1,"scope":"original-diskless-display-route",
  "vmID":"11111111-2222-4333-8444-555555555555",
  "sessionID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
  "controlSocket":"/private/tmp/mvo-efi-0123456789abcdef/worker.sock",
  "displaySocket":"/private/tmp/mvo-efi-0123456789abcdef/vnc.sock",
  "parentDevice":16777233,"parentInode":42,"socketDevice":16777233,"socketInode":43}
  """

private func replacingDisplayField(_ key: String, with token: String) -> Data {
  let originals: [String: String] = [
    "schemaVersion": "1", "scope": "\"original-diskless-display-route\"",
    "vmID": "\"11111111-2222-4333-8444-555555555555\"",
    "sessionID": "\"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE\"",
    "controlSocket": "\"/private/tmp/mvo-efi-0123456789abcdef/worker.sock\"",
    "displaySocket": "\"/private/tmp/mvo-efi-0123456789abcdef/vnc.sock\"",
    "parentDevice": "16777233", "parentInode": "42",
    "socketDevice": "16777233", "socketInode": "43",
  ]
  let original = originals[key]!
  return Data(
    displayRouteLiteral.replacingOccurrences(
      of: "\"\(key)\":\(original)", with: "\"\(key)\":\(token)"
    ).utf8)
}

private func displayStringToken(_ value: String) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

@Suite struct FlatDisplayRouteCodecTests {
  @Test func registeredQemuRouteIsSeparateFromEveryPrivateExperimentProfile() throws {
    let bytes = replacingDisplayField("scope", with: "\"macopenvm-registered-qemu-display-route\"")
    #expect(
      try FlatDisplayRouteCodec.decode(bytes, profile: .registeredQemu).scope
        == "macopenvm-registered-qemu-display-route")
    for profile: FlatDisplayRouteCodec.Profile in [
      .existing, .windowsNetworkContinuation, .windowsExternalContinuation,
    ] {
      #expect(throws: VMError.self) { try FlatDisplayRouteCodec.decode(bytes, profile: profile) }
    }
    for scope in [
      "original-diskless-display-route", "approved-windows-installer-display-route",
      "approved-windows-network-continuation-display-route",
      "approved-windows-external-continuation-display-route",
    ] {
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(
          replacingDisplayField("scope", with: try displayStringToken(scope)),
          profile: .registeredQemu)
      }
    }
  }

  @Test func externalContinuationHasOneSeparateExactScope() throws {
    let bytes = replacingDisplayField(
      "scope", with: "\"approved-windows-external-continuation-display-route\"")
    #expect(
      try FlatDisplayRouteCodec.decode(bytes, profile: .windowsExternalContinuation).scope
        == "approved-windows-external-continuation-display-route")
    #expect(throws: VMError.self) { try FlatDisplayRouteCodec.decode(bytes) }
    #expect(throws: VMError.self) {
      try FlatDisplayRouteCodec.decode(bytes, profile: .windowsNetworkContinuation)
    }
    for scope in [
      "original-diskless-display-route", "approved-windows-installer-display-route",
      "approved-windows-network-continuation-display-route",
    ] {
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(
          replacingDisplayField("scope", with: try displayStringToken(scope)),
          profile: .windowsExternalContinuation)
      }
    }
  }

  @Test func externalContinuationRetainsFlatDuplicateAndEndpointBounds() throws {
    let bytes = replacingDisplayField(
      "scope", with: "\"approved-windows-external-continuation-display-route\"")
    let text = String(decoding: bytes, as: UTF8.self)
    for changed in [
      Data(("{\"\\u0076mID\":\"11111111-2222-4333-8444-555555555555\"," + text.dropFirst()).utf8),
      Data(text.replacingOccurrences(of: "\"socketInode\":43", with: "\"socketInode\":[43]").utf8),
      Data(
        text.replacingOccurrences(
          of: "/private/tmp/mvo-efi-0123456789abcdef/vnc.sock", with: "/private/tmp/../vnc.sock"
        ).utf8),
      bytes + Data(repeating: 32, count: FlatDisplayRouteCodec.maximumBytes),
    ] {
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(changed, profile: .windowsExternalContinuation)
      }
    }
  }

  @Test func continuationRoutesRequireSeparateExplicitProfile() throws {
    let data = replacingDisplayField(
      "scope", with: "\"approved-windows-network-continuation-display-route\"")
    #expect(throws: VMError.self) { try FlatDisplayRouteCodec.decode(data) }
    let admitted = try FlatDisplayRouteCodec.decode(data, profile: .windowsNetworkContinuation)
    #expect(admitted.scope == "approved-windows-network-continuation-display-route")
    #expect(admitted.vmID == UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
    #expect(admitted.sessionID == UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
    for scope in ["original-diskless-display-route", "approved-windows-installer-display-route"] {
      let old = replacingDisplayField("scope", with: try displayStringToken(scope))
      #expect(try FlatDisplayRouteCodec.decode(old).scope == scope)
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(old, profile: .windowsNetworkContinuation)
      }
    }
  }

  @Test func continuationProfileKeepsFlatIdentityAndEndpointBounds() throws {
    let text = String(
      decoding: replacingDisplayField(
        "scope", with: "\"approved-windows-network-continuation-display-route\""), as: UTF8.self)
    for data in [
      Data(("{\"\\u0076mID\":\"11111111-2222-4333-8444-555555555555\"," + text.dropFirst()).utf8),
      Data(text.replacingOccurrences(of: "\"socketInode\":43", with: "\"socketInode\":[43]").utf8),
      Data(
        text.replacingOccurrences(
          of: "/private/tmp/mvo-efi-0123456789abcdef/vnc.sock", with: "/private/tmp/../vnc.sock"
        ).utf8),
    ] {
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(data, profile: .windowsNetworkContinuation)
      }
    }
  }

  @Test func windowsInstallerScopeStaysExplicit() throws {
    let route = try FlatDisplayRouteCodec.decode(
      replacingDisplayField("scope", with: "\"approved-windows-installer-display-route\""))
    #expect(route.scope == "approved-windows-installer-display-route")
    #expect(try route != FlatDisplayRouteCodec.decode(Data(displayRouteLiteral.utf8)))
    #expect(throws: VMError.self) {
      try FlatDisplayRouteCodec.decode(
        replacingDisplayField("scope", with: "\"windows-production-display-route\""))
    }
  }

  @Test func fixedLiteralDecodesExactTypedFields() throws {
    let route = try FlatDisplayRouteCodec.decode(Data(displayRouteLiteral.utf8))
    #expect(route.schemaVersion == 1 && route.scope == "original-diskless-display-route")
    #expect(route.vmID == UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
    #expect(route.sessionID == UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
    #expect(route.controlSocket == "/private/tmp/mvo-efi-0123456789abcdef/worker.sock")
    #expect(route.displaySocket == "/private/tmp/mvo-efi-0123456789abcdef/vnc.sock")
    #expect(route.parentDevice == 16_777_233 && route.parentInode == 42)
    #expect(route.socketDevice == 16_777_233 && route.socketInode == 43)
  }

  @Test func escapedKeysAndLowercaseCanonicalUUIDsRemainEquivalent() throws {
    let original = try FlatDisplayRouteCodec.decode(Data(displayRouteLiteral.utf8))
    let alternate =
      displayRouteLiteral
      .replacingOccurrences(of: "\"schemaVersion\"", with: "\"\\u0073chemaVersion\"")
      .replacingOccurrences(
        of: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", with: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
    #expect(try FlatDisplayRouteCodec.decode(Data(alternate.utf8)) == original)
  }

  @Test(arguments: ["literal", "escaped", "numeric", "scope"])
  func duplicateDecodedKeysAreRejected(_ kind: String) {
    let duplicate: String
    switch kind {
    case "escaped": duplicate = "\"\\u0076mID\":\"11111111-2222-4333-8444-555555555555\","
    case "numeric": duplicate = "\"parentInode\":42,"
    case "scope": duplicate = "\"\\u0073cope\":\"original-diskless-display-route\","
    default: duplicate = "\"vmID\":\"11111111-2222-4333-8444-555555555555\","
    }
    let bytes = Data(("{" + duplicate + displayRouteLiteral.dropFirst()).utf8)
    #expect(throws: VMError.self) { try FlatDisplayRouteCodec.decode(bytes) }
  }

  @Test func unknownMissingNestedAndMalformedObjectsReject() {
    let cases = [
      "", "{}", "[]", displayRouteLiteral + " trailing", displayRouteLiteral + displayRouteLiteral,
      displayRouteLiteral.replacingOccurrences(of: "\"socketInode\":43", with: "\"unknown\":43"),
      displayRouteLiteral.replacingOccurrences(of: ",\"socketInode\":43", with: ""),
      displayRouteLiteral.replacingOccurrences(
        of: "\"parentInode\":42", with: "\"parentInode\":[42]"),
      displayRouteLiteral.replacingOccurrences(
        of: "\"parentInode\":42", with: "\"parentInode\":{\"n\":42}"),
      displayRouteLiteral.replacingOccurrences(
        of: "\"parentInode\":42", with: "\"parentInode\":null"),
      displayRouteLiteral.replacingOccurrences(
        of: "\"socketInode\":43", with: "\"socketInode\":43,"),
      displayRouteLiteral.replacingOccurrences(of: "\"scope\":", with: "\"scope\" "),
    ]
    for text in cases {
      #expect(throws: VMError.self) { try FlatDisplayRouteCodec.decode(Data(text.utf8)) }
    }
    #expect(throws: VMError.self) { try FlatDisplayRouteCodec.decode(Data([0xff, 0xfe])) }
  }

  @Test func schemaAndIntegerTokensUseExactRanges() throws {
    for token in ["0", "2", "-1", "1.0", "1e0", "01", "+1", "true", "\"1\""] {
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(replacingDisplayField("schemaVersion", with: token))
      }
    }
    for key in ["parentDevice", "socketDevice"] {
      for token in [
        "2147483648", "-2147483649", "18446744073709551615", "1.0", "1e2", "01", "+1", "false",
        "\"1\"",
      ] {
        #expect(throws: VMError.self) {
          try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: token))
        }
      }
      for token in ["-2147483648", "2147483647", "0"] {
        let route = try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: token))
        #expect((key == "parentDevice" ? route.parentDevice : route.socketDevice) == Int32(token))
      }
    }
    for key in ["parentInode", "socketInode"] {
      for token in ["18446744073709551616", "-1", "-0", "1.0", "1e2", "01", "+1", "true", "\"1\""] {
        #expect(throws: VMError.self) {
          try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: token))
        }
      }
      for token in ["0", "18446744073709551615"] {
        let route = try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: token))
        #expect((key == "parentInode" ? route.parentInode : route.socketInode) == UInt64(token))
      }
    }
  }

  @Test func uuidAndScopeRequireCanonicalStrings() throws {
    for key in ["vmID", "sessionID"] {
      for value in [
        "", "11111111222243338444555555555555", "{11111111-2222-4333-8444-555555555555}",
        "11111111-2222-4333-8444-55555555555Z", " 11111111-2222-4333-8444-555555555555",
      ] {
        let token = try displayStringToken(value)
        #expect(throws: VMError.self) {
          try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: token))
        }
      }
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: "true"))
      }
    }
    for token in ["\"other-scope\"", "\"original-diskless-display-route \"", "1", "false"] {
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(replacingDisplayField("scope", with: token))
      }
    }
  }

  @Test func socketStringsAreBoundedCanonicalAbsoluteValuesOnly() throws {
    for key in ["controlSocket", "displaySocket"] {
      let invalid = [
        "", "/", "relative.sock", "file:///socket", "//host/socket", "/tmp//socket",
        "/tmp/./socket",
        "/tmp/../socket", "/tmp/socket/", "/tmp/\0socket", "/tmp/\nsocket", "/tmp/\tsocket",
        "/tmp/\u{7f}socket", "/tmp/\u{85}socket", "/" + String(repeating: "a", count: 103),
        "/" + String(repeating: "é", count: 52),
      ]
      for value in invalid {
        let token = try displayStringToken(value)
        #expect(throws: VMError.self) {
          try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: token))
        }
      }
      for value in [
        "/" + String(repeating: "a", count: 102), "/" + String(repeating: "é", count: 51),
      ] {
        let route = try FlatDisplayRouteCodec.decode(
          replacingDisplayField(key, with: displayStringToken(value)))
        #expect((key == "controlSocket" ? route.controlSocket : route.displaySocket) == value)
      }
      #expect(throws: VMError.self) {
        try FlatDisplayRouteCodec.decode(replacingDisplayField(key, with: "1"))
      }
    }
  }

  @Test func exactRecordLimitAndPrivacyErrorArePreserved() throws {
    let original = Data(displayRouteLiteral.utf8)
    var bounded = original
    bounded.append(Data(repeating: 32, count: FlatDisplayRouteCodec.maximumBytes - bounded.count))
    let paddedRoute = try FlatDisplayRouteCodec.decode(bounded)
    let originalRoute = try FlatDisplayRouteCodec.decode(original)
    #expect(paddedRoute == originalRoute)
    bounded.append(32)
    #expect(throws: VMError.self) { try FlatDisplayRouteCodec.decode(bounded) }
    let secret = "/private-fixture-sentinel/../secret-socket"
    do {
      _ = try FlatDisplayRouteCodec.decode(
        replacingDisplayField("controlSocket", with: displayStringToken(secret)))
      Issue.record("Unsafe socket unexpectedly decoded.")
    } catch let error as VMError {
      #expect(error.code == .corruptMetadata)
      #expect(!String(describing: error).contains(secret))
    }
  }
}
