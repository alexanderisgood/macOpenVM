// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct WindowsCreationDraftTests {
  private let host = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
  private func draft() -> WindowsCreationDraft {
    let draft = WindowsCreationDraft()
    draft.media = URL(fileURLWithPath: "/private/tmp/windows-arm64.iso")
    draft.parent = URL(fileURLWithPath: "/private/tmp/VMs", isDirectory: true)
    return draft
  }
  @Test func preparesFreshNormalOfflineIdentityAndDestination() throws {
    let draft = draft()
    draft.name = "  My Windows VM  "
    let first = try draft.prepared(host: host)
    let second = try draft.prepared(host: host)
    #expect(first.configuration.id != second.configuration.id)
    #expect(first.configuration.name == "My Windows VM")
    #expect(first.configuration.guest == .windows11 && first.configuration.backend == .qemuHVF)
    #expect(first.configuration.architecture == .arm64 && first.configuration.boot == .efi)
    #expect(first.configuration.network == .disconnected && first.configuration.supportMedia == nil)
    #expect(first.configuration.kernel == nil && first.configuration.initialRamdisk == nil)
    #expect(first.configuration.installationMedia == "/private/tmp/windows-arm64.iso")
    #expect(
      first.configuration.cpuCount == 2 && first.configuration.memoryBytes == 4 * 1_073_741_824)
    #expect(first.configuration.diskBytes == 64 * 1_073_741_824)
    #expect(first.destination.path == "/private/tmp/VMs/My Windows VM.macopenvm")
  }
  @Test func invalidSelectionsAndPathComponentsCannotPrepareAConfiguration() {
    for fault in ["media", "parent", "remote", "name", "control", "parent-traversal"] {
      let draft = draft()
      switch fault {
      case "media": draft.media = nil
      case "parent": draft.parent = nil
      case "remote": draft.media = URL(string: "https://example.invalid/windows.iso")
      case "name": draft.name = "../other"
      case "control": draft.name = "Windows\u{0}VM"
      default: draft.parent = URL(fileURLWithPath: "/private/tmp/VMs/../other")
      }
      #expect(throws: VMError.self) { try draft.prepared(host: host) }
    }
  }
  @Test func signedBoundsAndHostReservesRejectBeforeUnsignedConversion() {
    for fault in [
      "cpu-min", "cpu-reserve", "memory-min", "memory-negative", "memory-reserve", "disk-min",
      "disk-negative", "disk-max",
    ] {
      let draft = draft()
      switch fault {
      case "cpu-min": draft.cpuCountText = "1"
      case "cpu-reserve": draft.cpuCountText = "7"
      case "memory-min": draft.memoryGiBText = "3"
      case "memory-negative": draft.memoryGiBText = "-1"
      case "memory-reserve": draft.memoryGiBText = "9"
      case "disk-min": draft.diskGiBText = "63"
      case "disk-negative": draft.diskGiBText = "-1"
      default: draft.diskGiBText = String(Int.max)
      }
      #expect(throws: VMError.self) { try draft.prepared(host: host) }
    }
  }
}
