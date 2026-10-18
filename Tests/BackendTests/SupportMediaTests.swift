import BackendAPI
import Foundation
import Testing
import Virtualization

// SPDX-License-Identifier: Apache-2.0
@testable import AppleVz

@Test(arguments: [false, true])
@MainActor func appleSupportMediaUsesReadOnlyUSBAndPreservesPrimaryStorage(_ supportSelected: Bool)
  throws
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let disk = root.appendingPathComponent("disk.raw")
  let install = root.appendingPathComponent("installer.iso")
  let support = root.appendingPathComponent("support.iso")
  // Attachment configuration only: no VZVirtualMachine or guest is constructed.
  for (path, byte) in [(disk, UInt8(0x11)), (install, UInt8(0x22)), (support, UInt8(0x33))] {
    try Data(repeating: byte, count: 4096).write(to: path)
  }
  var configuration = VMConfiguration(name: "fixture", guest: .linux, backend: .appleVz)
  configuration.installationMedia = install.path
  configuration.supportMedia = supportSelected ? support.path : nil
  let before = try Data(contentsOf: support)
  do {
    let devices = try AppleVirtualMachine.storageDevices(for: configuration, in: root)
    #expect(devices.count == (supportSelected ? 3 : 2))
    #expect(devices[0] is VZVirtioBlockDeviceConfiguration)
    #expect(devices.dropFirst().allSatisfy { $0 is VZUSBMassStorageDeviceConfiguration })
    let system = try #require(devices[0].attachment as? VZDiskImageStorageDeviceAttachment)
    let installer = try #require(devices[1].attachment as? VZDiskImageStorageDeviceAttachment)
    #expect(!system.isReadOnly && installer.isReadOnly)
    #expect(system.url == disk && installer.url == install)
    #expect(system.synchronizationMode == .full && system.cachingMode == .automatic)
    if supportSelected {
      let data = try #require(devices[2].attachment as? VZDiskImageStorageDeviceAttachment)
      #expect(data.isReadOnly && data.url == support)
    }
    withExtendedLifetime(devices) {}
  }
  let after = try Data(contentsOf: support)
  #expect(after == before)
}

@Test @MainActor func appleSupportMediaDoesNotReplaceAnAbsentInstaller() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let support = root.appendingPathComponent("support.raw")
  try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("disk.raw"))
  try Data(repeating: 1, count: 4096).write(to: support)
  var configuration = VMConfiguration(name: "fixture", guest: .linux, backend: .appleVz)
  configuration.boot = .linuxKernel
  configuration.kernel = "/fixture-kernel"
  configuration.supportMedia = support.path
  do {
    let devices = try AppleVirtualMachine.storageDevices(for: configuration, in: root)
    #expect(devices.count == 2 && devices[0] is VZVirtioBlockDeviceConfiguration)
    #expect(devices[1] is VZUSBMassStorageDeviceConfiguration)
    let data = try #require(devices[1].attachment as? VZDiskImageStorageDeviceAttachment)
    #expect(data.isReadOnly && data.url == support)
    withExtendedLifetime(devices) {}
  }
}
