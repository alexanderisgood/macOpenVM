// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import Qemu

/// Actual resource/signature/import checks only. No endpoint, runtime permit,
/// process, guest, network or driver installation is created by this test.
@Suite struct QemuSharedCatalogNativeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_NAT_CATALOG_CHECK"] == "1",
      "Requires explicit MACOPENVM_NATIVE_NAT_CATALOG_CHECK=1 and the audited private driver carrier."
    )
  )
  func actualReviewedDriverCarrierVerifiesReadOnly() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let carrier = try QemuRegisteredCatalog.networkDriverSupportImage(projectRoot: root)
    #expect(carrier.byteCount == 921_600)
    #expect(carrier.sha256 == "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394")
    try carrier.verify()
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_NAT_CATALOG_CHECK"] == "1",
      "Requires explicit MACOPENVM_NATIVE_NAT_CATALOG_CHECK=1 and independently reviewed local resources."
    )
  )
  func actualSharedRuntimeVerifiesWithoutChangingCreationProvenance() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let offline = try QemuRegisteredCatalog.offlineEvaluation(projectRoot: root)
    let shared = try QemuRegisteredCatalog.sharedEvaluation(projectRoot: root)
    #expect(!offline.supportsShared && shared.supportsShared)
    #expect(shared.creation == offline.creation)
    #expect(shared.libraries.count == offline.libraries.count + 1)
    #expect(Array(shared.libraries.dropLast()) == offline.libraries)
    #expect(
      shared.swtpmImports == offline.swtpmImports && shared.systemImports == offline.systemImports)
    #expect(
      shared.runtimeQemu.sha256
        == "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745")
    #expect(shared.runtimeQemu.byteCount == 26_746_208)
    #expect(
      shared.libraries.last?.sha256
        == "10d404d8a693f2d37401ce0ff54e71d9ffb4a5fe42335a360dea39e6d083a5ab")
    try shared.verify()
    try offline.verify()
  }
}
