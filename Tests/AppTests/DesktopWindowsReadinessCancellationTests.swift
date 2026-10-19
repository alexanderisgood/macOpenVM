// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Combine
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class ReadinessCancellationPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class ReadinessCancellationWindow: NSWindow {
  var activationRequests = 0
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
}

/// The only injected output is a reason for unavailability. This fixture cannot
/// construct .ready/.checking, a reviewed worker or Windows creation resources.
@MainActor private final class ControlledUnavailableReadiness: DesktopWindowsReadinessInspecting {
  var hold = false
  var requests: [WindowsLaunchReadinessRequest] = []
  var pending: [UUID: CheckedContinuation<WindowsLaunchReadiness.Reason, Never>] = [:]
  var returned: Set<UUID> = []

  func inspect(_ request: WindowsLaunchReadinessRequest) async -> DesktopWindowsReadinessInspection
  {
    requests.append(request)
    let reason: WindowsLaunchReadiness.Reason
    if hold {
      reason = await withCheckedContinuation { pending[request.generation] = $0 }
    } else {
      reason = .reviewedRuntimeUnavailable
    }
    returned.insert(request.generation)
    return .unavailable(reason)
  }

  func release(_ generation: UUID, reason: WindowsLaunchReadiness.Reason) {
    let continuation = pending.removeValue(forKey: generation)
    continuation?.resume(returning: reason)
  }

  func releaseAll() {
    hold = false
    let continuations = Array(pending.values)
    pending.removeAll()
    for continuation in continuations { continuation.resume(returning: .unsupportedHost) }
  }
}

/// Uses ordinary saved-file selection and Check Again on actual DesktopSession.
/// These declarative Windows metadata fixtures contain no disk/platform/executable
/// authority. Successful Windows creation -> readiness remains unqualified.
@MainActor @Suite(.serialized) struct DesktopWindowsReadinessCancellationTests {
  private struct Fixture {
    let root: URL
    let configuration: VMConfiguration
    let otherConfiguration: VMConfiguration
    var registration: URL {
      root.appendingPathComponent("First.macopenvm/configuration.json")
    }
    var otherRegistration: URL {
      root.appendingPathComponent("Second.macopenvm/configuration.json")
    }
  }

  private func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("readiness-cancellation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "First", guest: .windows11, backend: .qemuHVF, cpuCount: 2,
      memoryBytes: 4 << 30, diskBytes: 64 << 30)
    var other = configuration
    other.id = UUID()
    other.name = "Second"
    other.macAddress = "02:52:00:00:00:04"
    let fixture = Fixture(root: root, configuration: configuration, otherConfiguration: other)
    for (url, configuration) in [
      (fixture.registration, configuration), (fixture.otherRegistration, other),
    ] {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try await VMFiles().atomicWrite(ConfigurationCodec.encode(configuration), at: url)
    }
    return fixture
  }

  private func window() -> ReadinessCancellationWindow {
    let owner = ReadinessCancellationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    return owner
  }

  private func session(_ fixture: Fixture, inspector: ControlledUnavailableReadiness) async throws
    -> (DesktopSession, ReadinessCancellationWindow)
  {
    _ = NSApplication.shared
    let owner = window()
    let session = DesktopSession(
      library: VMLibrary(preferences: ReadinessCancellationPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      windowsReadinessInspection: inspector)
    session.window = owner
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.configuration.id)
    try #require(inspector.requests.count == 1)
    #expect(session.windowsLaunchReadiness == .unavailable(.reviewedRuntimeUnavailable))
    #expect(!session.windowsLaunchReady && !session.canStartSelected && !session.isActive)
    return (session, owner)
  }

  private func wait(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate())
  }

  private func writeIntent(
    _ intent: RuntimeIntentInspectionStatus, in fixture: Fixture
  ) async throws -> Data {
    let bytes: Data
    if intent == .invalid {
      bytes = Data("{invalid session record".utf8)
    } else {
      let record: [String: Any] = [
        "schemaVersion": 1,
        "vmID": (intent == .identityMismatch ? UUID() : fixture.configuration.id).uuidString,
        "sessionID": UUID().uuidString,
        "state": intent == .unsettled ? "unsettled" : "settled",
      ]
      bytes = try JSONSerialization.data(withJSONObject: record)
    }
    try await VMFiles().atomicWrite(
      bytes,
      at: fixture.registration.deletingLastPathComponent().appendingPathComponent(
        RuntimeIntent.filename))
    return bytes
  }

  @Test(arguments: [RuntimeIntentInspectionStatus.unsettled, .invalid, .identityMismatch])
  func interruptedSelectionCannotUseCheckAgainAsRecoveryOrBlockAnotherLocation(
    intent: RuntimeIntentInspectionStatus
  ) async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let intentBytes = try await writeIntent(intent, in: f)
    // Equal declarative identity at another location is navigation metadata,
    // not a second runtime or reconstructed ownership authority.
    try await VMFiles().atomicWrite(
      ConfigurationCodec.encode(f.configuration), at: f.otherRegistration)
    let firstRegistration = try Data(contentsOf: f.registration)
    let otherRegistration = try Data(contentsOf: f.otherRegistration)
    let inspector = ControlledUnavailableReadiness()
    defer { inspector.releaseAll() }
    let (s, owner) = try await session(f, inspector: inspector)
    let blocker = try #require(s.currentStartupBlocker)
    #expect(blocker.intent == intent)
    #expect(blocker.matches(configuration: f.configuration, at: f.registration))
    #expect(!blocker.matches(configuration: f.configuration, at: f.otherRegistration))
    var changed = f.configuration
    changed.name = "Changed selection"
    #expect(!blocker.matches(configuration: changed, at: f.registration))
    // A read-only classification must not fabricate retained runtime custody.
    #expect(!s.needsOwnershipRecovery && !s.isActive && !s.isBusy)
    #expect(!s.canStartSelected && !s.canRequestStart && !s.canRecheckWindowsReadiness)
    s.recheckWindowsReadiness()
    #expect(inspector.requests.count == 1 && !s.preparing)
    #expect(s.currentStartupBlocker == blocker)

    try await s.qualificationSelectVM(at: f.otherRegistration, expectedID: f.configuration.id)
    #expect(s.configuration == f.configuration && s.selectedConfigurationURL == f.otherRegistration)
    #expect(s.currentStartupBlocker == nil && s.canRecheckWindowsReadiness)
    s.recheckWindowsReadiness()
    try await wait { !s.preparing }
    #expect(inspector.requests.count == 3)
    #expect(inspector.requests.last?.configurationURL == f.otherRegistration)
    #expect(s.currentStartupBlocker == nil && !s.needsOwnershipRecovery && !s.isActive)
    #expect(try Data(contentsOf: f.registration) == firstRegistration)
    #expect(try Data(contentsOf: f.otherRegistration) == otherRegistration)
    #expect(
      try Data(
        contentsOf: f.registration.deletingLastPathComponent().appendingPathComponent(
          RuntimeIntent.filename)) == intentBytes)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["clear", "configuration-aba"])
  func changingTheConfigurationCannotResurrectAStaleStartupBlocker(change: String) async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let intentBytes = try await writeIntent(.unsettled, in: f)
    let inspector = ControlledUnavailableReadiness()
    defer { inspector.releaseAll() }
    let (s, owner) = try await session(f, inspector: inspector)
    try #require(s.currentStartupBlocker != nil)
    if change == "clear" {
      s.configuration = nil
    } else {
      var replacement = f.configuration
      replacement.name = "Temporary selection"
      s.configuration = replacement
      s.configuration = f.configuration
    }
    #expect(s.currentStartupBlocker == nil)
    #expect(!s.needsOwnershipRecovery && !s.isActive)
    #expect(
      try Data(
        contentsOf: f.registration.deletingLastPathComponent().appendingPathComponent(
          RuntimeIntent.filename)) == intentBytes)
    withExtendedLifetime(owner) {}
  }

  @Test func interruptedLinuxSelectionHasAnIndependentStartGate() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var linux = VMConfiguration(
      name: "Linux selection", guest: .linux, backend: .appleVz,
      cpuCount: 1, memoryBytes: 512 << 20, diskBytes: 1 << 30)
    linux.id = f.configuration.id
    for registration in [f.registration, f.otherRegistration] {
      try await VMFiles().atomicWrite(ConfigurationCodec.encode(linux), at: registration)
    }
    let intentBytes = try await writeIntent(.unsettled, in: f)
    let inspector = ControlledUnavailableReadiness()
    _ = NSApplication.shared
    let s = DesktopSession(
      library: VMLibrary(preferences: ReadinessCancellationPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      windowsReadinessInspection: inspector)
    let owner = window()
    s.window = owner
    try await s.qualificationSelectVM(at: f.registration, expectedID: linux.id)
    #expect(s.currentStartupBlocker?.intent == .unsettled && !s.canStartSelected)
    try await s.qualificationSelectVM(at: f.otherRegistration, expectedID: linux.id)
    #expect(s.currentStartupBlocker == nil)
    #expect(s.canStartSelected == SavedVMStartEligibility.permits(linux))
    #expect(inspector.requests.isEmpty && !s.needsOwnershipRecovery && !s.isActive)
    #expect(
      try Data(
        contentsOf: f.registration.deletingLastPathComponent().appendingPathComponent(
          RuntimeIntent.filename)) == intentBytes)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["owner-aba", "preparation-aba"])
  func cancelledOwnedCheckBecomesRetryableAndFreshCheckRemainsFailClosed(change: String)
    async throws
  {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let inspector = ControlledUnavailableReadiness()
    defer { inspector.releaseAll() }
    let (s, owner) = try await session(f, inspector: inspector)
    let otherOwner = window()
    inspector.hold = true
    s.recheckWindowsReadiness()
    try await wait { inspector.pending.count == 1 }
    let generation = try #require(inspector.requests.last?.generation)
    try #require(s.windowsLaunchReadiness == .checking && s.preparing)
    if change == "owner-aba" {
      s.window = otherOwner
      s.window = owner
    } else {
      // Public model scheduling replaces the old operation's preparing epoch;
      // its defer must not clear this replacement flag.
      s.preparing = false
      s.preparing = true
    }
    s.errorMessage = "Newer independent error"
    inspector.release(generation, reason: .unsupportedHost)
    try await wait { inspector.returned.contains(generation) }
    await Task.yield()
    #expect(s.windowsLaunchReadiness == .notChecked)
    #expect(s.configuration == f.configuration && s.selectedConfigurationURL == f.registration)
    #expect(s.errorMessage == "Newer independent error")
    #expect(s.preparing == (change == "preparation-aba"))
    if change == "preparation-aba" { s.preparing = false }
    // Check Again's view gate is now open: no stranded checking spinner remains.
    #expect(s.canRecheckWindowsReadiness && !s.windowsLaunchReadiness.isChecking)
    inspector.hold = false
    s.recheckWindowsReadiness()
    try await wait { !s.preparing }
    #expect(inspector.requests.count == 3)
    #expect(s.windowsLaunchReadiness == .unavailable(.reviewedRuntimeUnavailable))
    #expect(!s.windowsLaunchReady && !s.canStartSelected && !s.isActive)
    #expect(s.errorMessage == "Newer independent error")
    #expect(owner.activationRequests == 0 && otherOwner.activationRequests == 0)
    withExtendedLifetime((owner, otherOwner)) {}
  }

  @Test func olderCancellationCannotClearASupersedingGenerationOnTheSameSelection() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let inspector = ControlledUnavailableReadiness()
    defer { inspector.releaseAll() }
    let (s, owner) = try await session(f, inspector: inspector)
    inspector.hold = true
    s.recheckWindowsReadiness()
    try await wait { inspector.pending.count == 1 }
    let generation1 = try #require(inspector.requests.last?.generation)
    // Controlled public model scheduling admits a replacement operation. It is
    // not a claim that the disabled native Check Again button can do this.
    s.preparing = false
    s.recheckWindowsReadiness()
    try await wait { inspector.pending.count == 2 }
    let generation2 = try #require(inspector.requests.last?.generation)
    try #require(generation1 != generation2 && s.preparing)
    s.errorMessage = "Newer independent error"
    inspector.release(generation1, reason: .unsupportedHost)
    try await wait { inspector.returned.contains(generation1) }
    await Task.yield()
    #expect(s.windowsLaunchReadiness == .checking && s.preparing)
    #expect(inspector.pending[generation2] != nil)
    #expect(s.errorMessage == "Newer independent error")
    inspector.release(generation2, reason: .bundledWorkerUnavailable)
    try await wait { !s.preparing }
    #expect(s.windowsLaunchReadiness == .unavailable(.bundledWorkerUnavailable))
    #expect(s.configuration == f.configuration && s.selectedConfigurationURL == f.registration)
    #expect(!s.windowsLaunchReady && !s.canStartSelected && !s.isActive)
    #expect(s.errorMessage == "Newer independent error")
    withExtendedLifetime(owner) {}
  }

  @Test func olderCancellationCannotClearANewSelectionOrItsPendingCheck() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let inspector = ControlledUnavailableReadiness()
    defer { inspector.releaseAll() }
    let (s, owner) = try await session(f, inspector: inspector)
    inspector.hold = true
    s.recheckWindowsReadiness()
    try await wait { inspector.pending.count == 1 }
    let generation1 = try #require(inspector.requests.last?.generation)
    s.preparing = false
    let selection = Task { @MainActor in
      try await s.qualificationSelectVM(
        at: f.otherRegistration, expectedID: f.otherConfiguration.id)
    }
    defer { selection.cancel() }
    try await wait {
      inspector.pending.count == 2 && s.selectedConfigurationURL == f.otherRegistration
    }
    let generation2 = try #require(inspector.requests.last?.generation)
    try #require(generation1 != generation2)
    s.errorMessage = "Newer independent error"
    inspector.release(generation1, reason: .unsupportedHost)
    try await wait { inspector.returned.contains(generation1) }
    await Task.yield()
    #expect(
      s.configuration == f.otherConfiguration && s.selectedConfigurationURL == f.otherRegistration)
    #expect(s.windowsLaunchReadiness == .checking && s.preparing)
    #expect(inspector.pending[generation2] != nil && s.errorMessage == "Newer independent error")
    inspector.release(generation2, reason: .bundledWorkerUnavailable)
    try await selection.value
    #expect(s.windowsLaunchReadiness == .unavailable(.bundledWorkerUnavailable))
    #expect(
      s.configuration == f.otherConfiguration && s.selectedConfigurationURL == f.otherRegistration)
    #expect(!s.windowsLaunchReady && !s.canStartSelected && !s.isActive)
    #expect(s.errorMessage == "Newer independent error" && owner.activationRequests == 0)
    withExtendedLifetime(owner) {}
  }

  @Test func staleCheckDoesNotClearCheckingWhileRuntimeStateIsNotIdle() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let inspector = ControlledUnavailableReadiness()
    defer { inspector.releaseAll() }
    let (s, owner) = try await session(f, inspector: inspector)
    inspector.hold = true
    s.recheckWindowsReadiness()
    try await wait { inspector.pending.count == 1 }
    let generation = try #require(inspector.requests.last?.generation)
    // Public state exercises the idle predicate only; no runtime is fabricated.
    s.state = .running
    inspector.release(generation, reason: .unsupportedHost)
    try await wait { !s.preparing }
    #expect(s.windowsLaunchReadiness == .checking && s.state == .running)
    #expect(!s.windowsLaunchReady && !s.canStartSelected && !s.canRecheckWindowsReadiness)
    s.state = .stopped
    withExtendedLifetime(owner) {}
  }
  @Test func retryPreparingPublicationRejectsSynchronousWorkflowReentry() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let inspector = ControlledUnavailableReadiness()
    defer { inspector.releaseAll() }
    let (s, owner) = try await session(f, inspector: inspector)
    let initialRequests = inspector.requests.count
    let originalNonce = s.creationDraftNonce
    inspector.hold = true
    var reentries = 0
    let observation = s.$preparing.dropFirst().sink { value in
      guard value, reentries == 0 else { return }
      reentries += 1
      // Combine publishes before the preparing getter stores true. Both nested
      // ordinary actions must see the nonpublished synchronous busy claim.
      s.showLinuxCreation()
      s.recheckWindowsReadiness()
    }
    defer { observation.cancel() }
    s.recheckWindowsReadiness()
    try #require(reentries == 1)
    try #require(!s.creating && s.creationDraftNonce == originalNonce && s.preparing)
    try await wait { inspector.pending.count == 1 }
    #expect(inspector.requests.count == initialRequests + 1)
    let generation = try #require(inspector.requests.last?.generation)
    #expect(s.windowsLaunchReadiness == .checking && !s.creating)
    inspector.release(generation, reason: .bundledWorkerUnavailable)
    try await wait { !s.preparing }
    #expect(inspector.requests.count == initialRequests + 1 && reentries == 1)
    #expect(s.windowsLaunchReadiness == .unavailable(.bundledWorkerUnavailable))
    #expect(!s.windowsLaunchReady && !s.canStartSelected && !s.isActive)
    #expect(!s.creating && s.creationDraftNonce == originalNonce)
    #expect(s.configuration == f.configuration && s.selectedConfigurationURL == f.registration)
    // The synchronous claim has ended, so a fresh ordinary action still admits.
    s.showLinuxCreation()
    #expect(s.creating && s.creationDraftNonce != originalNonce && !s.preparing)
    #expect(owner.activationRequests == 0)
    withExtendedLifetime(owner) {}
  }
}
