// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Qemu
import VMStorage

/// One new disposable disk, two directly owned firmware processes. This is not
/// a Windows launcher, runtime worker, power-loss test or guest shutdown proof.
@MainActor enum QemuNvmeLab {
  static func run(directory: URL) async throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
      throw nvmeFailure("The pinned NVMe lab requires macOS 27.")
    }
    try Task.checkCancellation()
    var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &coreLimit) == 0 else {
      throw nvmeFailure("The lab core-file limit could not be applied.")
    }
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    let files = NvmeLabFiles()
    // Empty/unqualified payload pins fail before a claim, writer creation or spawn.
    let baseline = try await files.validate(directory)
    let lock = try VMLock(directory: directory, expectedVMID: baseline.input.vmID)
    let lease = try lock.duplicateForInheritance()
    var children: [OwnedProcess] = []
    defer { withExtendedLifetime((lock, lease, children)) {} }
    try await files.claim(directory, baseline: baseline)
    try await files.save(
      NvmeAssetRecord(
        schemaVersion: 1, vmID: baseline.input.vmID,
        preparedMetadataSHA256: baseline.inputSHA256, readonly: baseline.readonly,
        initialDisk: baseline.disk, variableFileIdentity: baseline.variablesIdentity,
        preparationRecord: baseline.preparationRecord),
      at: directory.appendingPathComponent("swift-nvme-assets.json"))
    var phases: [NvmePhaseResult] = []
    var preparedDisk: NvmeDiskProof?
    var preparedVariables: NvmeAsset?
    var failure: Error?
    for phase in NvmePhase.allCases {
      var child: OwnedProcess?
      var monitor: QMPClient?
      var endpoint: NvmeSocketIdentity?
      var completed = false
      var quitAcknowledged = false
      var diskProof: NvmeDiskProof?
      do {
        try Task.checkCancellation()
        guard lock.owns(directory) else { throw nvmeFailure("The writer identity changed.") }
        try await files.beforePhase(
          directory, phase: phase, baseline: baseline, disk: preparedDisk,
          variables: preparedVariables)
        let socket = URL(fileURLWithPath: baseline.input.socketDirectory)
          .appendingPathComponent("\(phase.rawValue)-qmp.sock")
        let arguments = arguments(
          directory, phase: phase, socket: socket,
          payloadData: baseline.payloadData)
        try await files.save(
          NvmeRecipe(
            schemaVersion: 1, phase: phase, vmID: baseline.input.vmID,
            arguments: arguments, leaseDescriptor: 200, qemuFdset: 77),
          at: directory.appendingPathComponent("swift-nvme-\(phase.rawValue)-recipe.json"))
        let process = OwnedProcess(
          configuration: .init(
            executable: URL(fileURLWithPath: baseline.input.qemuExecutable), arguments: arguments,
            workingDirectory: directory,
            stdoutLog: directory.appendingPathComponent("swift-nvme-\(phase.rawValue)-stdout.log"),
            stderrLog: directory.appendingPathComponent("swift-nvme-\(phase.rawValue)-stderr.log"),
            environment: [
              "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C",
              "TMPDIR": baseline.input.socketDirectory,
            ],
            inheritedDescriptors: [.init(source: lease.descriptor, target: 200)]))
        child = process
        children.append(process)  // Retain the owner before the only launch attempt.
        try await process.launch()
        withExtendedLifetime(lease) {}
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while endpoint == nil {
          let state = await process.snapshot()
          guard state.running, state.firstError == nil, ContinuousClock.now < readyDeadline else {
            throw nvmeFailure("The new NVMe process did not expose its private monitor.")
          }
          endpoint = try await files.socket(socket, parent: baseline.socketDirectoryIdentity)
          if endpoint == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        let control = QMPClient(socketURL: socket)
        monitor = control
        try await control.connect()
        guard try await files.socket(socket, parent: baseline.socketDirectoryIdentity) == endpoint,
          try await files.writerBusy(directory, descriptor: lease.descriptor)
        else { throw nvmeFailure("The monitor or inherited writer identity changed.") }
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < completionDeadline {
          let state = await process.snapshot()
          guard state.running, state.firstError == nil else {
            throw nvmeFailure("The NVMe process failed before its complete observations.")
          }
          if try observation(state.stdout, phase: phase) {
            completed = true
            break
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        guard completed, try await control.queryStatus().running else {
          throw nvmeFailure("The exact NVMe observation sequence did not complete.")
        }
        try await control.quit()
        quitAcknowledged = true
        try await awaitInactive(process, seconds: 10)
        let terminal = await process.snapshot()
        guard terminal.exit?.status == 0, terminal.exit?.wasSignalled == false,
          terminal.firstError == nil, terminal.drainsFinished,
          try observation(terminal.stdout, phase: phase),
          try await files.writerBusy(directory, descriptor: lease.descriptor)
        else { throw nvmeFailure("NVMe exit, drains, output or writer custody failed.") }
        diskProof = try await files.scanDisk(directory, payloadData: baseline.payloadData)
        guard let diskProof, diskProof.identity == baseline.disk.identity else {
          throw nvmeFailure("The disposable disk identity or permissions changed.")
        }
        if phase == .verify, diskProof != preparedDisk {
          throw nvmeFailure("The verification process changed the prepared disk.")
        }
        let variables = try await files.variables(directory, baseline: baseline)
        if phase == .prepare {
          preparedDisk = diskProof
          preparedVariables = variables
        }
        try await files.verifyReadonly(directory, baseline: baseline)
        phases.append(
          phaseResult(
            phase, state: terminal, completed: completed,
            quit: quitAcknowledged, fallback: false, disk: diskProof, successful: true))
      } catch {
        failure = error
        if let child {
          // This lab invocation explicitly authorizes cleanup of its registered
          // child. A separate task survives caller cancellation and retains the
          // real child and lease through terminal status plus both completed EOFs.
          let selectedEndpoint = endpoint
          let selectedMonitor = monitor
          let observedCompletion = completed
          let observedQuit = quitAcknowledged
          let observedDisk = diskProof
          let recovery = Task { @MainActor [child, lock, lease, files, baseline] in
            if let selectedMonitor { await selectedMonitor.close() }
            var cleanupQuit = observedQuit
            var fallback = false
            if await child.snapshot().running {
              let socket = URL(fileURLWithPath: baseline.input.socketDirectory)
                .appendingPathComponent("\(phase.rawValue)-qmp.sock")
              let fresh = QMPClient(socketURL: socket)
              do {
                guard
                  let identity = try await files.socket(
                    socket, parent: baseline.socketDirectoryIdentity),
                  selectedEndpoint == nil || selectedEndpoint == identity
                else { throw nvmeFailure("The cleanup monitor identity changed.") }
                try await fresh.connect()
                guard
                  try await files.socket(socket, parent: baseline.socketDirectoryIdentity)
                    == identity
                else {
                  throw nvmeFailure("The cleanup monitor was replaced.")
                }
                try await fresh.quit()
                cleanupQuit = true
                try await awaitInactive(child, seconds: 10)
              } catch {
                await fresh.close()
                if await child.snapshot().running {
                  fallback = true
                  try? await child.terminate()
                }
              }
              await fresh.close()
            }
            await retainUntilInactive(child)
            let state = await child.snapshot()
            withExtendedLifetime((lock, lease, child)) {}
            return phaseResult(
              phase, state: state, completed: observedCompletion,
              quit: cleanupQuit, fallback: fallback, disk: observedDisk, successful: false)
          }
          phases.append(await recovery.value)
        } else if let monitor {
          await monitor.close()
        }
        break  // Never relaunch a phase or advance after an uncertain attempt.
      }
      if let monitor { await monitor.close() }
    }
    var readonlyPreserved = false
    do {
      try await files.verifyReadonly(directory, baseline: baseline)
      readonlyPreserved = true
    } catch { failure = failure ?? error }
    let allInactive = await snapshotsInactive(children)
    let leaseHeld = lock.owns(directory)
    let passed =
      failure == nil && phases.count == 2 && readonlyPreserved && allInactive && leaseHeld
      && phases.allSatisfy { $0.passed }
    let result = NvmeLabResult(
      schemaVersion: 1, status: passed ? "passed" : "failed", vmID: baseline.input.vmID,
      phases: phases, readonlyHashesPreserved: readonlyPreserved,
      allChildrenTerminalAndDrained: allInactive, writerLeaseHeldAtRecord: leaseHeld,
      payloadDataSHA256: nvmeDigest(baseline.payloadData),
      orderlyNvmePersistenceVerified: passed, windowsCompatibilityVerified: false,
      powerLossPersistenceVerified: false, guestCleanShutdownVerified: false,
      failure: failure == nil ? nil : "controlled-nvme-lab-failure")
    // A reporting failure occurs only after actual cleanup; it cannot skip custody.
    try await files.save(result, at: directory.appendingPathComponent("swift-nvme-result.json"))
    withExtendedLifetime((lock, lease, children)) {}
    if let failure { throw failure }
    guard passed else { throw nvmeFailure("The isolated NVMe persistence trial failed.") }
    print("Original NVMe orderly persistence passed; Windows driver loading remains unverified.")
  }

  private static func arguments(
    _ directory: URL, phase: NvmePhase,
    socket: URL, payloadData: Data
  ) -> [String] {
    let eui64 = payloadData[24..<32].map { String(format: "%02x", $0) }.joined()
    let serial = "MVO" + payloadData[8..<16].map { String(format: "%02x", $0) }.joined()
    return [
      "-no-user-config", "-nodefaults", "-machine",
      "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off", "-accel", "hvf",
      "-cpu", "host", "-smp", "2", "-m", "2048", "-display", "none", "-monitor", "none",
      "-serial", "stdio", "-nic", "none", "-qmp", "unix:\(socket.path),server=on,wait=off",
      "-drive",
      "if=pflash,unit=0,format=raw,readonly=on,file=\(directory.path)/firmware-code-64m.fd",
      "-device",
      "uefi-vars-sysbus,jsonfile=\(directory.path)/uefi-vars.json,size=262144,force-secure-boot=off,disable-custom-mode=on",
      "-drive",
      "if=none,id=efimedia,format=raw,readonly=on,file=fat:16:\(directory.path)/\(phase.rawValue)-media",
      "-device", "virtio-blk-pci,drive=efimedia,bootindex=1",
      "-drive", "if=none,id=nvmetest,format=raw,cache=none,file=\(directory.path)/nvme-test.raw",
      "-device", "nvme,id=nvme0,serial=\(serial)",
      "-device",
      "nvme-ns,bus=nvme0,drive=nvmetest,nsid=1,bootindex=2,eui64=0x\(eui64),logical_block_size=512,physical_block_size=512,ms=0,pi=0",
      "-add-fd", "fd=200,set=77,opaque=macopenvm-writer-lease",
    ]
  }

  private static func observation(_ data: Data, phase: NvmePhase) throws -> Bool {
    guard data.count <= 2_097_152 else { throw nvmeFailure("NVMe output exceeded its bound.") }
    guard let raw = String(data: data, encoding: .utf8) else { return false }
    let text = raw.replacingOccurrences(
      of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression
    )
    .replacingOccurrences(of: "\r", with: "")
    var lines = text.components(separatedBy: "\n")
    if !text.hasSuffix("\n") { lines.removeLast() }
    let rows = lines.filter { $0.hasPrefix("mvo.nvme-probe.") }
    guard !rows.contains(where: { $0.hasPrefix("mvo.nvme-probe.failure") }),
      rows.count <= (phase == .prepare ? 14 : 7), rows.allSatisfy({ $0.utf8.count <= 256 })
    else { throw nvmeFailure("NVMe output contains failed or excessive observations.") }
    let complete =
      "mvo.nvme-probe.complete phase=\(phase.rawValue) sectors=3 reads=\(phase == .prepare ? 6 : 3) writes=\(phase == .prepare ? 3 : 0) flushes=\(phase == .prepare ? 1 : 0)"
    guard rows.contains(complete) else { return false }
    guard rows.count >= 3,
      rows[2].range(
        of:
          "^mvo\\.nvme-probe\\.namespace nsid=1 block-size=512 last-block=65535 io-align=(0|1|2|4|8|16|32|64|128|256|512|1024|2048|4096) matches=1$",
        options: .regularExpression) != nil
    else { throw nvmeFailure("NVMe namespace observations are invalid.") }
    var expected = [
      "mvo.nvme-probe.begin version=1 phase=\(phase.rawValue)",
      "mvo.nvme-probe.fixture bytes=64", rows[2],
    ]
    if phase == .prepare {
      expected += nvmeLBAs.map { "mvo.nvme-probe.zero lba=\($0) matched=1" }
      expected += nvmeLBAs.map { "mvo.nvme-probe.write lba=\($0) bytes=512" }
      expected.append("mvo.nvme-probe.flush count=1")
    }
    expected += nvmeLBAs.map {
      "mvo.nvme-probe.readback phase=\(phase.rawValue) lba=\($0) matched=1"
    }
    expected.append(complete)
    guard rows == expected else {
      throw nvmeFailure("NVMe observations are repeated, missing or unordered.")
    }
    return true
  }

  private static func awaitInactive(_ child: OwnedProcess, seconds: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while await child.snapshot().isActive {
      guard ContinuousClock.now < deadline else {
        throw nvmeFailure("Actual NVMe cleanup exceeded its deadline.")
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private static func retainUntilInactive(_ child: OwnedProcess) async {
    if await child.snapshot().started { _ = try? await child.wait() }
    while await child.snapshot().isActive {
      // Lost observation is never transformed into exit or permission to release.
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  private static func snapshotsInactive(_ children: [OwnedProcess]) async -> Bool {
    for child in children {
      let state = await child.snapshot()
      if state.isActive || (state.started && (state.termination == nil || !state.drainsFinished)) {
        return false
      }
    }
    return true
  }

  private static func phaseResult(
    _ phase: NvmePhase, state: OwnedProcess.Snapshot,
    completed: Bool, quit: Bool, fallback: Bool,
    disk: NvmeDiskProof?, successful: Bool
  ) -> NvmePhaseResult {
    let clean =
      state.started && !state.isActive && state.exit?.status == 0
      && state.exit?.wasSignalled == false && state.drainsFinished && state.firstError == nil
    return .init(
      phase: phase, passed: successful && clean && completed && quit && !fallback && disk != nil,
      started: state.started, observationsCompleted: completed, qmpQuitAcknowledged: quit,
      fallbackTerminationRequested: fallback, exitStatus: state.exit?.status,
      wasSignalled: state.exit?.wasSignalled, drainsFinished: state.drainsFinished,
      outputCaptureErrors: state.firstError != nil, disk: disk)
  }
}

private enum NvmePhase: String, Codable, CaseIterable, Sendable { case prepare, verify }
private let nvmeLBAs: [UInt64] = [8, 32_768, 65_535]
private struct NvmePin: Sendable {
  let bytes: Int
  let sha256: String
}
// Root fills both exact qualified original payload pins after the separate module build.
// An empty map is a closed admission gate, never permission to trust fixture-provided hashes.
private let nvmePayloadPins: [NvmePhase: NvmePin] = [
  .prepare: NvmePin(
    bytes: 36_864, sha256: "1028f592387e459c8621edbea76e75dda1886c4933536ed1c865294c907e5335"),
  .verify: NvmePin(
    bytes: 36_864, sha256: "390f049b77e4d67ba1c8fedf830b634080b3a785dbf8f5c86cb3c4729f20f8e6"),
]
private struct NvmePreparedInput: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let scope: String
  let status: String
  let nativeChildrenLaunched: Bool
  let vmID: UUID
  let qemuExecutable: String
  let socketDirectory: String
}
private struct NvmeIdentity: Codable, Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let mode: UInt16
  let owner: UInt32
  let links: UInt64
  let bytes: Int64
  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
    mode = info.st_mode
    owner = info.st_uid
    // New evidence and sockets change directory length. Its anchored identity
    // consists of device/inode/type/mode/owner; regular files retain size/links.
    let directory = info.st_mode & S_IFMT == S_IFDIR
    links = directory ? 0 : UInt64(info.st_nlink)
    bytes = directory ? 0 : info.st_size
  }
}
private struct NvmeAsset: Codable, Equatable, Sendable {
  let path: String
  let identity: NvmeIdentity
  let sha256: String
}
private struct NvmeSocketIdentity: Codable, Equatable, Sendable {
  let parent: NvmeIdentity
  let socket: NvmeIdentity
}
private struct NvmeDiskProof: Codable, Equatable, Sendable {
  let identity: NvmeIdentity
  let sha256: String
  let bytesScanned: Int
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
}
private struct NvmeBaseline: Sendable {
  let input: NvmePreparedInput
  let inputSHA256: String
  let directoryIdentity: NvmeIdentity
  let socketDirectoryIdentity: NvmeIdentity
  let readonly: [NvmeAsset]
  let payloadData: Data
  let disk: NvmeDiskProof
  let variablesIdentity: NvmeIdentity
  let preparationRecord: NvmeAsset
}
private struct NvmeAssetRecord: Codable, Sendable {
  let schemaVersion: Int
  let vmID: UUID
  let preparedMetadataSHA256: String
  let readonly: [NvmeAsset]
  let initialDisk: NvmeDiskProof
  let variableFileIdentity: NvmeIdentity
  let preparationRecord: NvmeAsset
}
private struct NvmeRecipe: Codable, Sendable {
  let schemaVersion: Int
  let phase: NvmePhase
  let vmID: UUID
  let arguments: [String]
  let leaseDescriptor: Int
  let qemuFdset: Int
}
private struct NvmePhaseResult: Codable, Sendable {
  let phase: NvmePhase
  let passed: Bool
  let started: Bool
  let observationsCompleted: Bool
  let qmpQuitAcknowledged: Bool
  let fallbackTerminationRequested: Bool
  let exitStatus: Int32?
  let wasSignalled: Bool?
  let drainsFinished: Bool
  let outputCaptureErrors: Bool
  let disk: NvmeDiskProof?
}
private struct NvmeLabResult: Codable, Sendable {
  let schemaVersion: Int
  let status: String
  let vmID: UUID
  let phases: [NvmePhaseResult]
  let readonlyHashesPreserved: Bool
  let allChildrenTerminalAndDrained: Bool
  let writerLeaseHeldAtRecord: Bool
  let payloadDataSHA256: String
  let orderlyNvmePersistenceVerified: Bool
  let windowsCompatibilityVerified: Bool
  let powerLossPersistenceVerified: Bool
  let guestCleanShutdownVerified: Bool
  let failure: String?
}

/// Bounded file I/O and complete disk scans run on this actor, away from MainActor.
private actor NvmeLabFiles {
  private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()
  private let diskBytes = 33_554_432

  func validate(_ directory: URL) throws -> NvmeBaseline {
    guard nvmePayloadPins.count == 2, NvmePhase.allCases.allSatisfy({ nvmePayloadPins[$0] != nil })
    else {
      throw nvmeFailure("Qualified original NVMe payload pins have not been supplied.")
    }
    try normalized(directory.path)
    guard directory.deletingLastPathComponent().path == root.appendingPathComponent(".lab").path,
      directory.lastPathComponent.range(
        of: "^windows-nvme-probe-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$", options: .regularExpression)
        != nil
    else { throw nvmeFailure("Select only a new original NVMe fixture.") }
    let directoryIdentity = try privateDirectory(directory)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    let required: Set<String> = [
      "nvme-prepared.json", "firmware-code-64m.fd", "nvme-test.raw",
      "uefi-vars.json", "prepare-media", "verify-media", "preparation-record.json",
    ]
    guard names == required || names == required.union(["writer.lock"]) else {
      throw nvmeFailure("The new NVMe fixture has unexpected or previously used entries.")
    }
    let metadata = try read(
      directory.appendingPathComponent("nvme-prepared.json"), maximum: 8192, mode: 0o600
    ).0
    let input = try decodeInput(metadata)
    // This record is preserved provenance, never an authority for argv or pins.
    let preparationPath = directory.appendingPathComponent("preparation-record.json")
    let preparation = try read(preparationPath, maximum: 2048, mode: 0o600)
    let preparationRecord = NvmeAsset(
      path: preparationPath.path, identity: preparation.1,
      sha256: nvmeDigest(preparation.0))
    let expectedQemu = root.appendingPathComponent(
      ".lab/windows-platform-a77101301bb14ba085a3a6e4b4f070ab/tools/qemu-pkcs7-envelope-candidate-158d2cad44c94efbab3e1880329ed8f3/qemu-system-aarch64"
    )
    guard input.schemaVersion == 1, input.scope == "new-owned-offline-no-os-nvme-fixture",
      input.status == "prepared", !input.nativeChildrenLaunched,
      input.qemuExecutable == expectedQemu.path
    else { throw nvmeFailure("NVMe prepared metadata is not qualified.") }
    try normalized(input.socketDirectory)
    guard
      input.socketDirectory.range(
        of: "^/private/tmp/mvo-nvme-[0-9a-f]{16}$", options: .regularExpression) != nil,
      input.socketDirectory.utf8.count + 17 <= 103
    else { throw nvmeFailure("The private socket route is invalid.") }
    let socketDirectory = URL(fileURLWithPath: input.socketDirectory)
    let socketDirectoryIdentity = try privateDirectory(socketDirectory)
    guard try FileManager.default.contentsOfDirectory(atPath: socketDirectory.path).isEmpty else {
      throw nvmeFailure("The new socket directory is not empty.")
    }
    var assets: [NvmeAsset] = []
    let qemu = try read(expectedQemu, maximum: 26_756_880, mode: nil)
    guard qemu.0.count == 26_756_880, qemu.1.mode & 0o111 != 0,
      nvmeDigest(qemu.0) == "ed753107501522f937d6293e7119a6a3ee2c5c9b0294e13e1fc0c5671ff0528c"
    else {
      throw nvmeFailure("The pinned HVF executable changed.")
    }
    assets.append(.init(path: expectedQemu.path, identity: qemu.1, sha256: nvmeDigest(qemu.0)))
    let firmware = directory.appendingPathComponent("firmware-code-64m.fd")
    let code = try read(firmware, maximum: 67_108_864, mode: 0o400)
    guard code.0.count == 67_108_864,
      nvmeDigest(code.0) == "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532"
    else {
      throw nvmeFailure("The pinned read-only firmware changed.")
    }
    assets.append(.init(path: firmware.path, identity: code.1, sha256: nvmeDigest(code.0)))
    var fixtureData: Data?
    for phase in NvmePhase.allCases {
      let media = directory.appendingPathComponent("\(phase.rawValue)-media")
      try mediaTree(media)
      guard let pin = nvmePayloadPins[phase], pin.bytes > 0, pin.bytes <= 131_072,
        pin.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else {
        throw nvmeFailure("A NVMe payload pin is invalid.")
      }
      let payload = media.appendingPathComponent("EFI/BOOT/BOOTAA64.EFI")
      let image = try read(payload, maximum: 131_072, mode: 0o400)
      guard image.0.count == pin.bytes, nvmeDigest(image.0) == pin.sha256 else {
        throw nvmeFailure("The original NVMe payload is unqualified.")
      }
      assets.append(.init(path: payload.path, identity: image.1, sha256: pin.sha256))
      let dataPath = media.appendingPathComponent("MVO-NVME-DATA.BIN")
      let data = try read(dataPath, maximum: 64, mode: 0o400)
      guard data.0.count == 64, data.0.prefix(8) == Data("MVONVME1".utf8),
        data.0[8..<24].contains(where: { $0 != 0 }), data.0[24..<32].contains(where: { $0 != 0 }),
        data.0[32..<64].contains(where: { $0 != 0 }), fixtureData == nil || fixtureData == data.0
      else { throw nvmeFailure("The fixed original NVMe data file is invalid.") }
      fixtureData = data.0
      assets.append(.init(path: dataPath.path, identity: data.1, sha256: nvmeDigest(data.0)))
    }
    let variables = try read(
      directory.appendingPathComponent("uefi-vars.json"), maximum: 0, mode: 0o600)
    guard variables.0.isEmpty,
      let payloadData = fixtureData
    else { throw nvmeFailure("Only a fresh empty variable store is admitted.") }
    let disk = try scanDisk(directory, payloadData: nil)
    return .init(
      input: input, inputSHA256: nvmeDigest(metadata), directoryIdentity: directoryIdentity,
      socketDirectoryIdentity: socketDirectoryIdentity, readonly: assets, payloadData: payloadData,
      disk: disk, variablesIdentity: variables.1, preparationRecord: preparationRecord)
  }

  func claim(_ directory: URL, baseline: NvmeBaseline) throws {
    guard try privateDirectory(directory) == baseline.directoryIdentity,
      nvmeDigest(
        try read(directory.appendingPathComponent("nvme-prepared.json"), maximum: 8192, mode: 0o600)
          .0) == baseline.inputSHA256,
      try scanDisk(directory, payloadData: nil) == baseline.disk
    else { throw nvmeFailure("The prepared fixture changed before ownership.") }
    try verifyReadonly(directory, baseline: baseline)
    try save(
      Data("original-new-nvme-two-boot\n".utf8),
      at: directory.appendingPathComponent("swift-nvme.claim"))
  }

  func beforePhase(
    _ directory: URL, phase: NvmePhase, baseline: NvmeBaseline, disk: NvmeDiskProof?,
    variables savedVariables: NvmeAsset?
  )
    throws
  {
    guard try privateDirectory(directory) == baseline.directoryIdentity,
      try privateDirectory(URL(fileURLWithPath: baseline.input.socketDirectory))
        == baseline.socketDirectoryIdentity
    else {
      throw nvmeFailure("An anchored fixture directory changed.")
    }
    let socketPath = baseline.input.socketDirectory + "/\(phase.rawValue)-qmp.sock"
    var info = stat()
    guard lstat(socketPath, &info) != 0, errno == ENOENT else {
      throw nvmeFailure("The phase monitor already exists.")
    }
    let current = try scanDisk(
      directory, payloadData: phase == .prepare ? nil : baseline.payloadData)
    guard current == (phase == .prepare ? baseline.disk : disk) else {
      throw nvmeFailure("The disk changed between owned boots.")
    }
    let currentVariables = try variables(directory, baseline: baseline)
    guard
      phase == .prepare
        ? currentVariables.identity == baseline.variablesIdentity
        : currentVariables == savedVariables
    else {
      throw nvmeFailure("The retained variable file changed between owned boots.")
    }
    try verifyReadonly(directory, baseline: baseline)
  }

  func variables(_ directory: URL, baseline: NvmeBaseline) throws -> NvmeAsset {
    let path = directory.appendingPathComponent("uefi-vars.json")
    let contents = try read(path, maximum: 262_144, mode: 0o600)
    let prior = baseline.variablesIdentity
    let current = contents.1
    guard current.device == prior.device, current.inode == prior.inode,
      current.mode == prior.mode, current.owner == prior.owner, current.links == prior.links
    else {
      throw nvmeFailure("The original mutable variable file was replaced or aliased.")
    }
    return .init(path: path.path, identity: current, sha256: nvmeDigest(contents.0))
  }

  func verifyReadonly(_ directory: URL, baseline: NvmeBaseline) throws {
    guard try privateDirectory(directory) == baseline.directoryIdentity else {
      throw nvmeFailure("The selected fixture directory changed.")
    }
    let metadata = try read(
      directory.appendingPathComponent("nvme-prepared.json"), maximum: 8192, mode: 0o600)
    let preparation = try read(
      URL(fileURLWithPath: baseline.preparationRecord.path), maximum: 2048, mode: 0o600)
    guard nvmeDigest(metadata.0) == baseline.inputSHA256,
      preparation.1 == baseline.preparationRecord.identity,
      nvmeDigest(preparation.0) == baseline.preparationRecord.sha256
    else {
      throw nvmeFailure("The original bounded preparation provenance changed.")
    }
    for asset in baseline.readonly {
      let file = try read(
        URL(fileURLWithPath: asset.path), maximum: Int(asset.identity.bytes),
        mode: asset.path == baseline.input.qemuExecutable ? nil : 0o400)
      guard file.1 == asset.identity, nvmeDigest(file.0) == asset.sha256 else {
        throw nvmeFailure("A read-only NVMe asset changed.")
      }
    }
    for phase in NvmePhase.allCases {
      try mediaTree(directory.appendingPathComponent("\(phase.rawValue)-media"))
    }
  }

  func scanDisk(_ directory: URL, payloadData: Data?) throws -> NvmeDiskProof {
    let path = directory.appendingPathComponent("nvme-test.raw")
    let fd = try regular(path, maximum: diskBytes, mode: 0o600)
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_size == diskBytes else {
      throw nvmeFailure("Only the exact 32 MiB test disk is admitted.")
    }
    let patterns: [(UInt64, Data)] =
      payloadData.map { data in nvmeLBAs.map { ($0 * 512, sector(data, lba: $0)) } } ?? []
    var hash = SHA256()
    var offset = 0
    while offset < diskBytes {
      let count = min(65_536, diskBytes - offset)
      var actual = Data(count: count)
      let readCount = actual.withUnsafeMutableBytes {
        Darwin.pread(fd, $0.baseAddress, count, off_t(offset))
      }
      guard readCount == count else { throw nvmeFailure("The complete bounded disk scan failed.") }
      var expected = Data(repeating: 0, count: count)
      for (position, pattern) in patterns
      where position >= UInt64(offset) && position < UInt64(offset + count) {
        let start = Int(position) - offset
        guard start <= count - 512 else {
          throw nvmeFailure("A test sector crosses the scan bound.")
        }
        expected.replaceSubrange(start..<(start + 512), with: pattern)
      }
      guard actual == expected else {
        throw nvmeFailure("The test disk has unexpected bytes inside or outside its three sectors.")
      }
      hash.update(data: actual)
      offset += count
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, NvmeIdentity(before) == NvmeIdentity(after),
      lstat(path.path, &named) == 0, NvmeIdentity(after) == NvmeIdentity(named),
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else {
      throw nvmeFailure("The test disk changed during its independent scan.")
    }
    return .init(
      identity: NvmeIdentity(after),
      sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
      bytesScanned: diskBytes, modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
      changedSeconds: Int64(after.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(after.st_ctimespec.tv_nsec))
  }

  private func sector(_ fixture: Data, lba: UInt64) -> Data {
    let data = Array(fixture)
    var result = Array(repeating: UInt8(0), count: 512)
    result.replaceSubrange(0..<8, with: "MVONVSEC".utf8)
    result.replaceSubrange(8..<64, with: data[8..<64])
    let lbaBytes = (0..<8).map { UInt8(truncatingIfNeeded: lba >> ($0 * 8)) }
    result.replaceSubrange(64..<72, with: lbaBytes)
    for index in 72..<512 {
      let n = index - 72
      result[index] =
        data[32 + n % 32] ^ data[8 + n % 16] ^ lbaBytes[n % 8] ^ UInt8(truncatingIfNeeded: index)
    }
    return Data(result)
  }

  func socket(_ path: URL, parent: NvmeIdentity) throws -> NvmeSocketIdentity? {
    guard try privateDirectory(path.deletingLastPathComponent()) == parent else {
      throw nvmeFailure("The private monitor parent changed.")
    }
    var info = stat()
    if lstat(path.path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw nvmeFailure("The private monitor cannot be inspected.")
    }
    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_nlink == 1,
      [mode_t(0o600), mode_t(0o700)].contains(info.st_mode & 0o777)
    else {
      throw nvmeFailure("The owned monitor is not a private Unix socket.")
    }
    return .init(parent: parent, socket: NvmeIdentity(info))
  }

  func writerBusy(_ directory: URL, descriptor: Int32) throws -> Bool {
    let fd = try regular(directory.appendingPathComponent("writer.lock"), maximum: 0, mode: 0o600)
    defer { close(fd) }
    var held = stat()
    var named = stat()
    guard fstat(descriptor, &held) == 0, fstat(fd, &named) == 0,
      NvmeIdentity(held) == NvmeIdentity(named)
    else { throw nvmeFailure("The inherited writer inode changed.") }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
    guard errno == EWOULDBLOCK else {
      throw nvmeFailure("The independent writer exclusion probe failed.")
    }
    return true
  }

  func save<T: Encodable & Sendable>(_ value: T, at path: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try save(encoder.encode(value), at: path)
  }

  private func save(_ data: Data, at path: URL) throws {
    guard data.count <= 32_768 else {
      throw nvmeFailure("A private lab record exceeded its bound.")
    }
    _ = try privateDirectory(path.deletingLastPathComponent())
    let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw nvmeFailure("An exclusive private NVMe record could not be saved.") }
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw nvmeFailure("A NVMe evidence write failed.") }
        offset += count
      }
    }
    guard fsync(fd) == 0 else { throw nvmeFailure("A NVMe evidence record could not be flushed.") }
    let parent = open(
      path.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw nvmeFailure("The evidence directory cannot be flushed.") }
    defer { close(parent) }
    guard fsync(parent) == 0 else { throw nvmeFailure("The evidence directory flush failed.") }
  }

  private func decodeInput(_ data: Data) throws -> NvmePreparedInput {
    // The fixed original preparer emits unescaped strings. Reject escapes before
    // the lexical key count, including escaped aliases of duplicate field names.
    guard let text = String(data: data, encoding: .utf8), !text.contains("\\"),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw nvmeFailure("NVMe metadata is not a flat object.") }
    let expected: Set<String> = [
      "schemaVersion", "scope", "status", "nativeChildrenLaunched", "vmID", "qemuExecutable",
      "socketDirectory",
    ]
    let expression = try NSRegularExpression(pattern: "(?<!\\\\)\"([A-Za-z][A-Za-z0-9]*)\"\\s*:")
    let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    let keys = matches.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    guard Set(object.keys) == expected, keys.count == expected.count, Set(keys) == expected,
      object.values.allSatisfy({ $0 is String || $0 is NSNumber })
    else { throw nvmeFailure("NVMe metadata contains duplicate, unknown or nested fields.") }
    return try JSONDecoder().decode(NvmePreparedInput.self, from: data)
  }

  private func mediaTree(_ media: URL) throws {
    _ = try privateDirectory(media)
    _ = try privateDirectory(media.appendingPathComponent("EFI"))
    _ = try privateDirectory(media.appendingPathComponent("EFI/BOOT"))
    guard
      Set(try FileManager.default.contentsOfDirectory(atPath: media.path)) == [
        "EFI", "MVO-NVME-DATA.BIN",
      ],
      try FileManager.default.contentsOfDirectory(atPath: media.appendingPathComponent("EFI").path)
        == ["BOOT"],
      try FileManager.default.contentsOfDirectory(
        atPath: media.appendingPathComponent("EFI/BOOT").path) == ["BOOTAA64.EFI"]
    else {
      throw nvmeFailure("The original read-only NVMe media tree changed.")
    }
  }

  private func normalized(_ path: String) throws {
    guard path.hasPrefix("/"), !path.contains("//"), !path.contains("\\"),
      !path.contains(","), !path.contains(":"), !path.contains("\""),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      URL(fileURLWithPath: path).path == path
    else { throw nvmeFailure("A canonical local lab path is required.") }
  }

  private func ancestry(_ path: URL) throws {
    try normalized(path.path)
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for part in path.pathComponents.dropFirst() {
      current.appendPathComponent(part, isDirectory: true)
      var info = stat()
      guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == getuid() || info.st_uid == 0,
        info.st_mode & 0o022 == 0
          || (current.path == "/private/tmp" && info.st_uid == 0 && info.st_mode & S_ISVTX != 0)
      else {
        throw nvmeFailure("A lab directory ancestor is linked or writable by another owner.")
      }
    }
  }

  private func privateDirectory(_ path: URL) throws -> NvmeIdentity {
    try ancestry(path)
    var info = stat()
    guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
    else { throw nvmeFailure("A lab directory is not private and owned.") }
    return NvmeIdentity(info)
  }

  private func regular(_ path: URL, maximum: Int, mode: mode_t?) throws -> Int32 {
    try ancestry(path.deletingLastPathComponent())
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw nvmeFailure("A bounded lab asset could not be opened.") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= maximum,
      mode == nil || info.st_mode & 0o777 == mode
    else {
      close(fd)
      throw nvmeFailure("A lab file has unsafe metadata.")
    }
    return fd
  }

  private func read(_ path: URL, maximum: Int, mode: mode_t?) throws -> (Data, NvmeIdentity) {
    let fd = try regular(path, maximum: maximum, mode: mode)
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0 else { throw nvmeFailure("An asset identity could not be read.") }
    var data = Data(count: Int(before.st_size))
    var offset = 0
    while offset < data.count {
      let remaining = data.count - offset
      let count = data.withUnsafeMutableBytes {
        Darwin.pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
      }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw nvmeFailure("A bounded read-only asset read failed.") }
      offset += count
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, NvmeIdentity(before) == NvmeIdentity(after),
      lstat(path.path, &named) == 0, NvmeIdentity(after) == NvmeIdentity(named),
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else {
      throw nvmeFailure("A read-only asset changed during its read.")
    }
    return (data, NvmeIdentity(after))
  }
}

private func nvmeDigest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func nvmeFailure(_ message: String) -> VMError {
  VMError(
    .backendFailure, message,
    recovery: "Preserve this new fixture and its evidence; never reuse a user disk.")
}
