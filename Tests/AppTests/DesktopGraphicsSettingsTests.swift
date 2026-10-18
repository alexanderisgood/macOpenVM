// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore

@testable import MacOpenVMApp

@MainActor private final class GraphicsSettingsPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class GraphicsSettingsWindow: NSWindow {
  var activationRequests = 0
  override var screen: NSScreen? { nil }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
}

/// Only fresh configuration metadata is inspected. No disk, platform identity,
/// worker capability, guest view, pointer capture or visible window is created.
@MainActor @Suite(.serialized) struct DesktopGraphicsSettingsTests {
  private struct Fixture {
    let root: URL
    let directory: URL
    let configuration: VMConfiguration
    let bytes: Data
    var registration: URL { directory.appendingPathComponent("configuration.json") }
  }

  @Test func editorCancellationAndBusyGatesPreserveTheSelectedMetadata() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (session, owner) = try await selected(fixture)
    defer { session.window = nil }
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    #expect(session.canEditGraphicsSettings && !session.isActive && !session.isBusy)
    try showEditor(session)
    #expect(session.editingGraphics && session.isBusy && !session.inputCaptured)
    #expect(!session.canRequestLibraryNavigation && !session.canEditNetworkSettings)
    session.showLibrary()
    session.showHardwareSettings()
    session.showLinuxCreation()
    #expect(!session.showingLibrary && !session.editingHardware && !session.creating)
    session.cancelGraphicsSettings()
    #expect(!session.editingGraphics && session.graphicsError == nil && !session.isBusy)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test func rememberedChoiceDoesNotFollowTheSameUUIDToAnotherURL() async throws {
    let first = try fixture()
    let second = try fixture(id: first.configuration.id)
    defer {
      try? FileManager.default.removeItem(at: first.root)
      try? FileManager.default.removeItem(at: second.root)
    }
    let (session, owner) = try await selected(first)
    defer { session.window = nil }
    let settings = accelerated()
    try showEditor(session)
    session.saveGraphicsSettings(settings)
    try await settle(session)
    #expect(!session.editingGraphics && session.graphicsError == nil)
    #expect(session.windowsGraphicsSettings == settings)
    #expect(session.windowsGraphicsSummary.contains("2560 × 1440 at 60 Hz"))
    try unchanged(first, session: session, owner: owner)
    try await session.qualificationSelectVM(
      at: second.registration, expectedID: second.configuration.id)
    #expect(session.selectedConfigurationURL == second.registration)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    try unchanged(second, session: session, owner: owner)
    try await session.qualificationSelectVM(
      at: first.registration, expectedID: first.configuration.id)
    #expect(session.windowsGraphicsSettings == settings)
    try unchanged(first, session: session, owner: owner)
  }

  @Test func changedLifecycleStateOrWindowRejectsAStaleEditor() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (session, owner) = try await selected(fixture)
    defer { session.window = nil }
    for state in [VMState.starting, .running, .paused, .stopping, .suspended] {
      try showEditor(session)
      session.state = state
      session.saveGraphicsSettings(accelerated())
      #expect(session.editingGraphics && session.graphicsError != nil && !session.preparing)
      #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
      session.state = .stopped
      session.cancelGraphicsSettings()
    }
    try showEditor(session)
    let replacement = makeWindow()
    session.window = replacement
    session.saveGraphicsSettings(accelerated())
    #expect(session.editingGraphics && session.graphicsError != nil && !session.preparing)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    session.cancelGraphicsSettings()
    session.window = owner
    #expect(replacement.activationRequests == 0)
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test func invalidGeometryAndUnknownHighRefreshKeepTheEditorOpen() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (session, owner) = try await selected(fixture)
    defer { session.window = nil }
    #expect(!session.canUse120HzGraphics)
    try showEditor(session)
    session.saveGraphicsSettings(
      WindowsGraphicsSettings(mode: .accelerated, initialWidth: 8192, initialHeight: 8192))
    #expect(session.editingGraphics && session.graphicsError != nil && !session.preparing)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    session.saveGraphicsSettings(
      WindowsGraphicsSettings(mode: .accelerated, refreshRate: .hz120))
    #expect(session.editingGraphics && session.graphicsError != nil && !session.preparing)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    session.saveGraphicsSettings(
      WindowsGraphicsSettings(
        mode: .basic, initialWidth: -1, initialHeight: Int.max, refreshRate: .hz120))
    try await settle(session)
    #expect(!session.editingGraphics && session.graphicsError == nil)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    try unchanged(fixture, session: session, owner: owner)
  }

  @Test func replacementUUIDAtTheSameLocationDoesNotInheritRememberedSettings() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (session, owner) = try await selected(fixture)
    defer { session.window = nil }
    try showEditor(session)
    session.saveGraphicsSettings(accelerated())
    try await settle(session)
    #expect(session.windowsGraphicsSettings == accelerated())
    var replacement = fixture.configuration
    replacement.id = UUID()
    let replacementBytes = try ConfigurationCodec.encode(replacement)
    try replacementBytes.write(to: fixture.registration)
    try await session.qualificationSelectVM(at: fixture.registration, expectedID: replacement.id)
    #expect(session.configuration == replacement)
    #expect(session.windowsGraphicsSettings == WindowsGraphicsSettings())
    #expect(try Data(contentsOf: fixture.registration) == replacementBytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == [
        "configuration.json"
      ])
    #expect(session.qualificationWindowsRuntime == nil && session.backend == nil)
    #expect(!session.isActive && !session.needsOwnershipRecovery && !session.canStartSelected)
    #expect(owner.activationRequests == 0)
  }

  private func accelerated() -> WindowsGraphicsSettings {
    WindowsGraphicsSettings(
      mode: .accelerated, initialWidth: 2560, initialHeight: 1440, refreshRate: .hz60)
  }

  private func fixture(id: UUID = UUID()) throws -> Fixture {
    let root = URL(fileURLWithPath: "/private/tmp/macOpenVM-desktop-graphics-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("Windows.macopenvm", isDirectory: true)
    for path in [root, directory] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let configuration = VMConfiguration(
      name: "Windows graphics fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30, id: id)
    let bytes = try ConfigurationCodec.encode(configuration)
    let registration = directory.appendingPathComponent("configuration.json")
    try bytes.write(to: registration)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: registration.path)
    return Fixture(root: root, directory: directory, configuration: configuration, bytes: bytes)
  }

  private func selected(_ fixture: Fixture) async throws -> (DesktopSession, GraphicsSettingsWindow)
  {
    _ = NSApplication.shared
    let owner = makeWindow()
    let session = DesktopSession(
      library: VMLibrary(preferences: GraphicsSettingsPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()))
    session.window = owner
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.configuration.id)
    #expect(session.configuration == fixture.configuration)
    #expect(session.selectedConfigurationURL == fixture.registration)
    #expect(session.qualificationWindowsRuntime == nil && session.backend == nil)
    #expect(!session.canStartSelected && session.windowsLaunchReadiness != .ready)
    return (session, owner)
  }

  private func makeWindow() -> GraphicsSettingsWindow {
    let window = GraphicsSettingsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: .titled, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  private func showEditor(_ session: DesktopSession) throws {
    // With no shared lease, the release route cannot invoke any association or
    // cursor-restoration closure. No guest view or pointer owner is ever installed.
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
    _ fixture: Fixture, session: DesktopSession, owner: GraphicsSettingsWindow
  ) throws {
    #expect(session.configuration == fixture.configuration)
    #expect(session.selectedConfigurationURL == fixture.registration)
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
