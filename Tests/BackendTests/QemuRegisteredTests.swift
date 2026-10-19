// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Testing
import VMStorage

@testable import Qemu

// Parser/file admission does not allocate guest CPUs or depend on CI core count.
private let registeredTestHost = HostResources(cpuCount: 8, memoryBytes: 16 << 30)

private func registeredTestHash(_ bytes: Data) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
/// Synthetic public Mach-O headers are parser vectors, never executable code or health evidence.
private func registeredMachO(executable: Bool, imports: [String] = [], minimum: UInt32 = 27 << 16)
  -> Data
{
  func word(_ value: UInt32) -> Data {
    var v = value.littleEndian
    return withUnsafeBytes(of: &v) { Data($0) }
  }
  var commands = word(0x32) + word(24) + word(1) + word(minimum) + word(27 << 16) + word(0)
  for path in imports {
    var text = Data(path.utf8) + Data([0])
    while text.count % 4 != 0 { text.append(0) }
    commands +=
      word(0xc) + word(UInt32(24 + text.count)) + word(24) + word(0) + word(0) + word(0) + text
  }
  return word(0xfeed_facf) + word(0x0100_000c) + word(0) + word(executable ? 2 : 6)
    + word(UInt32(imports.count + 1)) + word(UInt32(commands.count)) + word(0) + word(0) + commands
}
private struct RegisteredFixture {
  let root: URL
  let vm: URL
  let sockets: URL
  let resources: ReviewedQemuLaunchResources
  var configuration: VMConfiguration
  init() throws {
    root = URL(fileURLWithPath: "/private/tmp/mvo-reg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    vm = root.appendingPathComponent("VM space λ")
    sockets = root.appendingPathComponent("sockets")
    for path in [vm, sockets] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let library = root.appendingPathComponent("public-library")
    let libraryBytes = registeredMachO(executable: false)
    try libraryBytes.write(to: library)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: library.path)
    var rows: [ReviewedQemuResource] = []
    for role in QemuCreationResourceRole.allCases {
      let path = root.appendingPathComponent(
        role == .firmware ? "firmware,readonly=off.fd" : role.rawValue)
      let bytes =
        role == .qemu || role == .swtpm
        ? registeredMachO(executable: true, imports: [library.path])
        : Data("Public file-only marker".utf8)
      try bytes.write(to: path)
      try FileManager.default.setAttributes(
        [.posixPermissions: role == .qemu || role == .swtpm ? 0o700 : 0o600],
        ofItemAtPath: path.path)
      rows.append(
        .init(
          role: role, url: path, byteCount: UInt64(bytes.count), sha256: registeredTestHash(bytes)))
    }
    resources = try ReviewedQemuLaunchResources(
      creation: ReviewedQemuCreationResources(resources: rows),
      libraries: [
        .init(
          url: library, byteCount: UInt64(libraryBytes.count),
          sha256: registeredTestHash(libraryBytes), importPaths: [library.path], dependencies: [])
      ],
      qemuImports: [library.path], swtpmImports: [library.path],
      systemImports: ["/usr/lib/libSystem.B.dylib"])
    var c = VMConfiguration(
      name: "Registered parser fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    c.diskFile = "disk,readonly=on.raw"
    let media = root.appendingPathComponent("installer,media=disk.iso")
    try Data("Public image marker".utf8).write(to: media)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: media.path)
    c.installationMedia = media.path
    configuration = c
  }
  /// Synthetic extra executable/import graph only; no code is launched and no NAT backend exists.
  func sharedResources(supportsShared: Bool = true) throws -> ReviewedQemuLaunchResources {
    let library = root.appendingPathComponent("synthetic-slirp.dylib")
    let libraryBytes = registeredMachO(executable: false, imports: ["/usr/lib/libSystem.B.dylib"])
    try libraryBytes.write(to: library)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: library.path)
    let selected = root.appendingPathComponent("synthetic-runtime-qemu")
    let imports = resources.qemuImports + [library.path]
    let bytes = registeredMachO(executable: true, imports: imports)
    try bytes.write(to: selected)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selected.path)
    return try ReviewedQemuLaunchResources(
      creation: resources.creation,
      libraries: resources.libraries + [
        .init(
          url: library, byteCount: UInt64(libraryBytes.count),
          sha256: registeredTestHash(libraryBytes), importPaths: [library.path],
          dependencies: ["/usr/lib/libSystem.B.dylib"])
      ],
      qemuImports: imports, swtpmImports: resources.swtpmImports,
      systemImports: resources.systemImports,
      runtimeQemu: .init(
        role: .qemu, url: selected, byteCount: UInt64(bytes.count),
        sha256: registeredTestHash(bytes)),
      supportsShared: supportsShared)
  }
  func supportImage() throws -> ReviewedQemuSupportImage {
    let url = root.appendingPathComponent("public-carrier,cache=unsafe λ.iso")
    let bytes = Data(repeating: 0x35, count: 1024)
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return try ReviewedQemuSupportImage(
      url: url, byteCount: UInt64(bytes.count), sha256: registeredTestHash(bytes))
  }
  func withSupport(
    _ image: ReviewedQemuSupportImage,
    base: ReviewedQemuLaunchResources? = nil
  ) throws -> ReviewedQemuLaunchResources {
    let selected = base ?? resources
    return try ReviewedQemuLaunchResources(
      creation: selected.creation, libraries: selected.libraries,
      qemuImports: selected.qemuImports, swtpmImports: selected.swtpmImports,
      systemImports: selected.systemImports, runtimeQemu: selected.runtimeQemu,
      supportsShared: selected.supportsShared, supportImage: image)
  }
  func withAgent(base: ReviewedQemuLaunchResources? = nil) throws -> ReviewedQemuLaunchResources {
    let selected = base ?? resources
    return try ReviewedQemuLaunchResources(
      creation: selected.creation, libraries: selected.libraries,
      qemuImports: selected.qemuImports, swtpmImports: selected.swtpmImports,
      systemImports: selected.systemImports, runtimeQemu: selected.runtimeQemu,
      supportsShared: selected.supportsShared, supportImage: selected.supportImage,
      agentChannel: .virtioSerialV1)
  }
  func close() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct QemuRegisteredTests {
  @Test func playbackRequiresReviewedRuntimeAndExposesNoCaptureDevice() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let r = f.resources
    let framework = "/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio"
    for (runtime, imports) in [
      (Optional<ReviewedQemuResource>.none, r.qemuImports + [framework]),
      (Optional(r.runtimeQemu), r.qemuImports),
    ] {
      #expect(throws: VMError.self) {
        try ReviewedQemuLaunchResources(
          creation: r.creation, libraries: r.libraries, qemuImports: imports,
          swtpmImports: r.swtpmImports, systemImports: r.systemImports.union([framework]),
          runtimeQemu: runtime, audioOutput: .coreAudioHDAV1)
      }
    }
    let selected = try ReviewedQemuLaunchResources(
      creation: r.creation, libraries: r.libraries, qemuImports: r.qemuImports + [framework],
      swtpmImports: r.swtpmImports, systemImports: r.systemImports.union([framework]),
      runtimeQemu: r.runtimeQemu, audioOutput: .coreAudioHDAV1)
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let original = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: r, endpoints: endpoints)
    let playback = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: selected, endpoints: endpoints)
    #expect(r.audioOutput == nil)
    #expect(
      playback.0 == original.0 + [
        "-audiodev",
        "coreaudio,id=audio0,in.voices=0,out.voices=1,out.fixed-settings=on,out.frequency=48000,out.channels=2,out.buffer-length=10000,out.buffer-count=4",
        "-device", "intel-hda,id=audio-controller0",
        "-device", "hda-output,id=audio-codec0,bus=audio-controller0.0,audiodev=audio0",
      ])
    #expect(playback.1 == original.1 && selected.creation == r.creation)
    // A forged framework description still fails byte/import verification.
    #expect(throws: VMError.self) { try selected.verify(hostMajor: 27, signature: { _, _ in }) }
  }

  @Test func explicitKeyboardMapChangesOnlyRuntimeArgumentAndRechecksPinnedBytes() throws {
    let f = try RegisteredFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let mapURL = f.root.appendingPathComponent("public-uk-keymap")
    let bytes = Data("quotedbl 0x03 shift\nbackslash 0x56\n".utf8)
    try bytes.write(to: mapURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
    let map = ReviewedQemuResource(
      role: .enUsKeymap, url: mapURL, byteCount: UInt64(bytes.count),
      sha256: registeredTestHash(bytes))
    let selected = try ReviewedQemuLaunchResources(
      creation: f.resources.creation, libraries: f.resources.libraries,
      qemuImports: f.resources.qemuImports, swtpmImports: f.resources.swtpmImports,
      systemImports: f.resources.systemImports, keyboardMap: map)
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let original = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: f.resources, endpoints: endpoints)
    let changed = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: selected, endpoints: endpoints)
    let index = try #require(original.0.firstIndex(of: "-k"))
    var expected = original.0
    expected[index + 1] = mapURL.path
    #expect(changed.0 == expected && changed.1 == original.1)
    #expect(selected.creation == f.resources.creation)
    try selected.verify(hostMajor: 27, signature: { _, _ in })
    #expect(throws: VMError.self) {
      try selected.verify(
        hostMajor: 27,
        signature: { _, _ in
          try Data(repeating: 0, count: bytes.count).write(to: mapURL)
        })
    }
    #expect(throws: VMError.self) {
      try ReviewedQemuLaunchResources(
        creation: f.resources.creation, libraries: f.resources.libraries,
        qemuImports: f.resources.qemuImports, swtpmImports: f.resources.swtpmImports,
        systemImports: f.resources.systemImports,
        keyboardMap: f.resources.creation.resource(.firmware))
    }
  }

  @Test func acceleratedDisplayUsesOneConsoleWithoutChangingFirmwareTPMOrNetworking() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let r = f.resources
    let before = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: r, endpoints: endpoints)
    #expect(before.0.contains("usb-mouse,id=relative-pointer0,bus=xhci0.0"))
    #expect(before.0.contains("usb-tablet,id=pointer0,bus=xhci0.0"))
    let pixels = PixelSize(width: 3456, height: 2064)
    let display = try ReviewedQemuAcceleratedDisplay(initialPixels: pixels)
    let server = ReviewedQemuRenderServer(
      url: r.runtimeQemu.url, byteCount: r.runtimeQemu.byteCount,
      sha256: r.runtimeQemu.sha256, imports: r.qemuImports)
    #expect(throws: VMError.self) {
      try ReviewedQemuLaunchResources(
        creation: r.creation, libraries: r.libraries, qemuImports: r.qemuImports,
        swtpmImports: r.swtpmImports, systemImports: r.systemImports,
        acceleratedDisplay: display)
    }
    let resources = try ReviewedQemuLaunchResources(
      creation: r.creation, libraries: r.libraries, qemuImports: r.qemuImports,
      swtpmImports: r.swtpmImports, systemImports: r.systemImports,
      acceleratedDisplay: display, renderServer: server)
    let after = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: resources, endpoints: endpoints)
    var expected = before.0
    expected[try #require(expected.firstIndex(of: "-vnc")) + 1] += ",active-refresh-ms=200"
    expected[try #require(expected.firstIndex(of: "ramfb,id=display0"))] =
      "virtio-ramfb-gl,id=display0,disable-legacy=on,disable-modern=off,neptune=on,blob=on,hostmem=1G,edid=on,edid-refresh-rate=60000,edid-4k=on,max_outputs=1,xres=3456,yres=2064,romfile="
    expected[try #require(expected.firstIndex(of: "-display")) + 1] =
      "egl-headless,gl=es,damage-readback=on"
    expected[try #require(expected.firstIndex(of: "-accel")) + 1] = "hvf,ipa-granule=4k"
    #expect(after.0 == expected && after.1 == before.1)
    #expect(!after.0.contains("ramfb,id=display0"))
    let separated = try ReviewedQemuLaunchResources(
      creation: r.creation, libraries: r.libraries, qemuImports: r.qemuImports,
      swtpmImports: r.swtpmImports, systemImports: r.systemImports,
      acceleratedDisplay: ReviewedQemuAcceleratedDisplay(
        initialPixels: pixels, separateFirmware: true, hostWindow: .fourGiB),
      renderServer: server)
    let separatedPlan = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: separated, endpoints: endpoints)
    var diagnostic = before.0
    diagnostic[try #require(diagnostic.firstIndex(of: "-vnc")) + 1] += ",active-refresh-ms=200"
    diagnostic[try #require(diagnostic.firstIndex(of: "-display")) + 1] =
      "egl-headless,gl=es,damage-readback=on"
    diagnostic[try #require(diagnostic.firstIndex(of: "-accel")) + 1] = "hvf,ipa-granule=4k"
    diagnostic += [
      "-device",
      "virtio-gpu-gl-pci,id=display1,disable-legacy=on,disable-modern=off,neptune=on,blob=on,hostmem=4G,edid=on,edid-refresh-rate=60000,edid-4k=on,max_outputs=1,xres=3456,yres=2064,romfile=",
    ]
    #expect(separatedPlan.0 == diagnostic && separatedPlan.1 == before.1)
    #expect(separatedPlan.0.contains("ramfb,id=display0"))
    #expect(display.hostWindow == .oneGiB)
    #expect(display.refreshRate == .hz60)
    #expect(ReviewedQemuAcceleratedDisplay.HostWindow(rawValue: "3G") == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path).isEmpty)
    #expect(throws: VMError.self) {
      try ReviewedQemuLaunchResources(
        creation: r.creation, libraries: r.libraries, qemuImports: r.qemuImports,
        swtpmImports: r.swtpmImports, systemImports: r.systemImports,
        displayEvaluation: ReviewedQemu2DDisplay(initialPixels: pixels),
        acceleratedDisplay: display, renderServer: server)
    }
  }
  @Test func highRefreshTrialChangesOnlyTheExplicitDisplayTiming() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let r = f.resources
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let server = ReviewedQemuRenderServer(
      url: r.runtimeQemu.url, byteCount: r.runtimeQemu.byteCount,
      sha256: r.runtimeQemu.sha256, imports: r.qemuImports)
    for separate in [false, true] {
      func resources(_ rate: ReviewedQemuAcceleratedDisplay.RefreshRate) throws
        -> ReviewedQemuLaunchResources
      {
        try ReviewedQemuLaunchResources(
          creation: r.creation, libraries: r.libraries, qemuImports: r.qemuImports,
          swtpmImports: r.swtpmImports, systemImports: r.systemImports,
          acceleratedDisplay: ReviewedQemuAcceleratedDisplay(
            initialPixels: PixelSize(width: 3456, height: 2168),
            separateFirmware: separate, hostWindow: .fourGiB, refreshRate: rate),
          renderServer: server)
      }
      let baseline = try QemuRegisteredPlan.arguments(
        configuration: f.configuration, directory: f.vm,
        resources: resources(.hz60), endpoints: endpoints)
      let trial = try QemuRegisteredPlan.arguments(
        configuration: f.configuration, directory: f.vm,
        resources: resources(.hz120), endpoints: endpoints)
      #expect(baseline.0.filter { $0.contains("edid-refresh-rate=60000") }.count == 1)
      #expect(trial.0.filter { $0.contains("edid-refresh-rate=120000") }.count == 1)
      #expect(
        trial.0
          == baseline.0.map {
            $0.replacingOccurrences(of: "edid-refresh-rate=60000", with: "edid-refresh-rate=120000")
          })
      #expect(trial.1 == baseline.1)
    }
    for raw in ["0", "119999", "240000", "nan", "120000,blob=off"] {
      #expect(ReviewedQemuAcceleratedDisplay.RefreshRate(rawValue: raw) == nil)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path).isEmpty)
  }
  @Test func displayEvaluationPreservesFirmwareAndRequiresBoundedPixels() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let before = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: f.resources, endpoints: endpoints)
    #expect(f.resources.displayEvaluation == nil)
    for pixels in [PixelSize(width: 1800, height: 1200), PixelSize(width: 3840, height: 2160)] {
      let display = try ReviewedQemu2DDisplay(initialPixels: pixels)
      let r = f.resources
      let resources = try ReviewedQemuLaunchResources(
        creation: r.creation, libraries: r.libraries, qemuImports: r.qemuImports,
        swtpmImports: r.swtpmImports, systemImports: r.systemImports,
        runtimeQemu: r.runtimeQemu, supportsShared: r.supportsShared,
        displayEvaluation: display)
      let after = try QemuRegisteredPlan.arguments(
        configuration: f.configuration, directory: f.vm, resources: resources, endpoints: endpoints)
      #expect(
        after.0 == before.0 + [
          "-device",
          "virtio-gpu-pci,id=display1,disable-legacy=on,disable-modern=off,edid=on,max_outputs=1,xres=\(pixels.width),yres=\(pixels.height),romfile=",
        ])
      #expect(after.1 == before.1 && after.0.contains("ramfb,id=display0"))
      #expect(resources.creation == r.creation && resources.runtimeQemu == r.runtimeQemu)
    }
    for pixels in [
      PixelSize(width: 0, height: 600), PixelSize(width: 800, height: -1),
      PixelSize(width: 8193, height: 600), PixelSize(width: 8192, height: 8192),
      PixelSize(width: Int.max, height: Int.max),
    ] {
      #expect(throws: VMError.self) { try ReviewedQemu2DDisplay(initialPixels: pixels) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path).isEmpty)
  }

  @Test func catalogSelectionUsesOnlyReviewedNetworkAndExactCarrierDescriptorsWithoutFiles() throws
  {
    let root = URL(
      fileURLWithPath: "/private/tmp/mvo-catalog-table-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var c = VMConfiguration(
      name: "Pure catalog table", guest: .windows11, backend: .qemuHVF,
      memoryBytes: 4 << 30, diskBytes: 64 << 30)
    let offline = try QemuRegisteredCatalog.offlineEvaluation(projectRoot: root)
    let first = try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    #expect(
      first == offline && !first.supportsShared && first.supportImage == nil
        && first.agentChannel == nil)
    c.network = .shared
    let shared = try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    #expect(shared == (try QemuRegisteredCatalog.sharedEvaluation(projectRoot: root)))
    #expect(
      shared.creation == offline.creation && shared.supportsShared && shared.supportImage == nil)
    #expect(
      shared.runtimeQemu.sha256
        == "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745")
    let carrier = try QemuRegisteredCatalog.networkDriverSupportImage(projectRoot: root)
    c.supportMedia = carrier.url.path
    let selected = try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    #expect(
      selected.supportImage == carrier && selected.runtimeQemu == shared.runtimeQemu
        && selected.agentChannel == nil)
    #expect(selected.creation == offline.creation && selected.libraries == shared.libraries)
    #expect(
      selected.supportImage?.sha256
        == "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394")
    for path in [
      carrier.url.path + "/", carrier.url.path + ",readonly=off", "/unreviewed/image.iso",
    ] {
      c.supportMedia = path
      #expect(throws: VMError.self) {
        try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
      }
    }
    c.supportMedia = nil
    let baseline = c
    c.guest = .linux
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    }
    c = baseline
    c.backend = .appleVz
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    }
    c = baseline
    c.architecture = .x8664
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    }
    c = baseline
    c.boot = .linuxKernel
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test(arguments: [false, true])
  func systemDiskForwardsGuestDiscardAndKeepsBootMediaReadOnly(shared: Bool) throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let base = shared ? try f.sharedResources() : f.resources
    let support = try f.supportImage()
    let resources = try f.withSupport(support, base: base)
    var configuration = f.configuration
    configuration.network = shared ? .shared : .disconnected
    configuration.supportMedia = support.url.path
    let arguments = try QemuRegisteredPlan.arguments(
      configuration: configuration, directory: f.vm, resources: resources, endpoints: endpoints).0
    let drives = arguments.indices.filter { arguments[$0] == "-drive" }.map { arguments[$0 + 1] }
    // A comma-bearing disk name stays literal while reclaim applies only to
    // the writable system disk. Firmware and both ISO carriers stay read-only.
    let system =
      "if=none,id=system,format=raw,cache=none,discard=unmap,file=\(f.vm.path)/disk,,readonly=on.raw"
    #expect(drives.count == 4)
    #expect(drives.filter { $0.hasPrefix("if=none,id=system,") } == [system])
    #expect(drives.filter { $0.contains(",discard=") } == [system])
    #expect(drives.filter { $0 != system }.allSatisfy { $0.contains(",readonly=on,") })
    #expect(!arguments.contains { $0.contains("detect-zeroes=") })
    #expect(!arguments.contains("-snapshot"))
  }

  @Test func configurationProducesOfflineArgumentsWithLiteralCommaSpaceAndUnicodePaths() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let first = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: f.resources.creation,
      endpoints: endpoints)
    #expect(
      first.0.contains(
        "if=none,id=system,format=raw,cache=none,discard=unmap,file=\(f.vm.path)/disk,,readonly=on.raw"))
    #expect(first.0.contains("none") && !first.0.contains("-netdev"))
    #expect(first.0.contains(where: { $0.contains("file=\(f.vm.path)/disk,,readonly=on.raw") }))
    #expect(first.0.contains(where: { $0.contains("firmware,,readonly=off.fd") }))
    #expect(first.0.contains(where: { $0.contains("installer,,media=disk.iso") }))
    #expect(first.1.contains("dir=\(f.vm.path)/tpm-state,mode=0600,lock"))
    var c = f.configuration
    c.cpuCount = 3
    c.memoryBytes = 6 << 30
    let second = try QemuRegisteredPlan.arguments(
      configuration: c, directory: f.vm, resources: f.resources.creation, endpoints: endpoints)
    let smp = try #require(second.0.firstIndex(of: "-smp"))
    let memory = try #require(second.0.firstIndex(of: "-m"))
    #expect(second.0[smp + 1] == "3")
    #expect(second.0[memory + 1] == "6144")
    #expect(
      second.1 == first.1 && c.id == f.configuration.id
        && c.macAddress == f.configuration.macAddress)
    let serial = try #require(first.0.first(where: { $0.hasPrefix("nvme,drive=system,serial=") }))
    #expect(serial.dropFirst("nvme,drive=system,serial=".count).utf8.count == 20)
    #expect(second.0.contains(serial))
    c.memoryBytes += 1
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: c, directory: f.vm, resources: f.resources.creation, endpoints: endpoints)
    }
    c.memoryBytes -= 1
    c.network = .shared
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: c, directory: f.vm, resources: f.resources.creation, endpoints: endpoints)
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: f.configuration, directory: f.root.appendingPathComponent("VM,comma"),
        resources: f.resources.creation, endpoints: endpoints)
    }
  }

  @Test func agentRecipeRequiresBothExplicitSelectionsAndPreservesEveryExistingArgument() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let ordinary = try QemuRegisteredEndpoints(directory: f.sockets)
    let selected = try QemuRegisteredEndpoints(directory: f.sockets, agentChannel: .virtioSerialV1)
    let resources = try f.withAgent()
    #expect(f.resources.agentChannel == nil && ordinary.agentSocket == nil)
    let before = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: f.resources,
      endpoints: ordinary)
    let creationOnly = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: f.resources.creation,
      endpoints: ordinary)
    #expect(before.0 == creationOnly.0 && before.1 == creationOnly.1)
    #expect(!before.0.contains { $0.contains("agentchr0") || $0.contains("virtio-serial") })
    let after = try QemuRegisteredPlan.arguments(
      configuration: f.configuration, directory: f.vm, resources: resources, endpoints: selected)
    let expected = [
      "-device",
      "virtio-serial-pci,id=agentserial0,disable-legacy=on,disable-modern=off,max_ports=2",
      "-chardev", "socket,id=agentchr0,path=\(f.sockets.path)/agent.sock,server=on,wait=off",
      "-device",
      "virtserialport,id=agentport0,bus=agentserial0.0,nr=1,chardev=agentchr0,name=org.macopenvm.agent.v1",
    ]
    #expect(after.0 == before.0 + expected && after.1 == before.1)
    #expect(resources.creation == f.resources.creation)
    #expect(resources.runtimeQemu == f.resources.runtimeQemu)
    #expect(resources.libraries == f.resources.libraries)
    #expect(selected.agentSocket?.path == f.sockets.path + "/agent.sock")
    for (r, e) in [(f.resources, selected), (resources, ordinary)] {
      #expect(throws: VMError.self) {
        try QemuRegisteredPlan.arguments(
          configuration: f.configuration, directory: f.vm, resources: r, endpoints: e)
      }
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: f.configuration, directory: f.vm, resources: f.resources.creation,
        endpoints: selected)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path).isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.vm.appendingPathComponent("runtime-intent.json").path))
  }

  @Test func agentRecipeIsIndependentOfNicAndLeavesSharedAndCarrierArgumentsIntact() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let ordinary = try QemuRegisteredEndpoints(directory: f.sockets)
    let selected = try QemuRegisteredEndpoints(directory: f.sockets, agentChannel: .virtioSerialV1)
    let carrier = try f.supportImage()
    let base = try f.withSupport(carrier, base: f.sharedResources())
    let agent = try f.withAgent(base: base)
    var c = f.configuration
    c.network = .shared
    c.supportMedia = carrier.url.path
    let before = try QemuRegisteredPlan.arguments(
      configuration: c, directory: f.vm, resources: base, endpoints: ordinary)
    let after = try QemuRegisteredPlan.arguments(
      configuration: c, directory: f.vm, resources: agent, endpoints: selected)
    #expect(Array(after.0.prefix(before.0.count)) == before.0 && after.1 == before.1)
    #expect(after.0.count == before.0.count + 6)
    #expect(after.0.filter { $0.hasPrefix("virtio-serial-pci,") }.count == 1)
    #expect(after.0.filter { $0.hasPrefix("virtserialport,") }.count == 1)
    #expect(after.0.filter { $0.hasPrefix("socket,id=agentchr0,") }.count == 1)
    #expect(
      !after.0.suffix(6).contains {
        $0.contains("tls-creds") || $0.contains("host=") || $0.contains("port=")
          || $0.contains("mux=") || $0.contains("telnet=") || $0.contains("websocket=")
      })
    #expect(c.id == f.configuration.id && c.macAddress == f.configuration.macAddress)
    #expect(
      try QemuPlatformIdentityCodec.encode(for: c, resources: agent.creation)
        == QemuPlatformIdentityCodec.encode(for: f.configuration, resources: f.resources.creation))
  }

  @Test func selectedAgentEndpointRejectsExistingRegularAndIndirectNamesWithoutRemovingThem()
    throws
  {
    let f = try RegisteredFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets, agentChannel: .virtioSerialV1)
    let socket = try #require(endpoints.agentSocket)
    try endpoints.requireChildSocketsAbsent()
    let marker = Data("Preserve existing agent endpoint".utf8)
    try marker.write(to: socket)
    #expect(throws: VMError.self) { try endpoints.requireChildSocketsAbsent() }
    #expect(try Data(contentsOf: socket) == marker)
    // Only this fixture's regular marker is removed to construct its next case.
    try FileManager.default.removeItem(at: socket)
    let target = f.root.appendingPathComponent("preserved-agent-target")
    try marker.write(to: target)
    try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: target)
    #expect(throws: VMError.self) { try endpoints.requireChildSocketsAbsent() }
    #expect(try Data(contentsOf: target) == marker)
    let moved = f.root.appendingPathComponent("preserved-agent-parent")
    try FileManager.default.moveItem(at: f.sockets, to: moved)
    try FileManager.default.createDirectory(
      at: f.sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(throws: VMError.self) { try endpoints.requireChildSocketsAbsent() }
    #expect(try Data(contentsOf: target) == marker)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path).isEmpty)
  }

  @Test func sharedArgumentsRequireExplicitCapabilityAndUseOnlyPersistentCanonicalMac() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let shared = try f.sharedResources()
    let originalIdentity = try QemuPlatformIdentityCodec.encode(
      for: f.configuration, resources: f.resources.creation)
    var c = f.configuration
    c.network = .shared
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: c, directory: f.vm, resources: f.resources, endpoints: endpoints)
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: c, directory: f.vm, resources: f.resources.creation, endpoints: endpoints)
    }
    let first = try QemuRegisteredPlan.arguments(
      configuration: c, directory: f.vm, resources: shared, endpoints: endpoints)
    let expectedNetwork =
      "user,id=net0,ipv4=on,ipv6=off,restrict=off,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15"
    let expectedNic =
      "virtio-net-pci,id=nic0,netdev=net0,disable-legacy=on,disable-modern=off,mac=\(c.macAddress),romfile="
    #expect(first.0.filter { $0 == "-netdev" }.count == 1 && first.0.contains(expectedNetwork))
    #expect(first.0.filter { $0.hasPrefix("virtio-net-pci,") } == [expectedNic])
    #expect(!first.0.contains("-nic"))
    #expect(!first.0.contains("-L"))
    #expect(!first.0.contains { $0.contains("efi-virtio.rom") })
    #expect(
      !first.0.contains {
        $0.contains("hostfwd") || $0.contains("guestfwd") || $0.contains("smb=")
          || $0.contains("tftp=")
      })
    c.cpuCount = 3
    c.memoryBytes = 6 << 30
    let changed = try QemuRegisteredPlan.arguments(
      configuration: c, directory: f.vm, resources: shared, endpoints: endpoints)
    #expect(
      changed.0.contains(expectedNetwork) && changed.0.contains(expectedNic) && changed.1 == first.1
    )
    #expect(c.id == f.configuration.id && c.macAddress == f.configuration.macAddress)
    #expect(
      try QemuPlatformIdentityCodec.encode(for: c, resources: shared.creation) == originalIdentity)
    for invalid in [
      "02:01:02:03:04:05,hostfwd=tcp", "03:01:02:03:04:05", "00:01:02:03:04:05",
      "02:AA:02:03:04:05",
    ] {
      c.macAddress = invalid
      #expect(throws: VMError.self) {
        try QemuRegisteredPlan.arguments(
          configuration: c, directory: f.vm, resources: shared, endpoints: endpoints)
      }
    }
  }
  @Test func selectedRuntimeHasItsOwnImportSignatureAndFinalExecutableRecheck() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let shared = try f.sharedResources()
    #expect(shared.creation == f.resources.creation && shared.supportsShared)
    #expect(
      f.resources.runtimeQemu == (try f.resources.creation.resource(.qemu))
        && !f.resources.supportsShared)
    var signed: [(URL, Bool)] = []
    try shared.verify(hostMajor: 27) { signed.append(($0, $1)) }
    #expect(signed.contains { $0.0 == shared.runtimeQemu.url && $0.1 })
    #expect(!signed.contains { $0.0 == (try? f.resources.creation.resource(.qemu).url) })
    #expect(throws: VMError.self) {
      try ReviewedQemuLaunchResources(
        creation: f.resources.creation,
        libraries: f.resources.libraries, qemuImports: f.resources.qemuImports,
        swtpmImports: f.resources.swtpmImports, systemImports: f.resources.systemImports,
        supportsShared: true)
    }
    #expect(throws: VMError.self) {
      try RegisteredMachO.signature(shared.runtimeQemu.url, hypervisor: true)
    }
    var changed = try Data(contentsOf: shared.runtimeQemu.url)
    changed[0] ^= 1
    var replaced = false
    #expect(throws: VMError.self) {
      try shared.verify(hostMajor: 27) { url, _ in
        if url == shared.runtimeQemu.url {
          try changed.write(to: url)
          replaced = true
        }
      }
    }
    #expect(replaced)
    #expect(try Data(contentsOf: shared.runtimeQemu.url) == changed)
  }
  @MainActor @Test func sharedPlanKeepsCreationIdentityAndWritableStateUnderActualLease()
    async throws
  {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
    let f = try RegisteredFixture()
    defer { f.close() }
    let shared = try f.sharedResources()
    let files = VMFiles()
    var c = f.configuration
    c.network = .shared
    try await files.createSparseDisk(
      at: f.vm.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
    try await files.writeNewMetadata(Data(), at: f.vm.appendingPathComponent("uefi-vars.json"))
    try await files.createDirectory(f.vm.appendingPathComponent("tpm-state"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let config = try encoder.encode(c)
    let identity = try QemuPlatformIdentityCodec.encode(
      for: f.configuration, resources: f.resources.creation)
    try await files.writeNewMetadata(config, at: f.vm.appendingPathComponent("configuration.json"))
    try await files.writeNewMetadata(
      identity, at: f.vm.appendingPathComponent("qemu-platform.json"))
    let lock = try VMLock(directory: f.vm, expectedVMID: c.id)
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let names = try FileManager.default.contentsOfDirectory(atPath: f.vm.path).sorted()
    var before = stat()
    #expect(lstat(f.vm.appendingPathComponent(c.diskFile).path, &before) == 0)
    #expect(throws: VMError.self) {
      try QemuRegisteredAdmission.prepare(
        configuration: c, in: f.vm,
        platformIdentity: identity, resources: f.resources, endpoints: endpoints, lock: lock,
        host: registeredTestHost, verify: {})
    }
    let plan = try QemuRegisteredAdmission.prepare(
      configuration: c, in: f.vm, platformIdentity: identity,
      resources: shared, endpoints: endpoints, lock: lock, host: registeredTestHost, verify: {})
    #expect(plan.qemuExecutable == shared.runtimeQemu.url && plan.vmID == c.id)
    #expect(await files.writerStatus(in: f.vm) == .held)
    #expect(try Data(contentsOf: f.vm.appendingPathComponent("qemu-platform.json")) == identity)
    #expect(try Data(contentsOf: f.vm.appendingPathComponent("configuration.json")) == config)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.vm.path).sorted() == names)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path).isEmpty)
    var after = stat()
    #expect(lstat(f.vm.appendingPathComponent(c.diskFile).path, &after) == 0)
    #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino && after.st_blocks == 0)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.vm.appendingPathComponent("runtime-intent.json").path))
  }

  @Test func reviewedSupportIsOneReadonlyDriveWithoutBootIndexAndNeverImplicitlySelected() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let image = try f.supportImage()
    let selected = try f.withSupport(image)
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let original = try QemuRegisteredPlan.arguments(
      configuration: f.configuration,
      directory: f.vm, resources: f.resources, endpoints: endpoints)
    let unselected = try QemuRegisteredPlan.arguments(
      configuration: f.configuration,
      directory: f.vm, resources: selected, endpoints: endpoints)
    #expect(original.0 == unselected.0 && original.1 == unselected.1)
    var c = f.configuration
    c.supportMedia = image.url.path
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: c,
        directory: f.vm, resources: f.resources, endpoints: endpoints)
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: c,
        directory: f.vm, resources: f.resources.creation, endpoints: endpoints)
    }
    let supported = try QemuRegisteredPlan.arguments(
      configuration: c, directory: f.vm,
      resources: selected, endpoints: endpoints)
    #expect(Array(supported.0.dropLast(4)) == original.0 && supported.1 == original.1)
    #expect(
      Array(supported.0.suffix(4)) == [
        "-drive",
        "if=none,id=support,format=raw,media=cdrom,readonly=on,file=\(QemuPlan.escape(image.url.path))",
        "-device", "usb-storage,drive=support,bus=xhci0.0",
      ])
    #expect(supported.0.filter { $0.hasPrefix("usb-storage,drive=support,") }.count == 1)
    #expect(!(try #require(supported.0.last)).contains("bootindex"))
    #expect(
      c.id == f.configuration.id && c.macAddress == f.configuration.macAddress
        && c.diskFile == f.configuration.diskFile)
    #expect(
      try QemuPlatformIdentityCodec.encode(for: c, resources: selected.creation)
        == QemuPlatformIdentityCodec.encode(for: f.configuration, resources: f.resources.creation))
    c.supportMedia = f.root.appendingPathComponent("different.iso").path
    #expect(throws: VMError.self) {
      try QemuRegisteredPlan.arguments(
        configuration: c,
        directory: f.vm, resources: selected, endpoints: endpoints)
    }
  }
  @Test func reviewedSupportRejectsBoundsAliasesPermissionsAndChangedBytes() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let image = try f.supportImage()
    try image.verify()
    for size: UInt64 in [0, 513, 134_218_240] {
      #expect(throws: VMError.self) {
        try ReviewedQemuSupportImage(url: image.url, byteCount: size, sha256: image.sha256)
      }
    }
    let incorrect = try ReviewedQemuSupportImage(
      url: image.url, byteCount: image.byteCount, sha256: String(repeating: "0", count: 64))
    #expect(throws: VMError.self) { try incorrect.verify() }
    let alias = f.root.appendingPathComponent("carrier-alias.iso")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: image.url)
    let indirect = try ReviewedQemuSupportImage(
      url: alias, byteCount: image.byteCount, sha256: image.sha256)
    #expect(throws: VMError.self) { try indirect.verify() }
    let link = f.root.appendingPathComponent("carrier-hardlink.iso")
    try FileManager.default.linkItem(at: image.url, to: link)
    #expect(throws: VMError.self) { try image.verify() }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.setAttributes([.posixPermissions: 0o620], ofItemAtPath: image.url.path)
    #expect(throws: VMError.self) { try image.verify() }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.url.path)
    let resources = try f.withSupport(image)
    var altered = try Data(contentsOf: image.url)
    altered[0] ^= 1
    var injected = false
    #expect(throws: VMError.self) {
      try resources.verify(hostMajor: 27) { _, _ in
        if !injected {
          try altered.write(to: image.url)
          injected = true
        }
      }
    }
    #expect(injected)
    #expect(throws: VMError.self) { try image.verify() }
  }
  @MainActor @Test func supportAdmissionPreservesPlatformAndStateWithoutMintingPermit() async throws
  {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
    let f = try RegisteredFixture()
    defer { f.close() }
    let image = try f.supportImage()
    let resources = try f.withSupport(image)
    let files = VMFiles()
    var c = f.configuration
    c.supportMedia = image.url.path
    try await files.createSparseDisk(
      at: f.vm.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
    try await files.writeNewMetadata(Data(), at: f.vm.appendingPathComponent("uefi-vars.json"))
    try await files.createDirectory(f.vm.appendingPathComponent("tpm-state"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let config = try encoder.encode(c)
    let identity = try QemuPlatformIdentityCodec.encode(
      for: f.configuration, resources: f.resources.creation)
    try await files.writeNewMetadata(config, at: f.vm.appendingPathComponent("configuration.json"))
    try await files.writeNewMetadata(
      identity, at: f.vm.appendingPathComponent("qemu-platform.json"))
    let lock = try VMLock(directory: f.vm, expectedVMID: c.id)
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let stateNames = [c.diskFile, "uefi-vars.json", "tpm-state"]
    let before = try stateNames.map { name -> String in
      var info = stat()
      guard lstat(f.vm.appendingPathComponent(name).path, &info) == 0 else {
        throw registeredQemuFailure()
      }
      return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode)"
    }
    #expect(throws: VMError.self) {
      try QemuRegisteredAdmission.prepare(
        configuration: c,
        in: f.vm, platformIdentity: identity, resources: f.resources, endpoints: endpoints,
        lock: lock, host: registeredTestHost, verify: {})
    }
    _ = try QemuRegisteredAdmission.prepare(
      configuration: c, in: f.vm, platformIdentity: identity,
      resources: resources, endpoints: endpoints, lock: lock,
      host: registeredTestHost,
      verify: { try resources.verify(hostMajor: 27, signature: { _, _ in }) })
    let after = try stateNames.map { name -> String in
      var info = stat()
      guard lstat(f.vm.appendingPathComponent(name).path, &info) == 0 else {
        throw registeredQemuFailure()
      }
      return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode)"
    }
    #expect(before == after)
    #expect(try Data(contentsOf: f.vm.appendingPathComponent("configuration.json")) == config)
    #expect(try Data(contentsOf: f.vm.appendingPathComponent("qemu-platform.json")) == identity)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path).isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.vm.appendingPathComponent("runtime-intent.json").path))
  }

  @Test func endpointIdentitySurvivesCallerControlBindingButRefusesReplacementAndChildNames() throws
  {
    let f = try RegisteredFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    // A public marker proves that parent revalidation does not adopt/control its contents.
    try Data("Caller-owned control marker; never a socket".utf8).write(to: endpoints.controlSocket)
    try endpoints.revalidateParent()
    try endpoints.requireChildSocketsAbsent()
    try Data("foreign endpoint".utf8).write(to: endpoints.qmpSocket)
    #expect(throws: VMError.self) { try endpoints.requireChildSocketsAbsent() }
    let moved = f.root.appendingPathComponent("preserved-parent")
    try FileManager.default.moveItem(at: f.sockets, to: moved)
    try FileManager.default.createDirectory(
      at: f.sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(throws: VMError.self) { try endpoints.revalidateParent() }
    #expect(
      try Data(contentsOf: moved.appendingPathComponent("qmp.sock"))
        == Data("foreign endpoint".utf8))
  }

  @Test func publicMachOParserRejectsWrongArchitectureTypeBoundsRelativeImportsAndNewerHost() throws
  {
    let good = registeredMachO(executable: true, imports: ["/usr/lib/libSystem.B.dylib"])
    #expect(
      try RegisteredMachO.parse(good, executable: true, hostMajor: 27) == [
        "/usr/lib/libSystem.B.dylib"
      ])
    for bytes in [
      Data(good.prefix(31)), registeredMachO(executable: false),
      registeredMachO(executable: true, minimum: 28 << 16),
      registeredMachO(executable: true, imports: ["relative.dylib"]),
    ] {
      #expect(throws: VMError.self) {
        try RegisteredMachO.parse(bytes, executable: true, hostMajor: 27)
      }
    }
    var changed = good
    changed[4] = 7
    #expect(throws: VMError.self) {
      try RegisteredMachO.parse(changed, executable: true, hostMajor: 27)
    }
  }

  @Test func reviewedClosureChecksEveryFileImportAndActualSignatureRejection() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    var verified = 0
    try f.resources.verify(hostMajor: 27) { _, _ in verified += 1 }
    #expect(verified == 3)
    #expect(throws: VMError.self) {
      try f.resources.verify(hostMajor: 26) { _, _ in verified += 1 }
    }
    #expect(throws: VMError.self) {
      try RegisteredMachO.signature(try f.resources.creation.resource(.qemu).url, hypervisor: true)
    }
    let library = try #require(f.resources.libraries.first)
    var bytes = try Data(contentsOf: library.url)
    bytes[0] ^= 1
    try bytes.write(to: library.url)
    #expect(throws: VMError.self) { try f.resources.verify(hostMajor: 27) { _, _ in } }
  }

  @Test func signatureBoundaryReplacementCannotReturnVerifiedResourceInputs() throws {
    let f = try RegisteredFixture()
    defer { f.close() }
    let library = try #require(f.resources.libraries.first)
    let original = try Data(contentsOf: library.url)
    var changed = original
    changed[0] ^= 1
    var replaced = false
    #expect(throws: VMError.self) {
      try f.resources.verify(hostMajor: 27) { url, _ in
        if url == library.url {
          try changed.write(to: url)
          replaced = true
        }
      }
    }
    let actual = try Data(contentsOf: library.url)
    #expect(replaced && actual == changed)
  }

  @MainActor @Test func actualWriterAndRegisteredIdentityAreRequiredBeforeAnyPlanMutation()
    async throws
  {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
    let f = try RegisteredFixture()
    defer { f.close() }
    let files = VMFiles()
    let c = f.configuration
    try await files.createSparseDisk(
      at: f.vm.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
    try await files.writeNewMetadata(Data(), at: f.vm.appendingPathComponent("uefi-vars.json"))
    try await files.createDirectory(f.vm.appendingPathComponent("tpm-state"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let config = try encoder.encode(c)
    let identity = try QemuPlatformIdentityCodec.encode(for: c, resources: f.resources.creation)
    try await files.writeNewMetadata(config, at: f.vm.appendingPathComponent("configuration.json"))
    try await files.writeNewMetadata(
      identity, at: f.vm.appendingPathComponent(QemuPlatformIdentityCodec.filename))
    let lock = try VMLock(directory: f.vm, expectedVMID: c.id)
    let beforeValidation = try FileManager.default.contentsOfDirectory(atPath: f.vm.path).sorted()
    let endpointNames = try FileManager.default.contentsOfDirectory(atPath: f.sockets.path)
    try QemuRegisteredAdmission.validateStoredState(
      configuration: c, in: f.vm, platformIdentity: identity,
      resources: f.resources, lock: lock, host: registeredTestHost, verify: {})
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: f.vm.path).sorted() == beforeValidation)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.sockets.path) == endpointNames)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.vm.appendingPathComponent("runtime-intent.json").path))
    let endpoints = try QemuRegisteredEndpoints(directory: f.sockets)
    let names = try FileManager.default.contentsOfDirectory(atPath: f.vm.path).sorted()
    let plan = try QemuRegisteredAdmission.prepare(
      configuration: c, in: f.vm, platformIdentity: identity,
      resources: f.resources, endpoints: endpoints, lock: lock, host: registeredTestHost, verify: {}
    )
    let expectedExecutable = try f.resources.creation.resource(.qemu).url
    #expect(plan.vmID == c.id && plan.qemuExecutable == expectedExecutable)
    #expect(await files.writerStatus(in: f.vm) == .held)
    #expect(throws: VMError.self) { try VMLock(directory: f.vm, expectedVMID: c.id) }
    var wrong = c
    wrong.id = UUID()
    #expect(throws: (any Error).self) {
      try QemuRegisteredAdmission.prepare(
        configuration: wrong, in: f.vm, platformIdentity: identity,
        resources: f.resources, endpoints: endpoints, lock: lock, host: registeredTestHost,
        verify: {})
    }
    let different = f.root.appendingPathComponent("other-writer")
    try await files.createDirectory(different)
    let foreign = try VMLock(directory: different, expectedVMID: c.id)
    #expect(throws: VMError.self) {
      try QemuRegisteredAdmission.prepare(
        configuration: c, in: f.vm, platformIdentity: identity,
        resources: f.resources, endpoints: endpoints, lock: foreign, host: registeredTestHost,
        verify: {})
    }
    try FileManager.default.linkItem(
      at: f.vm.appendingPathComponent(c.diskFile), to: f.root.appendingPathComponent("disk-alias"))
    #expect(throws: VMError.self) {
      try QemuRegisteredAdmission.prepare(
        configuration: c, in: f.vm, platformIdentity: identity,
        resources: f.resources, endpoints: endpoints, lock: lock, host: registeredTestHost,
        verify: {})
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.vm.path).sorted() == names)
    #expect(try Data(contentsOf: f.vm.appendingPathComponent("configuration.json")) == config)
    #expect(
      try Data(contentsOf: f.vm.appendingPathComponent(QemuPlatformIdentityCodec.filename))
        == identity)
    withExtendedLifetime((lock, foreign, plan)) {}
  }
}
