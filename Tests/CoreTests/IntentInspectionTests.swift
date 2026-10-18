// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

private let intentInspectionHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)

private struct IntentInspectionFixture {
  let directory: URL
  let configuration: VMConfiguration

  static func create() async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "macOpenVM-intent-inspection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let files = VMFiles()
    var configuration = VMConfiguration(
      name: "private fixture label", guest: .linux, backend: .appleVz,
      memoryBytes: 2 * 1_073_741_824, diskBytes: 1_073_741_824)
    let media = directory.appendingPathComponent("private-media.img")
    configuration.installationMedia = media.path
    try await files.createSparseDisk(
      at: directory.appendingPathComponent(configuration.diskFile), bytes: configuration.diskBytes)
    for (name, content) in [
      ("private-media.img", "synthetic nonbootable media"),
      ("machine-identity.bin", "unparsed native identity"),
      ("efi-variables.bin", "unparsed auxiliary storage"),
    ] {
      try await files.writeNewMetadata(
        Data(content.utf8), at: directory.appendingPathComponent(name))
    }
    try await files.writeNewMetadata(
      ConfigurationCodec.encode(configuration),
      at: directory.appendingPathComponent("configuration.json"))
    return Self(directory: directory, configuration: configuration)
  }

  func writeIntent(vmID: UUID, sessionID: UUID, state: String) async throws {
    let data = Data(
      ("{\"schemaVersion\":1,\"vmID\":\"\(vmID.uuidString)\","
        + "\"sessionID\":\"\(sessionID.uuidString)\",\"state\":\"\(state)\"}").utf8)
    try await VMFiles().writeNewMetadata(
      data, at: directory.appendingPathComponent(RuntimeIntent.filename))
  }

  func stamp() throws -> [String: IntentInspectionStamp] {
    var result: [String: IntentInspectionStamp] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
      let path = directory.appendingPathComponent(name)
      var info = stat()
      guard lstat(path.path, &info) == 0 else {
        throw VMError(.storage, "Fixture stat failed.", recovery: "Preserve the fixture.")
      }
      let bytes =
        info.st_mode & S_IFMT == S_IFREG && info.st_size <= 65_536
        ? try Data(contentsOf: path) : nil
      result[name] = IntentInspectionStamp(
        device: info.st_dev, inode: info.st_ino, size: info.st_size, mode: info.st_mode,
        links: info.st_nlink, modifiedSeconds: info.st_mtimespec.tv_sec,
        modifiedNanoseconds: info.st_mtimespec.tv_nsec, changedSeconds: info.st_ctimespec.tv_sec,
        changedNanoseconds: info.st_ctimespec.tv_nsec, bytes: bytes)
    }
    return result
  }
}

private struct IntentInspectionStamp: Equatable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let mode: UInt16
  let links: UInt16
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int
  let bytes: Data?
}

@Test func intentInspectionReportsAbsentWithoutCreatingOwnership() async throws {
  let fixture = try await IntentInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let before = try fixture.stamp()
  let report = await VMInspection().inspect(at: fixture.directory, host: intentInspectionHost)
  #expect(report.intent == .notRecorded && report.writer == .missing)
  #expect(report.status == .filesMatchConfiguration)
  #expect(
    report.files.contains(where: { $0.role == "runtime-intent" && $0.status.kind == .missing }))
  #expect(try fixture.stamp() == before)
}

@Test func intentInspectionRequiresReviewAfterKernelOwnerReleasesAndOmitsIDs() async throws {
  let fixture = try await IntentInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let sessionID = UUID()
  do {
    let owner = try VMLock(directory: fixture.directory)
    try await fixture.writeIntent(
      vmID: fixture.configuration.id, sessionID: sessionID, state: "unsettled")
    withExtendedLifetime(owner) {}
  }
  let before = try fixture.stamp()
  let report = await VMInspection().inspect(at: fixture.directory, host: intentInspectionHost)
  #expect(report.intent == .unsettled && report.writer == .available)
  #expect(report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "runtime-intent-unsettled" }))
  let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
  for privateValue in [
    fixture.directory.path, fixture.configuration.name,
    fixture.configuration.id.uuidString, sessionID.uuidString, fixture.configuration.macAddress,
  ] {
    #expect(!encoded.contains(privateValue))
  }
  #expect(try fixture.stamp() == before)
}

@Test(arguments: [false, true])
func intentInspectionChecksSettledIdentityAgainstConfiguration(mismatched: Bool) async throws {
  let fixture = try await IntentInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  try await fixture.writeIntent(
    vmID: mismatched ? UUID() : fixture.configuration.id, sessionID: UUID(), state: "settled")
  let before = try fixture.stamp()
  let report = await VMInspection().inspect(at: fixture.directory, host: intentInspectionHost)
  #expect(report.intent == (mismatched ? .identityMismatch : .settled))
  #expect(report.status == (mismatched ? .needsReview : .filesMatchConfiguration))
  #expect(
    report.findings.contains(where: { $0.code == "runtime-intent-identity-mismatch" }) == mismatched
  )
  #expect(try fixture.stamp() == before)
}

@Test(arguments: ["fifo", "symlink", "oversized", "malformed"])
func intentInspectionRejectsUnsafeRecordsReadOnly(kind: String) async throws {
  let fixture = try await IntentInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let intent = fixture.directory.appendingPathComponent(RuntimeIntent.filename)
  switch kind {
  case "fifo": #expect(mkfifo(intent.path, 0o600) == 0)
  case "symlink":
    let target = fixture.directory.appendingPathComponent("preserved-sentinel")
    try await VMFiles().writeNewMetadata(Data("preserve target".utf8), at: target)
    #expect(symlink(target.path, intent.path) == 0)
  default:
    let data = kind == "oversized" ? Data(repeating: 32, count: 4097) : Data("{invalid".utf8)
    try await VMFiles().writeNewMetadata(data, at: intent)
  }
  let before = try fixture.stamp()
  let report = await VMInspection().inspect(at: fixture.directory, host: intentInspectionHost)
  #expect(report.intent == .invalid && report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "runtime-intent-invalid" }))
  #expect(try fixture.stamp() == before)
}

@Test func intentInspectionPreservesLivePermitAndHeldKernelLock() async throws {
  let fixture = try await IntentInspectionFixture.create()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let owner = try VMLock(directory: fixture.directory, expectedVMID: fixture.configuration.id)
  let permit = try await VMFiles().beginRuntimeSession(
    in: fixture.directory, forVMID: fixture.configuration.id, lock: owner)
  let before = try fixture.stamp()
  let report = await VMInspection().inspect(at: fixture.directory, host: intentInspectionHost)
  #expect(report.intent == .unsettled && report.writer == .held && report.status == .busy)
  #expect(permit.owns(owner))
  #expect(try fixture.stamp() == before)
  withExtendedLifetime((owner, permit)) {}
}
