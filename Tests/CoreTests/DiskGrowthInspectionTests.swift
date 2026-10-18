// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMCore
@testable import VMStorage

private let growthInspectionGiB: UInt64 = 1_073_741_824
private let growthInspectionHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
private let growthInspectionSeed = Data("synthetic private disk contents to preserve".utf8)

private struct GrowthInspectionFixture {
  let directory: URL
  let configuration: VMConfiguration
  let original: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
  var disk: URL { directory.appendingPathComponent(configuration.diskFile) }
  var marker: URL { directory.appendingPathComponent(DiskGrowthIntent.filename) }

  static func create() async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("macOpenVM-growth-inspection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "private growth inspection label", guest: .linux, backend: .appleVz,
      memoryBytes: 2 * growthInspectionGiB, diskBytes: growthInspectionGiB)
    let original = try ConfigurationCodec.encode(configuration)
    let files = VMFiles()
    try await files.writeNewMetadata(
      original, at: directory.appendingPathComponent("configuration.json"))
    try await files.createSparseDisk(
      at: directory.appendingPathComponent(configuration.diskFile), bytes: configuration.diskBytes)
    for (name, content) in [
      ("machine-identity.bin", "synthetic private identity contents"),
      ("efi-variables.bin", "synthetic private firmware contents"),
    ] {
      try await files.writeNewMetadata(
        Data(content.utf8), at: directory.appendingPathComponent(name))
    }
    let fd = open(
      directory.appendingPathComponent(configuration.diskFile).path,
      O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw growthInspectionError() }
    defer { close(fd) }
    for offset in [UInt64(0), growthInspectionGiB - UInt64(growthInspectionSeed.count)] {
      let count = growthInspectionSeed.withUnsafeBytes {
        pwrite(fd, $0.baseAddress, $0.count, off_t(offset))
      }
      guard count == growthInspectionSeed.count else { throw growthInspectionError() }
    }
    guard fsync(fd) == 0 else { throw growthInspectionError() }
    return Self(directory: directory, configuration: configuration, original: original)
  }

  /// Produce authority through the actual Storage transaction, never forged marker JSON.
  func record(fault: DiskGrowthFaultPoint? = nil) async throws -> DiskGrowthIntent {
    let files = VMFiles()
    await files.injectDiskGrowthFault(fault)
    do {
      let lock = try VMLock(directory: directory, expectedVMID: configuration.id)
      let target = try StrictConfigurationDocument(original)
        .replacingDiskBytes(with: 2 * growthInspectionGiB).bytes
      do {
        let permit = try await files.beginDiskGrowth(
          in: directory, vmID: configuration.id, diskFile: configuration.diskFile,
          oldBytes: growthInspectionGiB, targetBytes: 2 * growthInspectionGiB,
          originalConfiguration: original, replacementConfiguration: target, lock: lock)
        _ = try await files.commitDiskGrowth(permit)
        #expect(fault == nil)
        withExtendedLifetime(permit) {}
      } catch let error as VMError {
        #expect(fault != nil && error.code == .storage)
        if fault == nil { throw error }
      }
      withExtendedLifetime(lock) {}
    }
    let record = try #require(try await files.readDiskGrowthIntent(in: directory))
    // Only this fresh fixture's released, empty lock is moved, preserving its bytes.
    // Every subsequent diagnostic must leave the normal lock name absent.
    try FileManager.default.moveItem(
      at: directory.appendingPathComponent("writer.lock"),
      to: directory.appendingPathComponent("preserved-test-writer.lock"))
    return record
  }
}

private struct GrowthInspectionStamp: Equatable {
  let device: Int32
  let inode: UInt64
  let owner: UInt32
  let size: Int64
  let mode: mode_t
  let links: UInt16
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
  let metadata: Data?
  let diskSamples: [Data]?
  let symlinkDestination: String?
}

private func growthInspectionRead(_ path: URL, offset: UInt64, count: Int) throws -> Data {
  let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
  guard fd >= 0 else { throw growthInspectionError() }
  defer { close(fd) }
  var result = Data(count: count)
  if count > 0 {
    let received = result.withUnsafeMutableBytes {
      pread(fd, $0.baseAddress, count, off_t(offset))
    }
    guard received == count else { throw growthInspectionError() }
  }
  return result
}

private func growthInspectionInventory(_ directory: URL) throws -> [String: GrowthInspectionStamp] {
  var result: [String: GrowthInspectionStamp] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let path = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(path.path, &info) == 0 else { throw growthInspectionError() }
    let regular = info.st_mode & S_IFMT == S_IFREG
    let metadata =
      regular && info.st_size <= 65_536
      ? try growthInspectionRead(path, offset: 0, count: Int(info.st_size)) : nil
    let samples: [Data]?
    if regular && info.st_size >= Int64(growthInspectionGiB) {
      samples = try [
        growthInspectionRead(path, offset: 0, count: growthInspectionSeed.count),
        growthInspectionRead(
          path, offset: growthInspectionGiB - UInt64(growthInspectionSeed.count),
          count: growthInspectionSeed.count),
        growthInspectionRead(path, offset: UInt64(info.st_size) - 512, count: 512),
      ]
    } else {
      samples = nil
    }
    let destination =
      info.st_mode & S_IFMT == S_IFLNK
      ? try FileManager.default.destinationOfSymbolicLink(atPath: path.path) : nil
    result[name] = GrowthInspectionStamp(
      device: info.st_dev, inode: info.st_ino, owner: info.st_uid, size: info.st_size,
      mode: info.st_mode, links: info.st_nlink,
      modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changedSeconds: Int64(info.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(info.st_ctimespec.tv_nsec), metadata: metadata,
      diskSamples: samples, symlinkDestination: destination)
  }
  return result
}

private func growthInspectionCheck(
  _ fixture: GrowthInspectionFixture, transaction: DiskGrowthIntent? = nil,
  otherVMID: UUID? = nil
) async throws -> VMInspectionReport {
  let before = try growthInspectionInventory(fixture.directory)
  #expect(!before.keys.contains("writer.lock"))
  let report = await VMInspection().inspect(at: fixture.directory, host: growthInspectionHost)
  #expect(try growthInspectionInventory(fixture.directory) == before)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.directory.appendingPathComponent("writer.lock").path))
  #expect(report.writer == .missing)
  let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
  var privateValues = [
    fixture.directory.path, fixture.directory.lastPathComponent, fixture.configuration.name,
    fixture.configuration.id.uuidString, fixture.configuration.macAddress,
    String(decoding: growthInspectionSeed, as: UTF8.self),
    "synthetic private identity contents", "synthetic private firmware contents",
    "private malformed growth marker contents",
  ]
  if let transaction { privateValues.append(transaction.transactionID.uuidString) }
  if let otherVMID { privateValues.append(otherVMID.uuidString) }
  for value in privateValues {
    #expect(!output.contains(value) && !output.lowercased().contains(value.lowercased()))
  }
  return report
}

private func growthInspectionError() -> VMError {
  VMError(.storage, "Synthetic inspection fixture I/O failed.", recovery: "Preserve its fixture.")
}

@Test func diskGrowthInspectionAbsentRecordDoesNotCreateWriter() async throws {
  let fixture = try await GrowthInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let report = try await growthInspectionCheck(fixture)
  #expect(report.status == .filesMatchConfiguration)
  #expect(
    report.files.contains(where: { $0.role == "disk-growth-intent" && $0.status.kind == .missing }))
  #expect(!report.findings.contains(where: { $0.code.hasPrefix("disk-growth-") }))
}

@Test(arguments: [DiskGrowthFaultPoint.afterPending, .afterGrow])
func diskGrowthInspectionPendingRequiresReviewWithoutCreatingOwnership(
  fault: DiskGrowthFaultPoint
) async throws {
  let fixture = try await GrowthInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let transaction = try await fixture.record(fault: fault)
  #expect(transaction.state == .pending)
  let report = try await growthInspectionCheck(fixture, transaction: transaction)
  #expect(report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "disk-growth-pending" }))
  #expect(
    report.findings.contains(where: { $0.code == "disk-size-mismatch" }) == (fault == .afterGrow))
}

@Test(arguments: [false, true])
func diskGrowthInspectionCompletedUsesCriticalBindingAfterLegitimateEdit(
  renameDisplay: Bool
) async throws {
  let fixture = try await GrowthInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let transaction = try await fixture.record()
  #expect(transaction.state == .completed)
  if renameDisplay {
    var current = try ConfigurationCodec.decode(Data(contentsOf: fixture.registration))
    current.name = "legitimate edited private display label"
    try await VMFiles().atomicWrite(ConfigurationCodec.encode(current), at: fixture.registration)
  }
  let report = try await growthInspectionCheck(fixture, transaction: transaction)
  #expect(report.status == .filesMatchConfiguration)
  #expect(!report.findings.contains(where: { $0.code.hasPrefix("disk-growth-") }))
  let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
  #expect(!output.contains("legitimate edited private display label"))
}

@Test(arguments: ["capacity", "disk-file", "disk-inode"])
func diskGrowthInspectionCompletedRejectsChangedCriticalBinding(kind: String) async throws {
  let fixture = try await GrowthInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let transaction = try await fixture.record()
  var current = try ConfigurationCodec.decode(Data(contentsOf: fixture.registration))
  switch kind {
  case "capacity": current.diskBytes += 512
  case "disk-file":
    current.diskFile = "unrelated.raw"
    try await VMFiles().createSparseDisk(
      at: fixture.directory.appendingPathComponent(current.diskFile), bytes: current.diskBytes)
  default:
    try FileManager.default.moveItem(
      at: fixture.disk, to: fixture.directory.appendingPathComponent("preserved-original.raw"))
    try await VMFiles().createSparseDisk(at: fixture.disk, bytes: current.diskBytes)
  }
  try await VMFiles().atomicWrite(ConfigurationCodec.encode(current), at: fixture.registration)
  let report = try await growthInspectionCheck(fixture, transaction: transaction)
  #expect(report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "disk-growth-completion-mismatch" }))
}

@Test(arguments: [false, true])
func diskGrowthInspectionRejectsAnotherRegistrationIdentity(completed: Bool) async throws {
  let fixture = try await GrowthInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let transaction = try await fixture.record(fault: completed ? nil : .afterPending)
  var current = try ConfigurationCodec.decode(Data(contentsOf: fixture.registration))
  current.id = UUID()
  try await VMFiles().atomicWrite(ConfigurationCodec.encode(current), at: fixture.registration)
  let report = try await growthInspectionCheck(
    fixture, transaction: transaction, otherVMID: current.id)
  #expect(report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "disk-growth-identity-mismatch" }))
}

@Test(
  .timeLimit(.minutes(1)),
  arguments: ["malformed", "unknown-schema", "oversized", "fifo", "symlink", "hardlink"])
func diskGrowthInspectionRejectsUnsafeMarkerWithoutFollowingOrRepairing(kind: String) async throws {
  let fixture = try await GrowthInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let transaction = try await fixture.record()
  let files = VMFiles()
  switch kind {
  case "malformed":
    try await files.atomicWrite(
      Data("{private malformed growth marker contents".utf8), at: fixture.marker)
  case "unknown-schema":
    let bytes = try Data(contentsOf: fixture.marker)
    var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["schemaVersion"] = 3
    try await files.atomicWrite(
      JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: fixture.marker)
  case "oversized":
    try await files.atomicWrite(
      Data(repeating: 32, count: DiskGrowthIntent.maximumBytes + 1), at: fixture.marker)
  case "hardlink":
    #expect(
      link(
        fixture.marker.path, fixture.directory.appendingPathComponent("preserved-marker-alias").path
      ) == 0)
  default:
    let preserved = fixture.directory.appendingPathComponent("preserved-growth-marker.json")
    try FileManager.default.moveItem(at: fixture.marker, to: preserved)
    if kind == "fifo" {
      #expect(mkfifo(fixture.marker.path, 0o600) == 0)
    } else {
      #expect(symlink(preserved.path, fixture.marker.path) == 0)
    }
  }
  let report = try await growthInspectionCheck(fixture, transaction: transaction)
  #expect(report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "disk-growth-invalid" }))
}
