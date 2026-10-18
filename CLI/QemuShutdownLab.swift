// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Qemu
import RuntimeIPC
import VMCore
import VMStorage

/// One new, diskless firmware fixture. The probe requests shutdown itself; this owner
/// never sends powerdown, quit, force stop or a signal, including on failure/deadline.
@MainActor enum QemuShutdownLab {
  static func run(directory: URL) async throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
      HostResources.current.architecture == .arm64
    else {
      throw LabRuntimeFiles.failure("This pinned diskless shutdown trial requires macOS 27 ARM64.")
    }
    try validateStandardStreams(in: directory)
    guard setsid() >= 0 else {
      throw LabRuntimeFiles.failure("Shutdown worker session separation failed.")
    }
    var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &coreLimit) == 0 else {
      throw LabRuntimeFiles.failure("Shutdown worker core-file restriction failed.")
    }
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    let files = ShutdownLabFiles()
    let admitted = try await files.admit(directory)
    let lock = try VMLock(directory: directory, expectedVMID: admitted.preparation.vmID)
    let lease = try lock.duplicateForInheritance()
    let mapping = [LeaseSpawn.DescriptorMapping(source: lease.descriptor, target: 200)]
    let input = admitted.input
    let qemuArguments =
      Array(input.qemuArgv.dropFirst()) + [
        "-add-fd", "fd=200,set=77,opaque=macopenvm-writer-lease",
      ]
    let backend = QemuMachineBackend(
      plan: .init(
        qemu: .init(
          executable: URL(fileURLWithPath: input.qemuArgv[0]), arguments: qemuArguments,
          workingDirectory: directory,
          stdoutLog: directory.appendingPathComponent("qemu-stdout.log"),
          stderrLog: directory.appendingPathComponent("qemu-stderr.log"),
          environment: input.environment, inheritedDescriptors: mapping),
        tpm: .init(
          executable: URL(fileURLWithPath: input.swtpmArgv[0]),
          arguments: Array(input.swtpmArgv.dropFirst()),
          workingDirectory: directory,
          stdoutLog: directory.appendingPathComponent("tpm-stdout.log"),
          stderrLog: directory.appendingPathComponent("tpm-stderr.log"),
          environment: input.environment, inheritedDescriptors: mapping),
        qmpSocket: URL(fileURLWithPath: input.qmpSocket),
        tpmSocket: URL(fileURLWithPath: input.tpmSocket)))
    let owner = try await RecordedRuntimeOwner.open(
      in: directory, vmID: admitted.preparation.vmID, lock: lock, backend: backend)
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    let endpoint = URL(fileURLWithPath: input.qmpSocket).deletingLastPathComponent()
      .appendingPathComponent("worker.sock")
    let server = WorkerIPCServer(socketURL: endpoint) { request in
      // This dedicated scope permits observation only. General worker commands do not
      // become cleanup authority merely because the parent can locate this endpoint.
      let status = await coordinator.handle(
        WorkerRequest(
          vmID: request.vmID, sessionID: request.sessionID, requestID: request.requestID,
          observedRevision: request.observedRevision, command: .status))
      guard request.command != .status else { return status }
      return WorkerResponse(
        vmID: status.vmID, sessionID: status.sessionID, requestID: status.requestID,
        revision: status.revision, state: status.state, ownership: status.ownership,
        backendActive: status.backendActive, operationPending: status.operationPending,
        error: status.error == .identity ? .identity : .recovery)
    }
    var failure = false
    var deadlineExceeded = false
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    do {
      try await server.start()
      try await files.records.save(
        ShutdownOwnerRoute(
          scope: "original-diskless-shutdown-status-only", vmID: owner.vmID,
          sessionID: owner.sessionID, socket: endpoint.path),
        at: directory.appendingPathComponent("shutdown-owner.json"))
      try await files.records.save(
        ShutdownRecipe(
          vmID: owner.vmID, sessionID: owner.sessionID, qemuArguments: qemuArguments,
          tpmArguments: Array(input.swtpmArgv.dropFirst()), childLeaseDescriptor: 200,
          qemuFdset: 77,
          inputSHA256: admitted.preparation.inputSHA256,
          profileSHA256: admitted.preparation.profileSHA256,
          cliSHA256: admitted.preparation.cliSHA256,
          sourcePinsAtPreparation: admitted.preparation.sourcePins),
        at: directory.appendingPathComponent("shutdown-recipe.json"))
      await coordinator.start()
    } catch {
      failure = true
      // A pre-launch metadata failure can settle only actual never-invoked evidence.
      // Uncertain settlement keeps the retained owner; no retry or cleanup is implicit.
      if !backend.isActive { try? await owner.settleOwnership() }
    }
    var reportedFailure = false
    while owner.ownershipState != .settled {
      await backend.refreshOutput()
      failure =
        failure || owner.controller.runtimeError != nil || owner.controller.historyError != nil
        || owner.ownershipState == .recoveryRequired
      if ContinuousClock.now >= deadline {
        deadlineExceeded = true
        failure = true
      }
      if failure, !reportedFailure {
        reportedFailure = true
        try? await files.records.save(
          ShutdownRetainedStatus(
            vmID: owner.vmID, sessionID: owner.sessionID, backendActive: backend.isActive,
            ownership: owner.ownershipState.rawValue, deadlineExceeded: deadlineExceeded,
            actualOwnerRetained: true),
          at: directory.appendingPathComponent("shutdown-failure-retained.json"))
        FileHandle.standardError.write(
          Data(
            "Shutdown trial pending or failed; actual owner retained. Status-only route remains available.\n"
              .utf8))
      }
      // Caller cancellation cannot drop an active owner or authorize a runtime signal.
      try? await Task.sleep(for: .milliseconds(100))
    }
    await backend.refreshOutput()
    await server.close()
    let qemu = backend.qemuSnapshot
    let tpm = backend.tpmSnapshot
    let monitor = backend.settledMonitorObservation
    var probeReady = false
    var probeRequest = false
    var preserved = false
    var receiptConfirmed = false
    do {
      (probeReady, probeRequest) = try probeFacts(qemu?.stdout ?? Data())
      try await files.verifyReadonly(directory, inputSHA256: admitted.preparation.inputSHA256)
      preserved = true
      let storage = VMFiles()
      let history = try RuntimeHistoryCodec.decode(
        await storage.readMetadata(at: directory.appendingPathComponent("runtime.json")))
      let intent = try await storage.readRuntimeIntent(in: directory)
      receiptConfirmed =
        history.sessionID == owner.sessionID && intent?.vmID == owner.vmID
        && intent?.sessionID == owner.sessionID
        && history.snapshot.outcome == .guestStopped && history.snapshot.state == .stopped
        && !history.snapshot.backendActive && intent?.state == .settled
    } catch { failure = true }
    let drained = qemu?.drainsFinished == true && tpm?.drainsFinished == true
    let monitorConfirmed =
      monitor?.guestShutdownObserved == true && monitor?.naturalEOF == true
      && monitor?.readerDrained == true && monitor?.intentionalClose == false
      && monitor?.failure == nil
    let passed =
      !failure && !deadlineExceeded && !backend.isActive && drained && preserved
      && probeReady && probeRequest && receiptConfirmed && monitorConfirmed
      && backend.terminationObservation == .guestStopObserved && backend.lastFailure == nil
      && owner.controller.runtimeError == nil && owner.controller.historyError == nil
      && qemu?.exit?.status == 0 && qemu?.exit?.wasSignalled == false && qemu?.firstError == nil
      && tpm?.exit?.status == 0 && tpm?.exit?.wasSignalled == false && tpm?.firstError == nil
    try await files.records.save(
      ShutdownResult(
        status: passed ? "passed" : "failed", vmID: owner.vmID, sessionID: owner.sessionID,
        probeReadySeen: probeReady, probeRequestSeen: probeRequest,
        qemuExit: qemu?.exit?.status, qemuSignalled: qemu?.exit?.wasSignalled,
        tpmExit: tpm?.exit?.status, tpmSignalled: tpm?.exit?.wasSignalled,
        drainsFinished: drained, monitor: monitor.map(ShutdownMonitorRecord.init),
        sameOwnerGuestStoppedReceipt: receiptConfirmed,
        runtimeIntentSettled: owner.ownershipState == .settled,
        readonlyHashesPreserved: preserved, deadlineExceeded: deadlineExceeded,
        inputSHA256: admitted.preparation.inputSHA256,
        profileSHA256: admitted.preparation.profileSHA256,
        cliSHA256: admitted.preparation.cliSHA256,
        sourcePinsAtPreparation: admitted.preparation.sourcePins),
      at: directory.appendingPathComponent("shutdown-result.json"))
    withExtendedLifetime((lock, lease, backend, owner, coordinator, server)) {}
    guard passed else { throw LabRuntimeFiles.failure("The diskless shutdown proof did not pass.") }
    print(
      "Original diskless EFI guest shutdown settled; Windows and guest filesystem qualification remain open."
    )
  }

  private static func probeFacts(_ data: Data) throws -> (Bool, Bool) {
    guard data.count <= 2_097_152, let raw = String(data: data, encoding: .utf8) else {
      throw LabRuntimeFiles.failure("The shutdown probe output exceeded its bound or format.")
    }
    let clean = raw.replacingOccurrences(
      of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression
    )
    .replacingOccurrences(of: "\r", with: "")
    let lines = clean.split(separator: "\n").map(String.init)
    guard !lines.contains(where: { $0.contains("mvo.shutdown-probe.failure=") }) else {
      throw LabRuntimeFiles.failure("The original shutdown probe reported a failure.")
    }
    return (
      lines.filter { $0 == "mvo.shutdown-probe.ready version=1 wait-seconds=30" }.count == 1,
      lines.filter { $0 == "mvo.shutdown-probe.request reset=shutdown" }.count == 1
    )
  }

  private static func validateStandardStreams(in directory: URL) throws {
    let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard null >= 0 else {
      throw LabRuntimeFiles.failure("Shutdown worker null input cannot be verified.")
    }
    defer { close(null) }
    var expected = stat()
    var input = stat()
    var output = stat()
    var error = stat()
    guard fstat(null, &expected) == 0, fstat(STDIN_FILENO, &input) == 0,
      input.st_mode & S_IFMT == S_IFCHR, input.st_rdev == expected.st_rdev
    else { throw LabRuntimeFiles.failure("Shutdown worker input must be the null device.") }
    guard fstat(STDOUT_FILENO, &output) == 0, fstat(STDERR_FILENO, &error) == 0,
      [output, error].allSatisfy({
        $0.st_mode & S_IFMT == S_IFREG && $0.st_uid == geteuid() && $0.st_nlink == 1
          && $0.st_mode & 0o777 == 0o600 && $0.st_size == 0
      }), output.st_dev != error.st_dev || output.st_ino != error.st_ino
    else {
      throw LabRuntimeFiles.failure("Shutdown worker output needs fresh private regular logs.")
    }
    for (name, info) in [("worker-stdout.log", output), ("worker-stderr.log", error)] {
      var stored = stat()
      guard lstat(directory.appendingPathComponent(name).path, &stored) == 0,
        stored.st_dev == info.st_dev, stored.st_ino == info.st_ino,
        stored.st_mode & S_IFMT == S_IFREG
      else {
        throw LabRuntimeFiles.failure("Shutdown worker output differs from its fresh fixture.")
      }
    }
  }
}

private struct ShutdownPreparation: Decodable, Sendable {
  let schemaVersion: Int
  let scope: String
  let preparedOnly: Bool
  let nativeChildrenLaunched: Bool
  let vmID: UUID
  let cliPath: String
  let cliBytes: Int
  let cliSHA256: String
  let profileSHA256: String
  let sourcePins: [String: String]
  let inputSHA256: String
}

private actor ShutdownLabFiles {
  let records = LabRuntimeFiles()
  static let scope = "original-diskless-shutdown-probe-v1"
  static let artifact = "efi-shutdown-probe-5f2c5b261b454ea687e604109f9fb3e4"
  static let profileHash = "b65782f00802d937bc042373e845af3cd2f3edca3a95454bb1387da18548d4c4"
  static let readonlyPins: [String: (Int, String)] = [
    "firmware-code-64m.fd": (
      67_108_864, "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532"
    ),
    "efi-media/EFI/BOOT/BOOTAA64.EFI": (
      24_576, "3c2bac406642468004f7dffa06ab93be51fec9fe45b6b8104d6aaecbfef3e92f"
    ),
    "efi-media/startup.nsh": (
      27, "7da73d5c619b7bbcbbc9d20b894b62fae55ef5dabe9f4775911cd753fe38e3c8"
    ),
  ]

  func admit(_ directory: URL) async throws -> (
    preparation: ShutdownPreparation, input: LabRuntimeInput
  ) {
    guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("//"),
      !directory.pathComponents.contains("."), !directory.pathComponents.contains(".."),
      !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !directory.path.contains(","), !directory.path.contains(":"),
      directory.deletingLastPathComponent()
        == URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".lab", isDirectory: true),
      directory.lastPathComponent.range(
        of: "^qemu-shutdown-native-[0-9a-f]{32}$", options: .regularExpression) != nil
    else { throw LabRuntimeFiles.failure("Select a newly prepared dedicated shutdown fixture.") }
    try await records.checkAncestry(directory)
    try await records.checkDirectory(directory)
    guard
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
        "efi-media", "firmware-code-64m.fd", "shutdown-prepared.json", "swift-runtime-input.json",
        "tpm-state",
        "uefi-vars.json", "worker-stderr.log", "worker-stdout.log",
      ]
    else { throw LabRuntimeFiles.failure("The dedicated shutdown fixture is not fresh.") }
    let preparation = try JSONDecoder().decode(
      ShutdownPreparation.self,
      from: await records.read(
        directory.appendingPathComponent("shutdown-prepared.json"), limit: 16_384))
    let sources: Set<String> = [
      "Backends/Qemu/QMPClient.swift", "Backends/Qemu/QemuMachineBackend.swift",
      "Backends/Qemu/OwnedProcess.swift",
      "Backends/Qemu/LeaseSpawn.swift", "Core/VMController.swift",
      "Core/RecordedRuntimeOwner.swift",
      "Core/RuntimeWorkerCoordinator.swift", "CLI/QemuShutdownLab.swift", "CLI/Main.swift",
      "Tests/Integration/qemu_shutdown_native.py",
      "Tests/EFI/MacOpenVMLabPkg/ShutdownProbe/ShutdownProbe.c",
      "Tests/EFI/MacOpenVMLabPkg/ShutdownProbe/ShutdownProbe.inf",
      "Tests/EFI/MacOpenVMLabPkg/ShutdownProbe/ShutdownProbe.dsc",
    ]
    guard preparation.schemaVersion == 1, preparation.scope == Self.scope, preparation.preparedOnly,
      !preparation.nativeChildrenLaunched, preparation.profileSHA256 == Self.profileHash,
      preparation.cliPath == CommandLine.arguments[0], preparation.cliBytes > 0,
      preparation.cliBytes <= 128 << 20,
      Set(preparation.sourcePins.keys) == sources,
      preparation.sourcePins.values.allSatisfy(Self.hashShape),
      Self.hashShape(preparation.cliSHA256)
    else { throw LabRuntimeFiles.failure("The shutdown preparation/source record is invalid.") }
    try await records.verify(
      URL(fileURLWithPath: preparation.cliPath), length: preparation.cliBytes,
      digest: preparation.cliSHA256, mode: nil)
    let raw = try await records.read(
      directory.appendingPathComponent("swift-runtime-input.json"), limit: 65_536)
    guard Self.digest(raw) == preparation.inputSHA256 else {
      throw LabRuntimeFiles.failure("The prepared shutdown input changed.")
    }
    let input = try JSONDecoder().decode(LabRuntimeInput.self, from: raw)
    let short = URL(fileURLWithPath: input.qmpSocket).deletingLastPathComponent()
    guard input.schemaVersion == 1, input.scope == "new-owned-offline-no-os-shutdown-fixture",
      !input.guestLaunched, !input.windowsCompatibilityVerified,
      short.path.range(of: "^/private/tmp/mvo-stop-[0-9a-f]{16}$", options: .regularExpression)
        != nil,
      input.qmpSocket == short.appendingPathComponent("qmp.sock").path,
      input.tpmSocket == short.appendingPathComponent("tpm.sock").path,
      input.environment == [
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C", "TMPDIR": short.path,
      ]
    else { throw LabRuntimeFiles.failure("The shutdown socket/environment record differs.") }
    try await records.checkAncestry(short)
    try await records.checkDirectory(short)
    guard try FileManager.default.contentsOfDirectory(atPath: short.path).isEmpty else {
      throw LabRuntimeFiles.failure("The shutdown endpoint directory is not new.")
    }
    let artifacts = directory.deletingLastPathComponent().appendingPathComponent(Self.artifact)
    let qemu = artifacts.appendingPathComponent("qemu-system-aarch64").path
    let tpm = "/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm"
    let expectedQemu = [
      qemu, "-no-user-config", "-nodefaults", "-machine",
      "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off", "-accel", "hvf", "-cpu",
      "host",
      "-smp", "2", "-m", "2048", "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic",
      "none",
      "-qmp", "unix:\(short.path)/qmp.sock,server=on,wait=off", "-drive",
      "if=pflash,unit=0,format=raw,readonly=on,file=\(directory.path)/firmware-code-64m.fd",
      "-device",
      "uefi-vars-sysbus,jsonfile=\(directory.path)/uefi-vars.json,size=262144,force-secure-boot=off,disable-custom-mode=on",
      "-chardev", "socket,id=chrtpm,path=\(short.path)/tpm.sock", "-tpmdev",
      "emulator,id=tpm0,chardev=chrtpm",
      "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on", "-drive",
      "if=none,id=efimedia,format=raw,readonly=on,file=fat:16:\(directory.path)/efi-media",
      "-device",
      "virtio-blk-pci,drive=efimedia,bootindex=1",
    ]
    let expectedTpm = [
      tpm, "socket", "--tpm2", "--tpmstate", "dir=\(directory.path)/tpm-state,mode=0600,lock",
      "--ctrl", "type=unixio,path=\(short.path)/tpm.sock,mode=0600,terminate", "--flags",
      "startup-none", "--log", "file=-",
    ]
    guard input.qemuArgv == expectedQemu, input.swtpmArgv == expectedTpm,
      try await records.read(directory.appendingPathComponent("uefi-vars.json"), limit: 1).isEmpty
    else {
      throw LabRuntimeFiles.failure("Only the dedicated diskless offline recipe is accepted.")
    }
    let state = directory.appendingPathComponent("tpm-state")
    try await records.checkDirectory(state)
    guard try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty else {
      throw LabRuntimeFiles.failure("The new shutdown TPM state is not empty.")
    }
    for (path, names) in [
      ("efi-media", ["EFI", "startup.nsh"]), ("efi-media/EFI", ["BOOT"]),
      ("efi-media/EFI/BOOT", ["BOOTAA64.EFI"]),
    ] {
      let media = directory.appendingPathComponent(path)
      try await records.checkDirectory(media)
      guard try FileManager.default.contentsOfDirectory(atPath: media.path).sorted() == names else {
        throw LabRuntimeFiles.failure("The dedicated shutdown media layout differs.")
      }
    }
    try await verifyReadonly(directory, inputSHA256: preparation.inputSHA256)
    try await records.saveBytes(
      Data((Self.scope + "\n").utf8), at: directory.appendingPathComponent("shutdown.claim"))
    return (preparation, input)
  }

  func verifyReadonly(_ directory: URL, inputSHA256: String) async throws {
    for (path, pin) in Self.readonlyPins {
      try await records.verify(
        directory.appendingPathComponent(path), length: pin.0, digest: pin.1, mode: 0o400)
    }
    let artifacts = directory.deletingLastPathComponent().appendingPathComponent(Self.artifact)
    try await records.checkAncestry(artifacts)
    try await records.checkDirectory(artifacts)
    try await records.verify(
      artifacts.appendingPathComponent("qemu-system-aarch64"), length: 26_756_880,
      digest: "ed753107501522f937d6293e7119a6a3ee2c5c9b0294e13e1fc0c5671ff0528c", mode: 0o500)
    try await records.verify(
      URL(fileURLWithPath: "/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm"), length: 72_192,
      digest: "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a", mode: nil)
    let input = try await records.read(
      directory.appendingPathComponent("swift-runtime-input.json"), limit: 65_536)
    guard Self.digest(input) == inputSHA256 else {
      throw LabRuntimeFiles.failure("The actual shutdown input record changed.")
    }
  }
  nonisolated private static func hashShape(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  nonisolated private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct ShutdownOwnerRoute: Encodable {
  let schemaVersion = 1
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let socket: String
}
private struct ShutdownRecipe: Encodable {
  let schemaVersion = 1
  let scope = "original-diskless-shutdown-probe-v1"
  let vmID: UUID
  let sessionID: UUID
  let qemuArguments: [String]
  let tpmArguments: [String]
  let childLeaseDescriptor: Int
  let qemuFdset: Int
  let inputSHA256: String
  let profileSHA256: String
  let cliSHA256: String
  let sourcePinsAtPreparation: [String: String]
}
private struct ShutdownRetainedStatus: Encodable {
  let vmID: UUID
  let sessionID: UUID
  let backendActive: Bool
  let ownership: String
  let deadlineExceeded: Bool
  let actualOwnerRetained: Bool
}
private struct ShutdownMonitorRecord: Encodable {
  let sequence: UInt64
  let connectionEpoch: UUID
  let guest: Bool?
  let reason: String?
  let naturalEOF: Bool
  let readerDrained: Bool
  let intentionalClose: Bool
  let failurePresent: Bool
  init(_ value: QMPMonitorObservation) {
    sequence = value.sequence
    connectionEpoch = value.connectionEpoch
    guest = value.shutdown?.guest
    reason = value.shutdown?.reason.rawValue
    naturalEOF = value.naturalEOF
    readerDrained = value.readerDrained
    intentionalClose = value.intentionalClose
    failurePresent = value.failure != nil
  }
}
private struct ShutdownResult: Encodable {
  let schemaVersion = 1
  let scope = "original-diskless-shutdown-probe-v1"
  let status: String
  let vmID: UUID
  let sessionID: UUID
  let probeReadySeen: Bool
  let probeRequestSeen: Bool
  let qemuExit: Int32?
  let qemuSignalled: Bool?
  let tpmExit: Int32?
  let tpmSignalled: Bool?
  let drainsFinished: Bool
  let monitor: ShutdownMonitorRecord?
  let sameOwnerGuestStoppedReceipt: Bool
  let runtimeIntentSettled: Bool
  let readonlyHashesPreserved: Bool
  let deadlineExceeded: Bool
  let inputSHA256: String
  let profileSHA256: String
  let cliSHA256: String
  let sourcePinsAtPreparation: [String: String]
  let qmpQuitRequested = false
  let probeSHA256 = "3c2bac406642468004f7dffa06ab93be51fec9fe45b6b8104d6aaecbfef3e92f"
  let forceStopRequested = false
  let signalsRequested = false
  let windowsCompatibilityVerified = false
  let guestFilesystemVerified = false
}
