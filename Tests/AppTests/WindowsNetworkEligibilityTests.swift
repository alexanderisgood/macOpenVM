// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

/// Package-only synthetic permission construction exercises exact-baseline UI
/// admission. These tests perform no native resource verification or networking.
@Suite struct WindowsNetworkEligibilityTests {
  private func windows() -> VMConfiguration {
    VMConfiguration(name: "Public Windows fixture", guest: .windows11, backend: .qemuHVF)
  }

  @Test(arguments: [NetworkMode.disconnected, .shared])
  func nativeLinuxKeepsItsExistingChoicesWithoutPermission(mode: NetworkMode) {
    let configuration = VMConfiguration(
      name: "Public Linux fixture", guest: .linux, backend: .appleVz)
    #expect(NetworkSettingsEligibility.allows(mode, configuration: configuration))
  }

  @Test(arguments: [NetworkMode.disconnected, .shared])
  func windowsNeedsExactPermissionOnlyForSharedChoice(mode: NetworkMode) {
    let configuration = windows()
    #expect(
      NetworkSettingsEligibility.allows(mode, configuration: configuration)
        == (mode == .disconnected))
    let permission = SharedNetworkConfigurationPermission(configuration: configuration)
    #expect(
      NetworkSettingsEligibility.allows(
        mode, configuration: configuration, sharedPermission: permission))
  }

  @Test(arguments: [
    "id", "name", "cpu", "network", "support", "installation", "guest", "backend", "architecture",
    "boot",
  ])
  func staleOrForeignSelectionCannotReusePermission(field: String) {
    let original = windows()
    let permission = SharedNetworkConfigurationPermission(configuration: original)
    var changed = original
    switch field {
    case "id": changed.id = UUID()
    case "name": changed.name = "Another public fixture"
    case "cpu": changed.cpuCount += 1
    case "network": changed.network = .shared
    case "support": changed.supportMedia = "/private/tmp/public-driver.iso"
    case "installation": changed.installationMedia = "/private/tmp/public-install.iso"
    case "guest": changed.guest = .linux
    case "backend": changed.backend = .appleVz
    case "architecture": changed.architecture = .x8664
    default: changed.boot = .linuxKernel
    }
    #expect(
      !NetworkSettingsEligibility.allows(
        .shared, configuration: changed, sharedPermission: permission))
    #expect(
      NetworkSettingsEligibility.allows(
        .disconnected, configuration: changed, sharedPermission: permission))
  }

  @Test(arguments: ["backend", "architecture", "boot", "linux-qemu"])
  func matchingSyntheticPermissionCannotBypassWindowsProfile(field: String) {
    var configuration = windows()
    switch field {
    case "backend": configuration.backend = .appleVz
    case "architecture": configuration.architecture = .x8664
    case "boot": configuration.boot = .linuxKernel
    default: configuration.guest = .linux
    }
    let permission = SharedNetworkConfigurationPermission(configuration: configuration)
    #expect(
      !NetworkSettingsEligibility.allows(
        .shared, configuration: configuration, sharedPermission: permission))
    #expect(NetworkSettingsEligibility.allows(.disconnected, configuration: configuration))
  }
}
