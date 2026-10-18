// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Darwin
import Foundation
import Security
import Virtualization

public struct HostReport: Codable, Sendable {
  public struct Display: Codable, Sendable {
    public let widthPoints: Double
    public let heightPoints: Double
    public let availableWidthPoints: Double
    public let availableHeightPoints: Double
    public let backingScale: Double
  }
  public let schemaVersion: Int
  public let architecture: String
  public let model: String?
  public let osVersion: String
  public let osBuild: String?
  public let memoryBytes: UInt64
  public let cpuCount: Int
  public let virtualizationSupported: Bool
  public let virtualizationEntitled: Bool
  public let minimumCPU: Int
  public let maximumCPU: Int
  public let minimumMemory: UInt64
  public let maximumMemory: UInt64
  public let displays: [Display]
  public let limitations: [String]
}

public enum HostProbe {
  @MainActor public static func capture() -> HostReport {
    let resources = HostResources.current
    let entitled = hasVirtualizationEntitlement()
    var limitations = [
      "Windows boot/TPM/graphics and macOS 14 runtime compatibility are unverified.",
      "No performance claim follows from this host probe.",
    ]
    if !entitled {
      limitations.append(
        "Executable lacks com.apple.security.virtualization; use the signed build workflow.")
    }
    return HostReport(
      schemaVersion: 1, architecture: resources.architecture.rawValue,
      model: sysctlString("hw.model"),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      osBuild: sysctlString("kern.osversion"), memoryBytes: resources.memoryBytes,
      cpuCount: resources.cpuCount, virtualizationSupported: VZVirtualMachine.isSupported,
      virtualizationEntitled: entitled,
      minimumCPU: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
      maximumCPU: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
      minimumMemory: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
      maximumMemory: VZVirtualMachineConfiguration.maximumAllowedMemorySize,
      displays: NSScreen.screens.map {
        HostReport.Display(
          widthPoints: $0.frame.width, heightPoints: $0.frame.height,
          availableWidthPoints: $0.visibleFrame.width,
          availableHeightPoints: $0.visibleFrame.height,
          backingScale: $0.backingScaleFactor)
      }, limitations: limitations)
  }

  public static func hasVirtualizationEntitlement() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return false
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let values = information as? [String: Any],
      let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    else { return false }
    return entitlements["com.apple.security.virtualization"] as? Bool == true
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
