// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMCLI

@Suite struct DiskGrowthIdentityUpgradeOptionTests {
  private let vm = "A1111111-1111-4111-8111-111111111111"
  private let transaction = "B2222222-2222-4222-8222-222222222222"

  @Test func confirmationTraversesBothOptionGatesAndRequiresExplicitAcknowledgment() throws {
    let options = try MacOpenVMCLI.parse([
      "--directory", "/private/tmp/fresh.macopenvm", "--vm-id", vm,
      "--growth-transaction", transaction, "--acknowledge-schema2-incompatibility", "yes",
    ])
    try MacOpenVMCLI.validateOptions(options, command: "upgrade-disk-growth-identity")
    let confirmation = try MacOpenVMCLI.diskGrowthIdentityUpgradeConfirmation(options)
    #expect(confirmation.vmID.uuidString == vm)
    #expect(confirmation.transactionID.uuidString == transaction)
    for command in [
      "check-disk-growth-identity-upgrade", "grow-disk", "finish-disk-growth", "doctor",
      "set-hardware",
    ] {
      #expect(throws: VMError.self) { try MacOpenVMCLI.validateOptions(options, command: command) }
    }
    let readOnly = try MacOpenVMCLI.parse(["--directory", "/private/tmp/fresh.macopenvm"])
    try MacOpenVMCLI.validateOptions(readOnly, command: "check-disk-growth-identity-upgrade")
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.diskGrowthIdentityUpgradeConfirmation(readOnly)
    }
  }

  @Test(arguments: ["", "no", "true", "YES", "Yes", " yes", "yes "])
  func noImplicitOrAlternativeAcknowledgment(value: String) {
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.diskGrowthIdentityUpgradeConfirmation([
        "vm-id": vm, "growth-transaction": transaction,
        "acknowledge-schema2-incompatibility": value,
      ])
    }
  }

  @Test func missingAndNoncanonicalIdentitiesFailBeforeFilesystemWork() {
    let valid = [
      "vm-id": vm, "growth-transaction": transaction, "acknowledge-schema2-incompatibility": "yes",
    ]
    for key in ["vm-id", "growth-transaction", "acknowledge-schema2-incompatibility"] {
      var missing = valid
      missing.removeValue(forKey: key)
      #expect(throws: VMError.self) {
        try MacOpenVMCLI.diskGrowthIdentityUpgradeConfirmation(missing)
      }
    }
    for key in ["vm-id", "growth-transaction"] {
      for value in [
        "not-a-uuid", "00000000-0000-0000-0000-000000000000", valid[key]!.lowercased(),
        " " + valid[key]!, valid[key]! + " ",
      ] {
        var malformed = valid
        malformed[key] = value
        #expect(throws: VMError.self) {
          try MacOpenVMCLI.diskGrowthIdentityUpgradeConfirmation(malformed)
        }
      }
    }
  }

  @Test func duplicatesUnknownOptionsAndCrossCommandLeakageStayRejected() {
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.parse([
        "--growth-transaction", transaction, "--growth-transaction", transaction,
      ])
    }
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.parse([
        "--acknowledge-schema2-incompatibility", "yes", "--acknowledge-schema2-incompatibility",
        "yes",
      ])
    }
    #expect(throws: VMError.self) { try MacOpenVMCLI.parse(["--force-legacy-device", "yes"]) }
    for key in ["disk-gib", "confirm-data-loss", "confirm-move-to-trash", "expected-session"] {
      #expect(throws: VMError.self) {
        try MacOpenVMCLI.validateOptions(
          ["directory": "/private/tmp/vm", key: "1"], command: "upgrade-disk-growth-identity")
      }
    }
  }
}
