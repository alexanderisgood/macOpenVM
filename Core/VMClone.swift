// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

public struct VMCloneResult: Encodable, Sendable {
  public let sourceVMID: UUID
  public let configuration: VMConfiguration
  public let disk: DiskUsage
}

/// A stopped Linux copy transaction. Guest account files remain on the copied disk;
/// new host/platform identity does not imply guest credential regeneration.
@MainActor public struct VMClone {
  private let files: VMFiles
  public init(files: VMFiles = VMFiles()) { self.files = files }

  public func copy(
    from source: URL, to destination: URL, name: String,
    platform: any VMCreationPlatform, host: HostResources = .current,
    expected: VMConfiguration? = nil
  ) async throws -> VMCloneResult {
    try Self.validateLocations(source, destination)
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard ConfigurationValidator.isSafeComponent(cleanName) else {
      throw Self.failure(.invalidConfiguration, "Choose a copy name without path separators.")
    }
    try Task.checkCancellation()
    let registrationURL = source.appendingPathComponent("configuration.json")
    let original = try StrictConfigurationDocument(
      await files.readMetadata(at: registrationURL, limit: ConfigurationCodec.maximumBytes))
    let c = original.configuration
    guard expected == nil || expected == c else {
      throw Self.failure(.staleOperation, "The selected source VM changed before copying.")
    }
    guard c.guest == .linux, c.backend == .appleVz, platform.backend == c.backend else {
      throw Self.failure(.unsupported, "Stopped copying currently requires a native Linux VM.")
    }
    try VMFiles.validateCloneDiskName(c.diskFile)
    try ConfigurationValidator.validate(c, host: host)
    try platform.validateHost(for: c)
    let sourceLock = try VMLock(directory: source, expectedVMID: c.id)
    defer { withExtendedLifetime(sourceLock) {} }
    guard
      try await files.readMetadata(at: registrationURL, limit: ConfigurationCodec.maximumBytes)
        == original.bytes
    else { throw Self.failure(.staleOperation, "The source registration changed.") }
    let usage = try await files.inspectWritableFile(at: source.appendingPathComponent(c.diskFile))
    guard usage.virtualBytes == c.diskBytes else {
      throw Self.failure(.corruptMetadata, "Source disk length does not match its registration.")
    }
    let history = try await stoppedHistory(in: source, configuration: c, usage: usage)
    let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
    for path in [c.installationMedia, c.supportMedia, c.kernel, c.initialRamdisk].compactMap({ $0 })
    {
      let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
      guard resolved != resolvedSource, !resolved.hasPrefix(resolvedSource + "/") else {
        throw Self.failure(
          .unsupported,
          "Move VM-contained boot media to a shared read-only location before copying.")
      }
      _ = try await files.inspectDisk(at: URL(fileURLWithPath: path))
    }
    var copy = VMConfiguration(
      name: cleanName, guest: c.guest, backend: c.backend, cpuCount: c.cpuCount,
      memoryBytes: c.memoryBytes, diskBytes: c.diskBytes)
    copy.architecture = c.architecture
    copy.diskFile = c.diskFile
    copy.boot = c.boot
    copy.installationMedia = c.installationMedia
    copy.supportMedia = c.supportMedia
    copy.kernel = c.kernel
    copy.initialRamdisk = c.initialRamdisk
    copy.kernelArguments = c.kernelArguments
    copy.network = .disconnected
    guard copy.id != c.id, copy.macAddress != c.macAddress else {
      throw Self.failure(.backendFailure, "A fresh copy identity could not be generated.")
    }
    try ConfigurationValidator.validate(copy, host: host)
    try await files.checkFreeSpace(at: destination.deletingLastPathComponent())
    try Task.checkCancellation()
    try await files.createDirectory(destination)
    let destinationLock = try VMLock(directory: destination, expectedVMID: copy.id)
    defer { withExtendedLifetime(destinationLock) {} }
    do {
      let disk = try await files.cloneStoppedDisk(
        from: source, to: destination, configuration: c, registration: original.bytes,
        history: history, destinationVMID: copy.id, sourceLock: sourceLock,
        destinationLock: destinationLock)
      try Task.checkCancellation()
      let identities = try platform.createIdentity(for: copy, in: destination)
      try validateCreatedPlatformIdentity(identities, diskFile: copy.diskFile)
      guard identities.emptyPrivateDirectories.isEmpty
      else { throw Self.failure(.backendFailure, "The new platform identity files are invalid.") }
      for identity in identities.files {
        try await files.syncRegularFile(at: destination.appendingPathComponent(identity))
      }
      try Task.checkCancellation()
      try await files.commitNewCloneConfiguration(
        ConfigurationCodec.encode(copy), from: source, to: destination, configuration: c,
        registration: original.bytes, history: history, sourceLock: sourceLock,
        destinationLock: destinationLock, destinationVMID: copy.id)
      return .init(sourceVMID: c.id, configuration: copy, disk: disk)
    } catch is CancellationError { throw CancellationError() } catch {
      throw Self.failure(
        (error as? VMError)?.code ?? .storage,
        "The VM copy could not be confirmed. Preserve its new folder and reopen it before retrying."
      )
    }
  }

  private func stoppedHistory(
    in source: URL, configuration: VMConfiguration, usage: DiskUsage
  ) async throws -> Data? {
    let intent = try await files.readRuntimeIntent(in: source)
    let url = source.appendingPathComponent("runtime.json")
    let status = await files.status(at: url)
    if status.kind == .missing {
      guard intent == nil, usage.allocatedBytes == 0 else {
        throw Self.failure(.busy, "A nonempty source requires a recorded normal guest stop.")
      }
      return nil
    }
    guard status.kind == .regular, status.links == 1, status.ownedByCurrentUser == true,
      status.otherWriteBits == false
    else { throw Self.failure(.corruptMetadata, "The source runtime record is unsafe.") }
    let bytes = try await files.readMetadata(at: url, limit: RuntimeHistoryCodec.maximumBytes)
    let record = try RuntimeHistoryCodec.decode(bytes)
    guard try RuntimeHistoryCodec.encode(record) == bytes,
      record.snapshot.outcome == .guestStopped
    else {
      throw Self.failure(.busy, "The source has no matching recorded normal guest stop.")
    }
    if let intent {
      guard intent.state == .settled, intent.vmID == configuration.id,
        intent.sessionID == record.sessionID
      else { throw Self.failure(.busy, "The source ownership and stop records do not match.") }
    }
    return bytes
  }

  private static func validateLocations(_ source: URL, _ destination: URL) throws {
    for url in [source, destination] {
      guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
        url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
        url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
        url.standardizedFileURL.path == url.path,
        !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw failure(.invalidConfiguration, "Choose normalized local VM folders.") }
    }
    let first = source.resolvingSymlinksInPath().standardizedFileURL.path
    let second = destination.resolvingSymlinksInPath().standardizedFileURL.path
    guard first != second, !second.hasPrefix(first + "/"), !first.hasPrefix(second + "/") else {
      throw failure(.invalidConfiguration, "Choose a separate new folder for the VM copy.")
    }
  }

  private static func failure(_ code: VMError.Code, _ message: String) -> VMError {
    VMError(
      code, message,
      recovery:
        "Preserve the source VM. Shut it down normally and choose a new private folder on the same volume."
    )
  }
}
