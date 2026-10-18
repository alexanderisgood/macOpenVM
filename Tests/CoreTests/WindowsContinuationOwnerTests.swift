// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMStorage

@testable import VMCore

/// Real storage/permit contract with the existing in-memory backend fixture only.
/// These marker files are not VM media and no backend process or guest is started.
private struct WindowsStoppedOwnerFixture {
  let directory: URL
  let vmID: UUID
  let previousSessionID: UUID
  let history: Data
  let intent: Data
  let persistent: [String: Data]
}

@MainActor
private func windowsStoppedOwnerFixture() async throws -> WindowsStoppedOwnerFixture {
  let (directory, vmID, lock, backend, owner) = try await recordedFixture()
  let persistent: [String: Data] = [
    "blank-nvme.raw": Data("installed disk marker".utf8),
    "firmware-code.fd": Data("read-only firmware marker".utf8),
    "uefi-vars.json": Data("persistent EFI identity marker".utf8),
    "tpm-state/state.bin": Data("persistent TPM identity marker".utf8),
  ]
  try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("tpm-state"), withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  for (name, bytes) in persistent {
    try await VMFiles().writeNewMetadata(bytes, at: directory.appendingPathComponent(name))
  }
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o400],
    ofItemAtPath: directory.appendingPathComponent("firmware-code.fd").path)
  try await owner.perform(.start)
  await owner.controller.finishPersistence()
  backend.runtimeExit()
  await owner.controller.finishPersistence()
  try await owner.settleOwnership()
  #expect(owner.ownershipState == .settled && owner.controller.state == .failed)
  let history = try Data(contentsOf: directory.appendingPathComponent("runtime.json"))
  let intent = try Data(contentsOf: directory.appendingPathComponent(RuntimeIntent.filename))
  let record = try RuntimeHistoryCodec.decode(history)
  #expect(record.sessionID == owner.sessionID)
  #expect(record.snapshot.outcome == .failed && !record.snapshot.backendActive)
  #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
  withExtendedLifetime(lock) {}
  return .init(
    directory: directory, vmID: vmID, previousSessionID: owner.sessionID,
    history: history, intent: intent, persistent: persistent)
}

private func windowsContinuationMetadata(_ f: WindowsStoppedOwnerFixture) throws -> [String: Data] {
  var bytes = f.persistent.mapValues { $0 }
  for name in Array(bytes.keys) {
    bytes[name] = try Data(contentsOf: f.directory.appendingPathComponent(name))
  }
  for name in ["runtime.json", RuntimeIntent.filename] {
    bytes[name] = try Data(contentsOf: f.directory.appendingPathComponent(name))
  }
  return bytes
}

@MainActor
@Test func windowsContinuationOwnerNewSessionPreservesOpaqueHistoryAndPersistentState() async throws
{
  let f = try await windowsStoppedOwnerFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  #expect(await VMFiles().writerStatus(in: f.directory) == .available)
  let archive = f.directory.appendingPathComponent(
    "runtime-\(f.previousSessionID.uuidString.lowercased()).json")
  let lock = try VMLock(directory: f.directory, expectedVMID: f.vmID)
  let backend = RecordedFixtureBackend()
  let owner = try await RecordedRuntimeOwner.open(
    in: f.directory, vmID: f.vmID, lock: lock, backend: backend)
  #expect(owner.vmID == f.vmID && owner.sessionID != f.previousSessionID)
  #expect(owner.ownershipState == .unsettled && !backend.isActive)
  let intent = try #require(try await VMFiles().readRuntimeIntent(in: f.directory))
  #expect(
    intent.vmID == f.vmID && intent.sessionID == owner.sessionID && intent.state == .unsettled)
  #expect(try Data(contentsOf: f.directory.appendingPathComponent("runtime.json")) == f.history)
  #expect(!FileManager.default.fileExists(atPath: archive.path))
  #expect(await VMFiles().writerStatus(in: f.directory) == .held)
  await #expect(throws: VMError.self) {
    try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.vmID, lock: lock, backend: RecordedFixtureBackend())
  }
  #expect(try await VMFiles().readRuntimeIntent(in: f.directory) == intent)
  try await owner.perform(.start)
  await owner.controller.finishPersistence()
  #expect(try Data(contentsOf: archive) == f.history)
  let current = try RuntimeHistoryCodec.decode(
    Data(contentsOf: f.directory.appendingPathComponent("runtime.json")))
  #expect(current.sessionID == owner.sessionID && current.snapshot.backendActive)
  for (name, bytes) in f.persistent {
    #expect(try Data(contentsOf: f.directory.appendingPathComponent(name)) == bytes)
  }
  backend.runtimeExit()
  await owner.controller.finishPersistence()
  try await owner.settleOwnership()
  #expect(owner.controller.state == .failed && owner.ownershipState == .settled)
  #expect(try Data(contentsOf: archive) == f.history)
  let ended = try RuntimeHistoryCodec.decode(
    Data(contentsOf: f.directory.appendingPathComponent("runtime.json")))
  #expect(ended.sessionID == owner.sessionID && ended.snapshot.outcome == .failed)
  #expect(!ended.snapshot.backendActive)
  withExtendedLifetime((lock, owner)) {}
}

@MainActor
@Test func windowsContinuationOwnerHeldAndInheritedWritersRejectWithoutMetadataChanges()
  async throws
{
  let f = try await windowsStoppedOwnerFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try windowsContinuationMetadata(f)
  var lock: VMLock? = try VMLock(directory: f.directory, expectedVMID: f.vmID)
  #expect(throws: VMError.self) { try VMLock(directory: f.directory, expectedVMID: f.vmID) }
  #expect(try windowsContinuationMetadata(f) == before)
  var inherited: VMLock.InheritedLease? = try #require(lock).duplicateForInheritance()
  lock = nil
  #expect(await VMFiles().writerStatus(in: f.directory) == .held)
  #expect(throws: VMError.self) { try VMLock(directory: f.directory, expectedVMID: f.vmID) }
  #expect(try windowsContinuationMetadata(f) == before)
  withExtendedLifetime(inherited) {}
  inherited = nil
  #expect(await VMFiles().writerStatus(in: f.directory) == .available)
  let admitted = try VMLock(directory: f.directory, expectedVMID: f.vmID)
  #expect(admitted.owns(f.directory))
  #expect(try windowsContinuationMetadata(f) == before)
}

@MainActor
@Test func windowsContinuationOwnerUnsettledPriorIntentRejectsWithoutOverwriting() async throws {
  let f = try await windowsStoppedOwnerFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let unsettled = String(decoding: f.intent, as: UTF8.self).replacingOccurrences(
    of: "\"state\":\"settled\"", with: "\"state\":\"unsettled\"")
  #expect(unsettled != String(decoding: f.intent, as: UTF8.self))
  try await VMFiles().atomicWrite(
    Data(unsettled.utf8), at: f.directory.appendingPathComponent(RuntimeIntent.filename))
  let before = try windowsContinuationMetadata(f)
  #expect(throws: VMError.self) { try VMLock(directory: f.directory, expectedVMID: f.vmID) }
  #expect(try windowsContinuationMetadata(f) == before)
}

@MainActor
@Test func windowsContinuationOwnerDifferentVMRejectsWithoutOverwriting() async throws {
  let f = try await windowsStoppedOwnerFixture()
  defer { try? FileManager.default.removeItem(at: f.directory) }
  let before = try windowsContinuationMetadata(f)
  #expect(throws: VMError.self) { try VMLock(directory: f.directory, expectedVMID: UUID()) }
  #expect(try windowsContinuationMetadata(f) == before)
  let lock = try VMLock(directory: f.directory, expectedVMID: f.vmID)
  await #expect(throws: VMError.self) {
    try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: UUID(), lock: lock, backend: RecordedFixtureBackend())
  }
  #expect(try windowsContinuationMetadata(f) == before)
}
