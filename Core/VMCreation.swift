// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

/// Shared CLI/desktop creation transaction. Failure preserves an incomplete new directory for inspection.
@MainActor public struct VMCreation {
  private let files: VMFiles
  public init(files: VMFiles = VMFiles()) { self.files = files }

  public func create(
    _ configuration: VMConfiguration, at directory: URL,
    platform: any VMCreationPlatform, host: HostResources = .current
  ) async throws {
    let c = configuration
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"),
      platform.backend == c.backend
    else {
      throw VMError(
        .invalidConfiguration, "Choose a local destination and matching backend.",
        recovery: "Create a new VM in a writable folder.")
    }
    try ConfigurationValidator.validate(c, host: host)
    try platform.validateHost(for: c)
    guard c.installationMedia != nil || c.kernel != nil else {
      throw VMError(
        .invalidConfiguration, "Installation media is required for a new VM.",
        recovery: "Select a lawfully obtained ARM64 image or kernel.")
    }
    for path in [c.installationMedia, c.kernel, c.initialRamdisk].compactMap({ $0 }) {
      let usage = try await files.inspectDisk(at: URL(fileURLWithPath: path))
      guard usage.virtualBytes > 0 else {
        throw VMError(
          .invalidConfiguration, "Selected media is empty.",
          recovery: "Choose a readable regular ARM64 installation file.")
      }
    }
    if let support = c.supportMedia {
      _ = try await files.inspectReadOnlyImage(at: URL(fileURLWithPath: support))
    }
    try await files.checkFreeSpace(at: directory.deletingLastPathComponent())
    try Task.checkCancellation()
    try await files.createDirectory(directory)
    let lock = try VMLock(directory: directory, expectedVMID: c.id)
    defer { withExtendedLifetime(lock) {} }
    try await files.createSparseDisk(
      at: directory.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
    let identities = try platform.createIdentity(for: c, in: directory)
    try validateCreatedPlatformIdentity(identities, diskFile: c.diskFile)
    guard lock.owns(directory) else { throw invalidCreatedPlatformIdentity() }
    for filename in identities.files {
      try await files.syncRegularFile(at: directory.appendingPathComponent(filename))
      guard lock.owns(directory) else { throw invalidCreatedPlatformIdentity() }
    }
    for name in identities.emptyPrivateDirectories {
      try await files.syncPrivateEmptyDirectory(in: directory, relativeName: name, lock: lock)
    }
    try Task.checkCancellation()
    guard lock.owns(directory) else { throw invalidCreatedPlatformIdentity() }
    // The configuration is the registration commit; identity and disk must be flushed first.
    try await files.atomicWrite(
      ConfigurationCodec.encode(c), at: directory.appendingPathComponent("configuration.json"))
  }
}

/// One direct namespace shared by files and directories; bookkeeping cannot become identity.
package func validateCreatedPlatformIdentity(
  _ identity: CreatedPlatformIdentity, diskFile: String
) throws {
  let names = identity.files + identity.emptyPrivateDirectories
  let folded = names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
  let reserved = Set([
    diskFile.precomposedStringWithCanonicalMapping.lowercased(), "configuration.json",
    "writer.lock",
    "runtime.json", "runtime-intent.json", "disk-growth-intent.json",
  ])
  let prefixes = [
    "runtime-", ".runtime-intent-", "disk-growth-", ".disk-growth-", "configuration-", ".metadata-",
  ]
  guard !names.isEmpty, names.count <= 8, Set(folded).count == names.count,
    names.allSatisfy({
      ConfigurationValidator.isSafeComponent($0)
        && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }),
    folded.allSatisfy({ name in
      !reserved.contains(name) && !prefixes.contains(where: { name.hasPrefix($0) })
    })
  else { throw invalidCreatedPlatformIdentity() }
}

private func invalidCreatedPlatformIdentity() -> VMError {
  VMError(
    .backendFailure, "Platform identity entries are invalid or writer ownership changed.",
    recovery: "Preserve the incomplete new VM and inspect the backend.")
}
