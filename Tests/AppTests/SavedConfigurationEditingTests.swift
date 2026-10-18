// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

private struct EditingFixture {
  let root: URL
  let registration: URL
  let configuration: VMConfiguration
  let original: Data
  static func create(windows: Bool = false) async throws -> Self {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("editing-saved-\(UUID().uuidString).macopenvm")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let c = VMConfiguration(
      name: "Moved allocation", guest: windows ? .windows11 : .linux,
      backend: windows ? .qemuHVF : .appleVz, cpuCount: 12, memoryBytes: 24 << 30,
      diskBytes: windows ? 64 << 30 : 1 << 30)
    let original = try ConfigurationCodec.encode(c)
    let registration = root.appendingPathComponent("configuration.json")
    let files = VMFiles()
    try await files.writeNewMetadata(original, at: registration)
    try await files.createSparseDisk(
      at: root.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
    for name in ["machine-identity.bin", "efi-variables.bin", "tpm-state.bin"] {
      try await files.writeNewMetadata(
        Data("unchanged \(name)".utf8), at: root.appendingPathComponent(name))
    }
    let handle = try FileHandle(forWritingTo: root.appendingPathComponent(c.diskFile))
    try handle.write(contentsOf: Data("unchanged sparse disk witness".utf8))
    try handle.synchronize()
    try handle.close()
    return .init(root: root, registration: registration, configuration: c, original: original)
  }

  func diskWitness() throws -> Data {
    let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(configuration.diskFile))
    defer { try? handle.close() }
    return try handle.read(upToCount: 64) ?? Data()
  }
  func inventory() throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
  }
}

private final class EditingReviewOwner {}

@MainActor @Suite(.serialized) struct SavedConfigurationEditingTests {

  @Test func numericTypeExtremesRemainOnlyEditableScalarText() throws {
    let maximumAlignedMemory = UInt64.max - UInt64.max % 1_048_576
    let saved = VMConfiguration(
      name: "scalar-only", guest: .linux, backend: .appleVz,
      cpuCount: Int.max, memoryBytes: maximumAlignedMemory)
    try ConfigurationValidator.validateSaved(saved)
    let draft = HardwareSettingsDraft(configuration: saved)
    #expect(draft.cpuCountText == String(Int.max))
    #expect(draft.memoryMiBText == String(maximumAlignedMemory / 1_048_576))
    let small = HostResources(cpuCount: 4, memoryBytes: 4 << 30)
    #expect(draft.numericError(host: small) != nil)
    #expect(!SavedVMStartEligibility.permits(saved, host: small))
  }

  @Test(arguments: ["schema", "cpuNegative", "memoryAlignment", "windowsMinimum", "diskPath"])
  func editingReaderRejectsMalformedOrSemanticallyInvalidSavedRegistration(kind: String)
    async throws
  {
    let f = try await EditingFixture.create()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var saved = f.configuration
    switch kind {
    case "cpuNegative": saved.cpuCount = -1
    case "memoryAlignment": saved.memoryBytes += 1
    case "windowsMinimum":
      saved.guest = .windows11
      saved.backend = .qemuHVF
      saved.cpuCount = 1
    case "diskPath": saved.diskFile = "../host-file"
    default: break
    }
    var data = try ConfigurationCodec.encode(saved)
    if kind == "schema" {
      var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      object["schemaVersion"] = 2
      data = try JSONSerialization.data(withJSONObject: object)
    }
    try data.write(to: f.registration)
    let inventory = try f.inventory()
    let witness = try f.diskWitness()
    await #expect(throws: VMError.self) {
      try await VMLibrarySelection.readForEditing(
        at: f.registration, expectedID: f.configuration.id)
    }
    #expect(try Data(contentsOf: f.registration) == data)
    #expect(try f.inventory() == inventory && f.diskWitness() == witness)
  }
  @Test(arguments: [false, true])
  func smallerHostCanSelectReviewAndReduceResourcesThroughExistingWriter(windows: Bool) async throws
  {
    let f = try await EditingFixture.create(windows: windows)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let small = HostResources(cpuCount: 4, memoryBytes: windows ? 8 << 30 : 4 << 30)
    let filesBefore = try f.inventory()
    let diskBefore = try f.diskWitness()
    let saved = try await VMLibrarySelection.readForEditing(
      at: f.registration, expectedID: f.configuration.id)
    #expect(saved == f.configuration)
    #expect(!SavedVMStartEligibility.permits(saved, host: small))
    await #expect(throws: VMError.self) {
      try await VMLibrarySelection.read(at: f.registration, expectedID: saved.id, host: small)
    }

    // Actual Core review retains the small-host settings finding. Its before/after
    // identity/exact-configuration checks use the new explicit editing route.
    let owner = EditingReviewOwner()
    let context = VMReviewContext(
      configurationURL: f.registration, configuration: saved,
      owner: ObjectIdentifier(owner), generation: UUID())
    let report = try await NativeVMReviewInspector(host: small).inspect(context)
    #expect(report.findings.contains { $0.code == "settings-review" })
    #expect(try f.inventory() == filesBefore)
    #expect(try Data(contentsOf: f.registration) == f.original)
    #expect(try f.diskWitness() == diskBefore)
    #expect(
      !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("writer.lock").path))

    let draft = HardwareSettingsDraft(configuration: saved)
    #expect(draft.numericError(host: small) != nil)
    draft.cpuCountText = "2"
    draft.memoryMiBText = windows ? "4096" : "1024"
    let values = try draft.prepared(host: small)
    let result = try await HardwareSettings().update(
      in: f.root, cpuCount: values.cpuCount, memoryBytes: values.memoryBytes,
      expected: saved, host: small)
    var expected = saved
    expected.cpuCount = values.cpuCount
    expected.memoryBytes = values.memoryBytes
    #expect(result.configuration == expected && result.changed)
    #expect(SavedVMStartEligibility.permits(expected, host: small))
    #expect(
      try await VMLibrarySelection.read(at: f.registration, expectedID: saved.id, host: small)
        == expected)
    let backup = try #require(result.backupFile)
    #expect(try Data(contentsOf: f.root.appendingPathComponent(backup)) == f.original)
    #expect(try f.diskWitness() == diskBefore)
    for name in ["machine-identity.bin", "efi-variables.bin", "tpm-state.bin"] {
      #expect(
        try Data(contentsOf: f.root.appendingPathComponent(name)) == Data("unchanged \(name)".utf8))
    }

    let settledInventory = try f.inventory()
    await #expect(throws: VMError.self) {
      try await HardwareSettings().update(
        in: f.root, cpuCount: 2, memoryBytes: values.memoryBytes, expected: saved, host: small)
    }
    #expect(try f.inventory() == settledInventory)
    #expect(try ConfigurationCodec.decode(Data(contentsOf: f.registration)) == expected)
    withExtendedLifetime(owner) {}
  }

  @Test func editingReadPreservesExpectedIdentityAndRegistrationLocationChecks() async throws {
    let f = try await EditingFixture.create()
    defer { try? FileManager.default.removeItem(at: f.root) }
    await #expect(throws: VMError.self) {
      try await VMLibrarySelection.readForEditing(at: f.registration, expectedID: UUID())
    }
    await #expect(throws: VMError.self) {
      try await VMLibrarySelection.readForEditing(at: f.root.appendingPathComponent("other.json"))
    }
    #expect(try Data(contentsOf: f.registration) == f.original)
  }

  @Test func strictReaderKeepsExistingSourceCompatibleSignatureAndHostRefusal() async throws {
    let f = try await EditingFixture.create()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let read: (URL, UUID?, VMFiles, HostResources) async throws -> VMConfiguration = {
      url, id, files, host in
      try await VMLibrarySelection.read(at: url, expectedID: id, files: files, host: host)
    }
    let small = HostResources(cpuCount: 4, memoryBytes: 4 << 30)
    await #expect(throws: VMError.self) {
      try await read(f.registration, f.configuration.id, VMFiles(), small)
    }
    // The explicit new route has no host parameter or synthetic-host substitution.
    #expect(try await VMLibrarySelection.readForEditing(at: f.registration) == f.configuration)
  }
}
