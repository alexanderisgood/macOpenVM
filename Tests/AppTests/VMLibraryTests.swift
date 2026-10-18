// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@MainActor private final class MemoryLibraryPreferences: VMLibraryPreferences {
  var data: Data?
  var failWrites = false
  func read() throws -> Data? { data }
  func write(_ data: Data) throws {
    if failWrites { throw VMLibrary.failure() }
    self.data = data
  }
}

@MainActor @Suite struct VMLibraryTests {
  private func configuration(_ name: String, windows: Bool = false) -> VMConfiguration {
    VMConfiguration(
      name: name, guest: windows ? .windows11 : .linux,
      backend: windows ? .qemuHVF : .appleVz, diskBytes: 64 << 30)
  }
  private func location(_ name: String) -> URL {
    URL(fileURLWithPath: "/private/tmp/\(name).macopenvm/configuration.json")
  }

  @Test func realPrivateTmpRegistrationPreservesLexicalPathAcrossFoundationAliasAndLibrary()
    async throws
  {
    let root = URL(
      fileURLWithPath: "/private/tmp/macOpenVM-library-alias-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("configuration.json")
    let original = configuration("Actual private path", windows: true)
    let bytes = try ConfigurationCodec.encode(original)
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(url.path.hasPrefix("/private/tmp/"))
    #expect(url.standardizedFileURL.path.hasPrefix("/tmp/"))
    #expect(url.path != url.standardizedFileURL.path)
    try VMLibraryEntry.validateURL(url)
    let preferences = MemoryLibraryPreferences()
    let library = VMLibrary(preferences: preferences)
    library.remember(original, at: url)
    let entry = try #require(VMLibrary(preferences: preferences).entries.first)
    #expect(entry.configurationURL == url && entry.configurationURL.path == url.path)
    #expect(entry.vmID == original.id)
    let host = HostResources(cpuCount: 8, memoryBytes: 32 << 30)
    #expect(
      try await VMLibrarySelection.read(
        at: entry.configurationURL, expectedID: original.id, host: host) == original)
    #expect(try Data(contentsOf: url) == bytes)
  }

  @Test func roundTripGroupsSearchAndDuplicateUUIDsAtDifferentLocations() throws {
    let preferences = MemoryLibraryPreferences()
    let library = VMLibrary(preferences: preferences)
    let linux = configuration("Dévelopment")
    let windows = configuration("Windows Work", windows: true)
    library.remember(linux, at: location("Linux"))
    library.remember(windows, at: location("Windows"))
    library.remember(linux, at: location("CopiedLinux"))
    let reopened = VMLibrary(preferences: preferences)
    #expect(reopened.entries.count == 3)
    #expect(reopened.entries.first?.id == location("CopiedLinux"))
    #expect(reopened.matching(.linux).count == 2)
    #expect(reopened.matching(.windows11).map(\.name) == ["Windows Work"])
    reopened.query = " development "
    #expect(reopened.matching(.linux).count == 2)
    #expect(reopened.matching(.windows11).isEmpty)
    reopened.query = "copied"
    #expect(reopened.matching(.linux).map(\.id) == [location("CopiedLinux")])
    var renamed = linux
    renamed.name = "Renamed"
    reopened.remember(renamed, at: location("Linux"))
    #expect(reopened.entries.count == 3)
    #expect(reopened.entries.first?.name == "Renamed")
    #expect(reopened.errorMessage == nil)
  }

  @Test func boundedRecencyAndFailedWritePreserveTheLastList() throws {
    let preferences = MemoryLibraryPreferences()
    let library = VMLibrary(preferences: preferences)
    for index in 0..<55 {
      library.remember(configuration("VM \(index)"), at: location("VM\(index)"))
    }
    #expect(library.entries.count == 50)
    #expect(library.entries.last?.name == "VM 5")
    let prior = try #require(preferences.data)
    let entries = library.entries
    preferences.failWrites = true
    library.forget(try #require(entries.first))
    #expect(preferences.data == prior)
    #expect(library.entries == entries)
    #expect(library.errorMessage != nil)
  }

  @Test(arguments: ["invalid", "future", "duplicate", "remote", "oversized"])
  func damagedOrFuturePreferencesAreNeverOverwritten(kind: String) throws {
    let preferences = MemoryLibraryPreferences()
    let valid = try VMLibraryEntry(configuration: configuration("One"), at: location("one"))
    var document = VMLibrary.Document(schemaVersion: kind == "future" ? 2 : 1, entries: [valid])
    if kind == "duplicate" { document = .init(schemaVersion: 1, entries: [valid, valid]) }
    preferences.data = try JSONEncoder().encode(document)
    if kind == "invalid" { preferences.data = Data("broken".utf8) }
    if kind == "oversized" { preferences.data = Data(repeating: 32, count: 262_145) }
    if kind == "remote" {
      let payload = try #require(preferences.data)
      var object = try #require(
        JSONSerialization.jsonObject(with: payload) as? [String: Any])
      var entries = try #require(object["entries"] as? [[String: Any]])
      entries[0]["configurationURL"] = "https://example.com/configuration.json"
      object["entries"] = entries
      preferences.data = try JSONSerialization.data(withJSONObject: object)
    }
    let prior = preferences.data
    let library = VMLibrary(preferences: preferences)
    #expect(library.entries.isEmpty)
    #expect(library.errorMessage != nil)
    library.remember(configuration("Replacement"), at: location("replacement"))
    library.forget(valid)
    #expect(preferences.data == prior)
    #expect(library.entries.isEmpty)
  }

  @Test func actualConfigurationIdentityAndForgetPreserveVMFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("configuration.json")
    let disk = root.appendingPathComponent("disk.raw")
    let bytes = Data("VM disk preservation witness".utf8)
    try bytes.write(to: disk)
    let original = configuration("Windows metadata", windows: true)
    try ConfigurationCodec.encode(original).write(to: url)
    let preferences = MemoryLibraryPreferences()
    let library = VMLibrary(preferences: preferences)
    library.remember(original, at: url)
    let entry = try #require(library.entries.first)
    let host = HostResources(cpuCount: 8, memoryBytes: 32 << 30)
    #expect(
      try await VMLibrarySelection.read(at: url, expectedID: entry.vmID, host: host) == original)
    let changed = configuration("Replacement", windows: true)
    let changedBytes = try ConfigurationCodec.encode(changed)
    try changedBytes.write(to: url)
    await #expect(throws: VMError.self) {
      try await VMLibrarySelection.read(at: url, expectedID: entry.vmID, host: host)
    }
    #expect(try await VMLibrarySelection.read(at: url, host: host) == changed)
    library.forget(entry)
    #expect(library.entries.isEmpty)
    #expect(VMLibrary(preferences: preferences).entries.isEmpty)
    #expect(try Data(contentsOf: disk) == bytes)
    #expect(try Data(contentsOf: url) == changedBytes)
    try FileManager.default.removeItem(at: url)
    await #expect(throws: Error.self) {
      try await VMLibrarySelection.read(at: url, expectedID: original.id, host: host)
    }
  }

  @Test func selectionRejectsNonCanonicalOrNonRegistrationLocations() throws {
    for path in [
      "https://example.com/configuration.json", "file://remote/private/configuration.json",
      "file:///private/other.json", "file:///private/configuration.json?token=1",
      "file:///private/configuration.json#fragment", "file:///private/one/../configuration.json",
      "file:///private/one/./configuration.json", "file:///private//configuration.json",
      "file://user:password@localhost/private/configuration.json",
      "file:///private/%00/configuration.json",
    ] {
      let url = try #require(URL(string: path))
      #expect(throws: VMError.self) { try VMLibraryEntry.validateURL(url) }
    }
  }

  @Test func foundationPreferencesStayInTheirOwnDomain() throws {
    let domain = "local.macOpenVM.libraryTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let preferences = DefaultVMLibraryPreferences(defaults: defaults)
    let library = VMLibrary(preferences: preferences)
    let vm = configuration("Windows", windows: true)
    library.remember(vm, at: location("Windows"))
    let another = try #require(UserDefaults(suiteName: domain))
    let loaded = VMLibrary(preferences: DefaultVMLibraryPreferences(defaults: another))
    #expect(loaded.entries.map(\.vmID) == [vm.id])
    defaults.set("wrong type", forKey: DefaultVMLibraryPreferences.key)
    loaded.reload()
    loaded.remember(configuration("New"), at: location("New"))
    #expect(loaded.errorMessage != nil)
    #expect(defaults.string(forKey: DefaultVMLibraryPreferences.key) == "wrong type")
  }

  @Test func libraryReleasesInputAndDefersSelectionUntilDismissal() throws {
    let preferences = MemoryLibraryPreferences()
    let library = VMLibrary(preferences: preferences)
    let session = DesktopSession(library: library)
    let first = configuration("First")
    session.configuration = first
    session.inputCaptured = true
    session.showLibrary()
    #expect(session.showingLibrary)
    #expect(!session.inputCaptured)
    let second = configuration("Second", windows: true)
    let entry = try VMLibraryEntry(configuration: second, at: location("Second"))
    session.preparing = true
    session.openSavedVM(entry)
    #expect(session.showingLibrary)
    #expect(session.configuration == first)
    session.preparing = false
    session.showHardwareSettings()
    #expect(!session.editingHardware)
    session.openSavedVM(entry, settings: true)
    #expect(!session.showingLibrary)
    #expect(session.isBusy)
    #expect(!session.preparing)
    #expect(session.configuration == first)
    #expect(!session.editingHardware)
    session.configuration = second
    #expect(!session.canStartSelected)
  }

  @Test func forgettingAStaleEntryPreservesAReplacementAtTheSamePath() throws {
    let preferences = MemoryLibraryPreferences()
    let library = VMLibrary(preferences: preferences)
    let path = location("shared-location")
    library.remember(configuration("Original"), at: path)
    let original = try #require(library.entries.first)
    let replacement = configuration("Replacement", windows: true)
    library.remember(replacement, at: path)
    library.forget(original)
    #expect(library.entries.count == 1 && library.entries.first?.vmID == replacement.id)
    let reloaded = VMLibrary(preferences: preferences)
    #expect(reloaded.entries == library.entries)
  }

  @Test func creationAssistantPreservesThePreviousSelectionUntilItIsDismissed() async throws {
    let library = VMLibrary(preferences: MemoryLibraryPreferences())
    let session = DesktopSession(library: library)
    let original = configuration("Previously selected")
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("library-creation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let registration = root.appendingPathComponent("configuration.json")
    try await VMFiles().atomicWrite(ConfigurationCodec.encode(original), at: registration)
    try await session.qualificationSelectVM(at: registration, expectedID: original.id)
    let owner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    session.window = owner
    defer { withExtendedLifetime(owner) {} }
    session.showLinuxCreation()
    #expect(session.creating && !session.isBusy)
    session.showHardwareSettings()
    session.showLibrary()
    session.showLinuxCreation()
    #expect(session.creating && !session.editingHardware && !session.showingLibrary)
    #expect(session.hardwareConfiguration == nil && session.configuration == original)

    session.creating = false
    session.showHardwareSettings()
    #expect(session.editingHardware && session.hardwareConfiguration == original)
    #expect(session.configuration == original)
  }
}
