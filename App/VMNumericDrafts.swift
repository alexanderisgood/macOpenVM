// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Combine
import Foundation

/// Parses the entire current edit. No previous number or locale-dependent grouping is accepted.
private enum VMNumericInput {
  static let mebibyte: UInt64 = 1_048_576
  static let gibibyte: UInt64 = 1_073_741_824

  static func wholeNumber(
    _ text: String, field: String, minimum: Int, maximum: Int
  ) throws -> Int {
    guard maximum >= minimum else {
      throw failure("This Mac cannot provide the minimum required \(field.lowercased()).")
    }
    // Bound work before trimming, then bound decimal length before conversion.
    guard text.utf8.prefix(129).count <= 128 else {
      throw invalid(field: field, minimum: minimum, maximum: maximum)
    }
    let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !digits.isEmpty, digits.utf8.count <= 19,
      digits.utf8.allSatisfy({ (48...57).contains($0) }),
      let value = Int(digits), (minimum...maximum).contains(value)
    else { throw invalid(field: field, minimum: minimum, maximum: maximum) }
    return value
  }

  static func cpuMaximum(_ host: HostResources) -> Int {
    host.cpuCount > 2 ? host.cpuCount - 2 : 1
  }

  static func memoryMaximum(_ host: HostResources, unit: UInt64, limit: Int) -> Int {
    Int(min(UInt64(limit), host.memoryBytes / 2 / unit))
  }

  static func failure(_ message: String) -> VMError {
    VMError(
      .invalidConfiguration, message,
      recovery: "Use whole numbers with digits 0–9 and leave capacity for this Mac.")
  }

  static func message(_ error: any Error) -> String {
    (error as? VMError)?.errorDescription ?? "Review the VM hardware settings."
  }

  private static func invalid(field: String, minimum: Int, maximum: Int) -> VMError {
    failure("\(field) must be a whole number between \(minimum) and \(maximum).")
  }
}

/// Desired values only. The session and storage layer still own stale-state and file admission.
@MainActor final class HardwareSettingsDraft: ObservableObject {
  @Published var cpuCountText: String
  @Published var memoryMiBText: String
  private let configuration: VMConfiguration

  init(configuration: VMConfiguration) {
    self.configuration = configuration
    cpuCountText = String(configuration.cpuCount)
    memoryMiBText = String(configuration.memoryBytes / VMNumericInput.mebibyte)
  }

  func prepared(host: HostResources) throws -> (cpuCount: Int, memoryBytes: UInt64) {
    let values = try numericValues(host: host)
    var proposed = configuration
    proposed.cpuCount = values.cpuCount
    proposed.memoryBytes = values.memoryBytes
    try ConfigurationValidator.validate(proposed, host: host)
    return values
  }

  func numericError(host: HostResources) -> String? {
    do {
      _ = try numericValues(host: host)
      return nil
    } catch { return VMNumericInput.message(error) }
  }

  private func numericValues(host: HostResources) throws -> (cpuCount: Int, memoryBytes: UInt64) {
    let cpu = try VMNumericInput.wholeNumber(
      cpuCountText, field: "Virtual CPUs", minimum: configuration.guest == .windows11 ? 2 : 1,
      maximum: VMNumericInput.cpuMaximum(host))
    let memory = try VMNumericInput.wholeNumber(
      memoryMiBText, field: "Memory (MiB)",
      minimum: configuration.guest == .windows11 ? 4096 : 512,
      maximum: VMNumericInput.memoryMaximum(host, unit: VMNumericInput.mebibyte, limit: Int.max))
    return (cpu, UInt64(memory) * VMNumericInput.mebibyte)
  }
}

private enum VMCreationDraftInput {
  static func local(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && url.path.hasPrefix("/") && url.path.utf8.count <= 4096
      && !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
  }

  static func selection(name: String, media: URL?, parent: URL?, guest: String) throws -> (
    name: String, media: URL, destination: URL
  ) {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard ConfigurationValidator.isSafeComponent(cleanName),
      !cleanName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let media, let parent, local(media), local(parent)
    else {
      throw VMError(
        .invalidConfiguration, "Review the \(guest) VM name, image and destination.",
        recovery: "Choose a local ARM64 installation image and a local destination folder.")
    }
    return (
      cleanName, media, parent.appendingPathComponent(cleanName + ".macopenvm", isDirectory: true)
    )
  }

  static func hardware(
    cpu: String, memory: String, disk: String, windows: Bool, host: HostResources
  ) throws -> (cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64) {
    let cpuCount = try VMNumericInput.wholeNumber(
      cpu, field: "Virtual CPUs", minimum: windows ? 2 : 1,
      maximum: VMNumericInput.cpuMaximum(host))
    let memoryGiB = try VMNumericInput.wholeNumber(
      memory, field: "Memory (GiB)", minimum: windows ? 4 : 1,
      maximum: VMNumericInput.memoryMaximum(host, unit: VMNumericInput.gibibyte, limit: 1024))
    let diskGiB = try diskValue(disk, windows: windows)
    return (
      cpuCount, UInt64(memoryGiB) * VMNumericInput.gibibyte,
      UInt64(diskGiB) * VMNumericInput.gibibyte
    )
  }

  static func diskValue(_ text: String, windows: Bool) throws -> Int {
    try VMNumericInput.wholeNumber(
      text, field: "Disk capacity (GiB)", minimum: windows ? 64 : 1, maximum: 2048)
  }
}

@MainActor final class WindowsCreationDraft: ObservableObject {
  @Published var name = "Windows 11 VM"
  @Published var media: URL?
  @Published var parent: URL?
  @Published var cpuCountText = "2"
  @Published var memoryGiBText = "4"
  @Published var diskGiBText = "64"

  /// Advisory display only; nil means the current text has no valid disk target.
  var parsedDiskGiB: Int? { try? VMCreationDraftInput.diskValue(diskGiBText, windows: true) }

  func numericError(host: HostResources) -> String? {
    do {
      _ = try numericValues(host: host)
      return nil
    } catch { return VMNumericInput.message(error) }
  }

  /// Desired configuration only; all actual file/resource admission stays in VMCreation/platform.
  func prepared(host: HostResources) throws -> (configuration: VMConfiguration, destination: URL) {
    let values = try numericValues(host: host)
    let selection = try VMCreationDraftInput.selection(
      name: name, media: media, parent: parent, guest: "Windows")
    var configuration = VMConfiguration(
      name: selection.name, guest: .windows11, backend: .qemuHVF,
      cpuCount: values.cpuCount, memoryBytes: values.memoryBytes, diskBytes: values.diskBytes)
    configuration.architecture = .arm64
    configuration.boot = .efi
    configuration.installationMedia = selection.media.path
    configuration.network = .disconnected
    try ConfigurationValidator.validate(configuration, host: host)
    return (configuration, selection.destination)
  }

  private func numericValues(host: HostResources) throws -> (
    cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64
  ) {
    try VMCreationDraftInput.hardware(
      cpu: cpuCountText, memory: memoryGiBText, disk: diskGiBText, windows: true, host: host)
  }
}

@MainActor final class LinuxCreationDraft: ObservableObject {
  @Published var name = "Linux VM"
  @Published var media: URL?
  @Published var parent: URL?
  @Published var cpuCountText: String
  @Published var memoryGiBText: String
  @Published var diskGiBText = "32"
  @Published var sharedNetwork = false

  init(host: HostResources) {
    cpuCountText = String(min(2, VMNumericInput.cpuMaximum(host)))
    memoryGiBText = String(
      max(1, VMNumericInput.memoryMaximum(host, unit: VMNumericInput.gibibyte, limit: 4)))
  }

  /// Advisory display only; nil means the current text has no valid disk target.
  var parsedDiskGiB: Int? { try? VMCreationDraftInput.diskValue(diskGiBText, windows: false) }

  func numericError(host: HostResources) -> String? {
    do {
      _ = try numericValues(host: host)
      return nil
    } catch { return VMNumericInput.message(error) }
  }

  /// Prepares declarative values before the existing session creation transaction begins.
  func prepared(host: HostResources) throws -> (configuration: VMConfiguration, destination: URL) {
    let values = try numericValues(host: host)
    let selection = try VMCreationDraftInput.selection(
      name: name, media: media, parent: parent, guest: "Linux")
    var configuration = VMConfiguration(
      name: selection.name, guest: .linux, backend: .appleVz,
      cpuCount: values.cpuCount, memoryBytes: values.memoryBytes, diskBytes: values.diskBytes)
    configuration.installationMedia = selection.media.path
    configuration.network = sharedNetwork ? .shared : .disconnected
    try ConfigurationValidator.validate(configuration, host: host)
    return (configuration, selection.destination)
  }

  private func numericValues(host: HostResources) throws -> (
    cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64
  ) {
    try VMCreationDraftInput.hardware(
      cpu: cpuCountText, memory: memoryGiBText, disk: diskGiBText, windows: false, host: host)
  }
}

/// The current whole-GiB edit alone determines the requested capacity.
@MainActor final class DiskCapacityDraft: ObservableObject {
  @Published var capacityGiBText: String
  @Published var confirmationTarget: UInt64?
  private let configuration: VMConfiguration

  init(configuration: VMConfiguration) {
    self.configuration = configuration
    capacityGiBText = String(configuration.diskBytes / VMNumericInput.gibibyte)
  }

  var currentCapacityDescription: String {
    if configuration.diskBytes % VMNumericInput.gibibyte == 0 {
      return "\(configuration.diskBytes / VMNumericInput.gibibyte) GiB"
    }
    return "\(configuration.diskBytes) bytes"
  }

  var inputError: String? {
    do {
      _ = try prepared()
      return nil
    } catch { return VMNumericInput.message(error) }
  }

  func prepared() throws -> UInt64 {
    let gibibytes = try VMNumericInput.wholeNumber(
      capacityGiBText, field: "New disk capacity (GiB)", minimum: 1, maximum: 2048)
    let target = UInt64(gibibytes) * VMNumericInput.gibibyte
    try Self.validate(target, largerThan: configuration.diskBytes)
    return target
  }

  static func validate(_ target: UInt64, largerThan current: UInt64) throws {
    guard current % 512 == 0, target > current, target % 512 == 0,
      target >= VMNumericInput.gibibyte, target <= 2048 * VMNumericInput.gibibyte
    else {
      throw VMNumericInput.failure(
        "Choose a disk capacity larger than the current disk, up to 2,048 GiB.")
    }
  }
}
