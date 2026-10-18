// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite struct WindowsLaunchReadinessTests {
  private let location = URL(fileURLWithPath: "/private/tmp/Windows.macopenvm/configuration.json")

  @Test func hostEligibilityKeepsTheReviewedArchitectureAndOSBoundary() {
    let required = WindowsLaunchReadiness.minimumHostMajorVersion
    #expect(!WindowsLaunchReadiness.supportsHost(architecture: .arm64, majorVersion: required - 1))
    #expect(WindowsLaunchReadiness.supportsHost(architecture: .arm64, majorVersion: required))
    #expect(WindowsLaunchReadiness.supportsHost(architecture: .arm64, majorVersion: required + 1))
    #expect(!WindowsLaunchReadiness.supportsHost(architecture: .x8664, majorVersion: required + 1))
  }

  @Test func aResultAppliesOnlyToItsCompleteUnownedSelection() {
    let request = request()
    #expect(applies(request))
    #expect(!applies(request, hasOwnedWindowsRuntime: true))
  }

  @Test func missingOrSupersededGenerationCannotEnableStart() {
    let request = request()
    for generation in [UUID?.none, UUID()] {
      #expect(
        !request.canApply(
          generation: generation, selectedURL: location, configuration: request.configuration,
          profile: request.profile, hasOwnedWindowsRuntime: false))
    }
  }

  @Test func identicalNamesAndUUIDsAtAnotherLocationCannotReceiveTheResult() {
    let request = request()
    let other = URL(fileURLWithPath: "/private/tmp/Other/Windows.macopenvm/configuration.json")
    for selectedURL in [URL?.none, other] {
      #expect(
        !request.canApply(
          generation: request.generation, selectedURL: selectedURL,
          configuration: request.configuration, profile: request.profile,
          hasOwnedWindowsRuntime: false))
    }
  }

  @Test func aRemovedOrReplacementConfigurationCannotReceiveTheResult() {
    let request = request()
    var replacement = request.configuration
    replacement.id = UUID()
    for configuration in [VMConfiguration?.none, replacement] {
      #expect(
        !request.canApply(
          generation: request.generation, selectedURL: location, configuration: configuration,
          profile: request.profile, hasOwnedWindowsRuntime: false))
    }
  }

  @Test func changedHardwareMediaNetworkingOrBootSelectionInvalidatesAnOlderCheck() {
    let request = request()
    for field in ["cpu", "memory", "disk", "installation", "support", "network", "boot"] {
      var changed = request.configuration
      switch field {
      case "cpu": changed.cpuCount += 1
      case "memory": changed.memoryBytes += 1 << 30
      case "disk": changed.diskBytes += 1 << 30
      case "installation": changed.installationMedia = "/private/tmp/new-installation.iso"
      case "support": changed.supportMedia = "/private/tmp/new-driver.iso"
      case "network": changed.network = .shared
      default: changed.boot = .linuxKernel
      }
      #expect(
        !request.canApply(
          generation: request.generation, selectedURL: location, configuration: changed,
          profile: request.profile, hasOwnedWindowsRuntime: false))
    }
  }

  @Test(arguments: WindowsLaunchReadinessRequest.Profile.allCases)
  func aGraphicsProfileChangeCannotReuseAnotherProfilesReadiness(
    profile: WindowsLaunchReadinessRequest.Profile
  ) {
    let request = request(profile: profile)
    for other in WindowsLaunchReadinessRequest.Profile.allCases where other != profile {
      #expect(
        !request.canApply(
          generation: request.generation, selectedURL: location,
          configuration: request.configuration, profile: other, hasOwnedWindowsRuntime: false))
    }
    #expect(applies(request))
  }

  private func request(
    profile: WindowsLaunchReadinessRequest.Profile = .basic
  ) -> WindowsLaunchReadinessRequest {
    WindowsLaunchReadinessRequest(
      configurationURL: location,
      configuration: VMConfiguration(
        name: "Windows", guest: .windows11, backend: .qemuHVF, diskBytes: 64 << 30),
      profile: profile)
  }

  private func applies(
    _ request: WindowsLaunchReadinessRequest, hasOwnedWindowsRuntime: Bool = false
  ) -> Bool {
    request.canApply(
      generation: request.generation, selectedURL: request.configurationURL,
      configuration: request.configuration, profile: request.profile,
      hasOwnedWindowsRuntime: hasOwnedWindowsRuntime)
  }
}
