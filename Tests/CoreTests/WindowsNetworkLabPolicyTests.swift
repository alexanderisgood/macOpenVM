// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import VMCore

private let winApprovalDirectory = "/private/tmp/macopenvm-approved-windows"
private let winApprovalVM = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
private let winApprovalSession = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
private let winApprovalPlan = String(repeating: "a", count: 64)
private let winApprovalMAC = "02:11:22:33:44:55"
private let winApprovalFrame = String(repeating: "b", count: 64)

private func winApprovalData(
  changes: [String: Any] = [:], omitted: Set<String> = [], reviewed: String? = nil
) throws -> Data {
  var values: [String: Any] = [
    "schemaVersion": 1, "scope": "approved-same-vm-windows-network-lab",
    "directory": winApprovalDirectory, "vmID": winApprovalVM.uuidString,
    "previousSessionID": winApprovalSession.uuidString, "planSHA256": winApprovalPlan,
    "macAddress": winApprovalMAC,
    "candidateSHA256": "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745",
    "driverISOSHA256": "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394",
    "networkAuthorized": true, "driverInstallationAuthorized": true,
    "normalShutdownAuthorized": true, "resumeAuthorized": true, "credentialsAuthorized": false,
  ]
  if let reviewed { values["consoleReviewedSHA256"] = reviewed }
  for (key, value) in changes { values[key] = value }
  for key in omitted { values.removeValue(forKey: key) }
  return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
}

private func winApproval(_ data: Data) throws -> WindowsNetworkLabApproval {
  try .validate(
    data: data, directory: winApprovalDirectory, vmID: winApprovalVM,
    sessionID: winApprovalSession, planSHA256: winApprovalPlan, macAddress: winApprovalMAC)
}

@Test func windowsNetworkApprovalRoundTripAndReviewedControl() throws {
  let initial = try winApproval(winApprovalData())
  try initial.requireControl(action: "open-console", expectedFrame: winApprovalFrame)
  #expect(throws: WindowsNetworkLabPolicyError.unreviewedFrame) {
    try initial.requireControl(action: "normal-shutdown", expectedFrame: winApprovalFrame)
  }
  let encoded = try JSONEncoder().encode(initial)
  let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect(fields.count == 15 && fields["consoleReviewedSHA256"] is NSNull)
  #expect(try winApproval(encoded) == initial)
  let reviewed = try winApproval(winApprovalData(reviewed: winApprovalFrame))
  try reviewed.requireControl(action: "normal-shutdown", expectedFrame: winApprovalFrame)
  #expect(throws: WindowsNetworkLabPolicyError.unreviewedFrame) {
    try reviewed.requireControl(action: "normal-shutdown", expectedFrame: winApprovalPlan)
  }
}

@Test(arguments: [
  "networkAuthorized", "driverInstallationAuthorized", "normalShutdownAuthorized",
  "resumeAuthorized",
])
func windowsNetworkApprovalRequiresEveryAuthorization(_ key: String) throws {
  for data in [try winApprovalData(changes: [key: false]), try winApprovalData(omitted: [key])] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) { try winApproval(data) }
  }
}

@Test func windowsNetworkApprovalRejectsCredentialsPinsUnknownAndWrongTypes() throws {
  let cases: [[String: Any]] = [
    ["credentialsAuthorized": true], ["credentialsAuthorized": NSNull()],
    ["networkAuthorized": 1], ["resumeAuthorized": "true"], ["schemaVersion": true],
    ["scope": "ordinary-network"], ["candidateSHA256": winApprovalPlan],
    ["driverISOSHA256": winApprovalPlan], ["launchAuthorized": true],
    ["consoleReviewedSHA256": "short"], ["vmID": "not-a-uuid"],
  ]
  for change in cases {
    #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) {
      try winApproval(winApprovalData(changes: change))
    }
  }
  #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) {
    try winApproval(winApprovalData(omitted: ["credentialsAuthorized"]))
  }
}

@Test func windowsNetworkApprovalMatchesExactCallerContext() throws {
  for change in [
    ["directory": "/private/tmp/another-vm"], ["vmID": UUID().uuidString],
    ["previousSessionID": UUID().uuidString], ["planSHA256": winApprovalFrame],
    ["macAddress": "02:11:22:33:44:56"],
  ] {
    #expect(throws: WindowsNetworkLabPolicyError.contextMismatch) {
      try winApproval(winApprovalData(changes: change))
    }
  }
}

@Test func windowsNetworkApprovalRejectsBadPathsHashesAndMulticast() throws {
  for path in [
    "relative", "/private/tmp/../vm", "/private//tmp/vm", "/private/tmp/vm/", "/tmp/\nvm",
  ] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) {
      try winApproval(winApprovalData(changes: ["directory": path]))
    }
  }
  for mac in [
    "03:11:22:33:44:55", "ff:ff:ff:ff:ff:ff", "00:00:00:00:00:00", "2:11:22:33:44:55",
    "02:11:22:33:44:gg",
  ] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) {
      try winApproval(winApprovalData(changes: ["macAddress": mac]))
    }
  }
  for digest in [
    String(repeating: "g", count: 64), String(repeating: "a", count: 63),
    winApprovalPlan.uppercased(),
  ] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) {
      try winApproval(winApprovalData(changes: ["planSHA256": digest]))
    }
  }
}

@Test func windowsNetworkApprovalRejectsAmbiguousOrNonflatJSON() throws {
  let good = String(decoding: try winApprovalData(), as: UTF8.self)
  let duplicate = String(good.dropLast()) + ",\"networkAuthorized\":false}"
  let escaped = String(good.dropLast()) + ",\"network\\u0041uthorized\":true}"
  let nested = good.replacingOccurrences(
    of: "\"networkAuthorized\":true", with: "\"networkAuthorized\":{\"value\":true}")
  let array = good.replacingOccurrences(
    of: "\"networkAuthorized\":true", with: "\"networkAuthorized\":[true]")
  let decimal = good.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0")
  for text in [
    duplicate, escaped, nested, array, decimal, good + "{}", String(good.dropLast()) + ",}", "{}",
  ] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) {
      try winApproval(Data(text.utf8))
    }
  }
  for data in [Data(), Data([0xff]), Data(repeating: 32, count: 8193)] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidApproval) { try winApproval(data) }
  }
}

@Test func windowsNetworkApprovalAdmitsOnlyFixedControlWithBoundedFrame() throws {
  let approval = try winApproval(winApprovalData(reviewed: winApprovalFrame))
  for action in ["quit", "force-stop", "resume", "shutdown /r", "open-console;quit", ""] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidControl) {
      try approval.requireControl(action: action, expectedFrame: winApprovalFrame)
    }
  }
  for frame in ["", String(repeating: "b", count: 63), String(repeating: "g", count: 64)] {
    #expect(throws: WindowsNetworkLabPolicyError.invalidControl) {
      try approval.requireControl(action: "open-console", expectedFrame: frame)
    }
  }
}
