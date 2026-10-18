// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore

@Suite struct SavedConfigurationValidationTests {
  private let small = HostResources(cpuCount: 4, memoryBytes: 4 << 30)

  @Test func savedAllocationCanExceedCurrentHostWithoutStartAdmission() throws {
    for allocation in [
      (cpu: 12, memory: UInt64(1 << 30)), (cpu: 2, memory: UInt64(24 << 30)),
      (cpu: 12, memory: UInt64(24 << 30)),
    ] {
      let saved = VMConfiguration(
        name: "moved Linux", guest: .linux, backend: .appleVz,
        cpuCount: allocation.cpu, memoryBytes: allocation.memory)
      try ConfigurationValidator.validateSaved(saved)
      #expect(throws: VMError.self) { try ConfigurationValidator.validate(saved, host: small) }
    }
  }

  @Test func savedNumericRepresentationBoundsDoNotBecomeBackendSupportClaims() throws {
    let maximumAlignedMemory = UInt64.max - UInt64.max % 1_048_576
    let saved = VMConfiguration(
      name: "bounded scalar metadata", guest: .linux, backend: .appleVz,
      cpuCount: Int.max, memoryBytes: maximumAlignedMemory)
    let decoded = try ConfigurationCodec.decode(ConfigurationCodec.encode(saved))
    try ConfigurationValidator.validateSaved(decoded)
    #expect(decoded == saved)
    #expect(throws: VMError.self) { try ConfigurationValidator.validate(decoded, host: small) }
  }

  @Test func strictHostArchitectureCheckRemainsUnchanged() throws {
    let saved = VMConfiguration(name: "ARM64", guest: .linux, backend: .appleVz)
    try ConfigurationValidator.validateSaved(saved)
    let intel = HostResources(cpuCount: 8, memoryBytes: 32 << 30, architecture: .x8664)
    #expect(throws: VMError.self) { try ConfigurationValidator.validate(saved, host: intel) }
  }

  @Test(arguments: [
    "schema", "emptyName", "cpuZero", "cpuNegative", "memoryMinimum",
    "memoryAlignment", "diskMinimum", "diskMaximum", "diskPath", "mediaPath", "supportPath",
    "kernelArguments", "directKernelWithoutKernel", "guestArchitecture", "mac",
  ])
  func savedValidationKeepsExistingFormatAndSemanticRejections(kind: String) throws {
    var saved = VMConfiguration(name: "untrusted", guest: .linux, backend: .appleVz)
    switch kind {
    case "schema": saved.schemaVersion = 2
    case "emptyName": saved.name = "  "
    case "cpuZero": saved.cpuCount = 0
    case "cpuNegative": saved.cpuCount = -1
    case "memoryMinimum": saved.memoryBytes = 511 << 20
    case "memoryAlignment": saved.memoryBytes += 1
    case "diskMinimum": saved.diskBytes = (1 << 30) - 1
    case "diskMaximum": saved.diskBytes = (2 << 40) + 1
    case "diskPath": saved.diskFile = "../disk.raw"
    case "mediaPath": saved.installationMedia = "relative.iso"
    case "supportPath": saved.supportMedia = "/private/invalid\n.iso"
    case "kernelArguments": saved.kernelArguments = "argument\0hidden"
    case "directKernelWithoutKernel": saved.boot = .linuxKernel
    case "guestArchitecture": saved.architecture = .x8664
    case "mac": saved.macAddress = "ff:ff:ff:ff:ff:ff"
    default: Issue.record("Unknown fixture")
    }
    #expect(throws: VMError.self) { try ConfigurationValidator.validateSaved(saved) }
    #expect(throws: VMError.self) { try ConfigurationValidator.validate(saved, host: small) }
  }

  @Test(arguments: ["cpuMinimum", "memoryMinimum", "diskMinimum", "backend", "boot"])
  func savedWindowsStillRequiresItsGuestBackendBootAndResourceMinimums(kind: String) throws {
    var saved = VMConfiguration(
      name: "Windows", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    switch kind {
    case "cpuMinimum": saved.cpuCount = 1
    case "memoryMinimum": saved.memoryBytes = 3 << 30
    case "diskMinimum": saved.diskBytes = 63 << 30
    case "backend": saved.backend = .appleVz
    case "boot":
      saved.boot = .linuxKernel
      saved.kernel = "/private/kernel"
    default: Issue.record("Unknown fixture")
    }
    #expect(throws: VMError.self) { try ConfigurationValidator.validateSaved(saved) }
  }

  @Test func strictlyValidConfigurationsRemainValidSavedConfigurations() throws {
    let host = HostResources(cpuCount: 16, memoryBytes: 64 << 30)
    for guest in [GuestOS.linux, .windows11] {
      for cpu in [2, 4, 12] {
        for memory in [UInt64(4 << 30), UInt64(24 << 30)] {
          let c = VMConfiguration(
            name: "strict compatibility", guest: guest,
            backend: guest == .linux ? .appleVz : .qemuHVF,
            cpuCount: cpu, memoryBytes: memory, diskBytes: 64 << 30)
          try ConfigurationValidator.validate(c, host: host)
          try ConfigurationValidator.validateSaved(c)
        }
      }
    }
  }

  @Test func codecStillRejectsUnknownSchemaAndOutOfRangeRepresentations() throws {
    let c = VMConfiguration(name: "codec", guest: .linux, backend: .appleVz)
    let data = try ConfigurationCodec.encode(c)
    for (key, value) in [
      ("schemaVersion", "2"), ("cpuCount", "9223372036854775808"),
      ("memoryBytes", "-1"), ("memoryBytes", "18446744073709551616"),
    ] {
      var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      object[key] = NSNull()
      let placeholder = String(
        decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
      let malformed = placeholder.replacingOccurrences(
        of: "\"\(key)\":null", with: "\"\(key)\":\(value)")
      try #require(malformed != placeholder)
      #expect(throws: VMError.self) { try ConfigurationCodec.decode(Data(malformed.utf8)) }
    }
  }
}
