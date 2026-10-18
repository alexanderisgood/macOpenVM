// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

public struct LinuxBootArgumentsResult: Encodable, Sendable {
  public let configuration: VMConfiguration
  public let changed: Bool
  public let backupFile: String?
}

package protocol LinuxBootArgumentsStore: Sendable {
  func readMetadata(at url: URL, limit: Int) async throws -> Data
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage
  func inspectWritableFile(at url: URL) async throws -> DiskUsage
  func inspectLinuxBootImage(at url: URL, maximumBytes: Int64) async throws
  func commitLinuxKernelArguments(
    in directory: URL, vmID: UUID, original: Data, replacement: Data,
    backupID: UUID, lock: VMLock
  ) async throws -> String
}

extension VMFiles: LinuxBootArgumentsStore {}

/// Stopped direct-kernel Linux settings; selection does not prove a bootable root.
public struct LinuxBootArguments: Sendable {
  private let files: any LinuxBootArgumentsStore
  private let backupID: @Sendable () -> UUID
  public init() {
    files = VMFiles()
    backupID = { UUID() }
  }
  package init(
    files: any LinuxBootArgumentsStore, backupID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.files = files
    self.backupID = backupID
  }

  public func update(
    in directory: URL, to arguments: String, kernel: URL? = nil,
    initialRamdisk: URL? = nil, host: HostResources = .current
  )
    async throws -> LinuxBootArgumentsResult
  {
    do {
      return try await updateOwned(
        in: directory, to: arguments, kernel: kernel, initialRamdisk: initialRamdisk, host: host)
    } catch {
      if error is CancellationError { throw CancellationError() }
      let code = (error as? VMError)?.code ?? .storage
      throw VMError(
        code, "The Linux boot-settings change could not be confirmed.",
        recovery:
          "Preserve configuration and its backup. Inspect actual state before another action; replacement may already be committed. No rollback or retry is automatic."
      )
    }
  }

  private func updateOwned(
    in directory: URL, to arguments: String, kernel: URL?, initialRamdisk: URL?, host: HostResources
  )
    async throws -> LinuxBootArgumentsResult
  {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), directory.path.utf8.count <= 4096,
      !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      directory.query == nil, directory.fragment == nil,
      arguments.utf8.count <= 4096, !arguments.contains("\0"),
      (kernel == nil) == (initialRamdisk == nil)
    else { throw invalid() }
    if let kernel, let initialRamdisk {
      guard isLocalImage(kernel), isLocalImage(initialRamdisk) else { throw invalid() }
    }
    try Task.checkCancellation()
    let registration = directory.appendingPathComponent("configuration.json")
    let observed = try StrictConfigurationDocument(
      await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes))
    let lock = try VMLock(directory: directory, expectedVMID: observed.configuration.id)
    defer { withExtendedLifetime(lock) {} }
    _ = try await files.inspectWritableConfiguration(at: registration)
    let original = try StrictConfigurationDocument(
      await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes))
    guard lock.owns(directory), original.configuration.id == observed.configuration.id else {
      throw VMError(
        .busy, "VM ownership or identity changed.",
        recovery: "Preserve the current registration and inspect it.")
    }
    guard original.configuration.guest == .linux, original.configuration.backend == .appleVz,
      original.configuration.boot == .linuxKernel
    else { throw invalid() }
    try ConfigurationValidator.validate(original.configuration, host: host)
    let disk = try await files.inspectWritableFile(
      at: directory.appendingPathComponent(original.configuration.diskFile))
    guard disk.virtualBytes == original.configuration.diskBytes else { throw invalid() }
    let replacement: StrictConfigurationDocument
    if let kernel, let initialRamdisk {
      try await files.inspectLinuxBootImage(at: kernel, maximumBytes: 128 * 1_048_576)
      try await files.inspectLinuxBootImage(at: initialRamdisk, maximumBytes: 512 * 1_048_576)
      replacement = try original.replacingBootSelection(
        kernel: kernel.path, initialRamdisk: initialRamdisk.path, arguments: arguments)
    } else {
      replacement = try original.replacingKernelArguments(with: arguments)
    }
    try Task.checkCancellation()
    if replacement.configuration == original.configuration {
      return .init(configuration: original.configuration, changed: false, backupFile: nil)
    }
    try ConfigurationValidator.validate(replacement.configuration, host: host)
    try Task.checkCancellation()
    let transaction = backupID()
    let backup = try await files.commitLinuxKernelArguments(
      in: directory, vmID: original.configuration.id, original: original.bytes,
      replacement: replacement.bytes, backupID: transaction, lock: lock)
    guard backup == "configuration-boot-backup-\(transaction.uuidString).json", lock.owns(directory)
    else { throw invalid() }
    return .init(configuration: replacement.configuration, changed: true, backupFile: backup)
  }

  private func invalid() -> VMError {
    VMError(
      .invalidConfiguration, "Invalid direct-kernel Linux boot settings.",
      recovery: "Inspect the stopped VM and its selected boot mode.")
  }

  private func isLocalImage(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && url.path.hasPrefix("/") && url.path.utf8.count <= 4096
      && !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}
