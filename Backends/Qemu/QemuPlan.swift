// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// An inspectable Linux feasibility plan, not proof of Windows compatibility.
public struct QemuPlan: Codable, Equatable, Sendable {
  public let executable: String
  public let arguments: [String]

  public static func linux(
    configuration: VMConfiguration, directory: URL, executable: URL,
    firmwareCode: URL, firmwareVariables: URL, host: HostResources = .current
  ) throws -> QemuPlan {
    try ConfigurationValidator.validate(configuration, host: host)
    guard configuration.guest == .linux, configuration.backend == .qemuHVF,
      configuration.boot == .efi
    else {
      throw VMError(
        .unsupported, "This plan evaluates ARM64 Linux EFI only.",
        recovery: "Windows remains gated by compliant platform and driver verification.")
    }
    var args = [
      "-machine", "virt-11.1,gic-version=3", "-accel", "hvf", "-cpu", "host",
      "-smp", String(configuration.cpuCount), "-m", String(configuration.memoryBytes / 1_048_576),
      "-drive", "if=pflash,format=raw,readonly=on,file=\(escape(firmwareCode.path))",
      "-drive", "if=pflash,format=raw,file=\(escape(firmwareVariables.path))",
      "-drive",
      "if=none,id=system,format=raw,cache=none,file=\(escape(directory.appendingPathComponent(configuration.diskFile).path))",
      "-device", "virtio-blk-pci,drive=system", "-device", "ramfb", "-device", "qemu-xhci",
      "-device", "usb-kbd", "-device", "usb-tablet", "-display", "cocoa", "-nic", "none",
    ]
    if let media = configuration.installationMedia {
      args += [
        "-drive", "if=none,id=install,format=raw,readonly=on,file=\(escape(media))", "-device",
        "usb-storage,drive=install",
      ]
    }
    if let support = configuration.supportMedia {
      args += [
        "-drive", "if=none,id=support,format=raw,readonly=on,file=\(escape(support))", "-device",
        "usb-storage,drive=support",
      ]
    }
    guard configuration.network == .disconnected else {
      throw VMError(
        .unsupported, "This feasibility plan has no verified NAT implementation.",
        recovery: "Select disconnected networking for the experiment.")
    }
    return QemuPlan(executable: executable.path, arguments: args)
  }

  /// QEMU key/value options use comma doubling, never shell interpolation.
  public static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: ",", with: ",,")
  }

  public static func windowsReadiness() throws -> Never {
    throw VMError(
      .unsupported,
      "Windows setup and start through the library are not integrated yet.",
      recovery:
        "The private installation reached first-run setup. Production media, Secure Boot trust, Windows TPM and driver health, networking, cold boot and normal shutdown remain unqualified."
    )
  }
}
