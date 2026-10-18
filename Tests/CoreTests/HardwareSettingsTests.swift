// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMCore
@testable import VMStorage

private let hardwareGiB: UInt64 = 1_073_741_824
private let hardwareHost = HostResources(cpuCount: 8, memoryBytes: 16 * hardwareGiB)

private struct HardwareFixture {
  let directory: URL
  let configuration: VMConfiguration
  let original: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
}

private func hardwareFixture(windows: Bool = false) async throws -> HardwareFixture {
  let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("macOpenVM-hardware-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let c = VMConfiguration(
    name: "settings fixture", guest: windows ? .windows11 : .linux,
    backend: windows ? .qemuHVF : .appleVz, memoryBytes: 4 * hardwareGiB,
    diskBytes: (windows ? 64 : 1) * hardwareGiB)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let text = String(decoding: try encoder.encode(c), as: UTF8.self)
    .replacingOccurrences(of: "\"cpuCount\"", with: "\"\\u0063puCount\"")
  let bytes = Data([0xef, 0xbb, 0xbf]) + Data(text.utf8) + Data("\n \n".utf8)
  let files = VMFiles()
  try await files.writeNewMetadata(
    bytes, at: directory.appendingPathComponent("configuration.json"))
  try await files.createSparseDisk(
    at: directory.appendingPathComponent("disk.raw"), bytes: c.diskBytes)
  for name in ["machine-identity.bin", "efi-variables.bin", "tpm-state.bin"] {
    try await files.writeNewMetadata(
      Data("preserve \(name)".utf8), at: directory.appendingPathComponent(name))
  }
  let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("disk.raw"))
  try handle.write(contentsOf: Data("preserve disk sector".utf8))
  try handle.synchronize()
  try handle.close()
  let lock = try VMLock(directory: directory, expectedVMID: c.id)
  withExtendedLifetime(lock) {}
  return .init(directory: directory, configuration: c, original: bytes)
}

private struct HardwareAsset: Equatable {
  let inode: UInt64
  let bytes: Int64
  let blocks: Int64
  let modified: Int
  let nanos: Int
  let prefix: Data
}

private func hardwareAssets(_ directory: URL) throws -> [String: HardwareAsset] {
  var result: [String: HardwareAsset] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let url = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
    let handle = try FileHandle(forReadingFrom: url)
    let prefix = try handle.read(upToCount: 65_536) ?? Data()
    try handle.close()
    result[name] = .init(
      inode: info.st_ino, bytes: info.st_size, blocks: info.st_blocks,
      modified: info.st_mtimespec.tv_sec, nanos: info.st_mtimespec.tv_nsec, prefix: prefix)
  }
  return result
}

@Test(arguments: [false, true])
func hardwareSettingsPreserveAssetsAndExactBackupAndNoOp(windows: Bool) async throws {
  let f = try await hardwareFixture(windows: windows)
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try hardwareAssets(f.directory)
  let result = try await HardwareSettings().update(
    in: f.directory, cpuCount: 4, memoryBytes: 6 * hardwareGiB, expected: f.configuration,
    host: hardwareHost)
  var expected = f.configuration
  expected.cpuCount = 4
  expected.memoryBytes = 6 * hardwareGiB
  #expect(result.configuration == expected && result.changed)
  let backup = try #require(result.backupFile)
  #expect(try Data(contentsOf: f.directory.appendingPathComponent(backup)) == f.original)
  let golden = String(decoding: f.original, as: UTF8.self)
    .replacingOccurrences(of: "\"\\u0063puCount\":2", with: "\"\\u0063puCount\":4")
    .replacingOccurrences(of: "\"memoryBytes\":4294967296", with: "\"memoryBytes\":6442450944")
  #expect(try Data(contentsOf: f.registration) == Data(golden.utf8))
  let after = try hardwareAssets(f.directory)
  for (name, asset) in before where name != "configuration.json" { #expect(after[name] == asset) }
  let unchanged = try await HardwareSettings().update(
    in: f.directory, cpuCount: 4, memoryBytes: 6 * hardwareGiB, host: hardwareHost)
  #expect(!unchanged.changed && unchanged.backupFile == nil)
  #expect(try hardwareAssets(f.directory) == after)
}

@Test(arguments: ["cpu", "memory", "windows-minimum", "stale", "duplicate", "unknown"])
func hardwareSettingsRejectUnsafeOrStaleInputWithoutMutation(_ kind: String) async throws {
  let f = try await hardwareFixture(windows: kind == "windows-minimum")
  defer { try? FileManager.default.removeItem(at: f.directory) }
  var expected = f.configuration
  if kind == "stale" { expected.name = "old editor snapshot" }
  if kind == "duplicate" || kind == "unknown" {
    let extra = kind == "duplicate" ? "\"cpuCount\":2," : "\"future\":true,"
    let original = try ConfigurationCodec.encode(f.configuration)
    try await VMFiles().atomicWrite(
      Data(("{" + extra).utf8) + original.dropFirst(), at: f.registration)
  }
  let before = try hardwareAssets(f.directory)
  await #expect(throws: VMError.self) {
    try await HardwareSettings().update(
      in: f.directory, cpuCount: kind == "cpu" ? 999 : 2,
      memoryBytes: kind == "memory" ? 9 * hardwareGiB : hardwareGiB,
      expected: expected, host: hardwareHost)
  }
  #expect(try hardwareAssets(f.directory) == before)
}

@Test(arguments: ["active", "runtime-intent", "growth-intent"])
func hardwareSettingsRejectOwnersAndPendingIntents(_ kind: String) async throws {
  let f = try await hardwareFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  var held: VMLock?
  if kind == "active" {
    held = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
  } else {
    let lock = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
    let files = VMFiles()
    if kind == "runtime-intent" {
      let permit = try await files.beginRuntimeSession(
        in: f.directory, forVMID: f.configuration.id, lock: lock)
      withExtendedLifetime(permit) {}
    } else {
      let target = try StrictConfigurationDocument(f.original).replacingDiskBytes(
        with: 2 * hardwareGiB)
      let permit = try await files.beginDiskGrowth(
        in: f.directory, vmID: f.configuration.id, diskFile: "disk.raw", oldBytes: hardwareGiB,
        targetBytes: 2 * hardwareGiB, originalConfiguration: f.original,
        replacementConfiguration: target.bytes, lock: lock)
      withExtendedLifetime(permit) {}
    }
    withExtendedLifetime(lock) {}
  }
  let before = try hardwareAssets(f.directory)
  await #expect(throws: VMError.self) {
    try await HardwareSettings().update(
      in: f.directory, cpuCount: 4, memoryBytes: 6 * hardwareGiB, host: hardwareHost)
  }
  #expect(try hardwareAssets(f.directory) == before)
  withExtendedLifetime(held) {}
}

private actor FaultHardwareStore: HardwareSettingsStore {
  let files = VMFiles()
  let fault: HardwareConfigurationFault
  init(_ fault: HardwareConfigurationFault) { self.fault = fault }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func commitHardwareConfiguration(
    in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64,
    host: HostResources, backupID: UUID, lock: VMLock
  ) async throws -> String? {
    try await files.commitHardwareConfiguration(
      in: directory, expected: expected, cpuCount: cpuCount, memoryBytes: memoryBytes,
      host: host, backupID: backupID, lock: lock, fault: fault)
  }
}

@Test(arguments: [HardwareConfigurationFault.afterBackup, .afterRename, .afterCommit])
func hardwareSettingsFaultsPreserveOriginalBackupAndDoNotRollback(
  _ fault: HardwareConfigurationFault
) async throws {
  let f = try await hardwareFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try hardwareAssets(f.directory)
  do {
    _ = try await HardwareSettings(files: FaultHardwareStore(fault)).update(
      in: f.directory, cpuCount: 4, memoryBytes: 6 * hardwareGiB, host: hardwareHost)
    Issue.record("A fault cannot report a confirmed save")
  } catch let error as VMError {
    #expect(!error.localizedDescription.contains(f.directory.path))
  }
  let after = try hardwareAssets(f.directory)
  let backups = after.filter { $0.key.hasPrefix("configuration-hardware-backup-") }
  #expect(backups.count == 1 && backups.values.first?.prefix == f.original)
  for (name, asset) in before where name != "configuration.json" { #expect(after[name] == asset) }
  let current = try ConfigurationCodec.decode(Data(contentsOf: f.registration))
  #expect(current.cpuCount == (fault == .afterBackup ? 2 : 4))
  let next = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
  withExtendedLifetime(next) {}
}

@Test func hardwareSettingsCanReduceAllocationForASmallerHost() async throws {
  let f = try await hardwareFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let small = HostResources(cpuCount: 4, memoryBytes: 4 * hardwareGiB)
  let result = try await HardwareSettings().update(
    in: f.directory, cpuCount: 2, memoryBytes: hardwareGiB, host: small)
  #expect(result.changed && result.configuration.memoryBytes == hardwareGiB)
}

@Test func hardwareSettingsBackupCollisionPreservesExistingFiles() async throws {
  let f = try await hardwareFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let id = UUID()
  try await VMFiles().writeNewMetadata(
    Data("existing backup must survive".utf8),
    at: f.directory.appendingPathComponent("configuration-hardware-backup-\(id.uuidString).json"))
  let before = try hardwareAssets(f.directory)
  await #expect(throws: VMError.self) {
    try await HardwareSettings(files: VMFiles(), backupID: { id }).update(
      in: f.directory, cpuCount: 4, memoryBytes: 6 * hardwareGiB, host: hardwareHost)
  }
  #expect(try hardwareAssets(f.directory) == before)
}

private actor RereadHardwareStore: HardwareSettingsStore {
  let files = VMFiles()
  let cancel: Bool
  init(cancel: Bool) { self.cancel = cancel }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func commitHardwareConfiguration(
    in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64,
    host: HostResources, backupID: UUID, lock: VMLock
  ) async throws -> String? {
    if cancel {
      withUnsafeCurrentTask { $0?.cancel() }
    } else {
      var newer = expected
      newer.name = "new registration after editor read"
      try await files.atomicWrite(
        ConfigurationCodec.encode(newer), at: directory.appendingPathComponent("configuration.json")
      )
    }
    return try await files.commitHardwareConfiguration(
      in: directory, expected: expected, cpuCount: cpuCount, memoryBytes: memoryBytes,
      host: host, backupID: backupID, lock: lock)
  }
}

@Test(arguments: [false, true])
func hardwareSettingsRecheckAfterAdmissionAndCancellation(cancel: Bool) async throws {
  let f = try await hardwareFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try hardwareAssets(f.directory)
  let failed = await Task {
    do {
      _ = try await HardwareSettings(files: RereadHardwareStore(cancel: cancel)).update(
        in: f.directory, cpuCount: 4, memoryBytes: 6 * hardwareGiB, host: hardwareHost)
      return false
    } catch is CancellationError { return cancel } catch let error as VMError {
      return !cancel && error.code == .staleOperation
    } catch { return false }
  }.value
  #expect(failed)
  let after = try hardwareAssets(f.directory)
  #expect(Set(after.keys) == Set(before.keys))
  for (name, asset) in before where name != "configuration.json" { #expect(after[name] == asset) }
  let current = try ConfigurationCodec.decode(Data(contentsOf: f.registration))
  #expect(current.cpuCount == 2 && current.memoryBytes == f.configuration.memoryBytes)
  if cancel {
    #expect(try Data(contentsOf: f.registration) == f.original)
  } else {
    #expect(current.name == "new registration after editor read")
  }
  let next = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
  withExtendedLifetime(next) {}
}
