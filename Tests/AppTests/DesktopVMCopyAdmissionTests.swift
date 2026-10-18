// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Combine
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// The existing Core clone-test platform: generated files, no VZ/QEMU native call.
@MainActor private struct CopyAdmissionFixturePlatform: VMCreationPlatform {
  let backend = BackendID.appleVz
  func validateHost(for configuration: VMConfiguration) throws {}
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    try Data(UUID().uuidString.utf8).write(
      to: directory.appendingPathComponent("machine-identity.bin"), options: .withoutOverwriting)
    try Data("new EFI fixture; not a firmware test".utf8).write(
      to: directory.appendingPathComponent("efi-variables.bin"), options: .withoutOverwriting)
    return CreatedPlatformIdentity(files: ["machine-identity.bin", "efi-variables.bin"])
  }
}

@MainActor private final class CopyAdmissionPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class CopyAdmissionWindow: NSWindow {
  var activationRequests = 0
  var controlledSheet: NSWindow?
  override var attachedSheet: NSWindow? { controlledSheet }
  override func makeKeyAndOrderFront(_ sender: Any?) { activationRequests += 1 }
}

@MainActor private final class ControlledCopyPresentation: DesktopVMCopyPresenting {
  let parent: URL
  var chosenName: String? = "Copy"
  var chooseParent = true
  var holdName = false
  var holdParent = false
  var nameCalls = 0
  var parentCalls = 0
  var nameReturned = false
  var parentReturned = false
  var namePending: CheckedContinuation<Void, Never>?
  var parentPending: CheckedContinuation<Void, Never>?

  init(parent: URL) { self.parent = parent }

  func name(for configuration: VMConfiguration, on owner: NSWindow?) async -> String? {
    nameCalls += 1
    if holdName { await withCheckedContinuation { namePending = $0 } }
    nameReturned = true
    return chosenName
  }

  func parentDirectory(for source: URL, on owner: NSWindow?) async -> URL? {
    parentCalls += 1
    if holdParent { await withCheckedContinuation { parentPending = $0 } }
    parentReturned = true
    return chooseParent ? parent : nil
  }

  func releaseName() {
    holdName = false
    let continuation = namePending
    namePending = nil
    continuation?.resume()
  }

  func releaseParent() {
    holdParent = false
    let continuation = parentPending
    parentPending = nil
    continuation?.resume()
  }

  func release() {
    releaseName()
    releaseParent()
  }
}

/// The barrier follows an actual ordinary Core clone and registration commit.
@MainActor private final class ControlledDesktopVMCopy: DesktopVMCopying {
  var calls = 0
  var holdCompletion = true
  var failAfterCommit = false
  var committed: VMCloneResult?
  var pending: CheckedContinuation<Void, Never>?

  func copy(from source: URL, to destination: URL, name: String, expected: VMConfiguration)
    async throws -> VMCloneResult
  {
    calls += 1
    let result = try await VMClone().copy(
      from: source, to: destination, name: name, platform: CopyAdmissionFixturePlatform(),
      host: HostResources(cpuCount: 8, memoryBytes: 16 << 30), expected: expected)
    committed = result
    if holdCompletion { await withCheckedContinuation { pending = $0 } }
    if failAfterCommit { throw NSError(domain: "private post-commit copy fixture", code: 1) }
    return result
  }

  func release() {
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
}

/// Hidden actual sessions and fresh Core transaction files; no sheets or VM are shown/run.
@MainActor @Suite(.serialized) struct DesktopVMCopyAdmissionTests {
  private struct Fixture {
    let root: URL
    let source: URL
    let original: VMConfiguration
    var registration: URL { source.appendingPathComponent("configuration.json") }
    var target: URL { root.appendingPathComponent("Copy.macopenvm", isDirectory: true) }
  }

  private struct SourceBytes: Equatable {
    let configuration: Data
    let identity: Data
    let efi: Data
    let diskLength: UInt64
    let first: Data
    let last: Data
  }

  private func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("copy-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let source = root.appendingPathComponent("source.macopenvm", isDirectory: true)
    let media = root.appendingPathComponent("generated.iso")
    try Data(repeating: 0x52, count: 1024).write(to: media)
    var configuration = VMConfiguration(
      name: "Original", guest: .linux, backend: .appleVz, cpuCount: 1,
      memoryBytes: 512 << 20, diskBytes: 1 << 30)
    configuration.installationMedia = media.path
    configuration.network = .shared
    try await VMCreation().create(
      configuration, at: source, platform: CopyAdmissionFixturePlatform(),
      host: HostResources(cpuCount: 8, memoryBytes: 16 << 30))
    return Fixture(root: root, source: source, original: configuration)
  }

  private func bytes(at directory: URL) throws -> SourceBytes {
    let disk = try FileHandle(forReadingFrom: directory.appendingPathComponent("disk.raw"))
    defer { try? disk.close() }
    let length = try disk.seekToEnd()
    guard length >= 512 else { throw CocoaError(.fileReadUnknown) }
    try disk.seek(toOffset: 0)
    let first = try disk.read(upToCount: 512) ?? Data()
    try disk.seek(toOffset: length - 512)
    let last = try disk.read(upToCount: 512) ?? Data()
    return try SourceBytes(
      configuration: Data(contentsOf: directory.appendingPathComponent("configuration.json")),
      identity: Data(contentsOf: directory.appendingPathComponent("machine-identity.bin")),
      efi: Data(contentsOf: directory.appendingPathComponent("efi-variables.bin")),
      diskLength: length, first: first, last: last)
  }

  private func window() -> CopyAdmissionWindow {
    let owner = CopyAdmissionWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    return owner
  }

  private func selected(
    _ fixture: Fixture, service: ControlledDesktopVMCopy, presentation: ControlledCopyPresentation
  ) async throws -> (DesktopSession, CopyAdmissionWindow) {
    _ = NSApplication.shared
    let owner = window()
    let session = DesktopSession(
      library: VMLibrary(preferences: CopyAdmissionPreferences()),
      graphicsPreferences: WindowsGraphicsPreferenceStore(
        preferences: MemoryWindowsGraphicsPreferences()),
      vmCopy: service, copyPresentation: presentation)
    session.window = owner
    try await session.qualificationSelectVM(
      at: fixture.registration, expectedID: fixture.original.id)
    #expect(session.configuration == fixture.original && session.canCopySelected)
    return (session, owner)
  }

  private func wait(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
  }

  private func verifyCopy(_ fixture: Fixture, result: VMCloneResult) throws {
    #expect(result.sourceVMID == fixture.original.id)
    #expect(result.configuration.id != fixture.original.id)
    #expect(result.configuration.macAddress != fixture.original.macAddress)
    #expect(result.configuration.network == .disconnected)
    #expect(
      try ConfigurationCodec.decode(
        Data(contentsOf: fixture.target.appendingPathComponent("configuration.json")))
        == result.configuration)
    let source = try bytes(at: fixture.source)
    let copy = try bytes(at: fixture.target)
    #expect(copy.identity != source.identity && copy.diskLength == source.diskLength)
    #expect(copy.first == source.first && copy.last == source.last)
  }

  @Test func releaseInputReentryRevokesTheCopyBeforeAnyPresentation() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try bytes(at: fixture.source)
    let service = ControlledDesktopVMCopy()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let presentation = ControlledCopyPresentation(parent: fixture.root)
    defer { presentation.release() }
    let (session, owner) = try await selected(fixture, service: service, presentation: presentation)
    let replacement = window()
    var reentered = false
    var reentryCount = 0
    let observer = session.$inputCaptured.dropFirst().sink { captured in
      guard !captured, !reentered else { return }
      reentryCount += 1
      reentered = true
      session.window = replacement
      session.window = owner
    }
    defer { observer.cancel() }
    #expect(!reentered && reentryCount == 0)
    session.chooseCopyVM()
    #expect(reentered && reentryCount == 1 && !session.preparing)
    #expect(presentation.nameCalls == 0 && presentation.parentCalls == 0 && service.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    #expect(try bytes(at: fixture.source) == original)
    #expect(
      session.configuration == fixture.original
        && session.selectedConfigurationURL == fixture.registration)
    withExtendedLifetime((owner, replacement)) {}
  }

  @Test(arguments: ["queued", "name", "parent"], ["owner-aba", "selection-aba"])
  func queuedAndSheetRepliesCannotReuseAnOldCopyConfirmation(phase: String, change: String)
    async throws
  {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try bytes(at: fixture.source)
    let service = ControlledDesktopVMCopy()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let presentation = ControlledCopyPresentation(parent: fixture.root)
    defer { presentation.release() }
    presentation.holdName = phase == "name"
    presentation.holdParent = phase == "parent"
    let (session, owner) = try await selected(fixture, service: service, presentation: presentation)
    let replacement = window()
    session.chooseCopyVM()
    #expect(session.preparing)
    if phase == "name" { try await wait { presentation.namePending != nil } }
    if phase == "parent" { try await wait { presentation.parentPending != nil } }
    if change == "owner-aba" {
      session.window = replacement
      session.window = owner
    } else {
      var changed = fixture.original
      changed.name = "Temporary selection"
      session.configuration = changed
      session.configuration = fixture.original
    }
    session.errorMessage = "Newer independent error"
    service.holdCompletion = false
    presentation.release()
    service.release()
    try await wait { !session.preparing }
    #expect(service.calls == 0 && session.errorMessage == "Newer independent error")
    #expect(presentation.nameCalls == (phase == "queued" ? 0 : 1))
    #expect(presentation.parentCalls == (phase == "parent" ? 1 : 0))
    #expect(try bytes(at: fixture.source) == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    // A fresh confirmation still performs the real Core copy after the rejection.
    session.errorMessage = nil
    session.chooseCopyVM()
    try await wait { !session.preparing }
    let result = try #require(service.committed)
    #expect(service.calls == 1 && session.configuration == result.configuration)
    #expect(
      session.library.entries.contains {
        $0.configurationURL == fixture.target.appendingPathComponent("configuration.json")
          && $0.vmID == result.configuration.id
      })
    try verifyCopy(fixture, result: result)
    #expect(try bytes(at: fixture.source) == original)
    #expect(owner.activationRequests == 0 && replacement.activationRequests == 0)
    withExtendedLifetime((owner, replacement)) {}
  }

  @Test func physicalSheetDetachmentGatesTheNextSheetAndTheWriter() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try bytes(at: fixture.source)
    let service = ControlledDesktopVMCopy()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let presentation = ControlledCopyPresentation(parent: fixture.root)
    defer { presentation.release() }
    presentation.holdName = true
    presentation.holdParent = true
    let (session, owner) = try await selected(fixture, service: service, presentation: presentation)
    session.chooseCopyVM()
    try await wait { presentation.namePending != nil }
    owner.controlledSheet = window()
    presentation.releaseName()
    try await wait { presentation.nameReturned }
    #expect(presentation.parentCalls == 0 && service.calls == 0 && session.preparing)
    owner.controlledSheet = nil
    try await wait { presentation.parentPending != nil }
    owner.controlledSheet = window()
    presentation.releaseParent()
    try await wait { presentation.parentReturned }
    #expect(service.calls == 0 && session.preparing)
    owner.controlledSheet = nil
    try await wait { service.pending != nil }
    let result = try #require(service.committed)
    service.release()
    try await wait { !session.preparing }
    try verifyCopy(fixture, result: result)
    #expect(try bytes(at: fixture.source) == original)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["owner-aba", "replacement"], [false, true])
  func staleCopyCompletionPreservesTheActualTransactionAndTheCurrentSelection(
    change: String, fail: Bool
  ) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try bytes(at: fixture.source)
    let service = ControlledDesktopVMCopy()
    defer {
      service.holdCompletion = false
      service.release()
    }
    service.failAfterCommit = fail
    let presentation = ControlledCopyPresentation(parent: fixture.root)
    defer { presentation.release() }
    let (session, owner) = try await selected(fixture, service: service, presentation: presentation)
    let replacementOwner = window()
    session.chooseCopyVM()
    try await wait { service.pending != nil }
    let result = try #require(service.committed)
    let target = try bytes(at: fixture.target)
    var replacement = fixture.original
    replacement.id = UUID()
    replacement.name = "Independent registration"
    let replacementBytes = try ConfigurationCodec.encode(replacement)
    if change == "owner-aba" {
      session.window = replacementOwner
      session.window = owner
    } else {
      try await VMFiles().atomicWrite(replacementBytes, at: fixture.registration)
      session.configuration = replacement
    }
    session.errorMessage = "Newer independent error"
    service.release()
    try await wait { !session.preparing }
    #expect(session.configuration == (change == "owner-aba" ? fixture.original : replacement))
    #expect(session.selectedConfigurationURL == fixture.registration)
    #expect(session.errorMessage == "Newer independent error")
    #expect(try bytes(at: fixture.target) == target)
    if change == "owner-aba" {
      #expect(try bytes(at: fixture.source) == original)
    } else {
      #expect(try Data(contentsOf: fixture.registration) == replacementBytes)
    }
    #expect(
      session.library.entries.contains {
        $0.configurationURL == fixture.target.appendingPathComponent("configuration.json")
          && $0.vmID == result.configuration.id
      } == !fail)
    // A delivery failure has no confirmed result in the controller: the real
    // committed target remains, but no invented library authority is published.
    #expect(
      try ConfigurationCodec.decode(
        Data(contentsOf: fixture.target.appendingPathComponent("configuration.json")))
        == result.configuration)
    #expect(owner.activationRequests == 0 && replacementOwner.activationRequests == 0)
    withExtendedLifetime((owner, replacementOwner)) {}
  }

  @Test func currentCopySelectsFreshIdentityWithoutClearingANewerError() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try bytes(at: fixture.source)
    let service = ControlledDesktopVMCopy()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let presentation = ControlledCopyPresentation(parent: fixture.root)
    defer { presentation.release() }
    let (session, owner) = try await selected(fixture, service: service, presentation: presentation)
    session.chooseCopyVM()
    try await wait { service.pending != nil }
    let result = try #require(service.committed)
    session.errorMessage = "Newer independent error"
    service.release()
    try await wait { !session.preparing }
    #expect(session.configuration == result.configuration)
    #expect(
      session.selectedConfigurationURL
        == fixture.target.appendingPathComponent("configuration.json"))
    #expect(session.errorMessage == "Newer independent error")
    try verifyCopy(fixture, result: result)
    #expect(try bytes(at: fixture.source) == original)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["name", "parent"])
  func cancellationAtEitherSheetDoesNotWriteOrClearANewerError(phase: String) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try bytes(at: fixture.source)
    let service = ControlledDesktopVMCopy()
    defer {
      service.holdCompletion = false
      service.release()
    }
    let presentation = ControlledCopyPresentation(parent: fixture.root)
    defer { presentation.release() }
    presentation.chosenName = phase == "name" ? nil : "Copy"
    presentation.chooseParent = phase != "parent"
    presentation.holdName = phase == "name"
    presentation.holdParent = phase == "parent"
    let (session, owner) = try await selected(fixture, service: service, presentation: presentation)
    session.errorMessage = "Newer independent error"
    session.chooseCopyVM()
    try await wait {
      phase == "name" ? presentation.namePending != nil : presentation.parentPending != nil
    }
    owner.controlledSheet = window()
    presentation.release()
    try await wait { phase == "name" ? presentation.nameReturned : presentation.parentReturned }
    #expect(session.preparing && service.calls == 0)
    owner.controlledSheet = nil
    try await wait { !session.preparing }
    #expect(service.calls == 0 && session.configuration == fixture.original)
    #expect(session.errorMessage == "Newer independent error")
    #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    #expect(try bytes(at: fixture.source) == original)
    withExtendedLifetime(owner) {}
  }
}
