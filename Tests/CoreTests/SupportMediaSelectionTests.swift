// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

private let selectionHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
private let selectionProtected = ["disk.raw", "machine-identity.bin", "efi-variables.bin"]

private struct SelectionFixture {
  let root: URL
  let directory: URL
  let support: URL
  let original: Data
  let configuration: VMConfiguration
  var registration: URL { directory.appendingPathComponent("configuration.json") }
}

private func selectionFixture(attached: Bool = true) async throws -> SelectionFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-support-selection-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let directory = root.appendingPathComponent("fixture.macopenvm")
  let files = VMFiles()
  try await files.createDirectory(directory)
  let installer = root.appendingPathComponent("installer.iso")
  let support = root.appendingPathComponent("support-data.iso")
  // Regular synthetic data, with no filesystem, architecture or guest compatibility claim.
  try Data(repeating: 0x11, count: 1024).write(to: installer)
  try Data(repeating: 0x22, count: 1024).write(to: support)
  var configuration = VMConfiguration(
    name: "media-selection-fixture", guest: .linux, backend: .appleVz,
    memoryBytes: 2 * 1_073_741_824, diskBytes: 1_073_741_824)
  configuration.installationMedia = installer.path
  configuration.supportMedia = attached ? support.path : nil
  configuration.kernel = "/fixture-kernel"
  configuration.initialRamdisk = "/fixture-initrd"
  configuration.kernelArguments = "console=hvc0 preserve-original-arguments"
  var original = try ConfigurationCodec.encode(configuration)
  original.append(Data("\n\n".utf8))
  try await files.atomicWrite(original, at: directory.appendingPathComponent("configuration.json"))
  try await files.createSparseDisk(
    at: directory.appendingPathComponent("disk.raw"), bytes: configuration.diskBytes)
  for name in selectionProtected.dropFirst() {
    try await files.writeNewMetadata(
      Data("preserve synthetic \(name)".utf8), at: directory.appendingPathComponent(name))
  }
  let lock = try VMLock(directory: directory, expectedVMID: configuration.id)
  withExtendedLifetime(lock) {}
  return SelectionFixture(
    root: root, directory: directory, support: support, original: original,
    configuration: configuration)
}

private struct SelectionStamp: Equatable {
  let device: Int32
  let inode: UInt64
  let mode: mode_t
  let owner: uid_t
  let links: UInt16
  let size: Int64
  let allocated: Int64
  let modifiedSeconds: Int64
  let modifiedNanos: Int64
  let changedSeconds: Int64
  let changedNanos: Int64
  let samples: Data
}

private func selectionSnapshot(_ directory: URL, names: [String]? = nil) throws
  -> [String: SelectionStamp]
{
  var values: [String: SelectionStamp] = [:]
  for name in try names ?? FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let path = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var samples = Data(count: Int(min(info.st_size, 4096)))
    let count = samples.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
    if info.st_size > 4096 {
      var tail = Data(count: 512)
      let tailCount = tail.withUnsafeMutableBytes {
        pread(fd, $0.baseAddress, $0.count, info.st_size - 512)
      }
      if tailCount == tail.count {
        samples.append(tail)
      } else {
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
    close(fd)
    guard count == Int(min(info.st_size, 4096)) else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    values[name] = SelectionStamp(
      device: info.st_dev, inode: info.st_ino, mode: info.st_mode, owner: info.st_uid,
      links: info.st_nlink, size: info.st_size, allocated: info.st_blocks,
      modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
      changedSeconds: Int64(info.st_ctimespec.tv_sec),
      changedNanos: Int64(info.st_ctimespec.tv_nsec),
      samples: samples)
  }
  return values
}

private func selectionBackups(_ directory: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasPrefix("configuration-support-media-backup-") }.sorted()
}

private func selectionOtherFields(_ data: Data) throws -> NSDictionary {
  var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  fields.removeValue(forKey: "supportMedia")
  return fields as NSDictionary
}

@Test func stoppedSupportDetachPreservesInstallerIdentityAndExactBackup() async throws {
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try selectionSnapshot(fixture.directory, names: selectionProtected)
  let support = try Data(contentsOf: fixture.support)
  let result = try await InstallationMedia().updateSupport(
    in: fixture.directory, to: nil, host: selectionHost)
  var expected = fixture.configuration
  expected.supportMedia = nil
  #expect(result.changed && result.configuration == expected)
  let backup = try #require(result.backupFile)
  #expect(backup.hasPrefix("configuration-support-media-backup-"))
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(backup)) == fixture.original)
  let backupInfo = try #require(try selectionSnapshot(fixture.directory)[backup])
  #expect(
    backupInfo.mode & 0o7777 == 0o600 && backupInfo.owner == geteuid() && backupInfo.links == 1)
  let current = try Data(contentsOf: fixture.registration)
  #expect(try ConfigurationCodec.decode(current) == expected)
  #expect(try selectionOtherFields(current) == selectionOtherFields(fixture.original))
  #expect(try selectionSnapshot(fixture.directory, names: selectionProtected) == protected)
  #expect(try Data(contentsOf: fixture.support) == support)
}

@Test func stoppedSupportAttachLeavesInstallerAndOtherSelectionsUnchanged() async throws {
  let fixture = try await selectionFixture(attached: false)
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try selectionSnapshot(fixture.directory, names: selectionProtected)
  let result = try await InstallationMedia().updateSupport(
    in: fixture.directory, to: fixture.support, host: selectionHost)
  var expected = fixture.configuration
  expected.supportMedia = fixture.support.path
  let backup = try #require(result.backupFile)
  #expect(result.changed && result.configuration == expected)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(backup)) == fixture.original)
  let current = try Data(contentsOf: fixture.registration)
  #expect(try selectionOtherFields(current) == selectionOtherFields(fixture.original))
  #expect(try selectionSnapshot(fixture.directory, names: selectionProtected) == protected)
}

@Test(arguments: [false, true])
func stoppedSupportNoOpPreservesOriginalFormattingAndCreatesNoBackup(_ attached: Bool) async throws
{
  let fixture = try await selectionFixture(attached: attached)
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try selectionSnapshot(fixture.directory)
  let result = try await InstallationMedia().updateSupport(
    in: fixture.directory, to: attached ? fixture.support : nil, host: selectionHost)
  #expect(
    !result.changed && result.backupFile == nil && result.configuration == fixture.configuration)
  #expect(try selectionSnapshot(fixture.directory) == before)
}

@Test func stoppedSupportRejectsActualCooperatingWriter() async throws {
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let before = try selectionSnapshot(fixture.directory)
  do {
    _ = try await InstallationMedia().updateSupport(
      in: fixture.directory, to: nil, host: selectionHost)
    Issue.record("A live cooperating writer admitted support detachment.")
  } catch let error as VMError { #expect(error.code == .busy) }
  #expect(try selectionSnapshot(fixture.directory) == before)
  withExtendedLifetime(owner) {}
}

private func leaveSelectionUnsettled(_ fixture: SelectionFixture) async throws {
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let permit = try await VMFiles().beginRuntimeSession(
    in: fixture.directory, forVMID: fixture.configuration.id, lock: owner)
  withExtendedLifetime(permit) {}
}

@Test func stoppedSupportUnsettledIntentStillRejectsAfterKernelLeaseRelease() async throws {
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try await leaveSelectionUnsettled(fixture)
  let before = try selectionSnapshot(fixture.directory)
  do {
    _ = try await InstallationMedia().updateSupport(
      in: fixture.directory, to: nil, host: selectionHost)
    Issue.record("A persisted unsettled session admitted support detachment.")
  } catch let error as VMError { #expect(error.code == .busy) }
  #expect(try selectionSnapshot(fixture.directory) == before)
}

@Test(arguments: ["missing", "empty", "unaligned", "directory", "symlink", "fifo"])
func stoppedSupportRejectsInvalidImageWithoutMetadataMutation(_ kind: String) async throws {
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let invalid = fixture.root.appendingPathComponent("invalid-support")
  switch kind {
  case "empty": try Data().write(to: invalid)
  case "unaligned": try Data(repeating: 1, count: 513).write(to: invalid)
  case "directory":
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
  case "symlink":
    try FileManager.default.createSymbolicLink(at: invalid, withDestinationURL: fixture.support)
  case "fifo": #expect(mkfifo(invalid.path, 0o600) == 0)
  default: break
  }
  let before = try selectionSnapshot(fixture.directory)
  await #expect(throws: VMError.self) {
    try await InstallationMedia().updateSupport(
      in: fixture.directory, to: invalid, host: selectionHost)
  }
  #expect(try selectionSnapshot(fixture.directory) == before)
  #expect(try selectionBackups(fixture.directory).isEmpty)
}

@Test(arguments: ["remote", "relative", "control", "query", "oversize"])
func stoppedSupportRejectsUnsafeLocationsWithoutDisclosingThem(_ kind: String) async throws {
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let sentinel = "private-support-selection-sentinel"
  let url: URL
  switch kind {
  case "remote": url = try #require(URL(string: "https://example.invalid/" + sentinel))
  case "relative": url = try #require(URL(string: sentinel))
  case "control": url = URL(fileURLWithPath: "/" + sentinel + "\n")
  case "query": url = try #require(URL(string: "file:///" + sentinel + "?private=1"))
  default: url = URL(fileURLWithPath: "/" + sentinel + String(repeating: "a", count: 4096))
  }
  let before = try selectionSnapshot(fixture.directory)
  do {
    _ = try await InstallationMedia().updateSupport(
      in: fixture.directory, to: url, host: selectionHost)
    Issue.record("Unsafe support selection passed.")
  } catch let error as VMError {
    #expect(error.code == .invalidConfiguration)
    #expect(!(error.message + error.recovery).contains(sentinel))
  }
  #expect(try selectionSnapshot(fixture.directory) == before)
}

private actor SelectionFaultStore: InstallationMediaStore {
  enum Fault: Sendable {
    case partialBackup, incompleteBackup, mismatchedCommit, afterCommit, pauseAfterBackup
  }
  private let files = VMFiles()
  private let fault: Fault
  private var ready = false
  private var readyWaiter: CheckedContinuation<Void, Never>?
  private var resumeWaiter: CheckedContinuation<Void, Never>?
  init(_ fault: Fault) { self.fault = fault }
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableConfiguration(at: url)
  }
  func inspectDisk(at url: URL) async throws -> DiskUsage { try await files.inspectDisk(at: url) }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    if fault == .partialBackup || fault == .incompleteBackup {
      try await files.writeNewMetadata(Data(data.prefix(7)), at: url)
      if fault == .partialBackup { throw injected() }
      return
    }
    try await files.writeNewMetadata(data, at: url)
    if fault == .pauseAfterBackup {
      await withCheckedContinuation { continuation in
        resumeWaiter = continuation
        ready = true
        readyWaiter?.resume()
        readyWaiter = nil
      }
    }
  }
  func commitInstallationConfiguration(_ data: Data, at url: URL) async throws {
    if fault == .mismatchedCommit {
      var changed = try ConfigurationCodec.decode(data)
      changed.name = "independently changed fixture metadata"
      try await files.commitInstallationConfiguration(ConfigurationCodec.encode(changed), at: url)
    } else {
      try await files.commitInstallationConfiguration(data, at: url)
    }
    if fault == .afterCommit { throw injected() }
  }
  func waitUntilBackup() async {
    if ready { return }
    await withCheckedContinuation { readyWaiter = $0 }
  }
  func resumeBackup() {
    resumeWaiter?.resume()
    resumeWaiter = nil
  }
  private func injected() -> VMError {
    VMError(.storage, "private-support-fault-sentinel", recovery: "fixture only")
  }
}

@Test(arguments: ["partialBackup", "incompleteBackup", "mismatchedCommit", "afterCommit"])
func stoppedSupportBackupAndReadbackFaultsNeverReportSuccessOrRollback(_ kind: String) async throws
{
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try selectionSnapshot(fixture.directory, names: selectionProtected)
  let fault: SelectionFaultStore.Fault
  switch kind {
  case "partialBackup": fault = .partialBackup
  case "incompleteBackup": fault = .incompleteBackup
  case "mismatchedCommit": fault = .mismatchedCommit
  default: fault = .afterCommit
  }
  do {
    _ = try await InstallationMedia(files: SelectionFaultStore(fault)).updateSupport(
      in: fixture.directory, to: nil, host: selectionHost)
    Issue.record("Unconfirmed backup or replacement reported success.")
  } catch let error as VMError {
    #expect(error.code == .storage)
    #expect(!(error.message + error.recovery).contains("private-support-fault-sentinel"))
    #expect(error.recovery.contains("replacement may already be committed"))
  }
  let backups = try selectionBackups(fixture.directory)
  #expect(backups.count == 1)
  let backup = try #require(backups.first)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(backup))
      == (kind.hasSuffix("Backup") ? Data(fixture.original.prefix(7)) : fixture.original))
  if kind.hasSuffix("Backup") {
    #expect(try Data(contentsOf: fixture.registration) == fixture.original)
  } else {
    let current = try ConfigurationCodec.decode(Data(contentsOf: fixture.registration))
    #expect(current.supportMedia == nil)
    #expect(
      current.name
        == (kind == "mismatchedCommit"
          ? "independently changed fixture metadata" : fixture.configuration.name))
  }
  #expect(try selectionSnapshot(fixture.directory, names: selectionProtected) == protected)
  let next = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  withExtendedLifetime(next) {}
}

@Test func stoppedSupportBackupCollisionNeverOverwritesExistingEvidence() async throws {
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let backupID = UUID()
  let path = fixture.directory.appendingPathComponent(
    "configuration-support-media-backup-\(backupID.uuidString.lowercased()).json")
  try await VMFiles().writeNewMetadata(Data("existing exact evidence".utf8), at: path)
  let before = try selectionSnapshot(fixture.directory)
  await #expect(throws: VMError.self) {
    try await InstallationMedia(newBackupID: { backupID }).updateSupport(
      in: fixture.directory, to: nil, host: selectionHost)
  }
  #expect(try selectionSnapshot(fixture.directory) == before)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stoppedSupportCancellationAfterBackupRetainsOriginalAndReleasesOnlySettledCall() async throws {
  let fixture = try await selectionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try selectionSnapshot(fixture.directory, names: selectionProtected)
  let store = SelectionFaultStore(.pauseAfterBackup)
  let task = Task {
    try await InstallationMedia(files: store).updateSupport(
      in: fixture.directory, to: nil, host: selectionHost)
  }
  await store.waitUntilBackup()
  task.cancel()
  await store.resumeBackup()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(try Data(contentsOf: fixture.registration) == fixture.original)
  let backup = try #require(try selectionBackups(fixture.directory).first)
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent(backup)) == fixture.original)
  #expect(try selectionSnapshot(fixture.directory, names: selectionProtected) == protected)
  let next = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  withExtendedLifetime(next) {}
}
