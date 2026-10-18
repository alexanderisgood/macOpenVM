// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

@testable import Qemu

private let qemuCreationHost = HostResources(cpuCount: 8, memoryBytes: 16 << 30)

/// These are independently hashed file fixtures, never executable/firmware or
/// installation-image qualification. No process API is used by this suite.
private struct QemuCreationFixture {
  let root: URL
  let configuration: VMConfiguration
  let resources: ReviewedQemuCreationResources

  init() throws {
    root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("macOpenVM-qemu-creation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var rows: [ReviewedQemuResource] = []
    for role in QemuCreationResourceRole.allCases {
      let path = root.appendingPathComponent(role.rawValue)
      let bytes = Data("Independent dummy resource: \(role.rawValue)\n".utf8)
      try bytes.write(to: path, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: role == .qemu || role == .swtpm ? 0o700 : 0o600],
        ofItemAtPath: path.path)
      rows.append(
        ReviewedQemuResource(
          role: role, url: path, byteCount: UInt64(bytes.count), sha256: qemuFixtureDigest(bytes)))
    }
    resources = try ReviewedQemuCreationResources(resources: rows)
    let media = root.appendingPathComponent("file-only-media.iso")
    try Data("Regular file only; never an OS image claim.\n".utf8).write(to: media)
    var value = VMConfiguration(
      name: "File-only Windows fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    value.installationMedia = media.path
    configuration = value
  }

  func close() { try? FileManager.default.removeItem(at: root) }
}

private func qemuFixtureDigest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct QemuFileIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
  let mode: UInt16
  let links: UInt16
  let size: Int64
  init(_ path: URL) throws {
    var info = stat()
    guard lstat(path.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    device = UInt64(info.st_dev)
    inode = UInt64(info.st_ino)
    mode = info.st_mode
    links = info.st_nlink
    size = info.st_size
  }
}

@MainActor private final class QemuCreationWitness {
  var heldActualWriter = false
  var registrationWasAbsent = false
}

/// Delegation uses the real public platform. Only observation of the Core-owned
/// writer/commit ordering is injected, without creating a backend or child.
@MainActor private struct WitnessQemuPlatform: VMCreationPlatform {
  let backend = BackendID.qemuHVF
  let actual: QemuCreationPlatform
  let witness: QemuCreationWitness
  func validateHost(for configuration: VMConfiguration) throws {
    try actual.validateHost(for: configuration)
  }
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    do {
      let unexpected = try VMLock(directory: directory, expectedVMID: configuration.id)
      withExtendedLifetime(unexpected) {}
    } catch let error as VMError { witness.heldActualWriter = error.code == .busy }
    witness.registrationWasAbsent =
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("configuration.json").path)
    return try actual.createIdentity(for: configuration, in: directory)
  }
}

@Suite(.serialized) @MainActor struct QemuCreationTests {
  @Test func explicitResourceBundleRejectsDuplicateRolesAliasesAndNonemptyVariables() throws {
    let fixture = try QemuCreationFixture()
    defer { fixture.close() }
    let rows = fixture.resources.resources
    #expect(throws: VMError.self) {
      try ReviewedQemuCreationResources(resources: Array(rows.dropLast()))
    }
    #expect(throws: VMError.self) {
      try ReviewedQemuCreationResources(resources: Array(rows.dropLast()) + [rows[0]])
    }
    var aliased = rows
    aliased[1] = ReviewedQemuResource(
      role: rows[1].role, url: rows[0].url, byteCount: rows[0].byteCount, sha256: rows[0].sha256)
    #expect(throws: VMError.self) { try ReviewedQemuCreationResources(resources: aliased) }
    #expect(throws: VMError.self) {
      try ReviewedQemuCreationResources(resources: rows, uefiVariablesTemplate: Data("{}".utf8))
    }
    var bad = rows
    bad[0] = ReviewedQemuResource(
      role: rows[0].role, url: rows[0].url, byteCount: 0, sha256: rows[0].sha256)
    #expect(throws: VMError.self) { try ReviewedQemuCreationResources(resources: bad) }
    bad[0] = ReviewedQemuResource(
      role: rows[0].role, url: rows[0].url, byteCount: rows[0].byteCount,
      sha256: String(repeating: "f", count: 63))
    #expect(throws: VMError.self) { try ReviewedQemuCreationResources(resources: bad) }
  }

  @Test(arguments: [
    "bytes", "size", "symlink", "hardlink", "ancestor", "permissions", "not-executable",
  ])
  func reviewedBytesAreRecheckedFromActualFileAndNeverFromSavedClaims(kind: String) throws {
    let fixture = try QemuCreationFixture()
    defer { fixture.close() }
    try fixture.resources.verifyResourceFiles()
    let source = try fixture.resources.resource(.qemu)
    let original = try Data(contentsOf: source.url)
    switch kind {
    case "bytes":
      var changed = original
      changed[0] ^= 1
      try changed.write(to: source.url)
    case "size": try (original + Data("extra".utf8)).write(to: source.url)
    case "symlink":
      let saved = fixture.root.appendingPathComponent("external-source")
      try original.write(to: saved)
      try FileManager.default.removeItem(at: source.url)
      try FileManager.default.createSymbolicLink(at: source.url, withDestinationURL: saved)
    case "hardlink":
      try FileManager.default.linkItem(
        at: source.url, to: fixture.root.appendingPathComponent("source-alias"))
    case "ancestor":
      let directory = fixture.root.appendingPathComponent("indirect")
      try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.root)
      var rows = fixture.resources.resources
      rows[0] = ReviewedQemuResource(
        role: .qemu, url: directory.appendingPathComponent("qemu"),
        byteCount: source.byteCount, sha256: source.sha256)
      let indirect = try ReviewedQemuCreationResources(resources: rows)
      #expect(throws: VMError.self) { try indirect.verifyResourceFiles() }
      return
    case "permissions":
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o720], ofItemAtPath: source.url.path)
    default:
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: source.url.path)
    }
    #expect(throws: VMError.self) { try fixture.resources.verifyResourceFiles() }
  }

  @Test func savedIdentityCannotMintResourceAuthorityOrCrossVMAndProfileBoundaries() throws {
    let trusted = try QemuCreationFixture()
    defer { trusted.close() }
    let other = try QemuCreationFixture()
    defer { other.close() }
    let bytes = try QemuPlatformIdentityCodec.encode(
      for: trusted.configuration, resources: trusted.resources)
    try QemuPlatformIdentityCodec.validate(
      bytes, for: trusted.configuration, resources: trusted.resources)
    let selfConsistentUntrustedClaims = try QemuPlatformIdentityCodec.encode(
      for: trusted.configuration, resources: other.resources)
    try QemuPlatformIdentityCodec.validate(
      selfConsistentUntrustedClaims, for: trusted.configuration, resources: other.resources)
    #expect(throws: VMError.self) {
      try QemuPlatformIdentityCodec.validate(
        selfConsistentUntrustedClaims, for: trusted.configuration, resources: trusted.resources)
    }
    var differentVM = trusted.configuration
    differentVM.id = UUID()
    #expect(throws: VMError.self) {
      try QemuPlatformIdentityCodec.validate(bytes, for: differentVM, resources: trusted.resources)
    }
    var differentProfile = trusted.configuration
    differentProfile.guest = .linux
    #expect(throws: VMError.self) {
      try QemuPlatformIdentityCodec.validate(
        bytes, for: differentProfile, resources: trusted.resources)
    }
    let text = try #require(String(data: bytes, encoding: .utf8))
    let invalid = [
      Data(), bytes + Data(" ".utf8),
      Data(("{\"schemaVersion\":1," + String(text.dropFirst())).utf8),
      Data(repeating: 0, count: QemuPlatformIdentityCodec.maximumBytes + 1),
    ]
    for value in invalid {
      #expect(throws: VMError.self) {
        try QemuPlatformIdentityCodec.validate(
          value, for: trusted.configuration, resources: trusted.resources)
      }
    }
  }

  @Test func hostAndConfigurationAdmissionRejectsUnsupportedInputsBeforePublication() throws {
    let fixture = try QemuCreationFixture()
    defer { fixture.close() }
    try QemuCreationPlatform.validateConfiguration(
      fixture.configuration, host: qemuCreationHost, operatingSystemMajor: 27)
    #expect(throws: VMError.self) {
      try QemuCreationPlatform.validateConfiguration(
        fixture.configuration, host: qemuCreationHost, operatingSystemMajor: 26)
    }
    let mutations: [(inout VMConfiguration) -> Void] = [
      { $0.guest = .linux }, { $0.backend = .appleVz }, { $0.architecture = .x8664 },
      { $0.network = .shared }, { $0.supportMedia = "/dummy.iso" }, { $0.kernel = "/dummy-kernel" },
      { $0.cpuCount = 1 }, { $0.memoryBytes = 2 << 30 }, { $0.diskBytes = 32 << 30 },
      { $0.diskFile = "UEFI-VARS.JSON" }, { $0.diskFile = "tpm-state" },
    ]
    for mutation in mutations {
      var changed = fixture.configuration
      mutation(&changed)
      #expect(throws: VMError.self) {
        try QemuCreationPlatform.validateConfiguration(
          changed, host: qemuCreationHost, operatingSystemMajor: 27)
      }
    }
  }

  @Test func realCoreCreationHoldsWriterAndRegistersOnlyAfterPrivateIdentity() async throws {
    let fixture = try QemuCreationFixture()
    defer { fixture.close() }
    let destination = fixture.root.appendingPathComponent("new-vm")
    let witness = QemuCreationWitness()
    let platform = WitnessQemuPlatform(
      actual: QemuCreationPlatform(resources: fixture.resources), witness: witness)
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion
      < ReviewedQemuCreationResources.minimumHostMajorVersion
    {
      await #expect(throws: VMError.self) {
        try await VMCreation().create(
          fixture.configuration, at: destination, platform: platform, host: qemuCreationHost)
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      return
    }
    try await VMCreation().create(
      fixture.configuration, at: destination, platform: platform, host: qemuCreationHost)
    #expect(witness.heldActualWriter && witness.registrationWasAbsent)
    let files = VMFiles()
    #expect(
      try ConfigurationCodec.decode(
        await files.readMetadata(at: destination.appendingPathComponent("configuration.json")))
        == fixture.configuration)
    let data = try await files.readMetadata(
      at: destination.appendingPathComponent(QemuPlatformIdentityCodec.filename))
    try QemuPlatformIdentityCodec.validate(
      data, for: fixture.configuration, resources: fixture.resources)
    #expect(
      try Data(
        contentsOf: destination.appendingPathComponent(QemuPlatformIdentityCodec.variablesFilename)
      ).isEmpty)
    let state = destination.appendingPathComponent(QemuPlatformIdentityCodec.tpmDirectory)
    #expect(try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty)
    #expect(try QemuFileIdentity(state).mode & 0o7777 == 0o700)
    #expect(await files.writerStatus(in: destination) == .available)
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("runtime.json").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("runtime-intent.json").path))
    let registration = try await files.readMetadata(
      at: destination.appendingPathComponent("configuration.json"))
    let identity = try QemuFileIdentity(
      destination.appendingPathComponent(QemuPlatformIdentityCodec.filename))
    await #expect(throws: VMError.self) {
      try await VMCreation().create(
        fixture.configuration, at: destination, platform: platform, host: qemuCreationHost)
    }
    #expect(
      try await files.readMetadata(at: destination.appendingPathComponent("configuration.json"))
        == registration)
    #expect(
      try QemuFileIdentity(destination.appendingPathComponent(QemuPlatformIdentityCodec.filename))
        == identity)
  }

  @Test func freshVariablesAndEmptyPrivateDirectoriesAreIndependentBetweenVMs() async throws {
    let fixture = try QemuCreationFixture()
    defer { fixture.close() }
    let files = VMFiles()
    let record = try QemuPlatformIdentityCodec.encode(
      for: fixture.configuration, resources: fixture.resources)
    var second = fixture.configuration
    second.id = UUID()
    let secondRecord = try QemuPlatformIdentityCodec.encode(
      for: second, resources: fixture.resources)
    #expect(record != secondRecord)
    let firstDirectory = fixture.root.appendingPathComponent("first-files-only")
    let secondDirectory = fixture.root.appendingPathComponent("second-files-only")
    var held: [VMLock] = []
    for (directory, configuration, bytes) in [
      (firstDirectory, fixture.configuration, record),
      (secondDirectory, second, secondRecord),
    ] {
      try await files.createDirectory(directory)
      held.append(try VMLock(directory: directory, expectedVMID: configuration.id))
      try await files.createSparseDisk(
        at: directory.appendingPathComponent(configuration.diskFile), bytes: configuration.diskBytes
      )
      try QemuCreationIdentityIO.create(
        configuration: configuration, in: directory, variables: Data(), record: bytes)
    }
    let firstVariables = firstDirectory.appendingPathComponent(
      QemuPlatformIdentityCodec.variablesFilename)
    let secondVariables = secondDirectory.appendingPathComponent(
      QemuPlatformIdentityCodec.variablesFilename)
    let firstState = firstDirectory.appendingPathComponent(QemuPlatformIdentityCodec.tpmDirectory)
    let secondState = secondDirectory.appendingPathComponent(QemuPlatformIdentityCodec.tpmDirectory)
    #expect(try QemuFileIdentity(firstVariables).inode != QemuFileIdentity(secondVariables).inode)
    #expect(try QemuFileIdentity(firstState).inode != QemuFileIdentity(secondState).inode)
    // Arbitrary markers prove separate writable files/directories only. They are
    // not UEFI variable documents, TPM objects, guest keys or runtime evidence.
    try Data("file-only independent-write marker".utf8).write(to: firstVariables)
    try Data("file-only directory marker".utf8).write(
      to: firstState.appendingPathComponent("marker"))
    #expect(try Data(contentsOf: secondVariables).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: secondState.path).isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: firstDirectory.appendingPathComponent("configuration.json").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: secondDirectory.appendingPathComponent("configuration.json").path))
    withExtendedLifetime(held) {}
  }

  @Test(arguments: [
    "registration", "disk-bytes", "disk-alias", "disk-permissions", "existing-variables",
  ])
  func occupiedOrNonblankNamespaceIsPreservedWithoutIdentityPublication(kind: String) async throws {
    let fixture = try QemuCreationFixture()
    defer { fixture.close() }
    let directory = fixture.root.appendingPathComponent("private-new-namespace")
    let files = VMFiles()
    try await files.createDirectory(directory)
    let lock = try VMLock(directory: directory, expectedVMID: fixture.configuration.id)
    let disk = directory.appendingPathComponent(fixture.configuration.diskFile)
    try await files.createSparseDisk(at: disk, bytes: fixture.configuration.diskBytes)
    var sentinel: URL?
    switch kind {
    case "registration": sentinel = directory.appendingPathComponent("configuration.json")
    case "disk-bytes":
      let handle = try FileHandle(forWritingTo: disk)
      try handle.write(contentsOf: Data("preserved nonblank disk marker".utf8))
      try handle.synchronize()
      try handle.close()
    case "disk-alias":
      try FileManager.default.linkItem(
        at: disk, to: fixture.root.appendingPathComponent("disk-alias"))
    case "disk-permissions":
      try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: disk.path)
    default:
      sentinel = directory.appendingPathComponent(QemuPlatformIdentityCodec.variablesFilename)
    }
    let preserved = Data("preserved existing entry; not an identity".utf8)
    if let sentinel { try preserved.write(to: sentinel) }
    let before = try QemuFileIdentity(disk)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    let record = try QemuPlatformIdentityCodec.encode(
      for: fixture.configuration, resources: fixture.resources)
    #expect(throws: VMError.self) {
      try QemuCreationIdentityIO.create(
        configuration: fixture.configuration, in: directory, variables: Data(), record: record)
    }
    #expect(try QemuFileIdentity(disk) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
    if let sentinel { #expect(try Data(contentsOf: sentinel) == preserved) }
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(QemuPlatformIdentityCodec.filename).path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(QemuPlatformIdentityCodec.tpmDirectory).path))
    withExtendedLifetime(lock) {}
  }
}
