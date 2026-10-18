// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Combine
import Darwin
import Foundation
import Testing
import VMCore

@testable import MacOpenVMApp

@MainActor private final class ExportLibraryPreferences: VMLibraryPreferences {
  private(set) var writes = 0
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { writes += 1 }
}

@MainActor private final class ExportWindow: NSWindow {
  private(set) var activationRequests = 0
  var controlledSheet: NSWindow?
  var releaseResponder: (@MainActor () -> Void)?
  override var attachedSheet: NSWindow? { controlledSheet }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    let callback = releaseResponder
    releaseResponder = nil
    callback?()
    return true
  }
}

/// Pauses plain destination/outcome delivery, but executes the actual native Core
/// operation. No synthetic success/failure, runtime, worker or resource is admitted.
@MainActor private final class ControlledSupportReportExport: DesktopSupportReportExporting {
  enum Outcome {
    case success
    case failure(Error)
  }
  private var destination: (@MainActor (URL?) -> Void)?
  private var savedDestinations: [@MainActor (URL?) -> Void] = []
  var beforePresentation: (@MainActor () -> Void)?
  private var delivery: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var presentations = 0
  private(set) var operations = 0
  private(set) var outcome: Outcome?
  private(set) var delivered = false

  func chooseDestination(
    on owner: NSWindow, willPresent: () -> Bool,
    selected: @escaping @MainActor (URL?) -> Void
  ) {
    let callback = beforePresentation
    beforePresentation = nil
    callback?()
    guard willPresent() else { return }
    presentations += 1
    destination = selected
    savedDestinations.append(selected)
  }

  func select(_ url: URL?) throws {
    let callback = try #require(destination)
    destination = nil
    callback(url)
  }

  func replayDestination(_ index: Int, _ url: URL?) throws {
    try #require(savedDestinations.indices.contains(index))
    savedDestinations[index](url)
  }

  func makeAndExport(directory: URL?, host: DiagnosticHostFacts, to destination: URL) async throws {
    operations += 1
    let actual: Outcome
    do {
      try await NativeDesktopSupportReportExport().makeAndExport(
        directory: directory, host: host, to: destination)
      actual = .success
    } catch { actual = .failure(error) }
    outcome = actual
    await withCheckedContinuation {
      if released { $0.resume() } else { delivery = $0 }
    }
    delivered = true
    if case .failure(let error) = actual { throw error }
  }

  func releaseDelivery() {
    released = true
    let continuation = delivery
    delivery = nil
    continuation?.resume()
  }
}

private struct SupportExportFixture {
  let root: URL
  let existing: URL
  let newReport: URL
  static func create() throws -> Self {
    let root = URL(fileURLWithPath: "/private/tmp/macOpenVM-support-delivery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let existing = root.appendingPathComponent("existing.json")
    try Data("preserve this exact disposable destination\n".utf8).write(to: existing)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path)
    // Foundation can standardize an existing /private/tmp file to its /tmp alias.
    // Exercise the actual exclusive-write refusal after the URL admission guards.
    let canonicalExisting = existing.standardizedFileURL
    var originalMetadata = stat()
    var canonicalMetadata = stat()
    try #require(lstat(existing.path, &originalMetadata) == 0)
    try #require(lstat(canonicalExisting.path, &canonicalMetadata) == 0)
    try #require(
      originalMetadata.st_dev == canonicalMetadata.st_dev
        && originalMetadata.st_ino == canonicalMetadata.st_ino
        && canonicalExisting.standardizedFileURL.path == canonicalExisting.path)
    return Self(
      root: root, existing: canonicalExisting,
      newReport: root.appendingPathComponent("new-report.json"))
  }
  struct Stamp: Equatable {
    let device: Int32, inode: UInt64, uid: UInt32, gid: UInt32, mode: UInt16, links: UInt16
    let size: Int64, modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int,
      changedNanoseconds: Int
    let bytes: Data
  }
  func stamp(_ url: URL) throws -> Stamp {
    var value = stat()
    try #require(lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG)
    try #require(value.st_size >= 0 && value.st_size <= Int64(DiagnosticReport.maximumBytes))
    return Stamp(
      device: value.st_dev, inode: value.st_ino, uid: value.st_uid, gid: value.st_gid,
      mode: value.st_mode, links: value.st_nlink, size: value.st_size,
      modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
      changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec,
      bytes: try Data(contentsOf: url))
  }
}

@MainActor @Suite(.serialized) struct DesktopSupportReportExportTests {
  @Test func defaultExportConstructionAndOwnerlessEntryPreserveApplicationIdentity() throws {
    let applicationBefore: NSApplication? = NSApp
    if ProcessInfo.processInfo.environment["MACOPENVM_TEST_REQUIRE_NO_APPLICATION"] == "1" {
      try #require(applicationBefore == nil)
    }
    let library = ExportLibraryPreferences()
    let preferences = MemoryWindowsGraphicsPreferences()
    let session = DesktopSession(
      library: VMLibrary(preferences: library),
      graphicsPreferences: WindowsGraphicsPreferenceStore(preferences: preferences))
    #expect(NSApp === applicationBefore)
    session.exportSupportReport()
    #expect(NSApp === applicationBefore && session.window == nil && !session.preparing)
    #expect(
      session.errorMessage == nil && session.backend == nil
        && session.qualificationWindowsRuntime == nil)
    #expect(library.writes == 0 && preferences.reads == 0 && preferences.writes == 0)
    if applicationBefore == nil {
      print("Support export default probe: initial_nil=true, final_nil=true")
    }
  }

  @Test(arguments: [false, true])
  func currentRealExportFailureRemainsActionableWithNoInterveningError(_ existingError: Bool)
    async throws
  {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    defer { service.releaseDelivery() }
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    let initial = existingError ? "An earlier operation error is still current." : nil
    session.errorMessage = initial
    try begin(session, service: service)
    try service.select(fixture.existing)
    let actual = try await realFailure(service)
    #expect(session.preparing && session.errorMessage == initial && !service.delivered)
    #expect(try fixture.stamp(fixture.existing) == before)
    service.releaseDelivery()
    try await completed(session, service: service)
    #expect(session.errorMessage == actual.errorDescription)
    try unchanged(fixture, before: before, service: service, owner: owner)
  }

  @Test(arguments: ["destination", "outcome"])
  func newerErrorSurvivesLateRealExportRefusal(_ phase: String) async throws {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    defer { service.releaseDelivery() }
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    try begin(session, service: service)
    let newer = "A newer VM operation requires recovery; retain this exact message."
    if phase == "destination" { session.errorMessage = newer }
    try service.select(fixture.existing)
    _ = try await realFailure(service)
    if phase == "outcome" { session.errorMessage = newer }
    service.releaseDelivery()
    try await completed(session, service: service)
    #expect(session.errorMessage == newer)
    try unchanged(fixture, before: before, service: service, owner: owner)
  }

  @Test(arguments: ["destination", "outcome"])
  func aDismissedNewerErrorStaysNilAfterLateRealExportRefusal(_ phase: String) async throws {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    defer { service.releaseDelivery() }
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    try begin(session, service: service)
    if phase == "destination" {
      session.errorMessage = "A newer operation error was shown."
      session.errorMessage = nil
    }
    try service.select(fixture.existing)
    _ = try await realFailure(service)
    if phase == "outcome" {
      session.errorMessage = "A newer operation error was shown."
      session.errorMessage = nil
    }
    service.releaseDelivery()
    try await completed(session, service: service)
    #expect(session.errorMessage == nil)
    try unchanged(fixture, before: before, service: service, owner: owner)
  }

  @Test(arguments: ["destination", "outcome"])
  func successfulRealExportStillPreservesANewerOperationError(_ phase: String) async throws {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    defer { service.releaseDelivery() }
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    try begin(session, service: service)
    let newer = "A newer operation error must survive successful diagnostic export."
    if phase == "destination" { session.errorMessage = newer }
    try service.select(fixture.newReport)
    try await outcomeReady(service)
    guard case .success? = service.outcome else {
      Issue.record("The real Core export did not succeed.")
      return
    }
    if phase == "outcome" { session.errorMessage = newer }
    let exported = try fixture.stamp(fixture.newReport)
    #expect(exported.mode & 0o7777 == 0o600 && exported.uid == geteuid() && exported.links == 1)
    let document = try #require(
      try JSONSerialization.jsonObject(with: exported.bytes) as? [String: Any])
    #expect(document["format"] as? String == "macOpenVM-support-diagnostics")
    #expect(document["product"] as? String == "macOpenVM")
    #expect(exported.bytes.last == 10)
    service.releaseDelivery()
    try await completed(session, service: service)
    #expect(session.errorMessage == newer)
    #expect(try fixture.stamp(fixture.existing) == before)
    #expect(try fixture.stamp(fixture.newReport) == exported)
    #expect(service.operations == 1 && service.presentations == 1 && owner.activationRequests == 0)
    #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
  }

  @Test func synchronousPreparingPublicationClaimsOneDestinationBeforeStoredFlagChanges() throws {
    let service = ControlledSupportReportExport()
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    var reentered = false
    var publicationWasClaimed = false
    let observation = session.$preparing.dropFirst().sink { value in
      guard value, !reentered else { return }
      reentered = true
      // @Published is synchronous and the stored preparing value is still false here.
      publicationWasClaimed = session.isBusy && !session.canExportSupportReport
      session.exportSupportReport()
      session.showLinuxCreation()
    }
    defer { observation.cancel() }
    session.exportSupportReport()
    #expect(reentered && publicationWasClaimed && service.presentations == 1 && !session.creating)
    #expect(session.preparing && session.isBusy && service.operations == 0)
    try service.select(nil)
    #expect(!session.preparing && !session.isBusy && session.canExportSupportReport)
    #expect(service.operations == 0 && owner.activationRequests == 0)
  }

  @Test(arguments: ["owner", "owner-roundtrip", "selection", "selection-roundtrip", "sheet"])
  func responderReleaseRevalidatesOriginalOwnerSelectionAndSheet(_ change: String) throws {
    let service = ControlledSupportReportExport()
    let (session, owner) = makeSession(service)
    let replacementOwner = makeOwner()
    defer { session.window = nil }
    let replacement = replacementConfiguration()
    var releasedWhileClaimed = false
    owner.releaseResponder = {
      releasedWhileClaimed = session.isBusy && !session.canExportSupportReport
      switch change {
      case "owner", "owner-roundtrip":
        session.window = replacementOwner
        if change == "owner-roundtrip" { session.window = owner }
      case "selection", "selection-roundtrip":
        session.configuration = replacement
        if change == "selection-roundtrip" { session.configuration = nil }
      case "sheet": owner.controlledSheet = replacementOwner
      default: Issue.record("Unknown controlled release change.")
      }
    }
    session.exportSupportReport()
    #expect(releasedWhileClaimed && service.presentations == 0 && service.operations == 0)
    #expect(!session.preparing && !session.isBusy && session.errorMessage == nil)
    #expect(owner.activationRequests == 0 && replacementOwner.activationRequests == 0)
    owner.controlledSheet = nil
    withExtendedLifetime((owner, replacementOwner)) {}
  }

  @Test(arguments: ["owner", "sheet"])
  func finalPresentationCheckRefusesChangedOwnerOrNewSheet(_ change: String) {
    let service = ControlledSupportReportExport()
    let (session, owner) = makeSession(service)
    let replacementOwner = makeOwner()
    defer { session.window = nil }
    service.beforePresentation = {
      if change == "owner" {
        session.window = replacementOwner
      } else {
        owner.controlledSheet = replacementOwner
      }
    }
    session.exportSupportReport()
    #expect(service.presentations == 0 && service.operations == 0)
    #expect(!session.preparing && !session.isBusy && session.errorMessage == nil)
    owner.controlledSheet = nil
    withExtendedLifetime((owner, replacementOwner)) {}
  }

  @Test(arguments: ["owner", "selection"], ["destination", "queued"])
  func changedContextCannotExportAnOldDestination(_ change: String, _ phase: String) async throws {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    let (session, owner) = makeSession(service)
    let replacementOwner = makeOwner()
    defer { session.window = nil }
    try begin(session, service: service)
    if phase == "queued" { try service.select(fixture.newReport) }
    if change == "owner" {
      session.window = replacementOwner
    } else {
      session.configuration = replacementConfiguration()
    }
    if phase == "destination" { try service.select(fixture.newReport) }
    let deadline = ContinuousClock.now + .seconds(5)
    while session.isBusy && ContinuousClock.now < deadline { await Task.yield() }
    #expect(!session.preparing && !session.isBusy && service.operations == 0)
    #expect(service.presentations == 1 && session.errorMessage == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.newReport.path))
    #expect(try fixture.stamp(fixture.existing) == original)
    #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
    withExtendedLifetime((owner, replacementOwner)) {}
  }

  @Test func cancelledOldCallbackCannotReleaseAnotherDestinationOrStartAnExport() throws {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    try begin(session, service: service)
    try service.select(nil)
    try #require(!session.preparing && session.canExportSupportReport)
    session.exportSupportReport()
    try #require(service.presentations == 2 && session.preparing && session.isBusy)
    try service.replayDestination(0, nil)
    try service.replayDestination(0, fixture.newReport)
    #expect(session.preparing && session.isBusy && !session.canExportSupportReport)
    #expect(service.operations == 0 && service.presentations == 2)
    try service.select(nil)
    #expect(!session.preparing && !session.isBusy && session.canExportSupportReport)
    #expect(!FileManager.default.fileExists(atPath: fixture.newReport.path))
    #expect(try fixture.stamp(fixture.existing) == original)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [false, true])
  func oldDestinationCannotClearOrWriteDuringANewerPreparation(_ cancel: Bool) throws {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    try begin(session, service: service)
    session.preparing = false
    session.preparing = true
    try service.select(cancel ? nil : fixture.newReport)
    #expect(session.preparing && session.isBusy && !session.canExportSupportReport)
    #expect(service.operations == 0 && service.presentations == 1 && session.errorMessage == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.newReport.path))
    #expect(try fixture.stamp(fixture.existing) == original)
    session.preparing = false
    #expect(!session.isBusy && session.canExportSupportReport)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [false, true])
  func acceptedDestinationIgnoresReplayedCancellationAndDuplicateSelection(_ refuse: Bool)
    async throws
  {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    defer { service.releaseDelivery() }
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    let destination = refuse ? fixture.existing : fixture.newReport
    try begin(session, service: service)
    try service.select(destination)
    try service.replayDestination(0, nil)
    try service.replayDestination(0, destination)
    try await outcomeReady(service)
    if refuse {
      _ = try await realFailure(service)
    } else {
      guard case .success? = service.outcome else {
        Issue.record("Missing real success.")
        return
      }
    }
    #expect(session.preparing && session.isBusy && !session.canExportSupportReport)
    #expect(service.operations == 1 && service.presentations == 1 && !service.delivered)
    #expect(try fixture.stamp(fixture.existing) == original)
    if !refuse {
      let actual = try fixture.stamp(fixture.newReport)
      #expect(actual.mode & 0o7777 == 0o600 && actual.uid == geteuid() && actual.links == 1)
    }
    service.releaseDelivery()
    try await completed(session, service: service)
    #expect(!session.isBusy && session.canExportSupportReport && service.operations == 1)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [false, true])
  func olderRealOutcomeCannotClearOrReportIntoANewerPreparation(_ refuse: Bool) async throws {
    let fixture = try SupportExportFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try fixture.stamp(fixture.existing)
    let service = ControlledSupportReportExport()
    defer { service.releaseDelivery() }
    let (session, owner) = makeSession(service)
    defer { session.window = nil }
    try begin(session, service: service)
    try service.select(refuse ? fixture.existing : fixture.newReport)
    try await outcomeReady(service)
    if refuse {
      _ = try await realFailure(service)
    } else {
      guard case .success? = service.outcome else {
        Issue.record("Missing real success.")
        return
      }
    }
    let exported: SupportExportFixture.Stamp?
    if refuse { exported = nil } else { exported = try fixture.stamp(fixture.newReport) }
    // An unrelated preparation replaces the publication fact while the real outcome is held.
    // The old claim must still deny export entry even during the intervening false value.
    session.preparing = false
    #expect(session.isBusy && !session.canExportSupportReport)
    session.exportSupportReport()
    #expect(service.presentations == 1 && service.operations == 1)
    session.preparing = true
    service.releaseDelivery()
    let deadline = ContinuousClock.now + .seconds(5)
    while !service.delivered && ContinuousClock.now < deadline { await Task.yield() }
    try #require(service.delivered)
    #expect(session.preparing && session.isBusy && session.errorMessage == nil)
    #expect(try fixture.stamp(fixture.existing) == original)
    if let exported { #expect(try fixture.stamp(fixture.newReport) == exported) }
    #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
    // Release only the fixture's newer preparation; the old defer already returned.
    session.preparing = false
    #expect(!session.isBusy && session.canExportSupportReport)
    withExtendedLifetime(owner) {}
  }

  private func replacementConfiguration() -> VMConfiguration {
    VMConfiguration(
      name: "Read-only replacement selection", guest: .linux, backend: .appleVz,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
  }

  private func makeOwner() -> ExportWindow {
    let owner = ExportWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: .titled, backing: .buffered, defer: true)
    owner.isReleasedWhenClosed = false
    return owner
  }

  private func makeSession(_ service: ControlledSupportReportExport) -> (
    DesktopSession, ExportWindow
  ) {
    _ = NSApplication.shared
    let owner = makeOwner()
    let session = DesktopSession(
      library: VMLibrary(preferences: ExportLibraryPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      supportReportExport: service)
    session.window = owner
    return (session, owner)
  }

  private func begin(_ session: DesktopSession, service: ControlledSupportReportExport) throws {
    try #require(GuestHostPointerCapture.shared.canAcquire(for: UUID()))
    try #require(session.canExportSupportReport)
    session.exportSupportReport()
    try #require(session.preparing && service.presentations == 1 && service.operations == 0)
  }

  private func outcomeReady(_ service: ControlledSupportReportExport) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while service.outcome == nil && ContinuousClock.now < deadline { await Task.yield() }
    try #require(service.outcome != nil && !service.delivered)
  }

  private func realFailure(_ service: ControlledSupportReportExport) async throws -> VMError {
    try await outcomeReady(service)
    guard case .failure(let error)? = service.outcome else {
      Issue.record("The unchanged real exporter did not refuse an existing target.")
      throw VMError(
        .storage, "Missing fixture refusal.", recovery: "Inspect the disposable fixture.")
    }
    let actual = try #require(error as? VMError)
    #expect(actual.code == .storage)
    return actual
  }

  private func completed(_ session: DesktopSession, service: ControlledSupportReportExport)
    async throws
  {
    let deadline = ContinuousClock.now + .seconds(5)
    while session.preparing && ContinuousClock.now < deadline { await Task.yield() }
    try #require(!session.preparing && service.delivered)
    #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
  }

  private func unchanged(
    _ fixture: SupportExportFixture, before: SupportExportFixture.Stamp,
    service: ControlledSupportReportExport, owner: ExportWindow
  ) throws {
    #expect(try fixture.stamp(fixture.existing) == before)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["existing.json"])
    #expect(service.operations == 1 && service.presentations == 1 && owner.activationRequests == 0)
    guard case .failure(let error)? = service.outcome else {
      Issue.record("Suppressed UI delivery incorrectly lost the actual Core failure outcome.")
      return
    }
    #expect((error as? VMError)?.code == .storage)
  }
}
