// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMCLI

/// Synthetic backend evidence only; these tests exercise real files, permits and
/// kernel leases, and never claim a Windows boot or initialized TPM is healthy.
@MainActor private final class RegisteredStoreBackend: BackendSettlementSource {
  let capabilities = BackendCapabilities(id: .qemuHVF, operations: [.start], limitations: [])
  var isActive = false
  var terminationObservation = BackendTerminationObservation.notObserved
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  private var session: UUID?
  private var attempted = false
  private var sealed = false
  private let establishesRunning: Bool
  init(establishesRunning: Bool = false) { self.establishesRunning = establishesRunning }
  func bindRecordedSession(sessionID: UUID) throws { session = sessionID }
  func start() async throws {
    attempted = true
    guard establishesRunning else { throw RegisteredWindowsPlatformFlush.failure() }
    isActive = true
  }
  func failEstablishedRuntime() {
    isActive = false
    terminationObservation = .runtimeExited
    onFailure?(RegisteredWindowsPlatformFlush.failure())
    onGuestStopped?()
  }
  func requestStop() throws { throw RegisteredWindowsPlatformFlush.failure() }
  func forceStop() async throws { throw RegisteredWindowsPlatformFlush.failure() }
  func pause() async throws { throw RegisteredWindowsPlatformFlush.failure() }
  func resume() async throws { throw RegisteredWindowsPlatformFlush.failure() }
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    guard session == sessionID, !sealed, !isActive else {
      throw RegisteredWindowsPlatformFlush.failure()
    }
    sealed = true
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID,
      launchDisposition: attempted
        ? (establishesRunning ? .completedAttempt : .failedAttempt) : .neverInvoked,
      terminationObservation: .notObserved)
  }
}

private final class RegisteredSyncProbe: @unchecked Sendable {
  private let mutex = NSLock()
  private var value = 0
  let failureAt: Int?
  let mutation: @Sendable (Int32, Int) throws -> Void
  init(
    failureAt: Int? = nil, mutation: @escaping @Sendable (Int32, Int) throws -> Void = { _, _ in }
  ) {
    self.failureAt = failureAt
    self.mutation = mutation
  }
  var count: Int { mutex.withLock { value } }
  func synchronize(_ fd: Int32) throws {
    let next = mutex.withLock {
      value += 1
      return value
    }
    try mutation(fd, next)
    if failureAt == next { throw RegisteredWindowsPlatformFlush.failure() }
    guard fsync(fd) == 0 else { throw RegisteredWindowsPlatformFlush.failure() }
  }
}

private struct RegisteredStoreFiles: Sendable {
  let directory: URL
  let configuration: VMConfiguration
  let lock: VMLock
  init(tpmNames: [String] = [], diskBytes: UInt64 = 64 << 30) async throws {
    directory = URL(
      fileURLWithPath: "/private/tmp/mvo-registered-store-\(UUID().uuidString)", isDirectory: true)
    let files = VMFiles()
    try await files.createDirectory(directory)
    var c = VMConfiguration(
      name: "Public registered file fixture", guest: .windows11, backend: .qemuHVF,
      diskBytes: diskBytes)
    c.diskFile = "registered-system.img"
    configuration = c
    try await files.writeNewMetadata(
      try ConfigurationCodec.encode(c), at: directory.appendingPathComponent("configuration.json"))
    try await files.createSparseDisk(
      at: directory.appendingPathComponent(c.diskFile), bytes: c.diskBytes)
    try await files.writeNewMetadata(
      Data("public variables marker".utf8), at: directory.appendingPathComponent("uefi-vars.json"))
    let tpm = directory.appendingPathComponent("tpm-state")
    try await files.createDirectory(tpm)
    for name in tpmNames {
      try await files.writeNewMetadata(
        name == ".lock" ? Data() : Data("public opaque TPM marker".utf8),
        at: tpm.appendingPathComponent(name))
    }
    lock = try VMLock(directory: directory, expectedVMID: c.id)
  }
  func close() { try? FileManager.default.removeItem(at: directory) }
  var disk: URL { directory.appendingPathComponent(configuration.diskFile) }
  var tpm: URL { directory.appendingPathComponent("tpm-state") }
  func preservedFiles() throws -> [String: RegisteredStoreFingerprint] {
    let members = try FileManager.default.contentsOfDirectory(atPath: tpm.path)
    let names =
      [configuration.diskFile, "configuration.json", "uefi-vars.json", "tpm-state"]
      + members.map { "tpm-state/\($0)" }
    return try Dictionary(
      uniqueKeysWithValues: names.map {
        ($0, try RegisteredStoreFingerprint(directory.appendingPathComponent($0)))
      })
  }
}

private struct RegisteredStoreFingerprint: Equatable {
  let device: dev_t, inode: ino_t, mode: mode_t, uid: uid_t, gid: gid_t
  let links: nlink_t, size: off_t, blocks: blkcnt_t
  let bytes: Data?
  init(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw RegisteredWindowsPlatformFlush.failure() }
    device = info.st_dev
    inode = info.st_ino
    mode = info.st_mode
    uid = info.st_uid
    gid = info.st_gid
    links = info.st_nlink
    size = info.st_size
    blocks = info.st_blocks
    bytes =
      info.st_mode & S_IFMT == S_IFREG && info.st_size <= 1_048_576
      ? try Data(contentsOf: url) : nil
  }
}

private actor CapturedRegisteredStore: RecordedRuntimeStore {
  let actual: RegisteredWindowsRuntimeStore
  private(set) var receipt: RuntimeSettlementReceipt?
  init(_ actual: RegisteredWindowsRuntimeStore) { self.actual = actual }
  func beginOwnership(in directory: URL, vmID: UUID, lock: VMLock) async throws
    -> RuntimeSessionPermit
  {
    try await actual.beginOwnership(in: directory, vmID: vmID, lock: lock)
  }
  func commitOwnership(in directory: URL, receipt: RuntimeSettlementReceipt) async throws {
    self.receipt = receipt
    try await actual.commitOwnership(in: directory, receipt: receipt)
  }
  func status(at url: URL) async -> VMFileStatus { await actual.status(at: url) }
  func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    try await actual.readOwnershipIntent(in: directory)
  }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await actual.inspectWritableFile(at: url)
  }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await actual.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    try await actual.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    try await actual.writeNewMetadata(data, at: url)
  }
  func atomicWrite(_ data: Data, at url: URL) async throws {
    try await actual.atomicWrite(data, at: url)
  }
}

@Suite(.serialized) @MainActor struct RegisteredWindowsRuntimeStoreTests {
  @Test(arguments: [UInt64(64 << 30), UInt64(96 << 30)])
  func neverInvokedCanSettleOnlyEmptyInitialTPMWithoutBootClaim(bytes: UInt64) async throws {
    let f = try await RegisteredStoreFiles(diskBytes: bytes)
    defer { f.close() }
    let probe = RegisteredSyncProbe()
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock,
      synchronize: probe.synchronize)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: RegisteredStoreBackend(), files: store)
    try await owner.settleOwnership()
    #expect(owner.ownershipState == .settled)
    #expect(probe.count == 4)
    let history = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: f.directory.appendingPathComponent("runtime.json")))
    #expect(history.snapshot.outcome == .failed && !history.snapshot.backendActive)
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .settled)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.directory.appendingPathComponent("blank-nvme.raw").path))
  }

  @Test(arguments: [[".lock"], [".lock", "tpm2-00.permall"]])
  func neverInvokedRejectsPreexistingTPMMembersWithoutMutation(names: [String]) async throws {
    let f = try await RegisteredStoreFiles(tpmNames: names)
    defer { f.close() }
    let before = try f.preservedFiles()
    let probe = RegisteredSyncProbe()
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock, synchronize: probe.synchronize)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: RegisteredStoreBackend(), files: store)
    await #expect(throws: VMError.self) { try await owner.settleOwnership() }
    #expect(owner.ownershipState == .recoveryRequired && probe.count == 0)
    #expect(try f.preservedFiles() == before)
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
    #expect(await VMFiles().writerStatus(in: f.directory) == .held)
  }

  @Test(arguments: [[], [".lock"], [".lock", "tpm2-00.permall"]])
  func failedAttemptAllowsOnlyEmptyOrFullTPMAndPreservesFailedOutcome(names: [String]) async throws
  {
    let f = try await RegisteredStoreFiles(tpmNames: names)
    defer { f.close() }
    let before = try f.preservedFiles()
    let probe = RegisteredSyncProbe()
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock, synchronize: probe.synchronize)
    let captured = CapturedRegisteredStore(store)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: RegisteredStoreBackend(), files: captured)
    await #expect(throws: VMError.self) { try await owner.perform(.start) }
    if names == [".lock"] {
      await #expect(throws: VMError.self) { try await owner.settleOwnership() }
      #expect(owner.ownershipState == .recoveryRequired && probe.count == 0)
      #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    } else {
      try await owner.settleOwnership()
      #expect(owner.ownershipState == .settled && probe.count == 4 + names.count)
      #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .settled)
    }
    let receipt = try #require(await captured.receipt)
    #expect(receipt.backend.launchDisposition == .failedAttempt)
    #expect(try f.preservedFiles() == before)
    let history = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: f.directory.appendingPathComponent("runtime.json")))
    #expect(history.snapshot.outcome == .failed && !history.snapshot.backendActive)
  }

  @Test(arguments: ["unknown", "directory-mode", "member-mode", "symlink", "hardlink", "lock-data"])
  func failedAttemptFullTPMRejectsUnsafeMetadataAndAliasesWithoutMutation(kind: String) async throws
  {
    let f = try await RegisteredStoreFiles(tpmNames: [".lock", "tpm2-00.permall"])
    defer { f.close() }
    let member = f.tpm.appendingPathComponent("tpm2-00.permall")
    switch kind {
    case "unknown":
      try await VMFiles().writeNewMetadata(Data(), at: f.tpm.appendingPathComponent("unknown"))
    case "directory-mode": #expect(chmod(f.tpm.path, 0o755) == 0)
    case "member-mode": #expect(chmod(member.path, 0o644) == 0)
    case "symlink":
      try FileManager.default.removeItem(at: member)
      try FileManager.default.createSymbolicLink(
        at: member, withDestinationURL: f.directory.appendingPathComponent("uefi-vars.json"))
    case "hardlink":
      try FileManager.default.linkItem(
        at: member, to: f.directory.appendingPathComponent("public-tpm-alias"))
    default: try Data([1]).write(to: f.tpm.appendingPathComponent(".lock"))
    }
    let before = try f.preservedFiles()
    let probe = RegisteredSyncProbe()
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock, synchronize: probe.synchronize)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: RegisteredStoreBackend(), files: store)
    await #expect(throws: VMError.self) { try await owner.perform(.start) }
    await #expect(throws: VMError.self) { try await owner.settleOwnership() }
    #expect(owner.ownershipState == .recoveryRequired && probe.count == 0)
    #expect(try f.preservedFiles() == before)
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
    #expect(await VMFiles().writerStatus(in: f.directory) == .held)
  }

  @Test(arguments: [[], [".lock"], [".lock", "tpm2-00.permall"]])
  func completedAttemptNeedsBothOpaqueMembersEvenWhenHistoryFailed(names: [String]) async throws {
    let f = try await RegisteredStoreFiles(tpmNames: names)
    defer { f.close() }
    let before = try f.preservedFiles()
    let probe = RegisteredSyncProbe()
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock, synchronize: probe.synchronize)
    let backend = RegisteredStoreBackend(establishesRunning: true)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: backend, files: store)
    try await owner.perform(.start)
    backend.failEstablishedRuntime()
    if names.count == 2 {
      try await owner.settleOwnership()
      #expect(owner.ownershipState == .settled && probe.count == 6)
    } else {
      await #expect(throws: VMError.self) { try await owner.settleOwnership() }
      #expect(owner.ownershipState == .recoveryRequired && probe.count == 0)
      #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
      #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    }
    #expect(try f.preservedFiles() == before)
    let history = try RuntimeHistoryCodec.decode(
      await VMFiles().readMetadata(at: f.directory.appendingPathComponent("runtime.json")))
    #expect(history.snapshot.outcome == .failed)
  }

  @Test func actualRegistrationAndWriterMustMatchBeforePermitReturns() async throws {
    let f = try await RegisteredStoreFiles()
    defer { f.close() }
    let store = try RegisteredWindowsRuntimeStore(configuration: f.configuration, lock: f.lock)
    await #expect(throws: VMError.self) {
      try await store.beginOwnership(in: f.directory, vmID: UUID(), lock: f.lock)
    }
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory) == nil)
    var changed = f.configuration
    changed.id = UUID()
    try ConfigurationCodec.encode(changed).write(
      to: f.directory.appendingPathComponent("configuration.json"))
    await #expect(throws: VMError.self) {
      try await store.beginOwnership(in: f.directory, vmID: f.configuration.id, lock: f.lock)
    }
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
    #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    #expect(throws: VMError.self) {
      try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
    }
  }

  @Test func otherActualOwnerReceiptAndUnbegunStoreCannotCommitThisPermit() async throws {
    let a = try await RegisteredStoreFiles()
    let b = try await RegisteredStoreFiles()
    defer {
      a.close()
      b.close()
    }
    let first = try RegisteredWindowsRuntimeStore(configuration: a.configuration, lock: a.lock)
    let captured = CapturedRegisteredStore(first)
    let owner = try await RecordedRuntimeOwner.open(
      in: a.directory, vmID: a.configuration.id,
      lock: a.lock, backend: RegisteredStoreBackend(), files: captured)
    await #expect(throws: VMError.self) { try await owner.perform(.start) }
    try await owner.settleOwnership()
    let receipt = try #require(await captured.receipt)
    #expect(receipt.backend.launchDisposition == .failedAttempt)
    let probe = RegisteredSyncProbe()
    let other = try RegisteredWindowsRuntimeStore(
      configuration: b.configuration, lock: b.lock,
      synchronize: probe.synchronize)
    _ = try await other.beginOwnership(in: b.directory, vmID: b.configuration.id, lock: b.lock)
    let protected = try b.preservedFiles()
    let before = try Data(contentsOf: b.directory.appendingPathComponent("runtime-intent.json"))
    await #expect(throws: VMError.self) {
      try await other.commitOwnership(in: b.directory, receipt: receipt)
    }
    #expect(probe.count == 0)
    #expect(try b.preservedFiles() == protected)
    #expect(
      try Data(contentsOf: b.directory.appendingPathComponent("runtime-intent.json")) == before)
    let unbegun = try RegisteredWindowsRuntimeStore(configuration: a.configuration, lock: a.lock)
    await #expect(throws: VMError.self) {
      try await unbegun.commitOwnership(in: a.directory, receipt: receipt)
    }
  }

  @Test func registrationDriftBeforeFinalCommitIsPreservedWithActualCustody() async throws {
    let f = try await RegisteredStoreFiles()
    defer { f.close() }
    let probe = RegisteredSyncProbe()
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock,
      synchronize: probe.synchronize)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: RegisteredStoreBackend(), files: store)
    var changed = f.configuration
    changed.name = "Changed public fixture"
    let bytes = try ConfigurationCodec.encode(changed)
    try bytes.write(to: f.directory.appendingPathComponent("configuration.json"))
    await #expect(throws: VMError.self) { try await owner.settleOwnership() }
    #expect(owner.ownershipState == .recoveryRequired && probe.count == 0)
    #expect(try Data(contentsOf: f.directory.appendingPathComponent("configuration.json")) == bytes)
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
  }

  @Test(arguments: Array(1...6))
  func everyFileTPMAndParentFlushFailureKeepsActualOwnerAndIntent(boundary: Int) async throws {
    let f = try await RegisteredStoreFiles(tpmNames: [".lock", "tpm2-00.permall"])
    defer { f.close() }
    let probe = RegisteredSyncProbe(failureAt: boundary)
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock,
      synchronize: probe.synchronize)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: RegisteredStoreBackend(), files: store)
    await #expect(throws: VMError.self) { try await owner.perform(.start) }
    let original = try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json"))
    await #expect(throws: VMError.self) { try await owner.settleOwnership() }
    #expect(owner.ownershipState == .recoveryRequired && probe.count == boundary)
    #expect(
      try Data(contentsOf: f.directory.appendingPathComponent("runtime-intent.json")) == original)
    #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    #expect(throws: VMError.self) {
      try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
    }
    await #expect(throws: VMError.self) { try await owner.settleOwnership() }
    #expect(probe.count == boundary)
  }

  @Test(arguments: [
    "registered-system.img", "uefi-vars.json", "tpm-state/.lock", "tpm-state/tpm2-00.permall",
  ])
  func parentFlushDetectsEarlierNamedInodeReplacement(name: String) async throws {
    let f = try await RegisteredStoreFiles(tpmNames: [".lock", "tpm2-00.permall"])
    defer { f.close() }
    let target = f.directory.appendingPathComponent(name)
    let displaced = target.appendingPathExtension("preserved")
    let probe = RegisteredSyncProbe { _, call in
      if call == 6 {
        try FileManager.default.moveItem(at: target, to: displaced)
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RegisteredWindowsPlatformFlush.failure() }
        defer { close(fd) }
        let length: off_t = name == "registered-system.img" ? off_t(f.configuration.diskBytes) : 0
        guard ftruncate(fd, length) == 0 else { throw RegisteredWindowsPlatformFlush.failure() }
      }
    }
    let store = try RegisteredWindowsRuntimeStore(
      configuration: f.configuration, lock: f.lock,
      synchronize: probe.synchronize)
    let owner = try await RecordedRuntimeOwner.open(
      in: f.directory, vmID: f.configuration.id,
      lock: f.lock, backend: RegisteredStoreBackend(), files: store)
    await #expect(throws: VMError.self) { try await owner.perform(.start) }
    await #expect(throws: VMError.self) { try await owner.settleOwnership() }
    #expect(owner.ownershipState == .recoveryRequired)
    #expect(FileManager.default.fileExists(atPath: displaced.path))
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
  }

  @Test func unsafeGeometryUnknownTPMAndAliasInputsPreserveUnsettledIntent() async throws {
    for kind in 0..<4 {
      let f = try await RegisteredStoreFiles(tpmNames: [".lock", "tpm2-00.permall"])
      defer { f.close() }
      switch kind {
      case 0:
        let fd = open(f.disk.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RegisteredWindowsPlatformFlush.failure() }
        #expect(ftruncate(fd, off_t(f.configuration.diskBytes - 1)) == 0)
        close(fd)
      case 1:
        try await VMFiles().writeNewMetadata(Data(), at: f.tpm.appendingPathComponent("unknown"))
      case 2:
        try FileManager.default.linkItem(
          at: f.disk, to: f.directory.appendingPathComponent("alias"))
      default:
        try await VMFiles().atomicWrite(Data([1]), at: f.tpm.appendingPathComponent(".lock"))
      }
      let store = try RegisteredWindowsRuntimeStore(configuration: f.configuration, lock: f.lock)
      let owner = try await RecordedRuntimeOwner.open(
        in: f.directory, vmID: f.configuration.id,
        lock: f.lock, backend: RegisteredStoreBackend(), files: store)
      await #expect(throws: VMError.self) { try await owner.perform(.start) }
      await #expect(throws: VMError.self) { try await owner.settleOwnership() }
      #expect(owner.ownershipState == .recoveryRequired)
      #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
    }
  }
}
