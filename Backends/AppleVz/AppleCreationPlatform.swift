// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Virtualization

@MainActor public struct AppleCreationPlatform: VMCreationPlatform {
  public let backend = BackendID.appleVz
  public init() {}
  public func validateHost(for c: VMConfiguration) throws {
    guard c.backend == backend, c.guest == .linux, HostResources.current.architecture == .arm64
    else {
      throw VMError(
        .unsupported, "This creation path requires Linux on Apple silicon.",
        recovery: "Review the capability map for other guest paths.")
    }
    guard HostProbe.hasVirtualizationEntitlement() else {
      throw VMError(
        .missingEntitlement, "The application lacks its virtualization entitlement.",
        recovery: "Use the signed development app or CLI from scripts/build.sh.")
    }
    guard VZVirtualMachine.isSupported else {
      throw VMError(
        .unsupported, "Native virtualization is unavailable in this execution environment.",
        recovery: "Review host support before creating a VM.")
    }
    guard c.cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
      c.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
      c.memoryBytes >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
      c.memoryBytes <= VZVirtualMachineConfiguration.maximumAllowedMemorySize
    else {
      throw VMError(
        .invalidConfiguration, "CPU or memory exceeds native backend limits.",
        recovery: "Reduce the allocation to the host's supported range.")
    }
  }
  public func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    try AppleVirtualMachine.createIdentity(at: directory)
    return CreatedPlatformIdentity(files: ["machine-identity.bin", "efi-variables.bin"])
  }
}
