// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Only small, private file markers. No runtime resources or process is selected.
private struct DesktopStartupStorageFixture: Sendable {
  let directory: URL
  let configuration: VMConfiguration

  init() async throws {
    directory = URL(
      fileURLWithPath: "/private/tmp/mvo-startup-capacity-\(UUID().uuidString)", isDirectory: true)
    configuration = VMConfiguration(
      name: "Startup storage fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    let files = VMFiles()
    try await files.createDirectory(directory)
    try await files.writeNewMetadata(
      try ConfigurationCodec.encode(configuration),
      at: directory.appendingPathComponent("configuration.json"))
    for name in ["writer.lock", configuration.diskFile, "qemu-platform.json", "uefi-vars.json"] {
      try await files.writeNewMetadata(
        name == "writer.lock" ? Data() : Data("preserved file marker".utf8),
        at: directory.appendingPathComponent(name))
    }
  }

  func contents() throws -> [String: Data] {
    try Dictionary(
      uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path).map {
        ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
      })
  }
  func close() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Suite(.serialized) struct DesktopWindowsStartupStorageTests {
  @Test(arguments: [UInt64(0), WindowsRuntimeStorageAdmission.minimumAvailableBytes - 1])
  func freshLowCapacityRefusesBeforeRunOrIntentCreation(bytes: UInt64) async throws {
    let f = try await DesktopStartupStorageFixture()
    defer { f.close() }
    let before = try f.contents()
    do {
      _ = try await DesktopWindowsRuntime.preflight(
        configuration: f.configuration, in: f.directory,
        storageCapacity: { selected in
          #expect(selected == f.directory)
          return bytes
        })
      Issue.record("Low-capacity App preflight was admitted.")
    } catch let error as VMError {
      #expect(error.code == .storage)
      #expect(error.recovery.contains("4 GiB"))
    }
    #expect(try f.contents() == before)
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory) == nil)
    #expect(await VMFiles().writerStatus(in: f.directory) == .available)
    #expect(
      !FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(".runtime").path))
  }

  @Test func unavailableCapacityRefusesBeforeRunOrIntentCreation() async throws {
    let f = try await DesktopStartupStorageFixture()
    defer { f.close() }
    let before = try f.contents()
    do {
      _ = try await DesktopWindowsRuntime.preflight(
        configuration: f.configuration, in: f.directory,
        storageCapacity: { _ in throw CocoaError(.fileReadUnknown) })
      Issue.record("Unknown-capacity App preflight was admitted.")
    } catch let error as VMError {
      #expect(error.code == .storage)
      #expect(error.message.contains("could not be checked"))
    }
    #expect(try f.contents() == before)
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory) == nil)
    #expect(await VMFiles().writerStatus(in: f.directory) == .available)
  }

  @Test func ampleCapacityCannotBypassExistingUnsettledIntent() async throws {
    let f = try await DesktopStartupStorageFixture()
    defer { f.close() }
    let record: [String: Any] = [
      "schemaVersion": 1, "vmID": f.configuration.id.uuidString,
      "sessionID": UUID().uuidString, "state": "unsettled",
    ]
    try await VMFiles().writeNewMetadata(
      JSONSerialization.data(withJSONObject: record),
      at: f.directory.appendingPathComponent(RuntimeIntent.filename))
    let before = try f.contents()
    await #expect(throws: VMError.self) {
      try await DesktopWindowsRuntime.preflight(
        configuration: f.configuration, in: f.directory,
        storageCapacity: { _ in
          Issue.record("Capacity must not bypass the existing ownership gate.")
          return UInt64.max
        })
    }
    #expect(try f.contents() == before)
    #expect(try await VMFiles().readRuntimeIntent(in: f.directory)?.state == .unsettled)
  }
}
