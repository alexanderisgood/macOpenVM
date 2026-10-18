// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

private let mediaHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
private let preservedMediaFiles = ["disk.raw", "machine-identity.bin", "efi-variables.bin"]
private let interveningMediaMetadata = Data("preserve an intervening writer's metadata".utf8)

private struct MediaFixture {
  let root: URL
  let directory: URL
  let media: URL
  let replacement: URL
  let configuration: VMConfiguration
  let original: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
}

private func makeMediaFixture(attached: Bool = true) async throws -> MediaFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-media-\(UUID().uuidString)")
  let directory = root.appendingPathComponent("fixture.macopenvm")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let media = root.appendingPathComponent("fixture.iso")
  let replacement = root.appendingPathComponent("selected-file.dat")
  // These regular-file fixtures do not establish ISO structure or guest architecture.
  try Data("initial media fixture".utf8).write(to: media)
  try Data("replacement media fixture".utf8).write(to: replacement)
  var configuration = VMConfiguration(
    name: "fixture", guest: .linux, backend: .appleVz, memoryBytes: 2 * 1_073_741_824,
    diskBytes: 1_073_741_824)
  configuration.installationMedia = attached ? media.path : nil
  var original = try ConfigurationCodec.encode(configuration)
  original.append(Data("\n\n".utf8))
  let files = VMFiles()
  try await files.atomicWrite(
    original, at: directory.appendingPathComponent("configuration.json"))
  for name in preservedMediaFiles {
    try await files.writeNewMetadata(
      Data("preserve \(name) bytes and permissions".utf8),
      at: directory.appendingPathComponent(name))
  }
  // Account for the persistent lock before snapshots; no-op may acquire an existing lock.
  let owner = try VMLock(directory: directory)
  withExtendedLifetime(owner) {}
  return MediaFixture(
    root: root, directory: directory, media: media, replacement: replacement,
    configuration: configuration, original: original)
}

private struct MediaStamp: Equatable {
  let size: Int64
  let mode: mode_t
  let owner: uid_t
  let links: UInt16
  let modifiedSeconds: Int64
  let modifiedNanos: Int64
  let bytes: Data?
}

private func mediaSnapshot(_ directory: URL, names: [String]? = nil) throws -> [String: MediaStamp]
{
  var snapshot: [String: MediaStamp] = [:]
  for name in try names ?? FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let url = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let bytes =
      info.st_mode & S_IFMT == S_IFREG && info.st_size <= 131_072 ? try Data(contentsOf: url) : nil
    snapshot[name] = MediaStamp(
      size: info.st_size, mode: info.st_mode, owner: info.st_uid, links: info.st_nlink,
      modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanos: Int64(info.st_mtimespec.tv_nsec), bytes: bytes)
  }
  return snapshot
}

private func mediaBackups(_ directory: URL) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasPrefix("configuration-media-backup-") }
    .sorted().map { directory.appendingPathComponent($0) }
}

private func configurationFieldsExceptMedia(_ data: Data) throws -> NSDictionary {
  let decoded = try JSONSerialization.jsonObject(with: data)
  var fields = try #require(decoded as? [String: Any])
  fields.removeValue(forKey: "installationMedia")
  return fields as NSDictionary
}

@Test func installationMediaAttachDetachPreservesIdentityAndOriginalBytes() async throws {
  let fixture = try await makeMediaFixture(attached: false)
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try mediaSnapshot(fixture.directory, names: preservedMediaFiles)
  let result = try await InstallationMedia().update(
    in: fixture.directory, to: fixture.replacement, host: mediaHost)
  let backupFile = try #require(result.backupFile)
  let backup = fixture.directory.appendingPathComponent(backupFile)
  var expected = fixture.configuration
  expected.installationMedia = fixture.replacement.path
  #expect(result.changed && result.configuration == expected)
  #expect(try Data(contentsOf: backup) == fixture.original)
  let backupStamp = try #require(try mediaSnapshot(fixture.directory)[backupFile])
  #expect(backupStamp.mode & 0o7777 == 0o600)
  #expect(backupStamp.owner == geteuid() && backupStamp.links == 1)
  let attachedBytes = try Data(contentsOf: fixture.registration)
  #expect(
    try configurationFieldsExceptMedia(attachedBytes)
      == configurationFieldsExceptMedia(fixture.original))
  #expect(try ConfigurationCodec.decode(attachedBytes) == expected)

  let detached = try await InstallationMedia().update(
    in: fixture.directory, to: nil, host: mediaHost)
  let detachBackup = try #require(detached.backupFile)
  #expect(detached.changed && detached.configuration == fixture.configuration)
  #expect(detachBackup != backupFile)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(detachBackup)) == attachedBytes)
  #expect(try Data(contentsOf: backup) == fixture.original)
  #expect(try mediaBackups(fixture.directory).count == 2)
  #expect(try mediaSnapshot(fixture.directory, names: preservedMediaFiles) == protected)
}

@Test func installationMediaNoOpPreservesFormattingAndCreatesNoBackup() async throws {
  for attached in [true, false] {
    let fixture = try await makeMediaFixture(attached: attached)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try mediaSnapshot(fixture.directory)
    let result = try await InstallationMedia().update(
      in: fixture.directory, to: attached ? fixture.media : nil, host: mediaHost)
    #expect(!result.changed && result.backupFile == nil)
    #expect(result.configuration == fixture.configuration)
    #expect(try mediaSnapshot(fixture.directory) == before)
    #expect(try mediaBackups(fixture.directory).isEmpty)
  }
}

@Test func installationMediaRejectsActiveCooperatingOwnership() async throws {
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let owner = try VMLock(directory: fixture.directory)
  let before = try mediaSnapshot(fixture.directory)
  do {
    _ = try await InstallationMedia().update(
      in: fixture.directory, to: nil, host: mediaHost)
    Issue.record("A held writer lock must exclude metadata replacement")
  } catch let error as VMError { #expect(error.code == .busy) }
  #expect(try mediaSnapshot(fixture.directory) == before)
  withExtendedLifetime(owner) {}
}

@Test(.timeLimit(.minutes(1))) func installationMediaRejectsUnsafeRegistrationWithoutRepair()
  async throws
{
  for kind in [
    "missing", "fifo", "symlink", "hard-link", "group-write", "public-read", "read-only",
  ] {
    let fixture = try await makeMediaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    switch kind {
    case "missing": try FileManager.default.removeItem(at: fixture.registration)
    case "fifo":
      try FileManager.default.removeItem(at: fixture.registration)
      #expect(mkfifo(fixture.registration.path, 0o600) == 0)
    case "symlink":
      let target = fixture.directory.appendingPathComponent("original.json")
      try FileManager.default.moveItem(at: fixture.registration, to: target)
      try FileManager.default.createSymbolicLink(
        at: fixture.registration, withDestinationURL: target)
    case "hard-link":
      #expect(
        link(fixture.registration.path, fixture.directory.appendingPathComponent("alias.json").path)
          == 0)
    case "group-write": #expect(chmod(fixture.registration.path, 0o660) == 0)
    case "public-read": #expect(chmod(fixture.registration.path, 0o644) == 0)
    default: #expect(chmod(fixture.registration.path, 0o400) == 0)
    }
    let before = try mediaSnapshot(fixture.directory)
    await #expect(throws: VMError.self) {
      try await InstallationMedia().update(
        in: fixture.directory, to: nil, host: mediaHost)
    }
    #expect(try mediaSnapshot(fixture.directory) == before)
    #expect(try mediaBackups(fixture.directory).isEmpty)
  }
}

@Test(.timeLimit(.minutes(1))) func installationMediaRejectsUnavailableAndSpecialSelection()
  async throws
{
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let empty = fixture.root.appendingPathComponent("empty.iso")
  try Data().write(to: empty)
  let fifo = fixture.root.appendingPathComponent("fifo.iso")
  #expect(mkfifo(fifo.path, 0o600) == 0)
  let symlink = fixture.root.appendingPathComponent("symlink.iso")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.media)
  let selected = [
    fixture.root.appendingPathComponent("missing.iso"), empty, fifo, symlink, fixture.root,
  ]
  let before = try mediaSnapshot(fixture.directory)
  for media in selected {
    await #expect(throws: VMError.self) {
      try await InstallationMedia().update(
        in: fixture.directory, to: media, host: mediaHost)
    }
    #expect(try mediaSnapshot(fixture.directory) == before)
  }
  #expect(try mediaBackups(fixture.directory).isEmpty)
}

@Test func installationMediaRejectsUnknownCorruptAndUnsafeConfiguration() async throws {
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let decoded = try JSONSerialization.jsonObject(with: fixture.original)
  let originalObject = try #require(decoded as? [String: Any])
  var future = originalObject
  future["schemaVersion"] = 2
  var extensionObject = originalObject
  extensionObject["futureExtensions"] = ["important-state": ["must-be-preserved": true]]
  var invalidHardware = originalObject
  invalidHardware["cpuCount"] = 999
  var unsafeDisk = originalObject
  unsafeDisk["diskFile"] = "../outside.raw"
  let malformed =
    try [future, extensionObject, invalidHardware, unsafeDisk].map {
      try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
    } + [Data("{broken".utf8), Data(repeating: 0, count: ConfigurationCodec.maximumBytes + 1)]
  for bytes in malformed {
    try bytes.write(to: fixture.registration)
    let before = try mediaSnapshot(fixture.directory)
    await #expect(throws: VMError.self) {
      try await InstallationMedia().update(
        in: fixture.directory, to: fixture.replacement, host: mediaHost)
    }
    #expect(try mediaSnapshot(fixture.directory) == before)
    #expect(try mediaBackups(fixture.directory).isEmpty)
  }
}

@Test func installationMediaLocationPolicyIsLocalAndDoesNotInferFileArchitecture() async throws {
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try mediaSnapshot(fixture.directory)
  let invalid = try [
    "https://example.invalid/media.iso", "file://remote.invalid/media.iso", "relative.iso",
    "file:///invalid%00media.iso",
  ].map { try #require(URL(string: $0)) }
  for url in invalid {
    await #expect(throws: VMError.self) {
      try await InstallationMedia().update(in: fixture.directory, to: url, host: mediaHost)
    }
    await #expect(throws: VMError.self) {
      try await InstallationMedia().update(in: url, to: nil, host: mediaHost)
    }
    #expect(try mediaSnapshot(fixture.directory) == before)
  }
  let alias = fixture.root.appendingPathComponent("vm-alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
  await #expect(throws: VMError.self) {
    try await InstallationMedia().update(in: alias, to: nil, host: mediaHost)
  }
  var local = URLComponents()
  local.scheme = "file"
  local.host = "localhost"
  local.path = fixture.replacement.path
  let localMedia = try #require(local.url)
  let result = try await InstallationMedia().update(
    in: fixture.directory, to: localMedia, host: mediaHost)
  #expect(result.configuration.installationMedia == fixture.replacement.path)
  #expect(result.changed)
  #expect(result.configuration.architecture == fixture.configuration.architecture)
}

@Test func installationMediaRejectsAmbiguousDuplicateKeysAndPreservesOriginal() async throws {
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  for duplicate in [
    #""installationMedia": "/different-file.iso","#,
    #""\u0069nstallationMedia": null,"#,
    #""schemaVersion": 1,"#,
  ] {
    var ambiguous = Data("{\(duplicate)".utf8)
    ambiguous.append(fixture.original.dropFirst())
    try ambiguous.write(to: fixture.registration)
    let before = try mediaSnapshot(fixture.directory)
    do {
      _ = try await InstallationMedia().update(
        in: fixture.directory, to: fixture.replacement, host: mediaHost)
      Issue.record("Ambiguous registration keys must not be silently collapsed")
    } catch let error as VMError { #expect(error.code == .corruptMetadata) }
    #expect(try mediaSnapshot(fixture.directory) == before)
    #expect(try mediaBackups(fixture.directory).isEmpty)
  }
}

@Test func installationMediaPermissionFailureAndBackupCollisionPreserveFiles() async throws {
  let fixture = try await makeMediaFixture()
  defer {
    _ = chmod(fixture.directory.path, 0o700)
    try? FileManager.default.removeItem(at: fixture.root)
  }
  #expect(chmod(fixture.directory.path, 0o500) == 0)
  let before = try mediaSnapshot(fixture.directory)
  await #expect(throws: VMError.self) {
    try await InstallationMedia().update(
      in: fixture.directory, to: fixture.replacement, host: mediaHost)
  }
  #expect(try mediaSnapshot(fixture.directory) == before)
  #expect(chmod(fixture.directory.path, 0o700) == 0)
  let backupID = UUID()
  let backup = fixture.directory.appendingPathComponent(
    "configuration-media-backup-\(backupID.uuidString.lowercased()).json")
  try await VMFiles().writeNewMetadata(Data("pre-existing archive".utf8), at: backup)
  let collisionBefore = try mediaSnapshot(fixture.directory)
  await #expect(throws: VMError.self) {
    try await InstallationMedia(newBackupID: { backupID }).update(
      in: fixture.directory, to: fixture.replacement, host: mediaHost)
  }
  #expect(try mediaSnapshot(fixture.directory) == collisionBefore)
}

private actor MediaFaultStore: InstallationMediaStore {
  enum Fault: Sendable {
    case freeSpace, backup, beforeRename, afterRename, pauseAfterBackup, changeAfterBackup
  }
  private let files = VMFiles()
  private let fault: Fault
  private var backupReady = false
  private var readyWaiter: CheckedContinuation<Void, Never>?
  private var resumeWaiter: CheckedContinuation<Void, Never>?
  init(_ fault: Fault) { self.fault = fault }

  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableConfiguration(at: url)
  }
  func inspectDisk(at url: URL) async throws -> DiskUsage {
    try await files.inspectDisk(at: url)
  }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    if fault == .freeSpace { throw injectedFault() }
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    if fault == .backup {
      try await files.writeNewMetadata(Data(data.prefix(7)), at: url)
      throw injectedFault()
    }
    try await files.writeNewMetadata(data, at: url)
    if fault == .changeAfterBackup {
      try await files.atomicWrite(
        interveningMediaMetadata,
        at: url.deletingLastPathComponent().appendingPathComponent("configuration.json"))
    }
    if fault == .pauseAfterBackup {
      await withCheckedContinuation { continuation in
        resumeWaiter = continuation
        backupReady = true
        readyWaiter?.resume()
        readyWaiter = nil
      }
    }
  }
  func commitInstallationConfiguration(_ data: Data, at url: URL) async throws {
    if fault == .beforeRename { throw injectedFault() }
    try await files.commitInstallationConfiguration(data, at: url)
    if fault == .afterRename { throw injectedFault() }
  }
  func waitUntilBackup() async {
    if backupReady { return }
    await withCheckedContinuation { readyWaiter = $0 }
  }
  func resumeBackup() {
    resumeWaiter?.resume()
    resumeWaiter = nil
  }
  private func injectedFault() -> VMError {
    VMError(.storage, "private-path-and-token-must-not-escape", recovery: "fixture only")
  }
}

@Test func installationMediaFaultsPreserveBackupAndDoNotGuessRollback() async throws {
  for fault in [MediaFaultStore.Fault.backup, .beforeRename, .afterRename] {
    let fixture = try await makeMediaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let protected = try mediaSnapshot(fixture.directory, names: preservedMediaFiles)
    do {
      _ = try await InstallationMedia(files: MediaFaultStore(fault)).update(
        in: fixture.directory, to: fixture.replacement, host: mediaHost)
      Issue.record("The injected storage failure must reach the caller")
    } catch let error as VMError {
      #expect(error.code == .storage)
      #expect(!error.errorDescription.orEmpty.contains("private-path-and-token-must-not-escape"))
      if fault != .backup {
        #expect(error.recovery.contains("replacement may already be committed"))
      }
    }
    let backups = try mediaBackups(fixture.directory)
    #expect(backups.count == 1)
    let backup = try #require(backups.first)
    #expect(
      try Data(contentsOf: backup)
        == (fault == .backup ? Data(fixture.original.prefix(7)) : fixture.original))
    if fault == .afterRename {
      let current = try ConfigurationCodec.decode(Data(contentsOf: fixture.registration))
      #expect(current.installationMedia == fixture.replacement.path)
    } else {
      #expect(try Data(contentsOf: fixture.registration) == fixture.original)
    }
    #expect(try mediaSnapshot(fixture.directory, names: preservedMediaFiles) == protected)
    let released = try VMLock(directory: fixture.directory)
    withExtendedLifetime(released) {}
  }
}

@Test func installationMediaFreeSpaceFailureDoesNotCreateBackup() async throws {
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try mediaSnapshot(fixture.directory)
  await #expect(throws: VMError.self) {
    try await InstallationMedia(files: MediaFaultStore(.freeSpace)).update(
      in: fixture.directory, to: fixture.replacement, host: mediaHost)
  }
  #expect(try mediaSnapshot(fixture.directory) == before)
}

@Test func installationMediaDoesNotOverwriteAnInterveningMetadataChange() async throws {
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try mediaSnapshot(fixture.directory, names: preservedMediaFiles)
  do {
    _ = try await InstallationMedia(files: MediaFaultStore(.changeAfterBackup)).update(
      in: fixture.directory, to: fixture.replacement, host: mediaHost)
    Issue.record("An intervening configuration change must prevent replacement")
  } catch let error as VMError { #expect(error.code == .busy) }
  #expect(try Data(contentsOf: fixture.registration) == interveningMediaMetadata)
  let backup = try #require(try mediaBackups(fixture.directory).first)
  #expect(try Data(contentsOf: backup) == fixture.original)
  #expect(try mediaSnapshot(fixture.directory, names: preservedMediaFiles) == protected)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func installationMediaCancellationBeforeCommitRetainsRegistrationAndBackup() async throws {
  let fixture = try await makeMediaFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try mediaSnapshot(fixture.directory)
  let early = Task {
    try await InstallationMedia().update(
      in: fixture.directory, to: fixture.replacement, host: mediaHost)
  }
  early.cancel()
  await #expect(throws: CancellationError.self) { try await early.value }
  #expect(try mediaSnapshot(fixture.directory) == before)

  let store = MediaFaultStore(.pauseAfterBackup)
  let updating = Task {
    try await InstallationMedia(files: store).update(
      in: fixture.directory, to: fixture.replacement, host: mediaHost)
  }
  await store.waitUntilBackup()
  updating.cancel()
  await store.resumeBackup()
  await #expect(throws: CancellationError.self) { try await updating.value }
  #expect(try Data(contentsOf: fixture.registration) == fixture.original)
  let backups = try mediaBackups(fixture.directory)
  #expect(backups.count == 1)
  let backup = try #require(backups.first)
  #expect(try Data(contentsOf: backup) == fixture.original)
  #expect(
    try mediaSnapshot(fixture.directory, names: preservedMediaFiles)
      == before.filter { preservedMediaFiles.contains($0.key) })
  let released = try VMLock(directory: fixture.directory)
  withExtendedLifetime(released) {}
}

extension Optional where Wrapped == String {
  fileprivate var orEmpty: String { self ?? "" }
}
