// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import VMStorage

/// A local metadata result, never a guest installation or architecture verification.
public struct InstallationMediaResult: Encodable, Sendable {
  public let configuration: VMConfiguration
  public let changed: Bool
  public let backupFile: String?
}

/// Bounded storage boundary for a stopped VM's media selection.
/// Implementations must preserve exclusive backup creation and atomic replacement semantics.
public protocol InstallationMediaStore: Sendable {
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage
  func inspectDisk(at url: URL) async throws -> DiskUsage
  func inspectSelectedSupportImage(at url: URL) async throws -> DiskUsage
  func readMetadata(at url: URL, limit: Int) async throws -> Data
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws
  func writeNewMetadata(_ data: Data, at url: URL) async throws
  func commitInstallationConfiguration(_ data: Data, at url: URL) async throws
}

extension InstallationMediaStore {
  /// Existing custom stores retain the production read-only image admission by default.
  public func inspectSelectedSupportImage(at url: URL) async throws -> DiskUsage {
    try await VMFiles().inspectReadOnlyImage(at: url)
  }
}

extension VMFiles: InstallationMediaStore {
  /// Require the existing private mode; replacing metadata must not repair permissions.
  public func inspectWritableConfiguration(at url: URL) throws -> DiskUsage {
    let usage = try inspectWritableFile(at: url)
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
      access(url.path, W_OK) == 0, access(url.deletingLastPathComponent().path, W_OK) == 0
    else {
      throw mediaStorageError(
        "Configuration permissions do not permit a private metadata update.",
        recovery: "Preserve existing permissions and use read-only inspection before retrying.")
    }
    return usage
  }

  /// Check cancellation on the I/O actor before starting the nonsuspending commit.
  public func commitInstallationConfiguration(_ data: Data, at url: URL) throws {
    try Task.checkCancellation()
    try atomicWrite(data, at: url)
  }
}

/// Change one media selection under the cooperating writer lock, retaining original bytes.
/// Lock availability establishes exclusion of cooperating owners, not guest filesystem health.
public struct InstallationMedia: Sendable {
  private let files: any InstallationMediaStore
  private let newBackupID: @Sendable () -> UUID

  public init(
    files: any InstallationMediaStore = VMFiles(),
    newBackupID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.files = files
    self.newBackupID = newBackupID
  }

  public func update(
    in directory: URL, to selectedMedia: URL?, host: HostResources = .current,
    expected: VMConfiguration? = nil
  ) async throws -> InstallationMediaResult {
    try await update(
      in: directory, to: selectedMedia, host: host, selection: .installation, expected: expected)
  }

  /// Stopped-only support-disc selection. This does not authenticate media or run setup.
  public func updateSupport(
    in directory: URL, to selectedMedia: URL?, host: HostResources = .current,
    expected: VMConfiguration? = nil
  ) async throws -> InstallationMediaResult {
    guard Self.isSupportLocation(directory), selectedMedia.map(Self.isSupportLocation) ?? true
    else { throw invalidSupportLocation() }
    do {
      return try await update(
        in: directory, to: selectedMedia, host: host, selection: .support, expected: expected)
    } catch {
      if error is CancellationError { throw CancellationError() }
      throw VMError(
        (error as? VMError)?.code ?? .storage, "The support-media change could not be confirmed.",
        recovery:
          "Preserve the configuration backup and VM files. Inspect before retrying; replacement may already be committed. No rollback or retry is automatic."
      )
    }
  }

  private enum Selection: Sendable {
    case installation, support
    var field: String { self == .installation ? "installationMedia" : "supportMedia" }
    var backupPrefix: String {
      self == .installation ? "configuration-media-backup-" : "configuration-support-media-backup-"
    }
  }

  private func update(
    in directory: URL, to selectedMedia: URL?, host: HostResources, selection: Selection,
    expected: VMConfiguration?
  ) async throws -> InstallationMediaResult {
    guard Self.isLocalAbsolute(directory) else { throw invalidMediaLocation() }
    try Task.checkCancellation()
    let registration = directory.appendingPathComponent("configuration.json")
    let observed = try await files.readMetadata(
      at: registration, limit: ConfigurationCodec.maximumBytes)
    _ = try Self.knownConfigurationObject(observed)
    let observedConfiguration = try ConfigurationCodec.decode(observed)
    try Self.requireExpected(observedConfiguration, expected)
    let expectedID = observedConfiguration.id
    try Task.checkCancellation()
    let lock = try VMLock(directory: directory, expectedVMID: expectedID)
    defer { withExtendedLifetime(lock) {} }

    if expected != nil {
      try Self.requireExpected(
        ConfigurationCodec.decode(
          await files.readMetadata(
            at: registration, limit: ConfigurationCodec.maximumBytes)), expected)
    }

    _ = try await files.inspectWritableConfiguration(at: registration)
    let original = try await files.readMetadata(
      at: registration, limit: ConfigurationCodec.maximumBytes)
    var object = try Self.knownConfigurationObject(original)
    var configuration = try ConfigurationCodec.decode(original)
    try Self.requireExpected(configuration, expected)
    guard configuration.id == expectedID, lock.owns(directory) else {
      throw VMError(
        .busy, "The saved VM identity changed before media admission.",
        recovery:
          "Preserve the current configuration and reopen read-only inspection before retrying.")
    }
    try ConfigurationValidator.validate(configuration, host: host)

    if let selectedMedia {
      guard Self.isLocalAbsolute(selectedMedia) else { throw invalidMediaLocation() }
      let usage: DiskUsage
      if selection == .installation {
        usage = try await files.inspectDisk(at: selectedMedia)
      } else {
        usage = try await files.inspectSelectedSupportImage(at: selectedMedia)
      }
      guard usage.virtualBytes > 0 else {
        throw VMError(
          .invalidConfiguration, "The selected installation file is empty.",
          recovery: "Choose a readable regular local installation file.")
      }
    }
    try Task.checkCancellation()
    if selection == .support, !lock.owns(directory) {
      throw VMError(
        .busy, "VM ownership changed during support-media inspection.",
        recovery: "Preserve the current registration and inspect it.")
    }
    let path = selectedMedia?.path
    let current =
      selection == .installation ? configuration.installationMedia : configuration.supportMedia
    guard current != path else {
      return InstallationMediaResult(configuration: configuration, changed: false, backupFile: nil)
    }
    if selection == .installation {
      configuration.installationMedia = path
    } else {
      configuration.supportMedia = path
    }
    if let path {
      object[selection.field] = path
    } else {
      object.removeValue(forKey: selection.field)
    }
    let replacement: Data
    do {
      replacement = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    } catch { throw invalidMediaConfiguration() }
    guard replacement.count <= ConfigurationCodec.maximumBytes,
      try ConfigurationCodec.decode(replacement) == configuration
    else { throw invalidMediaConfiguration() }
    try ConfigurationValidator.validate(configuration, host: host)
    try await files.checkFreeSpace(at: directory, reserveBytes: 1_048_576)
    try Task.checkCancellation()

    let backupFile = "\(selection.backupPrefix)\(newBackupID().uuidString.lowercased()).json"
    let backup = directory.appendingPathComponent(backupFile)
    if selection == .support, !lock.owns(directory) {
      throw VMError(
        .busy, "VM ownership changed before support-media backup.",
        recovery: "Preserve the current registration and inspect it.")
    }
    do { try await files.writeNewMetadata(original, at: backup) } catch {
      throw mediaStorageError(
        "The original configuration backup could not be confirmed.",
        recovery: "Preserve all metadata and any partial backup. No replacement was attempted.")
    }

    if selection == .support {
      guard lock.owns(directory),
        try await files.readMetadata(at: backup, limit: ConfigurationCodec.maximumBytes) == original
      else {
        throw mediaStorageError(
          "The original support-media configuration backup could not be confirmed.",
          recovery: "Preserve all metadata and any partial backup. No replacement was attempted.")
      }
    }

    // Cancellation leaves the original registered configuration and its backup intact.
    try Task.checkCancellation()
    _ = try await files.inspectWritableConfiguration(at: registration)
    guard
      try await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes)
        == original
    else {
      throw VMError(
        .busy, "Configuration changed while its backup was being preserved.",
        recovery: "Preserve the backup and current configuration. Inspect before retrying.")
    }
    try Task.checkCancellation()
    do {
      if selection == .support, !lock.owns(directory) {
        throw mediaStorageError(
          "VM ownership changed before support-media replacement.",
          recovery: "Preserve the configuration and its backup.")
      }
      try await files.commitInstallationConfiguration(replacement, at: registration)
      if selection == .support {
        _ = try await files.inspectWritableConfiguration(at: registration)
        guard
          try await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes)
            == replacement,
          try await files.readMetadata(at: backup, limit: ConfigurationCodec.maximumBytes)
            == original,
          lock.owns(directory)
        else {
          throw mediaStorageError(
            "The support-media replacement could not be read back.",
            recovery: "Preserve the configuration and its backup.")
        }
      }
    } catch {
      // Directory flush can fail after rename. Keep both versions; never guess or auto-rollback.
      throw mediaStorageError(
        "The installation-media update could not be confirmed.",
        recovery:
          "Preserve the configuration backup and VM files. Use read-only inspection before retrying; the replacement may already be committed."
      )
    }
    return InstallationMediaResult(
      configuration: configuration, changed: true, backupFile: backupFile)
  }

  private static func requireExpected(_ actual: VMConfiguration, _ expected: VMConfiguration?)
    throws
  {
    guard expected == nil || actual == expected else {
      throw VMError(
        .staleOperation, "The selected VM configuration changed before media selection.",
        recovery: "Reopen the stopped VM and review its current media settings.")
    }
  }

  private static func isLocalAbsolute(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.path.hasPrefix("/") && url.path.utf8.count <= 4096 && !url.path.contains("\0")
  }

  private static func isSupportLocation(_ url: URL) -> Bool {
    isLocalAbsolute(url) && url.user == nil && url.password == nil && url.query == nil
      && url.fragment == nil
      && !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func knownConfigurationObject(_ bytes: Data) throws -> [String: Any] {
    do { return try StrictConfigurationDocument.knownObject(bytes) } catch {
      throw invalidMediaConfiguration()
    }
  }
}

private func invalidSupportLocation() -> VMError {
  VMError(
    .invalidConfiguration, "Support media and its VM require bounded local absolute locations.",
    recovery: "Choose a local VM directory and a readable regular support image.")
}

private func invalidMediaLocation() -> VMError {
  VMError(
    .invalidConfiguration,
    "Installation media and its VM require bounded local absolute locations.",
    recovery: "Choose a local VM directory and a regular local installation file.")
}

private func invalidMediaConfiguration() -> VMError {
  VMError(
    .corruptMetadata, "Configuration is malformed, oversized or contains unsupported fields.",
    recovery: "Preserve the original configuration. Use read-only inspection before changing media."
  )
}

private func mediaStorageError(_ message: String, recovery: String) -> VMError {
  VMError(.storage, message, recovery: recovery)
}
