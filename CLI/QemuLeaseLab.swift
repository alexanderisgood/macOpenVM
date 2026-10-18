// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Qemu
import VMStorage

extension QemuLabRuntime {
  /// Controlled parent-descriptor release in a new diskless fixture. This does not kill the
  /// worker, establish reconnect, or authorize opening a persistent Windows VM.
  static func runLease(directory: URL, firstExit: String) async throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
      firstExit == "qemu" || firstExit == "tpm"
    else { throw LabRuntimeFiles.failure("This exact private lease trial requires macOS 27.") }
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    let files = LabRuntimeFiles()
    try await files.validateSelection(directory)
    let owner = try LabLeaseOwner(directory: directory)
    let input = try await files.prepare(directory)
    let descriptor = await owner.descriptor()
    let mapping = [LeaseSpawn.DescriptorMapping(source: descriptor, target: 200)]
    // QEMU duplicates this inherited descriptor into its retained fdset. It is never
    // attached to a guest device; this command exposes no remove-fd operation.
    let qemuArguments =
      Array(input.qemuArgv.dropFirst())
      + ["-add-fd", "fd=200,set=77,opaque=macopenvm-writer-lease"]
    // Retain the TPM after QEMU disconnects so either survivor can be tested independently.
    // The only recipe change is the documented control-channel terminate flag.
    let tpmArguments = Array(input.swtpmArgv.dropFirst()).map {
      $0 == "type=unixio,path=\(input.tpmSocket),mode=0600,terminate"
        ? "type=unixio,path=\(input.tpmSocket),mode=0600" : $0
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
    let control = QMPClient(socketURL: URL(fileURLWithPath: input.qmpSocket))
    let identity = try await owner.identity()
    try await files.save(
      LeaseLabRecipe(
        schemaVersion: 1, qemuArguments: qemuArguments, tpmArguments: tpmArguments,
        childLeaseDescriptor: 200, qemuFdset: 77, firstExit: firstExit,
        qemuExitMode: firstExit == "qemu" ? "registered-child-sigkill" : "qmp-quit",
        lockIdentity: identity),
      at: directory.appendingPathComponent("swift-lease-recipe.json"))
    var phases: [String] = []
    var failure: Error?
    var parentCopiesClosed = false
    do {
      try await tpm.launch()
      try await waitSocket(input.tpmSocket, process: tpm)
      try await qemu.launch()
      let launchedQemu = await qemu.snapshot()
      let launchedTpm = await tpm.snapshot()
      try await files.save(
        LeaseLabStarted(
          schemaVersion: 1, qemuPID: launchedQemu.pid, tpmPID: launchedTpm.pid,
          lockIdentity: identity, firstExit: firstExit),
        at: directory.appendingPathComponent("swift-lease-started.json"))
      try await waitSocket(input.qmpSocket, process: qemu)
      try await control.connect()
      let readyDeadline = ContinuousClock.now.advanced(by: .seconds(60))
      var complete = false
      while ContinuousClock.now < readyDeadline {
        let q = await qemu.snapshot()
        let t = await tpm.snapshot()
        guard q.running, t.running, q.firstError == nil, t.firstError == nil else {
          throw LabRuntimeFiles.failure("The lease trial pair stopped before EFI completion.")
        }
        if try platformCompleted(q.stdout) {
          complete = true
          break
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard complete, try await control.queryStatus().running else {
        throw LabRuntimeFiles.failure("The original EFI lease trial did not complete.")
      }
      // Strong actor-owned wrappers keep the source alive across both async launches. No
      // source copy remains afterward; EBADF and weak witnesses check that boundary.
      try await owner.releaseParentCopies()
      parentCopiesClosed = true
      try await assertHeld(directory, identity: identity, qemu: qemu, tpm: tpm)
      phases.append("parent-copies-closed-both-running-writer-busy")
      if firstExit == "qemu" {
        // Normal QEMU teardown sends the TPM control SHUTDOWN command. Kill only this
        // registered disposable child to exercise an actual independently surviving TPM.
        await control.close()
        try await qemu.forceKill()
        try await awaitInactive(qemu)
        guard await tpm.snapshot().running else {
          throw LabRuntimeFiles.failure("The TPM did not survive QEMU exit.")
        }
        try await assertBusy(directory, identity: identity)
        phases.append("qemu-sigkill-terminal-drained-tpm-running-writer-busy")
        try await tpm.terminate()
        try await awaitInactive(tpm)
      } else {
        try await tpm.terminate()
        try await awaitInactive(tpm)
        guard await qemu.snapshot().running, try await control.queryStatus().running else {
          throw LabRuntimeFiles.failure("QEMU did not survive TPM exit.")
        }
        try await assertBusy(directory, identity: identity)
        phases.append("tpm-terminal-drained-qemu-running-writer-busy")
        try await control.quit()
        try await awaitInactive(qemu)
      }
      guard try await owner.probe(directory, expected: identity) == .available else {
        throw LabRuntimeFiles.failure("The last child exit did not release the same writer lock.")
      }
      phases.append("both-terminal-drained-same-writer-available")
    } catch {
      failure = error
      // Explicit cleanup authority belongs only to this command's newly claimed no-OS pair.
      // Its independent task cannot inherit a cancelled caller's waiting policy.
      let cleanup = Task { @MainActor in
        try? await control.quit()
        if await qemu.snapshot().running { try? await qemu.terminate() }
        if await tpm.snapshot().running { try? await tpm.terminate() }
        var reported = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
          let q = await qemu.snapshot()
          let t = await tpm.snapshot()
          if !q.isActive && !t.isActive { break }
          if !reported, ContinuousClock.now >= deadline {
            reported = true
            FileHandle.standardError.write(
              Data("Lease test cleanup pending; ownership and evidence are retained.\n".utf8))
          }
          try? await Task.sleep(for: .milliseconds(50))
        }
        await control.close()
      }
      await cleanup.value
    }
    await control.close()
    let q = await qemu.snapshot()
    let t = await tpm.snapshot()
    let preserved = (try? await files.verifyReadonly(directory)) == true
    let expectedQemuExit =
      firstExit == "qemu"
      ? q.exit?.status == SIGKILL && q.exit?.wasSignalled == true
      : q.exit?.status == 0 && q.exit?.wasSignalled == false
    let passed =
      failure == nil && parentCopiesClosed && phases.count == 3
      && !q.isActive && !t.isActive && q.drainsFinished && t.drainsFinished && preserved
      && q.firstError == nil && t.firstError == nil
      && expectedQemuExit
      && t.exit?.status == 0 && t.exit?.wasSignalled == false
    try await files.save(
      LeaseLabResult(
        schemaVersion: 1, status: passed ? "passed" : "failed", firstExit: firstExit,
        phases: phases, parentCopiesClosed: parentCopiesClosed, lockIdentity: identity,
        qemuPID: q.pid, tpmPID: t.pid,
        qemuExit: q.exit?.status, qemuSignalled: q.exit?.wasSignalled,
        tpmExit: t.exit?.status, tpmSignalled: t.exit?.wasSignalled,
        drainsFinished: q.drainsFinished && t.drainsFinished,
        outputCaptureErrors: q.firstError != nil || t.firstError != nil,
        readonlyHashesPreserved: preserved, workerCrashVerified: false,
        windowsCompatibilityVerified: false),
      at: directory.appendingPathComponent("swift-lease-result.json"))
    withExtendedLifetime(owner) {}
    if let failure { throw failure }
    guard passed else { throw LabRuntimeFiles.failure("The diskless child lease trial failed.") }
    print(
      "macOpenVM actual \(firstExit)-first child lease trial passed; worker crash recovery remains unverified."
    )
  }

  private static func waitSocket(_ path: String, process: OwnedProcess) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      let state = await process.snapshot()
      guard state.running, state.firstError == nil else {
        throw LabRuntimeFiles.failure("A lease trial child stopped during socket startup.")
      }
      var info = stat()
      if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0, info.st_nlink == 1
        else { throw LabRuntimeFiles.failure("A lease trial socket has unsafe metadata.") }
        return
      }
      guard errno == ENOENT else { throw LabRuntimeFiles.failure("Socket inspection failed.") }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw LabRuntimeFiles.failure("Lease trial socket startup timed out.")
  }

  private static func awaitInactive(_ process: OwnedProcess) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while await process.snapshot().isActive {
      guard ContinuousClock.now < deadline else {
        throw LabRuntimeFiles.failure("Child terminal status and output cleanup were not observed.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard await process.snapshot().exit != nil else {
      throw LabRuntimeFiles.failure("The lease trial child has no observed terminal status.")
    }
  }

  private static func assertHeld(
    _ directory: URL, identity: LeaseLockIdentity, qemu: OwnedProcess, tpm: OwnedProcess
  ) async throws {
    let q = await qemu.snapshot()
    let t = await tpm.snapshot()
    guard q.running, t.running else {
      throw LabRuntimeFiles.failure("Both lease trial children must still be running.")
    }
    try await assertBusy(directory, identity: identity)
  }

  private static func assertBusy(_ directory: URL, identity: LeaseLockIdentity) async throws {
    guard try await LabLeaseOwner.probe(directory, expected: identity) == .held else {
      throw LabRuntimeFiles.failure("A surviving child did not retain the same writer lock.")
    }
  }
}

private struct LeaseLockIdentity: Codable, Equatable, Sendable {
  let device: Int32
  let inode: UInt64
}

/// Mutable descriptor ownership stays on this actor, away from AppKit/UI work.
private actor LabLeaseOwner {
  private static let prober = LabLeaseProbe()
  private var lock: VMLock?
  private var copy: VMLock.InheritedLease?
  private weak var lockWitness: VMLock?
  private weak var copyWitness: VMLock.InheritedLease?

  init(directory: URL) throws {
    let lease = try VMLock(directory: directory)
    let duplicate = try lease.duplicateForInheritance()
    lock = lease
    copy = duplicate
    lockWitness = lease
    copyWitness = duplicate
  }

  func descriptor() -> Int32 { copy?.descriptor ?? -1 }

  func identity() throws -> LeaseLockIdentity {
    var info = stat()
    guard let copy, fstat(copy.descriptor, &info) == 0 else {
      throw LabRuntimeFiles.failure("The parent writer lease cannot be inspected.")
    }
    return LeaseLockIdentity(device: info.st_dev, inode: info.st_ino)
  }

  func releaseParentCopies() throws {
    let fd = descriptor()
    withExtendedLifetime(copy) {}
    withExtendedLifetime(lock) {}
    copy = nil
    lock = nil
    guard copyWitness == nil, lockWitness == nil, fcntl(fd, F_GETFD) == -1, errno == EBADF else {
      throw LabRuntimeFiles.failure("A parent writer descriptor remained after release.")
    }
  }

  func probe(_ directory: URL, expected: LeaseLockIdentity) async throws -> WriterStatus {
    try await Self.probe(directory, expected: expected)
  }

  static func probe(_ directory: URL, expected: LeaseLockIdentity) async throws -> WriterStatus {
    try await prober.probe(directory, expected: expected)
  }
}

private actor LabLeaseProbe {
  func probe(_ directory: URL, expected: LeaseLockIdentity) throws -> WriterStatus {
    let fd = open(
      directory.appendingPathComponent("writer.lock").path,
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw LabRuntimeFiles.failure("The independent writer probe failed.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
      LeaseLockIdentity(device: info.st_dev, inode: info.st_ino) == expected
    else { throw LabRuntimeFiles.failure("The writer lock identity changed during the trial.") }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .available }
    guard errno == EWOULDBLOCK else { throw LabRuntimeFiles.failure("Writer probing failed.") }
    return .held
  }
}

private struct LeaseLabRecipe: Encodable, Sendable {
  let schemaVersion: Int
  let qemuArguments: [String]
  let tpmArguments: [String]
  let childLeaseDescriptor: Int
  let qemuFdset: Int
  let firstExit: String
  let qemuExitMode: String
  let lockIdentity: LeaseLockIdentity
}

private struct LeaseLabStarted: Encodable, Sendable {
  let schemaVersion: Int
  let qemuPID: Int32?
  let tpmPID: Int32?
  let lockIdentity: LeaseLockIdentity
  let firstExit: String
}

private struct LeaseLabResult: Encodable, Sendable {
  let schemaVersion: Int
  let status: String
  let firstExit: String
  let phases: [String]
  let parentCopiesClosed: Bool
  let lockIdentity: LeaseLockIdentity
  let qemuPID: Int32?
  let tpmPID: Int32?
  let qemuExit: Int32?
  let qemuSignalled: Bool?
  let tpmExit: Int32?
  let tpmSignalled: Bool?
  let drainsFinished: Bool
  let outputCaptureErrors: Bool
  let readonlyHashesPreserved: Bool
  let workerCrashVerified: Bool
  let windowsCompatibilityVerified: Bool
}
