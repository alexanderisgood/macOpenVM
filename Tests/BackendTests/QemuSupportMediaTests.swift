// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu
import Testing

private func supportMediaPlan(_ configuration: VMConfiguration) throws -> QemuPlan {
  try QemuPlan.linux(
    configuration: configuration, directory: URL(fileURLWithPath: "/vm"),
    executable: URL(fileURLWithPath: "/qemu"), firmwareCode: URL(fileURLWithPath: "/code"),
    firmwareVariables: URL(fileURLWithPath: "/vars"),
    host: HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824))
}

@Test func qemuSupportMediaKeepsSystemAndInstallerDrivesSeparate() throws {
  var configuration = VMConfiguration(name: "Linux", guest: .linux, backend: .qemuHVF)
  configuration.installationMedia = "/install.iso"
  let original = try supportMediaPlan(configuration)
  configuration.supportMedia = "/support,tools.iso"
  let plan = try supportMediaPlan(configuration)
  #expect(Array(plan.arguments.dropLast(4)) == original.arguments)
  #expect(
    Array(plan.arguments.suffix(4)) == [
      "-drive", "if=none,id=support,format=raw,readonly=on,file=/support,,tools.iso",
      "-device", "usb-storage,drive=support",
    ])
  #expect(plan.arguments.contains("if=none,id=install,format=raw,readonly=on,file=/install.iso"))
  #expect(plan.arguments.contains("if=none,id=system,format=raw,cache=none,file=/vm/disk.raw"))
}

@Test func qemuSupportMediaDoesNotEnableWindowsPlanning() throws {
  var configuration = VMConfiguration(
    name: "Windows", guest: .windows11, backend: .qemuHVF,
    diskBytes: 64 * 1_073_741_824)
  configuration.supportMedia = "/support.iso"
  do {
    _ = try supportMediaPlan(configuration)
    Issue.record("A support image must not enable the unverified Windows path.")
  } catch let error as VMError {
    #expect(error.code == .unsupported)
  }
}
