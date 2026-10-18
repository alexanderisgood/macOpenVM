// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Qemu
import RuntimeIPC
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMCLI

// File/ownership fixtures model a supported host, independently of CI hardware.
private let registeredWorkerTestHost = HostResources(cpuCount: 8, memoryBytes: 16 << 30)

/// Real private files/descriptors/locks/socket nodes only. No listener, child, guest or OS image.
private struct WorkerFileFixture {
  let directory: URL
  let run: URL
  let endpoints: URL
  let configuration: VMConfiguration
  let lock: VMLock
  init() async throws {
    directory = URL(
      fileURLWithPath: "/private/tmp/mvo-worker-test-\(UUID().uuidString)", isDirectory: true)
    let files = VMFiles()
    try await files.createDirectory(directory)
    let runtime = directory.appendingPathComponent(".runtime")
    try await files.createDirectory(runtime)
    run = runtime.appendingPathComponent(
      "run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    try await files.createDirectory(run)
    endpoints = URL(
      fileURLWithPath:
        "/private/tmp/mvo-qemu-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))",
      isDirectory: true)
    try await files.createDirectory(endpoints)
    configuration = VMConfiguration(
      name: "Worker file fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    try await files.writeNewMetadata(
      try ConfigurationCodec.encode(configuration),
      at: directory.appendingPathComponent("configuration.json"))
    for name in ["parent-stdout.log", "parent-stderr.log"] {
      try await files.writeNewMetadata(Data(), at: run.appendingPathComponent(name))
    }
    lock = try VMLock(directory: directory, expectedVMID: configuration.id)
  }
  func close() {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: endpoints)
  }
}
@Suite(.serialized) @MainActor struct RegisteredWindowsWorkerTests {
  @Test func preflightRequiresFreshNamespacesAndActualWriterBeforeIntent() async throws {
    let f = try await WorkerFileFixture()
    defer { f.close() }
    let configuration = try Data(
      contentsOf: f.directory.appendingPathComponent("configuration.json"))
    let records = try RegisteredWorkerPreflight.prepare(
      directory: f.directory, runDirectory: f.run,
      endpointDirectory: f.endpoints, lock: f.lock)
    try records.verify()
    #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    #expect(throws: VMError.self) {
      try VMLock(directory: f.directory, expectedVMID: f.configuration.id)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: f.directory.appendingPathComponent("runtime-intent.json").path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: f.run.path).sorted() == [
        "parent-stderr.log", "parent-stdout.log",
      ])
    let unrelated = f.run.appendingPathComponent("display.json")
    let marker = Data("Existing entry preserved".utf8)
    try marker.write(to: unrelated)
    #expect(throws: VMError.self) {
      try RegisteredWorkerPreflight.prepare(
        directory: f.directory, runDirectory: f.run,
        endpointDirectory: f.endpoints, lock: f.lock)
    }
    #expect(try Data(contentsOf: unrelated) == marker)
    #expect(
      try Data(contentsOf: f.directory.appendingPathComponent("configuration.json"))
        == configuration)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.directory.appendingPathComponent("runtime-intent.json").path))
  }
  @Test func standardStreamsAreRealNamedPrivateDescriptorsAndNoSharedOutput() async throws {
    let f = try await WorkerFileFixture()
    defer { f.close() }
    let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
    let output = open(f.run.appendingPathComponent("parent-stdout.log").path, O_RDWR | O_CLOEXEC)
    let error = open(f.run.appendingPathComponent("parent-stderr.log").path, O_RDWR | O_CLOEXEC)
    #expect(input >= 0 && output >= 0 && error >= 0)
    defer {
      close(input)
      close(output)
      close(error)
    }
    try RegisteredWorkerPreflight.validateStreams(
      runDirectory: f.run, input: input, output: output, error: error)
    #expect(throws: VMError.self) {
      try RegisteredWorkerPreflight.validateStreams(
        runDirectory: f.run, input: output, output: output, error: error)
    }
    #expect(throws: VMError.self) {
      try RegisteredWorkerPreflight.validateStreams(
        runDirectory: f.run, input: input, output: output, error: output)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o640],
      ofItemAtPath: f.run.appendingPathComponent("parent-stdout.log").path)
    #expect(throws: VMError.self) {
      try RegisteredWorkerPreflight.validateStreams(
        runDirectory: f.run, input: input, output: output, error: error)
    }
  }
  @Test func readinessPublicationIsExclusiveAndAnchoredToOriginalRecordDirectory() async throws {
    let f = try await WorkerFileFixture()
    defer { f.close() }
    let records = try RegisteredWorkerPreflight.prepare(
      directory: f.directory, runDirectory: f.run, endpointDirectory: f.endpoints, lock: f.lock)
    let route = RegisteredWorkerRoute(
      schemaVersion: 1, scope: "macopenvm-registered-qemu-worker-route",
      vmID: f.configuration.id, sessionID: UUID(), socket: f.endpoints.path + "/worker.sock")
    try records.publish(route, name: "worker.json")
    let original = try Data(contentsOf: f.run.appendingPathComponent("worker.json"))
    #expect(throws: VMError.self) { try records.publish(route, name: "worker.json") }
    #expect(try Data(contentsOf: f.run.appendingPathComponent("worker.json")) == original)
    let saved = f.run.deletingLastPathComponent().appendingPathComponent("preserved-run")
    #expect(throws: VMError.self) {
      try records.publish(
        route, name: "display.json",
        beforeOpenParent: {
          try FileManager.default.moveItem(at: f.run, to: saved)
          try FileManager.default.createDirectory(
            at: f.run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.run.path).isEmpty)
    #expect(try Data(contentsOf: saved.appendingPathComponent("worker.json")) == original)
  }
  @Test func actualDisplaySocketModesMatchExistingPrivateRfbPolicy() async throws {
    let f = try await WorkerFileFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.endpoints)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw registeredWorkerFailure() }
    defer { Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(endpoints.displaySocket.path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw registeredWorkerFailure() }
    for mode: mode_t in [0o600, 0o700] {
      #expect(chmod(endpoints.displaySocket.path, mode) == 0)
      let result = try RegisteredWorkerPublication.display(
        vmID: f.configuration.id, sessionID: UUID(), endpoints: endpoints)
      var info = stat()
      #expect(lstat(endpoints.displaySocket.path, &info) == 0)
      #expect(info.st_mode & 0o7777 == mode)
      #expect(result.socketDevice == info.st_dev && result.socketInode == info.st_ino)
    }
    // macOS strips setgid from socket chmod; that metadata case is controlled in Python.
    for mode: mode_t in [0o660, 0o606, 0o400, 0o200, 0o1600, 0o4600] {
      #expect(chmod(endpoints.displaySocket.path, mode) == 0)
      var before = stat()
      #expect(lstat(endpoints.displaySocket.path, &before) == 0)
      #expect(before.st_mode & 0o7777 == mode)
      #expect(throws: VMError.self) {
        try RegisteredWorkerPublication.display(
          vmID: f.configuration.id, sessionID: UUID(), endpoints: endpoints)
      }
      var after = stat()
      #expect(lstat(endpoints.displaySocket.path, &after) == 0)
      #expect(before.st_mode == after.st_mode && before.st_ino == after.st_ino)
    }
  }
  @Test func missingNativeDisplayAndPreOwnerCommandsCannotPublishOrLaunch() async throws {
    let f = try await WorkerFileFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(directory: f.endpoints)
    let marker = Data("Public regular marker, never a socket".utf8)
    try marker.write(to: endpoints.displaySocket)
    #expect(throws: VMError.self) {
      try RegisteredWorkerPublication.display(
        vmID: f.configuration.id, sessionID: UUID(), endpoints: endpoints)
    }
    let records = try RegisteredWorkerRecords(directory: f.run)
    let lease = try f.lock.duplicateForInheritance()
    let qemu = OwnedProcess.Configuration(
      executable: URL(fileURLWithPath: "/public-unexecuted-qemu"), arguments: [],
      workingDirectory: f.directory, stdoutLog: f.run.appendingPathComponent("unused-qemu-out"),
      stderrLog: f.run.appendingPathComponent("unused-qemu-error"))
    let tpm = OwnedProcess.Configuration(
      executable: URL(fileURLWithPath: "/public-unexecuted-tpm"), arguments: [],
      workingDirectory: f.directory, stdoutLog: f.run.appendingPathComponent("unused-tpm-out"),
      stderrLog: f.run.appendingPathComponent("unused-tpm-error"))
    let backend = QemuMachineBackend(
      plan: QemuRuntimePlan(
        qemu: qemu, tpm: tpm, qmpSocket: endpoints.qmpSocket, tpmSocket: endpoints.tpmSocket))
    let custody = RegisteredWorkerCustody(
      vmID: f.configuration.id, lock: f.lock, lease: lease, backend: backend,
      store: try RegisteredWindowsRuntimeStore(
        configuration: f.configuration, lock: f.lock, host: registeredWorkerTestHost),
      records: records)
    for command in WorkerCommand.allCases {
      let response = await custody.handle(
        WorkerRequest(
          vmID: f.configuration.id, sessionID: UUID(), requestID: 1,
          observedRevision: 0, command: command))
      #expect(response.error == .recovery && !response.backendActive)
    }
    #expect(!backend.isActive && backend.qemuSnapshot == nil && backend.tpmSnapshot == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.directory.appendingPathComponent("runtime-intent.json").path))
    #expect(try Data(contentsOf: endpoints.displaySocket) == marker)
  }

  @Test func agentRouteRequiresSelectedPrivateSocketAndPublishesOnlyBoundedSessionLocation()
    async throws
  {
    let f = try await WorkerFileFixture()
    defer { f.close() }
    let absent = try QemuRegisteredEndpoints(directory: f.endpoints)
    let endpoints = try QemuRegisteredEndpoints(
      directory: f.endpoints, agentChannel: .virtioSerialV1)
    let path = try #require(endpoints.agentSocket)
    let session = UUID()
    #expect(throws: VMError.self) {
      try RegisteredWorkerPublication.agent(
        vmID: f.configuration.id, sessionID: session, endpoints: absent)
    }
    #expect(throws: VMError.self) {
      try RegisteredWorkerPublication.agent(
        vmID: f.configuration.id, sessionID: session, endpoints: endpoints)
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw registeredWorkerFailure() }
    defer { Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(path.path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw registeredWorkerFailure() }
    for mode: mode_t in [0o600, 0o700] {
      #expect(chmod(path.path, mode) == 0)
      let route = try RegisteredWorkerPublication.agent(
        vmID: f.configuration.id, sessionID: session, endpoints: endpoints)
      var parent = stat()
      var socket = stat()
      #expect(lstat(f.endpoints.path, &parent) == 0 && lstat(path.path, &socket) == 0)
      #expect(route.vmID == f.configuration.id && route.sessionID == session)
      #expect(route.agentSocket == path.path && route.controlSocket == endpoints.controlSocket.path)
      #expect(route.parentDevice == parent.st_dev && route.parentInode == parent.st_ino)
      #expect(route.socketDevice == socket.st_dev && route.socketInode == socket.st_ino)
    }
    for mode: mode_t in [0o660, 0o606, 0o400, 0o200, 0o1600, 0o4600] {
      #expect(chmod(path.path, mode) == 0)
      #expect(throws: VMError.self) {
        try RegisteredWorkerPublication.agent(
          vmID: f.configuration.id, sessionID: session, endpoints: endpoints)
      }
    }
    #expect(chmod(path.path, 0o600) == 0)
    let route = try RegisteredWorkerPublication.agent(
      vmID: f.configuration.id, sessionID: session, endpoints: endpoints)
    let records = try RegisteredWorkerRecords(directory: f.run)
    try records.publish(route, name: "agent.json")
    let bytes = try Data(contentsOf: f.run.appendingPathComponent("agent.json"))
    let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(bytes.count <= 4096)
    #expect(
      Set(fields.keys) == [
        "schemaVersion", "scope", "vmID", "sessionID", "controlSocket", "agentSocket",
        "parentDevice", "parentInode", "socketDevice", "socketInode",
      ])
    #expect(fields["scope"] as? String == "macopenvm-registered-qemu-agent-route")
    #expect(throws: VMError.self) { try records.publish(route, name: "agent.json") }
    #expect(try Data(contentsOf: f.run.appendingPathComponent("agent.json")) == bytes)
    #expect(await VMFiles().writerStatus(in: f.directory) == .held)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.directory.appendingPathComponent("runtime-intent.json").path))
  }

  @Test func agentRouteRefusesRegularIndirectAndReplacedParentsWithoutMutation() async throws {
    let f = try await WorkerFileFixture()
    defer { f.close() }
    let endpoints = try QemuRegisteredEndpoints(
      directory: f.endpoints, agentChannel: .virtioSerialV1)
    let path = try #require(endpoints.agentSocket)
    let marker = Data("Preserved unrelated endpoint".utf8)
    try marker.write(to: path)
    #expect(throws: VMError.self) {
      try RegisteredWorkerPublication.agent(
        vmID: f.configuration.id, sessionID: UUID(), endpoints: endpoints)
    }
    #expect(try Data(contentsOf: path) == marker)
    try FileManager.default.removeItem(at: path)
    let target = f.directory.appendingPathComponent("agent-target")
    try marker.write(to: target)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
    #expect(throws: VMError.self) {
      try RegisteredWorkerPublication.agent(
        vmID: f.configuration.id, sessionID: UUID(), endpoints: endpoints)
    }
    #expect(try Data(contentsOf: target) == marker)
    let preserved = f.directory.appendingPathComponent("preserved-endpoints")
    try FileManager.default.moveItem(at: f.endpoints, to: preserved)
    try FileManager.default.createDirectory(
      at: f.endpoints, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(throws: VMError.self) {
      try RegisteredWorkerPublication.agent(
        vmID: f.configuration.id, sessionID: UUID(), endpoints: endpoints)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.endpoints.path).isEmpty)
    #expect(try Data(contentsOf: target) == marker)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: f.run.path).sorted() == [
        "parent-stderr.log", "parent-stdout.log",
      ])
  }
}

/// Controlled lifecycle callbacks plus real Core receipts/storage/leases only;
/// this is not evidence that a Windows guest or TPM actually ran.
@MainActor private final class WorkerRecoveryBackend: BackendSettlementSource {
  let capabilities = BackendCapabilities(
    id: .qemuHVF, operations: [.start, .stop, .forceStop], limitations: [])
  var isActive = false
  var terminationObservation = BackendTerminationObservation.notObserved
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  var stopCalls = 0
  var forceCalls = 0
  let partialStart: Bool
  private var session: UUID?
  private var sealed = false
  init(partialStart: Bool) { self.partialStart = partialStart }
  func bindRecordedSession(sessionID: UUID) throws { session = sessionID }
  func start() async throws {
    isActive = true
    if partialStart { throw registeredWorkerFailure() }
  }
  func requestStop() throws { stopCalls += 1 }
  func guestStop() {
    isActive = false
    terminationObservation = .guestStopObserved
    onGuestStopped?()
  }
  func forceStop() async throws {
    forceCalls += 1
    isActive = false
    terminationObservation = .explicitForcedTermination
    onGuestStopped?()
  }
  func pause() async throws { throw registeredWorkerFailure() }
  func resume() async throws { throw registeredWorkerFailure() }
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    guard session == sessionID, !sealed, !isActive else { throw registeredWorkerFailure() }
    sealed = true
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID, launchDisposition: .completedAttempt,
      terminationObservation: terminationObservation)
  }
}
@MainActor private func recoveryWorker(partialStart: Bool) async throws -> (
  RegisteredWorkerCustody, WorkerRecoveryBackend, URL, URL
) {
  let f = try await WorkerFileFixture()
  let files = VMFiles()
  try await files.createSparseDisk(
    at: f.directory.appendingPathComponent(f.configuration.diskFile),
    bytes: f.configuration.diskBytes)
  try await files.writeNewMetadata(Data(), at: f.directory.appendingPathComponent("uefi-vars.json"))
  let tpm = f.directory.appendingPathComponent("tpm-state")
  try await files.createDirectory(tpm)
  try await files.writeNewMetadata(Data(), at: tpm.appendingPathComponent(".lock"))
  try await files.writeNewMetadata(
    Data("Public state marker".utf8), at: tpm.appendingPathComponent("tpm2-00.permall"))
  let backend = WorkerRecoveryBackend(partialStart: partialStart)
  let store = try RegisteredWindowsRuntimeStore(
    configuration: f.configuration, lock: f.lock, host: registeredWorkerTestHost)
  let custody = RegisteredWorkerCustody(
    vmID: f.configuration.id, lock: f.lock, lease: try f.lock.duplicateForInheritance(),
    backend: backend, store: store, records: try RegisteredWorkerRecords(directory: f.run))
  let owner = try await RecordedRuntimeOwner.open(
    in: f.directory, vmID: f.configuration.id, lock: f.lock, backend: backend, files: store)
  custody.owner = owner
  let coordinator = RuntimeWorkerCoordinator(owner: owner)
  custody.coordinator = coordinator
  coordinator.onSettled = { custody.ended.complete() }
  await coordinator.start()
  return (custody, backend, f.directory, f.endpoints)
}

@MainActor @Test
func registeredRecoveryNormalStopUsesActualCoreIdentityRevisionAndSettlesBeforeRelease()
  async throws
{
  let (custody, backend, directory, endpoints) = try await recoveryWorker(partialStart: false)
  defer {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: endpoints)
  }
  let session = try #require(custody.owner?.sessionID)
  let original = VMError(
    .storage, "Controlled publication failure.", recovery: "Retain actual custody.")
  let recovery = Task { @MainActor in
    do {
      try await RegisteredWindowsWorker.finishFailedRun(original, custody: custody)
      return Optional<VMError>.none
    } catch { return error as? VMError }
  }
  for _ in 0..<100 {
    if FileManager.default.fileExists(
      atPath: custody.records.directory.appendingPathComponent("recovery.json").path)
    {
      break
    }
    await Task.yield()
  }
  let status = await custody.handle(
    WorkerRequest(
      vmID: custody.vmID, sessionID: session, requestID: 1, observedRevision: 0, command: .status))
  #expect(status.backendActive && status.state == 2)
  for (vm, sid) in [(UUID(), session), (custody.vmID, UUID())] {
    let response = await custody.handle(
      WorkerRequest(
        vmID: vm, sessionID: sid, requestID: 2, observedRevision: status.revision, command: .stop))
    #expect(response.error == .identity)
  }
  let stale = await custody.handle(
    WorkerRequest(
      vmID: custody.vmID, sessionID: session, requestID: 3, observedRevision: 0, command: .stop))
  #expect(stale.error == .stale && backend.stopCalls == 0)
  let pause = await custody.handle(
    WorkerRequest(
      vmID: custody.vmID, sessionID: session, requestID: 4, observedRevision: status.revision,
      command: .pause))
  #expect(pause.error == .recovery)
  let stopped = await custody.handle(
    WorkerRequest(
      vmID: custody.vmID, sessionID: session, requestID: 5, observedRevision: status.revision,
      command: .stop))
  #expect(stopped.error == .none && backend.stopCalls == 1 && backend.isActive)
  #expect(!custody.releaseAfterSettlement())
  #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
  #expect(await VMFiles().writerStatus(in: directory) == .held)
  backend.isActive = false  // Inactivity alone is not the Core settlement receipt.
  #expect(!custody.releaseAfterSettlement())
  #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .unsettled)
  #expect(await VMFiles().writerStatus(in: directory) == .held)
  backend.guestStop()
  #expect(await recovery.value == original)
  #expect(custody.owner == nil)
  #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
  for _ in 0..<100 {
    if await VMFiles().writerStatus(in: directory) == .available { break }
    await Task.yield()
  }
  #expect(await VMFiles().writerStatus(in: directory) == .available)
}

@MainActor @Test
func registeredRecoveryPartialStartAllowsOnlyExplicitForceAndPreservesOriginalFailure() async throws
{
  let (custody, backend, directory, endpoints) = try await recoveryWorker(partialStart: true)
  defer {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: endpoints)
  }
  let session = try #require(custody.owner?.sessionID)
  #expect(backend.isActive && !custody.releaseAfterSettlement())
  let original = registeredWorkerFailure()
  let recovery = Task { @MainActor in
    do {
      try await RegisteredWindowsWorker.finishFailedRun(original, custody: custody)
      return Optional<VMError>.none
    } catch { return error as? VMError }
  }
  for _ in 0..<100 {
    if FileManager.default.fileExists(
      atPath: custody.records.directory.appendingPathComponent("recovery.json").path)
    {
      break
    }
    await Task.yield()
  }
  let status = await custody.handle(
    WorkerRequest(
      vmID: custody.vmID, sessionID: session, requestID: 1, observedRevision: 0, command: .status))
  #expect(status.backendActive && status.error == .operationFailed)
  let result = await custody.handle(
    WorkerRequest(
      vmID: custody.vmID, sessionID: session, requestID: 2, observedRevision: status.revision,
      command: .forceStop))
  #expect(result.error == .none && backend.forceCalls == 1)
  #expect(await recovery.value == original)
  let history = try RuntimeHistoryCodec.decode(
    Data(contentsOf: directory.appendingPathComponent("runtime.json")))
  #expect(
    history.snapshot.outcome == .failed && history.snapshot.state == .failed
      && !history.snapshot.backendActive)
  #expect(try await VMFiles().readRuntimeIntent(in: directory)?.state == .settled)
  for _ in 0..<100 {
    if await VMFiles().writerStatus(in: directory) == .available { break }
    await Task.yield()
  }
  #expect(await VMFiles().writerStatus(in: directory) == .available)
}
