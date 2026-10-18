// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMStorage

@testable import VMCore

private let supportHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)

@MainActor private struct SupportCreationPlatform: VMCreationPlatform {
  let backend = BackendID.appleVz
  func validateHost(for configuration: VMConfiguration) throws {}
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    for name in ["machine-identity.bin", "efi-variables.bin"] {
      try Data("structural fixture only".utf8).write(
        to: directory.appendingPathComponent(name), options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(name).path)
    }
    return CreatedPlatformIdentity(files: ["machine-identity.bin", "efi-variables.bin"])
  }
}

private struct SupportFixture {
  let root: URL
  let directory: URL
  let installer: URL
  let support: URL
  var configuration: VMConfiguration {
    var value = VMConfiguration(
      name: "support-fixture", guest: .linux, backend: .appleVz,
      memoryBytes: 2 * 1_073_741_824, diskBytes: 1_073_741_824)
    value.installationMedia = installer.path
    value.supportMedia = support.path
    return value
  }
}

private func supportFixture() throws -> SupportFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let installer = root.appendingPathComponent("installer.iso")
  let support = root.appendingPathComponent("support.iso")
  // Small raw regular-file fixtures, not filesystem or guest boot evidence.
  try Data(repeating: 0x11, count: 1024).write(to: installer)
  try Data(repeating: 0x22, count: 1024).write(to: support)
  return SupportFixture(
    root: root, directory: root.appendingPathComponent("new.macopenvm"),
    installer: installer, support: support)
}

@Test func supportMediaLegacyAndPresentConfigurationRoundTrip() throws {
  let fixture = try supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var value = fixture.configuration
  value.supportMedia = nil
  let legacy = try ConfigurationCodec.encode(value)
  let fields = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
  #expect(fields["supportMedia"] == nil)
  #expect(try ConfigurationCodec.decode(legacy).supportMedia == nil)
  value.supportMedia = fixture.support.path
  let roundTrip = try ConfigurationCodec.decode(ConfigurationCodec.encode(value))
  #expect(roundTrip == value)
}

@Test(arguments: ["relative", "nul", "newline", "oversize"])
func supportMediaRejectsUnsafePathsWithoutEchoingThem(_ kind: String) throws {
  var value = VMConfiguration(name: "fixture", guest: .linux, backend: .appleVz)
  let sentinel = "private-support-sentinel"
  switch kind {
  case "relative": value.supportMedia = sentinel
  case "nul": value.supportMedia = "/" + sentinel + "\0"
  case "newline": value.supportMedia = "/" + sentinel + "\n"
  default: value.supportMedia = "/" + sentinel + String(repeating: "a", count: 4096)
  }
  do {
    try ConfigurationValidator.validate(value, host: supportHost)
    Issue.record("Unsafe support location was accepted.")
  } catch let error as VMError {
    #expect(error.code == .invalidConfiguration)
    #expect(!(error.message + error.recovery).contains(sentinel))
  }
}

@Test(arguments: ["missing", "empty", "directory", "symlink", "unaligned"])
@MainActor func supportMediaInvalidInputPrecedesDestinationCreation(_ kind: String) async throws {
  let fixture = try supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let selected = fixture.root.appendingPathComponent("invalid-support")
  switch kind {
  case "empty": try Data().write(to: selected)
  case "directory":
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
  case "symlink":
    try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: fixture.support)
  case "unaligned": try Data(repeating: 1, count: 513).write(to: selected)
  default: break
  }
  var value = fixture.configuration
  value.supportMedia = selected.path
  let configuration = value
  let before = try Data(contentsOf: fixture.support)
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      configuration, at: fixture.directory, platform: SupportCreationPlatform(), host: supportHost)
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
  let after = try Data(contentsOf: fixture.support)
  #expect(after == before)
}

@Test(arguments: [false, true])
@MainActor func supportMediaCreationPreservesLegacyAndIndependentSelections(_ selected: Bool)
  async throws
{
  let fixture = try supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var value = fixture.configuration
  if !selected { value.supportMedia = nil }
  let supportBefore = try Data(contentsOf: fixture.support)
  try await VMCreation().create(
    value, at: fixture.directory, platform: SupportCreationPlatform(), host: supportHost)
  let bytes = try await VMFiles().readMetadata(
    at: fixture.directory.appendingPathComponent("configuration.json"))
  let saved = try ConfigurationCodec.decode(bytes)
  #expect(saved == value)
  #expect(saved.installationMedia == fixture.installer.path)
  #expect(saved.supportMedia == value.supportMedia)
  let supportAfter = try Data(contentsOf: fixture.support)
  #expect(supportAfter == supportBefore)
}

@Test @MainActor func supportMediaCannotReplaceRequiredPrimaryBootSelection() async throws {
  let fixture = try supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var value = fixture.configuration
  value.installationMedia = nil
  let configuration = value
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      configuration, at: fixture.directory, platform: SupportCreationPlatform(), host: supportHost)
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
}

@Test func supportMediaStrictConfigurationAcceptsAllFieldsAndRejectsEscapedDuplicates() throws {
  let fixture = try supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var value = fixture.configuration
  value.kernel = "/fixture-kernel"
  value.initialRamdisk = "/fixture-initrd"
  let bytes = try ConfigurationCodec.encode(value)
  let fields = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  #expect(fields.count == 18)
  let document = try StrictConfigurationDocument(bytes)
  #expect(document.configuration == value)
  for key in ["supportMedia", "support\\u004dedia"] {
    var duplicate = Data(("{\"" + key + "\":\"/conflicting\",").utf8)
    duplicate.append(bytes.dropFirst())
    #expect(throws: VMError.self) { try StrictConfigurationDocument(duplicate) }
  }
  let grown = try document.replacingDiskBytes(with: 2 * 1_073_741_824)
  #expect(grown.configuration.supportMedia == value.supportMedia)
}

@Test @MainActor func installationMediaUpdatePreservesSupportAndExactBackup() async throws {
  let fixture = try supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let value = fixture.configuration
  try await VMCreation().create(
    value, at: fixture.directory, platform: SupportCreationPlatform(), host: supportHost)
  let registration = fixture.directory.appendingPathComponent("configuration.json")
  let files = VMFiles()
  let original = try await files.readMetadata(at: registration)
  let replacement = fixture.root.appendingPathComponent("replacement.iso")
  try Data(repeating: 0x44, count: 1024).write(to: replacement)
  let changed = try await InstallationMedia().update(
    in: fixture.directory, to: replacement, host: supportHost)
  #expect(changed.changed && changed.configuration.supportMedia == value.supportMedia)
  let backup = try #require(changed.backupFile)
  let backupBytes = try await files.readMetadata(
    at: fixture.directory.appendingPathComponent(backup))
  #expect(backupBytes == original)
  let detached = try await InstallationMedia().update(
    in: fixture.directory, to: nil, host: supportHost)
  #expect(detached.configuration.installationMedia == nil)
  #expect(detached.configuration.supportMedia == value.supportMedia)
}

@Test(arguments: ["valid", "missing", "unaligned"])
func supportMediaInspectionIsReadOnlyAndReportsActualImageBounds(_ kind: String) async throws {
  let fixture = try supportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let files = VMFiles()
  try await files.createDirectory(fixture.directory)
  let value = fixture.configuration
  try await files.createSparseDisk(
    at: fixture.directory.appendingPathComponent(value.diskFile), bytes: value.diskBytes)
  for name in ["machine-identity.bin", "efi-variables.bin"] {
    try await files.writeNewMetadata(
      Data("structural fixture only".utf8), at: fixture.directory.appendingPathComponent(name))
  }
  let registration = fixture.directory.appendingPathComponent("configuration.json")
  let original = try ConfigurationCodec.encode(value)
  try await files.atomicWrite(original, at: registration)
  if kind == "missing" { try FileManager.default.removeItem(at: fixture.support) }
  if kind == "unaligned" { try Data(repeating: 3, count: 513).write(to: fixture.support) }
  let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
  let report = await VMInspection().inspect(at: fixture.directory, host: supportHost)
  #expect(report.files.contains(where: { $0.role == "support-media" }))
  #expect(report.writer == .missing)
  #expect(report.status == (kind == "valid" ? .filesMatchConfiguration : .needsReview))
  let currentNames = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    .sorted()
  let current = try await files.readMetadata(at: registration)
  #expect(currentNames == names && current == original)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.directory.appendingPathComponent("writer.lock").path))
  let encoded = try JSONEncoder().encode(report)
  #expect(!String(decoding: encoded, as: UTF8.self).contains(fixture.support.path))
}
