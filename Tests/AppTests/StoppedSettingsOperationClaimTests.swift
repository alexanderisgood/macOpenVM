// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Combine
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

enum SettingsClaimKind: String, CaseIterable, Sendable {
  case hardware, network, disk
}

@MainActor private final class SettingsClaimPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class SettingsClaimWindow: NSWindow {
  var activationRequests = 0
  override var attachedSheet: NSWindow? { nil }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
}

/// Each controller invocation has its own pre-Core barrier. A success always
/// comes from the ordinary Core transaction; no invented replacement is returned.
@MainActor
private final class SettingsClaimService:
  DesktopHardwareSettingsUpdating, DesktopNetworkSettingsUpdating, DesktopDiskGrowing
{
  struct Call {
    let kind: SettingsClaimKind
    let directory: URL
    let original: VMConfiguration
    let desired: VMConfiguration
  }
  private(set) var calls: [Call] = []
  private(set) var coreCalls = 0
  private(set) var returned = 0
  private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
  var failAfterCommit = false
  var pendingIDs: [Int] { pending.keys.sorted() }
  var pendingCount: Int { pending.count }

  private func held(
    _ call: Call, write: () async throws -> VMConfiguration
  ) async throws -> VMConfiguration {
    let id = calls.count
    calls.append(call)
    defer { returned += 1 }
    try await withCheckedThrowingContinuation { pending[id] = $0 }
    coreCalls += 1
    let committed = try await write()
    if failAfterCommit {
      throw NSError(domain: "private post-commit delivery fixture", code: 1)
    }
    return committed
  }

  func update(
    in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64
  ) async throws -> VMConfiguration {
    var desired = expected
    desired.cpuCount = cpuCount
    desired.memoryBytes = memoryBytes
    return try await held(
      Call(kind: .hardware, directory: directory, original: expected, desired: desired)
    ) {
      try await NativeDesktopHardwareSettings().update(
        in: directory, expected: expected, cpuCount: cpuCount, memoryBytes: memoryBytes)
    }
  }

  func update(
    in directory: URL, expected: VMConfiguration, mode: NetworkMode,
    sharedPermission: SharedNetworkConfigurationPermission?
  ) async throws -> VMConfiguration {
    var desired = expected
    desired.network = mode
    return try await held(
      Call(kind: .network, directory: directory, original: expected, desired: desired)
    ) {
      try await NativeDesktopNetworkSettings().update(
        in: directory, expected: expected, mode: mode, sharedPermission: sharedPermission)
    }
  }

  func grow(
    in directory: URL, expected: VMConfiguration, targetBytes: UInt64
  ) async throws -> VMConfiguration {
    var desired = expected
    desired.diskBytes = targetBytes
    return try await held(
      Call(kind: .disk, directory: directory, original: expected, desired: desired)
    ) {
      try await NativeDesktopDiskGrowth().grow(
        in: directory, expected: expected, targetBytes: targetBytes)
    }
  }

  func release(_ id: Int, allowCore: Bool) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    if allowCore {
      continuation.resume()
    } else {
      continuation.resume(throwing: NSError(domain: "private pre-Core fixture failure", code: 1))
    }
  }

  func releaseAll(allowCore: Bool) {
    for id in pendingIDs { release(id, allowCore: allowCore) }
  }
}

@MainActor @Suite(.serialized) struct StoppedSettingsOperationClaimTests {
  private struct Fixture {
    let root: URL
    let original: VMConfiguration
    let originalBytes: Data
    let session: DesktopSession
    let owner: SettingsClaimWindow
    var registration: URL { root.appendingPathComponent("configuration.json") }
  }

  private func fixture(service: SettingsClaimService) async throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("settings-claim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let original = VMConfiguration(
      name: "Stopped operation claim", guest: .linux, backend: .appleVz,
      cpuCount: 1, memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let bytes = try ConfigurationCodec.encode(original)
    let files = VMFiles()
    try await files.atomicWrite(bytes, at: root.appendingPathComponent("configuration.json"))
    try await files.createSparseDisk(at: root.appendingPathComponent("disk.raw"), bytes: 1 << 30)
    let owner = SettingsClaimWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    let session = DesktopSession(
      library: VMLibrary(preferences: SettingsClaimPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      diskGrowth: service, hardwareSettings: service, networkSettings: service)
    session.window = owner
    try await session.qualificationSelectVM(
      at: root.appendingPathComponent("configuration.json"), expectedID: original.id)
    #expect(session.configuration == original && !session.preparing)
    return Fixture(
      root: root, original: original, originalBytes: bytes, session: session, owner: owner)
  }

  private func wait(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
  }

  private func show(_ kind: SettingsClaimKind, session: DesktopSession) {
    switch kind {
    case .hardware: session.showHardwareSettings()
    case .network: session.showNetworkSettings()
    case .disk: session.showDiskCapacitySettings()
    }
  }

  private func save(_ kind: SettingsClaimKind, session: DesktopSession, nested: Bool = false) {
    switch kind {
    case .hardware:
      session.saveHardware(cpuCount: 1, memoryBytes: nested ? 2 << 30 : 1 << 30)
    case .network: session.saveNetwork(mode: nested ? .disconnected : .shared)
    case .disk:
      session.saveDiskCapacity(
        targetBytes: nested ? 3 << 30 : 2 << 30, draft: session.diskCapacityDraftNonce)
    }
  }

  private func desired(_ kind: SettingsClaimKind, original: VMConfiguration) -> VMConfiguration {
    var result = original
    switch kind {
    case .hardware: result.memoryBytes = 1 << 30
    case .network: result.network = .shared
    case .disk: result.diskBytes = 2 << 30
    }
    return result
  }

  private func cancel(_ kind: SettingsClaimKind, session: DesktopSession) {
    switch kind {
    case .hardware:
      session.editingHardware = false
      session.hardwareSettingsDismissed()
    case .network:
      session.editingNetwork = false
      session.networkSettingsDismissed()
    case .disk:
      session.editingDiskCapacity = false
      session.diskCapacitySettingsDismissed()
    }
  }

  private func preservedRuntimeBoundary(_ fixture: Fixture) {
    #expect(!fixture.session.isActive && fixture.session.backend == nil)
    #expect(fixture.session.qualificationWindowsRuntime == nil)
    #expect(fixture.owner.activationRequests == 0)
    for name in ["runtime.json", "runtime-intent.json"] {
      #expect(
        !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path))
    }
  }

  private func requireCommit(_ kind: SettingsClaimKind, fixture: Fixture) async throws {
    let expected = desired(kind, original: fixture.original)
    #expect(try ConfigurationCodec.decode(Data(contentsOf: fixture.registration)) == expected)
    #expect(
      try await VMFiles().inspectWritableFile(at: fixture.root.appendingPathComponent("disk.raw"))
        .virtualBytes == expected.diskBytes)
    let prefix: String
    switch kind {
    case .hardware: prefix = "configuration-hardware-backup-"
    case .network: prefix = "configuration-network-backup-"
    case .disk: prefix = "disk-growth-"
    }
    let backups = try FileManager.default.contentsOfDirectory(
      at: fixture.root, includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix(prefix)
        && (kind != .disk || $0.lastPathComponent.hasSuffix("-original.json"))
    }
    #expect(backups.count == 1)
    let backup = try #require(backups.first)
    #expect(try Data(contentsOf: backup) == fixture.originalBytes)
  }

  @Test(arguments: SettingsClaimKind.allCases, [false, true])
  func synchronousPublicationAdmitsOnlyOuterSaveAndNeverReleasesBusyOverPendingWriter(
    kind: SettingsClaimKind, failFirst: Bool
  ) async throws {
    let service = SettingsClaimService()
    defer { service.releaseAll(allowCore: false) }
    let f = try await fixture(service: service)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let s = f.session
    show(kind, session: s)
    var reentered = false
    var busyReleasedWhileWriterPending = false
    let observation = s.$preparing.dropFirst().sink { value in
      if !value && service.pendingCount > 0 { busyReleasedWhileWriterPending = true }
      guard value, !reentered else { return }
      reentered = true
      save(kind, session: s, nested: true)
    }
    defer { observation.cancel() }
    save(kind, session: s)
    try await wait { service.pendingCount > 0 }
    #expect(reentered && s.preparing && service.calls.count == 1)
    for call in service.calls {
      #expect(call.kind == kind)
      #expect(call.directory == f.root)
      #expect(call.original == f.original)
      #expect(call.desired == desired(kind, original: f.original))
    }
    if failFirst {
      let first = try #require(service.pendingIDs.first)
      service.release(first, allowCore: false)
      // On the old controller the nested first call fails while the outer call
      // is still at its own barrier; its unowned defer publishes preparing=false.
      try await wait { !s.preparing }
      #expect(!busyReleasedWhileWriterPending)
      service.releaseAll(allowCore: false)
      try await wait { service.returned == service.calls.count && !s.preparing }
      #expect(service.coreCalls == 0)
      #expect(try Data(contentsOf: f.registration) == f.originalBytes)
      #expect(
        try await VMFiles().inspectWritableFile(at: f.root.appendingPathComponent("disk.raw"))
          .virtualBytes == f.original.diskBytes)
    } else {
      service.releaseAll(allowCore: true)
      try await wait { service.returned == service.calls.count && !s.preparing }
      #expect(service.coreCalls == 1 && service.calls.count == 1)
      #expect(s.configuration == desired(kind, original: f.original))
      try await requireCommit(kind, fixture: f)
    }
    preservedRuntimeBoundary(f)
    cancel(kind, session: s)
    withExtendedLifetime(f.owner) {}
  }

  @Test(arguments: SettingsClaimKind.allCases)
  func failedOlderSaveCannotClearANewerPreparationAfterItsRealCommit(
    kind: SettingsClaimKind
  ) async throws {
    let service = SettingsClaimService()
    service.failAfterCommit = true
    defer { service.releaseAll(allowCore: false) }
    let f = try await fixture(service: service)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let s = f.session
    show(kind, session: s)
    save(kind, session: s)
    try await wait { service.pendingCount == 1 }
    // Model a new unrelated preparation while the old service is suspended.
    // No replacement writer or runtime is granted by these publication facts.
    s.preparing = false
    s.preparing = true
    service.releaseAll(allowCore: true)
    // A post-commit failure reads the actual changed registration and invalidates
    // only its matching old selection. This is after the catch's last suspension.
    try await wait { s.configuration == nil && service.returned == 1 }
    #expect(s.preparing && s.selectedConfigurationURL == nil)
    #expect(service.calls.count == 1 && service.coreCalls == 1 && service.pendingCount == 0)
    try await requireCommit(kind, fixture: f)
    preservedRuntimeBoundary(f)
    s.preparing = false
    cancel(kind, session: s)
    withExtendedLifetime(f.owner) {}
  }
}
