// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class StoppedSettingsPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class StoppedSettingsWindow: NSWindow {
  var activationRequests = 0
  var controlledSheet: NSWindow?
  override var attachedSheet: NSWindow? { controlledSheet }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
}

/// The barrier follows an actual ordinary Core save; it never supplies a fabricated result.
@MainActor
private final class ControlledStoppedSettings:
  DesktopHardwareSettingsUpdating, DesktopNetworkSettingsUpdating
{
  var calls = 0
  var holdCompletion = true
  var failAfterCommit = false
  var committed: VMConfiguration?
  var pending: CheckedContinuation<Void, Never>?

  func update(in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64)
    async throws -> VMConfiguration
  {
    calls += 1
    let result = try await NativeDesktopHardwareSettings().update(
      in: directory, expected: expected, cpuCount: cpuCount, memoryBytes: memoryBytes)
    return try await completed(result)
  }

  func update(
    in directory: URL, expected: VMConfiguration, mode: NetworkMode,
    sharedPermission: SharedNetworkConfigurationPermission?
  ) async throws -> VMConfiguration {
    calls += 1
    let result = try await NativeDesktopNetworkSettings().update(
      in: directory, expected: expected, mode: mode, sharedPermission: sharedPermission)
    return try await completed(result)
  }

  private func completed(_ configuration: VMConfiguration) async throws -> VMConfiguration {
    committed = configuration
    if holdCompletion { await withCheckedContinuation { pending = $0 } }
    if failAfterCommit { throw NSError(domain: "private post-commit fixture detail", code: 1) }
    return configuration
  }

  func release() {
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

/// Always unavailable: no fixture can manufacture a shared-network permission.
@MainActor private final class ControlledUnavailableNetwork: DesktopSharedNetworkPreparing {
  var calls = 0
  var released = false
  var pending: CheckedContinuation<Void, Never>?
  func permission(for configuration: VMConfiguration) async throws
    -> SharedNetworkConfigurationPermission
  {
    calls += 1
    if !released { await withCheckedContinuation { pending = $0 } }
    throw NSError(domain: "private unavailable catalog fixture", code: 1)
  }
  func release() {
    released = true
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

/// Actual hidden sessions and fresh files only. No guest, native sheets, activation or input.
@MainActor @Suite(.serialized) struct DesktopStoppedSettingsAdmissionTests {
  enum Kind: CaseIterable, Sendable { case hardware, network }
  enum Timing: CaseIterable, Sendable { case beforeSave, beforeWriter }
  private struct Fixture {
    let root: URL
    let original: VMConfiguration
    let bytes: Data
    var registration: URL { root.appendingPathComponent("configuration.json") }
  }

  private func fixture(windows: Bool = false) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("stopped-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "Stopped editor", guest: windows ? .windows11 : .linux,
      backend: windows ? .qemuHVF : .appleVz, cpuCount: windows ? 2 : 1,
      memoryBytes: windows ? 4 << 30 : 512 << 20, diskBytes: windows ? 64 << 30 : 1 << 30)
    let bytes = try ConfigurationCodec.encode(configuration)
    let files = VMFiles()
    try await files.atomicWrite(bytes, at: root.appendingPathComponent("configuration.json"))
    if !windows {
      try await files.createSparseDisk(at: root.appendingPathComponent("disk.raw"), bytes: 1 << 30)
    }
    return Fixture(root: root, original: configuration, bytes: bytes)
  }

  private func window() -> StoppedSettingsWindow {
    let owner = StoppedSettingsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    return owner
  }

  private func selected(
    _ fixture: Fixture, service: ControlledStoppedSettings,
    catalog: any DesktopSharedNetworkPreparing = NativeDesktopSharedNetworkPreparation()
  ) async throws -> (DesktopSession, StoppedSettingsWindow) {
    _ = NSApplication.shared
    let owner = window()
    let session = DesktopSession(
      library: VMLibrary(preferences: StoppedSettingsPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      hardwareSettings: service, networkSettings: service, sharedNetworkPreparation: catalog)
    session.window = owner
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.original.id)
    #expect(session.configuration == fixture.original)
    #expect(session.selectedConfigurationURL == fixture.registration && !session.isBusy)
    return (session, owner)
  }

  private func show(_ kind: Kind, session: DesktopSession) {
    if kind == .hardware { session.showHardwareSettings() } else { session.showNetworkSettings() }
    #expect(kind == .hardware ? session.editingHardware : session.editingNetwork)
  }

  private func save(_ kind: Kind, session: DesktopSession) {
    if kind == .hardware {
      session.saveHardware(cpuCount: 1, memoryBytes: 1 << 30)
    } else {
      session.saveNetwork(mode: .shared)
    }
  }

  private func cancel(_ kind: Kind, session: DesktopSession) {
    if kind == .hardware {
      session.editingHardware = false
      session.hardwareSettingsDismissed()
    } else {
      session.editingNetwork = false
      session.networkSettingsDismissed()
    }
  }

  private func settle(_ session: DesktopSession) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while session.preparing && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.preparing)
  }

  private func entered(_ service: ControlledStoppedSettings) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while service.pending == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.pending != nil && service.committed != nil)
  }

  private func drainUnexpectedWriter(_ service: ControlledStoppedSettings, session: DesktopSession)
    async throws
  {
    let deadline = ContinuousClock.now + .seconds(4)
    while session.preparing && service.pending == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    service.release()
    try await settle(session)
  }

  private func requireCommittedBackup(
    _ kind: Kind, fixture: Fixture, configuration: VMConfiguration
  ) throws {
    #expect(try ConfigurationCodec.decode(Data(contentsOf: fixture.registration)) == configuration)
    let prefix =
      kind == .hardware ? "configuration-hardware-backup-" : "configuration-network-backup-"
    let backups = try FileManager.default.contentsOfDirectory(
      at: fixture.root, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(prefix) }
    #expect(backups.count == 1)
    let backup = try #require(backups.first)
    #expect(try Data(contentsOf: backup) == fixture.bytes)
  }

  @Test(arguments: Kind.allCases, Timing.allCases)
  func ownerRoundTripsBeforeTheWriterCannotReuseAnOldConfirmation(kind: Kind, timing: Timing)
    async throws
  {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = ControlledStoppedSettings()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let (session, owner) = try await selected(fixture, service: service)
    let replacement = window()
    show(kind, session: session)
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
    if timing == .beforeWriter {
      save(kind, session: session)
      #expect(session.preparing)
    }
    session.window = replacement
    session.window = owner
    if timing == .beforeSave { save(kind, session: session) }
    try await drainUnexpectedWriter(service, session: session)
    #expect(service.calls == 0 && session.configuration == fixture.original)
    #expect(try Data(contentsOf: fixture.registration) == fixture.bytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == names)
    cancel(kind, session: session)
    show(kind, session: session)
    service.holdCompletion = false
    save(kind, session: session)
    try await settle(session)
    #expect(service.calls == 1 && session.configuration == service.committed)
    try requireCommittedBackup(kind, fixture: fixture, configuration: #require(service.committed))
    #expect(owner.activationRequests == 0 && replacement.activationRequests == 0)
    withExtendedLifetime((owner, replacement)) {}
  }

  @Test(arguments: Kind.allCases)
  func ownerRoundTripAfterRealCommitPreservesTheTransactionWithoutPublishingStaleSuccess(kind: Kind)
    async throws
  {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = ControlledStoppedSettings()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let (session, owner) = try await selected(fixture, service: service)
    let replacement = window()
    show(kind, session: session)
    save(kind, session: session)
    try await entered(service)
    let committed = try #require(service.committed)
    try requireCommittedBackup(kind, fixture: fixture, configuration: committed)
    session.window = replacement
    session.window = owner
    service.release()
    try await settle(session)
    #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
    #expect(!session.canStartSelected && service.calls == 1)
    #expect(try ConfigurationCodec.decode(Data(contentsOf: fixture.registration)) == committed)
    #expect(kind == .hardware ? session.hardwareError != nil : session.networkError != nil)
    withExtendedLifetime((owner, replacement)) {}
  }

  @Test(arguments: Kind.allCases, [false, true])
  func lateSuccessOrPostCommitDeliveryFailureCannotOverwriteAnUnrelatedReplacement(
    kind: Kind, fail: Bool
  ) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = ControlledStoppedSettings()
    defer {
      service.holdCompletion = false
      service.release()
    }
    service.failAfterCommit = fail
    let (session, owner) = try await selected(fixture, service: service)
    show(kind, session: session)
    save(kind, session: session)
    try await entered(service)
    try requireCommittedBackup(kind, fixture: fixture, configuration: #require(service.committed))
    var replacement = fixture.original
    replacement.id = UUID()
    replacement.name = "Independent replacement"
    let bytes = try ConfigurationCodec.encode(replacement)
    // Real Core has released its writer; this models a later independent saved replacement.
    try await VMFiles().atomicWrite(bytes, at: fixture.registration)
    session.configuration = replacement
    service.release()
    try await settle(session)
    #expect(session.configuration == replacement)
    #expect(session.selectedConfigurationURL == fixture.registration)
    #expect(try Data(contentsOf: fixture.registration) == bytes)
    #expect(kind == .hardware ? session.hardwareError != nil : session.networkError != nil)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: Kind.allCases)
  func dismissedEditorKeepsAnUncertainRealCommitVisibleAndInvalidatesOnlyTheOldSelection(kind: Kind)
    async throws
  {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = ControlledStoppedSettings()
    defer {
      service.holdCompletion = false
      service.release()
    }
    service.failAfterCommit = true
    let (session, owner) = try await selected(fixture, service: service)
    show(kind, session: session)
    save(kind, session: session)
    try await entered(service)
    let committed = try #require(service.committed)
    try requireCommittedBackup(kind, fixture: fixture, configuration: committed)
    let closingSheet = window()
    owner.controlledSheet = closingSheet
    cancel(kind, session: session)
    service.release()
    try await settle(session)
    #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
    #expect(session.errorMessage != nil && !session.canStartSelected)
    #expect(session.errorMessage?.contains("private post-commit fixture detail") == false)
    #expect(!session.canPresentOperationError)
    let message = session.errorMessage
    owner.controlledSheet = nil
    #expect(!session.canPresentOperationError)
    NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: owner)
    let deadline = ContinuousClock.now + .seconds(3)
    while !session.canPresentOperationError && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.canPresentOperationError && session.errorMessage == message)
    // An alert's later attachment cannot re-block an already admitted warning.
    owner.controlledSheet = window()
    NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: owner)
    await Task.yield()
    await Task.yield()
    #expect(session.canPresentOperationError && session.errorMessage == message)
    owner.controlledSheet = nil
    #expect(try ConfigurationCodec.decode(Data(contentsOf: fixture.registration)) == committed)
    withExtendedLifetime((owner, closingSheet)) {}
  }

  @Test(arguments: ["replacement", "nil"])
  func abandonedOwnerCannotKeepAHiddenEditorWarningBlocked(change: String) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = ControlledStoppedSettings()
    defer {
      service.holdCompletion = false
      service.release()
    }
    service.failAfterCommit = true
    let (session, owner) = try await selected(fixture, service: service)
    let replacement = window()
    show(.hardware, session: session)
    save(.hardware, session: session)
    try await entered(service)
    owner.controlledSheet = window()
    cancel(.hardware, session: session)
    service.release()
    try await settle(session)
    #expect(session.errorMessage != nil && !session.canPresentOperationError)
    let message = session.errorMessage
    session.window = change == "replacement" ? replacement : nil
    #expect(session.canPresentOperationError && session.errorMessage == message)
    // Clearing this message also releases its private gate for an unrelated error.
    session.errorMessage = nil
    session.errorMessage = "Unrelated newer operation"
    #expect(session.canPresentOperationError)
    withExtendedLifetime((owner, replacement)) {}
  }

  @Test(arguments: ["owner-aba", "configuration-aba"])
  func unavailableWindowsCatalogCannotPresentAStaleNetworkEditor(change: String) async throws {
    let fixture = try await fixture(windows: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = ControlledStoppedSettings()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let catalog = ControlledUnavailableNetwork()
    defer { catalog.release() }
    let (session, owner) = try await selected(fixture, service: service, catalog: catalog)
    let replacement = window()
    session.showNetworkSettings()
    let deadline = ContinuousClock.now + .seconds(4)
    while catalog.pending == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(catalog.pending != nil && catalog.calls == 1)
    if change == "owner-aba" {
      session.window = replacement
      session.window = owner
    } else {
      var changed = fixture.original
      changed.name = "Temporary selection"
      session.configuration = changed
      session.configuration = fixture.original
    }
    catalog.release()
    try await settle(session)
    #expect(!session.editingNetwork && session.networkSharedPermission == nil)
    #expect(session.configuration == fixture.original && service.calls == 0)
    #expect(try Data(contentsOf: fixture.registration) == fixture.bytes)
    #expect(owner.activationRequests == 0 && replacement.activationRequests == 0)
    withExtendedLifetime((owner, replacement)) {}
  }
}
