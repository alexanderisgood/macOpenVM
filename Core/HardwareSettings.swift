// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

public struct HardwareSettingsResult: Encodable, Sendable {
  public let configuration: VMConfiguration
  public let changed: Bool
  public let backupFile: String?
}

package protocol HardwareSettingsStore: Sendable {
  func readMetadata(at url: URL, limit: Int) async throws -> Data
  func commitHardwareConfiguration(
    in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64,
    host: HostResources, backupID: UUID, lock: VMLock
  ) async throws -> String?
}

extension VMFiles: HardwareSettingsStore {}

/// Offline CPU/memory changes. Saving metadata does not establish backend or guest support.
public struct HardwareSettings: Sendable {
  private let files: any HardwareSettingsStore
  private let backupID: @Sendable () -> UUID
  public init() {
    files = VMFiles()
    backupID = { UUID() }
  }
  package init(
    files: any HardwareSettingsStore, backupID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.files = files
    self.backupID = backupID
  }

  public func update(
    in directory: URL, cpuCount: Int, memoryBytes: UInt64,
    expected: VMConfiguration? = nil, host: HostResources = .current
  ) async throws -> HardwareSettingsResult {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.user == nil, directory.password == nil, directory.query == nil,
      directory.fragment == nil, directory.path.hasPrefix("/"), directory.path.utf8.count <= 4096,
      !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw VMError(.invalidConfiguration, "Choose a local VM.", recovery: "Reopen its settings.")
    }
    try Task.checkCancellation()
    let registration = directory.appendingPathComponent("configuration.json")
    let observed = try StrictConfigurationDocument(
      await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes))
    let baseline = expected ?? observed.configuration
    guard baseline == observed.configuration else { throw Self.stale() }
    var replacement = baseline
    replacement.cpuCount = cpuCount
    replacement.memoryBytes = memoryBytes
    // Validate the proposed resources even if the old allocation exceeds this host's capacity.
    try ConfigurationValidator.validate(replacement, host: host)
    let lock = try VMLock(directory: directory, expectedVMID: baseline.id)
    defer { withExtendedLifetime(lock) {} }
    do {
      let backup = try await files.commitHardwareConfiguration(
        in: directory, expected: baseline, cpuCount: cpuCount, memoryBytes: memoryBytes,
        host: host, backupID: backupID(), lock: lock)
      return .init(configuration: replacement, changed: backup != nil, backupFile: backup)
    } catch is CancellationError { throw CancellationError() } catch {
      throw VMError(
        (error as? VMError)?.code ?? .storage, "The hardware-settings save could not be confirmed.",
        recovery:
          "Preserve the VM and its configuration backup. Reopen the saved configuration before retrying; the change may already be committed."
      )
    }
  }

  private static func stale() -> VMError {
    VMError(
      .staleOperation, "The saved VM settings changed while this editor was open.",
      recovery: "Cancel and reopen the VM before editing again.")
  }
}
