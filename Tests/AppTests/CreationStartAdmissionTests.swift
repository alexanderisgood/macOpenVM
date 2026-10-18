// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Combine
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class CreationStartPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class CreationStartWindow: NSWindow {
  var controlledSheet: NSWindow?
  var activationRequests = 0
  override var attachedSheet: NSWindow? { controlledSheet }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
}

@MainActor @Suite(.serialized) struct CreationStartAdmissionTests {
  private struct Fixture {
    let root: URL
    let configuration: VMConfiguration
    let bytes: Data
    let session: DesktopSession
    let owner: CreationStartWindow
    var registration: URL { root.appendingPathComponent("configuration.json") }
  }

  private func fixture() async throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("creation-start-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "Previously selected VM", guest: .linux, backend: .appleVz,
      cpuCount: 1, memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let bytes = try ConfigurationCodec.encode(configuration)
    try await VMFiles().atomicWrite(bytes, at: root.appendingPathComponent("configuration.json"))
    // Deliberately no disk, EFI or identity. Even the old accidental start must
    // fail at inspectWritableFile before AppleVirtualMachine construction.
    let owner = CreationStartWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    owner.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let session = DesktopSession(
      library: VMLibrary(preferences: CreationStartPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()))
    session.window = owner
    try await session.qualificationSelectVM(
      at: root.appendingPathComponent("configuration.json"), expectedID: configuration.id)
    #expect(session.canStartSelected && session.canRequestStart && !session.isBusy)
    return Fixture(
      root: root, configuration: configuration, bytes: bytes, session: session, owner: owner)
  }

  private func settleUnexpectedAttempt(_ session: DesktopSession) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while session.preparing && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.preparing)
  }

  private func preserved(_ fixture: Fixture) throws {
    let s = fixture.session
    #expect(
      s.configuration == fixture.configuration && s.selectedConfigurationURL == fixture.registration
    )
    #expect(!s.isActive && s.backend == nil && s.qualificationWindowsRuntime == nil)
    #expect(!s.needsOwnershipRecovery && fixture.owner.activationRequests == 0)
    #expect(try Data(contentsOf: fixture.registration) == fixture.bytes)
    // Reject writer admission as well as backend construction. On the old draft
    // path, the missing disk bounds cleanup but a writer.lock may already appear.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        == ["configuration.json"])
  }

  @Test(arguments: ["new-linux", "library"])
  func visibleDraftOrLibraryCannotStartThePreviouslySelectedVM(surface: String) async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let s = f.session
    if surface == "new-linux" {
      s.showLinuxCreation()
      try #require(s.creating)
    } else {
      s.showLibrary()
      try #require(s.showingLibrary)
    }
    let nonce = s.creationDraftNonce
    s.errorMessage = "Keep this existing draft or workspace message"
    var preparingPublications = 0
    let observation = s.$preparing.dropFirst().sink { value in
      if value { preparingPublications += 1 }
    }
    defer { observation.cancel() }
    // Saved resource eligibility remains true; the visible surface blocks the
    // same action predicate shared by Machine Start and the workspace button.
    #expect(s.canStartSelected && !s.canRequestStart)
    s.start()
    #expect(!s.preparing && preparingPublications == 0)
    try await settleUnexpectedAttempt(s)
    #expect(preparingPublications == 0)
    #expect(s.errorMessage == "Keep this existing draft or workspace message")
    #expect(s.creationDraftNonce == nonce)
    #expect(surface == "new-linux" ? s.creating : s.showingLibrary)
    try preserved(f)
    if surface == "new-linux" {
      s.cancelCreation(nonce: nonce)
    } else {
      s.showingLibrary = false
    }
    #expect(s.canRequestStart && s.canStartSelected)
    withExtendedLifetime(f.owner) {}
  }

  @Test func workspaceAdmissionTracksOwnerSheetAndLifecycleWithoutStartingABackend() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let s = f.session
    let states: [VMState] = [.stopped, .failed, .starting, .running, .paused, .stopping, .saving]
    for state in states {
      s.state = state
      #expect(s.canStartSelected)
      #expect(s.canRequestStart == (state == .stopped || state == .failed))
    }
    s.state = .stopped
    s.preparing = true
    #expect(!s.canRequestStart && s.canStartSelected)
    s.preparing = false
    let content = try #require(f.owner.contentView)
    f.owner.contentView = nil
    #expect(!s.canRequestStart && s.canStartSelected)
    f.owner.contentView = content
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    f.owner.controlledSheet = sheet
    #expect(!s.canRequestStart && s.canStartSelected)
    f.owner.controlledSheet = nil
    s.window = nil
    #expect(!s.canRequestStart && s.canStartSelected)
    s.window = f.owner
    #expect(s.canRequestStart && s.canStartSelected)
    try preserved(f)
    withExtendedLifetime((f.owner, sheet, content)) {}
  }
}
