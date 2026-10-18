// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore

@testable import MacOpenVMApp

@MainActor private final class RememberedGraphicsLibraryPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class RememberedGraphicsWindow: NSWindow {
  var activationRequests = 0
  override var screen: NSScreen? { nil }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
}

/// Actual selection/editor routes with only fresh metadata and in-memory prefs.
/// No visible window, guest/pointer view, disk, lock, worker or Start route exists.
@MainActor @Suite(.serialized) struct DesktopGraphicsPreferencesTests {
  private struct Fixture {
    let directory: URL
    let configuration: VMConfiguration
    let bytes: Data
    var registration: URL { directory.appendingPathComponent("configuration.json") }
  }

  @Test func anExplicitSaveIsRestoredByAnotherSessionWithoutChangingVMFiles() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    let (first, firstOwner) = try await selected(fixture, memory: memory)
    defer { first.window = nil }
    try showEditor(first)
    first.saveGraphicsSettings(choice())
    try await settle(first)
    #expect(first.windowsGraphicsSettings == choice() && memory.writes == 1)
    let (reopened, secondOwner) = try await selected(fixture, memory: memory)
    defer { reopened.window = nil }
    #expect(reopened.windowsGraphicsSettings == choice())
    #expect(reopened.graphicsPreferencesWarning == nil && !reopened.editingGraphics)
    #expect(memory.writes == 1)
    try unchanged(fixture, session: first, owner: firstOwner)
    try unchanged(fixture, session: reopened, owner: secondOwner)
  }

  @Test func storedHighRefreshIsShownButUnknownCurrentScreenCannotSaveIt() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let high = WindowsGraphicsSettings(mode: .accelerated, refreshRate: .hz120)
    _ = try store.remember(
      high, from: store.load(at: fixture.registration, vmID: fixture.configuration.id))
    let (session, owner) = try await selected(fixture, memory: memory)
    defer { session.window = nil }
    #expect(session.windowsGraphicsSettings == high && !session.canUse120HzGraphics)
    #expect(session.windowsGraphicsSummary.contains("120 Hz"))
    try showEditor(session)
    session.saveGraphicsSettings(high)
    #expect(session.editingGraphics && session.graphicsError != nil && memory.writes == 1)
    #expect(session.windowsGraphicsSettings == high)
    session.cancelGraphicsSettings()
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test func unreadablePreferencesSelectBasicAndDoNotAuthorizeSaveOrReset() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    memory.failReads = true
    let (session, owner) = try await selected(fixture, memory: memory)
    defer { session.window = nil }
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    #expect(session.graphicsPreferencesWarning != nil)
    try showEditor(session)
    #expect(!session.canResetRememberedGraphicsSettings)
    session.saveGraphicsSettings(choice())
    #expect(session.editingGraphics && session.graphicsError != nil && memory.writes == 0)
    session.resetRememberedGraphicsSettings()
    #expect(session.editingGraphics && session.graphicsError != nil && memory.writes == 0)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    session.cancelGraphicsSettings()
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test func corruptPreferencesRequireExplicitResetAndASeparateSave() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    let corrupt = WindowsGraphicsPreferencesValue.data(Data("corrupt preference fixture".utf8))
    memory.value = corrupt
    let (session, owner) = try await selected(fixture, memory: memory)
    defer { session.window = nil }
    #expect(session.graphicsPreferencesWarning != nil)
    try showEditor(session)
    #expect(session.canResetRememberedGraphicsSettings)
    session.saveGraphicsSettings(choice())
    #expect(session.editingGraphics && session.graphicsError != nil)
    #expect(memory.value == corrupt && memory.writes == 0)
    session.resetRememberedGraphicsSettings()
    #expect(session.editingGraphics && session.graphicsError == nil)
    #expect(
      session.graphicsPreferencesWarning == nil && !session.canResetRememberedGraphicsSettings)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings() && memory.writes == 1)
    session.saveGraphicsSettings(choice())
    try await settle(session)
    #expect(
      !session.editingGraphics && session.windowsGraphicsSettings == choice() && memory.writes == 2)
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test(arguments: ["write", "readback-error", "readback-mismatch"])
  func failedPersistenceLeavesThePriorPublishedChoiceAndEditorIntact(kind: String) async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let prior = WindowsGraphicsSettings(mode: .accelerated, initialWidth: 1280, initialHeight: 720)
    _ = try store.remember(
      prior, from: store.load(at: fixture.registration, vmID: fixture.configuration.id))
    let (session, owner) = try await selected(fixture, memory: memory)
    defer { session.window = nil }
    try showEditor(session)
    let warning = session.graphicsPreferencesWarning
    memory.failWrites = kind == "write"
    memory.failReadback = kind == "readback-error"
    memory.mismatchedReadback = kind == "readback-mismatch"
    session.saveGraphicsSettings(choice())
    #expect(session.editingGraphics && session.graphicsError != nil && !session.preparing)
    #expect(
      session.windowsGraphicsSettings == prior && session.graphicsPreferencesWarning == warning)
    #expect(memory.writes == 2)
    // A failed confirmation may already have changed backing data. It must not
    // be described as an applied current choice or a rollback of the store.
    session.cancelGraphicsSettings()
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test func aSecondWindowSaveMakesTheFirstEditorsSnapshotStale() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    let (first, firstOwner) = try await selected(fixture, memory: memory)
    let (second, secondOwner) = try await selected(fixture, memory: memory)
    defer {
      first.window = nil
      second.window = nil
    }
    try showEditor(first)
    try showEditor(second)
    second.saveGraphicsSettings(choice())
    try await settle(second)
    let confirmed = memory.value
    first.saveGraphicsSettings(WindowsGraphicsSettings())
    #expect(first.editingGraphics && first.graphicsError != nil)
    #expect(first.windowsGraphicsSettings == WindowsGraphicsSettings())
    #expect(memory.value == confirmed && memory.writes == 1)
    first.cancelGraphicsSettings()
    try unchanged(fixture, session: first, owner: firstOwner)
    try unchanged(fixture, session: second, owner: secondOwner)
  }

  @Test func staleResetCannotEraseASecondWindowsRepairedPreferences() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    memory.value = .data(Data("broken".utf8))
    let (first, firstOwner) = try await selected(fixture, memory: memory)
    let (second, secondOwner) = try await selected(fixture, memory: memory)
    defer {
      first.window = nil
      second.window = nil
    }
    try showEditor(first)
    try showEditor(second)
    second.resetRememberedGraphicsSettings()
    second.saveGraphicsSettings(choice())
    try await settle(second)
    let confirmed = memory.value
    first.resetRememberedGraphicsSettings()
    #expect(first.editingGraphics && first.graphicsError != nil)
    #expect(first.windowsGraphicsSettings == WindowsGraphicsSettings())
    #expect(memory.value == confirmed && memory.writes == 2)
    first.cancelGraphicsSettings()
    try unchanged(fixture, session: first, owner: firstOwner)
    try unchanged(fixture, session: second, owner: secondOwner)
  }

  @Test func resetRevalidatesLifecycleAndOwnerBeforeTouchingPreferences() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    memory.value = .data(Data("broken".utf8))
    let original = memory.value
    let (session, owner) = try await selected(fixture, memory: memory)
    defer { session.window = nil }
    try showEditor(session)
    session.state = .running
    session.resetRememberedGraphicsSettings()
    #expect(session.graphicsError != nil && memory.value == original && memory.writes == 0)
    session.state = .stopped
    session.cancelGraphicsSettings()
    try showEditor(session)
    let replacement = makeWindow()
    session.window = replacement
    session.resetRememberedGraphicsSettings()
    #expect(session.graphicsError != nil && memory.value == original && memory.writes == 0)
    session.cancelGraphicsSettings()
    session.window = owner
    #expect(replacement.activationRequests == 0)
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test func privateEvaluationDoesNotReadOrRestoreOrdinaryPreferences() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let memory = MemoryWindowsGraphicsPreferences()
    memory.failReads = true
    let (session, owner) = try await selected(fixture, memory: memory, privateEvaluation: true)
    defer { session.window = nil }
    #expect(memory.reads == 0 && memory.writes == 0)
    #expect(!session.canEditGraphicsSettings && session.graphicsPreferencesWarning == nil)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    try unchanged(fixture, session: session, owner: owner)
  }

  private func choice() -> WindowsGraphicsSettings {
    WindowsGraphicsSettings(mode: .accelerated, initialWidth: 2560, initialHeight: 1440)
  }

  private func fixture() throws -> Fixture {
    let directory = URL(
      fileURLWithPath: "/private/tmp/macOpenVM-remembered-graphics-\(UUID().uuidString).macopenvm")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "Remembered graphics fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    let bytes = try ConfigurationCodec.encode(configuration)
    let registration = directory.appendingPathComponent("configuration.json")
    try bytes.write(to: registration)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: registration.path)
    return Fixture(directory: directory, configuration: configuration, bytes: bytes)
  }

  private func selected(
    _ fixture: Fixture, memory: MemoryWindowsGraphicsPreferences, privateEvaluation: Bool = false
  ) async throws -> (DesktopSession, RememberedGraphicsWindow) {
    _ = NSApplication.shared
    let owner = makeWindow()
    let session = DesktopSession(
      library: VMLibrary(preferences: RememberedGraphicsLibraryPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(preferences: memory),
      acceleratedDisplayEvaluation: privateEvaluation)
    session.window = owner
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.configuration.id)
    #expect(session.configuration == fixture.configuration)
    #expect(session.selectedConfigurationURL == fixture.registration)
    return (session, owner)
  }

  private func makeWindow() -> RememberedGraphicsWindow {
    let window = RememberedGraphicsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: .titled, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  private func showEditor(_ session: DesktopSession) throws {
    try #require(GuestHostPointerCapture.shared.canAcquire(for: UUID()))
    session.showGraphicsSettings()
    #expect(session.editingGraphics)
  }

  private func settle(_ session: DesktopSession) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while session.preparing && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!session.preparing)
  }

  private func unchanged(
    _ fixture: Fixture, session: DesktopSession, owner: RememberedGraphicsWindow
  ) throws {
    #expect(try Data(contentsOf: fixture.registration) == fixture.bytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == [
        "configuration.json"
      ])
    #expect(session.qualificationWindowsRuntime == nil && session.backend == nil)
    #expect(!session.isActive && !session.needsOwnershipRecovery && !session.canStartSelected)
    #expect(owner.activationRequests == 0)
  }
}
