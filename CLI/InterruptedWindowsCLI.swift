// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import VMCore

struct CLIInterruptionSelection: Sendable {
  let directory: URL
  let vmID: UUID
  let sessionID: UUID
  let runName: String
}

struct CLIInterruptionRecoveryRequest: Sendable {
  let selection: CLIInterruptionSelection
  let metadataSHA256: String
  let rebootEvidence: URL
  let processEvidence: URL
}

struct CLIAbandonedOwnerRecoveryRequest: Sendable {
  let selection: CLIInterruptionSelection
  let metadataSHA256: String
  let ownerExitEvidence: URL
  let noOtherRuntimeEvidence: URL
}

enum CLIInterruptionRequest: Sendable {
  case inspect(CLIInterruptionSelection)
  case recover(CLIInterruptionRecoveryRequest)
  case recoverAbandonedOwner(CLIAbandonedOwnerRecoveryRequest)
}

struct CLIInterruptionCustodyReport: Encodable, Sendable {
  let schemaVersion = 1
  let status = "recoveryFailedCustodyRetained"
  let vmID: UUID
  let interruptedSessionID: UUID
  let ordinaryExitAllowed = false
  let oldSessionNormallySettled = false
  let oldChildReapingProved = false
  let recovery =
    "Preserve this process and all VM/archive files. No automatic retry, unlock or normal-shutdown inference."
}

@MainActor enum CLIInterruptionOutcome {
  case inspected(RuntimeInterruptionInspection)
  case recovered(RuntimeInterruptionRecoveryResult)
  case custodyRequired(RegisteredWindowsInterruptionRecovery, CLIInterruptionCustodyReport)
}

/// Holds both the actual recovery owner and a continuation that has no legal resume value.
/// Cancellation does not resume/remove either value. No timer, signal or release API exists.
@MainActor final class CLIInterruptionExitHold {
  static let shared = CLIInterruptionExitHold()
  private struct Hold {
    let owner: RegisteredWindowsInterruptionRecovery
    let continuation: CheckedContinuation<Never, Never>
  }
  private var holds: [Hold] = []
  var retainedCount: Int { holds.count }
  func retains(_ owner: RegisteredWindowsInterruptionRecovery) -> Bool {
    holds.contains { $0.owner === owner }
  }
  func refuseExit(owning owner: RegisteredWindowsInterruptionRecovery) async -> Never {
    await withCheckedContinuation { (continuation: CheckedContinuation<Never, Never>) in
      holds.append(Hold(owner: owner, continuation: continuation))
    }
  }
}

@MainActor enum InterruptedWindowsCLI {
  static let acknowledgement = "observed-reboot-and-reviewed-processes"
  static let abandonedOwnerAcknowledgement = "reviewed-owner-exit-and-no-other-runtime"
  static let selectionKeys: Set<String> = [
    "directory", "expected-vm", "expected-session", "run-name",
  ]
  static let recoveryKeys: Set<String> = selectionKeys.union([
    "expected-metadata-sha256", "reboot-evidence", "process-evidence", "acknowledge-host-reboot",
  ])
  static let abandonedOwnerRecoveryKeys: Set<String> = selectionKeys.union([
    "expected-metadata-sha256", "owner-exit-evidence", "no-other-runtime-evidence",
    "acknowledge-owner-exit",
  ])

  static func parse(command: String, options: [String: String]) throws -> CLIInterruptionRequest {
    let required: Set<String>
    switch command {
    case "inspect-interrupted-windows": required = selectionKeys
    case "recover-interrupted-windows": required = recoveryKeys
    case "recover-abandoned-windows-owner": required = abandonedOwnerRecoveryKeys
    default: throw failure()
    }
    guard Set(options.keys) == required,
      let directory = options["directory"], let rawVM = options["expected-vm"],
      let rawSession = options["expected-session"], let run = options["run-name"]
    else { throw failure() }
    let zero = "00000000-0000-0000-0000-000000000000"
    guard rawVM.utf8.count == 36, rawSession.utf8.count == 36,
      let vm = UUID(uuidString: rawVM), let session = UUID(uuidString: rawSession),
      vm.uuidString.lowercased() == rawVM.lowercased(),
      session.uuidString.lowercased() == rawSession.lowercased(),
      vm.uuidString != zero, session.uuidString != zero,
      run.hasPrefix("run-"), run.utf8.count == 36,
      run.dropFirst(4).allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw failure() }
    let selection = CLIInterruptionSelection(
      directory: try localPath(directory), vmID: vm, sessionID: session, runName: run)
    if command == "inspect-interrupted-windows" { return .inspect(selection) }
    if command == "recover-abandoned-windows-owner" {
      guard options["acknowledge-owner-exit"] == abandonedOwnerAcknowledgement,
        let digest = options["expected-metadata-sha256"], digest.utf8.count == 64,
        digest.allSatisfy({ "0123456789abcdef".contains($0) }),
        let ownerExit = options["owner-exit-evidence"],
        let processes = options["no-other-runtime-evidence"]
      else { throw failure() }
      let ownerExitURL = try localPath(ownerExit)
      let processURL = try localPath(processes)
      guard ownerExitURL.path != processURL.path else { throw failure() }
      return .recoverAbandonedOwner(
        .init(
          selection: selection, metadataSHA256: digest,
          ownerExitEvidence: ownerExitURL, noOtherRuntimeEvidence: processURL))
    }
    guard options["acknowledge-host-reboot"] == acknowledgement,
      let digest = options["expected-metadata-sha256"], digest.utf8.count == 64,
      digest.allSatisfy({ "0123456789abcdef".contains($0) }),
      let reboot = options["reboot-evidence"], let process = options["process-evidence"]
    else { throw failure() }
    let rebootURL = try localPath(reboot)
    let processURL = try localPath(process)
    guard rebootURL.path != processURL.path else { throw failure() }
    return .recover(
      .init(
        selection: selection, metadataSHA256: digest,
        rebootEvidence: rebootURL, processEvidence: processURL))
  }

  /// This actual dispatcher is tested without entering the deliberately unbounded exit hold.
  static func execute(
    _ request: CLIInterruptionRequest,
    makeOwner: @MainActor () -> RegisteredWindowsInterruptionRecovery = {
      RegisteredWindowsInterruptionRecovery()
    }
  ) async throws -> CLIInterruptionOutcome {
    let owner = makeOwner()
    switch request {
    case .inspect(let selection):
      return .inspected(
        try await owner.inspect(
          in: selection.directory, expectedVMID: selection.vmID,
          expectedSessionID: selection.sessionID, runName: selection.runName))
    case .recover(let request):
      let reboot = try readEvidence(request.rebootEvidence)
      let process = try readEvidence(request.processEvidence)
      let selection = request.selection
      do {
        return .recovered(
          try await owner.recover(
            in: selection.directory, expectedVMID: selection.vmID,
            expectedSessionID: selection.sessionID, runName: selection.runName,
            expectedMetadataSHA256: request.metadataSHA256,
            rebootObservation: reboot, processObservation: process,
            acknowledgement: .observedHostRebootAndReviewedNoOtherRuntime))
      } catch {
        guard owner.custodyRetained else { throw error }
        return .custodyRequired(
          owner,
          .init(
            vmID: selection.vmID, interruptedSessionID: selection.sessionID))
      }
    case .recoverAbandonedOwner(let request):
      let ownerExit = try readEvidence(request.ownerExitEvidence)
      let processes = try readEvidence(request.noOtherRuntimeEvidence)
      let selection = request.selection
      do {
        return .recovered(
          try await owner.recoverAbandonedOwner(
            in: selection.directory, expectedVMID: selection.vmID,
            expectedSessionID: selection.sessionID, runName: selection.runName,
            expectedMetadataSHA256: request.metadataSHA256,
            ownerExitObservation: ownerExit, processObservation: processes,
            acknowledgement: .reviewedOwnerExitAndNoOtherRuntime))
      } catch {
        guard owner.custodyRetained else { throw error }
        return .custodyRequired(
          owner,
          .init(vmID: selection.vmID, interruptedSessionID: selection.sessionID))
      }
    }
  }

  static func run(command: String, options: [String: String]) async throws {
    let outcome = try await execute(parse(command: command, options: options))
    switch outcome {
    case .inspected(let result): try writeResult(result)
    case .recovered(let result): try writeResult(result)
    case .custodyRequired(let owner, let report):
      // No throwing operation may escape this branch to Main's normal error/exit path.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let fallback = Data(
        "{\"status\":\"recoveryFailedCustodyRetained\",\"ordinaryExitAllowed\":false}".utf8)
      let bytes = (try? encoder.encode(report)) ?? fallback
      _ = writeCustodyReport(bytes + Data("\n".utf8))
      await CLIInterruptionExitHold.shared.refuseExit(owning: owner)
    }
  }

  /// Reporting failure must not unwind owned custody or terminate via a broken output pipe.
  /// Set Darwin's per-descriptor no-SIGPIPE on an owned duplicate; send no process signals.
  static func writeCustodyReport(_ bytes: Data, to descriptor: Int32 = STDERR_FILENO) -> Bool {
    guard !bytes.isEmpty, bytes.count <= 4096 else { return false }
    let fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { return false }
    return bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.write(fd, raw.baseAddress?.advanced(by: offset), raw.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
  }
  private static func writeResult<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8))
  }
  private static func localPath(_ value: String) throws -> URL {
    guard value.hasPrefix("/"), value.utf8.count <= 4096,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw failure() }
    let url = URL(fileURLWithPath: value)
    guard url.standardizedFileURL.path == value else { throw failure() }
    return url
  }
  static func readEvidence(_ path: URL) throws -> Data {
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw failure() }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, safeEvidence(before), before.st_size > 0,
      before.st_size <= 65_536
    else { throw failure() }
    var bytes = Data()
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    while let next = try handle.read(upToCount: 65_536 - bytes.count + 1), !next.isEmpty {
      bytes.append(next)
      guard bytes.count <= 65_536 else { throw failure() }
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, lstat(path.path, &named) == 0,
      stable(before, after), stable(after, named), bytes.count == before.st_size
    else { throw failure() }
    return bytes
  }
  private static func safeEvidence(_ value: stat) -> Bool {
    value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1
      && value.st_mode & 0o022 == 0
  }
  private static func stable(_ first: stat, _ second: stat) -> Bool {
    safeEvidence(second) && first.st_dev == second.st_dev && first.st_ino == second.st_ino
      && first.st_mode == second.st_mode && first.st_uid == second.st_uid
      && first.st_gid == second.st_gid && first.st_size == second.st_size
      && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
      && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
      && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
      && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
  }
  private static func failure() -> VMError {
    VMError(
      .invalidConfiguration,
      "Explicit interruption recovery arguments or evidence are unavailable.",
      recovery: "Inspect first and preserve the exact VM, evidence and any retained recovery owner."
    )
  }
}
