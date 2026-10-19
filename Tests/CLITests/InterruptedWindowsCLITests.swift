// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import MacOpenVMCLI
@testable import VMCore
@testable import VMStorage

private let cliInterruptionRun = "run-0123456789abcdef0123456789abcdef"
private let cliInterruptionReboot = Data(
  "GENERATED FIXTURE: explicit operator reboot observation".utf8)
private let cliInterruptionOwnerExit = Data(
  "GENERATED FIXTURE: operator reviewed owner exit within the current boot; no reaping proof".utf8)
private let cliInterruptionProcesses = Data(
  "GENERATED FIXTURE: operator reviewed process observation".utf8)

private struct CLIInterruptionFixture {
  let directory: URL
  let vmID: UUID
  let sessionID: UUID
  let configuration: Data
  let intent: Data
  let history: Data
  let run: [String: Data]
}

private func writeCLIInterruptionFixture(_ data: Data, to url: URL) throws {
  try data.write(to: url, options: .withoutOverwriting)
  try #require(chmod(url.path, 0o600) == 0)
}

private func cliInterruptionFixture() throws -> CLIInterruptionFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "macopenvm-explicit-recovery-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  var configuration = VMConfiguration(
    name: "Generated interruption fixture", guest: .windows11, backend: .qemuHVF,
    cpuCount: 2, memoryBytes: 4_294_967_296, diskBytes: 1_073_741_824)
  configuration.network = .disconnected
  let registration = try ConfigurationCodec.encode(configuration)
  try writeCLIInterruptionFixture(
    registration, to: directory.appendingPathComponent("configuration.json"))
  let disk = open(
    directory.appendingPathComponent(configuration.diskFile).path,
    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
  try #require(disk >= 0)
  guard ftruncate(disk, off_t(configuration.diskBytes)) == 0 else {
    close(disk)
    throw VMError(
      .storage, "Generated sparse fixture failed.", recovery: "Preserve only this fixture.")
  }
  close(disk)
  do {
    let initial = try VMLock(directory: directory, expectedVMID: configuration.id)
    withExtendedLifetime(initial) {}
  }
  let session = UUID()
  let intent = Data(
    ("{\"schemaVersion\":1,\"vmID\":\"\(configuration.id.uuidString)\","
      + "\"sessionID\":\"\(session.uuidString)\",\"state\":\"unsettled\"}\n").utf8)
  let history = try RuntimeHistoryCodec.encode(
    RuntimeRecord(
      sessionID: session, sequence: 2, recordedAt: 1_792_310_350.901952,
      snapshot: RuntimeSnapshot(
        state: .running, operation: nil, backendActive: true, outcome: .pending)))
  try writeCLIInterruptionFixture(
    intent, to: directory.appendingPathComponent(RuntimeIntent.filename))
  try writeCLIInterruptionFixture(history, to: directory.appendingPathComponent("runtime.json"))
  let runtime = directory.appendingPathComponent(".runtime")
  let runDirectory = runtime.appendingPathComponent(cliInterruptionRun)
  for folder in [runtime, runDirectory] {
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  var run: [String: Data] = [:]
  let scopes = [
    "worker.json": "macopenvm-registered-qemu-worker-route",
    "display.json": "macopenvm-registered-qemu-display-route",
    "surface.json": "macopenvm-registered-qemu-shared-frame-route",
  ]
  for (name, scope) in scopes {
    let bytes = Data(
      ("{\"schemaVersion\":1,\"scope\":\"\(scope)\",\"vmID\":\"\(configuration.id.uuidString)\","
        + "\"sessionID\":\"\(session.uuidString)\",\"fixture\":\"\(name)\","
        + "\"historicalDevice\":16777232}").utf8)
    run[name] = bytes
    try writeCLIInterruptionFixture(bytes, to: runDirectory.appendingPathComponent(name))
  }
  return .init(
    directory: directory, vmID: configuration.id, sessionID: session,
    configuration: registration, intent: intent, history: history, run: run)
}

@MainActor private func cliParsed(
  _ command: String, _ arguments: [String]
) throws -> CLIInterruptionRequest {
  let options = try MacOpenVMCLI.parse(arguments)
  try MacOpenVMCLI.validateOptions(options, command: command)
  return try InterruptedWindowsCLI.parse(command: command, options: options)
}

private func cliSelectionArguments(_ fixture: CLIInterruptionFixture) -> [String] {
  [
    "--directory", fixture.directory.path, "--expected-vm", fixture.vmID.uuidString,
    "--expected-session", fixture.sessionID.uuidString, "--run-name", cliInterruptionRun,
  ]
}

@MainActor private func cliInspection(_ fixture: CLIInterruptionFixture) async throws
  -> RuntimeInterruptionInspection
{
  let request = try cliParsed("inspect-interrupted-windows", cliSelectionArguments(fixture))
  switch try await InterruptedWindowsCLI.execute(request) {
  case .inspected(let result): return result
  default:
    throw VMError(.storage, "Wrong generated inspection route.", recovery: "Preserve fixture.")
  }
}

@MainActor private func cliRecoveryArguments(
  _ fixture: CLIInterruptionFixture, digest: String
) throws -> [String] {
  let reboot = fixture.directory.appendingPathComponent("reboot-observation.txt")
  let processes = fixture.directory.appendingPathComponent("process-observation.txt")
  try writeCLIInterruptionFixture(cliInterruptionReboot, to: reboot)
  try writeCLIInterruptionFixture(cliInterruptionProcesses, to: processes)
  return cliSelectionArguments(fixture) + [
    "--expected-metadata-sha256", digest, "--reboot-evidence", reboot.path,
    "--process-evidence", processes.path,
    "--acknowledge-host-reboot", InterruptedWindowsCLI.acknowledgement,
  ]
}

@MainActor private func cliAbandonedOwnerArguments(
  _ fixture: CLIInterruptionFixture, digest: String
) throws -> [String] {
  let ownerExit = fixture.directory.appendingPathComponent("owner-exit-observation.txt")
  let processes = fixture.directory.appendingPathComponent("no-other-runtime-observation.txt")
  try writeCLIInterruptionFixture(cliInterruptionOwnerExit, to: ownerExit)
  try writeCLIInterruptionFixture(cliInterruptionProcesses, to: processes)
  return cliSelectionArguments(fixture) + [
    "--expected-metadata-sha256", digest, "--owner-exit-evidence", ownerExit.path,
    "--no-other-runtime-evidence", processes.path,
    "--acknowledge-owner-exit", InterruptedWindowsCLI.abandonedOwnerAcknowledgement,
  ]
}

@Suite @MainActor struct InterruptedWindowsCLITests {
  @Test func inspectionAndRecoveryHaveSeparateExplicitArgumentRoutes() throws {
    let selected = [
      "--directory", "/private/tmp/generated.macopenvm",
      "--expected-vm", "12345678-1234-1234-1234-123456789ABC",
      "--expected-session", "22345678-1234-1234-1234-123456789ABC",
      "--run-name", cliInterruptionRun,
    ]
    let inspected = try cliParsed("inspect-interrupted-windows", selected)
    guard case .inspect(let selection) = inspected else {
      Issue.record("Wrong route")
      return
    }
    #expect(selection.runName == cliInterruptionRun)
    #expect(throws: VMError.self) {
      _ = try cliParsed("recover-interrupted-windows", selected)
    }
    #expect(throws: VMError.self) {
      _ = try cliParsed(
        "inspect-interrupted-windows", selected + ["--acknowledge-host-reboot", "yes"])
    }
  }

  @Test(arguments: [
    "missing-ack", "wrong-ack", "extra", "unknown", "repeat", "zero-vm",
    "bad-session", "bad-sha", "bad-run", "relative", "same-evidence", "braced-session",
  ])
  func malformedOrLeakingArgumentsNeverBecomeRecovery(kind: String) throws {
    var options = [
      "directory": "/private/tmp/generated.macopenvm",
      "expected-vm": "12345678-1234-1234-1234-123456789ABC",
      "expected-session": "22345678-1234-1234-1234-123456789ABC",
      "run-name": cliInterruptionRun, "expected-metadata-sha256": String(repeating: "a", count: 64),
      "reboot-evidence": "/private/tmp/generated-reboot.json",
      "process-evidence": "/private/tmp/generated-processes.txt",
      "acknowledge-host-reboot": InterruptedWindowsCLI.acknowledgement,
    ]
    switch kind {
    case "missing-ack": options.removeValue(forKey: "acknowledge-host-reboot")
    case "wrong-ack": options["acknowledge-host-reboot"] = "yes"
    case "extra": options["seconds"] = "1"
    case "unknown": options["force-unstick"] = "yes"
    case "zero-vm": options["expected-vm"] = "00000000-0000-0000-0000-000000000000"
    case "bad-session": options["expected-session"] = "not-a-session"
    case "bad-sha": options["expected-metadata-sha256"] = String(repeating: "A", count: 64)
    case "bad-run": options["run-name"] = "../foreign-run"
    case "relative": options["directory"] = "relative.macopenvm"
    case "same-evidence": options["process-evidence"] = options["reboot-evidence"]
    case "braced-session": options["expected-session"] = "{22345678-1234-1234-1234-123456789ABC}"
    default: break
    }
    var arguments = options.keys.sorted().flatMap { ["--" + $0, options[$0]!] }
    if kind == "repeat" { arguments += ["--expected-vm", options["expected-vm"]!] }
    #expect(throws: VMError.self) {
      _ = try cliParsed("recover-interrupted-windows", arguments)
    }
  }

  @Test(arguments: [
    "old-command", "reboot-fields", "reboot-ack", "extra-reboot", "missing-ack",
    "same-evidence", "relative-evidence", "unknown", "duplicate", "old-process-field",
    "inspection-command", "bad-digest",
  ])
  func abandonedOwnerCommandCannotMixRebootBasisOrMalformedEvidence(kind: String) throws {
    var command = "recover-abandoned-windows-owner"
    var options = [
      "directory": "/private/tmp/generated.macopenvm",
      "expected-vm": "12345678-1234-1234-1234-123456789ABC",
      "expected-session": "22345678-1234-1234-1234-123456789ABC",
      "run-name": cliInterruptionRun, "expected-metadata-sha256": String(repeating: "a", count: 64),
      "owner-exit-evidence": "/private/tmp/generated-owner-exit.txt",
      "no-other-runtime-evidence": "/private/tmp/generated-processes.txt",
      "acknowledge-owner-exit": InterruptedWindowsCLI.abandonedOwnerAcknowledgement,
    ]
    switch kind {
    case "old-command": command = "recover-interrupted-windows"
    case "reboot-fields":
      options.removeValue(forKey: "owner-exit-evidence")
      options.removeValue(forKey: "no-other-runtime-evidence")
      options.removeValue(forKey: "acknowledge-owner-exit")
      options["reboot-evidence"] = "/private/tmp/generated-reboot.txt"
      options["process-evidence"] = "/private/tmp/generated-processes.txt"
      options["acknowledge-host-reboot"] = InterruptedWindowsCLI.acknowledgement
    case "reboot-ack": options["acknowledge-owner-exit"] = InterruptedWindowsCLI.acknowledgement
    case "extra-reboot": options["reboot-evidence"] = "/private/tmp/generated-reboot.txt"
    case "missing-ack": options.removeValue(forKey: "acknowledge-owner-exit")
    case "same-evidence": options["no-other-runtime-evidence"] = options["owner-exit-evidence"]
    case "relative-evidence": options["owner-exit-evidence"] = "relative.txt"
    case "unknown": options["force-unstick"] = "yes"
    case "old-process-field":
      options["process-evidence"] = options.removeValue(forKey: "no-other-runtime-evidence")
    case "inspection-command": command = "inspect-interrupted-windows"
    case "bad-digest": options["expected-metadata-sha256"] = String(repeating: "A", count: 64)
    default: break
    }
    var arguments = options.keys.sorted().flatMap { ["--" + $0, options[$0]!] }
    if kind == "duplicate" { arguments += ["--owner-exit-evidence", "/private/tmp/second.txt"] }
    #expect(throws: VMError.self) { _ = try cliParsed(command, arguments) }
  }

  @Test func actualInspectNeverRecoversOrReadsEvidence() async throws {
    let fixture = try cliInterruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = RegisteredWindowsInterruptionRecovery(fault: .afterPending)
    let request = try cliParsed("inspect-interrupted-windows", cliSelectionArguments(fixture))
    let outcome = try await InterruptedWindowsCLI.execute(request, makeOwner: { owner })
    guard case .inspected(let result) = outcome else {
      Issue.record("Wrong route")
      return
    }
    #expect(result.readOnly && result.interruptedSessionID == fixture.sessionID)
    #expect(!owner.custodyRetained)
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent(RuntimeIntent.filename))
        == fixture.intent)
    #expect(
      try Data(contentsOf: fixture.directory.appendingPathComponent("runtime.json"))
        == fixture.history)
    let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    #expect(!files.contains { $0.hasPrefix("runtime-interruption-") })
  }

  @Test func actualRecoveryRouteReturnsOnlyAfterClosedSuccessfulCustody() async throws {
    let fixture = try cliInterruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let observed = try await cliInspection(fixture)
    let arguments = try cliRecoveryArguments(fixture, digest: observed.metadataSHA256)
    let request = try cliParsed("recover-interrupted-windows", arguments)
    let owner = RegisteredWindowsInterruptionRecovery()
    let outcome = try await InterruptedWindowsCLI.execute(request, makeOwner: { owner })
    guard case .recovered(let result) = outcome else {
      Issue.record("Wrong route")
      return
    }
    #expect(result.recoverySessionID != fixture.sessionID && result.newOutcome == .failed)
    #expect(!owner.custodyRetained)
    let lock = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    withExtendedLifetime(lock) {}
  }

  @Test func actualAbandonedOwnerRouteArchivesExactEvidenceWithoutRebootClaim() async throws {
    let fixture = try cliInterruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let observed = try await cliInspection(fixture)
    let arguments = try cliAbandonedOwnerArguments(fixture, digest: observed.metadataSHA256)
    let request = try cliParsed("recover-abandoned-windows-owner", arguments)
    guard case .recoverAbandonedOwner(let parsed) = request else {
      Issue.record("Wrong owner-exit argument route")
      return
    }
    #expect(
      parsed.selection.vmID == fixture.vmID && parsed.selection.sessionID == fixture.sessionID)
    let owner = RegisteredWindowsInterruptionRecovery()
    let outcome = try await InterruptedWindowsCLI.execute(request, makeOwner: { owner })
    guard case .recovered(let result) = outcome else {
      Issue.record("Wrong owner-exit execution route")
      return
    }
    #expect(result.newOutcome == .failed && result.recoverySessionID != fixture.sessionID)
    #expect(!result.oldSessionNormallySettled && !result.oldChildReapingProved)
    #expect(!owner.custodyRetained)
    let archiveData = try Data(
      contentsOf: fixture.directory.appendingPathComponent(result.archiveFile))
    let archive = try #require(
      try JSONSerialization.jsonObject(with: archiveData) as? [String: Any])
    #expect(archive["basis"] as? String == "operator-reviewed-owner-exit-and-no-other-runtime")
    let evidence = try #require(archive["evidence"] as? [String: Any])
    #expect(Set(evidence.keys) == ["ownerExitObservation", "processObservation"])
    #expect(
      Data(base64Encoded: try #require(evidence["ownerExitObservation"] as? String))
        == cliInterruptionOwnerExit)
    #expect(
      Data(base64Encoded: try #require(evidence["processObservation"] as? String))
        == cliInterruptionProcesses)
    let lock = try VMLock(directory: fixture.directory, expectedVMID: fixture.vmID)
    withExtendedLifetime(lock) {}
  }

  @Test(arguments: [false, true])
  func actualUncertainRouteRetainsOwnerAndCancellationCannotOpenExitHold(
    abandonedOwner: Bool
  ) async throws {
    let fixture = try cliInterruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let observed = try await cliInspection(fixture)
    let arguments: [String]
    if abandonedOwner {
      arguments = try cliAbandonedOwnerArguments(fixture, digest: observed.metadataSHA256)
    } else {
      arguments = try cliRecoveryArguments(fixture, digest: observed.metadataSHA256)
    }
    let request = try cliParsed(
      abandonedOwner ? "recover-abandoned-windows-owner" : "recover-interrupted-windows", arguments)
    let owner = RegisteredWindowsInterruptionRecovery(fault: .afterPending)
    let outcome = try await InterruptedWindowsCLI.execute(request, makeOwner: { owner })
    guard case .custodyRequired(let retained, let report) = outcome else {
      Issue.record("Uncertain owned operation escaped to ordinary error/exit")
      return
    }
    #expect(retained === owner && owner.custodyRetained)
    #expect(!report.ordinaryExitAllowed && !report.oldSessionNormallySettled)
    // The actual hold implementation, scoped per parallel case so its exact
    // counter/continuation assertions cannot race another recovery basis.
    let keeper = CLIInterruptionExitHold()
    let priorCount = keeper.retainedCount
    let blocked = Task { @MainActor in await keeper.refuseExit(owning: retained) }
    for _ in 0..<64 {
      if keeper.retains(retained) { break }
      await Task.yield()
    }
    #expect(keeper.retainedCount == priorCount + 1 && keeper.retains(retained))
    blocked.cancel()
    for _ in 0..<8 { await Task.yield() }
    #expect(
      blocked.isCancelled && keeper.retainedCount == priorCount + 1 && keeper.retains(retained))
    let fd = open(fixture.directory.appendingPathComponent("writer.lock").path, O_RDWR | O_CLOEXEC)
    try #require(fd >= 0)
    defer { close(fd) }
    let status = flock(fd, LOCK_EX | LOCK_NB)
    let failure = errno
    #expect(status == -1 && failure == EWOULDBLOCK)
    // Do not resume/cancel away the continuation or unlock an uncertain owner.
    // This unstructured generated-fixture task remains held until the test process ends.
  }

  @Test func errorBeforeLeaseAcquisitionRemainsAnOrdinaryRefusal() async throws {
    let fixture = try cliInterruptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let observed = try await cliInspection(fixture)
    let arguments = try cliRecoveryArguments(fixture, digest: observed.metadataSHA256)
    let path = fixture.directory.appendingPathComponent("runtime.json")
    try FileManager.default.removeItem(at: path)
    try writeCLIInterruptionFixture(fixture.history + Data(" ".utf8), to: path)
    let owner = RegisteredWindowsInterruptionRecovery()
    let request = try cliParsed("recover-interrupted-windows", arguments)
    await #expect(throws: VMError.self) {
      _ = try await InterruptedWindowsCLI.execute(request, makeOwner: { owner })
    }
    #expect(!owner.custodyRetained)
  }

  @Test(arguments: ["symlink", "hardlink", "fifo", "oversized", "empty"])
  func unsafeOrUnboundedEvidenceCannotBeRead(kind: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "macopenvm-recovery-evidence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original.txt")
    let path = directory.appendingPathComponent("selected.txt")
    try writeCLIInterruptionFixture(cliInterruptionReboot, to: original)
    switch kind {
    case "symlink": try #require(symlink(original.path, path.path) == 0)
    case "hardlink": try #require(link(original.path, path.path) == 0)
    case "fifo": try #require(mkfifo(path.path, 0o600) == 0)
    default:
      let data = kind == "empty" ? Data() : Data(repeating: 65, count: 65_537)
      try writeCLIInterruptionFixture(data, to: path)
    }
    #expect(throws: VMError.self) { _ = try InterruptedWindowsCLI.readEvidence(path) }
    #expect(try Data(contentsOf: original) == cliInterruptionReboot)
  }

  @Test(arguments: [0o600, 0o644])
  func ownedStableEvidenceIsReadWithoutChangingItsBytes(mode: Int) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "macopenvm-recovery-evidence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("evidence.txt")
    try writeCLIInterruptionFixture(cliInterruptionReboot, to: path)
    try #require(chmod(path.path, mode_t(mode)) == 0)
    #expect(try InterruptedWindowsCLI.readEvidence(path) == cliInterruptionReboot)
    #expect(try Data(contentsOf: path) == cliInterruptionReboot)
  }

  @Test func normalReportPipeReceivesExactBoundedBytes() throws {
    var descriptors: [Int32] = [-1, -1]
    try #require(pipe(&descriptors) == 0)
    defer {
      close(descriptors[0])
      close(descriptors[1])
    }
    let flags = fcntl(descriptors[0], F_GETFL)
    try #require(flags >= 0 && fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) == 0)
    let bytes = Data("generated custody-required report\n".utf8)
    #expect(InterruptedWindowsCLI.writeCustodyReport(bytes, to: descriptors[1]))
    var readback = [UInt8](repeating: 0, count: 128)
    let count = readback.withUnsafeMutableBytes {
      Darwin.read(descriptors[0], $0.baseAddress, $0.count)
    }
    #expect(count == bytes.count)
    if count > 0 { #expect(Data(readback.prefix(count)) == bytes) }
  }

  @Test func brokenReportPipeCannotRaiseOrExitOwnedCustody() throws {
    var descriptors: [Int32] = [-1, -1]
    try #require(pipe(&descriptors) == 0)
    close(descriptors[0])
    defer { close(descriptors[1]) }
    #expect(!InterruptedWindowsCLI.writeCustodyReport(Data("owned".utf8), to: descriptors[1]))
    #expect(!InterruptedWindowsCLI.writeCustodyReport(Data("owned".utf8), to: -1))
  }
}
