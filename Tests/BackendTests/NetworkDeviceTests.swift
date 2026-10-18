// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Testing
import Virtualization

@testable import AppleVz

@Test(arguments: [NetworkMode.disconnected, .shared])
@MainActor func appleNetworkDevicesMatchSavedModeAndMAC(_ mode: NetworkMode) throws {
  var configuration = VMConfiguration(name: "fixture", guest: .linux, backend: .appleVz)
  configuration.network = mode
  configuration.macAddress = "02:ac:10:20:30:40"

  // Inspect public device configuration only: no VZVirtualMachine or guest is constructed.
  let devices = try AppleVirtualMachine.networkDevices(for: configuration)
  if mode == .disconnected {
    #expect(devices.isEmpty)
  } else {
    #expect(devices.count == 1)
    let network = try #require(devices.first as? VZVirtioNetworkDeviceConfiguration)
    #expect(network.attachment is VZNATNetworkDeviceAttachment)
    #expect(network.macAddress.string == configuration.macAddress)
  }
}

@Test(arguments: [NetworkMode.disconnected, .shared])
@MainActor func appleNetworkDevicesKeepIdentityAfterResourceChanges(_ mode: NetworkMode) throws {
  var configuration = VMConfiguration(name: "fixture", guest: .linux, backend: .appleVz)
  configuration.network = mode
  configuration.macAddress = "02:ab:cd:12:34:56"
  let original = try AppleVirtualMachine.networkDevices(for: configuration)
  configuration.cpuCount += 1
  configuration.memoryBytes += 1_073_741_824
  let updated = try AppleVirtualMachine.networkDevices(for: configuration)

  if mode == .disconnected {
    #expect(original.isEmpty && updated.isEmpty)
  } else {
    #expect(original.count == 1 && updated.count == 1)
    let before = try #require(original.first as? VZVirtioNetworkDeviceConfiguration)
    let after = try #require(updated.first as? VZVirtioNetworkDeviceConfiguration)
    #expect(before.attachment is VZNATNetworkDeviceAttachment)
    #expect(after.attachment is VZNATNetworkDeviceAttachment)
    #expect(before.macAddress.string == "02:ab:cd:12:34:56")
    #expect(after.macAddress.string == before.macAddress.string)
  }
}

@Test @MainActor func appleSharedNetworkRejectsInvalidMAC() {
  var configuration = VMConfiguration(name: "fixture", guest: .linux, backend: .appleVz)
  configuration.network = .shared
  configuration.macAddress = "invalid-mac"

  #expect(
    throws: VMError(
      .invalidConfiguration, "Network identity is invalid.",
      recovery: "Review the saved MAC address.")
  ) {
    try AppleVirtualMachine.networkDevices(for: configuration)
  }
}
