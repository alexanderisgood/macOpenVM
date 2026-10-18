// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

/// Shared only by tests; no UserDefaults domain is read or written.
@MainActor final class MemoryWindowsGraphicsPreferences: WindowsGraphicsPreferences {
  var value = WindowsGraphicsPreferencesValue.missing
  var failReads = false
  var failWrites = false
  var failReadback = false
  var mismatchedReadback = false
  private(set) var writes = 0
  private(set) var reads = 0
  private var pendingReadbackFailure = false

  func read() throws -> WindowsGraphicsPreferencesValue {
    reads += 1
    if pendingReadbackFailure {
      pendingReadbackFailure = false
      throw VMError(
        .storage, "Injected preference readback failure.", recovery: "Test fixture only.")
    }
    if failReads {
      throw VMError(.storage, "Injected preference read failure.", recovery: "Test fixture only.")
    }
    return value
  }

  func write(_ data: Data) throws {
    writes += 1
    if failWrites {
      throw VMError(.storage, "Injected preference write failure.", recovery: "Test fixture only.")
    }
    pendingReadbackFailure = failReadback
    value = .data(mismatchedReadback ? Data("unconfirmed readback".utf8) : data)
  }
}

@MainActor @Suite struct WindowsGraphicsPreferenceStoreTests {
  private let vmID = UUID()
  private let location = URL(fileURLWithPath: "/private/tmp/preference-fixture/configuration.json")

  @Test func freshStoreRoundTripKeepsOnlyDeclarativeValuesAndBasicReplacesAcceleration() throws {
    let memory = MemoryWindowsGraphicsPreferences()
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let initial = try store.load(at: location, vmID: vmID)
    #expect(initial.settings == WindowsGraphicsSettings() && !initial.isRemembered)
    #expect(initial.issue == nil && !initial.canReset && memory.writes == 0)
    let choice = WindowsGraphicsSettings(
      mode: .accelerated, initialWidth: 2560, initialHeight: 1440, refreshRate: .hz120)
    let saved = try store.remember(choice, from: initial)
    #expect(saved.settings == choice && saved.isRemembered && saved.issue == nil)
    let reopened = WindowsGraphicsPreferenceStore(preferences: memory)
    let restored = try reopened.load(at: location, vmID: vmID)
    #expect(restored.settings == choice && restored.isRemembered)
    #expect(try restored.settings.validatedPreference() == choice)
    #expect(throws: VMError.self) { try restored.settings.validated(canUse120: false) }
    let fields = try #require(try entries(memory).first)
    #expect(
      Set(fields.keys) == [
        "configurationURL", "vmID", "mode", "initialWidth", "initialHeight", "refreshRate",
      ])
    #expect(fields["configurationURL"] as? String == location.absoluteString)
    let basic = try reopened.remember(
      WindowsGraphicsSettings(mode: .basic, initialWidth: -1, refreshRate: .hz120), from: restored)
    #expect(basic.settings == WindowsGraphicsSettings() && basic.isRemembered)
    #expect(try entries(memory).count == 1)
  }

  @Test func exactURLAndUUIDBindingsNeverInheritOneAnothersChoices() throws {
    let memory = MemoryWindowsGraphicsPreferences()
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let otherLocation = URL(fileURLWithPath: "/private/tmp/copy/configuration.json")
    let aliasLocation = URL(fileURLWithPath: "/tmp/preference-fixture/configuration.json")
    let choice = WindowsGraphicsSettings(mode: .accelerated)
    _ = try store.remember(choice, from: store.load(at: location, vmID: vmID))
    #expect(try store.load(at: otherLocation, vmID: vmID).settings == WindowsGraphicsSettings())
    #expect(try store.load(at: aliasLocation, vmID: vmID).settings == WindowsGraphicsSettings())
    #expect(try store.load(at: location, vmID: UUID()).settings == WindowsGraphicsSettings())
    let otherChoice = WindowsGraphicsSettings(
      mode: .accelerated, initialWidth: 1280, initialHeight: 720)
    _ = try store.remember(otherChoice, from: store.load(at: otherLocation, vmID: vmID))
    let first = try store.load(at: location, vmID: vmID)
    #expect(first.settings == choice && first.matches(configurationURL: location, vmID: vmID))
    #expect(!first.matches(configurationURL: otherLocation, vmID: vmID))
    #expect(!first.matches(configurationURL: location, vmID: UUID()))
    #expect(try store.load(at: otherLocation, vmID: vmID).settings == otherChoice)
    #expect(try entries(memory).count == 2)
  }

  @Test func staleOrForeignSnapshotsCannotOverwriteAnotherWindowsPreference() throws {
    let memory = MemoryWindowsGraphicsPreferences()
    let first = WindowsGraphicsPreferenceStore(preferences: memory)
    let second = WindowsGraphicsPreferenceStore(preferences: memory)
    let stale = try first.load(at: location, vmID: vmID)
    let current = try second.load(at: location, vmID: vmID)
    _ = try second.remember(WindowsGraphicsSettings(mode: .accelerated), from: current)
    let before = memory.value
    #expect(throws: VMError.self) { try first.remember(WindowsGraphicsSettings(), from: stale) }
    #expect(throws: VMError.self) { try first.remember(WindowsGraphicsSettings(), from: current) }
    #expect(memory.value == before && memory.writes == 1)
    let fresh = try first.load(at: location, vmID: vmID)
    _ = try first.remember(WindowsGraphicsSettings(), from: fresh)
    #expect(try first.load(at: location, vmID: vmID).settings == WindowsGraphicsSettings())
  }

  @Test(arguments: [
    "broken", "future", "duplicate", "unknown-document-key", "unknown-record-key", "mode", "rate",
    "fraction", "overflow", "geometry", "basic-noncanonical", "remote", "relative", "oversized",
    "too-many",
  ])
  func invalidDocumentsFallBackAndArePreservedUntilExplicitReset(kind: String) throws {
    let memory = MemoryWindowsGraphicsPreferences()
    memory.value = .data(try damaged(kind))
    let before = memory.value
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let loaded = try store.load(at: location, vmID: vmID)
    #expect(loaded.settings == WindowsGraphicsSettings() && !loaded.isRemembered)
    #expect(loaded.issue != nil && loaded.canReset && memory.writes == 0)
    #expect(throws: VMError.self) {
      try store.remember(WindowsGraphicsSettings(mode: .accelerated), from: loaded)
    }
    #expect(memory.value == before && memory.writes == 0)
    let repaired = try store.resetAll(from: loaded)
    #expect(repaired.settings == WindowsGraphicsSettings() && !repaired.isRemembered)
    #expect(repaired.issue == nil && !repaired.canReset && memory.writes == 1)
    #expect(try entries(memory).isEmpty)
    _ = try store.remember(WindowsGraphicsSettings(mode: .accelerated), from: repaired)
    #expect(try store.load(at: location, vmID: vmID).isRemembered)
  }

  @Test func staleResetCannotEraseARepairedOrDifferentlyCorruptDocument() throws {
    let memory = MemoryWindowsGraphicsPreferences()
    memory.value = .data(Data("broken".utf8))
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let stale = try store.load(at: location, vmID: vmID)
    memory.value = .data(Data("differently broken".utf8))
    let different = memory.value
    #expect(throws: VMError.self) { try store.resetAll(from: stale) }
    #expect(memory.value == different && memory.writes == 0)
    memory.value = .data(try document([record()]))
    let repaired = memory.value
    #expect(throws: VMError.self) { try store.resetAll(from: stale) }
    #expect(memory.value == repaired && memory.writes == 0)
  }

  @Test func wrongTypeAndReadFailureNeverAuthorizeAResetOrWrite() throws {
    let memory = MemoryWindowsGraphicsPreferences()
    memory.value = .invalidType
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let wrongType = try store.load(at: location, vmID: vmID)
    #expect(wrongType.issue == .invalidValueType && !wrongType.canReset)
    #expect(throws: VMError.self) { try store.resetAll(from: wrongType) }
    #expect(throws: VMError.self) { try store.remember(WindowsGraphicsSettings(), from: wrongType) }
    memory.value = .missing
    memory.failReads = true
    let unreadable = try store.load(at: location, vmID: vmID)
    #expect(unreadable.issue == .unreadable && !unreadable.canReset)
    #expect(throws: VMError.self) { try store.resetAll(from: unreadable) }
    #expect(throws: VMError.self) {
      try store.remember(WindowsGraphicsSettings(), from: unreadable)
    }
    #expect(memory.writes == 0)
  }

  @Test(arguments: ["write", "readback-error", "readback-mismatch"])
  func failedSaveOrResetReturnsNoSuccessorSnapshot(kind: String) throws {
    let memory = MemoryWindowsGraphicsPreferences()
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    let previous = try store.load(at: location, vmID: vmID)
    memory.failWrites = kind == "write"
    memory.failReadback = kind == "readback-error"
    memory.mismatchedReadback = kind == "readback-mismatch"
    #expect(throws: VMError.self) {
      try store.remember(WindowsGraphicsSettings(mode: .accelerated), from: previous)
    }
    #expect(previous.settings == WindowsGraphicsSettings() && !previous.isRemembered)
    if kind != "write" {
      memory.failReadback = false
      #expect(throws: VMError.self) {
        try store.remember(WindowsGraphicsSettings(), from: previous)
      }
    }
    let resetMemory = MemoryWindowsGraphicsPreferences()
    resetMemory.value = .data(Data("bad".utf8))
    let resetStore = WindowsGraphicsPreferenceStore(preferences: resetMemory)
    let corrupt = try resetStore.load(at: location, vmID: vmID)
    resetMemory.failWrites = kind == "write"
    resetMemory.failReadback = kind == "readback-error"
    resetMemory.mismatchedReadback = kind == "readback-mismatch"
    #expect(throws: VMError.self) { try resetStore.resetAll(from: corrupt) }
    #expect(corrupt.issue == .invalidData && corrupt.canReset)
  }

  @Test func recencyAndEncodedBytesStayBoundedWithoutFilesystemAccess() throws {
    let memory = MemoryWindowsGraphicsPreferences()
    let store = WindowsGraphicsPreferenceStore(preferences: memory)
    for index in 0..<55 {
      let url = URL(fileURLWithPath: "/private/tmp/VM\(index)/configuration.json")
      _ = try store.remember(WindowsGraphicsSettings(), from: store.load(at: url, vmID: vmID))
    }
    #expect(try entries(memory).count == 50)
    #expect(
      try store.load(
        at: URL(fileURLWithPath: "/private/tmp/VM0/configuration.json"), vmID: vmID
      ).isRemembered == false)
    for index in 0..<50 {
      let url = URL(
        fileURLWithPath:
          "/private/tmp/\(index)-\(String(repeating: " ", count: 3800))/configuration.json")
      _ = try store.remember(WindowsGraphicsSettings(), from: store.load(at: url, vmID: vmID))
      guard case .data(let data) = memory.value else {
        Issue.record("Missing saved fixture")
        return
      }
      #expect(data.count <= WindowsGraphicsPreferenceStore.maximumBytes)
    }
    #expect(try entries(memory).count < 50)
  }

  private func entries(_ memory: MemoryWindowsGraphicsPreferences) throws -> [[String: Any]] {
    guard case .data(let data) = memory.value else {
      throw WindowsGraphicsPreferenceIssue.invalidData
    }
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["entries"] as? [[String: Any]])
  }

  private func record() -> [String: Any] {
    [
      "configurationURL": location.absoluteString, "vmID": vmID.uuidString,
      "mode": "accelerated", "initialWidth": 1920, "initialHeight": 1080, "refreshRate": "hz60",
    ]
  }

  private func document(_ entries: [[String: Any]], version: Int = 1) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "entries": entries])
  }

  private func damaged(_ kind: String) throws -> Data {
    if kind == "broken" { return Data("broken".utf8) }
    if kind == "oversized" {
      return Data(repeating: 32, count: WindowsGraphicsPreferenceStore.maximumBytes + 1)
    }
    if kind == "future" { return try document([record()], version: 2) }
    if kind == "duplicate" { return try document([record(), record()]) }
    if kind == "too-many" {
      return try document(
        (0..<51).map { index in
          var value = record()
          value["vmID"] = UUID().uuidString
          value["configurationURL"] = "file:///private/tmp/\(index)/configuration.json"
          return value
        })
    }
    if kind == "unknown-document-key" {
      return try JSONSerialization.data(
        withJSONObject: ["schemaVersion": 1, "entries": [record()], "authority": true])
    }
    var value = record()
    switch kind {
    case "unknown-record-key": value["executable"] = "/not/an/admitted/runtime"
    case "mode": value["mode"] = "automatic"
    case "rate": value["refreshRate"] = "hz240"
    case "fraction": value["initialWidth"] = 1920.5
    case "overflow": value["initialWidth"] = 1.0e100
    case "geometry":
      value["initialWidth"] = 8192
      value["initialHeight"] = 8192
    case "basic-noncanonical":
      value["mode"] = "basic"
      value["refreshRate"] = "hz120"
    case "remote": value["configurationURL"] = "https://example.com/configuration.json"
    case "relative": value["configurationURL"] = "configuration.json"
    default: break
    }
    return try document([value])
  }
}
