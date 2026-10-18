// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import SwiftUI
import VMCore
import VMStorage

struct VMLibraryEntry: Codable, Equatable, Identifiable {
  var id: URL { configurationURL }
  let configurationURL: URL
  let vmID: UUID
  let name: String
  let guest: GuestOS

  init(configuration: VMConfiguration, at url: URL) throws {
    try Self.validateURL(url)
    configurationURL = url
    vmID = configuration.id
    name = configuration.name
    guest = configuration.guest
    try validate()
  }

  func validate() throws {
    try Self.validateURL(configurationURL)
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name.utf8.count <= 128,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw VMLibrary.failure() }
  }

  static func validateURL(_ url: URL) throws {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      let decodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .percentEncodedPath.removingPercentEncoding,
      decodedPath == url.path,
      url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
      url.lastPathComponent == "configuration.json",
      url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw VMError(
        .invalidConfiguration, "Choose a local configuration.json file.",
        recovery: "Open the VM’s own configuration file from its saved folder.")
    }
  }
}

@MainActor protocol VMLibraryPreferences {
  func read() throws -> Data?
  func write(_ data: Data) throws
}

@MainActor struct DefaultVMLibraryPreferences: VMLibraryPreferences {
  static let key = "macOpenVM.savedVMs.v1"
  let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  func read() throws -> Data? {
    guard let value = defaults.object(forKey: Self.key) else { return nil }
    guard let data = value as? Data else { throw VMLibrary.failure() }
    return data
  }
  func write(_ data: Data) throws {
    defaults.set(data, forKey: Self.key)
    guard try read() == data else { throw VMLibrary.failure() }
  }
}

/// A recent navigation list, never authority to start or modify a VM.
@MainActor final class VMLibrary: ObservableObject {
  struct Document: Codable {
    let schemaVersion: Int
    let entries: [VMLibraryEntry]
  }
  static let maximumEntries = 50
  static let maximumBytes = 262_144
  @Published private(set) var entries: [VMLibraryEntry] = []
  @Published private(set) var errorMessage: String?
  @Published var query = ""
  private let preferences: any VMLibraryPreferences

  init(preferences: any VMLibraryPreferences = DefaultVMLibraryPreferences()) {
    self.preferences = preferences
    reload()
  }

  nonisolated static func failure() -> VMError {
    VMError(
      .corruptMetadata, "The saved VM list could not be read or updated.",
      recovery: "You can still open a VM with Open VM.")
  }

  private func read() throws -> [VMLibraryEntry] {
    guard let data = try preferences.read() else { return [] }
    guard data.count <= Self.maximumBytes else { throw Self.failure() }
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.schemaVersion == 1, document.entries.count <= Self.maximumEntries,
      Set(document.entries.map(\.id)).count == document.entries.count
    else { throw Self.failure() }
    for entry in document.entries { try entry.validate() }
    return document.entries
  }

  func reload() {
    do {
      entries = try read()
      errorMessage = nil
    } catch {
      entries = []
      errorMessage = Self.failure().errorDescription
    }
  }

  func matching(_ guest: GuestOS) -> [VMLibraryEntry] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return entries.filter {
      $0.guest == guest
        && (search.isEmpty || $0.name.localizedStandardContains(search)
          || $0.configurationURL.deletingLastPathComponent().lastPathComponent
            .localizedStandardContains(search))
    }
  }

  func remember(_ configuration: VMConfiguration, at url: URL) {
    change { current in
      let entry = try VMLibraryEntry(configuration: configuration, at: url)
      return Array(([entry] + current.filter { $0.id != entry.id }).prefix(Self.maximumEntries))
    }
  }

  func forget(_ entry: VMLibraryEntry) {
    change { current in
      current.filter {
        $0.configurationURL != entry.configurationURL || $0.vmID != entry.vmID
      }
    }
  }

  private func change(_ transform: ([VMLibraryEntry]) throws -> [VMLibraryEntry]) {
    do {
      let updated = try transform(read())
      let data = try JSONEncoder().encode(Document(schemaVersion: 1, entries: updated))
      guard data.count <= Self.maximumBytes else { throw Self.failure() }
      try preferences.write(data)
      entries = updated
      errorMessage = nil
    } catch { errorMessage = Self.failure().errorDescription }
  }
}

enum VMLibrarySelection {
  static func read(
    at url: URL, expectedID: UUID? = nil, files: VMFiles = VMFiles(),
    host: HostResources = .current
  ) async throws -> VMConfiguration {
    let configuration = try await saved(at: url, expectedID: expectedID, files: files)
    try ConfigurationValidator.validate(configuration, host: host)
    return configuration
  }

  /// Explicit repair/review entry point. Never call this from runtime admission.
  /// This accepts saved hardware too large for this host so an existing offline
  /// HardwareSettings transaction can propose a smaller, strictly validated replacement.
  static func readForEditing(
    at url: URL, expectedID: UUID? = nil, files: VMFiles = VMFiles()
  ) async throws -> VMConfiguration {
    let configuration = try await saved(at: url, expectedID: expectedID, files: files)
    try ConfigurationValidator.validateSaved(configuration)
    return configuration
  }

  private static func saved(
    at url: URL, expectedID: UUID?, files: VMFiles
  ) async throws -> VMConfiguration {
    try VMLibraryEntry.validateURL(url)
    let configuration = try ConfigurationCodec.decode(
      await files.readMetadata(at: url, limit: ConfigurationCodec.maximumBytes))
    guard expectedID == nil || expectedID == configuration.id else {
      throw VMError(
        .staleOperation, "A different VM now occupies this saved location.",
        recovery: "Use Open VM to review and select the replacement explicitly.")
    }
    return configuration
  }
}
