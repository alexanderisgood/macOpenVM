// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private let networkStoreHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)

private func networkStoreFixture() async throws -> (URL, VMConfiguration, Data) {
  let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("macOpenVM-network-store-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let configuration = VMConfiguration(
    name: "original networking", guest: .linux, backend: .appleVz, diskBytes: 1_073_741_824)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let original = try encoder.encode(configuration)
  let files = VMFiles()
  try await files.atomicWrite(original, at: directory.appendingPathComponent("configuration.json"))
  try await files.createSparseDisk(
    at: directory.appendingPathComponent(configuration.diskFile), bytes: configuration.diskBytes)
  return (directory, configuration, original)
}

@Test(arguments: [NetworkConfigurationFault.afterBackup, .afterRename, .afterCommit])
func networkConfigurationFaultsPreserveBackupWithoutFalseRollback(
  _ fault: NetworkConfigurationFault
) async throws {
  let (directory, configuration, original) = try await networkStoreFixture()
  defer { try? FileManager.default.removeItem(at: directory) }
  let owner = try VMLock(directory: directory, expectedVMID: configuration.id)
  let backupID = UUID()
  await #expect(throws: VMError.self) {
    try await VMFiles().commitNetworkConfiguration(
      in: directory, expected: configuration, mode: .shared, host: networkStoreHost,
      backupID: backupID, lock: owner, fault: fault)
  }
  #expect(
    try Data(
      contentsOf: directory.appendingPathComponent(
        "configuration-network-backup-\(backupID.uuidString).json")) == original)
  let result = try DiskGrowthIO.decodeConfiguration(
    Data(contentsOf: directory.appendingPathComponent("configuration.json")))
  var expected = configuration
  if fault != .afterBackup { expected.network = .shared }
  #expect(result == expected)
  #expect(throws: VMError.self) { _ = try owner.duplicateForInheritance() }
}

@Test(arguments: ["backup-collision", "inherited", "wrong-owner", "stale", "disk-alias"])
func networkConfigurationRejectsConflictsAndBadPurpose(_ kind: String) async throws {
  let (directory, configuration, original) = try await networkStoreFixture()
  defer { try? FileManager.default.removeItem(at: directory) }
  let owner = try VMLock(directory: directory, expectedVMID: configuration.id)
  let backupID = UUID()
  let backup = directory.appendingPathComponent(
    "configuration-network-backup-\(backupID.uuidString).json")
  let collision = Data("preserve an existing archive".utf8)
  var lease: VMLock.InheritedLease?
  if kind == "backup-collision" { try await VMFiles().writeNewMetadata(collision, at: backup) }
  if kind == "inherited" { lease = try owner.duplicateForInheritance() }
  if kind == "disk-alias" {
    #expect(
      link(
        directory.appendingPathComponent(configuration.diskFile).path,
        directory.appendingPathComponent("aliased.raw").path) == 0)
  }
  var expected = configuration
  if kind == "wrong-owner" { expected.id = UUID() }
  if kind == "stale" { expected.name = "previous configuration" }
  await #expect(throws: VMError.self) {
    try await VMFiles().commitNetworkConfiguration(
      in: directory, expected: expected, mode: .shared, host: networkStoreHost,
      backupID: backupID, lock: owner)
  }
  #expect(try Data(contentsOf: directory.appendingPathComponent("configuration.json")) == original)
  if kind == "backup-collision" {
    #expect(try Data(contentsOf: backup) == collision)
  } else {
    #expect(!FileManager.default.fileExists(atPath: backup.path))
  }
  withExtendedLifetime(lease) {}
}

@Test func networkConfigurationArchiveNamesCannotBecomeGuestDisks() {
  #expect(!DiskGrowthIO.safeDiskName("configuration-network-backup-test.json"))
  #expect(!DiskGrowthIO.safeDiskName("CONFIGURATION-NETWORK-BACKUP-test.json"))
  #expect(DiskGrowthIO.safeDiskName("network-disk.raw"))
}
