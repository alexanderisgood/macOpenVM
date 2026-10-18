// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Combine
import Foundation
import Testing

@testable import MacOpenVMApp
@testable import VMCore
@testable import VMStorage

@MainActor private final class UpgradePreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class UpgradeWindow: NSWindow {
  var controlledSheet: NSWindow?
  override var attachedSheet: NSWindow? { controlledSheet }
  override func makeKeyAndOrderFront(_ sender: Any?) {}
}

/// Pauses surround actual ordinary Core outcomes. No eligible report or success is fabricated.
@MainActor
private final class ControlledMetadataUpgrade: DesktopDiskMetadataUpgrading, DesktopDiskGrowing {
  var growthCalls = 0
  func grow(in directory: URL, expected: VMConfiguration, targetBytes: UInt64) async throws
    -> VMConfiguration
  {
    growthCalls += 1
    return try await NativeDesktopDiskGrowth().grow(
      in: directory, expected: expected, targetBytes: targetBytes)
  }
  var pauseInspection = false
  var pauseBeforeUpgrade = false
  var pauseAfterUpgrade = false
  var failDelivery = false
  var pending: CheckedContinuation<Void, Never>?
  var inspectionCalls = 0
  var upgradeCalls = 0
  var mutationAttempts = 0
  var committed: DiskGrowthIdentityUpgradeResult?
  var coreFailure: Error?
  var statuses: [DiskGrowthIdentityUpgradeInspection.Status] = []
  var faultCore: DiskGrowthIdentityUpgrade?

  func inspect(
    at registration: URL, expected: VMConfiguration, accepting: @MainActor () -> Bool
  ) async throws -> DiskGrowthIdentityUpgradeInspection {
    inspectionCalls += 1
    let result = try await NativeDesktopDiskMetadataUpgrade().inspect(
      at: registration, expected: expected, accepting: accepting)
    statuses.append(result.status)
    if pauseInspection {
      pauseInspection = false
      await withCheckedContinuation { pending = $0 }
    }
    return result
  }

  func upgrade(
    at registration: URL, expected: VMConfiguration, inspectedVMID: UUID,
    transactionID: UUID, acknowledgement: DiskGrowthIdentityUpgradeAcknowledgement,
    accepting: @MainActor () -> Bool
  ) async throws -> DiskGrowthIdentityUpgradeResult {
    upgradeCalls += 1
    if pauseBeforeUpgrade {
      pauseBeforeUpgrade = false
      await withCheckedContinuation { pending = $0 }
    }
    guard accepting() else { throw CancellationError() }
    do {
      let result: DiskGrowthIdentityUpgradeResult
      if let faultCore {
        // Same real expected-configuration precheck, then a real fault-injected Core transaction.
        let saved = try await VMLibrarySelection.readForEditing(
          at: registration, expectedID: expected.id)
        guard saved == expected, accepting() else { throw CancellationError() }
        mutationAttempts += 1
        result = try await faultCore.upgrade(
          in: registration.deletingLastPathComponent(), expectedVMID: inspectedVMID,
          expectedTransactionID: transactionID, acknowledgement: acknowledgement)
      } else {
        mutationAttempts += 1
        result = try await NativeDesktopDiskMetadataUpgrade().upgrade(
          at: registration, expected: expected, inspectedVMID: inspectedVMID,
          transactionID: transactionID, acknowledgement: acknowledgement, accepting: accepting)
      }
      committed = result
      if pauseAfterUpgrade {
        pauseAfterUpgrade = false
        await withCheckedContinuation { pending = $0 }
      }
      if failDelivery { throw NSError(domain: "private post-commit delivery detail", code: 1) }
      return result
    } catch {
      coreFailure = error
      throw error
    }
  }

  func release() {
    pauseInspection = false
    pauseBeforeUpgrade = false
    pauseAfterUpgrade = false
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

/// Existing Core/Storage fixture pattern on disposable files. The v1 record is deliberately
/// synthesized after actual fresh disk growth; this claims no historical/remount/native proof.
private struct MetadataUpgradeFixture {
  let directory: URL
  let configuration: VMConfiguration
  let transactionID: UUID
  let legacy: Data
  var registration: URL { directory.appendingPathComponent("configuration.json") }
  var journal: URL { directory.appendingPathComponent(DiskGrowthIntent.filename) }
  var archive: URL {
    directory.appendingPathComponent("disk-growth-\(transactionID)-schema1-completed.json")
  }

  static func create(kind: String = "eligible", runtime: String = "absent") async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("desktop-metadata-upgrade-\(UUID())")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let original = VMConfiguration(
      name: "Disposable compatibility", guest: .linux, backend: .appleVz,
      cpuCount: 1, memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let files = VMFiles()
    let bytes = try ConfigurationCodec.encode(original) + Data("\n ".utf8)
    let target = try StrictConfigurationDocument(bytes).replacingDiskBytes(
      with: original.diskBytes + 1024)
    try await files.atomicWrite(bytes, at: directory.appendingPathComponent("configuration.json"))
    let disk = directory.appendingPathComponent(original.diskFile)
    try await files.createSparseDisk(at: disk, bytes: original.diskBytes)
    let handle = try FileHandle(forWritingTo: disk)
    try handle.write(contentsOf: Data("unchanged disposable raw seed".utf8))
    try handle.synchronize()
    try handle.close()
    try await files.atomicWrite(
      Data("generated identity fixture".utf8),
      at: directory.appendingPathComponent("machine-identity.bin"))
    try await files.atomicWrite(
      Data("generated EFI fixture".utf8), at: directory.appendingPathComponent("efi-variables.bin"))
    let transaction: UUID
    do {
      let lock = try VMLock(directory: directory, expectedVMID: original.id)
      let permit = try await files.beginDiskGrowth(
        in: directory, vmID: original.id, diskFile: original.diskFile,
        oldBytes: original.diskBytes, targetBytes: target.configuration.diskBytes,
        originalConfiguration: bytes, replacementConfiguration: target.bytes, lock: lock)
      transaction = permit.transactionID
      if kind != "pending" { _ = try await files.commitDiskGrowth(permit) }
      withExtendedLifetime((lock, permit)) {}
    }
    let journal = directory.appendingPathComponent(DiskGrowthIntent.filename)
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
    if kind != "stable" {
      object["schemaVersion"] = 1
      object.removeValue(forKey: "directoryVolumeUUID")
      object.removeValue(forKey: "diskVolumeUUID")
    }
    if kind == "legacy-proof" {
      object["directoryDevice"] =
        (try #require(object["directoryDevice"] as? NSNumber)).int64Value + 1
    }
    let legacy =
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      + Data("\n \n".utf8)
    if kind != "stable" { try await files.atomicWrite(legacy, at: journal) }
    if kind == "not-needed" { try FileManager.default.removeItem(at: journal) }
    if kind == "needs-review" {
      try await files.atomicWrite(
        Data("invalid recorded runtime".utf8), at: directory.appendingPathComponent("runtime.json"))
    } else if runtime != "absent" {
      let session = UUID()
      let history = RuntimeRecord(
        sessionID: session, sequence: 1, recordedAt: 10,
        snapshot: .init(
          state: runtime == "failed" ? .failed : .stopped, operation: nil,
          backendActive: false,
          outcome: runtime == "failed"
            ? .failed : runtime == "forced" ? .forcedStopped : .guestStopped))
      try await files.atomicWrite(
        RuntimeHistoryCodec.encode(history), at: directory.appendingPathComponent("runtime.json"))
      try await files.atomicWrite(
        Data(
          "{\"schemaVersion\":1,\"vmID\":\"\(original.id)\",\"sessionID\":\"\(session)\",\"state\":\"settled\"}"
            .utf8),
        at: directory.appendingPathComponent(RuntimeIntent.filename))
    }
    return .init(
      directory: directory,
      configuration: try ConfigurationCodec.decode(
        Data(contentsOf: directory.appendingPathComponent("configuration.json"))),
      transactionID: transaction, legacy: legacy)
  }

  func metadata() throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
    where name != configuration.diskFile {
      result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
    }
    return result
  }

  struct Raw: Equatable {
    let length: UInt64
    let first: Data
    let last: Data
  }
  func raw() throws -> Raw {
    let file = try FileHandle(
      forReadingFrom: directory.appendingPathComponent(configuration.diskFile))
    defer { try? file.close() }
    let length = try file.seekToEnd()
    try file.seek(toOffset: 0)
    let first = try file.read(upToCount: 512) ?? Data()
    try file.seek(toOffset: length - 512)
    return .init(length: length, first: first, last: try file.read(upToCount: 512) ?? Data())
  }
}

/// Existing Core-test admission-gap pattern: real observations/lock/storage, deliberate file change.
private struct UpgradeAdmissionGapStore: DiskGrowthIdentityUpgradeStore {
  let change: String
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
    case "history":
      try await files.atomicWrite(
        Data("changed real history in admission gap".utf8),
        at: directory.appendingPathComponent("runtime.json"))
    case "configuration":
      let url = directory.appendingPathComponent("configuration.json")
      try await files.atomicWrite(Data(contentsOf: url) + Data("\n".utf8), at: url)
    case "journal":
      let url = directory.appendingPathComponent(DiskGrowthIntent.filename)
      try await files.atomicWrite(Data(contentsOf: url), at: url)
    default:
      try FileManager.default.removeItem(at: directory.appendingPathComponent("writer.lock"))
    }
    return try await files.upgradeCompletedDiskGrowthIdentity(
      in: directory, vmID: vmID, expectedTransactionID: expectedTransactionID,
      lock: lock, observed: observed, validateStopped: validateStopped)
  }
}

@MainActor @Suite(.serialized) struct DiskMetadataUpgradeTests {
  private struct Confirmation {
    let draft: UUID
    let check: UUID
    let vmID: UUID
    let transaction: UUID
  }

  private func window() -> UpgradeWindow {
    let owner = UpgradeWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    return owner
  }

  private func selected(_ fixture: MetadataUpgradeFixture, service: ControlledMetadataUpgrade)
    async throws -> (DesktopSession, UpgradeWindow)
  {
    _ = NSApplication.shared
    let owner = window()
    let s = DesktopSession(
      library: VMLibrary(preferences: UpgradePreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      diskGrowth: service, diskMetadataUpgrade: service)
    s.window = owner
    try await s.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.configuration.id)
    try #require(s.configuration == fixture.configuration && s.canEditDiskCapacity)
    s.showDiskCapacitySettings()
    try #require(s.editingDiskCapacity && s.canInspectDiskMetadata)
    return (s, owner)
  }

  private func wait(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate())
  }

  private func inspect(_ s: DesktopSession) async throws -> UUID {
    s.showDiskMetadataUpgrade(draft: s.diskCapacityDraftNonce)
    let nonce = try #require(s.diskMetadataDraftNonce)
    try await wait { !s.preparing }
    return nonce
  }

  private func confirmation(_ s: DesktopSession, nonce: UUID) throws -> Confirmation {
    let result = try #require(s.diskMetadataInspection)
    try #require(result.status == .eligibleAtCheck && result.eligibleAtCheck)
    return .init(
      draft: nonce, check: s.diskMetadataCheckGeneration,
      vmID: try #require(result.vmID), transaction: try #require(result.transactionID))
  }

  private func acknowledge(_ c: Confirmation, session: DesktopSession) {
    session.acknowledgeDiskMetadataUpgrade(true, draft: c.draft, check: c.check)
  }

  private func confirm(_ c: Confirmation, session: DesktopSession) {
    session.confirmDiskMetadataUpgrade(
      draft: c.draft, check: c.check,
      inspectedVMID: c.vmID, transactionID: c.transaction)
  }

  @Test(arguments: ["absent", "guest", "forced", "failed"])
  func explicitAcknowledgementCommitsRealCoreUpgradeAndReinspectsWithoutChangingTheVM(
    runtime: String
  ) async throws {
    let f = try await MetadataUpgradeFixture.create(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let before = try f.metadata()
    let raw = try f.raw()
    let original = try #require(
      try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: f.directory).snapshot)
    let nonce = try await inspect(s)
    #expect(try f.metadata() == before && f.raw() == raw)
    let c = try confirmation(s, nonce: nonce)
    #expect(!s.canConfirmDiskMetadataUpgrade)
    acknowledge(c, session: s)
    #expect(s.canConfirmDiskMetadataUpgrade && s.isBusy && !s.canEditNetworkSettings)
    s.showLibrary()
    s.showHardwareSettings()
    s.showVMReview()
    #expect(!s.showingLibrary && !s.editingHardware && !s.reviewingVM)
    confirm(c, session: s)
    confirm(c, session: s)
    try await wait { !s.preparing }
    #expect(service.upgradeCalls == 1 && service.committed?.vmID == f.configuration.id)
    #expect(service.statuses == [.eligibleAtCheck, .alreadyStable])
    #expect(s.diskMetadataInspection?.status == .alreadyStable && !s.canConfirmDiskMetadataUpgrade)
    #expect(s.diskMetadataMessage?.contains("was upgraded") == true && s.errorMessage == nil)
    #expect(s.configuration == f.configuration && s.selectedConfigurationURL == f.registration)
    #expect(s.backend == nil && !s.isActive && !s.needsOwnershipRecovery && s.state == .stopped)
    #expect(try Data(contentsOf: f.archive) == f.legacy && f.raw() == raw)
    let after = try f.metadata()
    for (name, bytes) in before where name != DiskGrowthIntent.filename {
      #expect(after[name] == bytes)
    }
    #expect(after.count == before.count + 1)
    let stable = try #require(
      try await VMFiles().inspectDiskGrowthIdentityUpgrade(in: f.directory).snapshot)
    #expect(stable.record.schemaVersion == 2 && stable.record.transactionID == f.transactionID)
    #expect(stable.preservesStoppedState(of: original))
    withExtendedLifetime(owner) {}
  }

  @Test func cancelNoAcknowledgementAndRetainedChecksNeverWrite() async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let before = try f.metadata()
    let raw = try f.raw()
    let old = try confirmation(s, nonce: await inspect(s))
    confirm(old, session: s)
    #expect(service.upgradeCalls == 0 && !s.preparing)
    acknowledge(old, session: s)
    s.refreshDiskMetadataUpgrade(draft: old.draft)
    try await wait { !s.preparing }
    acknowledge(old, session: s)
    confirm(old, session: s)
    #expect(!s.diskMetadataAcknowledged && service.upgradeCalls == 0)
    s.leaveDiskMetadataUpgrade(draft: old.draft, closeSheet: false)
    acknowledge(old, session: s)
    confirm(old, session: s)
    s.refreshDiskMetadataUpgrade(draft: old.draft)
    #expect(!s.showingDiskMetadataUpgrade && s.canSaveDiskCapacity && !s.preparing)
    #expect(service.upgradeCalls == 0)
    let fresh = try confirmation(s, nonce: await inspect(s))
    acknowledge(old, session: s)
    confirm(old, session: s)
    s.leaveDiskMetadataUpgrade(draft: old.draft, closeSheet: true)
    #expect(s.showingDiskMetadataUpgrade && s.diskMetadataDraftNonce == fresh.draft)
    acknowledge(fresh, session: s)
    s.leaveDiskMetadataUpgrade(draft: fresh.draft, closeSheet: true)
    s.diskCapacitySettingsDismissed()
    confirm(fresh, session: s)
    #expect(!s.editingDiskCapacity && !s.showingDiskMetadataUpgrade && service.upgradeCalls == 0)
    #expect(try f.metadata() == before && f.raw() == raw)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["stable", "not-needed", "pending", "busy", "legacy-proof", "needs-review"])
  func everyNoneligibleActualCoreStateStaysReadOnly(kind: String) async throws {
    let f = try await MetadataUpgradeFixture.create(kind: kind)
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let writer =
      kind == "busy"
      ? try VMLock(existingDirectory: f.directory, expectedVMID: f.configuration.id) : nil
    let before = try f.metadata()
    let raw = try f.raw()
    let nonce = try await inspect(s)
    let status = try #require(s.diskMetadataInspection?.status)
    let expected: DiskGrowthIdentityUpgradeInspection.Status =
      switch kind {
      case "stable": .alreadyStable
      case "not-needed": .notNeeded
      case "pending": .pendingGrowth
      case "busy": .busy
      case "legacy-proof": .legacyProofUnavailable
      default: .needsReview
      }
    #expect(status == expected && !s.canConfirmDiskMetadataUpgrade)
    s.acknowledgeDiskMetadataUpgrade(true, draft: nonce, check: s.diskMetadataCheckGeneration)
    s.confirmDiskMetadataUpgrade(
      draft: nonce, check: s.diskMetadataCheckGeneration,
      inspectedVMID: f.configuration.id, transactionID: f.transactionID)
    s.leaveDiskMetadataUpgrade(draft: nonce, closeSheet: true)
    #expect(service.upgradeCalls == 0 && !s.preparing)
    #expect(try f.metadata() == before && f.raw() == raw)
    withExtendedLifetime((owner, writer)) {}
  }

  @Test(arguments: ["vm", "transaction"])
  func confirmationMustMatchActualInspectedIdentities(which: String) async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let before = try f.metadata()
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    s.confirmDiskMetadataUpgrade(
      draft: c.draft, check: c.check,
      inspectedVMID: which == "vm" ? UUID() : c.vmID,
      transactionID: which == "transaction" ? UUID() : c.transaction)
    #expect(service.upgradeCalls == 0 && !s.preparing && s.canConfirmDiskMetadataUpgrade)
    #expect(try f.metadata() == before)
    withExtendedLifetime(owner) {}
  }

  @Test(
    arguments: ["owner-aba", "configuration-aba", "foreign-sheet", "sheet-aba"],
    ["before-confirm", "queued"])
  func stoppedSelectionAndModalAdmissionAreRecheckedBeforeAnyCoreMutation(
    change: String, timing: String
  ) async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let other = window()
    let before = try f.metadata()
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    if timing == "queued" { confirm(c, session: s) }
    if change == "owner-aba" {
      s.window = other
      s.window = owner
    } else if change == "configuration-aba" {
      var replacement = f.configuration
      replacement.name = "Temporary selection"
      s.configuration = replacement
      s.configuration = f.configuration
    } else if change == "sheet-aba" {
      s.registerDiskCapacityWindow(other)
      s.registerDiskCapacityWindow(nil)
    } else {
      owner.controlledSheet = other
    }
    if timing == "before-confirm" { confirm(c, session: s) }
    try await wait { !s.preparing }
    #expect(service.upgradeCalls == 0 && service.mutationAttempts == 0)
    #expect(try f.metadata() == before)
    owner.controlledSheet = nil
    s.leaveDiskMetadataUpgrade(draft: c.draft, closeSheet: true)
    s.diskCapacitySettingsDismissed()
    s.showDiskCapacitySettings()
    let fresh = try confirmation(s, nonce: await inspect(s))
    acknowledge(fresh, session: s)
    #expect(s.canConfirmDiskMetadataUpgrade && fresh.draft != c.draft)
    s.leaveDiskMetadataUpgrade(draft: fresh.draft, closeSheet: true)
    #expect(try f.metadata() == before)
    withExtendedLifetime((owner, other)) {}
  }

  @Test(arguments: ["owner-aba", "configuration-aba", "error", "dismissed-error"])
  func deferredRealInspectionCannotPublishIntoChangedUIOrOverwriteErrorDismissal(change: String)
    async throws
  {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    service.pauseInspection = true
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let other = window()
    let before = try f.metadata()
    s.showDiskMetadataUpgrade(draft: s.diskCapacityDraftNonce)
    let nonce = try #require(s.diskMetadataDraftNonce)
    try await wait { service.pending != nil }
    #expect(service.statuses == [.eligibleAtCheck])
    if change == "owner-aba" {
      s.window = other
      s.window = owner
    } else if change == "configuration-aba" {
      var changed = f.configuration
      changed.name = "Temporary selection"
      s.configuration = changed
      s.configuration = f.configuration
    } else {
      s.errorMessage = "Newer independent error"
      if change == "dismissed-error" { s.errorMessage = nil }
    }
    service.release()
    try await wait { !s.preparing }
    #expect(s.diskMetadataInspection == nil && s.diskMetadataMessage == nil)
    #expect(!s.canConfirmDiskMetadataUpgrade && service.upgradeCalls == 0)
    #expect(s.errorMessage == (change == "error" ? "Newer independent error" : nil))
    #expect(try f.metadata() == before)
    s.leaveDiskMetadataUpgrade(draft: nonce, closeSheet: true)
    withExtendedLifetime((owner, other)) {}
  }

  @Test(arguments: ["owner-aba", "configuration-aba", "error", "dismissed-error"])
  func deferredPrecommitStillRequiresCurrentAdmission(change: String) async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    service.pauseBeforeUpgrade = true
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let other = window()
    let before = try f.metadata()
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    confirm(c, session: s)
    try await wait { service.pending != nil }
    if change == "owner-aba" {
      s.window = other
      s.window = owner
    } else if change == "configuration-aba" {
      var changed = f.configuration
      changed.name = "Temporary selection"
      s.configuration = changed
      s.configuration = f.configuration
    } else {
      s.errorMessage = "Newer independent error"
      if change == "dismissed-error" { s.errorMessage = nil }
    }
    service.release()
    try await wait { !s.preparing }
    #expect(service.mutationAttempts == 0 && service.inspectionCalls == 2)
    #expect(s.diskMetadataMessage == nil && s.diskMetadataInspection == nil)
    #expect(s.errorMessage == (change == "error" ? "Newer independent error" : nil))
    #expect(try f.metadata() == before)
    withExtendedLifetime((owner, other)) {}
  }

  @Test(
    arguments: [
      "owner-aba", "configuration-aba", "replacement", "dismissed", "error", "dismissed-error",
    ], [false, true])
  func realCommittedUpgradeIsPreservedButStaleOrNewerErrorUIIsNeverReplaced(
    change: String, deliveryFails: Bool
  ) async throws {
    let f = try await MetadataUpgradeFixture.create(runtime: "guest")
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    service.pauseAfterUpgrade = true
    service.failDelivery = deliveryFails
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let other = window()
    let before = try f.metadata()
    let raw = try f.raw()
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    confirm(c, session: s)
    try await wait { service.pending != nil }
    #expect(service.committed?.transactionID == f.transactionID)
    #expect(try Data(contentsOf: f.archive) == f.legacy)
    var expected = f.configuration
    if change == "owner-aba" {
      s.window = other
      s.window = owner
    } else if change == "configuration-aba" || change == "replacement" {
      expected.name = "Independent replacement"
      s.configuration = expected
      if change == "configuration-aba" {
        expected = f.configuration
        s.configuration = expected
      }
    } else if change == "dismissed" {
      s.editingDiskCapacity = false
    } else {
      s.errorMessage = "Newer independent error"
      if change == "dismissed-error" { s.errorMessage = nil }
    }
    service.release()
    try await wait { !s.preparing }
    #expect(service.inspectionCalls == 2 && service.statuses.last == .alreadyStable)
    #expect(s.configuration == expected && s.selectedConfigurationURL == f.registration)
    #expect(s.diskMetadataMessage == nil && s.diskMetadataInspection == nil)
    #expect(s.errorMessage == (change == "error" ? "Newer independent error" : nil))
    #expect(!s.isActive && !s.needsOwnershipRecovery && s.backend == nil)
    #expect(try Data(contentsOf: f.archive) == f.legacy && f.raw() == raw)
    let after = try f.metadata()
    for (name, bytes) in before where name != DiskGrowthIntent.filename {
      #expect(after[name] == bytes)
    }
    #expect(after.count == before.count + 1)
    withExtendedLifetime((owner, other)) {}
  }

  @Test(arguments: ["history", "configuration", "journal", "writer"])
  func realCoreAnchoredRechecksRejectAdmissionGapChangesWithoutArchiveOrRollback(change: String)
    async throws
  {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    service.faultCore = DiskGrowthIdentityUpgrade(files: UpgradeAdmissionGapStore(change: change))
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let raw = try f.raw()
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    confirm(c, session: s)
    try await wait { !s.preparing }
    #expect(service.coreFailure is VMError && service.committed == nil)
    #expect(service.mutationAttempts == 1 && service.inspectionCalls == 2)
    #expect(s.diskMetadataMessage?.contains("could not be confirmed") == true)
    #expect(!s.diskMetadataAcknowledged && !s.canConfirmDiskMetadataUpgrade)
    #expect(try Data(contentsOf: f.journal) == f.legacy && f.raw() == raw)
    #expect(!FileManager.default.fileExists(atPath: f.archive.path))
    if change == "writer" {
      #expect(
        !FileManager.default.fileExists(
          atPath: f.directory.appendingPathComponent("writer.lock").path))
    }
    if change == "history" {
      #expect(
        try Data(contentsOf: f.directory.appendingPathComponent("runtime.json"))
          == Data("changed real history in admission gap".utf8))
    }
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [
    DiskGrowthFaultPoint.afterIdentityUpgradeArchive, .afterIdentityUpgradeRename,
    .afterIdentityUpgradeFlush,
  ])
  func realPartialCoreOutcomesAreReinspectedAndPreserved(point: DiskGrowthFaultPoint) async throws {
    let f = try await MetadataUpgradeFixture.create(runtime: "guest")
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let files = VMFiles()
    await files.injectDiskGrowthFault(point)
    let service = ControlledMetadataUpgrade()
    service.faultCore = DiskGrowthIdentityUpgrade(files: files)
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let before = try f.metadata()
    let raw = try f.raw()
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    confirm(c, session: s)
    try await wait { !s.preparing }
    #expect(service.coreFailure is VMError && service.committed == nil)
    #expect(s.diskMetadataMessage?.contains("could not be confirmed") == true)
    #expect(s.diskMetadataMessage?.contains("private") == false)
    #expect(!s.diskMetadataAcknowledged && !s.canConfirmDiskMetadataUpgrade)
    #expect(try Data(contentsOf: f.archive) == f.legacy && f.raw() == raw)
    let current = try #require(try await VMFiles().readDiskGrowthIntent(in: f.directory))
    #expect(current.schemaVersion == (point == .afterIdentityUpgradeArchive ? 1 : 2))
    #expect(
      s.diskMetadataInspection?.status
        == (point == .afterIdentityUpgradeArchive ? .eligibleAtCheck : .alreadyStable))
    for (name, bytes) in before where name != DiskGrowthIntent.filename {
      #expect(try Data(contentsOf: f.directory.appendingPathComponent(name)) == bytes)
    }
    confirm(c, session: s)
    #expect(service.upgradeCalls == 1 && !s.preparing)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["inspection", "acknowledgement", "commit", "back"])
  func retainedOriginalCapacityCallbacksCannotWriteOrCloseTheCompatibilityOrRebuiltDraft(
    stage: String
  ) async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    service.pauseInspection = stage == "inspection"
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let originalDraft = s.diskCapacityDraftNonce
    let raw = try f.raw()
    s.showDiskMetadataUpgrade(draft: originalDraft)
    let nonce = try #require(s.diskMetadataDraftNonce)
    if stage == "inspection" {
      try await wait { service.pending != nil }
    } else {
      try await wait { !s.preparing }
      let c = try confirmation(s, nonce: nonce)
      acknowledge(c, session: s)
      if stage == "commit" {
        service.pauseAfterUpgrade = true
        confirm(c, session: s)
        try await wait { service.pending != nil }
      } else if stage == "back" {
        s.leaveDiskMetadataUpgrade(draft: nonce, closeSheet: false)
      }
    }
    // Exactly the target+origin forwarded by the original form's retained confirmation.
    s.saveDiskCapacity(targetBytes: 2 << 30, draft: originalDraft)
    s.cancelDiskCapacitySettings(draft: originalDraft)
    #expect(s.editingDiskCapacity && service.growthCalls == 0)
    if stage == "back" {
      #expect(!s.showingDiskMetadataUpgrade && s.diskCapacityDraftNonce != originalDraft)
      #expect(s.canSaveDiskCapacity)
    } else {
      #expect(s.showingDiskMetadataUpgrade && !s.canSaveDiskCapacity)
    }
    service.release()
    try await wait { !s.preparing }
    #expect(try f.raw() == raw && service.growthCalls == 0)
    #expect(service.upgradeCalls == (stage == "commit" ? 1 : 0))
    withExtendedLifetime(owner) {}
  }

  @Test func retainedConfirmationRejectsActualSavedLocationRoundTripAndNewPage() async throws {
    let f = try await MetadataUpgradeFixture.create()
    let other = try await MetadataUpgradeFixture.create()
    defer {
      try? FileManager.default.removeItem(at: f.directory)
      try? FileManager.default.removeItem(at: other.directory)
    }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let before = try f.metadata()
    let otherBefore = try other.metadata()
    let old = try confirmation(s, nonce: await inspect(s))
    acknowledge(old, session: s)
    s.leaveDiskMetadataUpgrade(draft: old.draft, closeSheet: true)
    s.diskCapacitySettingsDismissed()
    try await s.qualificationSelectVM(at: other.registration, expectedID: other.configuration.id)
    try await s.qualificationSelectVM(at: f.registration, expectedID: f.configuration.id)
    s.showDiskCapacitySettings()
    let fresh = try confirmation(s, nonce: await inspect(s))
    acknowledge(old, session: s)
    confirm(old, session: s)
    s.leaveDiskMetadataUpgrade(draft: old.draft, closeSheet: true)
    #expect(s.diskMetadataDraftNonce == fresh.draft && !s.diskMetadataAcknowledged)
    #expect(service.upgradeCalls == 0 && !s.preparing)
    acknowledge(fresh, session: s)
    #expect(s.canConfirmDiskMetadataUpgrade)
    #expect(try f.metadata() == before && other.metadata() == otherBefore)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["history", "configuration", "transaction", "writer-held"])
  func realChangesAfterInspectionDoNotReuseItsEligibility(change: String) async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    service.pauseBeforeUpgrade = true
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    confirm(c, session: s)
    try await wait { service.pending != nil }
    var held: VMLock?
    if change == "history" {
      try await VMFiles().atomicWrite(
        Data("new invalid runtime history".utf8),
        at: f.directory.appendingPathComponent("runtime.json"))
    } else if change == "configuration" {
      var changed = f.configuration
      changed.name = "Saved independently"
      try await VMFiles().atomicWrite(ConfigurationCodec.encode(changed), at: f.registration)
    } else if change == "transaction" {
      var record = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as? [String: Any])
      record["transactionID"] = UUID().uuidString
      try await VMFiles().atomicWrite(
        JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), at: f.journal)
    } else {
      held = try VMLock(existingDirectory: f.directory, expectedVMID: f.configuration.id)
    }
    let changedBytes = try f.metadata()
    let raw = try f.raw()
    service.release()
    try await wait { !s.preparing }
    #expect(service.coreFailure is VMError && service.committed == nil)
    #expect(service.upgradeCalls == 1 && service.inspectionCalls == 2)
    #expect(s.diskMetadataMessage?.contains("could not be confirmed") == true)
    #expect(!s.canConfirmDiskMetadataUpgrade && !s.diskMetadataAcknowledged)
    #expect(!FileManager.default.fileExists(atPath: f.archive.path))
    #expect(try f.metadata() == changedBytes && f.raw() == raw)
    withExtendedLifetime((owner, held)) {}
  }

  @Test func acknowledgementPublicationCannotConfirmWithItsPreviousCheckedValue() async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let before = try f.metadata()
    let c = try confirmation(s, nonce: await inspect(s))
    acknowledge(c, session: s)
    var reentered = false
    let observation = s.$diskMetadataAcknowledged.dropFirst().sink { value in
      guard !value, !reentered else { return }
      reentered = true
      confirm(c, session: s)
    }
    defer { observation.cancel() }
    s.acknowledgeDiskMetadataUpgrade(false, draft: c.draft, check: c.check)
    #expect(reentered && !s.diskMetadataAcknowledged && !s.preparing)
    #expect(try f.metadata() == before && service.upgradeCalls == 0)
    acknowledge(c, session: s)
    confirm(c, session: s)
    try await wait { !s.preparing }
    #expect(service.upgradeCalls == 1 && s.diskMetadataInspection?.status == .alreadyStable)
    withExtendedLifetime(owner) {}
  }

  @Test func backRevokesOriginalCapacityCallbacksBeforePublishingThePlainPage() async throws {
    let f = try await MetadataUpgradeFixture.create()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = ControlledMetadataUpgrade()
    defer { service.release() }
    let (s, owner) = try await selected(f, service: service)
    let originalDraft = s.diskCapacityDraftNonce
    let before = try f.metadata()
    let raw = try f.raw()
    let c = try confirmation(s, nonce: await inspect(s))
    var reentered = false
    let observation = s.objectWillChange.sink { [weak s] _ in
      guard let s, !reentered, !s.showingDiskMetadataUpgrade else { return }
      reentered = true
      s.cancelDiskCapacitySettings(draft: originalDraft)
      s.saveDiskCapacity(targetBytes: 2 << 30, draft: originalDraft)
    }
    defer { observation.cancel() }
    s.leaveDiskMetadataUpgrade(draft: c.draft, closeSheet: false)
    #expect(reentered && s.editingDiskCapacity && !s.showingDiskMetadataUpgrade)
    #expect(s.diskCapacityDraftNonce != originalDraft && s.canSaveDiskCapacity)
    #expect(!s.preparing && service.growthCalls == 0 && service.upgradeCalls == 0)
    #expect(try f.metadata() == before && f.raw() == raw)
    withExtendedLifetime(owner) {}
  }
}
