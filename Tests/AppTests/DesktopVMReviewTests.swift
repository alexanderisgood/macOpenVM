// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore

@testable import MacOpenVMApp

@MainActor private final class ReviewLibraryPreferences: VMLibraryPreferences {
  var bytes: Data?
  func read() throws -> Data? { bytes }
  func write(_ data: Data) throws { bytes = data }
}

@MainActor private final class ReviewWindow: NSWindow {
  var controlledSheet: NSWindow?
  var activationRequests = 0
  override var attachedSheet: NSWindow? { controlledSheet }
  override var screen: NSScreen? { nil }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
}

private final class ReviewTerminationOwner {}

/// Hidden native owners only: no attached guest view, runtime, worker permit,
/// pointer owner, native panel presentation or activation is constructed.
@MainActor @Suite(.serialized) struct DesktopVMReviewTests {

  @Test func terminationPreparationDiscardsPendingReadOnlyReviewWithoutTouchingVMOrError()
    async throws
  {
    let fixture = try VMReviewFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let gate = DeferredVMReviewInspector()
    defer { Task { await gate.releaseAll() } }
    let session = DesktopSession(
      library: VMLibrary(preferences: ReviewLibraryPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()), reviewInspector: gate)
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.configuration.id)
    try #require(session.selectedConfigurationURL == fixture.registration)
    let owner = ReviewTerminationOwner()
    let context = fixture.context(owner: ObjectIdentifier(owner))
    // Exercise only session/controller termination preparation. No NSApplication,
    // window, alert, actual guest, writer or capture owner is created by this test.
    session.vmReview.open(context)
    session.reviewingVM = true
    let refresh = Task { @MainActor in
      await session.vmReview.refresh(context: context) { candidate in
        session.reviewingVM && session.vmReview.context == candidate
          && session.configuration == candidate.configuration
      }
    }
    try await blocked(gate)
    let before = try fixture.inventory()
    let selectedURL = session.selectedConfigurationURL
    session.errorMessage = "Retain an operation error while Quit cancels review."
    try #require(session.state == .stopped && session.isBusy && session.vmReview.isLoading)

    session.prepareReadOnlyReviewForTermination()
    #expect(!session.reviewingVM && session.vmReview.context == nil)
    #expect(!session.vmReview.isLoading && !session.isBusy)
    #expect(session.configuration == fixture.configuration)
    #expect(session.selectedConfigurationURL == selectedURL && session.state == .stopped)
    #expect(session.errorMessage == "Retain an operation error while Quit cancels review.")
    #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
    #expect(try fixture.inventory() == before)

    await gate.release(1)
    await refresh.value
    #expect(session.vmReview.presentation == nil && session.vmReview.error == nil)
    #expect(!session.reviewingVM && !session.vmReview.isLoading && !session.isBusy)
    session.prepareReadOnlyReviewForTermination()
    #expect(session.configuration == fixture.configuration)
    #expect(session.errorMessage == "Retain an operation error while Quit cancels review.")
    #expect(try fixture.inventory() == before)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent("writer.lock").path))
    withExtendedLifetime(owner) {}
  }

  @Test func terminationPreparationLeavesOtherWorkflowBusyReasonsIntact() {
    let session = DesktopSession(
      library: VMLibrary(preferences: ReviewLibraryPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()))
    let configuration = VMConfiguration(
      name: "termination policy", guest: .linux, backend: .appleVz)
    session.configuration = configuration
    session.errorMessage = "Preserve the existing operation error."
    let owner = ReviewTerminationOwner()
    for keyPath: ReferenceWritableKeyPath<DesktopSession, Bool> in [
      \.preparing, \.editingHardware, \.editingDiskCapacity, \.editingNetwork,
      \.editingGraphics,
    ] {
      session[keyPath: keyPath] = true
      let context = VMReviewContext(
        configurationURL: URL(fileURLWithPath: "/private/unopened.macopenvm/configuration.json"),
        configuration: configuration, owner: ObjectIdentifier(owner), generation: UUID())
      // UI-state fixture only: cleanup must not erase another busy reason even
      // when read-only review state coexists. No runtime authority is fabricated.
      session.vmReview.open(context)
      session.reviewingVM = true
      session.prepareReadOnlyReviewForTermination()
      #expect(!session.reviewingVM && session.vmReview.context == nil)
      #expect(session[keyPath: keyPath] && session.isBusy)
      #expect(session.configuration == configuration && session.state == .stopped)
      #expect(session.errorMessage == "Preserve the existing operation error.")
      #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
      session[keyPath: keyPath] = false
      #expect(!session.isBusy)
    }
    // An idle creation form is intentionally not a VM operation. Quit may close
    // the form, but review cleanup must preserve the creation flag itself.
    session.creating = true
    let context = VMReviewContext(
      configurationURL: URL(fileURLWithPath: "/private/unopened.macopenvm/configuration.json"),
      configuration: configuration, owner: ObjectIdentifier(owner), generation: UUID())
    session.vmReview.open(context)
    session.reviewingVM = true
    session.prepareReadOnlyReviewForTermination()
    #expect(session.creating && !session.isBusy && !session.reviewingVM)
    #expect(session.configuration == configuration && session.vmReview.context == nil)
    #expect(session.errorMessage == "Preserve the existing operation error.")
    withExtendedLifetime(owner) {}
  }
  @Test func ordinaryReviewRetainsSelectionAndBlocksMutatingWorkflows() async throws {
    let fixture = try VMReviewFixture.create(recordedIssues: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (session, owner) = try await selected(fixture)
    defer { session.window = nil }
    let before = try fixture.inventory()
    try #require(GuestHostPointerCapture.shared.canAcquire(for: UUID()))
    try #require(session.canReviewSelectedVM)
    session.showVMReview()
    try await settled(session)
    #expect(session.reviewingVM && session.isBusy && !session.inputCaptured)
    #expect(
      session.vmReview.presentation?.findings.contains { $0.id == "runtime-intent-unsettled" }
        == true)
    #expect(!session.canExportSupportReport && !session.canRequestLibraryNavigation)
    #expect(!session.canShowLibrary)
    #expect(
      !session.canEditDiskCapacity && !session.canEditGraphicsSettings
        && !session.canEditNetworkSettings)
    session.showLibrary()
    session.showHardwareSettings()
    session.showGraphicsSettings()
    session.showNetworkSettings()
    session.showDiskCapacitySettings()
    #expect(!session.showingLibrary && !session.editingHardware && !session.editingGraphics)
    #expect(!session.editingNetwork && !session.editingDiskCapacity)
    let sheet = makeWindow()
    owner.controlledSheet = sheet
    session.registerVMReviewWindow(sheet)
    session.errorMessage = "Retain an operation error arriving during review."
    #expect(!session.canRefreshVMReview && !session.canPresentOperationError)
    session.closeVMReview()
    #expect(!session.reviewingVM && session.vmReview.context == nil && !session.isBusy)
    #expect(session.canShowLibrary)
    #expect(!session.canPresentOperationError)
    #expect(session.errorMessage == "Retain an operation error arriving during review.")
    owner.controlledSheet = nil
    session.registerVMReviewWindow(nil)
    #expect(session.canPresentOperationError)
    #expect(session.errorMessage == "Retain an operation error arriving during review.")
    try unchanged(fixture, session: session, owner: owner, before: before)
    withExtendedLifetime(sheet) {}
  }

  @Test func changedOwnerAndLifecycleTransitionRevokePendingReports() async throws {
    for transition in ["owner", "starting", "preparing"] {
      let fixture = try VMReviewFixture.create()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let gate = DeferredVMReviewInspector()
      defer { Task { await gate.releaseAll() } }
      let (session, owner) = try await selected(fixture, inspector: gate)
      defer { session.window = nil }
      let before = try fixture.inventory()
      try #require(GuestHostPointerCapture.shared.canAcquire(for: UUID()))
      session.showVMReview()
      try await blocked(gate)
      let replacement = makeWindow()
      if transition == "owner" { session.window = replacement }
      if transition == "starting" { session.state = .starting }
      if transition == "preparing" { session.preparing = true }
      #expect(!session.reviewingVM && session.vmReview.context == nil)
      await gate.release(1)
      for _ in 0..<20 { await Task.yield() }
      #expect(session.vmReview.presentation == nil && !session.vmReview.isLoading)
      session.state = .stopped
      session.preparing = false
      session.window = owner
      try unchanged(fixture, session: session, owner: owner, before: before)
      #expect(replacement.activationRequests == 0)
    }
  }

  @Test func libraryReviewWaitsForDetachmentAndSelectsTheExactURLDespiteDuplicateUUIDs()
    async throws
  {
    let first = try VMReviewFixture.create()
    let second = try VMReviewFixture.create(id: first.configuration.id, recordedIssues: true)
    defer {
      try? FileManager.default.removeItem(at: first.root)
      try? FileManager.default.removeItem(at: second.root)
    }
    let (session, owner) = try await selected(first)
    defer { session.window = nil }
    let beforeFirst = try first.inventory()
    let beforeSecond = try second.inventory()
    session.library.remember(second.configuration, at: second.registration)
    let entry = try #require(
      session.library.entries.first { $0.configurationURL == second.registration })
    try #require(GuestHostPointerCapture.shared.canAcquire(for: UUID()))
    session.showLibrary()
    let sheet = makeWindow()
    owner.controlledSheet = sheet
    session.registerLibraryWindow(sheet)
    try #require(session.canOpenSavedVMReview(entry))
    session.openSavedVMReview(entry)
    #expect(!session.showingLibrary && session.isBusy && !session.reviewingVM)
    #expect(session.selectedConfigurationURL == first.registration)
    owner.controlledSheet = nil
    session.registerLibraryWindow(nil)
    session.libraryDismissed()
    try await settled(session, expectingReview: true)
    #expect(session.selectedConfigurationURL == second.registration)
    #expect(session.configuration == second.configuration)
    #expect(session.reviewingVM && session.vmReview.presentation != nil)
    let generation = session.vmReview.context?.generation
    session.libraryDismissed()
    for _ in 0..<10 { await Task.yield() }
    #expect(session.vmReview.context?.generation == generation)
    #expect(try first.inventory() == beforeFirst && second.inventory() == beforeSecond)
    #expect(owner.activationRequests == 0)
    #expect(session.qualificationWindowsRuntime == nil && session.backend == nil)
    session.closeVMReview()
    withExtendedLifetime(sheet) {}
  }

  @Test(arguments: ["still-attached", "owner", "selection-aba"])
  func libraryReviewRejectsAStaleDeferredRequestWithoutChangingSelection(_ change: String)
    async throws
  {
    let first = try VMReviewFixture.create()
    let second = try VMReviewFixture.create()
    defer {
      try? FileManager.default.removeItem(at: first.root)
      try? FileManager.default.removeItem(at: second.root)
    }
    let (session, owner) = try await selected(first)
    defer { session.window = nil }
    let before = try first.inventory()
    let secondBefore = try second.inventory()
    session.library.remember(second.configuration, at: second.registration)
    let entry = try #require(
      session.library.entries.first { $0.configurationURL == second.registration })
    try #require(GuestHostPointerCapture.shared.canAcquire(for: UUID()))
    session.showLibrary()
    let sheet = makeWindow()
    owner.controlledSheet = sheet
    session.registerLibraryWindow(sheet)
    session.openSavedVMReview(entry)
    if change != "still-attached" { owner.controlledSheet = nil }
    let replacement = makeWindow()
    if change == "owner" { session.window = replacement }
    if change == "selection-aba" {
      var changed = first.configuration
      changed.cpuCount += 1
      session.configuration = changed
      session.configuration = first.configuration
    }
    session.libraryDismissed()
    try await settled(session)
    #expect(!session.reviewingVM && session.vmReview.presentation == nil)
    #expect(
      session.configuration == first.configuration
        && session.selectedConfigurationURL == first.registration)
    #expect(try first.inventory() == before && second.inventory() == secondBefore)
    #expect(owner.activationRequests == 0 && replacement.activationRequests == 0)
    owner.controlledSheet = nil
    session.window = owner
    withExtendedLifetime(sheet) {}
  }

  @Test func directReviewUsesWorkflowGatesAndAnUnownedStateLabelDoesNotBecomeRuntimeAuthority()
    async throws
  {
    let fixture = try VMReviewFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (session, owner) = try await selected(fixture)
    defer { session.window = nil }
    let before = try fixture.inventory()
    for state: VMState in [.stopped, .failed, .running, .paused] {
      session.state = state
      #expect(session.canReviewSelectedVM)
      // This is only a UI state fixture. No backend or recovery/runtime object is fabricated.
      #expect(session.qualificationWindowsRuntime == nil && session.backend == nil)
    }
    for state: VMState in [
      .starting, .stopping, .pausing, .resuming, .saving, .restoring, .suspended,
    ] {
      session.state = state
      #expect(!session.canReviewSelectedVM)
    }
    session.state = .stopped
    for keyPath: ReferenceWritableKeyPath<DesktopSession, Bool> in [
      \.preparing, \.creating, \.showingLibrary, \.editingHardware, \.editingDiskCapacity,
      \.editingNetwork, \.editingGraphics,
    ] {
      session[keyPath: keyPath] = true
      #expect(!session.canReviewSelectedVM)
      session.showVMReview()
      #expect(!session.reviewingVM)
      session[keyPath: keyPath] = false
    }
    session.errorMessage = "An unrelated operation error must remain visible."
    #expect(!session.canReviewSelectedVM)
    session.showVMReview()
    #expect(session.errorMessage == "An unrelated operation error must remain visible.")
    session.errorMessage = nil
    owner.controlledSheet = makeWindow()
    #expect(!session.canReviewSelectedVM)
    owner.controlledSheet = nil
    try unchanged(fixture, session: session, owner: owner, before: before)
  }

  private func selected(
    _ fixture: VMReviewFixture,
    inspector: any VMReviewInspecting = NativeVMReviewInspector(host: VMReviewFixture.host)
  ) async throws -> (DesktopSession, ReviewWindow) {
    _ = NSApplication.shared
    let owner = makeWindow()
    let session = DesktopSession(
      library: VMLibrary(preferences: ReviewLibraryPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      reviewInspector: inspector)
    session.window = owner
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.configuration.id)
    try #require(session.configuration == fixture.configuration)
    try #require(session.selectedConfigurationURL == fixture.registration)
    try #require(session.qualificationWindowsRuntime == nil && session.backend == nil)
    return (session, owner)
  }

  private func makeWindow() -> ReviewWindow {
    let owner = ReviewWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: .titled, backing: .buffered, defer: true)
    owner.isReleasedWhenClosed = false
    return owner
  }

  private func settled(_ session: DesktopSession, expectingReview: Bool = false) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while (session.preparing || session.vmReview.isLoading
      || (session.reviewingVM && session.vmReview.presentation == nil
        && session.vmReview.error == nil)
      || (expectingReview && !session.reviewingVM))
      && ContinuousClock.now < deadline
    { await Task.yield() }
    try #require(!session.preparing && !session.vmReview.isLoading)
    if expectingReview { try #require(session.reviewingVM) }
  }

  private func blocked(_ gate: DeferredVMReviewInspector) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await gate.blocked != [1], ContinuousClock.now < deadline { await Task.yield() }
    try #require(await gate.blocked == [1])
  }

  private func unchanged(
    _ fixture: VMReviewFixture, session: DesktopSession, owner: ReviewWindow,
    before: [String: VMReviewFixture.Stamp]
  ) throws {
    #expect(
      session.configuration == fixture.configuration
        && session.selectedConfigurationURL == fixture.registration)
    #expect(try fixture.inventory() == before)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent("writer.lock").path))
    #expect(session.qualificationWindowsRuntime == nil && session.backend == nil)
    #expect(owner.activationRequests == 0)
  }
}
