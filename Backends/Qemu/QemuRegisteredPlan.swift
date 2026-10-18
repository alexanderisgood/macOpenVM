// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import VMStorage

/// One caller-created private endpoint directory. Names locate children/IPC;
/// no PID, saved session or socket file grants runtime ownership.
public struct QemuRegisteredEndpoints: Sendable {
  public let directory: URL
  public let qmpSocket: URL
  public let tpmSocket: URL
  public let displaySocket: URL
  public let sharedFrameSocket: URL
  public let controlSocket: URL
  public let agentChannel: ReviewedQemuAgentChannel?
  public let agentSocket: URL?
  private let device: dev_t
  private let inode: ino_t
  public init(directory: URL, agentChannel: ReviewedQemuAgentChannel? = nil) throws {
    guard !directory.path.contains(",") else { throw registeredQemuFailure() }
    let info = try RegisteredQemuIO.directory(directory)
    let names =
      ["qmp.sock", "tpm.sock", "vnc.sock", "worker.sock"]
      + (agentChannel == nil ? [] : ["agent.sock"])
    let paths = names.map {
      URL(fileURLWithPath: directory.path + "/" + $0)
    }
    guard paths.allSatisfy({ $0.path.utf8.count <= 103 }),
      try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
    else { throw registeredQemuFailure() }
    self.directory = directory
    qmpSocket = paths[0]
    tpmSocket = paths[1]
    displaySocket = paths[2]
    sharedFrameSocket = directory.appendingPathComponent("surface.sock")
    controlSocket = paths[3]
    self.agentChannel = agentChannel
    agentSocket = agentChannel == nil ? nil : paths[4]
    device = info.st_dev
    inode = info.st_ino
  }
  /// Allows the caller's actual retained IPC server to bind before children.
  /// This validates only the original parent; it never adopts any named socket.
  public func revalidateParent() throws {
    let info = try RegisteredQemuIO.directory(directory)
    guard info.st_dev == device, info.st_ino == inode else { throw registeredQemuFailure() }
  }
  /// Invoke before child launch. A worker socket is left to the actual server
  /// object; none of these child endpoints may already exist or be indirect.
  public func requireChildSocketsAbsent() throws {
    try revalidateParent()
    for url in [qmpSocket, tpmSocket, displaySocket, sharedFrameSocket]
      + (agentSocket.map { [$0] } ?? [])
    {
      var info = stat()
      errno = 0
      guard lstat(url.path, &info) != 0, errno == ENOENT else { throw registeredQemuFailure() }
    }
  }
}

/// Recomputed offline blueprint bound to the actual retained writer. Creating or
/// decoding metadata cannot start it; the worker still needs a new recorded owner.
public struct QemuRegisteredPlan: Sendable {
  public let vmID: UUID
  public let directory: URL
  public let endpoints: QemuRegisteredEndpoints
  public let qemuExecutable: URL
  public let swtpmExecutable: URL
  public let qemuArguments: [String]
  public let swtpmArguments: [String]
  public var environment: [String: String] {
    ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": endpoints.directory.path]
  }
  private let configuration: VMConfiguration
  private let resources: ReviewedQemuLaunchResources
  private let configurationBytes: Data
  private let identityBytes: Data
  private let lock: VMLock

  init(
    configuration: VMConfiguration, directory: URL, endpoints: QemuRegisteredEndpoints,
    resources: ReviewedQemuLaunchResources, configurationBytes: Data, identityBytes: Data,
    lock: VMLock
  ) throws {
    let blueprint = try Self.arguments(
      configuration: configuration, directory: directory,
      resources: resources, endpoints: endpoints)
    vmID = configuration.id
    self.directory = directory
    self.endpoints = endpoints
    qemuExecutable = resources.runtimeQemu.url
    swtpmExecutable = try resources.creation.resource(.swtpm).url
    qemuArguments = blueprint.0
    swtpmArguments = blueprint.1
    self.configuration = configuration
    self.resources = resources
    self.configurationBytes = configurationBytes
    self.identityBytes = identityBytes
    self.lock = lock
  }
  public func revalidate(lock expected: VMLock) throws {
    guard expected === lock, lock.owns(directory) else { throw registeredQemuFailure() }
    try endpoints.revalidateParent()
    guard
      try RegisteredQemuIO.read(
        directory.appendingPathComponent("configuration.json"), maximum: 16384, mode: 0o600)
        == configurationBytes,
      try RegisteredQemuIO.read(
        directory.appendingPathComponent(QemuPlatformIdentityCodec.filename), maximum: 8192,
        mode: 0o600) == identityBytes
    else {
      throw registeredQemuFailure()
    }
    try resources.verify()
    try RegisteredQemuIO.platformState(
      in: directory, diskFile: configuration.diskFile, diskBytes: configuration.diskBytes)
    guard lock.owns(directory) else { throw registeredQemuFailure() }
  }
  static func validateConfiguration(
    _ c: VMConfiguration, in directory: URL, supportsShared: Bool = false,
    supportImage: ReviewedQemuSupportImage? = nil
  ) throws {
    guard c.guest == .windows11, c.backend == .qemuHVF, c.architecture == .arm64, c.boot == .efi,
      c.network == .disconnected || (c.network == .shared && supportsShared), c.kernel == nil,
      c.initialRamdisk == nil,
      c.memoryBytes > 0, c.memoryBytes % 1_048_576 == 0,
      QemuCreationLocalPath.isValid(directory, maximumBytes: 4096), !directory.path.contains(","),
      ConfigurationValidator.isSafeComponent(c.diskFile),
      !c.diskFile.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !Set([
        "configuration.json", "writer.lock", "runtime.json", "runtime-intent.json", "runtime-runs",
        ".runtime",
        QemuPlatformIdentityCodec.filename, QemuPlatformIdentityCodec.variablesFilename,
        QemuPlatformIdentityCodec.tpmDirectory,
      ])
      .contains(c.diskFile.precomposedStringWithCanonicalMapping.lowercased())
    else { throw registeredQemuFailure() }
    if let support = c.supportMedia {
      guard let supportImage, support == supportImage.url.path,
        QemuCreationLocalPath.isValid(URL(fileURLWithPath: support), maximumBytes: 4096)
      else { throw registeredQemuFailure() }
    }
  }
  static func arguments(
    configuration c: VMConfiguration, directory: URL,
    resources: ReviewedQemuLaunchResources, endpoints: QemuRegisteredEndpoints
  ) throws -> ([String], [String]) {
    try arguments(
      configuration: c, directory: directory, resources: resources.creation,
      endpoints: endpoints, supportsShared: resources.supportsShared,
      supportImage: resources.supportImage, agentChannel: resources.agentChannel,
      displayEvaluation: resources.displayEvaluation,
      acceleratedDisplay: resources.acceleratedDisplay,
      keyboardMap: resources.keyboardMap, sharedFrameTransport: resources.sharedFrameTransport,
      audioOutput: resources.audioOutput, extraReadOnlyTools: resources.extraReadOnlyTools)
  }
  static func arguments(
    configuration c: VMConfiguration, directory: URL,
    resources: ReviewedQemuCreationResources, endpoints: QemuRegisteredEndpoints
  ) throws -> ([String], [String]) {
    try arguments(
      configuration: c, directory: directory, resources: resources,
      endpoints: endpoints, supportsShared: false, supportImage: nil, agentChannel: nil,
      displayEvaluation: nil, acceleratedDisplay: nil)
  }
  private static func arguments(
    configuration c: VMConfiguration, directory: URL,
    resources: ReviewedQemuCreationResources, endpoints: QemuRegisteredEndpoints,
    supportsShared: Bool, supportImage: ReviewedQemuSupportImage?,
    agentChannel: ReviewedQemuAgentChannel?, displayEvaluation: ReviewedQemu2DDisplay?,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay?, keyboardMap: ReviewedQemuResource? = nil,
    sharedFrameTransport: Bool = false, audioOutput: ReviewedQemuAudioOutput? = nil,
    extraReadOnlyTools: ReviewedQemuCaptureTools? = nil
  ) throws -> ([String], [String]) {
    guard endpoints.agentChannel == agentChannel else { throw registeredQemuFailure() }
    try validateConfiguration(
      c, in: directory, supportsShared: supportsShared, supportImage: supportImage)
    let firmware = try resources.resource(.firmware).url
    let keymap = try (keyboardMap ?? resources.resource(.enUsKeymap)).url
    // The pinned NVMe controller rejects serials longer than its 20-byte field.
    let serial =
      "MVO-"
      + String(c.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().suffix(16))
    let disk = directory.path + "/" + c.diskFile
    let vars = directory.path + "/" + QemuPlatformIdentityCodec.variablesFilename
    var args = [
      "-no-user-config", "-nodefaults", "-machine",
      "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off", "-accel", "hvf", "-cpu",
      "host",
      "-smp", String(c.cpuCount), "-m", String(c.memoryBytes / 1_048_576), "-display", "none",
      "-monitor", "none", "-serial", "stdio",
      "-qmp", "unix:\(endpoints.qmpSocket.path),server=on,wait=off", "-drive",
      "if=pflash,unit=0,format=raw,readonly=on,file=\(QemuPlan.escape(firmware.path))", "-device",
      "uefi-vars-sysbus,jsonfile=\(QemuPlan.escape(vars)),size=262144,force-secure-boot=off,disable-custom-mode=on",
      "-chardev", "socket,id=chrtpm,path=\(endpoints.tpmSocket.path)", "-tpmdev",
      "emulator,id=tpm0,chardev=chrtpm",
      "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on", "-device", "ramfb,id=display0",
      "-device", "qemu-xhci,id=xhci0", "-device", "usb-kbd,id=keyboard0,bus=xhci0.0", "-device",
      "usb-mouse,id=relative-pointer0,bus=xhci0.0", "-device",
      "usb-tablet,id=pointer0,bus=xhci0.0",
      "-drive", "if=none,id=system,format=raw,cache=none,file=\(QemuPlan.escape(disk))",
      "-device",
      "nvme,drive=system,serial=\(serial)",
      "-k", keymap.path, "-vnc", "unix:\(endpoints.displaySocket.path),share=force-shared",
    ]
    var networkArguments: [String]
    switch c.network {
    case .disconnected: networkArguments = ["-nic", "none"]
    case .shared:
      let mac = c.macAddress.split(separator: ":", omittingEmptySubsequences: false)
      guard mac.count == 6,
        mac.allSatisfy({ part in
          part.utf8.count == 2
            && part.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        }), let first = UInt8(mac[0], radix: 16), first & 3 == 2
      else { throw registeredQemuFailure() }
      networkArguments = [
        "-netdev",
        "user,id=net0,ipv4=on,ipv6=off,restrict=off,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15",
        "-device",
        "virtio-net-pci,id=nic0,netdev=net0,disable-legacy=on,disable-modern=off,mac=\(c.macAddress),romfile=",
      ]
    }
    guard let networkIndex = args.firstIndex(of: "-qmp") else { throw registeredQemuFailure() }
    args.insert(contentsOf: networkArguments, at: networkIndex)
    if let media = c.installationMedia {
      let url = URL(fileURLWithPath: media)
      guard QemuCreationLocalPath.isValid(url, maximumBytes: 4096) else {
        throw registeredQemuFailure()
      }
      args += [
        "-drive",
        "if=none,id=installer,format=raw,media=cdrom,readonly=on,file=\(QemuPlan.escape(media))",
        "-device", "usb-storage,drive=installer,bus=xhci0.0,bootindex=1",
      ]
    }
    if let support = c.supportMedia {
      args += [
        "-drive",
        "if=none,id=support,format=raw,media=cdrom,readonly=on,file=\(QemuPlan.escape(support))",
        "-device", "usb-storage,drive=support,bus=xhci0.0",
      ]
    }
    if let audioOutput {
      switch audioOutput {
      case .coreAudioHDAV1:
        args += [
          "-audiodev",
          "coreaudio,id=audio0,in.voices=0,out.voices=1,out.fixed-settings=on,out.frequency=48000,out.channels=2,out.buffer-length=10000,out.buffer-count=4",
          "-device", "intel-hda,id=audio-controller0",
          "-device", "hda-output,id=audio-codec0,bus=audio-controller0.0,audiodev=audio0",
        ]
      }
    }
    if let agentChannel {
      guard agentChannel == .virtioSerialV1, let socket = endpoints.agentSocket else {
        throw registeredQemuFailure()
      }
      args += [
        "-device",
        "virtio-serial-pci,id=agentserial0,disable-legacy=on,disable-modern=off,max_ports=2",
        "-chardev",
        "socket,id=agentchr0,path=\(socket.path),server=on,wait=off",
        "-device",
        "virtserialport,id=agentport0,bus=agentserial0.0,nr=1,chardev=agentchr0,name=org.macopenvm.agent.v1",
      ]
    }
    if let displayEvaluation {
      let pixels = displayEvaluation.initialPixels
      args += [
        "-device",
        "virtio-gpu-pci,id=display1,disable-legacy=on,disable-modern=off,edid=on,max_outputs=1,xres=\(pixels.width),yres=\(pixels.height),romfile=",
      ]
    }
    // Preserve 60 Hz unless the caller selects the separately reviewed trial.
    // Guest application and delivery still require independent evidence.
    if let acceleratedDisplay {
      guard let vncIndex = args.firstIndex(of: "-vnc") else { throw registeredQemuFailure() }
      args[vncIndex + 1] += ",active-refresh-ms=200"
      let pixels = acceleratedDisplay.initialPixels
      let hostWindow = acceleratedDisplay.hostWindow.rawValue
      let refresh = acceleratedDisplay.refreshRate.rawValue
      guard let firmwareDisplay = args.firstIndex(of: "ramfb,id=display0"),
        let display = args.firstIndex(of: "-display"), display + 1 < args.count
      else { throw registeredQemuFailure() }
      // One console hands firmware RAMFB to the Windows GPU. This prevents
      // the extended desktop offset caused by two separately exposed screens.
      if acceleratedDisplay.separateFirmware {
        args += [
          "-device",
          "virtio-gpu-gl-pci,id=display1,disable-legacy=on,disable-modern=off,neptune=on,blob=on,hostmem=\(hostWindow),edid=on,edid-refresh-rate=\(refresh),edid-4k=on,max_outputs=1,xres=\(pixels.width),yres=\(pixels.height),romfile=",
        ]
      } else {
        args[firmwareDisplay] =
          "virtio-ramfb-gl,id=display0,disable-legacy=on,disable-modern=off,neptune=on,blob=on,hostmem=\(hostWindow),edid=on,edid-refresh-rate=\(refresh),edid-4k=on,max_outputs=1,xres=\(pixels.width),yres=\(pixels.height),romfile="
      }
      args[display + 1] = "egl-headless,gl=es,damage-readback=on"
      if sharedFrameTransport {
        guard endpoints.sharedFrameSocket.path.utf8.count <= 103 else {
          throw registeredQemuFailure()
        }
        args[display + 1] += ",shared-frame=\(endpoints.sharedFrameSocket.path)"
      }
      guard let accelerator = args.firstIndex(of: "-accel"), accelerator + 1 < args.count
      else { throw registeredQemuFailure() }
      // The reviewed GPU runtime supports macOS 26's public 4 KB IPA API.
      // Windows shared GPU rings can occupy sub-host-page BAR offsets.
      args[accelerator + 1] = "hvf,ipa-granule=4k"
    }
    if let extraReadOnlyTools {
      args += [
        "-drive",
        "if=none,id=capturetools,format=raw,media=cdrom,readonly=on,file=\(QemuPlan.escape(extraReadOnlyTools.image.url.path))",
        "-device", "usb-storage,id=capture-tools0,drive=capturetools,bus=xhci0.0",
      ]
    }
    return (
      args,
      [
        "socket", "--tpm2", "--tpmstate", "dir=\(directory.path)/tpm-state,mode=0600,lock",
        "--ctrl",
        "type=unixio,path=\(endpoints.tpmSocket.path),mode=0600,terminate", "--flags",
        "startup-none", "--log", "file=-",
      ]
    )
  }
}

@MainActor public enum QemuRegisteredAdmission {
  /// File-only validation under the caller's actual writer. This creates no
  /// endpoints, plan, runtime permit, child or guest/device-health evidence.
  public static func validateStoredState(
    configuration: VMConfiguration, in directory: URL,
    platformIdentity: Data, resources: ReviewedQemuLaunchResources, lock: VMLock
  ) async throws {
    _ = try storedState(
      configuration: configuration, in: directory, platformIdentity: platformIdentity,
      resources: resources, lock: lock, verify: { try resources.verify() })
  }
  public static func prepare(
    configuration: VMConfiguration, in directory: URL, platformIdentity: Data,
    resources: ReviewedQemuLaunchResources, endpoints: QemuRegisteredEndpoints, lock: VMLock
  ) async throws -> QemuRegisteredPlan {
    try prepare(
      configuration: configuration, in: directory, platformIdentity: platformIdentity,
      resources: resources, endpoints: endpoints, lock: lock, verify: { try resources.verify() })
  }
  // Package fixtures exercise the actual storage/writer checks while separately
  // testing real signature rejection. Production always uses actual verification.
  static func validateStoredState(
    configuration: VMConfiguration, in directory: URL,
    platformIdentity: Data, resources: ReviewedQemuLaunchResources, lock: VMLock,
    verify: () throws -> Void
  ) throws {
    _ = try storedState(
      configuration: configuration, in: directory, platformIdentity: platformIdentity,
      resources: resources, lock: lock, verify: verify)
  }
  static func prepare(
    configuration: VMConfiguration, in directory: URL, platformIdentity: Data,
    resources: ReviewedQemuLaunchResources, endpoints: QemuRegisteredEndpoints, lock: VMLock,
    verify: () throws -> Void
  ) throws -> QemuRegisteredPlan {
    let bytes = try storedState(
      configuration: configuration, in: directory, platformIdentity: platformIdentity,
      resources: resources, lock: lock, verify: verify)
    try endpoints.requireChildSocketsAbsent()
    return try QemuRegisteredPlan(
      configuration: configuration, directory: directory, endpoints: endpoints,
      resources: resources, configurationBytes: bytes, identityBytes: platformIdentity, lock: lock)
  }
  private static func storedState(
    configuration: VMConfiguration, in directory: URL, platformIdentity: Data,
    resources: ReviewedQemuLaunchResources, lock: VMLock, verify: () throws -> Void
  ) throws -> Data {
    guard HostResources.current.architecture == .arm64,
      ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27, lock.owns(directory)
    else { throw registeredQemuFailure() }
    try ConfigurationValidator.validate(configuration, host: .current)
    try QemuRegisteredPlan.validateConfiguration(
      configuration, in: directory, supportsShared: resources.supportsShared,
      supportImage: resources.supportImage)
    let bytes = try RegisteredQemuIO.read(
      directory.appendingPathComponent("configuration.json"), maximum: 16384, mode: 0o600)
    guard try JSONDecoder().decode(VMConfiguration.self, from: bytes) == configuration,
      try RegisteredQemuIO.read(
        directory.appendingPathComponent(QemuPlatformIdentityCodec.filename), maximum: 8192,
        mode: 0o600) == platformIdentity
    else { throw registeredQemuFailure() }
    try QemuPlatformIdentityCodec.validate(
      platformIdentity, for: configuration, resources: resources.creation)
    try RegisteredQemuIO.platformState(
      in: directory, diskFile: configuration.diskFile, diskBytes: configuration.diskBytes)
    if let media = configuration.installationMedia {
      try RegisteredQemuIO.readOnlyImage(URL(fileURLWithPath: media))
    }
    try verify()
    guard lock.owns(directory) else { throw registeredQemuFailure() }
    return bytes
  }
}
