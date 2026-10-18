// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@Suite struct LibraryNetworkAppQualificationTests {
  private let directory =
    "/private/tmp/mvo-library-network-0123456789abcdef0123456789abcdef/Library Network.macopenvm"
  private let id = UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
  private var arguments: [String] {
    [
      "app", LibraryNetworkAppQualificationRequest.flag, "--run", "--directory", directory,
      "--expected-vm", id.uuidString, "--output-directory",
      "/private/tmp/mvo-library-network-0123456789abcdef0123456789abcdef/evidence",
    ]
  }
  private let environment = ["MVO_LIBRARY_NETWORK_APP_QUALIFICATION": "1"]

  @Test func explicitClosedRequestBindsDirectoryIdentityAndEvidence() throws {
    let request = try #require(
      try LibraryNetworkAppQualificationRequest.parse(
        arguments: arguments, environment: environment))
    #expect(request.directory.path == directory && request.vmID == id)
    #expect(request.outputDirectory.path == arguments[8])
    #expect(
      try LibraryNetworkAppQualificationRequest.parse(arguments: ["app"], environment: environment)
        == nil)
    var faults: [[String]] = [arguments + ["--extra"], Array(arguments.dropLast())]
    for index in [2, 3, 5, 7] {
      var changed = arguments
      changed[index] = "--other"
      faults.append(changed)
    }
    for value in [
      "/tmp/public",
      directory.replacingOccurrences(of: "0123456789abcdef", with: "0123456789abcdeF"),
      directory + "/",
    ] {
      var changed = arguments
      changed[4] = value
      faults.append(changed)
    }
    for value in ["bad", "00000000-0000-0000-0000-000000000000", id.uuidString.lowercased()] {
      var changed = arguments
      changed[6] = value
      faults.append(changed)
    }
    var changed = arguments
    changed[8] = "/private/tmp/mvo-library-network-ffffffffffffffffffffffffffffffff/evidence"
    faults.append(changed)
    faults.append(arguments + [RegisteredWindowsAppQualificationRequest.flag])
    for fault in faults {
      #expect(throws: VMError.self) {
        try LibraryNetworkAppQualificationRequest.parse(arguments: fault, environment: environment)
      }
    }
    #expect(throws: VMError.self) {
      try LibraryNetworkAppQualificationRequest.parse(arguments: arguments, environment: [:])
    }
  }

  @Test func freshFixtureAdmissionRefusesBootMediaNetworkingAndForeignIdentity() throws {
    let original = VMConfiguration(
      name: "Library Network", guest: .linux, backend: .appleVz, id: id)
    try LibraryNetworkQualificationAdmission.validate(original, expectedID: id)
    for fault in [
      "id", "name", "guest", "backend", "architecture", "boot", "network", "installation",
      "support", "kernel", "ramdisk",
    ] {
      var changed = original
      switch fault {
      case "id": changed.id = UUID()
      case "name": changed.name = "Existing guest"
      case "guest": changed.guest = .windows11
      case "backend": changed.backend = .qemuHVF
      case "architecture": changed.architecture = .x8664
      case "boot": changed.boot = .linuxKernel
      case "network": changed.network = .shared
      case "installation": changed.installationMedia = "/private/tmp/public.iso"
      case "support": changed.supportMedia = "/private/tmp/public.iso"
      case "kernel": changed.kernel = "/private/tmp/kernel"
      default: changed.initialRamdisk = "/private/tmp/ramdisk"
      }
      #expect(throws: VMError.self) {
        try LibraryNetworkQualificationAdmission.validate(changed, expectedID: id)
      }
    }
  }

  @MainActor @Test func qualificationLibraryPreferencesStayInMemory() throws {
    let preferences = LibraryNetworkQualificationPreferences()
    #expect(try preferences.read() == nil)
    let bytes = Data([1, 2, 3])
    try preferences.write(bytes)
    #expect(try preferences.read() == bytes)
    #expect(try LibraryNetworkQualificationPreferences().read() == nil)
  }

  @Test func freshSnapshotRefusesRuntimeMembersAndHeldWriter() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
      "mvo-library-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = VMConfiguration(
      name: "Library Network", guest: .linux, backend: .appleVz, diskBytes: 1 << 30, id: id)
    for name in ["configuration.json", "machine-identity.bin", "efi-variables.bin", "writer.lock"] {
      let url = root.appendingPathComponent(name)
      try Data([1]).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    let disk = root.appendingPathComponent(configuration.diskFile)
    #expect(
      FileManager.default.createFile(
        atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600]))
    let file = try FileHandle(forWritingTo: disk)
    try file.truncate(atOffset: configuration.diskBytes)
    try file.close()
    let first = try LibraryNetworkQualificationAdmission.snapshot(
      in: root, configuration: configuration)
    #expect(first[configuration.diskFile]?.blocks == 0)
    do {
      let owner = try VMLock(directory: root, expectedVMID: id)
      #expect(throws: VMError.self) {
        try LibraryNetworkQualificationAdmission.snapshot(in: root, configuration: configuration)
      }
      withExtendedLifetime(owner) {}
    }
    let runtime = root.appendingPathComponent("runtime.json")
    try Data([1]).write(to: runtime)
    #expect(throws: VMError.self) {
      try LibraryNetworkQualificationAdmission.snapshot(in: root, configuration: configuration)
    }
    try FileManager.default.removeItem(at: runtime)
    try FileManager.default.removeItem(at: root.appendingPathComponent("writer.lock"))
    #expect(throws: VMError.self) {
      try LibraryNetworkQualificationAdmission.snapshot(in: root, configuration: configuration)
    }
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("writer.lock").path))
  }
}
