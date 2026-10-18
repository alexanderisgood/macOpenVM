// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class NetworkEditorPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class NetworkLibraryPresentation: LibraryNetworkPresentation {
  var selectable = true
  var detached = false
  func canSelect(on owner: NSWindow?) -> Bool { selectable }
  func isDetached(on owner: NSWindow?) -> Bool { detached }
}

@MainActor private final class NetworkEditorWindow: NSWindow {
  override func makeKeyAndOrderFront(_ sender: Any?) {}
}

@MainActor @Suite struct NetworkSettingsSessionTests {
  private func fixture() throws -> (URL, VMConfiguration, Data) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "Network editor", guest: .linux, backend: .appleVz, cpuCount: 1,
      memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let bytes = try ConfigurationCodec.encode(configuration)
    try bytes.write(to: root.appendingPathComponent("configuration.json"))
    let disk = root.appendingPathComponent("disk.raw")
    #expect(FileManager.default.createFile(atPath: disk.path, contents: nil))
    let handle = try FileHandle(forWritingTo: disk)
    try handle.truncate(atOffset: configuration.diskBytes)
    try handle.close()
    for file in [disk, root.appendingPathComponent("configuration.json")] {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    return (root, configuration, bytes)
  }

  private func settle(_ session: DesktopSession) async throws {
    await Task.yield()
    let deadline = ContinuousClock.now + .seconds(3)
    while session.preparing && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.preparing)
  }

  private func open(_ root: URL, configuration: VMConfiguration) async throws
    -> (DesktopSession, NetworkEditorWindow)
  {
    _ = NSApplication.shared
    let library = VMLibrary(preferences: NetworkEditorPreferences())
    let registration = root.appendingPathComponent("configuration.json")
    let session = DesktopSession(library: library)
    try await session.qualificationSelectVM(at: registration, expectedID: configuration.id)
    let owner = NetworkEditorWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    session.window = owner
    #expect(session.configuration == configuration)
    #expect(session.selectedConfigurationURL == registration)
    return (session, owner)
  }

  @Test func networkEditorBlocksConflictingActionsAndCancellationDoesNotSave() async throws {
    let (root, configuration, bytes) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, hostWindow) = try await open(root, configuration: configuration)
    defer { withExtendedLifetime(hostWindow) {} }
    #expect(session.canCopySelected && session.canEditNetworkSettings)
    session.inputCaptured = true
    session.showNetworkSettings()
    #expect(session.editingNetwork && session.isBusy)
    #expect(!session.inputCaptured && !session.canCopySelected)
    #expect(session.networkConfiguration == configuration)
    session.showLibrary()
    session.showHardwareSettings()
    #expect(!session.showingLibrary && !session.editingHardware)
    session.saveHardware(cpuCount: 2, memoryBytes: 1 << 30)
    #expect(!session.preparing)
    session.editingNetwork = false
    session.networkSettingsDismissed()
    #expect(session.networkConfiguration == nil && session.networkError == nil)
    #expect(session.canEditNetworkSettings)
    #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
  }

  @Test func stoppedSaveChangesOnlyModeAndReopensTheSavedSelection() async throws {
    let (root, configuration, bytes) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, hostWindow) = try await open(root, configuration: configuration)
    defer { withExtendedLifetime(hostWindow) {} }
    session.showNetworkSettings()
    session.saveNetwork(mode: .shared)
    try await settle(session)
    var expected = configuration
    expected.network = .shared
    #expect(session.configuration == expected)
    #expect(!session.editingNetwork && session.networkError == nil)
    #expect(session.selectedConfigurationURL == root.appendingPathComponent("configuration.json"))
    #expect(session.state == .stopped && session.backend == nil)
    #expect(
      try ConfigurationCodec.decode(
        Data(contentsOf: root.appendingPathComponent("configuration.json")))
        == expected)
    let backup = try #require(
      FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix("configuration-network-backup-") })
    #expect(try Data(contentsOf: backup) == bytes)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.json").path))
    session.networkSettingsDismissed()
    session.showNetworkSettings()
    #expect(session.networkConfiguration == expected)
  }

  @Test func staleRegistrationClearsTheSelectionWithoutReplacingTheEditedFile() async throws {
    let (root, configuration, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, hostWindow) = try await open(root, configuration: configuration)
    defer { withExtendedLifetime(hostWindow) {} }
    session.showNetworkSettings()
    var changed = configuration
    changed.name = "Changed in another editor"
    let changedBytes = try ConfigurationCodec.encode(changed)
    try changedBytes.write(to: root.appendingPathComponent("configuration.json"))
    session.saveNetwork(mode: .shared)
    try await settle(session)
    #expect(session.networkError != nil && session.editingNetwork)
    #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
    #expect(!session.canStartSelected && !session.canCopySelected)
    #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == changedBytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path)
        .allSatisfy { !$0.hasPrefix("configuration-network-backup-") })
  }

  @Test func heldWriterPreservesTheCurrentSelectionAndRegistration() async throws {
    let (root, configuration, bytes) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, hostWindow) = try await open(root, configuration: configuration)
    defer { withExtendedLifetime(hostWindow) {} }
    let owner = try VMLock(directory: root, expectedVMID: configuration.id)
    session.showNetworkSettings()
    session.saveNetwork(mode: .shared)
    try await settle(session)
    #expect(session.networkError != nil && session.editingNetwork)
    #expect(session.configuration == configuration)
    #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == bytes)
    withExtendedLifetime(owner) {}
  }

  @Test func libraryNetworkingSelectsTheExactEntryOnlyAfterDismissal() async throws {
    let (firstRoot, first, _) = try fixture()
    let (secondRoot, second, bytes) = try fixture()
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }
    let (session, hostWindow) = try await open(firstRoot, configuration: first)
    defer { withExtendedLifetime(hostWindow) {} }
    let location = secondRoot.appendingPathComponent("configuration.json")
    session.library.remember(second, at: location)
    let entry = try #require(session.library.entries.first { $0.vmID == second.id })
    session.showLibrary()
    #expect(session.canOpenSavedNetworkSettings(entry))
    session.openSavedNetworkSettings(entry)
    #expect(!session.showingLibrary && session.isBusy && !session.preparing)
    #expect(session.configuration == first && !session.editingNetwork)
    session.libraryDismissed()
    try await settle(session)
    #expect(session.configuration == second && session.selectedConfigurationURL == location)
    #expect(session.editingNetwork && session.networkConfiguration == second)
    #expect(session.state == .stopped && session.backend == nil)
    #expect(try Data(contentsOf: location) == bytes)
  }

  @Test func libraryNetworkingRefusesBusyCreatingAndForgottenEntries() async throws {
    let (root, configuration, bytes) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, hostWindow) = try await open(root, configuration: configuration)
    defer { withExtendedLifetime(hostWindow) {} }
    let entry = try #require(session.library.entries.first)
    session.showLibrary()
    session.state = .running
    #expect(!session.canOpenSavedNetworkSettings(entry))
    session.openSavedNetworkSettings(entry)
    #expect(session.showingLibrary)
    session.state = .stopped
    session.preparing = true
    #expect(!session.canOpenSavedNetworkSettings(entry))
    session.preparing = false
    session.creating = true
    #expect(!session.canOpenSavedNetworkSettings(entry))
    session.creating = false
    session.library.forget(entry)
    #expect(!session.canOpenSavedNetworkSettings(entry))
    session.openSavedNetworkSettings(entry)
    #expect(session.showingLibrary && !session.editingNetwork)
    #expect(try Data(contentsOf: entry.configurationURL) == bytes)
  }

  @Test func libraryNetworkingRejectsReplacementAfterTheClick() async throws {
    let (root, configuration, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, hostWindow) = try await open(root, configuration: configuration)
    defer { withExtendedLifetime(hostWindow) {} }
    let entry = try #require(session.library.entries.first)
    session.showLibrary()
    session.openSavedNetworkSettings(entry)
    var replacement = configuration
    replacement.id = UUID()
    let bytes = try ConfigurationCodec.encode(replacement)
    try bytes.write(to: entry.configurationURL)
    session.libraryDismissed()
    try await settle(session)
    #expect(!session.editingNetwork && session.errorMessage != nil)
    #expect(session.configuration == configuration)
    #expect(try Data(contentsOf: entry.configurationURL) == bytes)
  }

  @Test func libraryNetworkingCancelsWhenTheOriginalOwnerChanges() async throws {
    let (root, configuration, bytes) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, hostWindow) = try await open(root, configuration: configuration)
    defer { withExtendedLifetime(hostWindow) {} }
    let entry = try #require(session.library.entries.first)
    let first = NSWindow()
    let replacement = NSWindow()
    session.window = first
    session.showLibrary()
    session.openSavedNetworkSettings(entry)
    session.window = replacement
    session.libraryDismissed()
    try await settle(session)
    #expect(!session.preparing && !session.editingNetwork && !session.isBusy)
    #expect(session.configuration == configuration)
    #expect(try Data(contentsOf: entry.configurationURL) == bytes)
  }

  @Test func libraryNetworkingOwnerChangeDuringDeferredDismissalPreservesThePreviousVM()
    async throws
  {
    let (firstRoot, first, _) = try fixture()
    let (secondRoot, second, _) = try fixture()
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }
    let (session, hostWindow) = try await open(firstRoot, configuration: first)
    defer { withExtendedLifetime(hostWindow) {} }
    let location = secondRoot.appendingPathComponent("configuration.json")
    session.library.remember(second, at: location)
    let entry = try #require(session.library.entries.first { $0.vmID == second.id })
    let owner = NSWindow()
    let replacement = NSWindow()
    session.window = owner
    session.showLibrary()
    session.openSavedNetworkSettings(entry)
    session.libraryDismissed()
    let deadline = ContinuousClock.now + .seconds(3)
    while !session.preparing && ContinuousClock.now < deadline { await Task.yield() }
    #expect(session.preparing)
    session.window = replacement
    try await settle(session)
    #expect(session.configuration == first)
    #expect(
      session.selectedConfigurationURL == firstRoot.appendingPathComponent("configuration.json"))
    #expect(!session.editingNetwork && !session.isBusy)
  }

  @Test func libraryNetworkingRejectsAStaleSheetAndCannotReplayAfterDismissal() async throws {
    let (root, configuration, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = NSApplication.shared
    let library = VMLibrary(preferences: NetworkEditorPreferences())
    library.remember(configuration, at: root.appendingPathComponent("configuration.json"))
    let presentation = NetworkLibraryPresentation()
    let session = DesktopSession(library: library, libraryNetworkPresentation: presentation)
    let entry = try #require(library.entries.first)
    session.showLibrary()
    #expect(session.canOpenSavedNetworkSettings(entry))
    session.openSavedNetworkSettings(entry)
    session.libraryDismissed()
    #expect(session.isBusy)
    try await settle(session)
    #expect(!session.preparing && !session.isBusy && !session.editingNetwork)
    presentation.detached = true
    session.libraryDismissed()
    try await settle(session)
    #expect(!session.editingNetwork)
    #expect(session.configuration == nil)
    session.showLibrary()
    presentation.selectable = false
    #expect(!session.canOpenSavedNetworkSettings(entry))
    session.openSavedNetworkSettings(entry)
    #expect(session.showingLibrary && !session.editingNetwork)
  }
}
