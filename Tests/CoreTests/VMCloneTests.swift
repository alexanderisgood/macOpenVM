// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

@MainActor private struct CloneTestPlatform: VMCreationPlatform {
  let backend = BackendID.appleVz
  var identityFails = false
  func validateHost(for configuration: VMConfiguration) throws {}
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    let identity = Data(UUID().uuidString.utf8)
    try identity.write(
      to: directory.appendingPathComponent("machine-identity.bin"), options: .withoutOverwriting)
    if identityFails {
      throw VMError(.backendFailure, "Identity fixture failed", recovery: "inspect")
    }
    try Data("new EFI fixture; not a firmware test".utf8).write(
      to: directory.appendingPathComponent("efi-variables.bin"), options: .withoutOverwriting)
    return CreatedPlatformIdentity(files: ["machine-identity.bin", "efi-variables.bin"])
  }
}

private let cloneHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
private struct CloneFixture {
  let root: URL
  let source: URL
  let target: URL
  let configuration: VMConfiguration
  let registration: Data
}

@MainActor private func cloneFixture() async throws -> CloneFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let source = root.appendingPathComponent("source.macopenvm")
  let target = root.appendingPathComponent("copy.macopenvm")
  let media = root.appendingPathComponent("fixture.iso")
  try Data(repeating: 1, count: 1024).write(to: media)
  var c = VMConfiguration(
    name: "source", guest: .linux, backend: .appleVz, diskBytes: 1_073_741_824)
  c.installationMedia = media.path
  c.network = .shared
  // These are real transaction files, not executable guest or OS-media evidence.
  try await VMCreation().create(c, at: source, platform: CloneTestPlatform(), host: cloneHost)
  return CloneFixture(
    root: root, source: source, target: target, configuration: c,
    registration: try await VMFiles().readMetadata(
      at: source.appendingPathComponent("configuration.json")))
}

private func marker(_ directory: URL, write value: UInt8? = nil) throws -> UInt8 {
  let fd = open(directory.appendingPathComponent("disk.raw").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  #expect(fd >= 0)
  guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
  defer { close(fd) }
  if var value {
    #expect(pwrite(fd, &value, 1, 1_048_576) == 1)
    #expect(fsync(fd) == 0)
  }
  var value: UInt8 = 0
  #expect(pread(fd, &value, 1, 1_048_576) == 1)
  return value
}

private func stoppedRecords(_ fixture: CloneFixture, kind: String = "stopped") async throws {
  let session = UUID()
  let snapshot: RuntimeSnapshot
  switch kind {
  case "pending":
    snapshot = .init(state: .running, operation: nil, backendActive: true, outcome: .pending)
  case "forced":
    snapshot = .init(state: .stopped, operation: nil, backendActive: false, outcome: .forcedStopped)
  case "failed":
    snapshot = .init(state: .failed, operation: nil, backendActive: false, outcome: .failed)
  default:
    snapshot = .init(state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped)
  }
  let bytes = try RuntimeHistoryCodec.encode(
    .init(sessionID: session, sequence: 2, recordedAt: 1, snapshot: snapshot))
  let files = VMFiles()
  try await files.writeNewMetadata(bytes, at: fixture.source.appendingPathComponent("runtime.json"))
  if kind == "legacy" { return }
  let intent: [String: Any] = [
    "schemaVersion": 1, "vmID": fixture.configuration.id.uuidString,
    "sessionID": kind == "session-mismatch" ? UUID().uuidString : session.uuidString,
    "state": kind == "unsettled" ? "unsettled" : "settled",
  ]
  try await files.writeNewMetadata(
    JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys]),
    at: fixture.source.appendingPathComponent("runtime-intent.json"))
}

@Test @MainActor func copyCreatesNewIdentityAndIndependentOfflineRegistration() async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  _ = try marker(f.source, write: 0x31)
  try await stoppedRecords(f)
  let originalIdentity = try Data(
    contentsOf: f.source.appendingPathComponent("machine-identity.bin"))
  let result = try await VMClone().copy(
    from: f.source, to: f.target, name: "Independent", platform: CloneTestPlatform(),
    host: cloneHost)
  #expect(result.sourceVMID == f.configuration.id)
  #expect(result.configuration.id != f.configuration.id)
  #expect(result.configuration.macAddress != f.configuration.macAddress)
  #expect(result.configuration.network == .disconnected)
  #expect(result.configuration.installationMedia == f.configuration.installationMedia)
  #expect(try marker(f.target) == 0x31)
  _ = try marker(f.target, write: 0x72)
  #expect(try marker(f.source) == 0x31)
  #expect(
    try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.registration)
  #expect(
    try Data(contentsOf: f.source.appendingPathComponent("machine-identity.bin"))
      == originalIdentity)
  #expect(
    try Data(contentsOf: f.target.appendingPathComponent("machine-identity.bin"))
      != originalIdentity)
  #expect(
    !FileManager.default.fileExists(atPath: f.target.appendingPathComponent("runtime.json").path))
  #expect(
    !FileManager.default.fileExists(
      atPath: f.target.appendingPathComponent("runtime-intent.json").path))
  let saved = try ConfigurationCodec.decode(
    await VMFiles().readMetadata(at: f.target.appendingPathComponent("configuration.json")))
  #expect(saved == result.configuration)
  let lock = try VMLock(directory: f.target, expectedVMID: saved.id)
  withExtendedLifetime(lock) {}
}

@Test @MainActor func newBlankVMCanBeCopiedWithoutClaimingGuestShutdown() async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let result = try await VMClone().copy(
    from: f.source, to: f.target, name: "Blank copy", platform: CloneTestPlatform(), host: cloneHost
  )
  #expect(result.disk.allocatedBytes == 0)
  #expect(result.configuration.id != f.configuration.id)
}

@Test @MainActor func staleSelectedCopySourceFailsBeforeCreatingDestination() async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  var selected = f.configuration
  selected.id = UUID()
  await #expect(throws: VMError.self) {
    try await VMClone().copy(
      from: f.source, to: f.target, name: "Copy", platform: CloneTestPlatform(), host: cloneHost,
      expected: selected)
  }
  #expect(!FileManager.default.fileExists(atPath: f.target.path))
  #expect(
    try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.registration)
}

@Test(arguments: [
  "missing", "pending", "forced", "failed", "session-mismatch", "unsettled",
])
@MainActor func copyRejectsUnprovenStoppedSources(kind: String) async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  _ = try marker(f.source, write: 0x53)
  if kind != "missing" { try await stoppedRecords(f, kind: kind) }
  await #expect(throws: VMError.self) {
    try await VMClone().copy(
      from: f.source, to: f.target, name: "Copy", platform: CloneTestPlatform(), host: cloneHost)
  }
  #expect(!FileManager.default.fileExists(atPath: f.target.path))
  #expect(try marker(f.source) == 0x53)
}

@Test @MainActor func nativeLegacyGuestStopRemainsEligibleWithoutAnIntentFile() async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  _ = try marker(f.source, write: 0x41)
  try await stoppedRecords(f, kind: "legacy")
  let result = try await VMClone().copy(
    from: f.source, to: f.target, name: "Legacy copy", platform: CloneTestPlatform(),
    host: cloneHost)
  #expect(result.configuration.id != f.configuration.id)
  #expect(try marker(f.target) == 0x41)
  #expect(try marker(f.source) == 0x41)
}

@Test @MainActor func identityFailureKeepsUnregisteredCopyAndSource() async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let originalIdentity = try Data(
    contentsOf: f.source.appendingPathComponent("machine-identity.bin"))
  await #expect(throws: VMError.self) {
    try await VMClone().copy(
      from: f.source, to: f.target, name: "Partial",
      platform: CloneTestPlatform(identityFails: true), host: cloneHost)
  }
  #expect(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("disk.raw").path))
  #expect(
    !FileManager.default.fileExists(
      atPath: f.target.appendingPathComponent("configuration.json").path))
  #expect(
    try Data(contentsOf: f.source.appendingPathComponent("machine-identity.bin"))
      == originalIdentity)
  #expect(
    try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.registration)
}

@Test @MainActor func copyDoesNotReplaceExistingDestinationOrUseNestedFolder() async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  try FileManager.default.createDirectory(at: f.target, withIntermediateDirectories: false)
  let existing = f.target.appendingPathComponent("disk.raw")
  try Data("keep existing contents".utf8).write(to: existing)
  for destination in [f.target, f.source, f.source.appendingPathComponent("nested.macopenvm")] {
    await #expect(throws: VMError.self) {
      try await VMClone().copy(
        from: f.source, to: destination, name: "Copy", platform: CloneTestPlatform(),
        host: cloneHost)
    }
  }
  #expect(try Data(contentsOf: existing) == Data("keep existing contents".utf8))
  #expect(
    !FileManager.default.fileExists(
      atPath: f.source.appendingPathComponent("nested.macopenvm").path))
}

@Test @MainActor func copyRejectsHeldSourceAndUnsafeRegistrationDiskName() async throws {
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  do {
    let owner = try VMLock(directory: f.source, expectedVMID: f.configuration.id)
    await #expect(throws: VMError.self) {
      try await VMClone().copy(
        from: f.source, to: f.target, name: "Copy", platform: CloneTestPlatform(), host: cloneHost)
    }
    withExtendedLifetime(owner) {}
  }
  var unsafe = f.configuration
  unsafe.diskFile = "writer.lock"
  try await VMFiles().atomicWrite(
    ConfigurationCodec.encode(unsafe), at: f.source.appendingPathComponent("configuration.json"))
  await #expect(throws: VMError.self) {
    try await VMClone().copy(
      from: f.source, to: f.target, name: "Copy", platform: CloneTestPlatform(), host: cloneHost)
  }
  #expect(!FileManager.default.fileExists(atPath: f.target.path))
}

@Test(arguments: ["windows", "contained-media", "contained-kernel", "unsafe-host", "invalid-name"])
@MainActor func copyRejectsUnsupportedOrUnsafeRequestsBeforeCreatingTarget(kind: String)
  async throws
{
  let f = try await cloneFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  var configuration = f.configuration
  var host = cloneHost
  var name = "Copy"
  switch kind {
  case "windows":
    configuration.guest = .windows11
    configuration.backend = .qemuHVF
  case "contained-media", "contained-kernel":
    let file = f.source.appendingPathComponent("local-input.bin")
    try Data(repeating: 1, count: 512).write(to: file)
    if kind == "contained-media" {
      configuration.installationMedia = file.path
    } else {
      configuration.boot = .linuxKernel
      configuration.kernel = file.path
    }
  case "unsafe-host": host = HostResources(cpuCount: 2, memoryBytes: 2 * 1_073_741_824)
  default: name = "../invalid"
  }
  try await VMFiles().atomicWrite(
    ConfigurationCodec.encode(configuration),
    at: f.source.appendingPathComponent("configuration.json"))
  let source = try Data(contentsOf: f.source.appendingPathComponent("configuration.json"))
  await #expect(throws: VMError.self) {
    try await VMClone().copy(
      from: f.source, to: f.target, name: name, platform: CloneTestPlatform(), host: host)
  }
  #expect(!FileManager.default.fileExists(atPath: f.target.path))
  #expect(try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == source)
}
