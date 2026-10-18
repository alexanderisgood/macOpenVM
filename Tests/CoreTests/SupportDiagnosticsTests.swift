// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMStorage

@testable import VMCore

private let diagnosticsResources = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
private let diagnosticsHost = DiagnosticHostFacts(
  resources: diagnosticsResources,
  osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 1),
  virtualizationSupported: true, virtualizationEntitled: false)
private let diagnosticsSecret = "PRIVATE_DIAGNOSTICS_TOKEN_NOT_FOR_EXPORT"

private struct DiagnosticsStamp: Equatable {
  let size: Int64
  let mode: mode_t
  let links: UInt16
  let inode: UInt64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let bytes: Data?
}

private func diagnosticsDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-diagnostics-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root
}

private func diagnosticsSnapshot(_ directory: URL) throws -> [String: DiagnosticsStamp] {
  var result: [String: DiagnosticsStamp] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let url = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw diagnosticsTestError() }
    result[name] = DiagnosticsStamp(
      size: info.st_size, mode: info.st_mode, links: info.st_nlink, inode: info.st_ino,
      modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      bytes: info.st_mode & S_IFMT == S_IFREG && info.st_size <= 65_536
        ? try Data(contentsOf: url) : nil)
  }
  return result
}

private func diagnosticsTestError() -> VMError {
  VMError(.storage, "Diagnostics test fixture failed.", recovery: "Inspect the synthetic fixture.")
}

@Test func supportDiagnosticsOmitsPlantedSecretsAndDoesNotModifyVMFiles() async throws {
  let root = try diagnosticsDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("private-user-name.macopenvm")
  let files = VMFiles()
  try await files.createDirectory(directory)
  let media = directory.appendingPathComponent("private-guest-file.iso")
  var mediaBytes = Data(diagnosticsSecret.utf8)
  mediaBytes.append(Data(repeating: 0, count: 512 - mediaBytes.count))
  try mediaBytes.write(to: media)
  var configuration = VMConfiguration(
    name: "private-user@example.invalid", guest: .linux, backend: .appleVz,
    memoryBytes: 2 * 1_073_741_824, diskBytes: 1_073_741_824)
  configuration.installationMedia = media.path
  configuration.kernelArguments = "console=hvc0 token=" + diagnosticsSecret
  try await files.createSparseDisk(
    at: directory.appendingPathComponent(configuration.diskFile), bytes: configuration.diskBytes)
  try await files.atomicWrite(
    ConfigurationCodec.encode(configuration),
    at: directory.appendingPathComponent("configuration.json"))
  for name in ["machine-identity.bin", "efi-variables.bin", "private-guest.log"] {
    try Data(diagnosticsSecret.utf8).write(to: directory.appendingPathComponent(name))
  }
  let session = UUID()
  let history = RuntimeRecord(
    sessionID: session, sequence: 2, recordedAt: 123,
    snapshot: .init(state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped))
  try await files.atomicWrite(
    RuntimeHistoryCodec.encode(history), at: directory.appendingPathComponent("runtime.json"))
  let before = try diagnosticsSnapshot(directory)
  let service = SupportDiagnostics(files: files)
  let report = await service.make(directory: directory, host: diagnosticsHost)
  let data = try report.jsonData()
  #expect(data.count <= DiagnosticReport.maximumBytes && data.last == 0x0A)
  #expect(report.vm?.status == .filesMatchConfiguration)
  #expect(report.vm?.history == .guestStopRecorded)
  #expect(report.vm?.writer == .missing)
  let text = String(decoding: data, as: UTF8.self)
  for secret in [
    diagnosticsSecret, directory.path, directory.lastPathComponent, media.path,
    configuration.name, configuration.id.uuidString, configuration.macAddress, session.uuidString,
    "private-guest.log", "private-user-name", "token=", "console=hvc0",
  ] {
    #expect(!text.contains(secret))
  }
  let destination = root.appendingPathComponent("shareable-report.json")
  try await service.export(report, to: destination)
  #expect(try Data(contentsOf: destination) == data)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["schemaVersion"] as? Int == 1)
  #expect(object["product"] as? String == "macOpenVM")
  #expect(try diagnosticsSnapshot(directory) == before)
  var info = stat()
  #expect(lstat(destination.path, &info) == 0)
  #expect(info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1)
  #expect(
    !FileManager.default.fileExists(atPath: directory.appendingPathComponent("writer.lock").path))
}

@Test func supportDiagnosticsWhitelistsInspectorFieldsInsteadOfRedactingStrings() async throws {
  let status = try JSONDecoder().decode(
    VMFileStatus.self,
    from: Data(
      "{\"kind\":\"regular\",\"bytes\":123,\"links\":1,\"ownedByCurrentUser\":true,\"otherWriteBits\":false}"
        .utf8))
  let original = VMInspectionReport(
    schemaVersion: 1, status: .needsReview, writer: .unavailable, history: .invalid,
    intent: .unsettled,
    files: [
      .init(role: "disk", status: status), .init(role: "disk", status: status),
      .init(role: diagnosticsSecret, status: status),
    ],
    findings: [
      .init(code: "unsafe-disk", message: diagnosticsSecret),
      .init(code: "unsafe-disk", message: "/Users/private-user/secret.txt"),
      .init(code: diagnosticsSecret, message: "192.0.2.123 aa:bb:cc:dd:ee:ff"),
    ], limitations: [diagnosticsSecret])
  let service = SupportDiagnostics(inspect: { _, _ in original })
  let report = await service.make(
    directory: URL(fileURLWithPath: "/private/synthetic"), host: diagnosticsHost)
  let vm = try #require(report.vm)
  #expect(vm.files.count == 1 && vm.files[0].role == .disk)
  #expect(vm.findings == [.unsafeDisk])
  #expect(vm.unrecognizedInspectionFields)
  #expect(vm.status == .needsReview && vm.writer == .unavailable)
  let text = String(decoding: try report.jsonData(), as: UTF8.self)
  for secret in [diagnosticsSecret, "/Users/private-user", "192.0.2.123", "aa:bb:cc:dd:ee:ff"] {
    #expect(!text.contains(secret))
  }
  #expect(!text.contains("\"bytes\"") && !text.contains("\"message\""))
}

@Test func supportDiagnosticsHasUnknownCapabilitiesWithoutFabricatingHealth() async throws {
  let service = SupportDiagnostics(inspect: { _, _ in
    Issue.record("Host-only diagnostics must not inspect a VM.")
    return VMInspectionReport(
      schemaVersion: 1, status: .unavailable, writer: .unavailable, history: .invalid,
      intent: .unavailable, files: [], findings: [], limitations: [])
  })
  let report = await service.make(
    host: DiagnosticHostFacts(
      resources: diagnosticsResources,
      osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 1)))
  #expect(report.vm == nil)
  #expect(report.host.virtualizationSupported == nil && report.host.virtualizationEntitled == nil)
  #expect(try report.jsonData() == report.jsonData())
  let invalid = DiagnosticHostFacts(
    resources: .init(cpuCount: Int.max, memoryBytes: UInt64.max),
    osVersion: .init(majorVersion: Int.max, minorVersion: -1, patchVersion: 0))
  #expect(invalid.cpuCount == nil && invalid.memoryMiB == nil && invalid.osVersion == nil)
}

@Test(arguments: ["regular", "symlink", "hardlink", "fifo"])
func supportDiagnosticsExclusiveExportPreservesExistingTargets(_ kind: String) async throws {
  let root = try diagnosticsDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let destination = root.appendingPathComponent("existing.json")
  let original = Data("existing VM data ".utf8) + Data(diagnosticsSecret.utf8)
  let linked = root.appendingPathComponent("preserved.json")
  if kind == "symlink" {
    try original.write(to: linked)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: linked)
  } else if kind == "hardlink" {
    try original.write(to: linked)
    #expect(link(linked.path, destination.path) == 0)
  } else if kind == "fifo" {
    #expect(mkfifo(destination.path, 0o600) == 0)
  } else {
    try original.write(to: destination)
  }
  let before = try diagnosticsSnapshot(root)
  let service = SupportDiagnostics()
  let report = await service.make(host: diagnosticsHost)
  await #expect(throws: VMError.self) { try await service.export(report, to: destination) }
  #expect(try diagnosticsSnapshot(root) == before)
}

@Test(arguments: [
  "configuration.json", "runtime.json", "runtime-intent.json", "disk-growth-intent.json",
  "opaque.log", ".metadata-secret.json",
])
func supportDiagnosticsRejectsVMArtifactAndNonJSONDestinations(_ name: String) async throws {
  let root = try diagnosticsDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = SupportDiagnostics()
  let report = await service.make(host: diagnosticsHost)
  await #expect(throws: VMError.self) {
    try await service.export(report, to: root.appendingPathComponent(name))
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func supportDiagnosticsDoesNotExportThroughRemoteOrSymlinkParents() async throws {
  let root = try diagnosticsDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let actual = root.appendingPathComponent("actual")
  let alias = root.appendingPathComponent("alias")
  try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
  let service = SupportDiagnostics()
  let report = await service.make(host: diagnosticsHost)
  let remote = try #require(URL(string: "https://example.invalid/report.json"))
  for destination in [remote, alias.appendingPathComponent("report.json")] {
    await #expect(throws: VMError.self) { try await service.export(report, to: destination) }
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
}
