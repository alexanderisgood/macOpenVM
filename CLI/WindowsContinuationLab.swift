import BackendAPI
// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation
import VMCore
import VMStorage

/// One pinned continuation, separate from fresh installer admission. This actor never
/// launches a child: the worker must retain its real VMLock and open a new recorded owner.
actor WindowsContinuationFiles {
  private let files = LabRuntimeFiles()
  private let decoder = JSONDecoder()
  private let planPin = "15ddb48ed4b2153957f48fc21ebadcd324800c40ef894f5e27c1417c3fb2ab12"
  private let candidatePin = "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745"
  private let driverPin = "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394"

  func prepare(
    directory: URL, planURL: URL, approvalURL: URL, terminalURL: URL,
    shutdownURL: URL, runDirectory: URL, lock: VMLock
  ) async throws -> (UUID, LabRuntimeInput) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let selected = root.appendingPathComponent(
      ".lab/windows-installer-boot-6223442a7c544aa8a7f17061aec76f80")
    let staging = root.appendingPathComponent(
      ".lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0")
    guard directory == selected, lock.owns(directory),
      planURL == staging.appendingPathComponent("plan.json"),
      approvalURL == staging.appendingPathComponent("approval.json"),
      runDirectory.deletingLastPathComponent() == staging,
      runDirectory.lastPathComponent.range(of: "^run-[0-9a-f]{32}$", options: .regularExpression)
        != nil
    else { throw invalid() }
    for path in [directory, staging, runDirectory] {
      try await files.checkAncestry(path)
      try await files.checkDirectory(path)
    }
    let planData = try await privateRead(planURL, limit: 65_536)
    guard digest(planData) == planPin else { throw invalid() }
    let plan = try decoder.decode(ContinuationPlan.self, from: planData)
    let approval = try WindowsNetworkLabApproval.validate(
      data: await privateRead(approvalURL, limit: 8192), directory: directory.path,
      vmID: plan.vmID, sessionID: plan.previousSessionID, planSHA256: planPin,
      macAddress: plan.macAddress)
    guard let reviewed = approval.consoleReviewedSHA256 else { throw invalid() }
    try approval.requireControl(action: "normal-shutdown", expectedFrame: reviewed)
    let terminal = try decoder.decode(
      ContinuationTerminal.self, from: await privateRead(terminalURL, limit: 32_768))
    let shutdownData = try await privateRead(shutdownURL, limit: 32_768)
    let shutdown = try decoder.decode(ContinuationShutdown.self, from: shutdownData)
    guard terminal.scope == "actual-parent-owned-windows-continuation-terminal",
      terminal.vmID == plan.vmID, terminal.sessionID == plan.previousSessionID,
      terminal.actualOwnerReaped, terminal.allChildrenTerminal, terminal.drainsFinished,
      terminal.pipesClosed, terminal.leasesClosed, terminal.runtimeIntentSettled,
      terminal.opaqueExitAdvisoryReviewed, terminal.qemuExit == 0, terminal.tpmExit == 0,
      [0, 1].contains(terminal.workerExit), !terminal.forceStopUsed,
      !terminal.guestCleanShutdownClaimed,
      terminal.shutdownRecordSHA256 == digest(shutdownData),
      shutdown.scope == "approved-fixed-windows-network-shutdown-input",
      shutdown.action == "normal-shutdown",
      shutdown.vmID == plan.vmID, shutdown.sessionID == plan.previousSessionID,
      shutdown.fixedCommand == "shutdown /s /t 0", shutdown.inputSequenceCompleted,
      !shutdown.guestShutdownVerified, !shutdown.forceStopUsed,
      shutdown.reviewedFrameSHA256 == reviewed
    else { throw invalid() }
    let intentData = try await privateRead(
      directory.appendingPathComponent("runtime-intent.json"), limit: 4096)
    let intent = try await VMFiles().readRuntimeIntent(in: directory)
    let historyData = try await privateRead(
      directory.appendingPathComponent("runtime.json"), limit: 4096)
    let history = try RuntimeHistoryCodec.decode(historyData)
    guard intent?.state == .settled, intent?.vmID == plan.vmID,
      intent?.sessionID == plan.previousSessionID,
      history.sessionID == plan.previousSessionID, history.snapshot.outcome == .failed,
      history.snapshot.state == .failed, !history.snapshot.backendActive
    else { throw invalid() }
    let resultData = try await privateRead(
      directory.appendingPathComponent("swift-worker-result.json"), limit: 32_768)
    let result = try decoder.decode(ContinuationPreviousResult.self, from: resultData)
    guard result.status == "failed", result.runtimeIntentSettled, result.drainsFinished,
      result.qemuExit == 0, result.tpmExit == 0, !result.guestCleanShutdownVerified
    else { throw invalid() }
    let originalData = try await privateRead(
      directory.appendingPathComponent("swift-runtime-input.json"), limit: 65_536)
    let original = try decoder.decode(LabRuntimeInput.self, from: originalData)
    guard digest(originalData) == plan.originalInputSHA256, original == plan.originalInput,
      original.scope == "approved-offline-windows-installer-fixture"
    else { throw invalid() }
    try resources(plan.resources, in: directory)
    let input = try decoder.decode(
      LabRuntimeInput.self,
      from: await privateRead(runDirectory.appendingPathComponent("input.json"), limit: 65_536))
    let short = URL(fileURLWithPath: input.qmpSocket).deletingLastPathComponent()
    guard
      short.path.range(of: "^/private/tmp/mvo-win-net-[0-9a-f]{16}$", options: .regularExpression)
        != nil,
      input == rebound(plan.proposedInput, to: short),
      input.scope == "approved-same-vm-windows-network-fixture"
    else { throw invalid() }
    try await files.checkAncestry(short)
    try await files.checkDirectory(short)
    guard try FileManager.default.contentsOfDirectory(atPath: short.path).isEmpty else {
      throw invalid()
    }
    try await verifyAssets(directory)
    try resources(plan.resources, in: directory)
    guard lock.owns(directory), try await VMFiles().readRuntimeIntent(in: directory) == intent,
      try await privateRead(directory.appendingPathComponent("runtime.json"), limit: 4096)
        == historyData
    else { throw invalid() }
    // Preserve exact prior advisory and settlement bytes before the new permit updates intent.
    for (name, data) in [
      ("previous-runtime.json", historyData), ("previous-intent.json", intentData),
      ("previous-worker-result.json", resultData), ("approved-plan.json", planData),
      ("shutdown-provenance.json", shutdownData),
    ] {
      try await files.saveBytes(data, at: runDirectory.appendingPathComponent(name))
    }
    try await files.saveBytes(
      Data("approved-same-vm-windows-network-continuation\n".utf8),
      at: runDirectory.appendingPathComponent("continuation.claim"))
    return (plan.vmID, input)
  }

  func verifyAssets(_ directory: URL) async throws {
    let root = directory.deletingLastPathComponent()
    let candidate = root.appendingPathComponent(
      "qemu-slirp-candidate-50c20db5653a47dd8a73d36439f45e66")
    try await files.checkAncestry(candidate)
    try await files.verify(
      candidate.appendingPathComponent("qemu-system-aarch64"), length: 26_746_208,
      digest: candidatePin, mode: 0o500)
    let library = candidate.appendingPathComponent("private-libslirp/lib")
    try await files.checkAncestry(library)
    try await files.verify(
      library.appendingPathComponent("libslirp.0.dylib"), length: 156_992,
      digest: "10d404d8a693f2d37401ce0ff54e71d9ffb4a5fe42335a360dea39e6d083a5ab", mode: nil)
    try await files.checkAncestry(candidate.appendingPathComponent("source/pc-bios/keymaps"))
    try await files.verify(
      candidate.appendingPathComponent("source/pc-bios/keymaps/en-us"), length: 27_086,
      digest: "52cf4c523e686078699ed58761c7e1443080305237a5f67a3716832570c5c8e5", mode: 0o600)
    let driver = root.appendingPathComponent(
      "windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09")
    try await files.checkAncestry(driver)
    try await files.verify(
      driver.appendingPathComponent("macopenvm-driver-evaluation.iso"), length: 921_600,
      digest: driverPin, mode: 0o400)
    try await files.verify(
      URL(fileURLWithPath: "/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm"), length: 72_192,
      digest: "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a", mode: nil)
    guard try await files.verifyReadonly(directory, profile: .windowsInstaller) else {
      throw invalid()
    }
  }

  private func resources(_ items: [String: ContinuationResource], in directory: URL) throws {
    guard Set(items.keys) == ["blank-nvme.raw", "firmware-code.fd", "uefi-vars.json", "tpm-state"]
    else { throw invalid() }
    for (name, item) in items {
      let path = directory.appendingPathComponent(name)
      var info = stat()
      let mode: mode_t = name == "firmware-code.fd" ? 0o400 : name == "tpm-state" ? 0o700 : 0o600
      guard item.path == path.path, lstat(path.path, &info) == 0,
        info.st_uid == geteuid(), info.st_mode & 0o7777 == mode,
        info.st_mode & S_IFMT == (name == "tpm-state" ? S_IFDIR : S_IFREG),
        name == "tpm-state" || info.st_nlink == 1,
        name == "uefi-vars.json"
          || (UInt64(info.st_dev) == item.device && UInt64(info.st_ino) == item.inode),
        name != "blank-nvme.raw" || info.st_size == 64 * 1_073_741_824
      else { throw invalid() }
    }
  }

  private func privateRead(_ url: URL, limit: Int) async throws -> Data {
    guard url.path == url.standardizedFileURL.path else { throw invalid() }
    try await files.checkAncestry(url.deletingLastPathComponent())
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600,
      info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1
    else { throw invalid() }
    return try await files.read(url, limit: limit)
  }

  func rebound(_ input: LabRuntimeInput, to short: URL) -> LabRuntimeInput {
    let previous = URL(fileURLWithPath: input.qmpSocket).deletingLastPathComponent().path
    var environment = input.environment
    environment["TMPDIR"] = short.path
    return LabRuntimeInput(
      schemaVersion: input.schemaVersion, scope: input.scope,
      qemuArgv: input.qemuArgv.map { $0.replacingOccurrences(of: previous, with: short.path) },
      swtpmArgv: input.swtpmArgv.map { $0.replacingOccurrences(of: previous, with: short.path) },
      environment: environment, qmpSocket: short.appendingPathComponent("qmp.sock").path,
      tpmSocket: short.appendingPathComponent("tpm.sock").path, guestLaunched: false,
      windowsCompatibilityVerified: false)
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private func invalid() -> Error {
    VMError(
      .invalidConfiguration, "The pinned same-VM continuation requirements did not match.",
      recovery: "Preserve the existing VM, prior owner records and any partial continuation files.")
  }
}

private struct ContinuationPlan: Decodable {
  let vmID: UUID, previousSessionID: UUID
  let macAddress: String, originalInputSHA256: String
  let originalInput: LabRuntimeInput, proposedInput: LabRuntimeInput
  let resources: [String: ContinuationResource]
}
private struct ContinuationResource: Decodable {
  let path: String
  let device: UInt64, inode: UInt64
}
private struct ContinuationTerminal: Decodable {
  let scope: String, shutdownRecordSHA256: String
  let vmID: UUID, sessionID: UUID
  let actualOwnerReaped: Bool, allChildrenTerminal: Bool, drainsFinished: Bool, pipesClosed: Bool,
    leasesClosed: Bool
  let runtimeIntentSettled: Bool, opaqueExitAdvisoryReviewed: Bool, forceStopUsed: Bool,
    guestCleanShutdownClaimed: Bool
  let qemuExit: Int, tpmExit: Int, workerExit: Int
}
private struct ContinuationShutdown: Decodable {
  let scope: String, action: String, fixedCommand: String, reviewedFrameSHA256: String
  let vmID: UUID, sessionID: UUID
  let inputSequenceCompleted: Bool, guestShutdownVerified: Bool, forceStopUsed: Bool
}
private struct ContinuationPreviousResult: Decodable {
  let status: String
  let runtimeIntentSettled: Bool, drainsFinished: Bool, guestCleanShutdownVerified: Bool
  let qemuExit: Int, tpmExit: Int
}
