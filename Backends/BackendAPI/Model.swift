// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum GuestOS: String, Codable, Sendable { case linux, windows11 }
public enum GuestArchitecture: String, Codable, Sendable {
  case arm64
  case x8664 = "x86_64"
}
public enum BackendID: String, Codable, Sendable { case appleVz, qemuHVF }
public enum NetworkMode: String, Codable, Sendable { case disconnected, shared }
public enum BootKind: String, Codable, Sendable { case efi, linuxKernel }

public struct PixelSize: Codable, Equatable, Sendable {
  public let width: Int
  public let height: Int
  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

/// Plain, versioned desired configuration. Contains no runtime or secret state.
public struct VMConfiguration: Codable, Equatable, Sendable {
  public var schemaVersion: Int = 1
  public var id: UUID
  public var name: String
  public var guest: GuestOS
  public var architecture: GuestArchitecture = .arm64
  public var backend: BackendID
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var diskFile: String = "disk.raw"
  public var boot: BootKind = .efi
  public var installationMedia: String?
  /// An optional local data image attached read-only, separately from installation media.
  public var supportMedia: String? = nil
  public var kernel: String?
  public var initialRamdisk: String?
  public var kernelArguments: String = "console=hvc0"
  public var network: NetworkMode = .disconnected
  public var macAddress: String

  public init(
    name: String, guest: GuestOS, backend: BackendID, cpuCount: Int = 2,
    memoryBytes: UInt64 = 4 * 1_073_741_824, diskBytes: UInt64 = 32 * 1_073_741_824,
    id: UUID = UUID()
  ) {
    self.id = id
    self.name = name
    self.guest = guest
    self.backend = backend
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    let bytes = withUnsafeBytes(of: id.uuid) { Array($0.prefix(5)) }
    self.macAddress = ([UInt8(0x02)] + bytes).map { String(format: "%02x", $0) }.joined(
      separator: ":")
  }
}

public struct HostResources: Sendable {
  public let cpuCount: Int
  public let memoryBytes: UInt64
  public let architecture: GuestArchitecture
  public init(cpuCount: Int, memoryBytes: UInt64, architecture: GuestArchitecture = .arm64) {
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.architecture = architecture
  }
  public static var current: HostResources {
    #if arch(arm64)
      let architecture = GuestArchitecture.arm64
    #else
      let architecture = GuestArchitecture.x8664
    #endif
    return HostResources(
      cpuCount: ProcessInfo.processInfo.activeProcessorCount,
      memoryBytes: ProcessInfo.processInfo.physicalMemory, architecture: architecture)
  }
}

/// Stable errors include user recovery, without incorporating untrusted paths or content.
public struct VMError: Error, LocalizedError, Equatable, Sendable {
  public enum Code: String, Codable, Sendable {
    case invalidConfiguration, unsupported, invalidTransition, staleOperation
    case busy, storage, corruptMetadata, missingEntitlement, backendFailure, cancelled
  }
  public let code: Code
  public let message: String
  public let recovery: String
  public init(_ code: Code, _ message: String, recovery: String) {
    self.code = code
    self.message = message
    self.recovery = recovery
  }
  public var errorDescription: String? { "\(message) \(recovery)" }
}

public enum ConfigurationValidator {
  /// Validate saved settings for read-only selection, review or an offline editor.
  /// Host capacity/architecture is intentionally not admission here. No guest resources
  /// are allocated, and this value grants no writer, backend or start authority.
  /// Existing scalar types and metadata-byte limits bound numeric representation;
  /// existing minimums, alignment, schema, path and guest/device rules still apply.
  public static func validateSaved(_ c: VMConfiguration) throws {
    try validateFields(c, host: nil)
  }

  /// Existing strict admission. Its signature and host-dependent rules are unchanged.
  public static func validate(_ c: VMConfiguration, host: HostResources) throws {
    try validateFields(c, host: host)
  }

  private static func validateFields(_ c: VMConfiguration, host: HostResources?) throws {
    func reject(_ message: String) throws -> Never {
      throw VMError(
        .invalidConfiguration, message, recovery: "Review the VM hardware and media settings.")
    }
    guard c.schemaVersion == 1 else { try reject("Unsupported configuration schema.") }
    guard !c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      c.name.utf8.count <= 128,
      !c.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { try reject("A VM name must contain 1–128 UTF-8 bytes without control characters.") }
    guard c.architecture == .arm64, host.map({ $0.architecture == .arm64 }) ?? true else {
      try reject("This experiment requires an ARM64 guest and Apple-silicon host.")
    }
    guard c.cpuCount >= 1, host.map({ c.cpuCount <= max(1, $0.cpuCount - 2) }) ?? true else {
      try reject("CPU allocation must leave host capacity.")
    }
    guard c.memoryBytes >= 512 * 1_048_576,
      host.map({ c.memoryBytes <= $0.memoryBytes / 2 }) ?? true,
      c.memoryBytes % 1_048_576 == 0
    else { try reject("Memory must be MiB aligned and at most half of host RAM.") }
    guard c.diskBytes >= 1_073_741_824, c.diskBytes <= 2 * 1_099_511_627_776 else {
      try reject("Disk size must be between 1 GiB and 2 TiB.")
    }
    guard isSafeComponent(c.diskFile) else {
      try reject("The disk must be a VM-contained filename.")
    }
    let mac = c.macAddress.split(separator: ":", omittingEmptySubsequences: false)
    guard mac.count == 6, mac.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }),
      let first = UInt8(mac[0], radix: 16), first & 3 == 2
    else { try reject("A locally administered unicast MAC is required.") }
    for path in [c.installationMedia, c.kernel, c.initialRamdisk].compactMap({ $0 }) {
      guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else {
        try reject("Media paths must be bounded local absolute paths.")
      }
    }
    if let support = c.supportMedia {
      guard support.hasPrefix("/"), support.utf8.count <= 4096,
        !support.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { try reject("Support media must be a bounded local absolute path without controls.") }
    }
    guard c.kernelArguments.utf8.count <= 4096, !c.kernelArguments.contains("\0") else {
      try reject("Kernel arguments exceed their safe bounds.")
    }
    if c.boot == .linuxKernel {
      guard c.guest == .linux, c.kernel != nil else {
        try reject("Direct kernel boot requires a Linux kernel.")
      }
    }
    if c.guest == .windows11 {
      guard c.backend == .qemuHVF, c.boot == .efi,
        c.memoryBytes >= 4 * 1_073_741_824, c.diskBytes >= 64 * 1_073_741_824,
        c.cpuCount >= 2
      else { try reject("Windows requires the evaluated QEMU path and its minimum resources.") }
    }
  }

  public static func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255
      && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
  }
}
