// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import OSLog
import Virtualization

/// A Linux-only public-framework adapter. Runtime and view access share the main queue.
@MainActor
public final class AppleVirtualMachine: NSObject, MachineBackend,
  @preconcurrency VZVirtualMachineDelegate
{
  /// Native rendering/socket handle. Bind a recorded session before first access;
  /// lifecycle control must use this backend, not direct methods on the handle.
  public var machine: VZVirtualMachine {
    stopDriver.markUnboundNativeExposure()
    return ownedMachine
  }
  private let ownedMachine: VZVirtualMachine
  public let capabilities = BackendCapabilities(
    id: .appleVz, operations: [.start, .stop, .forceStop, .pause, .resume],
    limitations: [
      "Linux-only experiment; guest boot is separate evidence.",
      "One display; suspend and snapshot integrity are not implemented.",
    ])
  public var onGuestStopped: (@MainActor () -> Void)?
  public var onFailure: (@MainActor (VMError) -> Void)?
  public private(set) var lastFrameworkStartDuration: Duration?
  public var terminationObservation: BackendTerminationObservation {
    stopDriver.terminationObservation
  }
  public var isActive: Bool { stopDriver.isActive }
  private static let log = Logger(subsystem: "local.macOpenVM", category: "apple-vz")
  private let stopDriver: AppleStopDriver
  private var activeLifetime: AppleVirtualMachine?

  public init(
    configuration: VMConfiguration, directory: URL, identityData: Data, display: PixelSize? = nil,
    serialInput: FileHandle? = nil, serialOutput: FileHandle? = nil
  ) throws {
    guard configuration.guest == .linux, configuration.backend == .appleVz else {
      throw VMError(
        .unsupported, "AppleVz is evaluated only for Linux here.",
        recovery: "Use the capability map for Windows prerequisites.")
    }
    guard HostProbe.hasVirtualizationEntitlement() else {
      throw VMError(
        .missingEntitlement, "The executable lacks its virtualization entitlement.",
        recovery: "Run scripts/build.sh and use its signed application or CLI.")
    }
    guard VZVirtualMachine.isSupported else {
      throw VMError(
        .unsupported, "Native virtualization is unavailable.",
        recovery: "Review host capabilities and hardware support.")
    }
    try ConfigurationValidator.validate(configuration, host: .current)
    if let display {
      guard display.width >= 64, display.width <= 16_384, display.height >= 64,
        display.height <= 16_384
      else {
        throw VMError(
          .invalidConfiguration, "Display dimensions are outside safe limits.",
          recovery: "Use the current display's backing-pixel viewport.")
      }
    }
    let config = VZVirtualMachineConfiguration()
    config.cpuCount = configuration.cpuCount
    config.memorySize = configuration.memoryBytes
    guard identityData.count <= 4096,
      let identity = VZGenericMachineIdentifier(dataRepresentation: identityData)
    else {
      throw VMError(
        .corruptMetadata, "Machine identity is invalid.",
        recovery: "Restore the original identity; do not replace it silently.")
    }
    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = identity
    config.platform = platform
    if configuration.boot == .efi {
      let boot = VZEFIBootLoader()
      boot.variableStore = VZEFIVariableStore(
        url: directory.appendingPathComponent("efi-variables.bin"))
      config.bootLoader = boot
    } else {
      guard let kernel = configuration.kernel else {
        throw VMError(
          .invalidConfiguration, "Linux kernel is missing.",
          recovery: "Select a valid ARM64 Linux kernel.")
      }
      let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernel))
      boot.commandLine = configuration.kernelArguments
      if let initrd = configuration.initialRamdisk {
        boot.initialRamdiskURL = URL(fileURLWithPath: initrd)
      }
      config.bootLoader = boot
    }
    config.storageDevices = try Self.storageDevices(for: configuration, in: directory)
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    if let display {
      let graphics = VZVirtioGraphicsDeviceConfiguration()
      graphics.scanouts = [
        VZVirtioGraphicsScanoutConfiguration(
          widthInPixels: display.width, heightInPixels: display.height)
      ]
      config.graphicsDevices = [graphics]
      config.keyboards = [VZUSBKeyboardConfiguration()]
      config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }
    config.networkDevices = try Self.networkDevices(for: configuration)
    let console = VZVirtioConsoleDeviceSerialPortConfiguration()
    console.attachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: serialInput, fileHandleForWriting: serialOutput)
    config.serialPorts = [console]
    try config.validate()
    let nativeMachine = VZVirtualMachine(configuration: config)
    ownedMachine = nativeMachine
    stopDriver = AppleStopDriver(
      nativeIdentity: ObjectIdentifier(nativeMachine),
      isActive: { nativeMachine.state != .stopped && nativeMachine.state != .error },
      isError: { nativeMachine.state == .error },
      canStart: { nativeMachine.canStart }, canStop: { nativeMachine.canStop },
      canPause: { nativeMachine.canPause }, canResume: { nativeMachine.canResume },
      start: { completion in
        nativeMachine.start { result in MainActor.assumeIsolated { completion(result) } }
      },
      stop: { completion in
        nativeMachine.stop { error in
          MainActor.assumeIsolated {
            if let error { completion(.failure(error)) } else { completion(.success(())) }
          }
        }
      },
      pause: { completion in
        nativeMachine.pause { result in MainActor.assumeIsolated { completion(result) } }
      },
      resume: { completion in
        nativeMachine.resume { result in MainActor.assumeIsolated { completion(result) } }
      },
      requestStop: { try nativeMachine.requestStop() })
    super.init()
    ownedMachine.delegate = self
    stopDriver.onGuestStopped = { [weak self] in
      guard let self else { return }
      if self.stopDriver.terminationObservation == .explicitForcedTermination {
        Self.log.info("vm.force-stop.observed")
      } else {
        Self.log.info("vm.guest.stopped")
      }
      self.onGuestStopped?()
      self.finishLifetimeIfInactive()
    }
    stopDriver.onFailure = { [weak self] error in
      guard let self else { return }
      Self.log.error("vm.backend.failed")
      self.onFailure?(error)
      self.finishLifetimeIfInactive()
    }
  }

  /// Device configuration only; constructing these attachments does not establish guest connectivity.
  static func networkDevices(for configuration: VMConfiguration) throws
    -> [VZNetworkDeviceConfiguration]
  {
    guard configuration.network == .shared else { return [] }
    let network = VZVirtioNetworkDeviceConfiguration()
    guard let mac = VZMACAddress(string: configuration.macAddress) else {
      throw VMError(
        .invalidConfiguration, "Network identity is invalid.",
        recovery: "Review the saved MAC address.")
    }
    network.macAddress = mac
    network.attachment = VZNATNetworkDeviceAttachment()
    return [network]
  }

  /// Attachment assembly only. Public creation/start callers inspect support media
  /// before this path-based framework open; no content or lasting identity proof is inferred.
  static func storageDevices(for configuration: VMConfiguration, in directory: URL) throws
    -> [VZStorageDeviceConfiguration]
  {
    let disk = try VZDiskImageStorageDeviceAttachment(
      url: directory.appendingPathComponent(configuration.diskFile), readOnly: false,
      cachingMode: .automatic, synchronizationMode: .full)
    var devices: [VZStorageDeviceConfiguration] = [
      VZVirtioBlockDeviceConfiguration(attachment: disk)
    ]
    for path in [configuration.installationMedia, configuration.supportMedia].compactMap({ $0 }) {
      let image = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: path), readOnly: true)
      devices.append(VZUSBMassStorageDeviceConfiguration(attachment: image))
    }
    return devices
  }

  public static func createIdentity(at directory: URL) throws {
    let url = directory.appendingPathComponent("machine-identity.bin")
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw VMError(
        .storage, "An identity already exists.", recovery: "Preserve existing VM identity.")
    }
    try VZGenericMachineIdentifier().dataRepresentation.write(to: url, options: .withoutOverwriting)
    _ = try VZEFIVariableStore(
      creatingVariableStoreAt: directory.appendingPathComponent("efi-variables.bin"))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: directory.appendingPathComponent("efi-variables.bin").path)
  }

  public func start() async throws {
    lastFrameworkStartDuration = nil
    activeLifetime = self
    defer { finishLifetimeIfInactive() }
    let began = ContinuousClock.now
    do {
      try await stopDriver.start()
      lastFrameworkStartDuration = began.duration(to: .now)
    } catch { throw Self.diagnostic(error, action: "start") }
    Self.log.info("vm.start.completed")
  }

  public func requestStop() throws {
    activeLifetime = self
    defer { finishLifetimeIfInactive() }
    try stopDriver.requestStop()
    Self.log.info("vm.shutdown.requested")
  }

  public func forceStop() async throws {
    activeLifetime = self
    defer { finishLifetimeIfInactive() }
    try await stopDriver.forceStop()
    Self.log.info("vm.force-stop.completed")
  }

  public func pause() async throws {
    activeLifetime = self
    defer { finishLifetimeIfInactive() }
    try await stopDriver.pause()
  }

  public func resume() async throws {
    activeLifetime = self
    defer { finishLifetimeIfInactive() }
    try await stopDriver.resume()
  }

  public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    guard virtualMachine === ownedMachine else { return }
    stopDriver.guestDidStop(from: ObjectIdentifier(virtualMachine))
  }

  public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    guard virtualMachine === ownedMachine else { return }
    stopDriver.didStopWithError(
      Self.diagnostic(error, action: "run"), from: ObjectIdentifier(virtualMachine))
  }

  package func bindRecordedSession(sessionID: UUID) throws {
    try stopDriver.bindRecordedSession(sessionID: sessionID)
  }

  package func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    let facts = try stopDriver.freezeForSettlement(sessionID: sessionID)
    activeLifetime = nil
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID, launchDisposition: facts.launchDisposition,
      terminationObservation: facts.terminationObservation)
  }

  private func finishLifetimeIfInactive() {
    if !stopDriver.isActive { activeLifetime = nil }
  }

  private static func diagnostic(_ error: Error, action: String) -> VMError {
    let e = error as NSError
    let allowed: Set<String> = [VZErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain]
    let domain = allowed.contains(e.domain) ? e.domain : "unclassified"
    Self.log.error(
      "vm.operation.failed domain=\(domain, privacy: .public) code=\(e.code) action=\(action, privacy: .public)"
    )
    return VMError(
      .backendFailure, "Native VM \(action) failed (\(domain), code \(e.code)).",
      recovery:
        "Check ARM64 boot format, host support, media permissions and available resources. Existing VM files are preserved."
    )
  }
}

extension AppleVirtualMachine: BackendSettlementSource {}
