// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import Qemu

@Suite struct QemuProducerCaptureResourcesTests {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  private func configuration(shared: Bool) -> VMConfiguration {
    var value = VMConfiguration(
      name: "Explicit capture resource evaluation", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    value.network = shared ? .shared : .disconnected
    return value
  }

  private func expectAllOtherFields(
    _ selected: ReviewedQemuLaunchResources, _ original: ReviewedQemuLaunchResources
  ) {
    #expect(selected.creation == original.creation)
    #expect(selected.libraries == original.libraries)
    #expect(selected.qemuImports == original.qemuImports)
    #expect(selected.swtpmImports == original.swtpmImports)
    #expect(selected.systemImports == original.systemImports)
    #expect(selected.supportsShared == original.supportsShared)
    #expect(selected.supportImage == original.supportImage)
    #expect(selected.agentChannel == original.agentChannel)
    #expect(selected.displayEvaluation == original.displayEvaluation)
    #expect(selected.acceleratedDisplay == original.acceleratedDisplay)
    #expect(selected.renderServer == original.renderServer)
    #expect(selected.keyboardMap == original.keyboardMap)
    #expect(selected.sharedFrameTransport == original.sharedFrameTransport)
    #expect(selected.audioOutput == original.audioOutput)
  }

  @Test(arguments: [false, true], [false, true])
  func explicitSelectionChangesOnlyThePinnedRuntime(shared: Bool, attachV8: Bool) throws {
    var value = configuration(shared: shared)
    if attachV8 {
      value.supportMedia =
        try QemuRegisteredCatalog.acceleratedDisplaySupportImage(projectRoot: root).url.path
    }
    let original = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: value, projectRoot: root)
    let selected = try QemuRegisteredCatalog.producerCaptureEvaluation(
      for: value, projectRoot: root)
    #expect(selected.runtimeQemu.role == .qemu)
    #expect(
      selected.runtimeQemu.url
        == root.appendingPathComponent(
          ".lab/unified-graphics-20261018/runtimes/capture/qemu-system-aarch64"
        ))
    #expect(selected.runtimeQemu.byteCount == 26_997_280)
    #expect(
      selected.runtimeQemu.sha256
        == "3975e5d2199bafb5ee82b40e5d79507a0a4b7adbdee7b570f2b06be0e492ed0e")
    #expect(selected.runtimeQemu != original.runtimeQemu)
    expectAllOtherFields(selected, original)
    #expect(selected.agentChannel == nil && selected.acceleratedDisplay == nil)
    #expect(selected.renderServer != nil && selected.sharedFrameTransport)
    #expect(selected.audioOutput == .coreAudioHDAV1 && selected.keyboardMap != nil)
  }

  @Test(arguments: [false, true])
  func ordinaryAndAcceleratedDefaultsRemainTheirExistingExactProfiles(shared: Bool) throws {
    let value = configuration(shared: shared)
    let ordinary = try QemuRegisteredCatalog.registeredEvaluation(for: value, projectRoot: root)
    let accelerated = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: value, projectRoot: root)
    let selected = try QemuRegisteredCatalog.producerCaptureEvaluation(
      for: value, projectRoot: root)
    #expect(
      ordinary.runtimeQemu.sha256
        == (shared
          ? "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745"
          : "26674b130d910136b31c7c576277639e8b4c5bc2bc499165acb8f39919e58529"))
    #expect(
      accelerated.runtimeQemu.sha256
        == "b3f6e87446c6967eb2efefd529f9b757de08b51caa6a225c5fb0831d15070955")
    #expect(ordinary.runtimeQemu != selected.runtimeQemu)
    #expect(accelerated.runtimeQemu != selected.runtimeQemu)
    let ordinaryAfter = try QemuRegisteredCatalog.registeredEvaluation(
      for: value, projectRoot: root)
    let acceleratedAfter = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: value, projectRoot: root)
    #expect(ordinary == ordinaryAfter)
    #expect(accelerated == acceleratedAfter)
    #expect(ordinary.audioOutput == nil && ordinary.renderServer == nil)
    #expect(accelerated.audioOutput == .coreAudioHDAV1 && accelerated.sharedFrameTransport)
    #expect(ordinary.supportImage == nil && accelerated.supportImage == nil)
  }

  @Test(arguments: ["guest", "backend", "architecture", "boot"])
  func inheritedWindowsShapeGuardsRemainRequired(field: String) throws {
    var value = configuration(shared: false)
    _ = try QemuRegisteredCatalog.producerCaptureEvaluation(for: value, projectRoot: root)
    switch field {
    case "guest": value.guest = .linux
    case "backend": value.backend = .appleVz
    case "architecture": value.architecture = .x8664
    default: value.boot = .linuxKernel
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.producerCaptureEvaluation(for: value, projectRoot: root)
    }
  }

  @Test(arguments: ["foreign", "complete", "legacy", "network"])
  func inheritedAcceleratedCarrierWhitelistIsNotExpanded(kind: String) throws {
    var value = configuration(shared: false)
    _ = try QemuRegisteredCatalog.producerCaptureEvaluation(for: value, projectRoot: root)
    switch kind {
    case "complete":
      value.supportMedia = try QemuRegisteredCatalog.displayDriverSupportImage(projectRoot: root)
        .url.path
    case "legacy":
      value.supportMedia =
        try QemuRegisteredCatalog.legacyDisplayDriverSupportImage(projectRoot: root).url.path
    case "network":
      value.supportMedia = try QemuRegisteredCatalog.networkDriverSupportImage(projectRoot: root)
        .url.path
    default: value.supportMedia = "/private/tmp/foreign-producer-capture-disc.iso"
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.producerCaptureEvaluation(for: value, projectRoot: root)
    }
  }

  /// Actual pinned unsigned sibling only, not a generic resource-injection helper.
  private func unsignedClone(of selected: ReviewedQemuLaunchResources) throws
    -> ReviewedQemuLaunchResources
  {
    try ReviewedQemuLaunchResources(
      creation: selected.creation, libraries: selected.libraries,
      qemuImports: selected.qemuImports, swtpmImports: selected.swtpmImports,
      systemImports: selected.systemImports,
      runtimeQemu: ReviewedQemuResource(
        role: .qemu,
        url: root.appendingPathComponent(
          ".lab/unified-graphics-20261018/runtimes/capture/qemu-system-aarch64-unsigned"
        ),
        byteCount: 26_943_880,
        sha256: "bfdc53d87625115a59b0fc656299379829e8ffdaca7a394e7d14c7445ca822b6"),
      supportsShared: selected.supportsShared,
      supportImage: selected.supportImage,
      agentChannel: selected.agentChannel,
      displayEvaluation: selected.displayEvaluation,
      acceleratedDisplay: selected.acceleratedDisplay,
      renderServer: selected.renderServer,
      keyboardMap: selected.keyboardMap,
      sharedFrameTransport: selected.sharedFrameTransport,
      audioOutput: selected.audioOutput)
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_CAPTURE_RESOURCE_CHECK"] == "1",
      "Requires explicit MACOPENVM_NATIVE_CAPTURE_RESOURCE_CHECK=1 and the exact signed/unsigned capture closure."
    ), arguments: [false, true]
  )
  func actualSecurityAndResourcePredicateAcceptsSignedAndRefusesUnsigned(shared: Bool) throws {
    let value = configuration(shared: shared)
    let selected = try QemuRegisteredCatalog.producerCaptureEvaluation(
      for: value, projectRoot: root)
    let original = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: value, projectRoot: root)
    expectAllOtherFields(selected, original)
    // Mandatory positive control: real public verification, actual host and
    // production Security APIs. No injected signature or host-major waiver.
    try selected.verify()

    let unsigned = try unsignedClone(of: selected)
    expectAllOtherFields(unsigned, selected)
    #expect(unsigned.runtimeQemu != selected.runtimeQemu)
    // Bind the negative to the real retained bytes and matching ordered imports.
    // A missing/altered/unsafe unsigned file or parser mismatch must fail here,
    // before its later refusal could satisfy the expected-error assertion.
    let bytes = try RegisteredQemuIO.reviewed(
      unsigned.runtimeQemu.url, count: unsigned.runtimeQemu.byteCount,
      sha256: unsigned.runtimeQemu.sha256)
    let imports = try RegisteredMachO.parse(
      bytes, executable: true,
      hostMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    try #require(imports == selected.qemuImports)
    #expect(throws: VMError.self) { try unsigned.verify() }
    // Also observe the exact existing Security predicate's unsigned refusal,
    // rather than attributing an unrelated resource failure to entitlement policy.
    #expect(throws: VMError.self) {
      try RegisteredMachO.signature(unsigned.runtimeQemu.url, hypervisor: true)
    }
    // Recheck the positive closure after both read-only negative observations.
    try selected.verify()
  }
}
