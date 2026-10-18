// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMCLI

/// Public marker files and synthetic stopped records only. No VM, executable,
/// device, credential or guest is constructed; the filesystem/lock are real.
private struct ExternalFileFixture {
  let directory: URL
  let run: URL
  let record: WindowsExternalPreparation
  let lock: VMLock

  init() async throws {
    directory = URL(
      fileURLWithPath: "/private/tmp/mvo-external-contract-\(UUID().uuidString)", isDirectory: true)
    let files = VMFiles()
    try await files.createDirectory(directory)
    run = directory.appendingPathComponent("run")
    try await files.createDirectory(run)
    let vmID = try #require(WindowsExternalContinuationFiles.vmID)
    let previous = try #require(WindowsExternalContinuationFiles.previousSessionID)
    let history = try RuntimeHistoryCodec.encode(
      RuntimeRecord(
        sessionID: previous, sequence: 1, recordedAt: 1,
        snapshot: RuntimeSnapshot(
          state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped)))
    let intent = Data(
      "{\"schemaVersion\":1,\"vmID\":\"\(vmID.uuidString)\",\"sessionID\":\"\(previous.uuidString)\",\"state\":\"settled\"}\n"
        .utf8)
    let result = Data(
      "{\"status\":\"passed\",\"runtimeIntentSettled\":true,\"drainsFinished\":true,\"readonlyHashesPreserved\":true,\"qemuExit\":0,\"tpmExit\":0}"
        .utf8)
    let stop = Data("Public request correlation marker only".utf8)
    for (name, data) in [
      ("runtime.json", history), ("runtime-intent.json", intent), ("writer.lock", Data()),
      ("firmware-code.fd", Data("public firmware marker".utf8)),
      ("uefi-vars.json", Data("public variables marker".utf8)),
    ] {
      try await files.writeNewMetadata(data, at: directory.appendingPathComponent(name))
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: directory.appendingPathComponent("firmware-code.fd").path)
    try await files.createSparseDisk(
      at: directory.appendingPathComponent("blank-nvme.raw"), bytes: 64 << 30)
    let tpm = directory.appendingPathComponent("tpm-state")
    try await files.createDirectory(tpm)
    for (name, data) in [
      (".lock", Data()), ("tpm2-00.permall", Data("public opaque state marker".utf8)),
    ] {
      try await files.writeNewMetadata(data, at: tpm.appendingPathComponent(name))
    }
    for (name, data) in [
      ("previous-runtime.json", history), ("previous-intent.json", intent),
      ("previous-worker-result.json", result), ("normal-stop.json", stop),
    ] {
      try await files.writeNewMetadata(data, at: run.appendingPathComponent(name))
    }
    var root = stat()
    #expect(lstat(directory.path, &root) == 0)
    var resources: [String: WindowsExternalFileIdentity] = [:]
    for name in [
      "blank-nvme.raw", "firmware-code.fd", "uefi-vars.json", "writer.lock", "tpm-state",
    ] {
      var info = stat()
      #expect(lstat(directory.appendingPathComponent(name).path, &info) == 0)
      resources[name] = .init(
        device: UInt64(info.st_dev), inode: info.st_ino, byteCount: UInt64(info.st_size),
        mode: info.st_mode & 0o7777)
    }
    var members: [String: WindowsExternalTPMIdentity] = [:]
    for name in [".lock", "tpm2-00.permall"] {
      let path = tpm.appendingPathComponent(name)
      var info = stat()
      #expect(lstat(path.path, &info) == 0)
      members[name] = .init(
        device: UInt64(info.st_dev), inode: info.st_ino, byteCount: UInt64(info.st_size),
        mode: 0o600,
        sha256: windowsExternalDigest(try Data(contentsOf: path)))
    }
    record = .init(
      schemaVersion: 1, scope: "approved-same-vm-windows-external-preparation", vmID: vmID,
      previousSessionID: previous,
      sourceDirectory: "/public-source", destinationDirectory: directory.path,
      runDirectory: run.path,
      socketDirectory: "/private/tmp/mvo-win-external-0123456789abcdef",
      macAddress: "02:11:22:33:44:55",
      directoryDevice: UInt64(root.st_dev), directoryInode: root.st_ino,
      previousRuntimeSHA256: windowsExternalDigest(history),
      previousIntentSHA256: windowsExternalDigest(intent),
      previousWorkerResultSHA256: windowsExternalDigest(result),
      normalStopRecordSHA256: windowsExternalDigest(stop),
      actualOwnerReaped: true, allChildrenTerminal: true, drainsFinished: true, pipesClosed: true,
      leasesClosed: true,
      runtimeIntentSettled: true, normalStopRequested: true, relocationApproved: true,
      continuationApproved: true,
      forceStopUsed: false, qemuSignalled: false, tpmSignalled: false, workerExit: 0, qemuExit: 0,
      tpmExit: 0,
      resources: resources, tpmFiles: members)
    lock = try VMLock(directory: directory, expectedVMID: vmID)
  }
  func close() { try? FileManager.default.removeItem(at: directory) }
  func decode(_ data: Data, pin: String? = nil) throws -> WindowsExternalPreparation {
    try WindowsExternalAdmission.decode(
      data, sha256: pin ?? windowsExternalDigest(data), sourcePath: record.sourceDirectory,
      directory: directory, runDirectory: run, vmID: record.vmID,
      previousSessionID: record.previousSessionID)
  }
}

@Suite(.serialized) struct WindowsExternalContinuationTests {
  @Test func reviewedRecordRejectsWrongPinsUnknownDuplicateKeysTypesAndIdentity() async throws {
    let f = try await ExternalFileFixture()
    defer { f.close() }
    let original = try WindowsExternalAdmission.encode(f.record)
    #expect(try f.decode(original) == f.record)
    #expect(throws: (any Error).self) {
      try f.decode(original, pin: String(repeating: "0", count: 64))
    }
    for (key, value) in [
      ("schemaVersion", true as Any), ("workerExit", false as Any),
      ("normalStopRequested", false as Any),
      ("forceStopUsed", true as Any), ("vmID", UUID().uuidString as Any),
      ("previousSessionID", UUID().uuidString as Any),
      ("unexpected", 1 as Any),
    ] {
      var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
      object[key] = value
      let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      #expect(throws: (any Error).self) { try f.decode(changed) }
    }
    let duplicate = Data(
      ("{\"schemaVersion\":1," + String(decoding: original.dropFirst(), as: UTF8.self)).utf8)
    #expect(throws: (any Error).self) { try f.decode(duplicate) }
    let nestedDuplicate = Data(
      String(decoding: original, as: UTF8.self).replacingOccurrences(
        of: "\"mode\":384", with: "\"mode\":384,\"m\\u006fde\":384"
      ).utf8)
    #expect(throws: (any Error).self) { try f.decode(nestedDuplicate) }
  }

  @Test func retainedRecordsRequireTheActualWriterAndUnchangedPreviousState() async throws {
    let f = try await ExternalFileFixture()
    defer { f.close() }
    let files = WindowsExternalContinuationFiles()
    try await files.verifyRetainedState(
      f.record, directory: f.directory, runDirectory: f.run, lock: f.lock)
    #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    #expect(throws: VMError.self) {
      try VMLock(directory: f.directory, expectedVMID: f.record.vmID)
    }
    let history = f.directory.appendingPathComponent("runtime.json")
    let before = try Data(contentsOf: history)
    try (before + Data(" ".utf8)).write(to: history)
    await #expect(throws: (any Error).self) {
      try await files.verifyRetainedState(
        f.record, directory: f.directory, runDirectory: f.run, lock: f.lock)
    }
    #expect(try Data(contentsOf: history) == before + Data(" ".utf8))
  }

  @Test func privateSnapshotsAndRetainedTPMRejectAliasesPermissionsAndByteDrift() async throws {
    let f = try await ExternalFileFixture()
    defer { f.close() }
    let snapshot = f.run.appendingPathComponent("normal-stop.json")
    try FileManager.default.linkItem(at: snapshot, to: f.run.appendingPathComponent("alias"))
    #expect(throws: (any Error).self) {
      try WindowsExternalFileIO.readPrivate(snapshot, maximum: 32768)
    }
    try FileManager.default.removeItem(at: f.run.appendingPathComponent("alias"))
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: snapshot.path)
    #expect(throws: (any Error).self) {
      try WindowsExternalFileIO.readPrivate(snapshot, maximum: 32768)
    }
    let state = f.directory.appendingPathComponent("tpm-state/tpm2-00.permall")
    let before = try Data(contentsOf: state)
    var changed = before
    changed[0] ^= 1
    try changed.write(to: state)
    #expect(throws: (any Error).self) {
      try WindowsExternalFileIO.verifyResources(f.record, directory: f.directory)
    }
    #expect(try Data(contentsOf: state) == changed)
  }

  @Test func realPermitFlushesBoundedFilesAndPreservesCustodyOnEveryFlushFailure() async throws {
    let f = try await ExternalFileFixture()
    defer { f.close() }
    let permit = try await VMFiles().beginRuntimeSession(
      in: f.directory, forVMID: f.record.vmID, lock: f.lock)
    let intent = try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json"))
    var count = 0
    try permit.withSettlementDirectory(in: f.directory) { anchor in
      try WindowsExternalPlatformFlush.flush(at: anchor) { fd in
        count += 1
        guard fsync(fd) == 0 else { throw windowsExternalFailure() }
      }
    }
    #expect(count == 6)
    for boundary in 1...6 {
      var calls = 0
      #expect(throws: VMError.self) {
        try permit.withSettlementDirectory(in: f.directory) { anchor in
          try WindowsExternalPlatformFlush.flush(at: anchor) { fd in
            calls += 1
            if calls == boundary { throw windowsExternalFailure() }
            guard fsync(fd) == 0 else { throw windowsExternalFailure() }
          }
        }
      }
      #expect(calls == boundary)
      #expect(
        try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json")) == intent)
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    }
  }
}
