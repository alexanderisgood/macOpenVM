// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@MainActor private struct FixturePlatform: VMCreationPlatform {
  let backend = BackendID.appleVz
  var rejectHost = false
  var failIdentity = false
  func validateHost(for configuration: VMConfiguration) throws {
    if rejectHost { throw VMError(.unsupported, "Fixture host unavailable", recovery: "inspect") }
  }
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    try Data("test identity; no credentials".utf8).write(
      to: directory.appendingPathComponent("identity.bin"), options: .withoutOverwriting)
    if failIdentity {
      throw VMError(.backendFailure, "Injected identity failure", recovery: "inspect")
    }
    return CreatedPlatformIdentity(files: ["identity.bin"])
  }
}

@MainActor private struct DirectoryFixturePlatform: VMCreationPlatform {
  let backend = BackendID.appleVz
  var reportedIdentity: CreatedPlatformIdentity?
  var directoryMode = 0o700
  var nonempty = false
  func validateHost(for configuration: VMConfiguration) throws {}
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    let identity = directory.appendingPathComponent("identity.bin")
    try Data(configuration.id.uuidString.utf8).write(to: identity, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)
    let state = directory.appendingPathComponent("platform-state")
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: directoryMode])
    if nonempty {
      try Data("preserve partial state".utf8).write(to: state.appendingPathComponent("existing"))
    }
    return reportedIdentity
      ?? CreatedPlatformIdentity(
        files: ["identity.bin"], emptyPrivateDirectories: ["platform-state"])
  }
}

private func creationFixture() throws -> (root: URL, configuration: VMConfiguration) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let media = root.appendingPathComponent("fixture.iso")
  // A regular-file fixture for transaction tests; it is not boot or image-validation evidence.
  try Data(repeating: 1, count: 1024).write(to: media)
  var c = VMConfiguration(
    name: "fixture", guest: .linux, backend: .appleVz, diskBytes: 1_073_741_824)
  c.installationMedia = media.path
  return (root, c)
}

private let fixtureHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)

@Test @MainActor func unavailableCreationHostDoesNotCreateFiles() async throws {
  let fixture = try creationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let destination = fixture.root.appendingPathComponent("new.macopenvm")
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      fixture.configuration, at: destination,
      platform: FixturePlatform(rejectHost: true), host: fixtureHost)
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test @MainActor func creationNeverReplacesAnExistingVM() async throws {
  let fixture = try creationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let destination = fixture.root.appendingPathComponent("existing.macopenvm")
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
  let disk = destination.appendingPathComponent("disk.raw")
  let original = Data("existing guest data".utf8)
  try original.write(to: disk)
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      fixture.configuration, at: destination,
      platform: FixturePlatform(), host: fixtureHost)
  }
  #expect(try Data(contentsOf: disk) == original)
  #expect(
    !FileManager.default.fileExists(atPath: destination.appendingPathComponent("identity.bin").path)
  )
}

@Test @MainActor func partialCreationPreservesFilesWithoutRegistering() async throws {
  let fixture = try creationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let destination = fixture.root.appendingPathComponent("partial.macopenvm")
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      fixture.configuration, at: destination,
      platform: FixturePlatform(failIdentity: true), host: fixtureHost)
  }
  let files = VMFiles()
  let disk = destination.appendingPathComponent("disk.raw")
  #expect(try await files.inspectDisk(at: disk).virtualBytes == 1_073_741_824)
  #expect(
    FileManager.default.fileExists(atPath: destination.appendingPathComponent("identity.bin").path))
  #expect(
    !FileManager.default.fileExists(
      atPath: destination.appendingPathComponent("configuration.json").path))
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      fixture.configuration, at: destination,
      platform: FixturePlatform(), host: fixtureHost)
  }
  #expect(try await files.inspectDisk(at: disk).virtualBytes == 1_073_741_824)
}

@Test @MainActor func creationCommitsSchemaAfterDiskAndIdentity() async throws {
  let fixture = try creationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let destination = fixture.root.appendingPathComponent("complete.macopenvm")
  try await VMCreation().create(
    fixture.configuration, at: destination,
    platform: FixturePlatform(), host: fixtureHost)
  let bytes = try await VMFiles().readMetadata(
    at: destination.appendingPathComponent("configuration.json"))
  #expect(try ConfigurationCodec.decode(bytes) == fixture.configuration)
  let lock = try VMLock(directory: destination)
  withExtendedLifetime(lock) {}
}

@Test @MainActor func creationBindsActualConfigurationAndRegistersAfterPrivateDirectory()
  async throws
{
  let fixture = try creationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let destination = fixture.root.appendingPathComponent("with-state.macopenvm")
  try await VMCreation().create(
    fixture.configuration, at: destination, platform: DirectoryFixturePlatform(), host: fixtureHost)
  #expect(
    try Data(contentsOf: destination.appendingPathComponent("identity.bin"))
      == Data(fixture.configuration.id.uuidString.utf8))
  #expect(
    try FileManager.default.contentsOfDirectory(
      atPath: destination.appendingPathComponent("platform-state").path
    ).isEmpty)
  let bytes = try await VMFiles().readMetadata(
    at: destination.appendingPathComponent("configuration.json"))
  #expect(try ConfigurationCodec.decode(bytes) == fixture.configuration)
}

@Test(arguments: [
  CreatedPlatformIdentity(files: ["identity.bin", "IDENTITY.BIN"]),
  CreatedPlatformIdentity(files: ["identity.bin"], emptyPrivateDirectories: ["IDENTITY.BIN"]),
  CreatedPlatformIdentity(files: ["DISK.RAW"]),
  CreatedPlatformIdentity(files: ["configuration.json"]),
  CreatedPlatformIdentity(files: ["writer.lock"]),
  CreatedPlatformIdentity(files: ["runtime.json"]),
  CreatedPlatformIdentity(files: ["runtime-intent.json"]),
  CreatedPlatformIdentity(files: ["runtime-previous.json"]),
  CreatedPlatformIdentity(files: ["disk-growth-intent.json"]),
  CreatedPlatformIdentity(files: [".disk-growth-temporary"]),
  CreatedPlatformIdentity(files: ["configuration-boot-backup-old.json"]),
  CreatedPlatformIdentity(files: ["../identity.bin"]),
  CreatedPlatformIdentity(files: ["identity\n.bin"]),
  CreatedPlatformIdentity(files: []),
  CreatedPlatformIdentity(files: (1...9).map { "identity-\($0).bin" }),
])
@MainActor func invalidCreatedIdentityPreservesPartialVMWithoutRegistration(
  _ identity: CreatedPlatformIdentity
) async throws {
  let fixture = try creationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let destination = fixture.root.appendingPathComponent("invalid-state.macopenvm")
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      fixture.configuration, at: destination,
      platform: DirectoryFixturePlatform(reportedIdentity: identity), host: fixtureHost)
  }
  #expect(
    FileManager.default.fileExists(atPath: destination.appendingPathComponent("identity.bin").path))
  #expect(
    try await VMFiles().inspectDisk(at: destination.appendingPathComponent("disk.raw")).virtualBytes
      == fixture.configuration.diskBytes)
  #expect(
    !FileManager.default.fileExists(
      atPath: destination.appendingPathComponent("configuration.json").path))
}

@Test(arguments: [false, true]) @MainActor
func privateDirectoryFailureCannotRegisterTheCreatedVM(_ nonempty: Bool) async throws {
  let fixture = try creationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let destination = fixture.root.appendingPathComponent("directory-failure.macopenvm")
  await #expect(throws: VMError.self) {
    try await VMCreation().create(
      fixture.configuration, at: destination,
      platform: DirectoryFixturePlatform(
        directoryMode: nonempty ? 0o700 : 0o755, nonempty: nonempty),
      host: fixtureHost)
  }
  #expect(
    FileManager.default.fileExists(atPath: destination.appendingPathComponent("identity.bin").path))
  #expect(
    !FileManager.default.fileExists(
      atPath: destination.appendingPathComponent("configuration.json").path))
  if nonempty {
    #expect(
      try Data(contentsOf: destination.appendingPathComponent("platform-state/existing"))
        == Data("preserve partial state".utf8))
  }
}
