// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class OpenLocationPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class PausedOpenLocationInspection: DesktopVMSelectionInspecting {
  var continuation: CheckedContinuation<Void, Never>?
  var failOnResume = false
  func inspect(at registration: URL, expectedID: UUID?) async throws
    -> DesktopVMSelectionObservation
  {
    let observed = try await NativeDesktopVMSelectionInspector().inspect(
      at: registration, expectedID: expectedID)
    await withCheckedContinuation { continuation = $0 }
    if failOnResume { throw NSError(domain: "obsolete selection failure", code: 1) }
    return observed
  }
  func resume() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }
}

@MainActor @Suite struct VMLibraryOpenLocationTests {
  private func fixture() async throws -> (URL, VMConfiguration, Data) {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-folder-\(UUID().uuidString).macopenvm", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let configuration = VMConfiguration(
      name: "Open folder", guest: .linux, backend: .appleVz,
      cpuCount: 1, memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let data = try ConfigurationCodec.encode(configuration)
    let files = VMFiles()
    try await files.atomicWrite(data, at: directory.appendingPathComponent("configuration.json"))
    try await files.createSparseDisk(
      at: directory.appendingPathComponent("disk.raw"), bytes: 1 << 30)
    return (directory, configuration, data)
  }

  private func makeSession(
    inspector: any DesktopVMSelectionInspecting = NativeDesktopVMSelectionInspector()
  ) -> (DesktopSession, NSWindow) {
    _ = NSApplication.shared
    let owner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    let result = DesktopSession(
      library: VMLibrary(preferences: OpenLocationPreferences()),
      selectionInspector: inspector)
    result.window = owner
    return (result, owner)
  }

  private func settle(_ session: DesktopSession) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while session.preparing && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.preparing)
  }

  @Test func directoryAndExplicitRegistrationResolveToTheSameExactLocation() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/Folder with spaces.macopenvm", isDirectory: true)
    let registration = directory.appendingPathComponent("configuration.json")
    #expect(
      try VMLibraryOpenLocation.registration(for: directory, kind: .directory) == registration)
    #expect(
      try VMLibraryOpenLocation.registration(for: registration, kind: .regular) == registration)
    // An arbitrary folder can contain a legitimate registration; extension is not authority.
    let plainFolder = URL(fileURLWithPath: "/private/tmp/Plain folder", isDirectory: true)
    #expect(
      try VMLibraryOpenLocation.registration(for: plainFolder, kind: .directory)
        == plainFolder.appendingPathComponent("configuration.json"))
  }

  @Test func unsafeKindsWrongFilesAndNonlocalOrAmbiguousLocationsReject() throws {
    let good = URL(fileURLWithPath: "/private/tmp/VM/configuration.json")
    for kind in [VMFileStatus.Kind.missing, .unreadable, .symlink, .other] {
      #expect(throws: VMError.self) {
        try VMLibraryOpenLocation.registration(for: good, kind: kind)
      }
    }
    for value in [
      "https://example.com/VM/configuration.json", "file://remote/VM/configuration.json",
      "file:///private/tmp/VM/configuration.json?other=1",
      "file:///private/tmp/VM/configuration.json#part",
      "file:///private/tmp/VM/other.json", "file:///private/tmp/VM/configuration.json/",
      "file:///private/tmp/../VM/configuration.json", "file:///private//tmp/VM/configuration.json",
    ] {
      let url = try #require(URL(string: value))
      #expect(throws: VMError.self) {
        try VMLibraryOpenLocation.registration(for: url, kind: .regular)
      }
    }
  }

  @Test func normalFolderAndFileOpeningSelectWithoutChangingAnyVMFileOrCreatingALock() async throws
  {
    let (directory, configuration, bytes) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    for location in [directory, directory.appendingPathComponent("configuration.json")] {
      let (session, owner) = makeSession()
      session.openVMLocation(location, activateWindow: false)
      try await settle(session)
      #expect(session.configuration == configuration && session.state == .stopped)
      #expect(
        session.selectedConfigurationURL == directory.appendingPathComponent("configuration.json"))
      #expect(
        session.library.entries.count == 1 && session.library.entries[0].vmID == configuration.id)
      #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
      #expect(try Data(contentsOf: directory.appendingPathComponent("configuration.json")) == bytes)
      #expect(
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
          == ["configuration.json", "disk.raw"])
      withExtendedLifetime(owner) {}
    }
  }

  @Test func replacementOwnerAndInterveningSelectionRejectTheAsynchronousLocationResult()
    async throws
  {
    let (directory, configuration, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    for replacement in ["owner", "selection"] {
      let (session, owner) = makeSession()
      session.openVMLocation(directory, activateWindow: false)
      if replacement == "owner" {
        session.window = nil
      } else {
        session.configuration = configuration
      }
      try await settle(session)
      #expect(session.selectedConfigurationURL == nil && session.library.entries.isEmpty)
      #expect(session.configuration == (replacement == "selection" ? configuration : nil))
      #expect(session.backend == nil && session.qualificationWindowsRuntime == nil)
      withExtendedLifetime(owner) {}
    }
  }

  @Test func symbolicLinkAndMalformedFolderDoNotReplaceThePreviousSelection() async throws {
    let (directory, configuration, bytes) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, owner) = makeSession()
    session.openVMLocation(directory, activateWindow: false)
    try await settle(session)
    let link = directory.appendingPathComponent("shortcut")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    session.openVMLocation(link, activateWindow: false)
    try await settle(session)
    #expect(session.configuration == configuration && session.library.entries.count == 1)
    let malformed = directory.appendingPathComponent("Malformed", isDirectory: true)
    try FileManager.default.createDirectory(
      at: malformed, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try Data("{}".utf8).write(to: malformed.appendingPathComponent("configuration.json"))
    session.openVMLocation(malformed, activateWindow: false)
    try await settle(session)
    #expect(session.configuration == configuration && session.library.entries.count == 1)
    #expect(
      session.selectedConfigurationURL == directory.appendingPathComponent("configuration.json"))
    #expect(try Data(contentsOf: directory.appendingPathComponent("configuration.json")) == bytes)
    withExtendedLifetime(owner) {}
  }

  @Test func lateInspectionAndItsErrorCannotPublishForAReplacedOwnerOrSelection() async throws {
    let (directory, configuration, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    for replacement in ["owner", "selection", "owner-and-error", "owner-aba", "selection-aba"] {
      let inspector = PausedOpenLocationInspection()
      let (session, owner) = makeSession(inspector: inspector)
      session.openVMLocation(directory, activateWindow: false)
      let deadline = ContinuousClock.now + .seconds(3)
      while inspector.continuation == nil && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(inspector.continuation != nil)
      defer { inspector.resume() }
      let replacementOwner = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
      if replacement == "selection" || replacement == "selection-aba" {
        session.configuration = configuration
        if replacement == "selection-aba" { session.configuration = nil }
      } else {
        session.window = replacementOwner
        if replacement == "owner-aba" { session.window = owner }
      }
      if replacement == "owner-and-error" { inspector.failOnResume = true }
      inspector.resume()
      try await settle(session)
      #expect(session.selectedConfigurationURL == nil && session.library.entries.isEmpty)
      #expect(session.configuration == (replacement == "selection" ? configuration : nil))
      #expect(session.errorMessage == nil && !owner.isVisible && !replacementOwner.isVisible)
      withExtendedLifetime((owner, replacementOwner)) {}
    }
  }
}
