// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMCore
@testable import VMStorage

private struct CoreUpgradeFixture {
  let directory: URL
  let configuration: VMConfiguration
  let transactionID: UUID
  let legacy: Data
  var journal: URL { directory.appendingPathComponent(DiskGrowthIntent.filename) }
  var archive: URL {
    directory.appendingPathComponent("disk-growth-\(transactionID)-schema1-completed.json")
  }

  static func create() async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("macOpenVM-core-upgrade-\(UUID())")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "fresh Core identity fixture", guest: .linux, backend: .qemuHVF,
      diskBytes: 1_073_741_824)
    let files = VMFiles()
    let original = try ConfigurationCodec.encode(configuration) + Data("\n ".utf8)
    let target = try StrictConfigurationDocument(original).replacingDiskBytes(
      with: configuration.diskBytes + 1024)
    try await files.atomicWrite(
      original, at: directory.appendingPathComponent("configuration.json"))
    let disk = directory.appendingPathComponent(configuration.diskFile)
    try await files.createSparseDisk(at: disk, bytes: configuration.diskBytes)
    let seed = Data("unchanged fresh Core raw seed".utf8)
    let fd = open(disk.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw coreUpgradeFailure() }
    let count = seed.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    let flushed = fsync(fd)
    close(fd)
    guard count == seed.count, flushed == 0 else { throw coreUpgradeFailure() }
    let transaction: UUID
    do {
      let lock = try VMLock(directory: directory, expectedVMID: configuration.id)
      let permit = try await files.beginDiskGrowth(
        in: directory, vmID: configuration.id, diskFile: configuration.diskFile,
        oldBytes: configuration.diskBytes, targetBytes: target.configuration.diskBytes,
        originalConfiguration: original, replacementConfiguration: target.bytes, lock: lock)
      transaction = permit.transactionID
      _ = try await files.commitDiskGrowth(permit)
      withExtendedLifetime((lock, permit)) {}
    }
    let journal = directory.appendingPathComponent(DiskGrowthIntent.filename)
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
    // Deliberately synthetic v1 metadata on a fresh fixture; no historical/remount claim.
    object["schemaVersion"] = 1
    object.removeValue(forKey: "directoryVolumeUUID")
    object.removeValue(forKey: "diskVolumeUUID")
    let legacy =
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      + Data("\n \n".utf8)
    try await files.atomicWrite(legacy, at: journal)
    return .init(
      directory: directory, configuration: configuration, transactionID: transaction, legacy: legacy
    )
  }

  func metadata() throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
    where name != configuration.diskFile {
      result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
    }
    return result
  }

  func runtime(_ condition: String) async throws {
    if condition == "absent" { return }
    let session = UUID()
    if condition != "intentOnly" {
      let record = RuntimeRecord(
        sessionID: session, sequence: 1, recordedAt: 10,
        snapshot: .init(
          state: condition == "active" || condition == "operation" || condition == "pending"
            || condition == "failed" ? .failed : .stopped,
          operation: condition == "operation" ? .stop : nil,
          backendActive: condition == "active",
          outcome: condition == "pending"
            ? .pending
            : condition == "failed" || condition == "active" || condition == "operation"
              ? .failed : condition == "forced" ? .forcedStopped : .guestStopped))
      var bytes = try RuntimeHistoryCodec.encode(record)
      if condition == "noncanonical" { bytes.append(Data("\n".utf8)) }
      if condition == "malformed" { bytes = Data("not runtime history".utf8) }
      try await VMFiles().atomicWrite(bytes, at: directory.appendingPathComponent("runtime.json"))
    }
    if condition != "historyOnly" {
      let recordedSession = condition == "differentSession" ? UUID() : session
      let vmID = condition == "differentVM" ? UUID() : configuration.id
      let state = condition == "unsettled" ? "unsettled" : "settled"
      let bytes = Data(
        "{\"schemaVersion\":1,\"vmID\":\"\(vmID)\",\"sessionID\":\"\(recordedSession)\",\"state\":\"\(state)\"}"
          .utf8)
      try await VMFiles().atomicWrite(
        bytes, at: directory.appendingPathComponent(RuntimeIntent.filename))
    }
  }

  func upgrade(using service: DiskGrowthIdentityUpgrade = .init()) async throws
    -> DiskGrowthIdentityUpgradeResult
  {
    try await service.upgrade(
      in: directory, expectedVMID: configuration.id, expectedTransactionID: transactionID,
      acknowledgement: .schema1OnlyAppsCannotOpenSchema2)
  }
}

private func coreUpgradeFailure() -> VMError {
  VMError(.storage, "Fresh Core upgrade fixture failed.", recovery: "Preserve evidence.")
}

private struct CoreUpgradeGapStore: DiskGrowthIdentityUpgradeStore {
  enum Change: Sendable { case history, configuration, journalBinding, writer, privateFailure }
  let change: Change
  let files = VMFiles()
  func writerStatus(in directory: URL) async -> WriterStatus {
    await files.writerStatus(in: directory)
  }
  func inspectDiskGrowthIdentityUpgrade(in directory: URL) async throws
    -> DiskGrowthIdentityUpgradeObservation
  {
    try await files.inspectDiskGrowthIdentityUpgrade(in: directory)
  }
  func upgradeCompletedDiskGrowthIdentity(
    in directory: URL, vmID: UUID, expectedTransactionID: UUID, lock: VMLock,
    observed: DiskGrowthIdentityUpgradeSnapshot?,
    validateStopped: (@Sendable (Data, Data?, RuntimeIntent?) throws -> Void)?
  ) async throws -> DiskGrowthIntent {
    switch change {
    case .history:
      try await files.atomicWrite(
        Data("changed in actor admission gap".utf8),
        at: directory.appendingPathComponent("runtime.json"))
    case .configuration:
      let url = directory.appendingPathComponent("configuration.json")
      let bytes = try Data(contentsOf: url) + Data("\n".utf8)
      try await files.atomicWrite(bytes, at: url)
    case .journalBinding:
      let url = directory.appendingPathComponent(DiskGrowthIntent.filename)
      let bytes = try Data(contentsOf: url)
      try await files.atomicWrite(bytes, at: url)
    case .writer:
      try FileManager.default.removeItem(at: directory.appendingPathComponent("writer.lock"))
    case .privateFailure:
      throw NSError(domain: "/private/should-not-be-disclosed", code: 1)
    }
    return try await files.upgradeCompletedDiskGrowthIdentity(
      in: directory, vmID: vmID, expectedTransactionID: expectedTransactionID, lock: lock,
      observed: observed, validateStopped: validateStopped)
  }
}

private actor CoreUpgradeNoAccessStore: DiskGrowthIdentityUpgradeStore {
  private(set) var calls = 0
  func writerStatus(in directory: URL) -> WriterStatus {
    calls += 1
    return .unavailable
  }
  func inspectDiskGrowthIdentityUpgrade(in directory: URL) throws
    -> DiskGrowthIdentityUpgradeObservation
  {
    calls += 1
    throw coreUpgradeFailure()
  }
  func upgradeCompletedDiskGrowthIdentity(
    in directory: URL, vmID: UUID, expectedTransactionID: UUID, lock: VMLock,
    observed: DiskGrowthIdentityUpgradeSnapshot?,
    validateStopped: (@Sendable (Data, Data?, RuntimeIntent?) throws -> Void)?
  ) throws -> DiskGrowthIntent {
    calls += 1
    throw coreUpgradeFailure()
  }
}

@Suite struct DiskGrowthIdentityUpgradeTests {
  @Test(arguments: ["absent", "guest", "forced", "failed"])
  func explicitUpgradePreservesRawAndEveryUnrelatedMetadataByte(runtime: String) async throws {
    let fixture = try await CoreUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.runtime(runtime)
    let before = try fixture.metadata()
    let files = VMFiles()
    let snapshot = try #require(
      try await files.inspectDiskGrowthIdentityUpgrade(in: fixture.directory).snapshot)
    let check = await DiskGrowthIdentityUpgrade().inspect(in: fixture.directory)
    #expect(check.status == .eligibleAtCheck && check.eligibleAtCheck && check.readOnly)
    #expect(check.vmID == fixture.configuration.id && check.transactionID == fixture.transactionID)
    #expect(try fixture.metadata() == before)
    let result = try await fixture.upgrade()
    #expect(result.changed && result.sourceSchemaVersion == 1 && result.targetSchemaVersion == 2)
    #expect(result.compatibilityNotice.contains("App79"))
    #expect(try Data(contentsOf: fixture.archive) == fixture.legacy)
    let after = try fixture.metadata()
    for (name, bytes) in before where name != DiskGrowthIntent.filename {
      #expect(after[name] == bytes)
    }
    #expect(after.count == before.count + 1)
    let stable = try #require(
      try await files.inspectDiskGrowthIdentityUpgrade(in: fixture.directory).snapshot)
    #expect(
      stable.record.schemaVersion == 2 && stable.record.transactionID == fixture.transactionID)
    // This compares actual raw device/inode/size/mode/owner/link/mtime/ctime facts too.
    #expect(stable.preservesStoppedState(of: snapshot))
    #expect(
      await DiskGrowthIdentityUpgrade().inspect(in: fixture.directory).status == .alreadyStable)
    await #expect(throws: VMError.self) { try await fixture.upgrade() }
    #expect(try fixture.metadata() == after)
  }

  @Test(arguments: [
    "historyOnly", "intentOnly", "differentSession", "differentVM", "unsettled", "active",
    "operation", "pending", "noncanonical", "malformed",
  ])
  func noFreeLockSubstitutesForStoppedRuntimeProof(condition: String) async throws {
    let fixture = try await CoreUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.runtime(condition)
    let before = try fixture.metadata()
    #expect(await DiskGrowthIdentityUpgrade().inspect(in: fixture.directory).status == .needsReview)
    await #expect(throws: VMError.self) { try await fixture.upgrade() }
    #expect(try fixture.metadata() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  @Test func missingOrHeldWriterNeverCreatesLockOrUpgrades() async throws {
    let fixture = try await CoreUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    do {
      let lock = try VMLock(
        existingDirectory: fixture.directory, expectedVMID: fixture.configuration.id)
      #expect(await DiskGrowthIdentityUpgrade().inspect(in: fixture.directory).status == .busy)
      await #expect(throws: VMError.self) { try await fixture.upgrade() }
      withExtendedLifetime(lock) {}
    }
    let writer = fixture.directory.appendingPathComponent("writer.lock")
    try FileManager.default.removeItem(at: writer)
    let before = try fixture.metadata()
    #expect(await DiskGrowthIdentityUpgrade().inspect(in: fixture.directory).status == .needsReview)
    await #expect(throws: VMError.self) { try await fixture.upgrade() }
    #expect(!FileManager.default.fileExists(atPath: writer.path))
    #expect(try fixture.metadata() == before)
  }

  @Test func explicitVMAndTransactionMustMatchExactly() async throws {
    let fixture = try await CoreUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let before = try fixture.metadata()
    for ids in [(UUID(), fixture.transactionID), (fixture.configuration.id, UUID())] {
      await #expect(throws: VMError.self) {
        try await DiskGrowthIdentityUpgrade().upgrade(
          in: fixture.directory, expectedVMID: ids.0, expectedTransactionID: ids.1,
          acknowledgement: .schema1OnlyAppsCannotOpenSchema2)
      }
    }
    #expect(try fixture.metadata() == before)
  }

  @Test(arguments: [CoreUpgradeGapStore.Change.history, .configuration, .journalBinding, .writer])
  fileprivate func actorAdmissionGapChangesAreRejectedBeforeArchive(
    change: CoreUpgradeGapStore.Change
  )
    async throws
  {
    let fixture = try await CoreUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let service = DiskGrowthIdentityUpgrade(files: CoreUpgradeGapStore(change: change))
    await #expect(throws: VMError.self) { try await fixture.upgrade(using: service) }
    #expect(try Data(contentsOf: fixture.journal) == fixture.legacy)
    #expect(!FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  @Test func unknownStorageErrorsAreSanitized() async throws {
    let fixture = try await CoreUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    do {
      _ = try await fixture.upgrade(
        using: .init(files: CoreUpgradeGapStore(change: .privateFailure)))
      Issue.record("Expected failure")
    } catch {
      #expect(error is VMError)
      #expect(!String(describing: error).contains("should-not-be-disclosed"))
    }
  }

  @Test(arguments: [
    DiskGrowthFaultPoint.afterIdentityUpgradeArchive, .afterIdentityUpgradeRename,
    .afterIdentityUpgradeFlush,
  ])
  func productBoundaryRetainsHonestPartialStateAfterDeterministicFault(point: DiskGrowthFaultPoint)
    async throws
  {
    let fixture = try await CoreUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.runtime("guest")
    let before = try fixture.metadata()
    let files = VMFiles()
    await files.injectDiskGrowthFault(point)
    await #expect(throws: VMError.self) {
      try await fixture.upgrade(using: .init(files: files))
    }
    #expect(try Data(contentsOf: fixture.archive) == fixture.legacy)
    let current = try #require(try await VMFiles().readDiskGrowthIntent(in: fixture.directory))
    #expect(current.schemaVersion == (point == .afterIdentityUpgradeArchive ? 1 : 2))
    for (name, bytes) in before where name != DiskGrowthIntent.filename {
      #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(name)) == bytes)
    }
  }

  @Test func zeroIdentityRefusesBeforeStorage() async throws {
    let store = CoreUpgradeNoAccessStore()
    let service = DiskGrowthIdentityUpgrade(files: store)
    let zero = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    for ids in [(zero, UUID()), (UUID(), zero)] {
      await #expect(throws: VMError.self) {
        try await service.upgrade(
          in: URL(fileURLWithPath: "/private/tmp/unopened-fixture"),
          expectedVMID: ids.0, expectedTransactionID: ids.1,
          acknowledgement: .schema1OnlyAppsCannotOpenSchema2)
      }
    }
    #expect(await store.calls == 0)
  }

  @Test(arguments: [
    "file:///private/tmp/example?query=x", "file:///private/tmp/example#fragment",
    "file://user@localhost/private/tmp/example",
    "file://user:password@localhost/private/tmp/example", "file:///private/tmp/one/../example",
    "https://localhost/private/tmp/example", "file://foreign/private/tmp/example",
  ])
  func decoratedOrAmbiguousURLsRefuseBeforeStorage(value: String) async throws {
    let store = CoreUpgradeNoAccessStore()
    let service = DiskGrowthIdentityUpgrade(files: store)
    let url = try #require(URL(string: value))
    #expect(await service.inspect(in: url).status == .needsReview)
    await #expect(throws: VMError.self) {
      try await service.upgrade(
        in: url, expectedVMID: UUID(), expectedTransactionID: UUID(),
        acknowledgement: .schema1OnlyAppsCannotOpenSchema2)
    }
    #expect(await store.calls == 0)
  }
}
