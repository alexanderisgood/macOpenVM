// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Foundation

enum WindowsGraphicsPreferencesValue: Equatable, Sendable {
  case missing
  case data(Data)
  case invalidType
}

@MainActor protocol WindowsGraphicsPreferences {
  func read() throws -> WindowsGraphicsPreferencesValue
  func write(_ data: Data) throws
}

@MainActor struct DefaultWindowsGraphicsPreferences: WindowsGraphicsPreferences {
  static let key = "macOpenVM.windowsGraphics.v1"
  let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  func read() throws -> WindowsGraphicsPreferencesValue {
    guard let value = defaults.object(forKey: Self.key) else { return .missing }
    guard let data = value as? Data else { return .invalidType }
    return .data(data)
  }
  func write(_ data: Data) throws { defaults.set(data, forKey: Self.key) }
}

enum WindowsGraphicsPreferenceIssue: Error, Equatable, Sendable {
  case unreadable, invalidData, unsupportedSchema, oversized, invalidValueType

  var message: String {
    switch self {
    case .unreadable:
      "Remembered graphics settings could not be read. Try opening Graphics Settings again."
    case .invalidValueType:
      "Remembered graphics settings have an unsupported storage type. They cannot be reset safely here."
    case .invalidData, .unsupportedSchema, .oversized:
      "Remembered graphics settings could not be read. Review Reset Remembered Graphics Settings to repair them."
    }
  }
}

private struct WindowsGraphicsPreferenceIdentity: Equatable, Hashable, Sendable {
  let configurationURL: String
  let vmID: UUID

  init(url: URL, vmID: UUID) throws {
    try VMLibraryEntry.validateURL(url)
    configurationURL = url.absoluteString
    self.vmID = vmID
  }

  init(configurationURL: String, vmID: UUID) {
    self.configurationURL = configurationURL
    self.vmID = vmID
  }
}

private enum WindowsGraphicsPreferenceRevision: Equatable, Sendable {
  case missing
  case data(count: Int, digest: Data)

  init?(_ value: WindowsGraphicsPreferencesValue) {
    switch value {
    case .missing: self = .missing
    case .data(let data): self = .data(count: data.count, digest: Data(SHA256.hash(data: data)))
    // Arbitrary wrong-type values have no exact revision. They must never be
    // overwritten on the strength of an indistinguishable wrong-type sentinel.
    case .invalidType: return nil
    }
  }
}

/// A bounded declarative candidate, never resource admission or current host capability.
struct WindowsGraphicsPreferenceSnapshot: Equatable, Sendable {
  let settings: WindowsGraphicsSettings
  let isRemembered: Bool
  let issue: WindowsGraphicsPreferenceIssue?
  fileprivate let identity: WindowsGraphicsPreferenceIdentity
  fileprivate let revision: WindowsGraphicsPreferenceRevision?
  fileprivate let storeID: UUID

  var canReset: Bool { issue != nil && revision != nil }

  func matches(configurationURL: URL, vmID: UUID) -> Bool {
    identity.configurationURL == configurationURL.absoluteString && identity.vmID == vmID
  }
}

/// App-local preferences only. No VM file is read or changed by this store.
/// Synchronous main-actor mutations avoid interleaved writes within the app;
/// revisions detect visible changes but UserDefaults is not cross-process CAS.
@MainActor final class WindowsGraphicsPreferenceStore {
  static let maximumEntries = 50
  static let maximumBytes = 262_144
  private let preferences: any WindowsGraphicsPreferences
  private let id = UUID()

  init(preferences: any WindowsGraphicsPreferences = DefaultWindowsGraphicsPreferences()) {
    self.preferences = preferences
  }

  func load(at configurationURL: URL, vmID: UUID) throws -> WindowsGraphicsPreferenceSnapshot {
    let identity = try WindowsGraphicsPreferenceIdentity(url: configurationURL, vmID: vmID)
    let value: WindowsGraphicsPreferencesValue
    do { value = try preferences.read() } catch {
      return snapshot(identity: identity, revision: nil, issue: .unreadable)
    }
    let revision = WindowsGraphicsPreferenceRevision(value)
    do {
      let document = try read(value)
      let record = document.entries.first { $0.identity == identity }
      return snapshot(
        identity: identity, revision: revision, settings: try record?.settings(),
        isRemembered: record != nil)
    } catch {
      return snapshot(
        identity: identity, revision: revision,
        issue: error as? WindowsGraphicsPreferenceIssue ?? .invalidData)
    }
  }

  func remember(
    _ settings: WindowsGraphicsSettings, from previous: WindowsGraphicsPreferenceSnapshot
  )
    throws -> WindowsGraphicsPreferenceSnapshot
  {
    guard previous.issue == nil else {
      throw Self.failure("Remembered graphics settings need repair before they can be saved.")
    }
    let canonical = try settings.validatedPreference()
    let current = try requireCurrent(previous)
    var entries = try read(current).entries.filter { $0.identity != previous.identity }
    entries.insert(Record(identity: previous.identity, settings: canonical), at: 0)
    entries = Array(entries.prefix(Self.maximumEntries))
    var data = try encode(entries)
    while data.count > Self.maximumBytes && entries.count > 1 {
      entries.removeLast()
      data = try encode(entries)
    }
    guard data.count <= Self.maximumBytes else {
      throw Self.failure("The graphics settings are too large to remember.")
    }
    try writeAndConfirm(data)
    return snapshot(
      identity: previous.identity, revision: WindowsGraphicsPreferenceRevision(.data(data)),
      settings: canonical, isRemembered: true)
  }

  /// The caller obtains explicit confirmation that this resets all remembered
  /// graphics choices. It does not apply a draft or modify any VM files.
  func resetAll(from previous: WindowsGraphicsPreferenceSnapshot) throws
    -> WindowsGraphicsPreferenceSnapshot
  {
    guard previous.canReset else {
      throw Self.failure("These remembered graphics settings cannot be reset safely.")
    }
    let current = try requireCurrent(previous)
    do {
      _ = try read(current)
    } catch {
      let data = try encode([])
      try writeAndConfirm(data)
      return snapshot(
        identity: previous.identity, revision: WindowsGraphicsPreferenceRevision(.data(data)))
    }
    throw Self.failure("Remembered graphics settings changed. Cancel and reopen Graphics Settings.")
  }

  private func snapshot(
    identity: WindowsGraphicsPreferenceIdentity, revision: WindowsGraphicsPreferenceRevision?,
    settings: WindowsGraphicsSettings? = nil, isRemembered: Bool = false,
    issue: WindowsGraphicsPreferenceIssue? = nil
  ) -> WindowsGraphicsPreferenceSnapshot {
    WindowsGraphicsPreferenceSnapshot(
      settings: settings ?? WindowsGraphicsSettings(), isRemembered: isRemembered, issue: issue,
      identity: identity, revision: revision, storeID: id)
  }

  private func requireCurrent(_ previous: WindowsGraphicsPreferenceSnapshot) throws
    -> WindowsGraphicsPreferencesValue
  {
    guard previous.storeID == id, let revision = previous.revision else {
      throw Self.failure(
        "Remembered graphics settings changed. Cancel and reopen Graphics Settings.")
    }
    let value: WindowsGraphicsPreferencesValue
    do { value = try preferences.read() } catch {
      throw Self.failure("Remembered graphics settings could not be read. Try again.")
    }
    guard WindowsGraphicsPreferenceRevision(value) == revision else {
      throw Self.failure(
        "Remembered graphics settings changed. Cancel and reopen Graphics Settings.")
    }
    return value
  }

  private func read(_ value: WindowsGraphicsPreferencesValue) throws -> Document {
    switch value {
    case .missing: return Document(schemaVersion: 1, entries: [])
    case .invalidType: throw WindowsGraphicsPreferenceIssue.invalidValueType
    case .data(let data):
      guard data.count <= Self.maximumBytes else { throw WindowsGraphicsPreferenceIssue.oversized }
      let document: Document
      do { document = try JSONDecoder().decode(Document.self, from: data) } catch {
        throw WindowsGraphicsPreferenceIssue.invalidData
      }
      guard document.schemaVersion == 1 else {
        throw WindowsGraphicsPreferenceIssue.unsupportedSchema
      }
      guard document.entries.count <= Self.maximumEntries else {
        throw WindowsGraphicsPreferenceIssue.invalidData
      }
      var identities = Set<WindowsGraphicsPreferenceIdentity>()
      for record in document.entries {
        try record.validate()
        guard identities.insert(record.identity).inserted else {
          throw WindowsGraphicsPreferenceIssue.invalidData
        }
      }
      return document
    }
  }

  private func encode(_ entries: [Record]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Document(schemaVersion: 1, entries: entries))
  }

  private func writeAndConfirm(_ data: Data) throws {
    do {
      try preferences.write(data)
      guard try preferences.read() == .data(data) else {
        throw Self.failure("The saved graphics settings could not be confirmed. Try again.")
      }
    } catch {
      throw Self.failure(
        "The graphics settings could not be saved and confirmed. Cancel and reopen Graphics Settings before trying again."
      )
    }
  }

  private static func failure(_ message: String) -> VMError {
    VMError(
      .corruptMetadata, message,
      recovery: "Cancel and reopen Graphics Settings to review the saved choice.")
  }

  private struct Document: Codable {
    let schemaVersion: Int
    let entries: [Record]
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, entries }
    init(schemaVersion: Int, entries: [Record]) {
      self.schemaVersion = schemaVersion
      self.entries = entries
    }
    init(from decoder: any Decoder) throws {
      try WindowsGraphicsPreferenceStore.requireKeys(
        decoder, expected: CodingKeys.allCases.map(\.rawValue))
      let values = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
      entries = try values.decode([Record].self, forKey: .entries)
    }
  }

  private struct Record: Codable {
    let configurationURL: String
    let vmID: UUID
    let mode: String
    let initialWidth: Int
    let initialHeight: Int
    let refreshRate: String
    var identity: WindowsGraphicsPreferenceIdentity {
      // Every decoded record is validated before identity is used in a lookup.
      WindowsGraphicsPreferenceIdentity(configurationURL: configurationURL, vmID: vmID)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
      case configurationURL, vmID, mode, initialWidth, initialHeight, refreshRate
    }
    init(identity: WindowsGraphicsPreferenceIdentity, settings: WindowsGraphicsSettings) {
      configurationURL = identity.configurationURL
      vmID = identity.vmID
      mode = settings.mode == .basic ? "basic" : "accelerated"
      initialWidth = settings.initialWidth
      initialHeight = settings.initialHeight
      refreshRate = settings.refreshRate == .hz60 ? "hz60" : "hz120"
    }
    init(from decoder: any Decoder) throws {
      try WindowsGraphicsPreferenceStore.requireKeys(
        decoder, expected: CodingKeys.allCases.map(\.rawValue))
      let values = try decoder.container(keyedBy: CodingKeys.self)
      configurationURL = try values.decode(String.self, forKey: .configurationURL)
      vmID = try values.decode(UUID.self, forKey: .vmID)
      mode = try values.decode(String.self, forKey: .mode)
      initialWidth = try values.decode(Int.self, forKey: .initialWidth)
      initialHeight = try values.decode(Int.self, forKey: .initialHeight)
      refreshRate = try values.decode(String.self, forKey: .refreshRate)
    }
    func settings() throws -> WindowsGraphicsSettings {
      guard mode == "basic" || mode == "accelerated",
        refreshRate == "hz60" || refreshRate == "hz120"
      else { throw WindowsGraphicsPreferenceIssue.invalidData }
      let result = WindowsGraphicsSettings(
        mode: mode == "basic" ? .basic : .accelerated,
        initialWidth: initialWidth, initialHeight: initialHeight,
        refreshRate: refreshRate == "hz60" ? .hz60 : .hz120)
      let canonical = try result.validatedPreference()
      guard canonical == result else { throw WindowsGraphicsPreferenceIssue.invalidData }
      return canonical
    }
    func validate() throws {
      guard let url = URL(string: configurationURL), url.absoluteString == configurationURL else {
        throw WindowsGraphicsPreferenceIssue.invalidData
      }
      try VMLibraryEntry.validateURL(url)
      _ = try settings()
    }
  }

  private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  nonisolated private static func requireKeys(_ decoder: any Decoder, expected: [String]) throws {
    let values = try decoder.container(keyedBy: AnyKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == Set(expected) else {
      throw WindowsGraphicsPreferenceIssue.invalidData
    }
  }
}
