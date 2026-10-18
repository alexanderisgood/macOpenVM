// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Qemu
import VMCore
import VMStorage

/// Fixed, disposable single-survivor trial. No production backend or IPC command
/// gains child-selection authority, and no PID from disk can authorize a signal.
@MainActor enum QemuSurvivorWorkerLab {
  static func run(directory: URL, firstExit: String) async throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
      firstExit == "qemu" || firstExit == "tpm"
    else { throw LabRuntimeFiles.failure("Select qemu or tpm on this exact macOS 27 lab host.") }
    try validateStandardStreams()
    guard setsid() >= 0 else {
      throw LabRuntimeFiles.failure("Lab worker session separation failed.")
    }
    var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &coreLimit) == 0 else {
      throw LabRuntimeFiles.failure("Lab worker core-file restriction failed.")
    }
    let oldMask = umask(0o077)
    defer { umask(oldMask) }
    let labFiles = LabRuntimeFiles()
    try await labFiles.validateSelection(directory)
    let vmID = UUID()
    let lock = try VMLock(directory: directory, expectedVMID: vmID)
    let input = try await labFiles.prepare(directory)
    let files = VMFiles()
    let permit = try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: lock)
    let history = try await VMRuntimeHistory.open(
      in: directory, files: files, lock: lock, permit: permit)
    let lease = try lock.duplicateForInheritance()
    // These are all retained until worker death or actual registered-child cleanup.
    // No releaseParentCopies, LOCK_UN, settlement receipt or intent clearing exists here.
    defer { withExtendedLifetime((lock, lease, permit, history)) {} }
    let mapping = [LeaseSpawn.DescriptorMapping(source: lease.descriptor, target: 200)]
    let qemuArguments =
      Array(input.qemuArgv.dropFirst())
      + ["-add-fd", "fd=200,set=77,opaque=macopenvm-writer-lease"]
    var tpmArguments = Array(input.swtpmArgv.dropFirst())
    let originalControl = "type=unixio,path=\(input.tpmSocket),mode=0600,terminate"
    guard tpmArguments.filter({ $0 == originalControl }).count == 1,
      let controlIndex = tpmArguments.firstIndex(of: originalControl)
    else { throw LabRuntimeFiles.failure("The exact original TPM control argument is absent.") }
    if firstExit == "qemu" {
      tpmArguments[controlIndex] = "type=unixio,path=\(input.tpmSocket),mode=0600"
    }
    let qemu = OwnedProcess(
      configuration: .init(
        executable: URL(fileURLWithPath: input.qemuArgv[0]), arguments: qemuArguments,
        workingDirectory: directory,
        stdoutLog: directory.appendingPathComponent("swift-qemu-stdout.log"),
        stderrLog: directory.appendingPathComponent("swift-qemu-stderr.log"),
        environment: input.environment, inheritedDescriptors: mapping))
    let tpm = OwnedProcess(
      configuration: .init(
        executable: URL(fileURLWithPath: input.swtpmArgv[0]), arguments: tpmArguments,
        workingDirectory: directory,
        stdoutLog: directory.appendingPathComponent("swift-tpm-stdout.log"),
        stderrLog: directory.appendingPathComponent("swift-tpm-stderr.log"),
        environment: input.environment, inheritedDescriptors: mapping))
    let monitor = QMPClient(socketURL: URL(fileURLWithPath: input.qmpSocket))
    defer { withExtendedLifetime((qemu, tpm, monitor)) {} }
    var lockInfo = stat()
    guard fstat(lease.descriptor, &lockInfo) == 0 else {
      throw LabRuntimeFiles.failure("The actual inherited writer identity is unavailable.")
    }
    let lockIdentity = SurvivorLockIdentity(device: lockInfo.st_dev, inode: lockInfo.st_ino)
    try await labFiles.save(
      SurvivorRecipe(
        schemaVersion: 1, scope: "original-diskless-single-survivor-worker",
        vmID: vmID, sessionID: permit.sessionID, firstExit: firstExit,
        qemuArguments: qemuArguments, tpmArguments: tpmArguments,
        controlTerminateRemoved: firstExit == "qemu", leaseDescriptor: 200, qemuFdset: 77,
        holdSeconds: 60), at: directory.appendingPathComponent("swift-survivor-recipe.json"))
    var readyPublished = false
    var trialFailure: Error?
    do {
      try await history.persist(
        .init(state: .starting, operation: .start, backendActive: false, outcome: .pending))
      try await tpm.launch()
      try await waitSocket(input.tpmSocket, child: tpm)
      try await qemu.launch()
      try await waitSocket(input.qmpSocket, child: qemu)
      try await monitor.connect()
      let completionDeadline = ContinuousClock.now.advanced(by: .seconds(60))
      var completed = false
      while ContinuousClock.now < completionDeadline {
        let q = await qemu.snapshot()
        let t = await tpm.snapshot()
        guard q.running, t.running, q.firstError == nil, t.firstError == nil else {
          throw LabRuntimeFiles.failure("The original pair ended before EFI completion.")
        }
        if try QemuLabRuntime.platformCompleted(q.stdout) {
          completed = true
          break
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard completed, try await monitor.queryStatus().running else {
        throw LabRuntimeFiles.failure("Unique actual EFI completion was not observed.")
      }
      try await monitor.stop()
      let paused = try await monitor.queryStatus()
      guard !paused.running, paused.status == "paused" else {
        throw LabRuntimeFiles.failure("The original QEMU did not become paused.")
      }
      try await history.persist(
        .init(state: .paused, operation: nil, backendActive: true, outcome: .pending))
      let survivorKind = firstExit == "qemu" ? "tpm" : "qemu"
      let survivorPath = firstExit == "qemu" ? input.tpmSocket : input.qmpSocket
      let socketIdentity = try inspectSocket(survivorPath)
      let survivor = firstExit == "qemu" ? tpm : qemu
      let first = firstExit == "qemu" ? qemu : tpm
      if firstExit == "qemu" {
        await monitor.close()
        try await qemu.forceKill()
      } else {
        try await tpm.terminate()
      }
      try await awaitInactive(first)
      let firstSnapshot = await first.snapshot()
      let live = await survivor.snapshot()
      guard let firstStatus = firstSnapshot.exit, firstSnapshot.drainsFinished,
        firstSnapshot.firstError == nil, live.running, live.firstError == nil,
        let survivorPID = live.pid,
        firstExit == "qemu"
          ? firstStatus.status == SIGKILL && firstStatus.wasSignalled
          : firstStatus.status == 0 && !firstStatus.wasSignalled,
        try inspectSocket(survivorPath) == socketIdentity
      else {
        throw LabRuntimeFiles.failure(
          "The selected first exit or actual survivor was not observed.")
      }
      if firstExit == "tpm" {
        let observed = try await monitor.queryStatus()
        guard !observed.running, observed.status == "paused" else {
          throw LabRuntimeFiles.failure("The QEMU survivor did not remain paused.")
        }
      }
      // This QEMU monitor admits one client at a time. Yield the lab connection
      // before ready so the observer can independently inspect/control the same
      // paused survivor; close affects only this monitor, not either owned child.
      await monitor.close()
      // A deliberately partial runtime is failed even though one process remains
      // owned. This is never labeled a successful/pending paused VM after QEMU exit.
      try await history.persist(
        .init(state: .failed, operation: nil, backendActive: true, outcome: .failed))
      let holdDeadline = ContinuousClock.now.advanced(by: .seconds(60))
      try await labFiles.save(
        SurvivorReady(
          schemaVersion: 1,
          scope: "original-diskless-single-survivor-worker", vmID: vmID,
          sessionID: permit.sessionID,
          firstExit: firstExit, workerPID: getpid(), survivorKind: survivorKind,
          survivorPID: survivorPID,
          firstChildExit: SurvivorFirstExit(
            status: firstStatus.status, wasSignalled: firstStatus.wasSignalled,
            drainsFinished: firstSnapshot.drainsFinished), lockIdentity: lockIdentity,
          survivorSocket: socketIdentity, holdSeconds: 60, historyOutcome: "failed"),
        at: directory.appendingPathComponent("swift-survivor-ready.json"))
      readyPublished = true
      while ContinuousClock.now < holdDeadline {
        let state = await survivor.snapshot()
        guard state.running, state.firstError == nil else {
          throw LabRuntimeFiles.failure(
            "The ready survivor ended before the owned worker-loss step.")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw LabRuntimeFiles.failure(
        "The explicit 60-second lab hold expired; registered cleanup follows.")
    } catch { trialFailure = error }
    do {
      try await labFiles.save(
        SurvivorCleanupStarted(schemaVersion: 1, vmID: vmID, sessionID: permit.sessionID),
        at: directory.appendingPathComponent("swift-survivor-cleanup-started.json"))
    } catch {
      // A failed exclusive marker cannot authorize an unobservable cleanup. This
      // branch never retries the marker, signals a child, unlocks or clears intent.
      try? FileHandle.standardError.write(
        contentsOf: Data(
          "Lab cleanup marker failed; registered children and writer custody remain retained.\n"
            .utf8))
      let retainedWait = Task { @MainActor in
        for child in [qemu, tpm] {
          if await child.snapshot().isActive {
            do { _ = try await child.wait() } catch {
              try? FileHandle.standardError.write(
                contentsOf: Data(
                  "Actual child completion is unavailable; retained custody remains pending.\n".utf8
                ))
              while await child.snapshot().isActive {
                try? await Task.sleep(for: .seconds(1))
              }
            }
          }
        }
        await monitor.close()
      }
      await retainedWait.value
      throw LabRuntimeFiles.failure("Lab cleanup was not authorized after its marker failed.")
    }
    // Launching this disposable command explicitly authorizes this fallback if
    // the harness does not kill it. Client/stdio EOF does not trigger this branch.
    let cleanup = Task { @MainActor in
      await monitor.close()
      if await qemu.snapshot().running {
        // The readiness monitor was deliberately released. Cleanup negotiates a
        // fresh owned connection and then observes actual child completion.
        let cleanupMonitor = QMPClient(socketURL: URL(fileURLWithPath: input.qmpSocket))
        do {
          try await cleanupMonitor.connect()
          try await cleanupMonitor.quit()
          try await awaitInactive(qemu)
        } catch {
          // Exact registered-child termination remains the explicit fallback.
        }
        await cleanupMonitor.close()
        if await qemu.snapshot().running { try? await qemu.terminate() }
      }
      if await tpm.snapshot().running { try? await tpm.terminate() }
      var reported = false
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while true {
        let q = await qemu.snapshot()
        let t = await tpm.snapshot()
        if !q.isActive && !t.isActive { break }
        if !reported, ContinuousClock.now >= deadline {
          reported = true
          try? FileHandle.standardError.write(
            contentsOf: Data("Single-survivor lab cleanup remains owned and pending.\n".utf8))
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      await monitor.close()
    }
    await cleanup.value
    let q = await qemu.snapshot()
    let t = await tpm.snapshot()
    let preserved = (try? await labFiles.verifyReadonly(directory)) == true
    try await labFiles.save(
      SurvivorFallbackResult(
        schemaVersion: 1, status: "failed",
        vmID: vmID, sessionID: permit.sessionID, firstExit: firstExit,
        readyPublished: readyPublished,
        fallbackCleanupComplete: !q.isActive && !t.isActive,
        drainsFinished: q.drainsFinished && t.drainsFinished,
        qemuExit: q.exit?.status, qemuSignalled: q.exit?.wasSignalled,
        tpmExit: t.exit?.status, tpmSignalled: t.exit?.wasSignalled,
        readonlyHashesPreserved: preserved, runtimeIntentSettled: false,
        hardWorkerLossVerified: false, windowsCompatibilityVerified: false),
      at: directory.appendingPathComponent("swift-survivor-result.json"))
    if let trialFailure { throw trialFailure }
    throw LabRuntimeFiles.failure("The disposable survivor worker returned without hard loss.")
  }

  private static func waitSocket(_ path: String, child: OwnedProcess) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      let state = await child.snapshot()
      guard state.running, state.firstError == nil else {
        throw LabRuntimeFiles.failure("An owned child ended before its public control socket.")
      }
      var info = stat()
      if lstat(path, &info) == 0 {
        _ = try inspectSocket(path)
        return
      }
      guard errno == ENOENT else {
        throw LabRuntimeFiles.failure("Socket inspection was unavailable.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw LabRuntimeFiles.failure("The owned control socket was not published before its deadline.")
  }

  private static func inspectSocket(_ path: String) throws -> SurvivorSocket {
    let url = URL(fileURLWithPath: path)
    var parent = stat()
    var info = stat()
    guard lstat(url.deletingLastPathComponent().path, &parent) == 0,
      parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(),
      parent.st_mode & 0o777 == 0o700,
      lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(),
      info.st_nlink == 1,
      info.st_mode & 0o077 == 0, info.st_mode & 0o600 == 0o600, info.st_mode & 0o7000 == 0
    else { throw LabRuntimeFiles.failure("The original survivor control socket is unsafe.") }
    return SurvivorSocket(
      path: path, parentDevice: parent.st_dev, parentInode: parent.st_ino,
      device: info.st_dev, inode: info.st_ino, ownerMode: UInt16(info.st_mode & 0o777))
  }

  private static func awaitInactive(_ child: OwnedProcess) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while await child.snapshot().isActive {
      guard ContinuousClock.now < deadline else {
        throw LabRuntimeFiles.failure(
          "Actual first-child status and finished drains were not observed.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard await child.snapshot().exit != nil else {
      throw LabRuntimeFiles.failure("The selected child has no observed terminal status.")
    }
  }

  private static func validateStandardStreams() throws {
    let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard null >= 0 else { throw LabRuntimeFiles.failure("Worker null input cannot be verified.") }
    defer { close(null) }
    var expected = stat()
    var input = stat()
    var output = stat()
    var error = stat()
    guard fstat(null, &expected) == 0, fstat(STDIN_FILENO, &input) == 0,
      input.st_mode & S_IFMT == S_IFCHR, input.st_rdev == expected.st_rdev,
      fstat(STDOUT_FILENO, &output) == 0, fstat(STDERR_FILENO, &error) == 0,
      [output, error].allSatisfy({
        $0.st_mode & S_IFMT == S_IFREG && $0.st_uid == geteuid()
          && $0.st_nlink == 1 && $0.st_mode & 0o777 == 0o600
      }),
      output.st_dev != error.st_dev || output.st_ino != error.st_ino
    else {
      throw LabRuntimeFiles.failure(
        "The lab worker requires null input and distinct private regular output.")
    }
  }
}

private struct SurvivorLockIdentity: Encodable, Sendable {
  let device: Int32
  let inode: UInt64
}
private struct SurvivorSocket: Encodable, Equatable, Sendable {
  let path: String
  let parentDevice: Int32
  let parentInode: UInt64
  let device: Int32
  let inode: UInt64
  let ownerMode: UInt16
}
private struct SurvivorFirstExit: Encodable, Sendable {
  let status: Int32
  let wasSignalled: Bool
  let drainsFinished: Bool
}
private struct SurvivorReady: Encodable, Sendable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let firstExit: String
  let workerPID: Int32
  let survivorKind: String
  let survivorPID: Int32
  let firstChildExit: SurvivorFirstExit
  let lockIdentity: SurvivorLockIdentity
  let survivorSocket: SurvivorSocket
  let holdSeconds: Int
  let historyOutcome: String
}
private struct SurvivorRecipe: Encodable, Sendable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let firstExit: String
  let qemuArguments: [String]
  let tpmArguments: [String]
  let controlTerminateRemoved: Bool
  let leaseDescriptor: Int
  let qemuFdset: Int
  let holdSeconds: Int
}
private struct SurvivorFallbackResult: Encodable, Sendable {
  let schemaVersion: Int
  let status: String
  let vmID: UUID
  let sessionID: UUID
  let firstExit: String
  let readyPublished: Bool
  let fallbackCleanupComplete: Bool
  let drainsFinished: Bool
  let qemuExit: Int32?
  let qemuSignalled: Bool?
  let tpmExit: Int32?
  let tpmSignalled: Bool?
  let readonlyHashesPreserved: Bool
  let runtimeIntentSettled: Bool
  let hardWorkerLossVerified: Bool
  let windowsCompatibilityVerified: Bool
}
private struct SurvivorCleanupStarted: Encodable, Sendable {
  let schemaVersion: Int
  let vmID: UUID
  let sessionID: UUID
}
