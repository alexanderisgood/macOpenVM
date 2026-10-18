// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Security

/// Independent caller/code-reviewed loader inputs. These are never decoded from VM metadata.
public struct ReviewedQemuLibrary: Equatable, Sendable {
  public let url: URL
  public let byteCount: UInt64
  public let sha256: String
  public let importPaths: [String]
  public let dependencies: [String]
  public init(
    url: URL, byteCount: UInt64, sha256: String, importPaths: [String], dependencies: [String]
  ) {
    self.url = url
    self.byteCount = byteCount
    self.sha256 = sha256
    self.importPaths = importPaths
    self.dependencies = dependencies
  }
}
/// Explicit caller selection of an experimental transport recipe. This is not
/// serialized VM metadata or evidence that Windows has loaded its port driver.
public enum ReviewedQemuAgentChannel: Equatable, Sendable {
  case virtioSerialV1
}
/// A caller-reviewed playback recipe. VM metadata cannot select host audio or
/// microphone access. This recipe exposes no capture codec or input voice.
public enum ReviewedQemuAudioOutput: Equatable, Sendable {
  case coreAudioHDAV1
}
/// Caller-selected 2D experiment, never derived from stored VM metadata.
/// RAMFB remains available for firmware recovery.
public struct ReviewedQemu2DDisplay: Equatable, Sendable {
  public let initialPixels: PixelSize
  public init(initialPixels: PixelSize) throws {
    guard (320...8192).contains(initialPixels.width), (200...8192).contains(initialPixels.height),
      initialPixels.width * initialPixels.height <= 16_777_216
    else { throw registeredQemuFailure() }
    self.initialPixels = initialPixels
  }
}
/// Explicit Neptune/DXMT experiment. Stored VM metadata cannot enable this profile.
public struct ReviewedQemuAcceleratedDisplay: Equatable, Sendable {
  /// PCI host-visible mapping capacity, not a reservation of physical GPU RAM.
  public enum HostWindow: String, Sendable {
    case oneGiB = "1G"
    case fourGiB = "4G"
  }
  /// Closed trial timings, selected by a reviewed caller rather than VM metadata.
  /// Advertising a timing does not prove the guest applied or delivered it.
  public enum RefreshRate: String, Sendable {
    case hz60 = "60000"
    case hz120 = "120000"
  }
  public let initialPixels: PixelSize
  public let separateFirmware: Bool
  public let hostWindow: HostWindow
  public let refreshRate: RefreshRate
  public init(
    initialPixels: PixelSize, separateFirmware: Bool = false, hostWindow: HostWindow = .oneGiB,
    refreshRate: RefreshRate = .hz60
  ) throws {
    self.initialPixels = try ReviewedQemu2DDisplay(initialPixels: initialPixels).initialPixels
    self.separateFirmware = separateFirmware
    self.hostWindow = hostWindow
    self.refreshRate = refreshRate
  }
}
/// The renderer's separately spawned helper is part of the admitted loader closure.
public struct ReviewedQemuRenderServer: Equatable, Sendable {
  public let url: URL
  public let byteCount: UInt64
  public let sha256: String
  public let imports: [String]
  public init(url: URL, byteCount: UInt64, sha256: String, imports: [String]) {
    self.url = url
    self.byteCount = byteCount
    self.sha256 = sha256
    self.imports = imports
  }
}
public struct ReviewedQemuLaunchResources: Equatable, Sendable {
  public let creation: ReviewedQemuCreationResources
  /// Independent runtime selection; creation provenance and platform bytes stay unchanged.
  public let runtimeQemu: ReviewedQemuResource
  /// A caller/code-reviewed capability, never inferred from desired VM metadata.
  public let supportsShared: Bool
  public let supportImage: ReviewedQemuSupportImage?
  /// Closed capture-only second CD; never persisted in VM configuration.
  public let extraReadOnlyTools: ReviewedQemuCaptureTools?
  public let agentChannel: ReviewedQemuAgentChannel?
  public let displayEvaluation: ReviewedQemu2DDisplay?
  public let acceleratedDisplay: ReviewedQemuAcceleratedDisplay?
  public let renderServer: ReviewedQemuRenderServer?
  public let sharedFrameTransport: Bool
  public let audioOutput: ReviewedQemuAudioOutput?
  /// Explicit runtime-only keymap; the creation identity remains unchanged.
  public let keyboardMap: ReviewedQemuResource?
  public let libraries: [ReviewedQemuLibrary]
  public let qemuImports: [String]
  public let swtpmImports: [String]
  public let systemImports: Set<String>
  public init(
    creation: ReviewedQemuCreationResources, libraries: [ReviewedQemuLibrary],
    qemuImports: [String], swtpmImports: [String], systemImports: Set<String>,
    runtimeQemu: ReviewedQemuResource? = nil, supportsShared: Bool = false,
    supportImage: ReviewedQemuSupportImage? = nil,
    agentChannel: ReviewedQemuAgentChannel? = nil,
    displayEvaluation: ReviewedQemu2DDisplay? = nil,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay? = nil,
    renderServer: ReviewedQemuRenderServer? = nil,
    keyboardMap: ReviewedQemuResource? = nil, sharedFrameTransport: Bool = false,
    audioOutput: ReviewedQemuAudioOutput? = nil,
    extraReadOnlyTools: ReviewedQemuCaptureTools? = nil
  ) throws {
    let selected = try runtimeQemu ?? creation.resource(.qemu)
    guard selected.role == .qemu, !supportsShared || runtimeQemu != nil else {
      throw registeredQemuFailure()
    }
    try QemuCreationResourceIO.validateDescription(selected)
    if let keyboardMap {
      guard keyboardMap.role == .enUsKeymap else { throw registeredQemuFailure() }
      try QemuCreationResourceIO.validateDescription(keyboardMap)
    }
    guard displayEvaluation == nil || acceleratedDisplay == nil,
      acceleratedDisplay == nil || renderServer != nil,
      !sharedFrameTransport || (runtimeQemu != nil && renderServer != nil),
      audioOutput == nil
        || (runtimeQemu != nil
          && qemuImports.contains(
            "/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio"))
    else { throw registeredQemuFailure() }
    if let extraReadOnlyTools {
      try extraReadOnlyTools.requireCaptureRuntime(selected)
      guard runtimeQemu != nil, renderServer != nil, sharedFrameTransport,
        agentChannel == nil, displayEvaluation == nil
      else { throw registeredQemuFailure() }
    }
    if let renderServer {
      guard QemuCreationLocalPath.isValid(renderServer.url, maximumBytes: 4096),
        renderServer.byteCount > 0, renderServer.byteCount <= 134_217_728,
        registeredDigestShape(renderServer.sha256), renderServer.imports.count <= 64,
        renderServer.imports.allSatisfy({
          $0.hasPrefix("/")
            && QemuCreationLocalPath.isValid(
              URL(fileURLWithPath: $0), maximumBytes: 4096)
        })
      else { throw registeredQemuFailure() }
    }
    let aliases = libraries.flatMap(\.importPaths)
    guard !libraries.isEmpty, libraries.count <= 32, aliases.count <= 64,
      Set(libraries.map { $0.url.path }).count == libraries.count,
      Set(aliases).count == aliases.count, !systemImports.isEmpty, systemImports.count <= 32,
      systemImports.allSatisfy({ $0.hasPrefix("/usr/lib/") || $0.hasPrefix("/System/Library/") }),
      (aliases + qemuImports + swtpmImports + Array(systemImports)
        + libraries.flatMap(\.dependencies)).allSatisfy({
          $0.hasPrefix("/")
            && QemuCreationLocalPath.isValid(URL(fileURLWithPath: $0), maximumBytes: 4096)
        }),
      libraries.allSatisfy({
        QemuCreationLocalPath.isValid($0.url, maximumBytes: 4096) && $0.byteCount > 0
          && $0.byteCount <= 134_217_728 && registeredDigestShape($0.sha256)
          && !$0.importPaths.isEmpty && $0.dependencies.count <= 64
      })
    else { throw registeredQemuFailure() }
    self.creation = creation
    self.runtimeQemu = selected
    self.supportsShared = supportsShared
    self.supportImage = supportImage
    self.extraReadOnlyTools = extraReadOnlyTools
    self.agentChannel = agentChannel
    self.displayEvaluation = displayEvaluation
    self.acceleratedDisplay = acceleratedDisplay
    self.renderServer = renderServer
    self.sharedFrameTransport = sharedFrameTransport
    self.audioOutput = audioOutput
    self.keyboardMap = keyboardMap
    self.libraries = libraries
    self.qemuImports = qemuImports
    self.swtpmImports = swtpmImports
    self.systemImports = systemImports
  }
  /// The actual registered worker uses this pure reconstruction. Both reviewed
  /// discs and all loader fields survive selection of its live display devices.
  package func selectingWorkerDevices(
    agentChannel: ReviewedQemuAgentChannel? = nil,
    displayEvaluation: ReviewedQemu2DDisplay? = nil,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay? = nil,
    producerCapture: CaptureCapability? = nil
  ) throws -> Self {
    guard
      producerCapture == nil
        ? extraReadOnlyTools == nil
        : (producerCapture == .boundedProducerV1 && extraReadOnlyTools != nil
          && acceleratedDisplay != nil && agentChannel == nil && displayEvaluation == nil)
    else { throw registeredQemuFailure() }
    return try Self(
      creation: creation, libraries: libraries, qemuImports: qemuImports,
      swtpmImports: swtpmImports, systemImports: systemImports, runtimeQemu: runtimeQemu,
      supportsShared: supportsShared, supportImage: supportImage,
      agentChannel: agentChannel, displayEvaluation: displayEvaluation,
      acceleratedDisplay: acceleratedDisplay, renderServer: renderServer,
      keyboardMap: keyboardMap, sharedFrameTransport: sharedFrameTransport,
      audioOutput: audioOutput, extraReadOnlyTools: extraReadOnlyTools)
  }

  public func verify() throws {
    try verify(
      hostMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      signature: RegisteredMachO.signature)
  }
  // The private package seam tests file/import admission without claiming signature or guest health.
  func verify(hostMajor: Int, signature: (URL, Bool) throws -> Void) throws {
    guard hostMajor >= 27, HostResources.current.architecture == .arm64 else {
      throw registeredQemuFailure()
    }
    try supportImage?.verify()
    try extraReadOnlyTools?.image.verify()
    try creation.verifyResourceFiles()
    if let keyboardMap { try QemuCreationResourceIO.verify(keyboardMap) }
    if runtimeQemu != (try creation.resource(.qemu)) {
      try QemuCreationResourceIO.verify(runtimeQemu)
    }
    let aliases = Dictionary(
      uniqueKeysWithValues: libraries.flatMap { library in
        library.importPaths.map { ($0, library.url.path) }
      })
    let executableRows = [
      (runtimeQemu, qemuImports, true),
      (try creation.resource(.swtpm), swtpmImports, false),
    ]
    if let renderServer {
      let bytes = try RegisteredQemuIO.reviewed(
        renderServer.url, count: renderServer.byteCount, sha256: renderServer.sha256)
      let facts = try RegisteredMachO.parse(bytes, executable: true, hostMajor: hostMajor)
      guard facts == renderServer.imports else { throw registeredQemuFailure() }
      try signature(renderServer.url, false)
      try validateImports(facts, aliases: aliases)
    }
    for (resource, imports, hypervisor) in executableRows {
      let bytes = try RegisteredQemuIO.reviewed(
        resource.url, count: resource.byteCount, sha256: resource.sha256)
      let facts = try RegisteredMachO.parse(bytes, executable: true, hostMajor: hostMajor)
      guard facts == imports else { throw registeredQemuFailure() }
      try signature(resource.url, hypervisor)
      try validateImports(facts, aliases: aliases)
    }
    for library in libraries {
      let bytes = try RegisteredQemuIO.reviewed(
        library.url, count: library.byteCount, sha256: library.sha256)
      let facts = try RegisteredMachO.parse(bytes, executable: false, hostMajor: hostMajor)
      guard facts == library.dependencies else { throw registeredQemuFailure() }
      try signature(library.url, false)
      try validateImports(facts, aliases: aliases)
    }
    // URL-based signature verification is a separate read. Recheck all pinned
    // names/bytes afterwards so replacement at that observed boundary refuses.
    // This does not eliminate a later same-user path-to-spawn race.
    try supportImage?.verify()
    try extraReadOnlyTools?.image.verify()
    try creation.verifyResourceFiles()
    if let keyboardMap { try QemuCreationResourceIO.verify(keyboardMap) }
    try QemuCreationResourceIO.verify(runtimeQemu)
    if let renderServer {
      _ = try RegisteredQemuIO.reviewed(
        renderServer.url, count: renderServer.byteCount, sha256: renderServer.sha256)
      try validateImports(renderServer.imports, aliases: aliases)
    }
    for library in libraries {
      _ = try RegisteredQemuIO.reviewed(
        library.url, count: library.byteCount, sha256: library.sha256)
      try validateImports(library.dependencies, aliases: aliases)
    }
    try validateImports(qemuImports, aliases: aliases)
    try validateImports(swtpmImports, aliases: aliases)
  }
  private func validateImports(_ paths: [String], aliases: [String: String]) throws {
    for path in paths {
      if systemImports.contains(path) { continue }
      guard let expected = aliases[path], let resolved = realpath(path, nil) else {
        throw registeredQemuFailure()
      }
      defer { free(resolved) }
      guard String(cString: resolved) == expected else { throw registeredQemuFailure() }
    }
  }
}

/// Bounded public Mach-O load-command inspection; it never loads or executes code.
enum RegisteredMachO {
  static func parse(_ data: Data, executable: Bool, hostMajor: Int) throws -> [String] {
    let bytes = Array(data)
    func u32(_ offset: Int) throws -> UInt32 {
      guard offset >= 0, offset <= bytes.count - 4 else { throw registeredQemuFailure() }
      return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    guard hostMajor >= 0, hostMajor <= 65535, bytes.count >= 32, try u32(0) == 0xfeed_facf,
      try u32(4) == 0x0100_000c,
      try u32(12) == (executable ? 2 : 6)
    else { throw registeredQemuFailure() }
    let count = Int(try u32(16))
    let size = Int(try u32(20))
    guard count > 0, count <= 256, size <= 65_536, 32 + size <= bytes.count else {
      throw registeredQemuFailure()
    }
    var offset = 32
    var imports: [String] = []
    var buildSeen = false
    for _ in 0..<count {
      let command = try u32(offset)
      let length = Int(try u32(offset + 4))
      guard length >= 8, offset + length <= 32 + size else { throw registeredQemuFailure() }
      if command == 0x32 {
        guard !buildSeen, length >= 24, try u32(offset + 8) == 1 else {
          throw registeredQemuFailure()
        }
        let minimum = try u32(offset + 12)
        guard minimum > 0, minimum >> 16 <= UInt32(hostMajor) else { throw registeredQemuFailure() }
        buildSeen = true
      }
      if [UInt32(0xc), 0x18, 0x8000_0018, 0x1f, 0x8000_001f].contains(command) {
        guard length >= 24, imports.count < 64 else { throw registeredQemuFailure() }
        let relative = Int(try u32(offset + 8))
        guard relative >= 24, relative < length else { throw registeredQemuFailure() }
        let start = offset + relative
        guard let end = bytes[start..<offset + length].firstIndex(of: 0), end - start <= 4096,
          let path = String(bytes: bytes[start..<end], encoding: .utf8), path.hasPrefix("/"),
          QemuCreationLocalPath.isValid(URL(fileURLWithPath: path), maximumBytes: 4096)
        else { throw registeredQemuFailure() }
        imports.append(path)
      }
      offset += length
    }
    guard offset == 32 + size, buildSeen else { throw registeredQemuFailure() }
    return imports
  }
  static func signature(_ url: URL, hypervisor: Bool) throws {
    var reference: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &reference) == errSecSuccess, let reference,
      SecStaticCodeCheckValidity(reference, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        == errSecSuccess
    else {
      throw registeredQemuFailure()
    }
    if hypervisor {
      var info: CFDictionary?
      guard
        SecCodeCopySigningInformation(
          reference, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
        let fields = info as? [String: Any],
        let entitlements = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
        let value = entitlements["com.apple.security.hypervisor"] as? NSNumber,
        CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue
      else { throw registeredQemuFailure() }
    }
  }
}
func registeredDigestShape(_ value: String) -> Bool {
  value.utf8.count == 64
    && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func registeredQemuFailure() -> VMError {
  VMError(
    .invalidConfiguration, "The registered Windows runtime inputs could not be safely confirmed.",
    recovery: "Preserve the selected VM and reviewed resources; inspect before starting.")
}
