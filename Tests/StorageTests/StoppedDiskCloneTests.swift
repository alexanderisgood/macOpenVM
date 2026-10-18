// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private let cloneDiskBytes: UInt64 = 1_073_741_824
private let cloneMarkers: [(UInt64, Data)] = [
  (0, Data(repeating: 0x37, count: 4096)),
  (1_048_576, Data(repeating: 0x83, count: 4096)),
  (cloneDiskBytes - 4096, Data(repeating: 0xD1, count: 4096)),
]
private let cloneVolumeAvailable =
  (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [
    .volumeSupportsFileCloningKey
  ])
  .volumeSupportsFileCloning) == true

private struct StoppedCloneFixture {
  let root: URL
  let source: URL
  let destination: URL
  let configuration: VMConfiguration
  let registration: Data
  let history: Data
  let destinationID = UUID()
  var sourceDisk: URL { source.appendingPathComponent(configuration.diskFile) }
  var resultDisk: URL { destination.appendingPathComponent(configuration.diskFile) }
}

private func stoppedCloneFixture() async throws -> StoppedCloneFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-clone-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let files = VMFiles()
  let source = root.appendingPathComponent("source.macopenvm")
  let destination = root.appendingPathComponent("destination.macopenvm")
  try await files.createDirectory(source)
  try await files.createDirectory(destination)
  let configuration = VMConfiguration(
    name: "synthetic stopped disk", guest: .linux, backend: .appleVz, diskBytes: cloneDiskBytes)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let registration = try encoder.encode(configuration)
  let history = Data(
    """
    {"schemaVersion":1,"sessionID":"\(UUID().uuidString)","sequence":2,"recordedAt":1,
    "snapshot":{"state":"stopped","backendActive":false,"outcome":"guestStopped"}}
    """.utf8)
  try await files.atomicWrite(registration, at: source.appendingPathComponent("configuration.json"))
  try await files.atomicWrite(history, at: source.appendingPathComponent("runtime.json"))
  try await files.createSparseDisk(
    at: source.appendingPathComponent("disk.raw"), bytes: cloneDiskBytes)
  let fixture = StoppedCloneFixture(
    root: root, source: source, destination: destination, configuration: configuration,
    registration: registration, history: history)
  for (offset, bytes) in cloneMarkers {
    try cloneWrite(bytes, at: fixture.sourceDisk, offset: offset)
  }
  return fixture
}

private func cloneWrite(_ bytes: Data, at url: URL, offset: UInt64) throws {
  let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw cloneTestError() }
  defer { close(fd) }
  let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offset)) }
  guard written == bytes.count, fsync(fd) == 0 else { throw cloneTestError() }
}

private func cloneRead(at url: URL, offset: UInt64, count: Int = 4096) throws -> Data {
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw cloneTestError() }
  defer { close(fd) }
  var bytes = Data(count: count)
  let read = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
  guard read == count else { throw cloneTestError() }
  return bytes
}

private func cloneStat(_ url: URL) throws -> stat {
  var result = stat()
  guard lstat(url.path, &result) == 0 else { throw cloneTestError() }
  return result
}

private func cloneTestError() -> VMError {
  VMError(.storage, "Synthetic clone fixture failed.", recovery: "Inspect the private test files.")
}

private func cloneAddACL(at url: URL) throws {
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw cloneTestError() }
  defer { close(fd) }
  var acl = acl_init(1)
  defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
  var entry: acl_entry_t?
  guard acl_create_entry(&acl, &entry) == 0, let acl, let entry,
    acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0
  else { throw cloneTestError() }
  let qualifier = UUID().uuid
  let setQualifier = withUnsafeBytes(of: qualifier) { acl_set_qualifier(entry, $0.baseAddress) }
  var permissions: acl_permset_t?
  guard setQualifier == 0, acl_get_permset(entry, &permissions) == 0, let permissions,
    acl_clear_perms(permissions) == 0, acl_add_perm(permissions, ACL_READ_DATA) == 0,
    acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0
  else { throw cloneTestError() }
}

private func cloneTargetRegistration(_ fixture: StoppedCloneFixture) throws -> Data {
  var target = fixture.configuration
  target.id = fixture.destinationID
  target.name = "new independent clone"
  target.macAddress =
    VMConfiguration(
      name: target.name, guest: target.guest, backend: target.backend, id: target.id
    ).macAddress
  target.network = .disconnected
  return try JSONEncoder().encode(target)
}

private func cloneNoRegistration(_ fixture: StoppedCloneFixture) {
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.destination.appendingPathComponent("configuration.json").path))
}

private func cloneSourceUnchanged(
  _ fixture: StoppedCloneFixture, registration: Data? = nil, history: Data? = nil
) throws {
  #expect(
    try Data(contentsOf: fixture.source.appendingPathComponent("configuration.json"))
      == (registration ?? fixture.registration))
  #expect(
    try Data(contentsOf: fixture.source.appendingPathComponent("runtime.json"))
      == (history ?? fixture.history))
  for (offset, bytes) in cloneMarkers {
    #expect(try cloneRead(at: fixture.sourceDisk, offset: offset) == bytes)
  }
}

@Test(.enabled(if: cloneVolumeAvailable, "Temporary volume lacks actual file-cloning support."))
func stoppedDiskCloneCopiesSparseContentsWithIndependentFlushedWrites() async throws {
  let fixture = try await stoppedCloneFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let source = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  let destination = try VMLock(directory: fixture.destination, expectedVMID: fixture.destinationID)
  let before = try cloneStat(fixture.sourceDisk)
  let usage = try await VMFiles().cloneStoppedDisk(
    from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
    registration: fixture.registration, history: fixture.history,
    destinationVMID: fixture.destinationID, sourceLock: source, destinationLock: destination)
  #expect(usage.virtualBytes == cloneDiskBytes && usage.allocatedBytes < cloneDiskBytes)
  let copied = try cloneStat(fixture.resultDisk)
  #expect(before.st_dev == copied.st_dev && before.st_ino != copied.st_ino)
  #expect(before.st_nlink == 1 && copied.st_nlink == 1 && copied.st_mode & 0o7777 == 0o600)
  for (offset, bytes) in cloneMarkers {
    #expect(try cloneRead(at: fixture.resultDisk, offset: offset) == bytes)
  }
  #expect(
    try cloneRead(at: fixture.resultDisk, offset: 8_388_608) == Data(repeating: 0, count: 4096))
  let newCloneBytes = Data(repeating: 0x12, count: 4096)
  try cloneWrite(newCloneBytes, at: fixture.resultDisk, offset: 0)
  #expect(try cloneRead(at: fixture.resultDisk, offset: 0) == newCloneBytes)
  #expect(try cloneRead(at: fixture.sourceDisk, offset: 0) == cloneMarkers[0].1)
  let newSourceBytes = Data(repeating: 0xFA, count: 4096)
  try cloneWrite(newSourceBytes, at: fixture.sourceDisk, offset: 1_048_576)
  #expect(try cloneRead(at: fixture.sourceDisk, offset: 1_048_576) == newSourceBytes)
  #expect(try cloneRead(at: fixture.resultDisk, offset: 1_048_576) == cloneMarkers[1].1)
  cloneNoRegistration(fixture)
  #expect(throws: VMError.self) { _ = try source.duplicateForInheritance() }
  #expect(throws: VMError.self) { _ = try destination.duplicateForInheritance() }
  await #expect(throws: VMError.self) {
    try await VMFiles().cloneStoppedDisk(
      from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
      registration: fixture.registration, history: fixture.history,
      destinationVMID: fixture.destinationID, sourceLock: source, destinationLock: destination)
  }
}

@Test(arguments: ["symlink", "hardlink", "wrong-size", "existing-result"])
func stoppedDiskCloneRejectsUnsafeOrExistingDisks(_ kind: String) async throws {
  let fixture = try await stoppedCloneFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let preserved = fixture.source.appendingPathComponent("preserved.raw")
  if kind == "symlink" {
    try FileManager.default.moveItem(at: fixture.sourceDisk, to: preserved)
    try FileManager.default.createSymbolicLink(
      at: fixture.sourceDisk, withDestinationURL: preserved)
  } else if kind == "hardlink" {
    #expect(link(fixture.sourceDisk.path, preserved.path) == 0)
  } else if kind == "wrong-size" {
    #expect(truncate(fixture.sourceDisk.path, off_t(cloneDiskBytes - 512)) == 0)
  } else {
    try Data("existing target bytes".utf8).write(
      to: fixture.resultDisk, options: .withoutOverwriting)
    #expect(chmod(fixture.resultDisk.path, 0o600) == 0)
  }
  let sourceBefore = try cloneStat(kind == "symlink" ? preserved : fixture.sourceDisk)
  let source = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  let destination = try VMLock(directory: fixture.destination, expectedVMID: fixture.destinationID)
  await #expect(throws: VMError.self) {
    try await VMFiles().cloneStoppedDisk(
      from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
      registration: fixture.registration, history: fixture.history,
      destinationVMID: fixture.destinationID, sourceLock: source, destinationLock: destination)
  }
  let sourceAfter = try cloneStat(kind == "symlink" ? preserved : fixture.sourceDisk)
  #expect(sourceBefore.st_dev == sourceAfter.st_dev && sourceBefore.st_ino == sourceAfter.st_ino)
  #expect(
    sourceBefore.st_size == sourceAfter.st_size && sourceBefore.st_nlink == sourceAfter.st_nlink)
  #expect(sourceBefore.st_mtimespec.tv_sec == sourceAfter.st_mtimespec.tv_sec)
  #expect(sourceBefore.st_mtimespec.tv_nsec == sourceAfter.st_mtimespec.tv_nsec)
  #expect(sourceBefore.st_ctimespec.tv_sec == sourceAfter.st_ctimespec.tv_sec)
  #expect(sourceBefore.st_ctimespec.tv_nsec == sourceAfter.st_ctimespec.tv_nsec)
  cloneNoRegistration(fixture)
  if kind == "existing-result" {
    #expect(try Data(contentsOf: fixture.resultDisk) == Data("existing target bytes".utf8))
  } else {
    #expect(!FileManager.default.fileExists(atPath: fixture.resultDisk.path))
  }
}

@Test(arguments: ["source-directory", "source-disk", "destination-directory"])
func stoppedDiskCloneRejectsActualExtendedACLs(_ location: String) async throws {
  let fixture = try await stoppedCloneFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let target =
    location == "source-directory"
    ? fixture.source
    : location == "source-disk" ? fixture.sourceDisk : fixture.destination
  try cloneAddACL(at: target)
  let source = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  let destination = try VMLock(directory: fixture.destination, expectedVMID: fixture.destinationID)
  await #expect(throws: VMError.self) {
    try await VMFiles().cloneStoppedDisk(
      from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
      registration: fixture.registration, history: fixture.history,
      destinationVMID: fixture.destinationID, sourceLock: source, destinationLock: destination)
  }
  try cloneSourceUnchanged(fixture)
  cloneNoRegistration(fixture)
  #expect(!FileManager.default.fileExists(atPath: fixture.resultDisk.path))
}

@Test(arguments: [
  "configuration.json", "writer.lock", "machine-identity.bin", "../disk.raw",
  ".metadata-test", "configuration-hardware-backup-test.json",
])
func stoppedDiskCloneRejectsReservedNames(_ name: String) throws {
  #expect(throws: VMError.self) { try VMFiles.validateCloneDiskName(name) }
}

@Test(arguments: [
  "registration", "history", "missing-history", "unsettled-intent",
  "edited-registration", "edited-history",
])
func stoppedDiskCloneRejectsStaleCapturedMetadata(_ kind: String) async throws {
  let fixture = try await stoppedCloneFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let source = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  let destination = try VMLock(directory: fixture.destination, expectedVMID: fixture.destinationID)
  var registration = fixture.registration
  var history: Data? = fixture.history
  if kind == "registration" {
    var changed = fixture.configuration
    changed.name = "stale caller"
    registration = try JSONEncoder().encode(changed)
  } else if kind == "history" {
    history = Data("different captured history".utf8)
  } else if kind == "missing-history" {
    history = nil
  } else if kind == "edited-registration" {
    var changed = fixture.configuration
    changed.name = "registration changed after admission"
    try await VMFiles().atomicWrite(
      try JSONEncoder().encode(changed),
      at: fixture.source.appendingPathComponent("configuration.json"))
  } else if kind == "edited-history" {
    try await VMFiles().atomicWrite(
      fixture.history + Data(" ".utf8), at: fixture.source.appendingPathComponent("runtime.json"))
  } else {
    let intent = Data(
      """
      {"schemaVersion":1,"vmID":"\(fixture.configuration.id.uuidString)",
      "sessionID":"\(UUID().uuidString)","state":"unsettled"}
      """.utf8)
    try await VMFiles().atomicWrite(
      intent, at: fixture.source.appendingPathComponent(RuntimeIntent.filename))
  }
  let capturedRegistration = registration
  let capturedHistory = history
  let registrationBefore = try Data(
    contentsOf: fixture.source.appendingPathComponent("configuration.json"))
  let historyBefore = try Data(contentsOf: fixture.source.appendingPathComponent("runtime.json"))
  await #expect(throws: VMError.self) {
    try await VMFiles().cloneStoppedDisk(
      from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
      registration: capturedRegistration, history: capturedHistory,
      destinationVMID: fixture.destinationID, sourceLock: source, destinationLock: destination)
  }
  try cloneSourceUnchanged(fixture, registration: registrationBefore, history: historyBefore)
  cloneNoRegistration(fixture)
  #expect(!FileManager.default.fileExists(atPath: fixture.resultDisk.path))
}

@Test(arguments: [
  "inherited-source", "inherited-destination", "wrong-destination-id", "wrong-role",
])
func stoppedDiskCloneRequiresMatchingUninheritedOwners(_ role: String) async throws {
  let fixture = try await stoppedCloneFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let source = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  let destination = try VMLock(directory: fixture.destination, expectedVMID: fixture.destinationID)
  let inherited =
    role == "inherited-source"
    ? try source.duplicateForInheritance()
    : role == "inherited-destination" ? try destination.duplicateForInheritance() : nil
  #expect(throws: VMError.self) {
    _ = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  }
  await #expect(throws: VMError.self) {
    try await VMFiles().cloneStoppedDisk(
      from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
      registration: fixture.registration, history: fixture.history,
      destinationVMID: role == "wrong-destination-id" ? UUID() : fixture.destinationID,
      sourceLock: role == "wrong-role" ? destination : source, destinationLock: destination)
  }
  withExtendedLifetime(inherited) {}
  try cloneSourceUnchanged(fixture)
  cloneNoRegistration(fixture)
  #expect(!FileManager.default.fileExists(atPath: fixture.resultDisk.path))
}

@Test(
  .enabled(if: cloneVolumeAvailable, "Temporary volume lacks actual file-cloning support."),
  arguments: [StoppedDiskCloneFault.afterClone, .afterFlush])
func stoppedDiskClonePreservesUnregisteredResultOnFailure(_ fault: StoppedDiskCloneFault)
  async throws
{
  let fixture = try await stoppedCloneFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let source = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  let destination = try VMLock(directory: fixture.destination, expectedVMID: fixture.destinationID)
  await #expect(throws: VMError.self) {
    try await VMFiles().cloneStoppedDisk(
      from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
      registration: fixture.registration, history: fixture.history,
      destinationVMID: fixture.destinationID, sourceLock: source, destinationLock: destination,
      fault: fault)
  }
  try cloneSourceUnchanged(fixture)
  cloneNoRegistration(fixture)
  #expect(try cloneStat(fixture.resultDisk).st_size == cloneDiskBytes)
  for (offset, bytes) in cloneMarkers {
    #expect(try cloneRead(at: fixture.resultDisk, offset: offset) == bytes)
  }
}

@Test func stoppedDiskCloneCapacityArithmeticDoesNotOverflow() {
  let reserve = StoppedDiskCloneIO.reserveBytes
  #expect(
    StoppedDiskCloneIO.capacitySufficient(sourceBlocks: 0, freeBlocks: reserve, blockBytes: 1))
  #expect(
    !StoppedDiskCloneIO.capacitySufficient(sourceBlocks: 0, freeBlocks: reserve - 1, blockBytes: 1))
  #expect(
    !StoppedDiskCloneIO.capacitySufficient(sourceBlocks: -1, freeBlocks: .max, blockBytes: 4096))
  #expect(
    !StoppedDiskCloneIO.capacitySufficient(sourceBlocks: .max, freeBlocks: .max, blockBytes: 512))
  #expect(!StoppedDiskCloneIO.capacitySufficient(sourceBlocks: 1, freeBlocks: .max, blockBytes: 0))
  #expect(
    StoppedDiskCloneIO.capacitySufficient(sourceBlocks: 1, freeBlocks: 262_145, blockBytes: 4096))
  #expect(
    !StoppedDiskCloneIO.capacitySufficient(sourceBlocks: 1, freeBlocks: 262_144, blockBytes: 4096))
}

@Test(
  .enabled(if: cloneVolumeAvailable, "Temporary volume lacks actual file-cloning support."),
  arguments: ["complete", "existing-registration", "edited-source-disk", "changed-geometry"])
func stoppedDiskClonePublishesExclusivelyAfterCopy(_ scenario: String) async throws {
  let fixture = try await stoppedCloneFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let source = try VMLock(directory: fixture.source, expectedVMID: fixture.configuration.id)
  let destination = try VMLock(directory: fixture.destination, expectedVMID: fixture.destinationID)
  let files = VMFiles()
  _ = try await files.cloneStoppedDisk(
    from: fixture.source, to: fixture.destination, configuration: fixture.configuration,
    registration: fixture.registration, history: fixture.history,
    destinationVMID: fixture.destinationID, sourceLock: source, destinationLock: destination)
  var registration = try cloneTargetRegistration(fixture)
  let destinationRegistration = fixture.destination.appendingPathComponent("configuration.json")
  let preserved = Data("an intervening target registration".utf8)
  if scenario == "existing-registration" {
    try preserved.write(to: destinationRegistration, options: .withoutOverwriting)
    #expect(chmod(destinationRegistration.path, 0o600) == 0)
  } else if scenario == "edited-source-disk" {
    try cloneWrite(Data(repeating: 0xCC, count: 4096), at: fixture.sourceDisk, offset: 0)
  } else if scenario == "changed-geometry" {
    var target = try JSONDecoder().decode(VMConfiguration.self, from: registration)
    target.diskBytes += 512
    registration = try JSONEncoder().encode(target)
  }
  let targetBytes = registration
  if scenario == "complete" {
    try await files.commitNewCloneConfiguration(
      targetBytes, from: fixture.source, to: fixture.destination,
      configuration: fixture.configuration,
      registration: fixture.registration, history: fixture.history, sourceLock: source,
      destinationLock: destination, destinationVMID: fixture.destinationID)
    #expect(try Data(contentsOf: destinationRegistration) == targetBytes)
    let info = try cloneStat(destinationRegistration)
    #expect(info.st_nlink == 1 && info.st_mode & 0o7777 == 0o600)
  } else {
    await #expect(throws: VMError.self) {
      try await files.commitNewCloneConfiguration(
        targetBytes, from: fixture.source, to: fixture.destination,
        configuration: fixture.configuration,
        registration: fixture.registration, history: fixture.history, sourceLock: source,
        destinationLock: destination, destinationVMID: fixture.destinationID)
    }
    if scenario == "existing-registration" {
      #expect(try Data(contentsOf: destinationRegistration) == preserved)
    } else {
      cloneNoRegistration(fixture)
    }
  }
  for (offset, bytes) in cloneMarkers {
    #expect(try cloneRead(at: fixture.resultDisk, offset: offset) == bytes)
  }
  if scenario != "edited-source-disk" { try cloneSourceUnchanged(fixture) }
}
