// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMCore
@testable import VMStorage

private let bootGiB: UInt64 = 1_073_741_824
private let bootHost = HostResources(cpuCount: 8, memoryBytes: 16 * bootGiB)
private let bootSeed = Data("original seeded disk bytes".utf8)
private let newBootArguments = "console=hvc0 root=UUID=11111111-2222-3333-4444-555555555555 ro"

private struct BootFixture {
  let directory: URL
  let configuration: VMConfiguration
  let original: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
  var disk: URL { directory.appendingPathComponent("disk.raw") }
}

private func bootFixture() async throws -> BootFixture {
  let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("macOpenVM-boot-arguments-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  var configuration = VMConfiguration(
    name: "private boot fixture", guest: .linux,
    backend: .appleVz, memoryBytes: 2 * bootGiB, diskBytes: bootGiB)
  configuration.boot = .linuxKernel
  configuration.kernel = "/synthetic/kernel-selection"
  configuration.initialRamdisk = "/synthetic/initramfs-selection"
  let original = try ConfigurationCodec.encode(configuration) + Data("\n \n".utf8)
  let files = VMFiles()
  try await files.writeNewMetadata(
    original, at: directory.appendingPathComponent("configuration.json"))
  try await files.createSparseDisk(at: directory.appendingPathComponent("disk.raw"), bytes: bootGiB)
  for name in ["machine-identity.bin", "efi-variables.bin"] {
    try await files.writeNewMetadata(
      Data("preserve \(name)".utf8), at: directory.appendingPathComponent(name))
  }
  let fd = open(directory.appendingPathComponent("disk.raw").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw bootFailure() }
  defer { close(fd) }
  #expect(bootSeed.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == bootSeed.count)
  #expect(fsync(fd) == 0)
  let owner = try VMLock(directory: directory, expectedVMID: configuration.id)
  withExtendedLifetime(owner) {}
  return .init(directory: directory, configuration: configuration, original: original)
}

private struct BootStamp: Equatable {
  let inode: UInt64
  let device: Int32
  let size: Int64
  let mode: mode_t
  let links: UInt16
  let modifiedSeconds: Int64
  let modifiedNanos: Int64
  let changedSeconds: Int64
  let changedNanos: Int64
  let content: Data
}

private func bootInventory(_ directory: URL, excluding names: Set<String> = []) throws
  -> [String: BootStamp]
{
  var result: [String: BootStamp] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    if names.contains(name) { continue }
    let path = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw bootFailure()
    }
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw bootFailure() }
    var content = Data(count: info.st_size < 65_536 ? Int(info.st_size) : bootSeed.count)
    let count = content.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
    close(fd)
    guard count == content.count else { throw bootFailure() }
    result[name] = .init(
      inode: info.st_ino, device: info.st_dev, size: info.st_size,
      mode: info.st_mode, links: info.st_nlink, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
      changedSeconds: Int64(info.st_ctimespec.tv_sec),
      changedNanos: Int64(info.st_ctimespec.tv_nsec), content: content)
  }
  return result
}

private func bootFailure() -> VMError {
  .init(.storage, "Synthetic private detail must not escape.", recovery: "Preserve the fixture.")
}

private func bootImages(_ fixture: BootFixture) async throws -> (kernel: URL, initialRamdisk: URL) {
  let kernel = fixture.directory.appendingPathComponent("selected-kernel.bin")
  let initialRamdisk = fixture.directory.appendingPathComponent("selected-initramfs.bin")
  for (url, content) in [
    (kernel, "synthetic kernel bytes"), (initialRamdisk, "synthetic initramfs bytes"),
  ] {
    try await VMFiles().writeNewMetadata(Data(content.utf8), at: url)
    #expect(chmod(url.path, 0o400) == 0)
  }
  return (kernel, initialRamdisk)
}

private func bootSelectionGolden(
  _ original: Data, configuration: VMConfiguration, kernel: URL, initialRamdisk: URL,
  arguments: String
) throws -> Data {
  var expected = original
  for (old, new) in [
    (try #require(configuration.kernel), kernel.path),
    (try #require(configuration.initialRamdisk), initialRamdisk.path),
    (configuration.kernelArguments, arguments),
  ] {
    let token = try JSONEncoder().encode(old)
    let range = try #require(expected.range(of: token))
    expected.replaceSubrange(range, with: try JSONEncoder().encode(new))
  }
  return expected
}

private actor FaultBootStore: LinuxBootArgumentsStore {
  let files = VMFiles()
  let fault: BootConfigurationFault
  init(_ fault: BootConfigurationFault) { self.fault = fault }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableConfiguration(at: url)
  }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func inspectLinuxBootImage(at url: URL, maximumBytes: Int64) async throws {
    try await files.inspectLinuxBootImage(at: url, maximumBytes: maximumBytes)
  }
  func commitLinuxKernelArguments(
    in directory: URL, vmID: UUID, original: Data,
    replacement: Data, backupID: UUID, lock: VMLock
  ) async throws -> String {
    try await files.commitLinuxKernelArguments(
      in: directory, vmID: vmID, original: original,
      replacement: replacement, backupID: backupID, lock: lock, fault: fault)
  }
}

private actor RereadBootStore: LinuxBootArgumentsStore {
  enum Mode { case identity, rename, cancel }
  let files = VMFiles()
  let mode: Mode
  private(set) var commits = 0
  private(set) var changedBytes: Data?
  init(_ mode: Mode) { self.mode = mode }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage {
    let usage = try await files.inspectWritableConfiguration(at: url)
    if mode == .cancel {
      withUnsafeCurrentTask { $0?.cancel() }
    } else {
      var current = try ConfigurationCodec.decode(await files.readMetadata(at: url))
      if mode == .identity { current.id = UUID() } else { current.name = "fresh reread name" }
      let bytes = try ConfigurationCodec.encode(current)
      try await files.atomicWrite(bytes, at: url)
      changedBytes = bytes
    }
    return usage
  }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func inspectLinuxBootImage(at url: URL, maximumBytes: Int64) async throws {
    try await files.inspectLinuxBootImage(at: url, maximumBytes: maximumBytes)
  }
  func commitLinuxKernelArguments(
    in directory: URL, vmID: UUID, original: Data,
    replacement: Data, backupID: UUID, lock: VMLock
  ) async throws -> String {
    commits += 1
    return try await files.commitLinuxKernelArguments(
      in: directory, vmID: vmID,
      original: original, replacement: replacement, backupID: backupID, lock: lock)
  }
}

@Test func linuxBootArgumentsExactStringTokenPreservesEscapesBOMAndOtherBytes() async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let text = String(decoding: fixture.original, as: UTF8.self)
    .replacingOccurrences(of: "\"kernelArguments\"", with: "\"\\u006bernelArguments\"")
  let original = Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)
  try await VMFiles().atomicWrite(original, at: fixture.registration)
  let document = try StrictConfigurationDocument(original)
  let target = try document.replacingKernelArguments(with: "console=hvc0 quoted=\"x\" path=/disk")
  let encoded = try JSONEncoder().encode("console=hvc0 quoted=\"x\" path=/disk")
  let expected = original.range(of: try JSONEncoder().encode(fixture.configuration.kernelArguments))
  var golden = original
  golden.replaceSubrange(try #require(expected), with: encoded)
  #expect(target.bytes == golden)
  let result = try await LinuxBootArguments().update(
    in: fixture.directory,
    to: target.configuration.kernelArguments, host: bootHost)
  #expect(result.changed && result.configuration == target.configuration)
  #expect(try Data(contentsOf: fixture.registration) == golden)
  let backup = try #require(result.backupFile)
  #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(backup)) == original)
}

@Test func linuxBootArgumentsPreserveActualDiskIdentityAndNoOpCreatesNothing() async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let before = try bootInventory(fixture.directory)
  let result = try await LinuxBootArguments().update(
    in: fixture.directory, to: newBootArguments, host: bootHost)
  var expected = fixture.configuration
  expected.kernelArguments = newBootArguments
  #expect(result.configuration == expected && result.changed)
  let after = try bootInventory(fixture.directory)
  for name in ["disk.raw", "machine-identity.bin", "efi-variables.bin", "writer.lock"] {
    #expect(before[name] == after[name])
  }
  let backup = try #require(result.backupFile)
  #expect(after[backup]?.content == fixture.original)
  #expect((after[backup]?.mode ?? 0) & 0o7777 == 0o600)
  let unchanged = try await LinuxBootArguments().update(
    in: fixture.directory, to: newBootArguments, host: bootHost)
  #expect(!unchanged.changed && unchanged.backupFile == nil)
  #expect(try bootInventory(fixture.directory) == after)
}

@Test(arguments: [BootConfigurationFault.afterBackup, .afterRename, .afterCommit])
func linuxBootArgumentFaultsPreserveBackupAndActualStateWithoutRollback(
  _ fault: BootConfigurationFault
) async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let before = try bootInventory(fixture.directory)
  do {
    _ = try await LinuxBootArguments(files: FaultBootStore(fault)).update(
      in: fixture.directory,
      to: newBootArguments, host: bootHost)
    Issue.record("Fault must not be reported as confirmed success")
  } catch let error as VMError {
    #expect(!error.localizedDescription.contains("Synthetic private detail"))
  }
  let after = try bootInventory(fixture.directory)
  let backups = after.filter { $0.key.hasPrefix("configuration-boot-backup-") }
  #expect(backups.count == 1 && backups.values.first?.content == fixture.original)
  for name in ["disk.raw", "machine-identity.bin", "efi-variables.bin"] {
    #expect(before[name] == after[name])
  }
  let current = try ConfigurationCodec.decode(Data(contentsOf: fixture.registration))
  #expect(
    current.kernelArguments
      == (fault == .afterBackup ? fixture.configuration.kernelArguments : newBootArguments))
}

@Test func linuxBootArgumentsRejectActiveRuntimeAndPendingGrowth() async throws {
  for kind in ["active", "runtime", "growth"] {
    let fixture = try await bootFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var held: VMLock?
    if kind == "active" {
      held = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    } else {
      let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
      let files = VMFiles()
      if kind == "runtime" {
        let permit = try await files.beginRuntimeSession(
          in: fixture.directory, forVMID: fixture.configuration.id, lock: owner)
        withExtendedLifetime(permit) {}
      } else {
        let target = try StrictConfigurationDocument(fixture.original).replacingDiskBytes(
          with: 2 * bootGiB)
        let permit = try await files.beginDiskGrowth(
          in: fixture.directory, vmID: fixture.configuration.id,
          diskFile: "disk.raw", oldBytes: bootGiB, targetBytes: 2 * bootGiB,
          originalConfiguration: fixture.original, replacementConfiguration: target.bytes,
          lock: owner)
        withExtendedLifetime(permit) {}
      }
      withExtendedLifetime(owner) {}
    }
    if kind != "active" {
      #expect(await VMFiles().writerStatus(in: fixture.directory) == .available)
    }
    let before = try bootInventory(fixture.directory)
    await #expect(throws: VMError.self) {
      try await LinuxBootArguments().update(
        in: fixture.directory, to: newBootArguments, host: bootHost)
    }
    #expect(try bootInventory(fixture.directory) == before)
    withExtendedLifetime(held) {}
  }
}

@Test func linuxBootArgumentsRejectAmbiguousInvalidAndWrongBootMode() async throws {
  for kind in ["duplicate", "unknown", "efi", "windows", "oversized", "nul", "disk-size"] {
    let fixture = try await bootFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var configuration = fixture.configuration
    var arguments = newBootArguments
    if kind == "efi" { configuration.boot = .efi }
    if kind == "windows" {
      configuration.guest = .windows11
      configuration.backend = .qemuHVF
      configuration.boot = .efi
    }
    if kind == "oversized" { arguments = String(repeating: "x", count: 4097) }
    if kind == "nul" { arguments += "\0" }
    if kind == "disk-size" { configuration.diskBytes = 2 * bootGiB }
    var original = try ConfigurationCodec.encode(configuration)
    if kind == "duplicate" || kind == "unknown" {
      let extra = kind == "duplicate" ? #""\u006bernelArguments":"other","# : #""future":1,"#
      original = Data(("{" + extra).utf8) + original.dropFirst()
    }
    try await VMFiles().atomicWrite(original, at: fixture.registration)
    let before = try bootInventory(fixture.directory)
    await #expect(throws: VMError.self) {
      try await LinuxBootArguments().update(in: fixture.directory, to: arguments, host: bootHost)
    }
    #expect(try bootInventory(fixture.directory) == before)
  }
}

@Test func linuxBootArgumentsBackupCollisionNeverOverwrites() async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let id = UUID()
  try await VMFiles().writeNewMetadata(
    Data("preserved conflict".utf8),
    at:
      fixture.directory.appendingPathComponent("configuration-boot-backup-\(id.uuidString).json"))
  let before = try bootInventory(fixture.directory)
  await #expect(throws: VMError.self) {
    try await LinuxBootArguments(files: VMFiles(), backupID: { id }).update(
      in: fixture.directory,
      to: newBootArguments, host: bootHost)
  }
  #expect(try bootInventory(fixture.directory) == before)
}

@Test func linuxBootMetadataReservationRejectsInheritanceRuntimeAndRetry() async throws {
  for kind in ["inheritance", "runtime", "metadata-fault"] {
    let fixture = try await bootFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
    let files = VMFiles()
    let target = try StrictConfigurationDocument(fixture.original).replacingKernelArguments(
      with: newBootArguments)
    if kind == "inheritance" {
      let lease = try owner.duplicateForInheritance()
      await #expect(throws: VMError.self) {
        try await files.commitLinuxKernelArguments(
          in: fixture.directory, vmID: fixture.configuration.id,
          original: fixture.original, replacement: target.bytes, backupID: UUID(), lock: owner)
      }
      withExtendedLifetime(lease) {}
    } else if kind == "runtime" {
      let permit = try await files.beginRuntimeSession(
        in: fixture.directory, forVMID: fixture.configuration.id, lock: owner)
      await #expect(throws: VMError.self) {
        try await files.commitLinuxKernelArguments(
          in: fixture.directory, vmID: fixture.configuration.id,
          original: fixture.original, replacement: target.bytes, backupID: UUID(), lock: owner)
      }
      withExtendedLifetime(permit) {}
    } else {
      await #expect(throws: VMError.self) {
        try await files.commitLinuxKernelArguments(
          in: fixture.directory, vmID: fixture.configuration.id,
          original: fixture.original, replacement: target.bytes, backupID: UUID(), lock: owner,
          fault: .afterBackup)
      }
      #expect(throws: VMError.self) { try owner.duplicateForInheritance() }
      await #expect(throws: VMError.self) {
        try await files.beginRuntimeSession(
          in: fixture.directory, forVMID: fixture.configuration.id, lock: owner)
      }
      await #expect(throws: VMError.self) {
        try await files.commitLinuxKernelArguments(
          in: fixture.directory, vmID: fixture.configuration.id,
          original: fixture.original, replacement: target.bytes, backupID: UUID(), lock: owner)
      }
    }
    #expect(try Data(contentsOf: fixture.registration) == fixture.original)
    withExtendedLifetime(owner) {}
  }
}

@Test func linuxBootStorageRejectsUnrelatedSettingsEvenWhenArgumentTextIsValid() async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  var unrelated = fixture.configuration
  unrelated.kernelArguments = newBootArguments
  unrelated.cpuCount = 3
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let before = try bootInventory(fixture.directory)
  await #expect(throws: VMError.self) {
    try await VMFiles().commitLinuxKernelArguments(
      in: fixture.directory, vmID: fixture.configuration.id, original: fixture.original,
      replacement: ConfigurationCodec.encode(unrelated), backupID: UUID(), lock: owner)
  }
  #expect(try bootInventory(fixture.directory) == before)
  #expect(throws: VMError.self) { try owner.duplicateForInheritance() }
  withExtendedLifetime(owner) {}
}

@Test func linuxBootStorageCancelledAttemptConsumesActualOwnerWithoutWriting() async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let target = try StrictConfigurationDocument(fixture.original)
    .replacingKernelArguments(with: newBootArguments)
  let before = try bootInventory(fixture.directory)
  let wasCancelled = await Task {
    withUnsafeCurrentTask { $0?.cancel() }
    do {
      _ = try await VMFiles().commitLinuxKernelArguments(
        in: fixture.directory, vmID: fixture.configuration.id, original: fixture.original,
        replacement: target.bytes, backupID: UUID(), lock: owner)
      return false
    } catch is CancellationError { return true } catch { return false }
  }.value
  #expect(wasCancelled)
  #expect(try bootInventory(fixture.directory) == before)
  await #expect(throws: VMError.self) {
    try await VMFiles().commitLinuxKernelArguments(
      in: fixture.directory, vmID: fixture.configuration.id, original: fixture.original,
      replacement: target.bytes, backupID: UUID(), lock: owner)
  }
  #expect(throws: VMError.self) { try owner.duplicateForInheritance() }
  withExtendedLifetime(owner) {}
}

@Test(arguments: [false, true])
func linuxBootArgumentsUseFreshRereadAndRejectChangedIdentity(rename: Bool) async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let protected = try bootInventory(fixture.directory)["disk.raw"]
  let store = RereadBootStore(rename ? .rename : .identity)
  if rename {
    let result = try await LinuxBootArguments(files: store).update(
      in: fixture.directory,
      to: newBootArguments, host: bootHost)
    #expect(result.configuration.name == "fresh reread name")
    let backup = try #require(result.backupFile)
    let changed = await store.changedBytes
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent(backup)) == changed)
    #expect(await store.commits == 1)
  } else {
    do {
      _ = try await LinuxBootArguments(files: store).update(
        in: fixture.directory,
        to: newBootArguments, host: bootHost)
      Issue.record("Changed identity must reject before backup/commit")
    } catch let error as VMError { #expect(error.code == .busy) }
    let changed = await store.changedBytes
    #expect(try Data(contentsOf: fixture.registration) == changed)
    #expect(await store.commits == 0)
    #expect(
      !(try bootInventory(fixture.directory).keys.contains {
        $0.hasPrefix("configuration-boot-backup-")
      }))
  }
  #expect(try bootInventory(fixture.directory)["disk.raw"] == protected)
}

@Test func linuxBootArgumentsCancellationAfterAdmissionPreservesFilesAndReleasesOwner() async throws
{
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let before = try bootInventory(fixture.directory)
  let store = RereadBootStore(.cancel)
  let cancelled = await Task {
    do {
      _ = try await LinuxBootArguments(files: store).update(
        in: fixture.directory,
        to: newBootArguments, host: bootHost)
      return false
    } catch is CancellationError { return true } catch { return false }
  }.value
  let commits = await store.commits
  #expect(cancelled && commits == 0)
  #expect(try bootInventory(fixture.directory) == before)
  let next = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  withExtendedLifetime(next) {}
}

@Test func linuxBootStorageRejectsReserializationOfUnchangedFields() async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  var replacement = fixture.configuration
  replacement.kernelArguments = newBootArguments
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let before = try bootInventory(fixture.directory)
  await #expect(throws: VMError.self) {
    try await VMFiles().commitLinuxKernelArguments(
      in: fixture.directory,
      vmID: fixture.configuration.id, original: fixture.original,
      replacement: ConfigurationCodec.encode(replacement), backupID: UUID(), lock: owner)
  }
  #expect(try bootInventory(fixture.directory) == before)
  withExtendedLifetime(owner) {}
}

@Test func linuxBootSelectionCommitsThreeExactTokensAndPreservesAssets() async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let images = try await bootImages(fixture)
  let text = String(decoding: fixture.original, as: UTF8.self)
    .replacingOccurrences(of: "\"kernel\"", with: "\"\\u006bernel\"")
    .replacingOccurrences(of: "\"initialRamdisk\"", with: "\"initial\\u0052amdisk\"")
  let original = Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)
  try await VMFiles().atomicWrite(original, at: fixture.registration)
  let before = try bootInventory(fixture.directory)
  let golden = try bootSelectionGolden(
    original, configuration: fixture.configuration, kernel: images.kernel,
    initialRamdisk: images.initialRamdisk, arguments: newBootArguments)
  let result = try await LinuxBootArguments().update(
    in: fixture.directory, to: newBootArguments, kernel: images.kernel,
    initialRamdisk: images.initialRamdisk, host: bootHost)
  #expect(result.changed && result.configuration.kernel == images.kernel.path)
  #expect(result.configuration.initialRamdisk == images.initialRamdisk.path)
  #expect(result.configuration.kernelArguments == newBootArguments)
  #expect(try Data(contentsOf: fixture.registration) == golden)
  let backup = try #require(result.backupFile)
  let after = try bootInventory(fixture.directory)
  #expect(after[backup]?.content == original)
  for (name, value) in before where name != "configuration.json" { #expect(after[name] == value) }
  let noOp = try await LinuxBootArguments().update(
    in: fixture.directory, to: newBootArguments, kernel: images.kernel,
    initialRamdisk: images.initialRamdisk, host: bootHost)
  #expect(!noOp.changed && noOp.backupFile == nil)
  #expect(try bootInventory(fixture.directory) == after)
}

@Test(arguments: [BootConfigurationFault.afterBackup, .afterRename, .afterCommit])
func linuxBootSelectionFaultsLeaveOneWholeConfigurationAndExactBackup(
  _ fault: BootConfigurationFault
) async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let images = try await bootImages(fixture)
  let before = try bootInventory(fixture.directory)
  let target = try bootSelectionGolden(
    fixture.original, configuration: fixture.configuration, kernel: images.kernel,
    initialRamdisk: images.initialRamdisk, arguments: newBootArguments)
  do {
    _ = try await LinuxBootArguments(files: FaultBootStore(fault)).update(
      in: fixture.directory, to: newBootArguments, kernel: images.kernel,
      initialRamdisk: images.initialRamdisk, host: bootHost)
    Issue.record("An uncertain selection must not report success")
  } catch let error as VMError {
    #expect(!error.localizedDescription.contains(fixture.directory.path))
    #expect(!error.localizedDescription.contains(fixture.configuration.id.uuidString))
  }
  #expect(
    try Data(contentsOf: fixture.registration)
      == (fault == .afterBackup ? fixture.original : target))
  let after = try bootInventory(fixture.directory)
  let backups = after.filter { $0.key.hasPrefix("configuration-boot-backup-") }
  #expect(backups.count == 1 && backups.values.first?.content == fixture.original)
  for (name, value) in before where name != "configuration.json" { #expect(after[name] == value) }
  let next = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  withExtendedLifetime(next) {}
}

@Test(arguments: [
  "kernel-only", "initramfs-only", "missing", "empty", "directory", "symlink", "fifo",
  "kernel-size", "initramfs-size", "remote", "control", "old-absent", "old-null", "old-number",
])
func linuxBootSelectionRejectsInvalidPairAndImagesWithoutMutation(_ kind: String) async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let images = try await bootImages(fixture)
  var kernel: URL? = images.kernel
  var initialRamdisk: URL? = images.initialRamdisk
  if kind == "kernel-only" { initialRamdisk = nil }
  if kind == "initramfs-only" { kernel = nil }
  if kind == "missing" { kernel = fixture.directory.appendingPathComponent("missing") }
  if kind == "remote" { kernel = URL(string: "https://example.invalid/kernel") }
  if kind == "control" { kernel = fixture.directory.appendingPathComponent("bad\nimage") }
  if ["empty", "directory", "symlink", "fifo"].contains(kind) {
    let selected = fixture.directory.appendingPathComponent("invalid-image")
    if kind == "empty" {
      try await VMFiles().writeNewMetadata(Data(), at: selected)
    } else if kind == "directory" {
      try FileManager.default.createDirectory(
        at: selected, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } else if kind == "symlink" {
      #expect(symlink(images.kernel.path, selected.path) == 0)
    } else {
      #expect(mkfifo(selected.path, 0o600) == 0)
    }
    kernel = selected
  }
  if kind == "kernel-size" || kind == "initramfs-size" {
    let selected = kind == "kernel-size" ? images.kernel : images.initialRamdisk
    #expect(chmod(selected.path, 0o600) == 0)
    let fd = open(selected.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw bootFailure() }
    defer { close(fd) }
    #expect(ftruncate(fd, off_t((kind == "kernel-size" ? 128 : 512) * 1_048_576 + 1)) == 0)
  }
  if kind.hasPrefix("old-") {
    var original = try JSONSerialization.jsonObject(with: fixture.original) as? [String: Any]
    if kind == "old-absent" { original?.removeValue(forKey: "initialRamdisk") }
    if kind == "old-null" { original?["initialRamdisk"] = NSNull() }
    if kind == "old-number" { original?["initialRamdisk"] = 1 }
    try await VMFiles().atomicWrite(
      JSONSerialization.data(withJSONObject: try #require(original), options: [.sortedKeys]),
      at: fixture.registration)
  }
  // Never open an invalid alias/FIFO; preserve its metadata and all regular VM files.
  let invalidNode = fixture.directory.appendingPathComponent("invalid-image")
  let nodeBefore = try bootNodeStamp(invalidNode)
  let before = try bootInventory(fixture.directory, excluding: ["invalid-image"])
  do {
    _ = try await LinuxBootArguments().update(
      in: fixture.directory, to: newBootArguments, kernel: kernel,
      initialRamdisk: initialRamdisk, host: bootHost)
    Issue.record("Invalid image selection must reject")
  } catch let error as VMError {
    #expect(!error.localizedDescription.contains(fixture.directory.path))
  }
  #expect(try bootInventory(fixture.directory, excluding: ["invalid-image"]) == before)
  #expect(try bootNodeStamp(invalidNode) == nodeBefore)
}

private func bootNodeStamp(_ url: URL) throws -> BootStamp? {
  var info = stat()
  guard lstat(url.path, &info) == 0 else {
    if errno == ENOENT { return nil }
    throw bootFailure()
  }
  return .init(
    inode: info.st_ino, device: info.st_dev, size: info.st_size, mode: info.st_mode,
    links: info.st_nlink, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
    modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
    changedSeconds: Int64(info.st_ctimespec.tv_sec),
    changedNanos: Int64(info.st_ctimespec.tv_nsec), content: Data())
}

@Test(arguments: ["other-field", "reserialized", "missing-image", "relative-image"])
func linuxBootStorageIndependentlyRejectsInvalidThreeTokenReplacement(_ kind: String) async throws {
  let fixture = try await bootFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let images = try await bootImages(fixture)
  let document = try StrictConfigurationDocument(fixture.original)
  var replacement = try document.replacingBootSelection(
    kernel: images.kernel.path, initialRamdisk: images.initialRamdisk.path,
    arguments: newBootArguments)
  if kind == "other-field" || kind == "reserialized" {
    var configuration = replacement.configuration
    if kind == "other-field" { configuration.name = "unrelated change" }
    replacement = try StrictConfigurationDocument(ConfigurationCodec.encode(configuration))
  } else {
    replacement = try document.replacingBootSelection(
      kernel: kind == "relative-image"
        ? "selected-kernel.bin"
        : fixture.directory.appendingPathComponent("missing-image").path,
      initialRamdisk: images.initialRamdisk.path, arguments: newBootArguments)
  }
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let before = try bootInventory(fixture.directory)
  await #expect(throws: VMError.self) {
    try await VMFiles().commitLinuxKernelArguments(
      in: fixture.directory, vmID: fixture.configuration.id, original: fixture.original,
      replacement: replacement.bytes, backupID: UUID(), lock: owner)
  }
  #expect(try bootInventory(fixture.directory) == before)
  #expect(throws: VMError.self) { try owner.duplicateForInheritance() }
  withExtendedLifetime(owner) {}
}
