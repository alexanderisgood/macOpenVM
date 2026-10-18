// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private func intentDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macOpenVM-intent-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return directory
}

private func intentBytes(vmID: UUID, sessionID: UUID = UUID(), state: String = "settled") -> Data {
  Data(
    ("{\"schemaVersion\":1,\"vmID\":\"\(vmID.uuidString)\","
      + "\"sessionID\":\"\(sessionID.uuidString)\",\"state\":\"\(state)\"}").utf8)
}

private func writeIntentFixture(_ data: Data, in directory: URL) throws {
  let path = directory.appendingPathComponent(RuntimeIntent.filename)
  try data.write(to: path, options: .withoutOverwriting)
  guard chmod(path.path, 0o600) == 0 else {
    throw VMError(
      .storage, "Cannot prepare private test metadata.", recovery: "Preserve the fixture.")
  }
}

private final class WeakIntentOwner<Owner: AnyObject> {
  weak var value: Owner?
  init(_ value: Owner?) { self.value = value }
}

@Test func absentIntentPreservesExistingLockAdmission() throws {
  let directory = try intentDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let owner = try VMLock(directory: directory)
  #expect(owner.owns(directory))
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(RuntimeIntent.filename).path))
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  withExtendedLifetime(owner) {}
}

@Test func unsettledIntentBlocksReacquisitionAfterOriginalOwnerCloses() async throws {
  let directory = try intentDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let vmID = UUID()
  let files = VMFiles()
  var owner: VMLock? = try VMLock(directory: directory, expectedVMID: vmID)
  let witness = WeakIntentOwner(owner)
  var permit: RuntimeSessionPermit? = try await files.beginRuntimeSession(
    in: directory, forVMID: vmID, lock: try #require(owner))
  let record = try #require(try await files.readRuntimeIntent(in: directory))
  #expect(record.schemaVersion == 1 && record.state == .unsettled)
  #expect(record.vmID == vmID && record.sessionID == permit?.sessionID)
  do {
    let heldOwner = try #require(owner)
    #expect(permit?.owns(heldOwner) == true)
    withExtendedLifetime(heldOwner) {}
  }
  withExtendedLifetime(owner) {}
  owner = nil
  #expect(witness.value != nil)
  withExtendedLifetime(permit) {}
  permit = nil
  #expect(witness.value == nil)
  #expect(await files.writerStatus(in: directory) == .available)
  // Even the exact UUID read from disk cannot authorize continuation of unsettled intent.
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory, expectedVMID: record.vmID) }
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  #expect(try await files.readRuntimeIntent(in: directory) == record)
}

@Test func settledIntentRequiresCallerExpectedVMIdentity() async throws {
  let directory = try intentDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let vmID = UUID()
  let oldSession = UUID()
  let original = intentBytes(vmID: vmID, sessionID: oldSession)
  try writeIntentFixture(original, in: directory)
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory) }
  #expect(throws: VMError.self) { _ = try VMLock(directory: directory, expectedVMID: UUID()) }
  let owner = try VMLock(directory: directory, expectedVMID: vmID)
  await #expect(throws: VMError.self) {
    try await VMFiles().beginRuntimeSession(in: directory, forVMID: UUID(), lock: owner)
  }
  #expect(
    try Data(contentsOf: directory.appendingPathComponent(RuntimeIntent.filename)) == original)
  let permit = try await VMFiles().beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
  #expect(permit.vmID == vmID && permit.sessionID != oldSession && permit.owns(owner))
  let updated = try #require(try await VMFiles().readRuntimeIntent(in: directory))
  #expect(updated.state == .unsettled && updated.sessionID == permit.sessionID)
  var info = stat()
  #expect(lstat(directory.appendingPathComponent(RuntimeIntent.filename).path, &info) == 0)
  #expect(info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1)
  #expect(
    !((try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains {
      $0.hasPrefix(".runtime-intent-")
    }))
  withExtendedLifetime((owner, permit)) {}
}

@Test func strictIntentSchemaRejectsDuplicateExtraNestedAndMalformedRecords() throws {
  let vmID = UUID()
  let valid = String(decoding: intentBytes(vmID: vmID), as: UTF8.self)
  let cases = [
    "", "{}", "{", valid + " trailing",
    valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
    valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
    valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
    valid.replacingOccurrences(
      of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
    valid.replacingOccurrences(
      of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"\\u0073chemaVersion\":1"),
    valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":[[[1]]]"),
    valid.replacingOccurrences(of: "\"state\":\"settled\"", with: "\"state\":\"unknown\""),
    valid.replacingOccurrences(of: "}", with: ",\"extra\":\"ignored\"}"),
    String(repeating: " ", count: RuntimeIntent.maximumBytes + 1),
  ]
  for text in cases {
    let directory = try intentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(text.utf8)
    try writeIntentFixture(bytes, in: directory)
    #expect(throws: VMError.self) { _ = try VMLock(directory: directory, expectedVMID: vmID) }
    #expect(try Data(contentsOf: directory.appendingPathComponent(RuntimeIntent.filename)) == bytes)
  }
}

@Test func unsafeIntentMetadataAndAliasesAreRejectedWithoutFollowing() throws {
  let vmID = UUID()
  for kind in ["symlink", "hardlink", "fifo", "directory", "mode"] {
    let directory = try intentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let intent = directory.appendingPathComponent(RuntimeIntent.filename)
    let other = directory.appendingPathComponent("preserved.json")
    let original = intentBytes(vmID: vmID)
    switch kind {
    case "symlink":
      try writeIntentFixture(original, in: directory)
      try FileManager.default.moveItem(at: intent, to: other)
      #expect(symlink(other.path, intent.path) == 0)
    case "hardlink":
      try writeIntentFixture(original, in: directory)
      #expect(link(intent.path, other.path) == 0)
    case "fifo": #expect(mkfifo(intent.path, 0o600) == 0)
    case "directory":
      try FileManager.default.createDirectory(at: intent, withIntermediateDirectories: false)
    default:
      try writeIntentFixture(original, in: directory)
      #expect(chmod(intent.path, 0o640) == 0)
    }
    #expect(throws: VMError.self) { _ = try VMLock(directory: directory, expectedVMID: vmID) }
    if kind == "symlink" || kind == "hardlink" {
      #expect(try Data(contentsOf: other) == original)
    }
    var metadata = stat()
    #expect(lstat(intent.path, &metadata) == 0)
    #expect(kind != "symlink" || metadata.st_mode & S_IFMT == S_IFLNK)
    #expect(kind != "fifo" || metadata.st_mode & S_IFMT == S_IFIFO)
    #expect(kind != "mode" || metadata.st_mode & 0o7777 == 0o640)
  }
}

@Test func oneShotReservationIsSharedAcrossDifferentFileActors() async throws {
  let directory = try intentDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let vmID = UUID()
  let owner = try VMLock(directory: directory, expectedVMID: vmID)
  let first = VMFiles()
  let second = VMFiles()
  let attempts = [first, second].map { files in
    Task { () -> Result<RuntimeSessionPermit, any Error> in
      do {
        return .success(
          try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: owner))
      } catch { return .failure(error) }
    }
  }
  var permits: [RuntimeSessionPermit] = []
  var rejected = 0
  for attempt in attempts {
    switch await attempt.value {
    case .success(let permit): permits.append(permit)
    case .failure(let error):
      #expect((error as? VMError)?.code == .busy)
      rejected += 1
    }
  }
  #expect(permits.count == 1 && rejected == 1)
  #expect(
    try await VMFiles().readRuntimeIntent(in: directory)?.sessionID == permits.first?.sessionID)
  withExtendedLifetime((owner, permits)) {}
}

@Test func failedBeginFreezesOwnerWithoutAutomaticRetry() async throws {
  let directory = try intentDirectory()
  defer {
    _ = chmod(directory.path, 0o700)
    try? FileManager.default.removeItem(at: directory)
  }
  let vmID = UUID()
  let owner = try VMLock(directory: directory, expectedVMID: vmID)
  #expect(chmod(directory.path, 0o500) == 0)
  await #expect(throws: VMError.self) {
    try await VMFiles().beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
  }
  #expect(chmod(directory.path, 0o700) == 0)
  await #expect(throws: VMError.self) {
    try await VMFiles().beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
  }
  #expect(try await VMFiles().readRuntimeIntent(in: directory) == nil)
  withExtendedLifetime(owner) {}
}

@Test func replacementDirectoryCannotBorrowOriginalOwnersAuthority() async throws {
  let directory = try intentDirectory()
  let moved = directory.appendingPathExtension("preserved")
  defer {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: moved)
  }
  let vmID = UUID()
  let owner = try VMLock(directory: directory, expectedVMID: vmID)
  try FileManager.default.moveItem(at: directory, to: moved)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  #expect(!owner.owns(directory))
  await #expect(throws: VMError.self) {
    try await VMFiles().beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  #expect(
    !FileManager.default.fileExists(
      atPath: moved.appendingPathComponent(RuntimeIntent.filename).path))
  withExtendedLifetime(owner) {}
}

@Test func replacementWriterLockCannotBorrowOriginalOwnersAuthority() async throws {
  let directory = try intentDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let vmID = UUID()
  let owner = try VMLock(directory: directory, expectedVMID: vmID)
  let writer = directory.appendingPathComponent("writer.lock")
  let preserved = directory.appendingPathComponent("writer-preserved.lock")
  try FileManager.default.moveItem(at: writer, to: preserved)
  try Data().write(to: writer, options: .withoutOverwriting)
  #expect(chmod(writer.path, 0o600) == 0)
  #expect(!owner.owns(directory))
  await #expect(throws: VMError.self) {
    try await VMFiles().beginRuntimeSession(in: directory, forVMID: vmID, lock: owner)
  }
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(RuntimeIntent.filename).path))
  withExtendedLifetime(owner) {}
}

@Test(arguments: ["directory", "writer"])
func replacementInsideAnchoredBodyCannotPublishSuccess(_ kind: String) throws {
  let directory = try intentDirectory()
  let moved = directory.appendingPathExtension("preserved")
  defer {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: moved)
  }
  let owner = try VMLock(directory: directory, expectedVMID: UUID())
  var bodyRan = false
  #expect(throws: VMError.self) {
    _ = try owner.withRuntimeIntentDirectory { _ in
      bodyRan = true
      if kind == "directory" {
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      } else {
        let writer = directory.appendingPathComponent("writer.lock")
        try FileManager.default.moveItem(
          at: writer, to: directory.appendingPathComponent("writer-preserved.lock"))
        try Data().write(to: writer, options: .withoutOverwriting)
        #expect(chmod(writer.path, 0o600) == 0)
      }
      return "success must not escape"
    }
  }
  #expect(bodyRan && !owner.owns(directory))
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(RuntimeIntent.filename).path))
  withExtendedLifetime(owner) {}
}
