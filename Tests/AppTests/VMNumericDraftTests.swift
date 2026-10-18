// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct VMNumericDraftTests {
  private let host = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
  private let invalidEdits = [
    "", "   \n", "letters", "4.5", "-1", "+2", "1e3", "1,024", "2_048", "１２", "٢",
    "2 4", "4\u{0}", "9223372036854775808", String(Int.max) + "0",
    String(repeating: "9", count: 256),
    String(repeating: "0", count: 20) + "4",
  ]

  private func windows() -> WindowsCreationDraft {
    let draft = WindowsCreationDraft()
    draft.media = URL(fileURLWithPath: "/private/tmp/windows-arm64.iso")
    draft.parent = URL(fileURLWithPath: "/private/tmp/VMs", isDirectory: true)
    return draft
  }

  private func linux() -> LinuxCreationDraft {
    let draft = LinuxCreationDraft(host: host)
    draft.media = URL(fileURLWithPath: "/private/tmp/linux-arm64.iso")
    draft.parent = URL(fileURLWithPath: "/private/tmp/VMs", isDirectory: true)
    return draft
  }

  private func configuration(windows: Bool = false) -> VMConfiguration {
    VMConfiguration(
      name: windows ? "Windows VM" : "Linux VM", guest: windows ? .windows11 : .linux,
      backend: windows ? .qemuHVF : .appleVz, diskBytes: 64 * 1_073_741_824)
  }

  @Test func windowsEveryCurrentInvalidEditRejectsPreparationThenCorrectionTakesEffect() throws {
    let fields: [ReferenceWritableKeyPath<WindowsCreationDraft, String>] = [
      \.cpuCountText, \.memoryGiBText, \.diskGiBText,
    ]
    let corrected = ["4", "6", "128"]
    let labels = ["Virtual CPUs", "Memory (GiB)", "Disk capacity (GiB)"]
    for (index, field) in fields.enumerated() {
      for edit in invalidEdits {
        let draft = windows()
        _ = try draft.prepared(host: host)
        draft[keyPath: field] = edit
        #expect(draft.numericError(host: host)?.contains(labels[index]) == true)
        var successfulPreparations = 0
        #expect(throws: VMError.self) {
          _ = try draft.prepared(host: host)
          successfulPreparations += 1
        }
        #expect(successfulPreparations == 0)
        #expect(draft[keyPath: field] == edit)
        draft[keyPath: field] = corrected[index]
        let prepared = try draft.prepared(host: host)
        #expect(draft.numericError(host: host) == nil)
        #expect(prepared.configuration.cpuCount == (index == 0 ? 4 : 2))
        #expect(prepared.configuration.memoryBytes == UInt64(index == 1 ? 6 : 4) << 30)
        #expect(prepared.configuration.diskBytes == UInt64(index == 2 ? 128 : 64) << 30)
        #expect(prepared.configuration.network == .disconnected)
      }
    }
  }

  @Test func linuxEveryCurrentInvalidEditRejectsPreparationThenCorrectionTakesEffect() throws {
    let fields: [ReferenceWritableKeyPath<LinuxCreationDraft, String>] = [
      \.cpuCountText, \.memoryGiBText, \.diskGiBText,
    ]
    let corrected = ["4", "6", "128"]
    let labels = ["Virtual CPUs", "Memory (GiB)", "Disk capacity (GiB)"]
    for (index, field) in fields.enumerated() {
      for edit in invalidEdits {
        let draft = linux()
        _ = try draft.prepared(host: host)
        draft[keyPath: field] = edit
        #expect(draft.numericError(host: host)?.contains(labels[index]) == true)
        var successfulPreparations = 0
        #expect(throws: VMError.self) {
          _ = try draft.prepared(host: host)
          successfulPreparations += 1
        }
        #expect(successfulPreparations == 0)
        #expect(draft[keyPath: field] == edit)
        draft[keyPath: field] = corrected[index]
        let prepared = try draft.prepared(host: host)
        #expect(draft.numericError(host: host) == nil)
        #expect(prepared.configuration.cpuCount == (index == 0 ? 4 : 2))
        #expect(prepared.configuration.memoryBytes == UInt64(index == 1 ? 6 : 4) << 30)
        #expect(prepared.configuration.diskBytes == UInt64(index == 2 ? 128 : 32) << 30)
        #expect(prepared.configuration.network == .disconnected)
      }
    }
  }

  @Test func hardwareCurrentInvalidEditsCannotReturnThePreviousValidAllocation() throws {
    let fields: [ReferenceWritableKeyPath<HardwareSettingsDraft, String>] = [
      \.cpuCountText, \.memoryMiBText,
    ]
    let labels = ["Virtual CPUs", "Memory (MiB)"]
    for (index, field) in fields.enumerated() {
      for edit in invalidEdits {
        let original = configuration()
        let draft = HardwareSettingsDraft(configuration: original)
        _ = try draft.prepared(host: host)
        draft[keyPath: field] = edit
        #expect(draft.numericError(host: host)?.contains(labels[index]) == true)
        var successfulPreparations = 0
        #expect(throws: VMError.self) {
          _ = try draft.prepared(host: host)
          successfulPreparations += 1
        }
        #expect(successfulPreparations == 0)
        draft[keyPath: field] = index == 0 ? "4" : "6144"
        let prepared = try draft.prepared(host: host)
        #expect(prepared.cpuCount == (index == 0 ? 4 : 2))
        #expect(prepared.memoryBytes == UInt64(index == 1 ? 6144 : 4096) << 20)
        #expect(original.cpuCount == 2 && original.memoryBytes == 4 << 30)
      }
    }
  }

  @Test func boundariesHostReservesAndWindowsMinimumsRemainAuthoritative() throws {
    let windows = windows()
    windows.cpuCountText = "6"
    windows.memoryGiBText = "8"
    windows.diskGiBText = "2048"
    let largest = try windows.prepared(host: host).configuration
    #expect(largest.cpuCount == 6 && largest.memoryBytes == 8 << 30)
    #expect(largest.diskBytes == 2048 << 30)
    let invalidWindows: [(ReferenceWritableKeyPath<WindowsCreationDraft, String>, String)] = [
      (\.cpuCountText, "1"), (\.cpuCountText, "7"),
      (\.memoryGiBText, "3"), (\.memoryGiBText, "9"),
      (\.diskGiBText, "63"), (\.diskGiBText, "2049"),
    ]
    for (field, invalid) in invalidWindows {
      let draft = self.windows()
      draft[keyPath: field] = invalid
      #expect(throws: VMError.self) { try draft.prepared(host: host) }
    }
    let linux = linux()
    linux.cpuCountText = "1"
    linux.memoryGiBText = "1"
    linux.diskGiBText = "1"
    let smallest = try linux.prepared(host: host).configuration
    #expect(smallest.cpuCount == 1 && smallest.memoryBytes == 1 << 30)
    #expect(smallest.diskBytes == 1 << 30)
    let invalidLinux: [(ReferenceWritableKeyPath<LinuxCreationDraft, String>, String)] = [
      (\.cpuCountText, "0"), (\.cpuCountText, "7"),
      (\.memoryGiBText, "0"), (\.memoryGiBText, "9"),
      (\.diskGiBText, "0"), (\.diskGiBText, "2049"),
    ]
    for (field, invalid) in invalidLinux {
      let draft = self.linux()
      draft[keyPath: field] = invalid
      #expect(throws: VMError.self) { try draft.prepared(host: host) }
    }
    let hardware = HardwareSettingsDraft(configuration: configuration())
    hardware.cpuCountText = "1"
    hardware.memoryMiBText = "512"
    #expect(try hardware.prepared(host: host).memoryBytes == 512 << 20)
    hardware.memoryMiBText = "8192"
    #expect(try hardware.prepared(host: host).memoryBytes == 8 << 30)
    for memory in ["511", "8193"] {
      hardware.memoryMiBText = memory
      #expect(throws: VMError.self) { try hardware.prepared(host: host) }
    }
    hardware.memoryMiBText = "4096"
    for cpu in ["0", "7"] {
      hardware.cpuCountText = cpu
      #expect(throws: VMError.self) { try hardware.prepared(host: host) }
    }
    let windowsHardware = HardwareSettingsDraft(configuration: configuration(windows: true))
    windowsHardware.cpuCountText = "1"
    #expect(throws: VMError.self) { try windowsHardware.prepared(host: host) }
    windowsHardware.cpuCountText = "2"
    windowsHardware.memoryMiBText = "4095"
    #expect(throws: VMError.self) { try windowsHardware.prepared(host: host) }
    windowsHardware.memoryMiBText = "4096"
    #expect(try windowsHardware.prepared(host: host).memoryBytes == 4 << 30)
  }

  @Test func creationFormCeilingsAndWholeEditWorkBoundsRemainFinite() throws {
    let largeHost = HostResources(cpuCount: 32, memoryBytes: 4096 << 30)
    let windows = windows()
    let linux = linux()
    windows.memoryGiBText = "1024"
    linux.memoryGiBText = "1024"
    #expect(try windows.prepared(host: largeHost).configuration.memoryBytes == 1024 << 30)
    #expect(try linux.prepared(host: largeHost).configuration.memoryBytes == 1024 << 30)
    windows.memoryGiBText = "1025"
    linux.memoryGiBText = "1025"
    #expect(throws: VMError.self) { try windows.prepared(host: largeHost) }
    #expect(throws: VMError.self) { try linux.prepared(host: largeHost) }
    windows.memoryGiBText = "4"
    windows.cpuCountText = String(repeating: " ", count: 127) + "2"
    #expect(try windows.prepared(host: host).configuration.cpuCount == 2)
    windows.cpuCountText = String(repeating: " ", count: 128) + "2"
    #expect(throws: VMError.self) { try windows.prepared(host: host) }
    windows.cpuCountText = "2"
    #expect(try windows.prepared(host: host).configuration.cpuCount == 2)
  }

  @Test func trimmedDecimalEditsAndLinuxDefaultsKeepIntendedConfigurationSemantics() throws {
    let draft = linux()
    #expect(draft.cpuCountText == "2" && draft.memoryGiBText == "4" && draft.diskGiBText == "32")
    draft.name = "  My Linux VM  "
    draft.cpuCountText = " \t0004\n"
    draft.memoryGiBText = "\u{a0}6\u{a0}"
    draft.diskGiBText = " 128 "
    let first = try draft.prepared(host: host)
    let second = try draft.prepared(host: host)
    #expect(first.configuration.id != second.configuration.id)
    #expect(first.configuration.name == "My Linux VM")
    #expect(first.configuration.backend == .appleVz && first.configuration.guest == .linux)
    #expect(first.configuration.boot == .efi && first.configuration.architecture == .arm64)
    #expect(first.configuration.cpuCount == 4 && first.configuration.memoryBytes == 6 << 30)
    #expect(first.configuration.diskBytes == 128 << 30)
    #expect(first.configuration.network == .disconnected)
    #expect(first.configuration.installationMedia == "/private/tmp/linux-arm64.iso")
    #expect(first.configuration.supportMedia == nil && first.configuration.kernel == nil)
    #expect(first.destination.path == "/private/tmp/VMs/My Linux VM.macopenvm")
    draft.sharedNetwork = true
    #expect(try draft.prepared(host: host).configuration.network == .shared)
    let smallHost = HostResources(cpuCount: 2, memoryBytes: 4 << 30)
    let small = LinuxCreationDraft(host: smallHost)
    #expect(small.cpuCountText == "1" && small.memoryGiBText == "2")
    let insufficient = HostResources(cpuCount: 2, memoryBytes: 4 << 30)
    #expect(throws: VMError.self) { try windows().prepared(host: insufficient) }
  }

  @Test func invalidDiskEditsHaveNoPreviousTargetButKeepTheHostCapacityReading() async throws {
    let advisor = CreationStorageAdvisor(provider: { _ in 8 << 30 })
    let windows = windows()
    let linux = linux()
    await advisor.refresh(parent: windows.parent)
    #expect(advisor.growthDeficit(diskGiB: try #require(windows.parsedDiskGiB)) == 56 << 30)
    for edit in invalidEdits + ["0", "2049"] {
      windows.diskGiBText = edit
      linux.diskGiBText = edit
      #expect(windows.parsedDiskGiB == nil && linux.parsedDiskGiB == nil)
      #expect(advisor.growthDeficit(diskGiB: windows.parsedDiskGiB ?? 0) == nil)
      #expect(advisor.growthDeficit(diskGiB: linux.parsedDiskGiB ?? 0) == nil)
      #expect(advisor.reading == .available(8 << 30) && advisor.canCreate(in: windows.parent))
      #expect(throws: VMError.self) { try windows.prepared(host: host) }
      #expect(throws: VMError.self) { try linux.prepared(host: host) }
    }
    windows.diskGiBText = "128"
    linux.diskGiBText = "16"
    #expect(advisor.growthDeficit(diskGiB: try #require(windows.parsedDiskGiB)) == 120 << 30)
    #expect(advisor.growthDeficit(diskGiB: try #require(linux.parsedDiskGiB)) == 8 << 30)
    #expect(try windows.prepared(host: host).configuration.diskBytes == 128 << 30)
    #expect(try linux.prepared(host: host).configuration.diskBytes == 16 << 30)
  }

  @Test func invalidSelectionsAndUnsupportedConfigurationsDoNotProducePreparedValues() {
    for invalid in ["media", "parent", "remote", "name", "control", "parent-traversal"] {
      let draft = linux()
      switch invalid {
      case "media": draft.media = nil
      case "parent": draft.parent = nil
      case "remote": draft.media = URL(string: "https://example.invalid/linux.iso")
      case "name": draft.name = "../other"
      case "control": draft.name = "Linux\u{0}VM"
      default: draft.parent = URL(fileURLWithPath: "/private/tmp/VMs/../other")
      }
      #expect(throws: VMError.self) { try draft.prepared(host: host) }
    }
    var invalid = configuration()
    invalid.architecture = .x8664
    let draft = HardwareSettingsDraft(configuration: invalid)
    #expect(throws: VMError.self) { try draft.prepared(host: host) }
  }
}
