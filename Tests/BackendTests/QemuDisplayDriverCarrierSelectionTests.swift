// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu
import Testing

/// Actual catalog selection only. No verify, file creation, launch or runtime permit.
@Suite struct QemuDisplayDriverCarrierSelectionTests {
  enum Carrier: CaseIterable, Sendable {
    case complete, legacy, network

    func image(projectRoot: URL) throws -> ReviewedQemuSupportImage {
      switch self {
      case .complete:
        try QemuRegisteredCatalog.displayDriverSupportImage(projectRoot: projectRoot)
      case .legacy:
        try QemuRegisteredCatalog.legacyDisplayDriverSupportImage(projectRoot: projectRoot)
      case .network:
        try QemuRegisteredCatalog.networkDriverSupportImage(projectRoot: projectRoot)
      }
    }
  }

  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  private func configuration(shared: Bool) -> VMConfiguration {
    var value = VMConfiguration(
      name: "Carrier catalog selection", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    value.network = shared ? .shared : .disconnected
    return value
  }

  private func previousAcceleratedImage() throws -> ReviewedQemuSupportImage {
    try ReviewedQemuSupportImage(
      url: root.appendingPathComponent(
        ".lab/windows-gpu-driver-v04-20261015/macopenvm-graphics-check-v8.iso"),
      byteCount: 6_387_712,
      sha256: "081fbffac74f3e59f9e2256d5efc50b326b56d5911f02c49cf708ca58a4457a0")
  }

  private func expectSameRuntime(
    _ selected: ReviewedQemuLaunchResources, _ baseline: ReviewedQemuLaunchResources
  ) {
    #expect(selected.creation == baseline.creation)
    #expect(selected.runtimeQemu == baseline.runtimeQemu)
    #expect(selected.supportsShared == baseline.supportsShared)
    #expect(selected.libraries == baseline.libraries)
    #expect(selected.qemuImports == baseline.qemuImports)
    #expect(selected.swtpmImports == baseline.swtpmImports)
    #expect(selected.systemImports == baseline.systemImports)
    #expect(selected.agentChannel == baseline.agentChannel)
    #expect(selected.displayEvaluation == baseline.displayEvaluation)
    #expect(selected.acceleratedDisplay == baseline.acceleratedDisplay)
    #expect(selected.renderServer == baseline.renderServer)
    #expect(selected.sharedFrameTransport == baseline.sharedFrameTransport)
    #expect(selected.audioOutput == baseline.audioOutput)
    #expect(selected.keyboardMap == baseline.keyboardMap)
    #expect(selected.extraReadOnlyTools == baseline.extraReadOnlyTools)
  }

  @Test func exactDescriptorsRetainTheOldCarriersAndPinTheCompleteDefault() throws {
    let complete = try Carrier.complete.image(projectRoot: root)
    #expect(
      complete.url
        == root.appendingPathComponent(
          ".lab/windows-driver-support-74576ef0ea6441bf92f92d78cd62ec28/macopenvm-driver-evaluation-complete.iso"
        ))
    #expect(complete.byteCount == 921_600)
    #expect(complete.sha256 == "cb9f8dea1c9c0647e73f61ecb204f3f09af2b9bfe46fe1056806b278878c8f6d")
    let legacy = try Carrier.legacy.image(projectRoot: root)
    #expect(
      legacy.url
        == root.appendingPathComponent(
          ".lab/windows-display-support-3ff9bac089d546578527603a56909818/macopenvm-display-evaluation.iso"
        ))
    #expect(legacy.byteCount == 921_600)
    #expect(legacy.sha256 == "55897e3e181068a5e5e4ea52a1e2aed7ec2bbc296ae0afc549d0c139e2dbef3d")
    let network = try Carrier.network.image(projectRoot: root)
    #expect(
      network.url
        == root.appendingPathComponent(
          ".lab/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso"
        ))
    #expect(network.byteCount == 921_600)
    #expect(network.sha256 == "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394")
    #expect(Set([complete.url, legacy.url, network.url]).count == 3)
  }

  @Test(arguments: [false, true], Carrier.allCases)
  func twoDimensionalSelectionRetainsEachExactCarrierWithoutChangingRuntime(
    shared: Bool, carrier: Carrier
  ) throws {
    var value = configuration(shared: shared)
    let baseline = try QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(
      for: value, projectRoot: root)
    let image = try carrier.image(projectRoot: root)
    value.supportMedia = image.url.path
    let selected = try QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(
      for: value, projectRoot: root)
    #expect(selected.supportImage == image)
    expectSameRuntime(selected, baseline)
  }

  @Test(arguments: [false, true])
  func noSavedDiscDoesNotAttachAnyCarrier(shared: Bool) throws {
    let value = configuration(shared: shared)
    let ordinary = try QemuRegisteredCatalog.registeredEvaluation(for: value, projectRoot: root)
    let basic = try QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(
      for: value, projectRoot: root)
    let accelerated = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: value, projectRoot: root)
    #expect(ordinary.supportImage == nil && basic.supportImage == nil)
    #expect(accelerated.supportImage == nil)
    #expect(basic.creation == ordinary.creation && accelerated.creation == ordinary.creation)
    #expect(basic.supportsShared == ordinary.supportsShared)
    #expect(accelerated.supportsShared == ordinary.supportsShared)
  }

  @Test(arguments: [false, true], ["foreign", "sibling", "case", "accelerated", "accelerated-v8"])
  func twoDimensionalSelectionRefusesForeignOrConfusedPaths(shared: Bool, kind: String) throws {
    var value = configuration(shared: shared)
    // Establish a positive same-configuration control before each negative path.
    _ = try QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(for: value, projectRoot: root)
    let complete = try Carrier.complete.image(projectRoot: root)
    switch kind {
    case "foreign": value.supportMedia = "/private/tmp/foreign-complete-driver-disc.iso"
    case "sibling": value.supportMedia = complete.url.path + ".copy"
    case "case":
      value.supportMedia = complete.url.path.replacingOccurrences(
        of: "windows-driver-support-", with: "Windows-driver-support-")
    case "accelerated-v8": value.supportMedia = try previousAcceleratedImage().url.path
    default:
      value.supportMedia =
        try QemuRegisteredCatalog.acceleratedDisplaySupportImage(projectRoot: root).url.path
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(for: value, projectRoot: root)
    }
  }

  @Test(arguments: [false, true])
  func ordinarySelectionRemainsNetworkOnly(shared: Bool) throws {
    var value = configuration(shared: shared)
    let baseline = try QemuRegisteredCatalog.registeredEvaluation(for: value, projectRoot: root)
    let network = try Carrier.network.image(projectRoot: root)
    value.supportMedia = network.url.path
    let selected = try QemuRegisteredCatalog.registeredEvaluation(for: value, projectRoot: root)
    #expect(selected.supportImage == network)
    expectSameRuntime(selected, baseline)
    let accelerated = try QemuRegisteredCatalog.acceleratedDisplaySupportImage(projectRoot: root)
    for path in [
      try Carrier.complete.image(projectRoot: root).url.path,
      try Carrier.legacy.image(projectRoot: root).url.path,
      accelerated.url.path, try previousAcceleratedImage().url.path,
      "/private/tmp/foreign-network-driver-disc.iso",
    ] {
      value.supportMedia = path
      #expect(throws: VMError.self) {
        try QemuRegisteredCatalog.registeredEvaluation(for: value, projectRoot: root)
      }
    }
  }

  @Test(arguments: [false, true])
  func acceleratedSelectionKeepsV8AndRefusesEveryBasicCarrier(shared: Bool) throws {
    var value = configuration(shared: shared)
    let baseline = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: value, projectRoot: root)
    #expect(baseline.supportImage == nil)
    let current = try QemuRegisteredCatalog.acceleratedDisplaySupportImage(projectRoot: root)
    #expect(
      current.url
        == root.appendingPathComponent(
          ".lab/manager-iteration-20261016/root-windows-graphics-tools-v9-iso1/macopenvm-graphics-check-v9.iso"
        ))
    #expect(current.byteCount == 6_488_064)
    #expect(current.sha256 == "041d07817f37e1f89ff5175c98a879675be8328ab2f00e192c3154629a670056")
    for image in [current, try previousAcceleratedImage()] {
      value.supportMedia = image.url.path
      let selected = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
        for: value, projectRoot: root)
      #expect(selected.supportImage == image)
      expectSameRuntime(selected, baseline)
    }
    var rejected = try Carrier.allCases.map { try $0.image(projectRoot: root).url.path }
    rejected += [
      root.appendingPathComponent(
        ".lab/windows-graphics-diagnostics-20261013/macopenvm-graphics-check-v7.iso"
      ).path,
      root.appendingPathComponent(
        ".lab/manager-iteration-20261016/root-native-d3d11-presenter-r4-carrier1/macopenvm-native-d3d11-presenter.iso"
      ).path,
      root.appendingPathComponent(
        ".lab/manager-iteration-20261016/root-native-d3d11-presenter-r5-phase-carrier1/macopenvm-native-d3d11-presenter.iso"
      ).path,
      current.url.path + ".copy",
      current.url.path.replacingOccurrences(
        of: "macopenvm-graphics-check-v9.iso", with: "MacOpenVM-graphics-check-v9.iso"),
      "/private/tmp/macopenvm-graphics-check-v9.iso",
      "/private/tmp/foreign-accelerated-driver-disc.iso",
    ]
    for path in rejected {
      value.supportMedia = path
      #expect(throws: VMError.self) {
        try QemuRegisteredCatalog.acceleratedDisplayEvaluation(for: value, projectRoot: root)
      }
    }
  }
}
