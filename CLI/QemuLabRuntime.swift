// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Qemu
import VMCore
import VMStorage

/// Explicit diskless integration launcher, never the production Windows launch path.
@MainActor
enum QemuLabRuntime {
  static func run(directory: URL) async throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
      throw LabRuntimeFiles.failure("This exact private runtime requires macOS 27.")
    }
    // This one-command CLI launcher owns its process-wide mask. The application
    // adapter must provide an equivalent child/socket policy before UI adoption.
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    let files = LabRuntimeFiles()
    try await files.validateSelection(directory)
    let vmID = UUID()
    let lock = try VMLock(directory: directory, expectedVMID: vmID)
    let input = try await files.prepare(directory)
    let childLease = try lock.duplicateForInheritance()
    let mapping = [LeaseSpawn.DescriptorMapping(source: childLease.descriptor, target: 200)]
    let qemu = OwnedProcess.Configuration(
      executable: URL(fileURLWithPath: input.qemuArgv[0]),
      arguments: Array(input.qemuArgv.dropFirst())
        + ["-add-fd", "fd=200,set=77,opaque=macopenvm-writer-lease"],
      workingDirectory: directory,
      stdoutLog: directory.appendingPathComponent("swift-qemu-stdout.log"),
      stderrLog: directory.appendingPathComponent("swift-qemu-stderr.log"),
      environment: input.environment, inheritedDescriptors: mapping)
    let tpm = OwnedProcess.Configuration(
      executable: URL(fileURLWithPath: input.swtpmArgv[0]),
      arguments: Array(input.swtpmArgv.dropFirst()),
      workingDirectory: directory,
      stdoutLog: directory.appendingPathComponent("swift-tpm-stdout.log"),
      stderrLog: directory.appendingPathComponent("swift-tpm-stderr.log"),
      environment: input.environment, inheritedDescriptors: mapping)
    let backend = QemuMachineBackend(
      plan: QemuRuntimePlan(
        qemu: qemu, tpm: tpm, qmpSocket: URL(fileURLWithPath: input.qmpSocket),
        tpmSocket: URL(fileURLWithPath: input.tpmSocket)))
    let owner = try await RecordedRuntimeOwner.open(
      in: directory, vmID: vmID, lock: lock, backend: backend)
    let controller = owner.controller
    var states: [String] = []
    controller.onStateChange = { state in
      if states.count < 32 { states.append(state.rawValue) }
    }
    var failure: Error?
    do {
      try await owner.perform(.start)
      let deadline = ContinuousClock.now.advanced(by: .seconds(60))
      var completed = false
      while ContinuousClock.now < deadline {
        if let error = controller.runtimeError { throw error }
        guard backend.isActive else {
          throw LabRuntimeFiles.failure("The EFI process ended early.")
        }
        let data = backend.qemuSnapshot?.stdout ?? Data()
        if try Self.platformCompleted(data) {
          completed = true
          break
        }
        try await Task.sleep(for: .milliseconds(50))
        // Ordinary reads refresh capped stdout without creating per-chunk callbacks.
        await backend.refreshOutput()
      }
      guard completed else {
        throw LabRuntimeFiles.failure("The original EFI probe did not complete.")
      }
      try await owner.perform(.pause)
      guard controller.state == .paused, backend.lastStatus?.status == "paused" else {
        throw LabRuntimeFiles.failure("Pause was not observed.")
      }
      try await Task.sleep(for: .milliseconds(100))
      try await owner.perform(.resume)
      guard controller.state == .running, backend.lastStatus?.running == true else {
        throw LabRuntimeFiles.failure("Resume was not observed.")
      }
      try await owner.perform(.forceStop)
      try await owner.settleOwnership()
    } catch {
      failure = error
      // This command explicitly authorizes cleanup of its new diskless fixture only.
      // It does not change general backend cancellation policy or touch a user guest.
      let recovery = Task { @MainActor [owner, controller, backend] in
        if backend.isActive { try? await owner.perform(.forceStop) }
        try? await controller.settleRuntime()
        if !backend.isActive { try? await owner.settleOwnership() }
      }
      await recovery.value
    }
    guard !backend.isActive else {
      // settleRuntime retains the controller/lease while any runtime child survives.
      try await controller.settleRuntime()
      throw LabRuntimeFiles.failure("The isolated runtime remained active.")
    }
    var preserved = false
    do { preserved = try await files.verifyReadonly(directory) } catch {
      failure = failure ?? error
    }
    let exitedNormally =
      backend.qemuSnapshot?.exit?.status == 0 && backend.tpmSnapshot?.exit?.status == 0
    let drained =
      backend.qemuSnapshot?.drainsFinished == true && backend.tpmSnapshot?.drainsFinished == true
    let passed =
      failure == nil && exitedNormally && drained && preserved
      && owner.ownershipState == .settled
    let result = LabRuntimeResult(
      schemaVersion: 1, status: passed ? "passed" : "failed", states: states,
      qemuExit: backend.qemuSnapshot?.exit?.status, tpmExit: backend.tpmSnapshot?.exit?.status,
      drainsFinished: drained,
      readonlyHashesPreserved: preserved, writerLeaseHeldAtRecord: true,
      runtimeIntentSettled: owner.ownershipState == .settled,
      windowsCompatibilityVerified: false, guestCleanShutdownVerified: false)
    try await files.save(result, at: directory.appendingPathComponent("swift-runtime-result.json"))
    withExtendedLifetime((lock, childLease, owner)) {}
    if let failure { throw failure }
    guard result.qemuExit == 0, result.tpmExit == 0, result.drainsFinished, preserved else {
      throw LabRuntimeFiles.failure("Runtime exit, drain or preservation verification failed.")
    }
    print("macOpenVM Swift QEMU lifecycle passed; Windows compatibility remains unverified.")
  }

  static func platformCompleted(_ data: Data) throws -> Bool {
    guard data.count <= 2_097_152 else {
      throw LabRuntimeFiles.failure("EFI output exceeded its bound.")
    }
    guard let raw = String(data: data, encoding: .utf8) else { return false }
    let output = raw.replacingOccurrences(
      of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression
    )
    .replacingOccurrences(of: "\r", with: "")
    let lines = output.split(separator: "\n").map(String.init)
    guard !lines.contains(where: { $0.contains("mvo.platform-probe.failure=") }) else {
      throw LabRuntimeFiles.failure("The original EFI probe reported a failure.")
    }
    let complete = "mvo.platform-probe.complete setup=1 secure-boot=0"
    guard lines.contains(complete) else { return false }
    let required = [
      "mvo.platform-probe.begin version=1", "mvo.platform-probe.arch=aarch64",
      "mvo.platform-probe.setup status=Success value=1",
      "mvo.platform-probe.secure-boot status=Success value=0", complete,
    ]
    let prefixes = [
      "mvo.platform-probe.begin ", "mvo.platform-probe.arch=",
      "mvo.platform-probe.setup ", "mvo.platform-probe.secure-boot ",
      "mvo.platform-probe.complete ",
      "mvo.platform-probe.tcg2 ", "mvo.platform-probe.tpm-public-manufacturer=",
    ]
    guard prefixes.allSatisfy({ prefix in lines.filter({ $0.hasPrefix(prefix) }).count == 1 })
    else {
      throw LabRuntimeFiles.failure("EFI output contains duplicate or contradictory platform rows.")
    }
    guard required.allSatisfy({ expected in lines.filter({ $0 == expected }).count == 1 }),
      let bank = lines.first(where: {
        $0.range(
          of:
            "^mvo\\.platform-probe\\.tcg2 status=Success present=1 active-banks=0x[0-9a-fA-F]{8}$",
          options: .regularExpression) != nil
      }), let bits = UInt32(bank.suffix(8), radix: 16), bits & 2 != 0,
      lines.filter({ $0.hasPrefix("mvo.platform-probe.tcg2 ") }).count == 1,
      lines.filter({
        $0.range(
          of: "^mvo\\.platform-probe\\.tpm-public-manufacturer=0x[0-9a-fA-F]{8}$",
          options: .regularExpression) != nil
      }).count == 1
    else {
      throw LabRuntimeFiles.failure("EFI completion lacks unique actual platform observations.")
    }
    return true
  }
}

struct LabRuntimeInput: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let scope: String
  let qemuArgv: [String]
  let swtpmArgv: [String]
  let environment: [String: String]
  let qmpSocket: String
  let tpmSocket: String
  let guestLaunched: Bool
  let windowsCompatibilityVerified: Bool
}

private struct LabRuntimeResult: Encodable, Sendable {
  let schemaVersion: Int
  let status: String
  let states: [String]
  let qemuExit: Int32?
  let tpmExit: Int32?
  let drainsFinished: Bool
  let readonlyHashesPreserved: Bool
  let writerLeaseHeldAtRecord: Bool
  let runtimeIntentSettled: Bool
  let windowsCompatibilityVerified: Bool
  let guestCleanShutdownVerified: Bool
}

actor LabRuntimeFiles {
  enum Profile: Sendable { case platform, display, windowsInstaller }
  private static let pins: [String: (Int, String)] = [
    "firmware-code-64m.fd": (
      67_108_864, "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532"
    ),
    "efi-media/EFI/BOOT/BOOTAA64.EFI": (
      28_672, "7186d46978eca379293c0d1efb32e1be80082705890e42a1f0d58a2e9c9b92bb"
    ),
    "efi-media/startup.nsh": (
      40, "eca75fc1735b201238b023368f002fab85d1419b7edc809fb4a44178bba77a90"
    ),
  ]

  func validateSelection(_ directory: URL) throws {
    guard directory.isFileURL, directory.path.hasPrefix("/"),
      !directory.path.contains("//"),
      !directory.pathComponents.contains("."), !directory.pathComponents.contains(".."),
      !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      directory.deletingLastPathComponent().lastPathComponent == ".lab",
      directory.lastPathComponent.range(
        of: "^(windows-efi-probe-[0-9]{8}T[0-9]{6}Z-|windows-installer-boot-)[0-9a-f]{32}$",
        options: .regularExpression)
        != nil
    else { throw Self.failure("Select a newly prepared private EFI fixture.") }
    try checkAncestry(directory)
    try checkDirectory(directory)
  }

  func prepare(
    _ directory: URL, profile: Profile = .platform, installationAuthorized: Bool = false
  ) throws -> LabRuntimeInput {
    if profile == .windowsInstaller {
      return try prepareWindowsInstaller(directory, installationAuthorized: installationAuthorized)
    }
    guard !installationAuthorized else {
      throw Self.failure(
        "Installation authorization applies only to a new Windows installer fixture.")
    }
    try validateSelection(directory)
    let result = try JSONSerialization.jsonObject(
      with: read(directory.appendingPathComponent("result.json"), limit: 32_768))
    guard let prepared = result as? [String: Any], prepared["status"] as? String == "prepared",
      prepared["preparedOnly"] as? Bool == true,
      prepared["nativeChildrenLaunched"] as? Bool == false
    else { throw Self.failure("The fixture was not prepared for a new Swift runtime launch.") }
    let input = try JSONDecoder().decode(
      LabRuntimeInput.self,
      from: read(directory.appendingPathComponent("swift-runtime-input.json"), limit: 65_536))
    let scope =
      profile == .platform
      ? "new-owned-offline-no-os-fixture" : "new-owned-offline-no-os-display-fixture"
    guard input.schemaVersion == 1, input.scope == scope,
      !input.guestLaunched, !input.windowsCompatibilityVerified,
      input.qemuArgv.count <= 128, input.swtpmArgv.count <= 32,
      let qemu = input.qemuArgv.first, let tpm = input.swtpmArgv.first,
      input.qmpSocket.hasSuffix("/qmp.sock"), input.tpmSocket.hasSuffix("/tpm.sock")
    else { throw Self.failure("The isolated runtime inputs are invalid.") }
    let short = URL(fileURLWithPath: input.qmpSocket).deletingLastPathComponent()
    guard
      short.path.range(of: "^/private/tmp/mvo-efi-[0-9a-f]{16}$", options: .regularExpression)
        != nil,
      input.qmpSocket == short.appendingPathComponent("qmp.sock").path, short.path.utf8.count < 90,
      input.tpmSocket == short.appendingPathComponent("tpm.sock").path,
      input.environment == [
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C", "TMPDIR": short.path,
      ]
    else { throw Self.failure("The private runtime socket/environment inputs are invalid.") }
    try checkAncestry(short)
    try checkDirectory(short)
    guard try FileManager.default.contentsOfDirectory(atPath: short.path).isEmpty else {
      throw Self.failure("The new runtime socket directory is not empty.")
    }
    var displayData: URL?
    if profile == .display {
      // Exact separately qualified VNC build: reject the earlier VNC-disabled
      // platform binary before TPM or QEMU spawn. This is a private lab gate.
      let platform = directory.deletingLastPathComponent().appendingPathComponent(
        "windows-platform-a77101301bb14ba085a3a6e4b4f070ab")
      let candidate = platform.appendingPathComponent(
        "tools/qemu-vnc-candidate-1b9f04f265434bd08993c175502f5b89")
      guard qemu == candidate.appendingPathComponent("qemu-system-aarch64").path else {
        throw Self.failure("The display fixture requires the qualified VNC candidate.")
      }
      try verify(
        URL(fileURLWithPath: qemu), length: 26_832_496,
        digest: "26674b130d910136b31c7c576277639e8b4c5bc2bc499165acb8f39919e58529",
        mode: 0o500)
      let data = candidate.appendingPathComponent("source/pc-bios")
      try checkAncestry(data)
      try checkDirectory(data)
      let keymaps = data.appendingPathComponent("keymaps")
      try checkAncestry(keymaps)
      try checkDirectory(keymaps)
      try verify(
        keymaps.appendingPathComponent("en-us"), length: 27_086,
        digest: "52cf4c523e686078699ed58761c7e1443080305237a5f67a3716832570c5c8e5",
        mode: 0o600)
      displayData = data
    } else {
      try verify(
        URL(fileURLWithPath: qemu), length: 26_756_880,
        digest: "ed753107501522f937d6293e7119a6a3ee2c5c9b0294e13e1fc0c5671ff0528c",
        mode: nil)
    }
    try verify(
      URL(fileURLWithPath: tpm), length: 72_192,
      digest: "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a", mode: nil)
    let code = directory.appendingPathComponent("firmware-code-64m.fd").path
    let vars = directory.appendingPathComponent("uefi-vars.json").path
    let media = directory.appendingPathComponent("efi-media").path
    let state = directory.appendingPathComponent("tpm-state")
    var expectedQemu = [
      qemu, "-no-user-config", "-nodefaults", "-machine",
      "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off", "-accel", "hvf", "-cpu",
      "host",
      "-smp", "2", "-m", "2048", "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic",
      "none",
      "-qmp", "unix:\(short.path)/qmp.sock,server=on,wait=off", "-drive",
      "if=pflash,unit=0,format=raw,readonly=on,file=\(code)", "-device",
      "uefi-vars-sysbus,jsonfile=\(vars),size=262144,force-secure-boot=off,disable-custom-mode=on",
      "-chardev", "socket,id=chrtpm,path=\(short.path)/tpm.sock", "-tpmdev",
      "emulator,id=tpm0,chardev=chrtpm",
      "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on", "-drive",
      "if=none,id=efimedia,format=raw,readonly=on,file=fat:16:\(media)", "-device",
      "virtio-blk-pci,drive=efimedia,bootindex=1",
    ]
    if profile == .display {
      guard let displayData else { throw Self.failure("Display data was not qualified.") }
      expectedQemu += [
        "-device", "ramfb,id=display0", "-device", "qemu-xhci,id=xhci0",
        "-device", "usb-kbd,id=keyboard0,bus=xhci0.0", "-L", displayData.path, "-k",
        displayData.appendingPathComponent("keymaps/en-us").path,
        "-vnc",
        "unix:\(short.path)/vnc.sock,share=force-shared",
      ]
    }
    let expectedTpm = [
      tpm, "socket", "--tpm2", "--tpmstate", "dir=\(state.path),mode=0600,lock",
      "--ctrl", "type=unixio,path=\(short.path)/tpm.sock,mode=0600,terminate", "--flags",
      "startup-none",
      "--log", "file=-",
    ]
    guard input.qemuArgv == expectedQemu, input.swtpmArgv == expectedTpm,
      !directory.path.contains(","), !directory.path.contains(":"),
      try read(URL(fileURLWithPath: vars), limit: 1).isEmpty
    else { throw Self.failure("Only the original diskless offline runtime recipe is accepted.") }
    try checkDirectory(state)
    guard try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty else {
      throw Self.failure("The new fixture TPM store is not empty.")
    }
    guard try verifyReadonly(directory, profile: profile) else {
      throw Self.failure("The readonly fixture assets differ.")
    }
    try checkMedia(directory.appendingPathComponent("efi-media"))
    try save(
      Data("new-owned-offline-no-os-fixture\n".utf8),
      at: directory.appendingPathComponent("swift-runtime.claim"))
    return input
  }

  /// Narrow approval exception for one preserved Microsoft image and a NEW blank VM.
  /// This never changes the production readiness gate or accepts installer terms.
  private func prepareWindowsInstaller(
    _ directory: URL, installationAuthorized: Bool
  ) throws -> LabRuntimeInput {
    try validateSelection(directory)
    guard directory.lastPathComponent.hasPrefix("windows-installer-boot-") else {
      throw Self.failure("Select a new approved Windows installer fixture.")
    }
    let prepared =
      try JSONSerialization.jsonObject(
        with: read(directory.appendingPathComponent("result.json"), limit: 32_768))
      as? [String: Any]
    let approval =
      try JSONSerialization.jsonObject(
        with: read(directory.appendingPathComponent("recipe.json"), limit: 32_768))
      as? [String: Any]
    guard prepared?["status"] as? String == "prepared",
      prepared?["preparedOnly"] as? Bool == true,
      prepared?["nativeChildrenLaunched"] as? Bool == false,
      approval?["humanApprovedIsolatedBoot"] as? Bool == true,
      approval?["checksumAssociationResolved"] as? Bool == false,
      approval?["licenseAcceptanceAuthorized"] as? Bool == installationAuthorized,
      approval?["credentialsAuthorized"] as? Bool == false
    else { throw Self.failure("The approved installer fixture is not newly prepared.") }
    let input = try JSONDecoder().decode(
      LabRuntimeInput.self,
      from: read(directory.appendingPathComponent("swift-runtime-input.json"), limit: 65_536))
    let short = URL(fileURLWithPath: input.qmpSocket).deletingLastPathComponent()
    guard input.schemaVersion == 1, input.scope == "approved-offline-windows-installer-fixture",
      !input.guestLaunched, !input.windowsCompatibilityVerified,
      short.path.range(of: "^/private/tmp/mvo-win-[0-9a-f]{16}$", options: .regularExpression)
        != nil,
      input.qmpSocket == short.appendingPathComponent("qmp.sock").path,
      input.tpmSocket == short.appendingPathComponent("tpm.sock").path,
      input.environment == [
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C", "TMPDIR": short.path,
      ],
      !directory.path.contains(","), !directory.path.contains(":")
    else { throw Self.failure("The approved installer inputs differ from their fixed scope.") }
    try checkAncestry(short)
    try checkDirectory(short)
    let state = directory.appendingPathComponent("tpm-state")
    try checkDirectory(state)
    guard try FileManager.default.contentsOfDirectory(atPath: short.path).isEmpty,
      try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty,
      try read(directory.appendingPathComponent("uefi-vars.json"), limit: 1).isEmpty
    else { throw Self.failure("The installer fixture has already been used.") }
    let disk = try file(
      directory.appendingPathComponent("blank-nvme.raw"), maximum: 64 * 1_073_741_824)
    defer { close(disk) }
    var diskInfo = stat()
    guard fstat(disk, &diskInfo) == 0, diskInfo.st_size == 64 * 1_073_741_824,
      diskInfo.st_blocks == 0, diskInfo.st_uid == geteuid(), diskInfo.st_mode & 0o777 == 0o600
    else { throw Self.failure("This experiment accepts only a newly empty sparse disk.") }
    let candidate = directory.deletingLastPathComponent().appendingPathComponent(
      "windows-platform-a77101301bb14ba085a3a6e4b4f070ab/tools/qemu-vnc-candidate-1b9f04f265434bd08993c175502f5b89"
    )
    let qemu = candidate.appendingPathComponent("qemu-system-aarch64")
    try checkAncestry(candidate)
    try verify(
      qemu, length: 26_832_496,
      digest: "26674b130d910136b31c7c576277639e8b4c5bc2bc499165acb8f39919e58529", mode: 0o500)
    let data = candidate.appendingPathComponent("source/pc-bios")
    try checkAncestry(data.appendingPathComponent("keymaps"))
    try checkDirectory(data)
    try checkDirectory(data.appendingPathComponent("keymaps"))
    try verify(
      data.appendingPathComponent("keymaps/en-us"), length: 27_086,
      digest: "52cf4c523e686078699ed58761c7e1443080305237a5f67a3716832570c5c8e5", mode: 0o600)
    let tpm = "/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm"
    try verify(
      URL(fileURLWithPath: tpm), length: 72_192,
      digest: "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a", mode: nil)
    let expectedQemu = [
      qemu.path, "-no-user-config", "-nodefaults", "-machine",
      "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off",
      "-accel", "hvf", "-cpu", "host", "-smp", "4", "-m", "6144",
      "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none",
      "-qmp", "unix:\(short.path)/qmp.sock,server=on,wait=off",
      "-drive", "if=pflash,unit=0,format=raw,readonly=on,file=\(directory.path)/firmware-code.fd",
      "-device",
      "uefi-vars-sysbus,jsonfile=\(directory.path)/uefi-vars.json,size=262144,force-secure-boot=off,disable-custom-mode=on",
      "-chardev", "socket,id=chrtpm,path=\(short.path)/tpm.sock",
      "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on",
      "-device", "ramfb,id=display0", "-device", "qemu-xhci,id=xhci0",
      "-device", "usb-kbd,id=keyboard0,bus=xhci0.0", "-device",
      "usb-tablet,id=pointer0,bus=xhci0.0",
      "-drive",
      "if=none,id=installer,format=raw,media=cdrom,readonly=on,file=\(windowsMedia(directory).path)",
      "-device", "usb-storage,drive=installer,bus=xhci0.0,bootindex=1",
      "-drive", "if=none,id=target,format=raw,file=\(directory.path)/blank-nvme.raw",
      "-device", "nvme,drive=target,serial=MVO-NEW-WIN-BOOT",
      "-L", data.path, "-k", data.appendingPathComponent("keymaps/en-us").path,
      "-vnc", "unix:\(short.path)/vnc.sock,share=force-shared",
    ]
    let expectedTpm = [
      tpm, "socket", "--tpm2", "--tpmstate", "dir=\(state.path),mode=0600,lock",
      "--ctrl", "type=unixio,path=\(short.path)/tpm.sock,mode=0600,terminate", "--flags",
      "startup-none", "--log", "file=-",
    ]
    guard input.qemuArgv == expectedQemu, input.swtpmArgv == expectedTpm,
      try verifyWindowsInstallerReadonly(directory)
    else { throw Self.failure("The approved offline installer recipe or assets differ.") }
    try save(
      Data("approved-offline-windows-installer-fixture\n".utf8),
      at: directory.appendingPathComponent("swift-runtime.claim"))
    return input
  }

  private func windowsMedia(_ directory: URL) -> URL {
    directory.deletingLastPathComponent().appendingPathComponent(
      "windows-media-48f5f2b7600e4010b813985fcea79ef8/Windows11_Client_arm64_en-us_26300_9457.iso.partial"
    )
  }

  private func verifyWindowsInstallerReadonly(_ directory: URL) throws -> Bool {
    try verify(
      directory.appendingPathComponent("firmware-code.fd"), length: 67_108_864,
      digest: "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532", mode: 0o400)
    let media = windowsMedia(directory)
    try checkAncestry(media.deletingLastPathComponent())
    try checkDirectory(media.deletingLastPathComponent())
    try verify(
      media, length: 8_528_523_264,
      digest: "8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c", mode: 0o600)
    return true
  }

  func verifyReadonly(_ directory: URL, profile: Profile = .platform) throws -> Bool {
    if profile == .windowsInstaller { return try verifyWindowsInstallerReadonly(directory) }
    var pins = Self.pins
    if profile == .display {
      pins["efi-media/EFI/BOOT/BOOTAA64.EFI"] = (
        32_768, "d98fea5975ef70a5cf87abd756321e5218d6c4154ad5d9d1f9e437a24f0381ff"
      )
    }
    for (path, pin) in pins {
      try verify(directory.appendingPathComponent(path), length: pin.0, digest: pin.1, mode: 0o400)
    }
    return true
  }

  func save<T: Encodable>(_ value: T, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try save(encoder.encode(value), at: url)
  }

  func saveBytes(_ data: Data, at url: URL) throws { try save(data, at: url) }

  private func save(_ data: Data, at url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Self.failure("An exclusive runtime record could not be created.") }
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw Self.failure("A runtime record could not be saved.") }
        offset += count
      }
    }
    guard fsync(fd) == 0 else { throw Self.failure("A runtime record could not be flushed.") }
  }

  func read(_ url: URL, limit: Int) throws -> Data {
    let fd = try file(url, maximum: limit)
    defer { close(fd) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var before = stat()
    guard fstat(fd, &before) == 0 else {
      throw Self.failure("Runtime metadata cannot be inspected.")
    }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(4096, limit - data.count + 1)), !chunk.isEmpty
    {
      data.append(chunk)
      guard data.count <= limit else { throw Self.failure("Runtime metadata exceeded its bound.") }
    }
    var after = stat()
    guard fstat(fd, &after) == 0, before.st_ino == after.st_ino,
      before.st_size == after.st_size, data.count == before.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw Self.failure("Runtime metadata changed during its bounded read.") }
    return data
  }

  func verify(_ url: URL, length: Int, digest: String, mode: mode_t?) throws {
    let fd = try file(url, maximum: length)
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_size == length,
      mode == nil || before.st_mode & 0o777 == mode
    else { throw Self.failure("A runtime asset has unexpected metadata.") }
    var hash = SHA256()
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var total = 0
    while let data = try handle.read(upToCount: min(1_048_576, length - total + 1)), !data.isEmpty {
      total += data.count
      guard total <= length else { throw Self.failure("A runtime asset grew beyond its bound.") }
      hash.update(data: data)
    }
    var after = stat()
    guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
      before.st_size == after.st_size, total == length,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest
    else { throw Self.failure("A pinned runtime asset changed or failed its hash.") }
  }

  private func file(_ url: URL, maximum: Int) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      throw Self.failure("A runtime input path is invalid.")
    }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Self.failure("A runtime input could not be opened safely.") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0,
      info.st_size >= 0, info.st_size <= maximum
    else {
      close(fd)
      throw Self.failure("A runtime input has unsafe metadata.")
    }
    return fd
  }

  func checkDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
    else { throw Self.failure("A runtime directory is not private and owned.") }
  }

  func checkAncestry(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      current.appendPathComponent(component, isDirectory: true)
      var info = stat()
      guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == getuid() || info.st_uid == 0,
        info.st_mode & 0o022 == 0 || current.path == "/private/tmp"
      else { throw Self.failure("A runtime directory ancestor is unsafe.") }
    }
  }

  private func checkMedia(_ directory: URL) throws {
    try checkAncestry(directory)
    try checkDirectory(directory)
    guard
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
        "EFI", "startup.nsh",
      ]
    else {
      throw Self.failure("The EFI media root has unexpected contents.")
    }
    let efi = directory.appendingPathComponent("EFI", isDirectory: true)
    let boot = efi.appendingPathComponent("BOOT", isDirectory: true)
    try checkDirectory(efi)
    try checkDirectory(boot)
    guard try FileManager.default.contentsOfDirectory(atPath: efi.path) == ["BOOT"],
      try FileManager.default.contentsOfDirectory(atPath: boot.path) == ["BOOTAA64.EFI"]
    else { throw Self.failure("The EFI media tree has unexpected contents.") }
  }

  nonisolated static func failure(_ message: String) -> VMError {
    VMError(
      .invalidConfiguration, message,
      recovery: "Prepare a new pinned no-OS fixture; preserve existing files.")
  }
}
