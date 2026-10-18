// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

public struct NetworkSettingsResult: Encodable, Sendable {
  public let configuration: VMConfiguration
  public let changed: Bool
  public let backupFile: String?
}

package protocol NetworkSettingsStore: Sendable {
  func readMetadata(at url: URL, limit: Int) async throws -> Data
  func commitNetworkConfiguration(
    in directory: URL, expected: VMConfiguration, mode: NetworkMode,
    host: HostResources, backupID: UUID, lock: VMLock,
    sharedPermission: SharedNetworkConfigurationPermission?
  ) async throws -> String?
}

extension VMFiles: NetworkSettingsStore {}

/// Stopped-only desired networking. Saving never starts a network or alters guest input,
/// and does not establish connectivity or support for the selected guest/backend.
public struct NetworkSettings: Sendable {
  private let files: any NetworkSettingsStore
  private let backupID: @Sendable () -> UUID
  public init() {
    files = VMFiles()
    backupID = { UUID() }
  }
  package init(
    files: any NetworkSettingsStore, backupID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.files = files
    self.backupID = backupID
  }

  public func update(
    in directory: URL, mode: NetworkMode, expected: VMConfiguration? = nil,
    host: HostResources = .current,
    sharedPermission: SharedNetworkConfigurationPermission? = nil
  ) async throws -> NetworkSettingsResult {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.user == nil, directory.password == nil, directory.query == nil,
      directory.fragment == nil, directory.path.hasPrefix("/"), directory.path.utf8.count <= 4096,
      let decodedPath = URLComponents(url: directory, resolvingAgainstBaseURL: false)?
        .percentEncodedPath.removingPercentEncoding,
      decodedPath == directory.path
        || (directory.hasDirectoryPath && decodedPath == directory.path + "/"),
      directory.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw Self.failure(.invalidConfiguration, "Choose a normalized local VM folder.") }
    try Task.checkCancellation()
    let observed = try StrictConfigurationDocument(
      await files.readMetadata(
        at: directory.appendingPathComponent("configuration.json"),
        limit: ConfigurationCodec.maximumBytes))
    let baseline = expected ?? observed.configuration
    guard baseline == observed.configuration else {
      throw Self.failure(.staleOperation, "The selected VM changed before saving its networking.")
    }
    guard
      mode != .shared || baseline.guest == .linux && baseline.backend == .appleVz
        || sharedPermission?.allowsSharedConfiguration(baseline) == true
    else {
      throw Self.failure(
        .unsupported,
        "Shared networking requires native Linux or independently verified Windows runtime inputs.")
    }
    var replacement = baseline
    replacement.network = mode
    try ConfigurationValidator.validate(replacement, host: host)
    let lock = try VMLock(directory: directory, expectedVMID: baseline.id)
    defer { withExtendedLifetime(lock) {} }
    do {
      let backup = try await files.commitNetworkConfiguration(
        in: directory, expected: baseline, mode: mode, host: host, backupID: backupID(), lock: lock,
        sharedPermission: sharedPermission)
      return .init(configuration: replacement, changed: backup != nil, backupFile: backup)
    } catch is CancellationError { throw CancellationError() } catch {
      throw Self.failure(
        (error as? VMError)?.code ?? .storage,
        "The networking save could not be confirmed. Keep its configuration backup and reopen the VM before retrying; the change may already be committed."
      )
    }
  }

  private static func failure(_ code: VMError.Code, _ message: String) -> VMError {
    VMError(
      code, message,
      recovery:
        "Use the stopped VM's networking settings. Shared mode takes effect on its next start.")
  }
}
