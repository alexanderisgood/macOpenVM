// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

private struct AdmissionFixture {
  let root: URL
  let directory: URL
  let media: URL
  let configuration: VMConfiguration
  let original: Data
  let intent: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
}

private let admissionHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)

private func admissionFixture(state: String = "settled", matchingID: Bool = true) async throws
  -> AdmissionFixture
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-media-admission-\(UUID().uuidString)")
  let directory = root.appendingPathComponent("fixture.macopenvm")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let configuration = VMConfiguration(
    name: "saved fixture", guest: .linux, backend: .appleVz,
    memoryBytes: 2 * 1_073_741_824, diskBytes: 1_073_741_824)
  let original = try ConfigurationCodec.encode(configuration)
  let files = VMFiles()
  try await files.atomicWrite(original, at: directory.appendingPathComponent("configuration.json"))
  let media = root.appendingPathComponent("new-media.dat")
  try Data("ordinary metadata fixture, no installation claim".utf8).write(to: media)
  for name in ["disk.raw", "machine-identity.bin", "efi-variables.bin"] {
    try await files.writeNewMetadata(
      Data("preserve \(name)".utf8), at: directory.appendingPathComponent(name))
  }
  // Create the durable lock name before preservation snapshots.
  do {
    let lock = try VMLock(directory: directory, expectedVMID: configuration.id)
    withExtendedLifetime(lock) {}
  }
  let vmID = matchingID ? configuration.id : UUID()
  let intent = Data(
    ("{\"schemaVersion\":1,\"vmID\":\"\(vmID.uuidString)\","
      + "\"sessionID\":\"\(UUID().uuidString)\",\"state\":\"\(state)\"}").utf8)
  try await files.writeNewMetadata(
    intent, at: directory.appendingPathComponent(RuntimeIntent.filename))
  return AdmissionFixture(
    root: root, directory: directory, media: media, configuration: configuration,
    original: original, intent: intent)
}

/// Independently simulates a cooperating configuration update before admission.
/// All transaction writes are counted; the source's first read still returns the old snapshot.
private actor AdmissionStore: InstallationMediaStore {
  private let files = VMFiles()
  private let afterInitialRead: Data?
  private var reads = 0
  private var inspections = 0
  private var backups = 0
  private var commits = 0

  init(afterInitialRead: Data? = nil) { self.afterInitialRead = afterInitialRead }

  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    #expect(limit == ConfigurationCodec.maximumBytes)
    let bytes = try await files.readMetadata(at: url, limit: limit)
    reads += 1
    if reads == 1, let afterInitialRead {
      try await files.atomicWrite(afterInitialRead, at: url)
    }
    return bytes
  }
  func inspectWritableConfiguration(at url: URL) async throws -> DiskUsage {
    inspections += 1
    return try await files.inspectWritableConfiguration(at: url)
  }
  func inspectDisk(at url: URL) async throws -> DiskUsage {
    try await files.inspectDisk(at: url)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    backups += 1
    try await files.writeNewMetadata(data, at: url)
  }
  func commitInstallationConfiguration(_ data: Data, at url: URL) async throws {
    commits += 1
    try await files.commitInstallationConfiguration(data, at: url)
  }
  func counts() -> (reads: Int, inspections: Int, backups: Int, commits: Int) {
    (reads, inspections, backups, commits)
  }
}

private func admissionBackups(_ directory: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasPrefix("configuration-media-backup-") }
}

private func protectedAdmissionBytes(_ directory: URL) throws -> [String: Data] {
  try Dictionary(
    uniqueKeysWithValues: [
      "disk.raw", "machine-identity.bin", "efi-variables.bin", RuntimeIntent.filename,
    ].map {
      ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
    })
}

private struct ExpectedMediaStamp: Equatable {
  let device: Int32, inode: UInt64, mode: mode_t, uid: uid_t, links: UInt16
  let bytes: Data
}
private func expectedMediaSnapshot(_ directory: URL) throws -> [String: ExpectedMediaStamp] {
  try Dictionary(
    uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path).map {
      name in
      let path = directory.appendingPathComponent(name)
      var info = stat()
      guard lstat(path.path, &info) == 0 else {
        throw VMError(.storage, "Fixture stat failed", recovery: "Fixture only")
      }
      return (
        name,
        ExpectedMediaStamp(
          device: info.st_dev, inode: info.st_ino, mode: info.st_mode,
          uid: info.st_uid, links: info.st_nlink, bytes: try Data(contentsOf: path))
      )
    })
}

@Test(arguments: [
  "installation-same-id", "installation-foreign-id", "support-same-id", "support-foreign-id",
])
func mediaExpectedSelectionRejectsStaleUIBeforeInspectionOrBackup(_ kind: String) async throws {
  let fixture = try await admissionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let before = try expectedMediaSnapshot(fixture.directory)
  var expected = fixture.configuration
  if kind.contains("foreign-id") {
    expected.id = UUID()
  } else {
    expected.name = "Earlier UI selection"
  }
  let store = AdmissionStore()
  let unavailable = fixture.root.appendingPathComponent("must-not-be-inspected.iso")
  do {
    if kind.hasPrefix("support") {
      _ = try await InstallationMedia(files: store).updateSupport(
        in: fixture.directory,
        to: unavailable, host: admissionHost, expected: expected)
    } else {
      _ = try await InstallationMedia(files: store).update(
        in: fixture.directory,
        to: unavailable, host: admissionHost, expected: expected)
    }
    Issue.record("Stale UI media selection was accepted")
  } catch let error as VMError { #expect(error.code == .staleOperation) }
  let counts = await store.counts()
  #expect(
    counts.reads == 1 && counts.inspections == 0 && counts.backups == 0 && counts.commits == 0)
  #expect(try expectedMediaSnapshot(fixture.directory) == before)
}

@Test(arguments: ["installation", "support"])
func mediaExpectedSelectionRechecksUnderActualLockBeforeInspection(_ kind: String) async throws {
  let fixture = try await admissionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try protectedAdmissionBytes(fixture.directory)
  var intervening = fixture.configuration
  intervening.name = "Actual new configuration under the same VM identity"
  let replacement = try ConfigurationCodec.encode(intervening)
  let store = AdmissionStore(afterInitialRead: replacement)
  do {
    if kind == "support" {
      _ = try await InstallationMedia(files: store).updateSupport(
        in: fixture.directory,
        to: fixture.media, host: admissionHost, expected: fixture.configuration)
    } else {
      _ = try await InstallationMedia(files: store).update(
        in: fixture.directory,
        to: fixture.media, host: admissionHost, expected: fixture.configuration)
    }
    Issue.record("Intervening configuration passed the expected UI guard")
  } catch let error as VMError { #expect(error.code == .staleOperation) }
  let counts = await store.counts()
  #expect(
    counts.reads == 2 && counts.inspections == 0 && counts.backups == 0 && counts.commits == 0)
  #expect(try Data(contentsOf: fixture.registration) == replacement)
  #expect(try protectedAdmissionBytes(fixture.directory) == protected)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter {
      $0.hasPrefix("configuration-")
    }.isEmpty)
}

@Test(arguments: ["unsettled", "mismatched-settled"])
func mediaAdmissionRejectsUnsettledOrDifferentVMBeforeTransaction(_ kind: String) async throws {
  let fixture = try await admissionFixture(
    state: kind == "unsettled" ? "unsettled" : "settled", matchingID: kind == "unsettled")
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try protectedAdmissionBytes(fixture.directory)
  let store = AdmissionStore()
  do {
    // Nil is a metadata no-op; intent admission must still reject it.
    _ = try await InstallationMedia(files: store).update(
      in: fixture.directory, to: nil, host: admissionHost)
    Issue.record("Unsettled or mismatched intent permitted a media transaction")
  } catch let error as VMError { #expect(error.code == .busy) }
  let counts = await store.counts()
  #expect(counts.reads == 1 && counts.inspections == 0)
  #expect(counts.backups == 0 && counts.commits == 0)
  #expect(try Data(contentsOf: fixture.registration) == fixture.original)
  #expect(try protectedAdmissionBytes(fixture.directory) == protected)
  #expect(try admissionBackups(fixture.directory).isEmpty)
}

@Test func mediaAdmissionRejectsIdentityChangeAcrossLockWithoutBackup() async throws {
  let fixture = try await admissionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try protectedAdmissionBytes(fixture.directory)
  var replacement = fixture.configuration
  replacement.id = UUID()
  let replacementBytes = try ConfigurationCodec.encode(replacement)
  let store = AdmissionStore(afterInitialRead: replacementBytes)
  do {
    _ = try await InstallationMedia(files: store).update(
      in: fixture.directory, to: fixture.media, host: admissionHost)
    Issue.record("Changed saved VM identity permitted a media transaction")
  } catch let error as VMError { #expect(error.code == .busy) }
  let counts = await store.counts()
  #expect(counts.reads == 2 && counts.inspections == 1)
  #expect(counts.backups == 0 && counts.commits == 0)
  #expect(try Data(contentsOf: fixture.registration) == replacementBytes)
  #expect(try protectedAdmissionBytes(fixture.directory) == protected)
  #expect(try admissionBackups(fixture.directory).isEmpty)
}

@Test func mediaAdmissionUsesFreshSameVMConfigurationUnderLock() async throws {
  let fixture = try await admissionFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let protected = try protectedAdmissionBytes(fixture.directory)
  var fresh = fixture.configuration
  fresh.name = "newer saved settings"
  fresh.cpuCount = 3
  let freshBytes = try ConfigurationCodec.encode(fresh)
  let store = AdmissionStore(afterInitialRead: freshBytes)
  let result = try await InstallationMedia(files: store).update(
    in: fixture.directory, to: fixture.media, host: admissionHost)
  fresh.installationMedia = fixture.media.path
  #expect(result.changed && result.configuration == fresh)
  let backup = try #require(result.backupFile)
  #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(backup)) == freshBytes)
  #expect(try ConfigurationCodec.decode(Data(contentsOf: fixture.registration)) == fresh)
  let counts = await store.counts()
  #expect(counts.backups == 1 && counts.commits == 1)
  #expect(try protectedAdmissionBytes(fixture.directory) == protected)
  #expect(try admissionBackups(fixture.directory) == [backup])
}
