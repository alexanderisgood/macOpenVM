// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import Qemu

/// Read-only hashes, Mach-O imports and signatures. No VM, endpoint, writer,
/// driver, network, process or platform identity is created by this check.
@Suite struct QemuGpuCatalogNativeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_GPU_CATALOG_CHECK"] == "1",
      "Requires explicit MACOPENVM_NATIVE_GPU_CATALOG_CHECK=1 and the reviewed private GPU artifacts."
    )
  )
  func actualGpuClosurePreservesCreationAndRequiresEveryCurrentArtifact() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let configuration = VMConfiguration(
      name: "Public synthetic GPU admission configuration", guest: .windows11,
      backend: .qemuHVF, cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    let base = try QemuRegisteredCatalog.registeredEvaluation(
      for: configuration, projectRoot: root)
    let selected = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: configuration, projectRoot: root)
    #expect(selected.creation == base.creation)
    #expect(selected.supportsShared == base.supportsShared)
    #expect(selected.supportImage == nil && selected.agentChannel == nil)
    #expect(selected.runtimeQemu != base.runtimeQemu && selected.renderServer != nil)
    #expect(base.audioOutput == nil && selected.audioOutput == .coreAudioHDAV1)
    try selected.verify()
    let current = try QemuRegisteredCatalog.acceleratedDisplaySupportImage(projectRoot: root)
    #expect(current.url.lastPathComponent == "macopenvm-graphics-check-v9.iso")
    var attached = configuration
    attached.supportMedia = current.url.path
    let resources = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: attached, projectRoot: root)
    let image = try #require(resources.supportImage)
    #expect(image.url == current.url)
    try image.verify()
    var previous = configuration
    previous.supportMedia =
      root.appendingPathComponent(
        ".lab/windows-gpu-driver-v04-20261015/macopenvm-graphics-check-v8.iso"
      ).path
    let previousResources = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: previous, projectRoot: root)
    let previousImage = try #require(previousResources.supportImage)
    #expect(previousImage.url.path == previous.supportMedia)
    #expect(previousImage.byteCount == 6_387_712)
    #expect(
      previousImage.sha256 == "081fbffac74f3e59f9e2256d5efc50b326b56d5911f02c49cf708ca58a4457a0")
    try previousImage.verify()
    var oldProtocolCarrier = configuration
    oldProtocolCarrier.supportMedia =
      root.appendingPathComponent(
        ".lab/windows-graphics-diagnostics-20261013/macopenvm-graphics-check-v7.iso"
      ).path
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
        for: oldProtocolCarrier, projectRoot: root)
    }
    var foreign = configuration
    foreign.supportMedia = "/private/tmp/foreign-driver-disc.iso"
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.acceleratedDisplayEvaluation(for: foreign, projectRoot: root)
    }
  }
}
