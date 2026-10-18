// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

private let inspectionHost = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)

private func inspectionDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-inspect-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return url
}

private struct Stamp: Equatable {
  let size: Int64
  let mode: mode_t
  let links: UInt16
  let modified: Int64
  let bytes: Data?
}

private func snapshot(_ directory: URL) throws -> [String: Stamp] {
  var result: [String: Stamp] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let url = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let bytes =
      info.st_mode & S_IFMT == S_IFREG && info.st_size <= 65_536 ? try Data(contentsOf: url) : nil
    result[name] = Stamp(
      size: info.st_size, mode: info.st_mode, links: info.st_nlink,
      modified: Int64(info.st_mtimespec.tv_sec), bytes: bytes)
  }
  return result
}

private func inspectionFixture(at directory: URL) async throws -> VMConfiguration {
  let files = VMFiles()
  let media = directory.appendingPathComponent("private-media.iso")
  try Data("transaction fixture only; not boot media".utf8).write(to: media)
  var c = VMConfiguration(
    name: "private-display-name", guest: .linux, backend: .appleVz, memoryBytes: 2 * 1_073_741_824,
    diskBytes: 1_073_741_824)
  c.installationMedia = media.path
  try await files.createSparseDisk(
    at: directory.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
  try Data("bounded identity fixture".utf8).write(
    to: directory.appendingPathComponent("machine-identity.bin"))
  try Data("unparsed firmware fixture".utf8).write(
    to: directory.appendingPathComponent("efi-variables.bin"))
  try await files.atomicWrite(
    ConfigurationCodec.encode(c), at: directory.appendingPathComponent("configuration.json"))
  return c
}

@Test func incompleteInspectionPreservesPartialFilesAndCreatesNoLock() async throws {
  let directory = try inspectionDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  try Data("preserve partial creation".utf8).write(to: directory.appendingPathComponent("disk.raw"))
  let before = try snapshot(directory)
  let report = await VMInspection().inspect(at: directory, host: inspectionHost)
  #expect(report.status == .incomplete)
  #expect(report.writer == .missing)
  #expect(report.findings.contains(where: { $0.code == "registration-missing" }))
  #expect(try snapshot(directory) == before)
}

@Test func structuralInspectionOmitsPrivateValuesAndPreservesFiles() async throws {
  let directory = try inspectionDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let c = try await inspectionFixture(at: directory)
  let before = try snapshot(directory)
  let report = await VMInspection().inspect(at: directory, host: inspectionHost)
  #expect(report.status == .filesMatchConfiguration)
  #expect(report.writer == .missing)
  #expect(!report.limitations.isEmpty)
  let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
  for value in [directory.path, c.name, c.id.uuidString, c.macAddress, "bounded identity fixture"] {
    #expect(!encoded.contains(value))
  }
  #expect(try snapshot(directory) == before)
}

@Test(.timeLimit(.minutes(1))) func malformedAndSpecialRegistrationAreBoundedReadOnlyFailures()
  async throws
{
  let directory = try inspectionDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let registration = directory.appendingPathComponent("configuration.json")
  for data in [Data("{broken".utf8), Data(repeating: 0, count: 65_537)] {
    try data.write(to: registration)
    let before = try snapshot(directory)
    #expect(
      await VMInspection().inspect(at: directory, host: inspectionHost).status == .needsReview)
    #expect(try snapshot(directory) == before)
  }
  try FileManager.default.removeItem(at: registration)
  #expect(mkfifo(registration.path, 0o600) == 0)
  let before = try snapshot(directory)
  #expect(await VMInspection().inspect(at: directory, host: inspectionHost).status == .needsReview)
  #expect(try snapshot(directory) == before)
}

@Test func inspectionDoesNotFollowUnsafeDiskPath() async throws {
  let directory = try inspectionDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  var c = try await inspectionFixture(at: directory)
  c.diskFile = "../outside.raw"
  try await VMFiles().atomicWrite(
    ConfigurationCodec.encode(c), at: directory.appendingPathComponent("configuration.json"))
  let before = try snapshot(directory)
  let report = await VMInspection().inspect(at: directory, host: inspectionHost)
  #expect(report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "unsafe-disk-path" }))
  #expect(!report.files.contains(where: { $0.role == "disk" }))
  #expect(try snapshot(directory) == before)
}

@Test func inspectionObservesCooperatingOwnerWithoutReplacingItsLock() async throws {
  let directory = try inspectionDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  _ = try await inspectionFixture(at: directory)
  let owner = try VMLock(directory: directory)
  let before = try snapshot(directory)
  let report = await VMInspection().inspect(at: directory, host: inspectionHost)
  #expect(report.status == .busy)
  #expect(report.writer == .held)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  #expect(try snapshot(directory) == before)
  withExtendedLifetime(owner) {}
}

@Test func inspectionFlagsWritableAliasesAndMissingMedia() async throws {
  let directory = try inspectionDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let c = try await inspectionFixture(at: directory)
  let disk = directory.appendingPathComponent(c.diskFile)
  #expect(link(disk.path, directory.appendingPathComponent("alias.raw").path) == 0)
  try FileManager.default.removeItem(at: directory.appendingPathComponent("private-media.iso"))
  let before = try snapshot(directory)
  let report = await VMInspection().inspect(at: directory, host: inspectionHost)
  #expect(report.status == .needsReview)
  #expect(report.findings.contains(where: { $0.code == "unsafe-disk" }))
  #expect(report.findings.contains(where: { $0.code == "media-unavailable" }))
  #expect(try snapshot(directory) == before)
}

@Test func inspectionRejectsSymlinkAndRemoteDirectoriesWithoutFollowingThem() async throws {
  let directory = try inspectionDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let link = directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
  let before = try snapshot(directory)
  #expect(await VMInspection().inspect(at: link, host: inspectionHost).status == .unavailable)
  let remote = try #require(URL(string: "file://remote.invalid/never-inspected.macopenvm"))
  let report = await VMInspection().inspect(at: remote, host: inspectionHost)
  #expect(report.status == .unavailable)
  #expect(report.files.isEmpty)
  #expect(try snapshot(directory) == before)
}
