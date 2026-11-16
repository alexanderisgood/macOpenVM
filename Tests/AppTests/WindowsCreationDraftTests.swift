// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct WindowsCreationDraftTests {
  private let host = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
  private func draft() -> WindowsCreationDraft {
    let draft = WindowsCreationDraft(host: host)
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
      first.configuration.cpuCount == 4 && first.configuration.memoryBytes == 8 * 1_073_741_824)
    #expect(first.configuration.diskBytes == 128 * 1_073_741_824)
    #expect(first.destination.path == "/private/tmp/VMs/My Windows VM.macopenvm")
  }
  @Test(arguments: [
    (8, 8, 4, 4), (8, 16, 4, 8), (10, 24, 5, 12),
    (18, 48, 8, 16), (32, 128, 8, 16),
  ])
  func defaultsScaleWithHostCapacity(cpu: Int, ramGiB: Int, expectedCPU: Int, expectedGiB: Int)
    throws
  {
    let host = HostResources(cpuCount: cpu, memoryBytes: UInt64(ramGiB) << 30)
    let draft = WindowsCreationDraft(host: host)
    draft.media = URL(fileURLWithPath: "/private/tmp/windows-arm64.iso")
    draft.parent = URL(fileURLWithPath: "/private/tmp/VMs", isDirectory: true)
    let prepared = try draft.prepared(host: host).configuration
    #expect(prepared.cpuCount == expectedCPU)
    #expect(prepared.memoryBytes == UInt64(expectedGiB) << 30)
    #expect(prepared.cpuCount <= host.cpuCount - 2)
    #expect(prepared.memoryBytes <= host.memoryBytes / 2)
    // Explicit edits remain the next-start values, including an 85 GiB disk.
    draft.cpuCountText = "2"
    draft.memoryGiBText = "4"
    draft.diskGiBText = "85"
    let edited = try draft.prepared(host: host).configuration
    #expect(edited.cpuCount == 2 && edited.memoryBytes == 4 << 30)
    #expect(edited.diskBytes == 85 << 30)
  }

  @Test func insufficientHostsStillRejectRecommendedValues() {
    for host in [
      HostResources(cpuCount: 2, memoryBytes: 8 << 30),
      HostResources(cpuCount: 8, memoryBytes: 4 << 30),
    ] {
      let draft = WindowsCreationDraft(host: host)
      #expect(draft.numericError(host: host) != nil)
    }
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
