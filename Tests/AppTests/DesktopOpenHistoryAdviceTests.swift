// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class OpenHistoryAdvicePreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class OpenHistoryAdviceWindow: NSWindow {
  override func makeKeyAndOrderFront(_ sender: Any?) {}
}

/// Existing generated Linux/Core fixture pattern; no VZ/QEMU or native firmware call.
@MainActor private struct OpenHistoryAdvicePlatform: VMCreationPlatform {
  let backend = BackendID.appleVz
  func validateHost(for configuration: VMConfiguration) throws {}
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    try Data(configuration.id.uuidString.utf8).write(
      to: directory.appendingPathComponent("machine-identity.bin"), options: .withoutOverwriting)
    try Data("generated EFI fixture; not a firmware test".utf8).write(
      to: directory.appendingPathComponent("efi-variables.bin"), options: .withoutOverwriting)
    return CreatedPlatformIdentity(files: ["machine-identity.bin", "efi-variables.bin"])
  }
}

/// Suspends the ordinary real inspector. Reports/history classifications are not fabricated.
@MainActor private final class ControlledOpenHistoryInspector: DesktopVMSelectionInspecting {
  enum Pause: Equatable { case none, beforeRead, afterRead }
  var pause = Pause.none
  var histories: [RuntimeHistoryStatus] = []
  var failure: Error?
  var pending: CheckedContinuation<Void, Never>?

  func inspect(at registration: URL, expectedID: UUID?) async throws
    -> DesktopVMSelectionObservation
  {
    if pause == .beforeRead { await withCheckedContinuation { pending = $0 } }
    do {
      let observation = try await NativeDesktopVMSelectionInspector().inspect(
        at: registration, expectedID: expectedID)
      histories.append(observation.report.history)
      if pause == .afterRead { await withCheckedContinuation { pending = $0 } }
      return observation
    } catch {
      failure = error
      throw error
    }
  }

  func release() {
    pause = .none
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

/// Actual sessions, ordinary Library row actions and real disposable Core files.
/// These are source/model schedules; no native panel or VM is presented or started.
@MainActor @Suite(.serialized) struct DesktopOpenHistoryAdviceTests {
  enum Destination: CaseIterable, Equatable, Sendable { case hardware, network }
  enum Advisory: CaseIterable, Sendable {
    case interrupted, forced, failed
    var history: RuntimeHistoryStatus {
      switch self {
      case .interrupted: .interruptedOrUnreconciled
      case .forced: .forcedStopRecorded
      case .failed: .failureRecorded
      }
    }
  }

  private struct Fixture {
    let root: URL
    let configuration: VMConfiguration
    let history: RuntimeHistoryStatus
    var directory: URL { root.appendingPathComponent("Saved.macopenvm") }
    var registration: URL { directory.appendingPathComponent("configuration.json") }
    var runtime: URL { directory.appendingPathComponent("runtime.json") }
  }

  private struct Snapshot: Equatable {
    let configuration: Data
    let history: Data?
    let identity: Data
    let efi: Data
    let names: [String]
    let diskLength: UInt64
    let diskFirst: Data
    let diskLast: Data
  }

  private func fixture(
    history: RuntimeHistoryStatus, configuration supplied: VMConfiguration? = nil
  ) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-history-advice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let media = root.appendingPathComponent("generated.iso")
    try Data(repeating: 0x52, count: 1024).write(to: media)
    var configuration =
      supplied
      ?? VMConfiguration(
        name: "Saved history", guest: .linux, backend: .appleVz, cpuCount: 1,
        memoryBytes: 512 << 20, diskBytes: 1 << 30)
    if supplied == nil { configuration.installationMedia = media.path }
    let fixture = Fixture(root: root, configuration: configuration, history: history)
    try await VMCreation().create(
      configuration, at: fixture.directory, platform: OpenHistoryAdvicePlatform(),
      host: HostResources(cpuCount: 8, memoryBytes: 16 << 30))
    if history != .notRecorded {
      let snapshot: RuntimeSnapshot
      switch history {
      case .interruptedOrUnreconciled:
        snapshot = RuntimeSnapshot(
          state: .starting, operation: .start, backendActive: false, outcome: .pending)
      case .forcedStopRecorded:
        snapshot = RuntimeSnapshot(
          state: .stopped, operation: nil, backendActive: false, outcome: .forcedStopped)
      case .failureRecorded:
        snapshot = RuntimeSnapshot(
          state: .failed, operation: nil, backendActive: false, outcome: .failed)
      default:
        snapshot = RuntimeSnapshot(
          state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped)
      }
      // Bounded recorded history only; no live runtime, permit or ownership intent.
      let record = RuntimeRecord(
        sessionID: UUID(), sequence: 1, recordedAt: 1, snapshot: snapshot)
      try await VMFiles().atomicWrite(RuntimeHistoryCodec.encode(record), at: fixture.runtime)
    }
    return fixture
  }

  private func snapshot(_ fixture: Fixture) throws -> Snapshot {
    let disk = try FileHandle(forReadingFrom: fixture.directory.appendingPathComponent("disk.raw"))
    defer { try? disk.close() }
    let length = try disk.seekToEnd()
    try #require(length >= 512)
    try disk.seek(toOffset: 0)
    let first = try disk.read(upToCount: 512) ?? Data()
    try disk.seek(toOffset: length - 512)
    let last = try disk.read(upToCount: 512) ?? Data()
    return try Snapshot(
      configuration: Data(contentsOf: fixture.registration),
      history: FileManager.default.fileExists(atPath: fixture.runtime.path)
        ? Data(contentsOf: fixture.runtime) : nil,
      identity: Data(contentsOf: fixture.directory.appendingPathComponent("machine-identity.bin")),
      efi: Data(contentsOf: fixture.directory.appendingPathComponent("efi-variables.bin")),
      names: FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(),
      diskLength: length, diskFirst: first, diskLast: last)
  }

  private func session(_ fixtures: [Fixture], inspector: ControlledOpenHistoryInspector) throws
    -> (DesktopSession, OpenHistoryAdviceWindow)
  {
    _ = NSApplication.shared
    let owner = OpenHistoryAdviceWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    let library = VMLibrary(preferences: OpenHistoryAdvicePreferences())
    for fixture in fixtures { library.remember(fixture.configuration, at: fixture.registration) }
    let session = DesktopSession(
      library: library,
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      selectionInspector: inspector)
    session.window = owner
    return (session, owner)
  }

  private func request(
    _ destination: Destination?, fixture: Fixture, session: DesktopSession
  ) throws {
    let entry = try #require(
      session.library.entries.first { $0.configurationURL == fixture.registration })
    session.showLibrary()
    try #require(session.showingLibrary)
    if destination == .network {
      try #require(session.canOpenSavedNetworkSettings(entry))
      session.openSavedNetworkSettings(entry)
    } else {
      session.openSavedVM(entry, settings: destination == .hardware)
    }
    try #require(!session.showingLibrary)
    session.libraryDismissed()
  }

  private func cancel(_ destination: Destination, session: DesktopSession) {
    if destination == .hardware {
      session.editingHardware = false
      session.hardwareSettingsDismissed()
    } else {
      session.editingNetwork = false
      session.networkSettingsDismissed()
    }
  }

  private func wait(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate())
  }

  @Test(arguments: Destination.allCases, Advisory.allCases)
  func librarySettingsRetainTheirDestinationAndVisibleAdviceWithoutChangingFiles(
    destination: Destination, advisory: Advisory
  ) async throws {
    let f = try await fixture(history: advisory.history)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let before = try snapshot(f)
    let inspector = ControlledOpenHistoryInspector()
    defer { inspector.release() }
    let (s, owner) = try session([f], inspector: inspector)
    try request(destination, fixture: f, session: s)
    try await wait { !s.preparing }
    #expect(s.editingHardware == (destination == .hardware))
    #expect(s.editingNetwork == (destination == .network))
    #expect(s.configuration == f.configuration && s.selectedConfigurationURL == f.registration)
    #expect(inspector.histories == [advisory.history] && s.errorMessage == nil)
    let advice = try #require(s.currentOpenHistoryAdvice)
    #expect(advice.history == advisory.history && advice.configurationURL == f.registration)
    #expect(advice.configuration == f.configuration)
    #expect(
      (destination == .hardware ? s.hardwareOpenHistoryAdvice : s.networkOpenHistoryAdvice)?.id
        == advice.id)
    cancel(destination, session: s)
    #expect(s.currentOpenHistoryAdvice?.id == advice.id)
    #expect(s.hardwareOpenHistoryAdvice == nil && s.networkOpenHistoryAdvice == nil)
    // Dismissal is independent of the real operation-error channel.
    s.errorMessage = "Newer independent operation failure"
    s.dismissOpenHistoryAdvice(advice.id)
    #expect(
      s.currentOpenHistoryAdvice == nil && s.errorMessage == "Newer independent operation failure")
    s.libraryDismissed()
    await Task.yield()
    #expect(!s.editingHardware && !s.editingNetwork && !s.preparing)
    #expect(s.errorMessage == "Newer independent operation failure")
    #expect(try snapshot(f) == before)
    #expect(s.state == .stopped && !s.isActive && !s.needsOwnershipRecovery && s.backend == nil)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: Destination.allCases, [RuntimeHistoryStatus.guestStopRecorded, .notRecorded])
  func nonadvisoryHistoryPreservesOrdinarySettingsNavigation(
    destination: Destination, history: RuntimeHistoryStatus
  ) async throws {
    let f = try await fixture(history: history)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let before = try snapshot(f)
    let inspector = ControlledOpenHistoryInspector()
    defer { inspector.release() }
    let (s, owner) = try session([f], inspector: inspector)
    try request(destination, fixture: f, session: s)
    try await wait { !s.preparing }
    #expect(s.editingHardware == (destination == .hardware))
    #expect(s.editingNetwork == (destination == .network))
    #expect(s.currentOpenHistoryAdvice == nil && s.errorMessage == nil)
    #expect(inspector.histories == [history])
    cancel(destination, session: s)
    #expect(try snapshot(f) == before)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: Destination.allCases, [false, true])
  func newerOperationErrorSurvivesInspectionAndStillBlocksEditorDispatch(
    destination: Destination, dismissed: Bool
  ) async throws {
    let f = try await fixture(history: .forcedStopRecorded)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let before = try snapshot(f)
    let inspector = ControlledOpenHistoryInspector()
    inspector.pause = .afterRead
    defer { inspector.release() }
    let (s, owner) = try session([f], inspector: inspector)
    try request(destination, fixture: f, session: s)
    try await wait { inspector.pending != nil }
    s.errorMessage = "Newer independent operation failure"
    if dismissed { s.errorMessage = nil }
    inspector.release()
    try await wait { !s.preparing }
    #expect(s.currentOpenHistoryAdvice?.history == .forcedStopRecorded)
    #expect(s.configuration == f.configuration && s.selectedConfigurationURL == f.registration)
    if dismissed {
      // Dismissal during inspection remains nil and permits the requested destination.
      #expect(s.errorMessage == nil)
      #expect(s.editingHardware == (destination == .hardware))
      #expect(s.editingNetwork == (destination == .network))
      cancel(destination, session: s)
    } else {
      #expect(s.errorMessage == "Newer independent operation failure")
      #expect(!s.editingHardware && !s.editingNetwork)
      s.errorMessage = nil
      s.libraryDismissed()
      await Task.yield()
      #expect(!s.editingHardware && !s.editingNetwork)
    }
    // A fresh explicit row action can open the requested editor; no old action replays.
    try request(destination, fixture: f, session: s)
    try await wait { !s.preparing }
    #expect(destination == .hardware ? s.editingHardware : s.editingNetwork)
    cancel(destination, session: s)
    #expect(try snapshot(f) == before)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["current", "newer", "dismissed"])
  func actualSelectionFailureUsesTheErrorChannelWithoutReplacingANewerFailure(errorState: String)
    async throws
  {
    let f = try await fixture(history: .failureRecorded)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runtimeBytes = try Data(contentsOf: f.runtime)
    let inspector = ControlledOpenHistoryInspector()
    inspector.pause = .beforeRead
    defer { inspector.release() }
    let (s, owner) = try session([f], inspector: inspector)
    try request(.hardware, fixture: f, session: s)
    try await wait { inspector.pending != nil }
    // Remove only this disposable fixture's registration to produce an actual read failure.
    try FileManager.default.removeItem(at: f.registration)
    if errorState != "current" { s.errorMessage = "Newer independent operation failure" }
    if errorState == "dismissed" { s.errorMessage = nil }
    inspector.release()
    try await wait { !s.preparing }
    #expect(inspector.failure != nil)
    if errorState == "dismissed" {
      #expect(s.errorMessage == nil)
    } else if errorState == "newer" {
      #expect(s.errorMessage == "Newer independent operation failure")
    } else {
      #expect(s.errorMessage != nil)
    }
    #expect(s.currentOpenHistoryAdvice == nil && s.configuration == nil)
    #expect(!s.editingHardware && !s.editingNetwork && !s.isActive)
    #expect(try Data(contentsOf: f.runtime) == runtimeBytes)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [RuntimeHistoryStatus.failureRecorded, .guestStopRecorded])
  func anotherLocationWithEqualConfigurationCannotReuseOldAdviceOrItsDismissal(
    history: RuntimeHistoryStatus
  ) async throws {
    let first = try await fixture(history: .forcedStopRecorded)
    defer { try? FileManager.default.removeItem(at: first.root) }
    // Equal declarative identity at another path is navigation metadata only.
    let second = try await fixture(history: history, configuration: first.configuration)
    defer { try? FileManager.default.removeItem(at: second.root) }
    let firstBefore = try snapshot(first)
    let secondBefore = try snapshot(second)
    let inspector = ControlledOpenHistoryInspector()
    defer { inspector.release() }
    let (s, owner) = try session([first, second], inspector: inspector)
    try request(nil, fixture: first, session: s)
    try await wait { !s.preparing }
    let oldAdvice = try #require(s.currentOpenHistoryAdvice)
    try request(nil, fixture: second, session: s)
    try await wait { !s.preparing }
    #expect(
      s.configuration == second.configuration && s.selectedConfigurationURL == second.registration)
    if history == .failureRecorded {
      let current = try #require(s.currentOpenHistoryAdvice)
      #expect(current.id != oldAdvice.id && current.configurationURL == second.registration)
      s.dismissOpenHistoryAdvice(oldAdvice.id)
      #expect(s.currentOpenHistoryAdvice?.id == current.id)
    } else {
      #expect(s.currentOpenHistoryAdvice == nil)
    }
    #expect(s.errorMessage == nil)
    #expect(try snapshot(first) == firstBefore && snapshot(second) == secondBefore)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["nil", "configuration-aba"])
  func clearingOrReplacingTheSelectionCannotResurrectAnOldAdvice(change: String) async throws {
    let f = try await fixture(history: .interruptedOrUnreconciled)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let inspector = ControlledOpenHistoryInspector()
    defer { inspector.release() }
    let (s, owner) = try session([f], inspector: inspector)
    try request(nil, fixture: f, session: s)
    try await wait { !s.preparing }
    let oldAdvice = try #require(s.currentOpenHistoryAdvice)
    if change == "nil" {
      s.configuration = nil
    } else {
      var changed = f.configuration
      changed.name = "Temporary replacement"
      s.configuration = changed
      s.configuration = f.configuration
    }
    #expect(s.currentOpenHistoryAdvice == nil)
    s.errorMessage = "Newer independent operation failure"
    s.dismissOpenHistoryAdvice(oldAdvice.id)
    #expect(s.errorMessage == "Newer independent operation failure")
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: Destination.allCases)
  func staleInspectionCannotAttachAdviceOrAnEditorToAReplacementOwner(destination: Destination)
    async throws
  {
    let f = try await fixture(history: .failureRecorded)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let before = try snapshot(f)
    let inspector = ControlledOpenHistoryInspector()
    inspector.pause = .afterRead
    defer { inspector.release() }
    let (s, owner) = try session([f], inspector: inspector)
    try request(destination, fixture: f, session: s)
    try await wait { inspector.pending != nil }
    let replacement = OpenHistoryAdviceWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
      styleMask: [.titled], backing: .buffered, defer: false)
    replacement.isReleasedWhenClosed = false
    s.window = replacement
    s.window = owner
    inspector.release()
    try await wait { !s.preparing }
    #expect(s.currentOpenHistoryAdvice == nil && s.configuration == nil)
    #expect(!s.editingHardware && !s.editingNetwork && s.errorMessage == nil)
    #expect(try snapshot(f) == before)
    withExtendedLifetime((owner, replacement)) {}
  }
}
