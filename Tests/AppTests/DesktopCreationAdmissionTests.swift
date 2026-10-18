// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Combine
import Foundation
import Qemu
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Existing Core-test pattern: generated identity/EFI files, no VZ or QEMU call.
@MainActor private struct CreationAdmissionFixturePlatform: VMCreationPlatform {
  let backend = BackendID.appleVz
  var failIdentity = false
  func validateHost(for configuration: VMConfiguration) throws {}
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    try Data(configuration.id.uuidString.utf8).write(
      to: directory.appendingPathComponent("machine-identity.bin"), options: .withoutOverwriting)
    if failIdentity { throw NSError(domain: "partial identity fixture", code: 1) }
    try Data("new EFI fixture; not a firmware test".utf8).write(
      to: directory.appendingPathComponent("efi-variables.bin"), options: .withoutOverwriting)
    return CreatedPlatformIdentity(files: ["machine-identity.bin", "efi-variables.bin"])
  }
}

@MainActor private final class CreationAdmissionPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class CreationAdmissionWindow: NSWindow {
  var activationRequests = 0
  var controlledSheet: NSWindow?
  override var attachedSheet: NSWindow? { controlledSheet }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
}

/// Completion is paused only AFTER the ordinary Core registration commit.
@MainActor private final class ControlledDesktopCreation: DesktopVMCreating {
  var linuxCalls = 0
  var windowsCalls = 0
  var holdCompletion = true
  var failAfterCommit = false
  var failIdentity = false
  var holdTypedFailure = false
  var typedFailure: VMError?
  var committed: VMConfiguration?
  var returned = false
  var pending: CheckedContinuation<Void, Never>?
  func createLinux(_ configuration: VMConfiguration, at destination: URL) async throws {
    linuxCalls += 1
    do {
      try await VMCreation().create(
        configuration, at: destination,
        platform: CreationAdmissionFixturePlatform(failIdentity: failIdentity),
        host: HostResources(cpuCount: 8, memoryBytes: 16 << 30))
    } catch {
      typedFailure = error as? VMError
      if holdTypedFailure { await withCheckedContinuation { pending = $0 } }
      throw error
    }
    committed = configuration
    if holdCompletion { await withCheckedContinuation { pending = $0 } }
    returned = true
    if failAfterCommit { throw NSError(domain: "post-commit delivery fixture", code: 1) }
  }
  func createWindows(
    _ configuration: VMConfiguration, at destination: URL,
    resources: ReviewedQemuCreationResources
  ) async throws {
    windowsCalls += 1
    // Tests never mint a successful reviewed catalog or executable permission.
    throw NSError(domain: "Windows authority deliberately unavailable in fixture", code: 1)
  }
  func release() {
    holdCompletion = false
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

@MainActor private final class UnavailableCreationCatalog: DesktopWindowsCreationPreparing {
  var calls = 0
  var hold = true
  var returned = false
  var pending: CheckedContinuation<Void, Never>?
  func resources() async throws -> ReviewedQemuCreationResources {
    calls += 1
    if hold { await withCheckedContinuation { pending = $0 } }
    returned = true
    throw NSError(domain: "catalog unavailable fixture", code: 1)
  }
  func release() {
    hold = false
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

@MainActor private final class ControlledCreationPicker: DesktopCreationLocationPresenting {
  var calls = 0
  var hold = true
  var returned = false
  var selection: URL?
  var pending: CheckedContinuation<Void, Never>?
  func select(folder: Bool, title: String?, on owner: NSWindow?) async -> URL? {
    calls += 1
    if hold { await withCheckedContinuation { pending = $0 } }
    returned = true
    return selection
  }
  func release() {
    hold = false
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

/// Finite source/model schedules with hidden actual DesktopSession objects and
/// disposable ordinary Core files. Native callback reachability remains unproved.
@MainActor @Suite(.serialized) struct DesktopCreationAdmissionTests {
  private struct Fixture {
    let root: URL
    let original: VMConfiguration
    let created: VMConfiguration
    var source: URL { root.appendingPathComponent("Original.macopenvm") }
    var registration: URL { source.appendingPathComponent("configuration.json") }
    var target: URL { root.appendingPathComponent("Created.macopenvm") }
  }

  private func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("creation-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let media = root.appendingPathComponent("generated.iso")
    try Data(repeating: 0x52, count: 1024).write(to: media)
    var original = VMConfiguration(
      name: "Original", guest: .linux, backend: .appleVz, cpuCount: 1,
      memoryBytes: 512 << 20, diskBytes: 1 << 30)
    original.installationMedia = media.path
    var created = original
    created.id = UUID()
    created.name = "Created"
    created.macAddress = "02:52:00:00:00:03"
    let fixture = Fixture(root: root, original: original, created: created)
    try await VMCreation().create(
      original, at: fixture.source, platform: CreationAdmissionFixturePlatform(),
      host: HostResources(cpuCount: 8, memoryBytes: 16 << 30))
    return fixture
  }

  private func window() -> CreationAdmissionWindow {
    let owner = CreationAdmissionWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    return owner
  }

  private func session(
    _ fixture: Fixture, service: ControlledDesktopCreation,
    catalog: UnavailableCreationCatalog = UnavailableCreationCatalog(),
    picker: ControlledCreationPicker = ControlledCreationPicker()
  ) async throws -> (DesktopSession, CreationAdmissionWindow) {
    _ = NSApplication.shared
    let owner = window()
    let session = DesktopSession(
      library: VMLibrary(preferences: CreationAdmissionPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      vmCreation: service, windowsCreationPreparation: catalog,
      creationLocationPresentation: picker)
    session.window = owner
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.original.id)
    return (session, owner)
  }

  private func wait(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate())
  }

  private func verifyCommit(_ fixture: Fixture) throws {
    #expect(
      try ConfigurationCodec.decode(
        Data(contentsOf: fixture.target.appendingPathComponent("configuration.json")))
        == fixture.created)
    #expect(
      try Data(contentsOf: fixture.target.appendingPathComponent("machine-identity.bin"))
        == Data(fixture.created.id.uuidString.utf8))
    let disk = try FileHandle(forReadingFrom: fixture.target.appendingPathComponent("disk.raw"))
    defer { try? disk.close() }
    #expect(try disk.seekToEnd() == fixture.created.diskBytes)
  }

  @Test func retainedCallbacksCannotCancelReportPickOrSubmitIntoAReplacementDraft() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let picker = ControlledCreationPicker()
    defer { picker.release() }
    let (s, owner) = try await session(f, service: service, picker: picker)
    s.showLinuxCreation()
    let nonceN = s.creationDraftNonce
    let oldCancel = { s.cancelCreation(nonce: nonceN) }
    let oldSubmit = { s.createVM(f.created, in: f.target, nonce: nonceN) }
    var delivered = false
    let oldPicker = {
      s.chooseCreationDraftLocation(folder: true, nonce: nonceN) { _ in delivered = true }
    }
    let raw = LinuxCreationDraft(host: HostResources(cpuCount: 8, memoryBytes: 16 << 30))
    raw.cpuCountText = "-1"
    let oldValidation = {
      do { _ = try raw.prepared(host: HostResources(cpuCount: 8, memoryBytes: 16 << 30)) } catch {
        s.reportCreationError("Old raw validation error", nonce: nonceN)
      }
    }
    oldCancel()
    s.showLinuxCreation()
    let nonceM = s.creationDraftNonce
    try #require(nonceM != nonceN && s.creating)
    s.errorMessage = "Newer independent error"
    oldCancel()
    oldValidation()
    oldPicker()
    oldSubmit()
    #expect(s.creating && s.creationDraftNonce == nonceM && !s.preparing)
    #expect(s.errorMessage == "Newer independent error")
    #expect(!delivered && picker.calls == 0 && service.linuxCalls == 0)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    #expect(s.configuration == f.original && s.selectedConfigurationURL == f.registration)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["owner-aba", "configuration-aba", "draft-aba"])
  func queuedCreationRejectsABAThenFreshRequestCommits(change: String) async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    let otherOwner = window()
    s.showLinuxCreation()
    s.createVM(f.created, in: f.target, nonce: s.creationDraftNonce)
    try #require(s.preparing)
    switch change {
    case "owner-aba":
      s.window = otherOwner
      s.window = owner
    case "configuration-aba":
      var changed = f.original
      changed.name = "Temporary"
      s.configuration = changed
      s.configuration = f.original
    default:
      s.creating = false
      s.creating = true
    }
    s.errorMessage = "Newer independent error"
    try await wait { !s.preparing }
    #expect(service.linuxCalls == 0 && s.creating)
    #expect(s.errorMessage == "Newer independent error")
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    service.holdCompletion = false
    s.createVM(f.created, in: f.target, nonce: s.creationDraftNonce)
    try await wait { !s.preparing }
    #expect(service.linuxCalls == 1 && s.configuration == f.created && !s.creating)
    #expect(s.selectedConfigurationURL == f.target.appendingPathComponent("configuration.json"))
    #expect(s.errorMessage == "Newer independent error")
    try verifyCommit(f)
    #expect(owner.activationRequests == 0 && otherOwner.activationRequests == 0)
    withExtendedLifetime((owner, otherOwner)) {}
  }

  @Test(
    arguments: ["owner-aba", "configuration-aba", "configuration-replacement", "draft-aba"],
    [false, true])
  func postCommitStalenessPreservesDirectoryAndNewerUI(change: String, deliveryFailure: Bool)
    async throws
  {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let originalBytes = try Data(contentsOf: f.registration)
    let service = ControlledDesktopCreation()
    service.failAfterCommit = deliveryFailure
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    let otherOwner = window()
    s.showLinuxCreation()
    s.createVM(f.created, in: f.target, nonce: s.creationDraftNonce)
    try await wait { service.pending != nil }
    try verifyCommit(f)
    var currentConfiguration = f.original
    switch change {
    case "owner-aba":
      s.window = otherOwner
      s.window = owner
    case "configuration-aba":
      var replacement = f.original
      replacement.name = "Temporary"
      s.configuration = replacement
      s.configuration = f.original
    case "configuration-replacement":
      currentConfiguration.id = UUID()
      currentConfiguration.name = "Independent selection"
      s.configuration = currentConfiguration
    default:
      s.creating = false
      s.creating = true
    }
    let currentDraft = s.creationDraftNonce
    s.errorMessage = "Newer independent error"
    service.release()
    try await wait { !s.preparing }
    #expect(s.configuration == currentConfiguration && s.selectedConfigurationURL == f.registration)
    #expect(s.creating && s.creationDraftNonce == currentDraft)
    #expect(s.errorMessage == "Newer independent error")
    #expect(
      s.library.entries.contains {
        $0.vmID == f.created.id
          && $0.configurationURL == f.target.appendingPathComponent("configuration.json")
      } == !deliveryFailure)
    try verifyCommit(f)
    #expect(try Data(contentsOf: f.registration) == originalBytes)
    #expect(owner.activationRequests == 0 && otherOwner.activationRequests == 0)
    withExtendedLifetime((owner, otherOwner)) {}
  }

  @Test func currentSuccessSelectsCommitAndPreservesNewerError() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    s.showLinuxCreation()
    s.createVM(f.created, in: f.target, nonce: s.creationDraftNonce)
    try await wait { service.pending != nil }
    s.errorMessage = "Newer independent error"
    service.release()
    try await wait { !s.preparing }
    #expect(s.configuration == f.created && !s.creating)
    #expect(s.errorMessage == "Newer independent error")
    #expect(s.library.entries.contains { $0.vmID == f.created.id })
    try verifyCommit(f)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: [false, true])
  func uncertainDeliveryKeepsActualCommitAndDoesNotReviveDismissedError(errorWasReplaced: Bool)
    async throws
  {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    service.failAfterCommit = true
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    s.showLinuxCreation()
    s.createVM(f.created, in: f.target, nonce: s.creationDraftNonce)
    try await wait { service.pending != nil }
    if errorWasReplaced {
      s.errorMessage = "Newer error"
      s.errorMessage = nil
    }
    service.release()
    try await wait { !s.preparing }
    #expect(s.configuration == f.original && s.creating)
    #expect((s.errorMessage == nil) == errorWasReplaced)
    if !errorWasReplaced { #expect(s.errorMessage?.contains("could not be confirmed") == true) }
    #expect(!s.library.entries.contains { $0.vmID == f.created.id })
    try verifyCommit(f)
    withExtendedLifetime(owner) {}
  }

  @Test func realPartialCoreFailureRetainsUnregisteredFolder() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    service.failIdentity = true
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    s.showLinuxCreation()
    s.createVM(f.created, in: f.target, nonce: s.creationDraftNonce)
    try await wait { !s.preparing }
    #expect(service.linuxCalls == 1 && service.committed == nil && s.creating)
    #expect(
      FileManager.default.fileExists(atPath: f.target.appendingPathComponent("disk.raw").path))
    #expect(
      FileManager.default.fileExists(
        atPath: f.target.appendingPathComponent("machine-identity.bin").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: f.target.appendingPathComponent("configuration.json").path))
    #expect(!s.library.entries.contains { $0.vmID == f.created.id })
    #expect(s.errorMessage?.contains("could not be confirmed") == true)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["guest", "backend", "architecture", "boot"])
  func linuxAdmissionRejectsOtherProfilesBeforeCore(fault: String) async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    s.showLinuxCreation()
    var invalid = f.created
    switch fault {
    case "guest": invalid.guest = .windows11
    case "backend": invalid.backend = .qemuHVF
    case "architecture": invalid.architecture = .x8664
    default: invalid.boot = .linuxKernel
    }
    s.createVM(invalid, in: f.target, nonce: s.creationDraftNonce)
    #expect(service.linuxCalls == 0 && !s.preparing && s.creating)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    withExtendedLifetime(owner) {}
  }

  @Test(
    arguments: ["queued", "reply"], ["owner-aba", "configuration-aba", "draft-aba", "error-only"])
  func unavailableCatalogCannotPublishAcrossContextChanges(phase: String, change: String)
    async throws
  {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let catalog = UnavailableCreationCatalog()
    defer { catalog.release() }
    let (s, owner) = try await session(f, service: service, catalog: catalog)
    let otherOwner = window()
    s.showWindowsCreation()
    try #require(s.preparing)
    if phase == "reply" { try await wait { catalog.pending != nil } }
    switch change {
    case "owner-aba":
      s.window = otherOwner
      s.window = owner
    case "configuration-aba":
      var changed = f.original
      changed.name = "Temporary"
      s.configuration = changed
      s.configuration = f.original
    case "draft-aba":
      s.creating = true
      s.creating = false
    default: break
    }
    s.errorMessage = "Newer independent error"
    catalog.release()
    try await wait { !s.preparing }
    #expect(catalog.calls == (phase == "queued" && change != "error-only" ? 0 : 1))
    #expect(!s.creating && s.windowsCreationResources == nil)
    #expect(s.configuration == f.original && s.selectedConfigurationURL == f.registration)
    #expect(s.errorMessage == "Newer independent error" && service.linuxCalls == 0)
    withExtendedLifetime((owner, otherOwner)) {}
  }

  @Test func currentUnavailableCatalogReportsFailureWithoutResourceAuthority() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let catalog = UnavailableCreationCatalog()
    catalog.hold = false
    let (s, owner) = try await session(f, service: service, catalog: catalog)
    s.showWindowsCreation()
    try await wait { !s.preparing }
    #expect(catalog.calls == 1 && s.windowsCreationResources == nil && !s.creating)
    #expect(s.errorMessage?.contains("could not be confirmed") == true)
    #expect(service.windowsCalls == 0 && service.linuxCalls == 0)
    withExtendedLifetime(owner) {}
  }

  @Test func pickerWaitsForDetachmentAndRejectsStaleDelivery() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let picker = ControlledCreationPicker()
    picker.selection = f.root
    defer { picker.release() }
    let (s, owner) = try await session(f, service: service, picker: picker)
    s.showLinuxCreation()
    var delivered = false
    s.chooseCreationDraftLocation(folder: true, nonce: s.creationDraftNonce) { _ in delivered = true
    }
    try await wait { picker.pending != nil }
    owner.controlledSheet = window()
    picker.release()
    try await wait { picker.returned }
    #expect(s.preparing && !delivered)
    s.creating = false
    s.creating = true
    let currentDraft = s.creationDraftNonce
    s.errorMessage = "Newer independent error"
    owner.controlledSheet = nil
    try await wait { !s.preparing }
    #expect(!delivered && s.creating && s.creationDraftNonce == currentDraft)
    #expect(s.errorMessage == "Newer independent error" && service.linuxCalls == 0)
    #expect(owner.activationRequests == 0)
    withExtendedLifetime(owner) {}
  }

  @Test func pickerDeliversOnlyToCurrentDraftAndOwnFlagBlocksOtherRequests() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let catalog = UnavailableCreationCatalog()
    defer { catalog.release() }
    let picker = ControlledCreationPicker()
    picker.selection = f.root
    defer { picker.release() }
    let (s, owner) = try await session(f, service: service, catalog: catalog, picker: picker)
    s.showLinuxCreation()
    let nonce = s.creationDraftNonce
    var delivered: URL?
    s.chooseCreationDraftLocation(folder: true, nonce: nonce) { delivered = $0 }
    s.cancelCreation(nonce: nonce)
    s.showWindowsCreation()
    s.createVM(f.created, in: f.target, nonce: nonce)
    s.chooseCreationDraftLocation(folder: true, nonce: nonce) { _ in }
    try await wait { picker.pending != nil }
    #expect(s.creating && picker.calls == 1 && catalog.calls == 0 && service.linuxCalls == 0)
    picker.release()
    try await wait { !s.preparing }
    #expect(delivered == f.root && s.creating && s.creationDraftNonce == nonce)
    withExtendedLifetime(owner) {}
  }

  @Test func staleDeferCannotClearAnUnrelatedPreparation() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let picker = ControlledCreationPicker()
    defer { picker.release() }
    let (s, owner) = try await session(f, service: service, picker: picker)
    s.showLinuxCreation()
    var delivered = false
    s.chooseCreationDraftLocation(folder: true, nonce: s.creationDraftNonce) { _ in delivered = true
    }
    try await wait { picker.pending != nil }
    s.preparing = false
    s.preparing = true
    picker.release()
    try await wait { picker.returned }
    // The continuation and controller completion execute on this actor before this next turn.
    await Task.yield()
    #expect(s.preparing && !delivered)
    s.preparing = false
    withExtendedLifetime(owner) {}
  }
  @Test func synchronousPreparingPublicationCannotAdmitAnotherRequest() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let picker = ControlledCreationPicker()
    defer { picker.release() }
    let (s, owner) = try await session(f, service: service, picker: picker)
    let otherOwner = window()
    s.showLinuxCreation()
    let nonce = s.creationDraftNonce
    var reentered = false
    let observation = s.$preparing.dropFirst().sink { value in
      guard value, !reentered else { return }
      reentered = true
      s.cancelCreation(nonce: nonce)
      s.createVM(f.created, in: f.target, nonce: nonce)
      s.chooseCreationDraftLocation(folder: true, nonce: nonce) { _ in }
      s.window = otherOwner
      s.window = owner
    }
    defer { observation.cancel() }
    s.createVM(f.created, in: f.target, nonce: nonce)
    #expect(reentered && !s.preparing && s.creating)
    #expect(service.linuxCalls == 0 && picker.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    withExtendedLifetime((owner, otherOwner)) {}
  }
  @Test(arguments: [
    "runtime-state", "hardware", "disk", "network", "graphics", "review", "library",
  ])
  func queuedWriterRejectsUnrelatedCustody(workflow: String) async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    s.showLinuxCreation()
    s.createVM(f.created, in: f.target, nonce: s.creationDraftNonce)
    switch workflow {
    case "runtime-state": s.state = .running
    case "hardware": s.editingHardware = true
    case "disk": s.editingDiskCapacity = true
    case "network": s.editingNetwork = true
    case "graphics": s.editingGraphics = true
    case "review": s.reviewingVM = true
    default: s.showingLibrary = true
    }
    try await wait { !s.preparing }
    #expect(service.linuxCalls == 0 && s.creating)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    #expect(s.configuration == f.original && s.selectedConfigurationURL == f.registration)
    withExtendedLifetime(owner) {}
  }
  @Test(arguments: ["owner-aba", "configuration-aba"], ["cancel", "error", "picker", "submit"])
  func retainedPreActionCallbacksRejectChangedDraftOrigin(change: String, action: String)
    async throws
  {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    service.holdCompletion = false
    defer { service.release() }
    let picker = ControlledCreationPicker()
    defer { picker.release() }
    let (s, owner) = try await session(f, service: service, picker: picker)
    let otherOwner = window()
    s.showLinuxCreation()
    let nonceN = s.creationDraftNonce
    let oldCancel = { s.cancelCreation(nonce: nonceN) }
    let oldSubmit = { s.createVM(f.created, in: f.target, nonce: nonceN) }
    var oldSelectionDelivered = false
    let oldPicker = {
      s.chooseCreationDraftLocation(folder: true, nonce: nonceN) { _ in oldSelectionDelivered = true
      }
    }
    let raw = LinuxCreationDraft(host: HostResources(cpuCount: 8, memoryBytes: 16 << 30))
    raw.cpuCountText = "-1"
    let oldValidation = {
      do { _ = try raw.prepared(host: HostResources(cpuCount: 8, memoryBytes: 16 << 30)) } catch {
        s.reportCreationError("Old raw validation error", nonce: nonceN)
      }
    }
    // No async request exists yet: the retained draft origin itself must expire.
    if change == "owner-aba" {
      s.window = otherOwner
      s.window = owner
    } else {
      var replacement = f.original
      replacement.name = "Temporary selection"
      s.configuration = replacement
      s.configuration = f.original
    }
    let currentNonce = s.creationDraftNonce
    try #require(currentNonce != nonceN && s.creating && !s.preparing)
    switch action {
    case "cancel": oldCancel()
    case "error": oldValidation()
    case "picker": oldPicker()
    default: oldSubmit()
    }
    #expect(s.creating && s.creationDraftNonce == currentNonce && !s.preparing)
    #expect(s.errorMessage == nil && !oldSelectionDelivered)
    #expect(service.linuxCalls == 0 && picker.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    #expect(s.configuration == f.original && s.selectedConfigurationURL == f.registration)
    // The visible replacement draft's fresh nonce still reaches the real Core writer.
    s.errorMessage = "Newer independent error"
    s.createVM(f.created, in: f.target, nonce: currentNonce)
    try await wait { !s.preparing }
    #expect(service.linuxCalls == 1 && s.configuration == f.created && !s.creating)
    #expect(s.errorMessage == "Newer independent error")
    try verifyCommit(f)
    #expect(owner.activationRequests == 0 && otherOwner.activationRequests == 0)
    withExtendedLifetime((owner, otherOwner)) {}
  }

  @Test(arguments: [
    "current", "newer-error", "dismissed-error", "owner-aba", "configuration-aba", "draft-aba",
  ])
  func typedRealCoreFailureKeepsSafeActionableFeedbackOnlyForCurrentRequest(change: String)
    async throws
  {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = ControlledDesktopCreation()
    service.holdTypedFailure = true
    defer { service.release() }
    let (s, owner) = try await session(f, service: service)
    let otherOwner = window()
    s.showLinuxCreation()
    var invalid = f.created
    // Controller profile is valid; actual strict Core admission rejects 7 CPUs
    // on the service's configured 8-CPU host, before creating the destination.
    invalid.cpuCount = 7
    s.createVM(invalid, in: f.target, nonce: s.creationDraftNonce)
    try await wait { service.pending != nil }
    let failure = try #require(service.typedFailure)
    let description = try #require(failure.errorDescription)
    #expect(failure.code == .invalidConfiguration && service.committed == nil)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    switch change {
    case "newer-error": s.errorMessage = "Newer independent error"
    case "dismissed-error":
      s.errorMessage = "Newer error"
      s.errorMessage = nil
    case "owner-aba":
      s.window = otherOwner
      s.window = owner
    case "configuration-aba":
      var replacement = f.original
      replacement.name = "Temporary"
      s.configuration = replacement
      s.configuration = f.original
    case "draft-aba":
      s.creating = false
      s.creating = true
    default: break
    }
    let currentDraft = s.creationDraftNonce
    service.release()
    try await wait { !s.preparing }
    if change == "current" {
      #expect(s.errorMessage?.contains(description) == true)
      #expect(s.errorMessage?.contains("could not be confirmed") == false)
    } else if change == "newer-error" {
      #expect(s.errorMessage == "Newer independent error")
    } else {
      #expect(s.errorMessage == nil)
    }
    #expect(s.configuration == f.original && s.selectedConfigurationURL == f.registration)
    #expect(s.creating && s.creationDraftNonce == currentDraft)
    #expect(service.linuxCalls == 1 && !s.library.entries.contains { $0.vmID == invalid.id })
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    withExtendedLifetime((owner, otherOwner)) {}
  }
}
