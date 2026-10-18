// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Qemu
import RuntimeIPC
import VMCore
import VMStorage

/// Separate process entry point for a newly prepared, pinned experiment. This is not
/// a general VM launcher, reconnect registry, persistent Windows path or global service.
@MainActor enum QemuWorkerLab {
  static func run(
    directory: URL, profile: LabRuntimeFiles.Profile = .platform,
    installationAuthorized: Bool = false
  ) async throws {
    try prepareWorkerProcess()
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    let files = LabRuntimeFiles()
    try await files.validateSelection(directory)
    let vmID = UUID()
    let lock = try VMLock(directory: directory, expectedVMID: vmID)
    let input = try await files.prepare(
      directory, profile: profile, installationAuthorized: installationAuthorized)
    try await runPrepared(
      directory: directory, recordDirectory: directory, profile: profile,
      files: files, input: input, vmID: vmID, lock: lock)
  }

  static func runWindowsNetworkContinuation(
    directory: URL, planURL: URL, approvalURL: URL, terminalURL: URL,
    shutdownURL: URL, runDirectory: URL
  ) async throws {
    try prepareWorkerProcess()
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    // Only this pinned plan's identity is accepted; old metadata does not mint authority.
    guard let vmID = UUID(uuidString: "11111111-1111-4111-8111-111111111111") else {
      throw LabRuntimeFiles.failure("Continuation VM identity is invalid.")
    }
    let files = LabRuntimeFiles()
    try await files.validateSelection(directory)
    let lock = try VMLock(directory: directory, expectedVMID: vmID)
    let prepared = try await WindowsContinuationFiles().prepare(
      directory: directory, planURL: planURL, approvalURL: approvalURL,
      terminalURL: terminalURL, shutdownURL: shutdownURL, runDirectory: runDirectory, lock: lock)
    guard prepared.0 == vmID else {
      throw LabRuntimeFiles.failure("Continuation VM identity differs.")
    }
    try await runPrepared(
      directory: directory, recordDirectory: runDirectory,
      profile: .windowsInstaller, files: files, input: prepared.1,
      vmID: vmID, lock: lock, continuation: true)
  }

  static func runWindowsExternalContinuation(
    directory: URL, recordURL: URL, recordSHA256: String, runDirectory: URL
  ) async throws {
    try prepareWorkerProcess()
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    guard let vmID = WindowsExternalContinuationFiles.vmID,
      directory.path == WindowsExternalContinuationFiles.destinationPath
    else { throw windowsExternalFailure() }
    try WindowsExternalFileIO.privateDirectory(directory)
    try WindowsExternalFileIO.requireRegular(
      directory.appendingPathComponent("writer.lock"), mode: 0o600, maximum: 0)
    var previous = stat()
    guard lstat(WindowsExternalContinuationFiles.sourcePath, &previous) != 0, errno == ENOENT else {
      throw windowsExternalFailure()
    }
    let lock = try VMLock(directory: directory, expectedVMID: vmID)
    let external = WindowsExternalContinuationFiles()
    let prepared = try await external.prepare(
      directory: directory, recordURL: recordURL,
      recordSHA256: recordSHA256, runDirectory: runDirectory, lock: lock)
    try await runPrepared(
      directory: directory, recordDirectory: runDirectory,
      profile: .windowsInstaller, files: LabRuntimeFiles(), input: prepared.input,
      vmID: vmID, lock: lock, continuation: true, external: true)
  }

  static func prepareWorkerProcess() throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
      throw LabRuntimeFiles.failure("This exact private worker trial requires macOS 27.")
    }
    try validateStandardStreams()
    guard setsid() >= 0 else {
      throw LabRuntimeFiles.failure("The new worker could not separate its terminal session.")
    }
    var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &coreLimit) == 0 else {
      throw LabRuntimeFiles.failure("The worker could not disable its process core files.")
    }
  }

  private static func runPrepared(
    directory: URL, recordDirectory: URL, profile: LabRuntimeFiles.Profile,
    files: LabRuntimeFiles, input: LabRuntimeInput, vmID: UUID, lock: VMLock,
    continuation: Bool = false, external: Bool = false
  ) async throws {
    let lease = try lock.duplicateForInheritance()
    let mappings = [LeaseSpawn.DescriptorMapping(source: lease.descriptor, target: 200)]
    let qemu = OwnedProcess.Configuration(
      executable: URL(fileURLWithPath: input.qemuArgv[0]),
      arguments: Array(input.qemuArgv.dropFirst())
        + ["-add-fd", "fd=200,set=77,opaque=macopenvm-writer-lease"],
      workingDirectory: directory,
      stdoutLog: recordDirectory.appendingPathComponent("swift-qemu-stdout.log"),
      stderrLog: recordDirectory.appendingPathComponent("swift-qemu-stderr.log"),
      environment: input.environment, inheritedDescriptors: mappings)
    let tpm = OwnedProcess.Configuration(
      executable: URL(fileURLWithPath: input.swtpmArgv[0]),
      arguments: Array(input.swtpmArgv.dropFirst()), workingDirectory: directory,
      stdoutLog: recordDirectory.appendingPathComponent("swift-tpm-stdout.log"),
      stderrLog: recordDirectory.appendingPathComponent("swift-tpm-stderr.log"),
      environment: input.environment, inheritedDescriptors: mappings)
    let backend = QemuMachineBackend(
      plan: QemuRuntimePlan(
        qemu: qemu, tpm: tpm, qmpSocket: URL(fileURLWithPath: input.qmpSocket),
        tpmSocket: URL(fileURLWithPath: input.tpmSocket)))
    let store: any RecordedRuntimeStore =
      external ? WindowsExternalRuntimeStore(lock: lock) : VMFiles()
    let owner = try await RecordedRuntimeOwner.open(
      in: directory, vmID: vmID, lock: lock, backend: backend, files: store)
    let coordinator = RuntimeWorkerCoordinator(owner: owner)
    let endpoint = URL(fileURLWithPath: input.qmpSocket).deletingLastPathComponent()
      .appendingPathComponent("worker.sock")
    let server = WorkerIPCServer(socketURL: endpoint) { request in
      await coordinator.handle(request)
    }
    try await server.start()
    do {
      // This bounded private routing record only locates a session. It does not grant
      // continuation authority or authorize launch/signaling from disk identifiers.
      try await files.save(
        WorkerLabRoute(
          schemaVersion: 1,
          scope: external
            ? "approved-windows-external-continuation-worker-route"
            : continuation
              ? "approved-windows-network-continuation-worker-route"
              : profile == .windowsInstaller
                ? "approved-windows-installer-worker-route" : "original-diskless-worker-route",
          vmID: vmID,
          sessionID: owner.sessionID, socket: endpoint.path),
        at: recordDirectory.appendingPathComponent("swift-worker-ready.json"))
    } catch {
      await server.close()
      throw error
    }
    let ended = WorkerEndSignal()
    coordinator.onSettled = { ended.complete() }
    let initialLaunch = Task { @MainActor in
      await coordinator.start()
      if profile != .platform, backend.isActive {
        do {
          let display = endpoint.deletingLastPathComponent().appendingPathComponent("vnc.sock")
          var parent = stat()
          var socket = stat()
          guard lstat(display.deletingLastPathComponent().path, &parent) == 0,
            parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(),
            parent.st_mode & 0o777 == 0o700,
            lstat(display.path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
            socket.st_uid == geteuid(), socket.st_nlink == 1, socket.st_mode & 0o077 == 0,
            socket.st_mode & 0o600 == 0o600, socket.st_mode & 0o7000 == 0
          else { throw LabRuntimeFiles.failure("The display endpoint is not private and owned.") }
          try await files.save(
            WorkerDisplayRoute(
              schemaVersion: 1,
              scope: external
                ? WindowsExternalContinuationFiles.displayScope
                : continuation
                  ? "approved-windows-network-continuation-display-route"
                  : profile == .windowsInstaller
                    ? "approved-windows-installer-display-route"
                    : "original-diskless-display-route",
              vmID: owner.vmID,
              sessionID: owner.sessionID, controlSocket: endpoint.path, displaySocket: display.path,
              parentDevice: parent.st_dev, parentInode: parent.st_ino,
              socketDevice: socket.st_dev, socketInode: socket.st_ino),
            at: recordDirectory.appendingPathComponent("swift-display-ready.json"))
        } catch {
          // The already launched owner stays alive with control IPC for explicit recovery.
          try? FileHandle.standardError.write(
            contentsOf: Data(
              "The private display route could not be published; runtime ownership remains retained.\n"
                .utf8))
        }
      }
    }
    // App/client EOF never completes this wait. Only the actual successful owned
    // receipt transaction permits normal worker exit. Recovery failures retain status.
    await ended.wait()
    await initialLaunch.value
    await server.finishWhenIdle()
    await backend.refreshOutput()
    let preserved: Bool
    if external {
      try await WindowsExternalContinuationFiles().verifyAssets(directory)
      preserved = true
    } else {
      preserved = try await files.verifyReadonly(directory, profile: profile)
    }
    if continuation && !external { try await WindowsContinuationFiles().verifyAssets(directory) }
    let probeCompleted =
      profile == .windowsInstaller
      ? false
      : profile == .platform
        ? try QemuLabRuntime.platformCompleted(backend.qemuSnapshot?.stdout ?? Data())
        : try displayCompleted(backend.qemuSnapshot?.stdout ?? Data())
    let drained =
      backend.qemuSnapshot?.drainsFinished == true && backend.tpmSnapshot?.drainsFinished == true
    let passed =
      owner.ownershipState == .settled && !backend.isActive && drained && preserved
      && (profile == .windowsInstaller || probeCompleted)
      && backend.qemuSnapshot?.exit?.status == 0 && backend.tpmSnapshot?.exit?.status == 0
      && owner.controller.runtimeError == nil && owner.controller.historyError == nil
    try await files.save(
      WorkerLabResult(
        schemaVersion: 1, status: passed ? "passed" : "failed",
        scope: external
          ? "approved-windows-external-continuation-runtime-only"
          : continuation
            ? "approved-windows-network-continuation-runtime-only"
            : profile == .windowsInstaller
              ? "approved-installer-runtime-lifecycle-only" : "original-diskless-probe",
        separatedSession: true,
        platformProbeCompleted: profile == .platform && probeCompleted,
        displayProbeCompleted: profile == .display && probeCompleted,
        runtimeIntentSettled: owner.ownershipState == .settled,
        qemuExit: backend.qemuSnapshot?.exit?.status, tpmExit: backend.tpmSnapshot?.exit?.status,
        drainsFinished: drained, readonlyHashesPreserved: preserved,
        windowsCompatibilityVerified: false, guestCleanShutdownVerified: false),
      at: recordDirectory.appendingPathComponent("swift-worker-result.json"))
    withExtendedLifetime((lock, lease, owner, coordinator, server)) {}
    guard passed else { throw LabRuntimeFiles.failure("The isolated worker trial did not pass.") }
  }

  private static func displayCompleted(_ data: Data) throws -> Bool {
    guard data.count <= 2_097_152, let raw = String(data: data, encoding: .utf8) else {
      throw LabRuntimeFiles.failure("Display probe output exceeded its format or size bound.")
    }
    let clean = raw.replacingOccurrences(
      of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression
    )
    .replacingOccurrences(of: "\r", with: "")
    let lines = clean.split(separator: "\n").map(String.init)
    guard !lines.contains(where: { $0.contains("mvo.display-input.failure") }) else {
      throw LabRuntimeFiles.failure("The original display probe reported a failure.")
    }
    let complete = "mvo.display-input.complete modes=2 keys=8"
    guard lines.contains(complete) else { return false }
    var required = [
      "mvo.display-input.begin version=1", "mvo.display-input.ack stage=0 key=1",
      "mvo.display-input.ack stage=1 key=2", complete,
    ]
    for (index, digit) in "11221122".utf8.enumerated() {
      required += [
        "mvo.display-input.key-ready index=\(index)",
        "mvo.display-input.key-ack index=\(index) unicode=\(digit) scan=0",
      ]
    }
    guard required.allSatisfy({ row in lines.filter({ $0 == row }).count == 1 }) else {
      throw LabRuntimeFiles.failure("Display completion lacks unique acknowledged input rows.")
    }
    var observedSizes: Set<String> = []
    var observedModes: Set<Int> = []
    for stage in 0...1 {
      let prefix = "mvo.display-input.ready stage=\(stage) "
      let rows = lines.filter { $0.hasPrefix(prefix) }
      guard rows.count == 1,
        rows[0].range(
          of: "^\(prefix)width=(640 height=480|800 height=600) mode=([0-9]|[1-5][0-9]|6[0-3])$",
          options: .regularExpression) != nil,
        let size = ["width=640 height=480", "width=800 height=600"].first(where: {
          rows[0].contains($0)
        }), observedSizes.insert(size).inserted,
        let modeField = rows[0].split(separator: " ").last,
        let mode = Int(modeField.dropFirst(5)), observedModes.insert(mode).inserted
      else {
        throw LabRuntimeFiles.failure(
          "The actual distinct display modes were not uniquely observed.")
      }
    }
    return true
  }

  /// Require worker I/O that remains valid after a launcher/client vanishes. The
  /// launcher supplies these private regular logs, never a client-held pipe or tty.
  private static func validateStandardStreams() throws {
    let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard null >= 0 else { throw LabRuntimeFiles.failure("Worker input cannot be verified.") }
    defer { close(null) }
    var expected = stat()
    var input = stat()
    guard fstat(null, &expected) == 0, fstat(STDIN_FILENO, &input) == 0,
      input.st_mode & S_IFMT == S_IFCHR, input.st_rdev == expected.st_rdev
    else { throw LabRuntimeFiles.failure("Worker input must be the null device.") }
    var output = stat()
    var error = stat()
    guard fstat(STDOUT_FILENO, &output) == 0, fstat(STDERR_FILENO, &error) == 0,
      [output, error].allSatisfy({
        $0.st_mode & S_IFMT == S_IFREG && $0.st_uid == getuid() && $0.st_nlink == 1
          && $0.st_mode & 0o777 == 0o600
      }), output.st_dev != error.st_dev || output.st_ino != error.st_ino
    else { throw LabRuntimeFiles.failure("Worker output requires distinct private regular logs.") }
  }
}

@MainActor private final class WorkerEndSignal {
  private var finished = false
  private var continuation: CheckedContinuation<Void, Never>?
  func complete() {
    finished = true
    continuation?.resume()
    continuation = nil
  }
  func wait() async {
    if !finished { await withCheckedContinuation { continuation = $0 } }
  }
}

private struct WorkerLabRoute: Encodable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let socket: String
}

private struct WorkerDisplayRoute: Encodable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let controlSocket: String
  let displaySocket: String
  let parentDevice: dev_t
  let parentInode: ino_t
  let socketDevice: dev_t
  let socketInode: ino_t
}

private struct WorkerLabResult: Encodable {
  let schemaVersion: Int
  let status: String
  let scope: String
  let separatedSession: Bool
  let platformProbeCompleted: Bool
  let displayProbeCompleted: Bool
  let runtimeIntentSettled: Bool
  let qemuExit: Int32?
  let tpmExit: Int32?
  let drainsFinished: Bool
  let readonlyHashesPreserved: Bool
  let windowsCompatibilityVerified: Bool
  let guestCleanShutdownVerified: Bool
}
