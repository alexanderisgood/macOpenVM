// SPDX-License-Identifier: Apache-2.0
// SOURCE ONLY / UNRUN: values, argument plans and isolated negative file reads.
import BackendAPI
import CryptoKit
import Foundation
import Testing

@testable import Qemu

@Suite @MainActor struct QemuCaptureToolsMediaTests {
  private let project = URL(fileURLWithPath: "/private/tmp/pure-tools-catalog,readonly=off λ")

  private func configuration(shared: Bool = true, attachV8: Bool = true) throws -> VMConfiguration {
    var c = VMConfiguration(
      name: "Pure capture tools plan", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    c.network = shared ? .shared : .disconnected
    if attachV8 {
      c.supportMedia = try QemuRegisteredCatalog.acceleratedDisplaySupportImage(
        projectRoot: project
      ).url.path
    }
    return c
  }
  private func selected() throws -> ReviewedQemuLaunchResources {
    try QemuRegisteredCatalog.producerCaptureEvaluation(for: configuration(), projectRoot: project)
  }
  private func display() throws -> ReviewedQemuAcceleratedDisplay {
    try ReviewedQemuAcceleratedDisplay(
      initialPixels: PixelSize(width: 3456, height: 2168),
      separateFirmware: true, hostWindow: .fourGiB, refreshRate: .hz120)
  }
  /// Deliberate value mutations only; never verifies or launches these fake paths.
  private func copy(_ original: ReviewedQemuLaunchResources, change: String = "none") throws
    -> ReviewedQemuLaunchResources
  {
    var runtime: ReviewedQemuResource? = original.runtimeQemu
    var server = original.renderServer
    var shared = original.sharedFrameTransport
    var channel = original.agentChannel
    var twoD = original.displayEvaluation
    var tools = original.extraReadOnlyTools
    switch change {
    case "runtime-hash":
      runtime = .init(
        role: .qemu, url: original.runtimeQemu.url,
        byteCount: original.runtimeQemu.byteCount, sha256: String(repeating: "0", count: 64))
    case "runtime-size":
      runtime = .init(
        role: .qemu, url: original.runtimeQemu.url,
        byteCount: original.runtimeQemu.byteCount + 1, sha256: original.runtimeQemu.sha256)
    case "no-runtime": runtime = nil
    case "no-render-server": server = nil
    case "no-shared-frames": shared = false
    case "agent-channel": channel = .virtioSerialV1
    case "two-dimensional":
      twoD = try ReviewedQemu2DDisplay(initialPixels: PixelSize(width: 800, height: 600))
    case "no-tools": tools = nil
    default: break
    }
    return try ReviewedQemuLaunchResources(
      creation: original.creation, libraries: original.libraries,
      qemuImports: original.qemuImports, swtpmImports: original.swtpmImports,
      systemImports: original.systemImports, runtimeQemu: runtime,
      supportsShared: original.supportsShared, supportImage: original.supportImage,
      agentChannel: channel, displayEvaluation: twoD,
      acceleratedDisplay: original.acceleratedDisplay,
      renderServer: server, keyboardMap: original.keyboardMap,
      sharedFrameTransport: shared, audioOutput: original.audioOutput, extraReadOnlyTools: tools)
  }

  @Test(arguments: [false, true], [false, true])
  func captureCatalogAddsOnlyTheClosedAdoptedSecondDisc(shared: Bool, attachV8: Bool) throws {
    let c = try configuration(shared: shared, attachV8: attachV8)
    let previous = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: c, projectRoot: project)
    let chosen = try QemuRegisteredCatalog.producerCaptureEvaluation(for: c, projectRoot: project)
    let tools = try #require(chosen.extraReadOnlyTools)
    #expect(
      tools.image.url
        == project.appendingPathComponent(
          ".lab/manager-iteration-20261016/root-native-d3d11-presenter-r4-carrier1/macopenvm-native-d3d11-presenter.iso"
        ))
    #expect(tools.image.byteCount == 921_600)
    #expect(
      tools.image.sha256 == "5ebea3828ff3797375547f05bec5e25bb7897289b37997c1ccd169c67ebf22aa")
    #expect(chosen.creation == previous.creation && chosen.libraries == previous.libraries)
    #expect(
      chosen.qemuImports == previous.qemuImports && chosen.swtpmImports == previous.swtpmImports)
    #expect(
      chosen.systemImports == previous.systemImports
        && chosen.supportsShared == previous.supportsShared)
    #expect(
      chosen.supportImage == previous.supportImage
        && chosen.supportImage?.url.path == c.supportMedia)
    #expect(
      chosen.agentChannel == previous.agentChannel
        && chosen.displayEvaluation == previous.displayEvaluation)
    #expect(
      chosen.acceleratedDisplay == previous.acceleratedDisplay
        && chosen.renderServer == previous.renderServer)
    #expect(
      chosen.keyboardMap == previous.keyboardMap
        && chosen.sharedFrameTransport == previous.sharedFrameTransport)
    #expect(chosen.audioOutput == previous.audioOutput)
  }

  @Test(arguments: [false, true])
  func ordinaryProfilesKeepNilToolsAndTheirExistingDefaults(shared: Bool) throws {
    let c = try configuration(shared: shared, attachV8: false)
    let ordinary = try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: project)
    let accelerated = try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
      for: c, projectRoot: project)
    #expect(ordinary.extraReadOnlyTools == nil && accelerated.extraReadOnlyTools == nil)
    let selected = try self.selected()
    let plain = try copy(selected, change: "no-tools")
    #expect(plain.extraReadOnlyTools == nil)
    #expect(
      try plain.selectingWorkerDevices(acceleratedDisplay: display()).extraReadOnlyTools == nil)
  }

  @Test(arguments: [
    "runtime-hash", "runtime-size", "no-runtime", "no-render-server",
    "no-shared-frames", "agent-channel", "two-dimensional",
  ])
  func extraDiscRefusesAnyOtherRuntimeOrDeviceGraph(change: String) throws {
    let chosen = try selected()
    #expect(try copy(chosen) == chosen)
    #expect(throws: VMError.self) { try copy(chosen, change: change) }
  }

  @Test func actualWorkerValueCopyRetainsBothCarriersAndEveryReviewedLoaderField() throws {
    let before = try selected()
    let display = try self.display()
    let after = try before.selectingWorkerDevices(
      acceleratedDisplay: display, producerCapture: .boundedProducerV1)
    #expect(
      after.extraReadOnlyTools == before.extraReadOnlyTools && after.extraReadOnlyTools != nil)
    #expect(after.supportImage == before.supportImage && after.supportImage != nil)
    #expect(after.creation == before.creation && after.runtimeQemu == before.runtimeQemu)
    #expect(after.libraries == before.libraries && after.qemuImports == before.qemuImports)
    #expect(
      after.swtpmImports == before.swtpmImports && after.systemImports == before.systemImports)
    #expect(
      after.supportsShared == before.supportsShared && after.renderServer == before.renderServer)
    #expect(
      after.keyboardMap == before.keyboardMap
        && after.sharedFrameTransport == before.sharedFrameTransport)
    #expect(after.audioOutput == before.audioOutput && after.acceleratedDisplay == display)
    #expect(after.agentChannel == nil && after.displayEvaluation == nil)
  }

  @Test func workerSelectionRefusesToolsWithoutCaptureOrAcceleratedDisplay() throws {
    let chosen = try selected()
    let accelerated = try display()
    #expect(throws: VMError.self) {
      try chosen.selectingWorkerDevices(acceleratedDisplay: accelerated)
    }
    #expect(throws: VMError.self) {
      try chosen.selectingWorkerDevices(producerCapture: .boundedProducerV1)
    }
    #expect(throws: VMError.self) {
      try chosen.selectingWorkerDevices(
        agentChannel: .virtioSerialV1,
        acceleratedDisplay: accelerated, producerCapture: .boundedProducerV1)
    }
    #expect(throws: VMError.self) {
      try chosen.selectingWorkerDevices(
        displayEvaluation: ReviewedQemu2DDisplay(initialPixels: PixelSize(width: 800, height: 600)),
        acceleratedDisplay: accelerated, producerCapture: .boundedProducerV1)
    }
    let withoutTools = try copy(chosen, change: "no-tools")
    #expect(throws: VMError.self) {
      try withoutTools.selectingWorkerDevices(
        acceleratedDisplay: accelerated, producerCapture: .boundedProducerV1)
    }
  }

  @Test func planAppendsOnlyReadOnlyUnbootindexedToolsSuffixAndPreservesV8() throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/mvo-tools-plan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let vm = root.appendingPathComponent("VM")
    let sockets = root.appendingPathComponent("sockets")
    for path in [vm, sockets] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    let endpoints = try QemuRegisteredEndpoints(directory: sockets)
    var c = try configuration()
    c.installationMedia = "/private/tmp/installer,media=disk.iso"
    let initial = try selected()
    let baseline = try copy(initial, change: "no-tools").selectingWorkerDevices(
      acceleratedDisplay: display())
    let selected = try initial.selectingWorkerDevices(
      acceleratedDisplay: display(), producerCapture: .boundedProducerV1)
    let before = try QemuRegisteredPlan.arguments(
      configuration: c, directory: vm, resources: baseline, endpoints: endpoints)
    let after = try QemuRegisteredPlan.arguments(
      configuration: c, directory: vm, resources: selected, endpoints: endpoints)
    let tools = try #require(selected.extraReadOnlyTools)
    let suffix = [
      "-drive",
      "if=none,id=capturetools,format=raw,media=cdrom,readonly=on,file=\(QemuPlan.escape(tools.image.url.path))",
      "-device", "usb-storage,id=capture-tools0,drive=capturetools,bus=xhci0.0",
    ]
    #expect(after.0 == before.0 + suffix && after.1 == before.1)
    #expect(after.0.filter { $0.hasPrefix("if=none,id=capturetools,") }.count == 1)
    let support = try #require(c.supportMedia)
    #expect(
      after.0.contains(
        "if=none,id=support,format=raw,media=cdrom,readonly=on,file=\(QemuPlan.escape(support))"))
    #expect(after.0.contains("usb-storage,drive=support,bus=xhci0.0"))
    #expect(
      after.0.contains(
        "if=none,id=installer,format=raw,media=cdrom,readonly=on,file=/private/tmp/installer,,media=disk.iso"
      ))
    #expect(!suffix.joined().contains("bootindex") && !suffix.joined().contains("readonly=off,"))
    #expect(suffix[1].contains("catalog,,readonly=off λ"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: vm.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: sockets.path).isEmpty)
  }

  @Test(arguments: ["missing", "wrong-size", "wrong-hash"])
  func missingOrChangedToolsImageFailsItsActualPinnedReader(kind: String) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/mvo-tools-read-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try ReviewedQemuCaptureTools.nativePresenterR4(projectRoot: root)
    try FileManager.default.createDirectory(
      at: tools.image.url.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if kind != "missing" {
      let bytes = Data(
        repeating: 0x41, count: kind == "wrong-size" ? 512 : Int(tools.image.byteCount))
      try bytes.write(to: tools.image.url)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: tools.image.url.path)
      if kind == "wrong-size" {
        #expect(UInt64(bytes.count) != tools.image.byteCount)
      } else {
        #expect(UInt64(bytes.count) == tools.image.byteCount)
        #expect(
          SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() != tools.image.sha256
        )
      }
    } else {
      #expect(!FileManager.default.fileExists(atPath: tools.image.url.path))
    }
    #expect(throws: VMError.self) { try tools.image.verify() }
  }
}
