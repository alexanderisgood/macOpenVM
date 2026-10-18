// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMCore
@testable import VMStorage

private let networkGiB: UInt64 = 1_073_741_824
private let networkHost = HostResources(cpuCount: 8, memoryBytes: 16 * networkGiB)

private struct NetworkFixture {
  let directory: URL
  let configuration: VMConfiguration
  let original: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
}

private func networkFixture(
  guest: GuestOS = .linux, backend: BackendID = .appleVz,
  mode: NetworkMode = .disconnected, directoryPrefix: String = "macOpenVM-network"
) async throws -> NetworkFixture {
  let directory = URL(
    fileURLWithPath: "/private/tmp/\(directoryPrefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  var c = VMConfiguration(
    name: "literal network shared disconnected", guest: guest, backend: backend,
    memoryBytes: 4 * networkGiB, diskBytes: (guest == .windows11 ? 64 : 1) * networkGiB)
  c.network = mode
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let text = String(decoding: try encoder.encode(c), as: UTF8.self)
    .replacingOccurrences(of: "\"network\"", with: "\"\\u006eetwork\"")
  let original = Data([0xef, 0xbb, 0xbf]) + Data(text.utf8) + Data("\n \n".utf8)
  let files = VMFiles()
  try await files.writeNewMetadata(
    original, at: directory.appendingPathComponent("configuration.json"))
  try await files.createSparseDisk(
    at: directory.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
  for name in ["machine-identity.bin", "efi-variables.bin", "tpm-state.bin"] {
    try await files.writeNewMetadata(
      Data("preserve \(name)".utf8), at: directory.appendingPathComponent(name))
  }
  if guest == .windows11 {
    try await files.writeNewMetadata(
      Data("preserve original QEMU provenance".utf8),
      at: directory.appendingPathComponent("qemu-platform.json"))
    try await files.writeNewMetadata(
      Data("preserve original QEMU variables".utf8),
      at: directory.appendingPathComponent("uefi-vars.json"))
    let tpm = directory.appendingPathComponent("tpm-state")
    try await files.createDirectory(tpm)
    for name in [".lock", "tpm2-00.permall"] {
      try await files.writeNewMetadata(
        Data("preserve synthetic TPM data".utf8), at: tpm.appendingPathComponent(name))
    }
  }
  let disk = try FileHandle(forWritingTo: directory.appendingPathComponent(c.diskFile))
  try disk.write(contentsOf: Data("preserve original disk sector".utf8))
  try disk.synchronize()
  try disk.close()
  let owner = try VMLock(directory: directory, expectedVMID: c.id)
  withExtendedLifetime(owner) {}
  return .init(directory: directory, configuration: c, original: original)
}

private struct NetworkStamp: Equatable {
  let inode: UInt64
  let size: Int64
  let blocks: Int64
  let mode: mode_t
  let seconds: Int
  let nanos: Int
  let prefix: Data
}

private func networkAssets(_ directory: URL) throws -> [String: NetworkStamp] {
  var result: [String: NetworkStamp] = [:]
  let rootNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  var names: [String] = []
  for name in rootNames {
    names.append(name)
    var info = stat()
    guard lstat(directory.appendingPathComponent(name).path, &info) == 0 else {
      throw CocoaError(.fileReadUnknown)
    }
    if info.st_mode & S_IFMT == S_IFDIR {
      names += try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent(name).path
      ).map { name + "/" + $0 }
    }
  }
  for name in names {
    let url = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
    let prefix: Data
    if info.st_mode & S_IFMT == S_IFDIR {
      prefix = Data()
    } else {
      let handle = try FileHandle(forReadingFrom: url)
      prefix = try handle.read(upToCount: 65_536) ?? Data()
      try handle.close()
    }
    result[name] = .init(
      inode: info.st_ino, size: info.st_size, blocks: info.st_blocks, mode: info.st_mode,
      seconds: info.st_mtimespec.tv_sec, nanos: info.st_mtimespec.tv_nsec, prefix: prefix)
  }
  return result
}

@Test func networkSettingsRoundTripPreservesIdentityAssetsAndExactBytes() async throws {
  let f = try await networkFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try networkAssets(f.directory)
  let result = try await NetworkSettings().update(
    in: f.directory, mode: .shared, expected: f.configuration, host: networkHost)
  var expected = f.configuration
  expected.network = .shared
  #expect(result.configuration == expected && result.changed)
  let backup = try #require(result.backupFile)
  #expect(try Data(contentsOf: f.directory.appendingPathComponent(backup)) == f.original)
  let exact = String(decoding: f.original, as: UTF8.self).replacingOccurrences(
    of: "\"\\u006eetwork\":\"disconnected\"", with: "\"\\u006eetwork\":\"shared\"")
  #expect(try Data(contentsOf: f.registration) == Data(exact.utf8))
  let after = try networkAssets(f.directory)
  for (name, value) in before where name != "configuration.json" { #expect(after[name] == value) }
  let noOp = try await NetworkSettings().update(in: f.directory, mode: .shared, host: networkHost)
  #expect(!noOp.changed && noOp.backupFile == nil)
  #expect(try networkAssets(f.directory) == after)
  let disconnected = try await NetworkSettings().update(
    in: f.directory, mode: .disconnected, expected: expected, host: networkHost)
  #expect(disconnected.configuration == f.configuration && disconnected.changed)
  #expect(try Data(contentsOf: f.registration) == f.original)
}

@Test(arguments: [GuestOS.linux, .windows11])
func networkSettingsAllowsOfflineOtherMetadataButRejectsUnverifiedShared(_ guest: GuestOS)
  async throws
{
  let f = try await networkFixture(guest: guest, backend: .qemuHVF, mode: .shared)
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try networkAssets(f.directory)
  await #expect(throws: VMError.self) {
    try await NetworkSettings().update(in: f.directory, mode: .shared, host: networkHost)
  }
  #expect(try networkAssets(f.directory) == before)
  let result = try await NetworkSettings().update(
    in: f.directory, mode: .disconnected, host: networkHost)
  var expected = f.configuration
  expected.network = .disconnected
  #expect(result.configuration == expected && result.changed)
  let after = try networkAssets(f.directory)
  for (name, value) in before where name != "configuration.json" { #expect(after[name] == value) }
}

@Test(arguments: ["stale", "duplicate", "unknown", "type"])
func networkSettingsRejectsStaleAndAmbiguousMetadata(_ kind: String) async throws {
  let f = try await networkFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  var expected = f.configuration
  if kind == "stale" {
    expected.name = "previous editor selection"
  } else if kind == "type" {
    let invalid = Data(
      String(decoding: f.original, as: UTF8.self).replacingOccurrences(
        of: "\"\\u006eetwork\":\"disconnected\"", with: "\"\\u006eetwork\":false"
      ).utf8)
    #expect(invalid != f.original)
    try await VMFiles().atomicWrite(
      invalid, at: f.registration)
  } else {
    let extra = kind == "duplicate" ? "\"network\":\"disconnected\"," : "\"future\":true,"
    let original = try ConfigurationCodec.encode(f.configuration)
    try await VMFiles().atomicWrite(
      Data(("{" + extra).utf8) + original.dropFirst(), at: f.registration)
  }
  let before = try networkAssets(f.directory)
  await #expect(throws: VMError.self) {
    try await NetworkSettings().update(
      in: f.directory, mode: .shared, expected: expected, host: networkHost)
  }
  #expect(try networkAssets(f.directory) == before)
}

@Test(arguments: ["held", "runtime-intent", "growth-intent"])
func networkSettingsRejectsOwnersAndPendingOperations(_ kind: String) async throws {
  let f = try await networkFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  var held: VMLock?
  if kind == "held" {
    held = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
  } else {
    let owner = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
    if kind == "runtime-intent" {
      let permit = try await VMFiles().beginRuntimeSession(
        in: f.directory, forVMID: f.configuration.id, lock: owner)
      withExtendedLifetime(permit) {}
    } else {
      let replacement = try StrictConfigurationDocument(f.original).replacingDiskBytes(
        with: 2 * networkGiB)
      let permit = try await VMFiles().beginDiskGrowth(
        in: f.directory, vmID: f.configuration.id, diskFile: f.configuration.diskFile,
        oldBytes: networkGiB, targetBytes: 2 * networkGiB,
        originalConfiguration: f.original, replacementConfiguration: replacement.bytes, lock: owner)
      withExtendedLifetime(permit) {}
    }
    withExtendedLifetime(owner) {}
  }
  let before = try networkAssets(f.directory)
  await #expect(throws: VMError.self) {
    try await NetworkSettings().update(in: f.directory, mode: .shared, host: networkHost)
  }
  #expect(try networkAssets(f.directory) == before)
  withExtendedLifetime(held) {}
}

// Package construction is a controlled capability fixture only, not native
// signature evidence. The separate QEMU factory test exercises real verification.
@Test func windowsSharedPermissionRoundTripPreservesPlatformAndExactBackups() async throws {
  let f = try await networkFixture(guest: .windows11, backend: .qemuHVF)
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try networkAssets(f.directory)
  let permission = SharedNetworkConfigurationPermission(configuration: f.configuration)
  let result = try await NetworkSettings().update(
    in: f.directory, mode: .shared,
    expected: f.configuration, host: networkHost, sharedPermission: permission)
  var expected = f.configuration
  expected.network = .shared
  #expect(result.configuration == expected && result.changed)
  let backup = try #require(result.backupFile)
  #expect(try Data(contentsOf: f.directory.appendingPathComponent(backup)) == f.original)
  let after = try networkAssets(f.directory)
  for (name, stamp) in before where name != "configuration.json" { #expect(after[name] == stamp) }
  let second = SharedNetworkConfigurationPermission(configuration: expected)
  let unchanged = try await NetworkSettings().update(
    in: f.directory, mode: .shared,
    expected: expected, host: networkHost, sharedPermission: second)
  #expect(!unchanged.changed && unchanged.backupFile == nil)
  #expect(try networkAssets(f.directory) == after)
  let disconnected = try await NetworkSettings().update(
    in: f.directory, mode: .disconnected,
    expected: expected, host: networkHost)
  #expect(disconnected.configuration == f.configuration)
  #expect(try Data(contentsOf: f.registration) == f.original)
}

@Test(arguments: ["none", "id", "name", "mode", "mac", "held", "intent", "stale"])
func windowsSharedPermissionRejectsWrongBaselineAndUnsettledOwners(_ kind: String) async throws {
  let f = try await networkFixture(guest: .windows11, backend: .qemuHVF)
  defer { try? FileManager.default.removeItem(at: f.directory) }
  var snapshot = f.configuration
  if kind == "id" { snapshot.id = UUID() }
  if kind == "name" { snapshot.name = "Previous editor baseline" }
  if kind == "mode" { snapshot.network = .shared }
  if kind == "mac" { snapshot.macAddress = "02:11:22:33:44:55" }
  let permission =
    kind == "none" ? nil : SharedNetworkConfigurationPermission(configuration: snapshot)
  var held: VMLock?
  if kind == "held" { held = try VMLock(directory: f.directory, expectedVMID: f.configuration.id) }
  if kind == "intent" {
    let lock = try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
    let permit = try await VMFiles().beginRuntimeSession(
      in: f.directory, forVMID: f.configuration.id, lock: lock)
    withExtendedLifetime((lock, permit)) {}
  }
  if kind == "stale" {
    var changed = f.configuration
    changed.cpuCount += 1
    try await VMFiles().atomicWrite(try ConfigurationCodec.encode(changed), at: f.registration)
  }
  let before = try networkAssets(f.directory)
  await #expect(throws: VMError.self) {
    try await NetworkSettings().update(
      in: f.directory, mode: .shared,
      host: networkHost, sharedPermission: permission)
  }
  #expect(try networkAssets(f.directory) == before)
  withExtendedLifetime(held) {}
}

@Test func controlledPermissionCannotExtendLinuxQemuSupportAndPrivatePercentPathsStayLiteral()
  async throws
{
  let unsupported = try await networkFixture(guest: .linux, backend: .qemuHVF)
  defer { try? FileManager.default.removeItem(at: unsupported.directory) }
  let proof = SharedNetworkConfigurationPermission(configuration: unsupported.configuration)
  await #expect(throws: VMError.self) {
    try await NetworkSettings().update(
      in: unsupported.directory, mode: .shared,
      host: networkHost, sharedPermission: proof)
  }
  let f = try await networkFixture(directoryPrefix: "literal%00network")
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let changed = try await NetworkSettings().update(
    in: f.directory, mode: .shared, host: networkHost)
  #expect(changed.changed && f.directory.path.hasPrefix("/private/tmp/literal%00network"))
  for value in [
    "file:///private/tmp/%00bad", "file:///private/tmp/a%2Fbad", "file:///private/tmp/a/../bad",
    "file:///private/tmp/a//bad", "file://remote/private/tmp/bad",
    "file:///private/tmp/bad?query=1",
  ] {
    let url = try #require(URL(string: value))
    await #expect(throws: VMError.self) {
      try await NetworkSettings().update(in: url, mode: .disconnected, host: networkHost)
    }
  }
}
