// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class DiskEditorPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class ControlledDiskGrowth: DesktopDiskGrowing {
  var calls: [(URL, VMConfiguration, UInt64)] = []
  var completion: CheckedContinuation<VMConfiguration, any Error>?
  func grow(in directory: URL, expected: VMConfiguration, targetBytes: UInt64) async throws
    -> VMConfiguration
  {
    calls.append((directory, expected, targetBytes))
    return try await withCheckedThrowingContinuation { completion = $0 }
  }
  func finish(_ configuration: VMConfiguration) {
    let pending = completion
    completion = nil
    pending?.resume(returning: configuration)
  }
  func fail() {
    let pending = completion
    completion = nil
    pending?.resume(throwing: NSError(domain: "private fixture detail", code: 1))
  }
}

@MainActor private final class DiskCapacityWarningWindow: NSWindow {
  var controlledSheet: NSWindow?
  override var attachedSheet: NSWindow? { controlledSheet }
  override func makeKeyAndOrderFront(_ sender: Any?) {}
}

@MainActor @Suite struct DiskCapacitySettingsTests {
  private let gibibyte: UInt64 = 1_073_741_824

  private func fixture() async throws -> (URL, VMConfiguration) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("disk-editor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "Disk editor", guest: .linux, backend: .appleVz,
      cpuCount: 1, memoryBytes: 512 << 20, diskBytes: gibibyte)
    let files = VMFiles()
    try await files.atomicWrite(
      ConfigurationCodec.encode(configuration),
      at: root.appendingPathComponent("configuration.json"))
    try await files.createSparseDisk(at: root.appendingPathComponent("disk.raw"), bytes: gibibyte)
    return (root, configuration)
  }

  private func open(
    _ root: URL, configuration: VMConfiguration,
    service: any DesktopDiskGrowing = NativeDesktopDiskGrowth()
  ) async throws -> (DesktopSession, NSWindow) {
    _ = NSApplication.shared
    let session = DesktopSession(
      library: VMLibrary(preferences: DiskEditorPreferences()),
      diskGrowth: service)
    try await session.qualificationSelectVM(
      at: root.appendingPathComponent("configuration.json"),
      expectedID: configuration.id)
    let owner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    session.window = owner
    #expect(session.configuration == configuration && session.canEditDiskCapacity)
    return (session, owner)
  }

  private func settle(_ session: DesktopSession) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while session.preparing && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.preparing)
  }

  private func entered(_ service: ControlledDiskGrowth) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while service.completion == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.completion != nil)
  }

  /// Keep a failed rejection assertion from leaving its controlled writer suspended.
  private func finishUnexpectedGrowth(
    _ session: DesktopSession, service: ControlledDiskGrowth, original: VMConfiguration,
    targetBytes: UInt64
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while session.preparing && service.completion == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if service.completion != nil {
      var completed = original
      completed.diskBytes = targetBytes
      service.finish(completed)
    }
    try await settle(session)
  }

  @Test func currentDraftRejectsMalformedSameSmallerAndOverlargeEdits() throws {
    let original = VMConfiguration(
      name: "Draft", guest: .linux, backend: .appleVz,
      diskBytes: 64 * gibibyte)
    let draft = DiskCapacityDraft(configuration: original)
    for text in [
      "", " ", "64", "63", "0", "-1", "+128", "128.0", "1e3", "１28",
      "2,048", "2049", String(repeating: "9", count: 256), "9223372036854775808",
    ] {
      draft.capacityGiBText = text
      #expect(draft.inputError != nil)
      #expect(throws: VMError.self) { try draft.prepared() }
      #expect(draft.capacityGiBText == text)
      draft.capacityGiBText = " 128\n"
      #expect(try draft.prepared() == 128 * gibibyte)
    }
    draft.capacityGiBText = "2048"
    #expect(try draft.prepared() == 2048 * gibibyte)
    #expect(original.diskBytes == 64 * gibibyte)
  }

  @Test func cancellationBlocksOtherActionsAndWritesNothing() async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    let before = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
    session.showDiskCapacitySettings()
    #expect(session.editingDiskCapacity && session.isBusy && session.canSaveDiskCapacity)
    session.showLibrary()
    session.showHardwareSettings()
    #expect(!session.showingLibrary && !session.editingHardware && !session.canExportSupportReport)
    session.cancelDiskCapacitySettings(draft: session.diskCapacityDraftNonce)
    session.diskCapacitySettingsDismissed()
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    #expect(service.calls.isEmpty && !session.preparing)
    #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == before)
    withExtendedLifetime(owner) {}
  }

  @Test func staleOwnerOrSameIdentityConfigurationAndInvalidDirectTargetsNeverCallTheWriter()
    async throws
  {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    session.showDiskCapacitySettings()
    for target in [UInt64(0), gibibyte, 2 * gibibyte + 1, UInt64.max] {
      session.saveDiskCapacity(targetBytes: target, draft: session.diskCapacityDraftNonce)
      #expect(service.calls.isEmpty && !session.preparing)
    }
    var changed = original
    changed.name = "Same ID, different selection"
    session.configuration = changed
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    #expect(service.calls.isEmpty && !session.preparing)
    session.configuration = original
    session.window = nil
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    #expect(service.calls.isEmpty && !session.preparing)
    withExtendedLifetime(owner) {}
  }

  @Test func lateCompletionCannotOverwriteAReplacementSelection() async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    session.showDiskCapacitySettings()
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    try await entered(service)
    session.cancelDiskCapacitySettings(draft: session.diskCapacityDraftNonce)
    #expect(session.editingDiskCapacity && session.preparing)
    var replacement = original
    replacement.name = "Replacement"
    session.configuration = replacement
    var completed = original
    completed.diskBytes = 2 * gibibyte
    service.finish(completed)
    try await settle(session)
    #expect(session.configuration == replacement && session.diskCapacityNotice == nil)
    #expect(session.diskCapacityError != nil)
    withExtendedLifetime(owner) {}
  }

  @Test func ownerRoundTripBeforeSavingCannotReuseTheOldConfirmation() async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    let replacementOwner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    session.showDiskCapacitySettings()
    #expect(session.canSaveDiskCapacity)
    session.window = replacementOwner
    session.window = owner
    #expect(!session.canSaveDiskCapacity)
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    try await finishUnexpectedGrowth(
      session, service: service, original: original, targetBytes: 2 * gibibyte)
    #expect(service.calls.isEmpty && !session.preparing)
    #expect(session.configuration == original && session.diskCapacityError != nil)
    session.cancelDiskCapacitySettings(draft: session.diskCapacityDraftNonce)
    session.diskCapacitySettingsDismissed()
    session.showDiskCapacitySettings()
    #expect(session.canSaveDiskCapacity && session.diskCapacityError == nil)
    #expect(service.calls.isEmpty)
    withExtendedLifetime((owner, replacementOwner)) {}
  }

  @Test func ownerRoundTripBeforeTheWriterStartsCancelsWithoutWriting() async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    let replacementOwner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    session.showDiskCapacitySettings()
    #expect(session.canSaveDiskCapacity)
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    #expect(session.preparing)
    // The MainActor task cannot start until this synchronous owner replacement finishes.
    session.window = replacementOwner
    session.window = owner
    try await finishUnexpectedGrowth(
      session, service: service, original: original, targetBytes: 2 * gibibyte)
    #expect(service.calls.isEmpty)
    #expect(session.configuration == original && session.diskCapacityError != nil)
    #expect(session.diskCapacityNotice == nil && !session.canSaveDiskCapacity)
    withExtendedLifetime((owner, replacementOwner)) {}
  }

  @Test func ownerRoundTripDuringGrowthCannotPublishAStaleCompletion() async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    let replacementOwner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    session.showDiskCapacitySettings()
    #expect(session.canSaveDiskCapacity)
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    try await entered(service)
    #expect(service.calls.count == 1)
    session.window = replacementOwner
    session.window = owner
    var completed = original
    completed.diskBytes = 2 * gibibyte
    service.finish(completed)
    try await settle(session)
    #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
    #expect(session.diskCapacityNotice == nil && session.diskCapacityError != nil)
    #expect(!session.canStartSelected && !session.canSaveDiskCapacity)
    #expect(service.calls.count == 1)
    withExtendedLifetime((owner, replacementOwner)) {}
  }

  @Test func uncertainFailureDisablesTheOldSelectionAndHidesPrivateDetails() async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    session.showDiskCapacitySettings()
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    try await entered(service)
    service.fail()
    try await settle(session)
    #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
    #expect(
      session.editingDiskCapacity && !session.canStartSelected && !session.canSaveDiskCapacity)
    #expect(session.diskCapacityError?.contains("private fixture detail") == false)
    withExtendedLifetime(owner) {}
  }

  @Test func ownerLossAndUnexpectedCompletionCannotLeaveTheOldSelectionStartable() async throws {
    for scenario in ["owner-loss", "owner-replacement", "wrong-result"] {
      let (root, original) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let service = ControlledDiskGrowth()
      let (session, owner) = try await open(root, configuration: original, service: service)
      session.showDiskCapacitySettings()
      session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
      try await entered(service)
      var completed = original
      let newOwner = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
      if scenario == "owner-loss" {
        session.window = nil
        completed.diskBytes = 2 * gibibyte
      } else if scenario == "owner-replacement" {
        session.window = newOwner
        completed.diskBytes = 2 * gibibyte
      }
      service.finish(completed)
      try await settle(session)
      #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
      #expect(session.diskCapacityNotice == nil && session.diskCapacityError != nil)
      #expect(!session.canStartSelected && !session.canSaveDiskCapacity)
      withExtendedLifetime((owner, newOwner)) {}
    }
  }

  @Test func repeatedSaveAndProgrammaticDismissalDoNotDuplicateTheWriterOrRetainTheDraft()
    async throws
  {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, owner) = try await open(root, configuration: original, service: service)
    session.showDiskCapacitySettings()
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    try await entered(service)
    session.saveDiskCapacity(targetBytes: 3 * gibibyte, draft: session.diskCapacityDraftNonce)
    #expect(service.calls.count == 1 && session.preparing)
    session.editingDiskCapacity = false
    session.diskCapacitySettingsDismissed()
    #expect(!session.canSaveDiskCapacity && !session.canEditDiskCapacity)
    var completed = original
    completed.diskBytes = 2 * gibibyte
    service.finish(completed)
    try await settle(session)
    #expect(session.configuration == completed && !session.editingDiskCapacity)
    #expect(session.diskCapacityConfiguration == nil && session.diskCapacityError == nil)
    #expect(service.calls.count == 1)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["failure", "stale-completion"], [false, true])
  func dismissedUncertainOperationRetainsItsMessageWithoutOverwritingANewerError(
    outcome: String, newerError: Bool
  ) async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ControlledDiskGrowth()
    let (session, originalOwner) = try await open(root, configuration: original, service: service)
    let owner = DiskCapacityWarningWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    let closingSheet = DiskCapacityWarningWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    session.window = owner
    session.showDiskCapacitySettings()
    #expect(session.canSaveDiskCapacity)
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    try await entered(service)
    owner.controlledSheet = closingSheet
    session.editingDiskCapacity = false
    session.diskCapacitySettingsDismissed()
    let sentinel = "A newer unrelated operation needs attention."
    if newerError { session.errorMessage = sentinel }
    if outcome == "failure" {
      service.fail()
    } else {
      var changed = original
      changed.name = "Temporary selection"
      session.configuration = changed
      session.configuration = original
      var completed = original
      completed.diskBytes = 2 * gibibyte
      service.finish(completed)
    }
    try await settle(session)
    #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
    #expect(session.diskCapacityError == nil && !session.canStartSelected)
    #expect(session.errorMessage != nil)
    #expect(session.errorMessage?.contains("private fixture detail") == false)
    if newerError {
      #expect(session.errorMessage == sentinel)
      #expect(session.canPresentOperationError)
    } else {
      #expect(!session.canPresentOperationError)
    }
    let retained = session.errorMessage
    owner.controlledSheet = nil
    if !newerError { #expect(!session.canPresentOperationError) }
    NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: owner)
    let deadline = ContinuousClock.now + .seconds(3)
    while !session.canPresentOperationError && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.canPresentOperationError && session.errorMessage == retained)
    #expect(
      try ConfigurationCodec.decode(
        Data(contentsOf: root.appendingPathComponent("configuration.json"))) == original)
    #expect(
      try await VMFiles().inspectWritableFile(at: root.appendingPathComponent("disk.raw"))
        .virtualBytes == gibibyte)
    withExtendedLifetime((originalOwner, owner, closingSheet)) {}
  }

  @Test func realDisposableGrowthUpdatesTheSameSelectionWithoutStartingAGuest() async throws {
    let (root, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, owner) = try await open(root, configuration: original)
    session.showDiskCapacitySettings()
    session.saveDiskCapacity(targetBytes: 2 * gibibyte, draft: session.diskCapacityDraftNonce)
    try await settle(session)
    var expected = original
    expected.diskBytes = 2 * gibibyte
    #expect(session.configuration == expected && !session.editingDiskCapacity)
    #expect(
      session.diskCapacityNotice != nil && session.state == .stopped && session.backend == nil)
    #expect(
      try ConfigurationCodec.decode(
        Data(
          contentsOf:
            root.appendingPathComponent("configuration.json"))) == expected)
    #expect(
      try await VMFiles().inspectWritableFile(at: root.appendingPathComponent("disk.raw"))
        .virtualBytes == 2 * gibibyte)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.json").path))
    withExtendedLifetime(owner) {}
  }
}
