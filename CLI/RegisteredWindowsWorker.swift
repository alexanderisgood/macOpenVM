// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Qemu
import RuntimeIPC
import VMCore
import VMStorage

/// One ordinary registration and actual worker custody. Closing a display/client
/// never stops this process or reconstructs an owner from a saved route or PID.
@MainActor enum RegisteredWindowsWorker {
  static func run(
    directory: URL, runDirectory: URL, endpointDirectory: URL,
    agentChannel: ReviewedQemuAgentChannel? = nil,
    displayEvaluation: ReviewedQemu2DDisplay? = nil,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay? = nil,
    producerCapture: CaptureCapability? = nil
  ) async throws {
    guard
      producerCapture == nil
        || (acceleratedDisplay != nil && agentChannel == nil
          && displayEvaluation == nil)
    else { throw registeredWorkerFailure() }
    try QemuWorkerLab.prepareWorkerProcess()
    let mask = umask(0o077)
    defer { umask(mask) }
    let files = VMFiles()
    let initial = try ConfigurationCodec.decode(
      RegisteredWorkerPreflight.readConfiguration(directory))
    let lock = try VMLock(directory: directory, expectedVMID: initial.id)
    let configuration = try ConfigurationCodec.decode(
      RegisteredWorkerPreflight.readConfiguration(directory))
    guard configuration.id == initial.id, lock.owns(directory) else {
      throw registeredWorkerFailure()
    }
    // The App's earlier reading is advisory to this process. Check this VM's
    // actual volume again before records, retained custody, intent or children.
    // A low-space refusal here needs no uncertain-owner recovery lifetime.
    try await WindowsRuntimeStorageAdmission.requireCapacity(in: directory)
    let records = try RegisteredWorkerPreflight.prepare(
      directory: directory, runDirectory: runDirectory,
      endpointDirectory: endpointDirectory, lock: lock)
    try RegisteredWorkerPreflight.validateStreams(
      runDirectory: runDirectory,
      input: STDIN_FILENO, output: STDOUT_FILENO, error: STDERR_FILENO)
    let endpoints = try QemuRegisteredEndpoints(
      directory: endpointDirectory, agentChannel: agentChannel)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let selected =
      try producerCapture != nil
      ? QemuRegisteredCatalog.producerCaptureEvaluation(for: configuration, projectRoot: project)
      : acceleratedDisplay != nil
        ? QemuRegisteredCatalog.acceleratedDisplayEvaluation(
          for: configuration, projectRoot: project)
        : displayEvaluation == nil
          ? QemuRegisteredCatalog.registeredEvaluation(for: configuration, projectRoot: project)
          : QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(
            for: configuration, projectRoot: project)
    // Only this explicit typed argument can select the transport. Ordinary
    // catalog selection, stored configuration and boot never select it.
    let resources = try selected.selectingWorkerDevices(
      agentChannel: agentChannel, displayEvaluation: displayEvaluation,
      acceleratedDisplay: acceleratedDisplay, producerCapture: producerCapture)
    let identity = try await files.readMetadata(
      at: directory.appendingPathComponent(QemuPlatformIdentityCodec.filename), limit: 8192)
    let plan = try await QemuRegisteredAdmission.prepare(
      configuration: configuration, in: directory,
      platformIdentity: identity, resources: resources, endpoints: endpoints, lock: lock)
    try plan.revalidate(lock: lock)
    try endpoints.requireChildSocketsAbsent()
    let lease = try lock.duplicateForInheritance()
    let mappings = [LeaseSpawn.DescriptorMapping(source: lease.descriptor, target: 200)]
    let qemu = OwnedProcess.Configuration(
      executable: plan.qemuExecutable,
      arguments: plan.qemuArguments + ["-add-fd", "fd=200,set=77,opaque=macopenvm-writer-lease"],
      workingDirectory: directory,
      stdoutLog: runDirectory.appendingPathComponent("qemu-stdout.log"),
      stderrLog: runDirectory.appendingPathComponent("qemu-stderr.log"),
      environment: plan.environment, inheritedDescriptors: mappings)
    let tpm = OwnedProcess.Configuration(
      executable: plan.swtpmExecutable, arguments: plan.swtpmArguments,
      workingDirectory: directory, stdoutLog: runDirectory.appendingPathComponent("tpm-stdout.log"),
      stderrLog: runDirectory.appendingPathComponent("tpm-stderr.log"),
      environment: plan.environment, inheritedDescriptors: mappings)
    let runtimePlan = QemuRuntimePlan(
      qemu: qemu, tpm: tpm,
      qmpSocket: endpoints.qmpSocket, tpmSocket: endpoints.tpmSocket)
    let backend: QemuMachineBackend
    if let producerCapture {
      // Actual public verification is mandatory; no signature/minOS waiver.
      try resources.verify()
      guard resources.runtimeQemu.sha256 == RegisteredWorkerCaptureRecord.expectedRuntimeSHA256
      else {
        throw registeredWorkerFailure()
      }
      backend = QemuMachineBackend(
        plan: runtimePlan, producerCaptureVMID: configuration.id,
        producerCaptureCapability: producerCapture)
    } else {
      backend = QemuMachineBackend(plan: runtimePlan)
    }
    let store = try RegisteredWindowsRuntimeStore(configuration: configuration, lock: lock)
    let custody = RegisteredWorkerCustody(
      vmID: configuration.id, lock: lock, lease: lease,
      backend: backend, store: store, records: records)
    let server: WorkerIPCServer
    if let producerCapture {
      server = WorkerIPCServer(
        socketURL: endpoints.controlSocket,
        producerCaptureCapability: producerCapture,
        handler: { await custody.handle($0) },
        producerCapture: { await custody.handleProducerCapture($0, connectionID: $1) },
        captureDisconnected: { await custody.captureAttachmentEnded($0, lostReply: $1) })
    } else {
      server = WorkerIPCServer(socketURL: endpoints.controlSocket) { request in
        await custody.handle(request)
      }
    }
    // Binding is fallible and occurs before any new runtime intent/permit.
    try await server.start()
    custody.server = server
    custody.retain()
    do {
      try plan.revalidate(lock: lock)
      try endpoints.requireChildSocketsAbsent()
      let owner = try await RecordedRuntimeOwner.open(
        in: directory, vmID: configuration.id,
        lock: lock, backend: backend, files: store)
      custody.owner = owner
      let coordinator = RuntimeWorkerCoordinator(owner: owner)
      coordinator.selectRelativeMouse = { relative in
        try await backend.selectRelativeMouse(relative)
      }
      custody.coordinator = coordinator
      coordinator.onSettled = { custody.ended.complete() }
      await coordinator.start()
      let status = await coordinator.handle(
        WorkerRequest(
          vmID: configuration.id, sessionID: owner.sessionID,
          requestID: 1, observedRevision: 0, command: .status))
      guard status.state == 2, status.ownership == 0, status.backendActive,
        !status.operationPending, status.error == .none
      else { throw registeredWorkerFailure() }
      try endpoints.revalidateParent()
      try records.publish(
        RegisteredWorkerRoute(
          schemaVersion: 1, scope: "macopenvm-registered-qemu-worker-route",
          vmID: configuration.id, sessionID: owner.sessionID, socket: endpoints.controlSocket.path),
        name: "worker.json")
      if let producerCapture {
        try plan.revalidate(lock: lock)  // resource/writer integrity remains mandatory
        do {
          let binding = try backend.producerCaptureBinding(
            vmID: configuration.id,
            sessionID: owner.sessionID)
          try coordinator.configureProducerCapture(
            binding: binding, capability: producerCapture,
            actualBinding: {
              try? backend.producerCaptureBinding(
                vmID: configuration.id, sessionID: owner.sessionID)
            },
            exchange: { command, terminal, capture in
              try await backend.exchangeProducerCapture(
                command, binding: binding,
                expectedCapture: capture, terminal: terminal)
            })
          try records.publish(
            RegisteredWorkerCaptureRecord(
              binding: binding,
              socket: endpoints.controlSocket.path), name: "capture.json")
        } catch {
          // Optional diagnostic publication/configuration cannot demote a healthy
          // ordinary owner into recovery or issue a lifecycle cleanup action.
          coordinator.disableProducerCapture()
          FileHandle.standardError.write(
            Data("Producer capture bootstrap unavailable; ordinary worker retained.\n".utf8))
        }
      }
      if resources.sharedFrameTransport && resources.acceleratedDisplay != nil {
        let shared = try RegisteredWorkerPublication.display(
          vmID: configuration.id, sessionID: owner.sessionID, endpoints: endpoints,
          sharedFrame: true)
        try records.publish(shared, name: "surface.json")
      }
      let display = try RegisteredWorkerPublication.display(
        vmID: configuration.id, sessionID: owner.sessionID, endpoints: endpoints)
      try records.publish(display, name: "display.json")
      if resources.agentChannel != nil {
        let agent = try RegisteredWorkerPublication.agent(
          vmID: configuration.id, sessionID: owner.sessionID, endpoints: endpoints)
        try records.publish(agent, name: "agent.json")
      }
      await custody.ended.wait()
      await backend.refreshOutput()
      guard owner.ownershipState == .settled, !backend.isActive,
        let q = backend.qemuSnapshot, let t = backend.tpmSnapshot,
        q.started, t.started, !q.isActive, !t.isActive, q.termination != nil, t.termination != nil,
        q.drainsFinished, t.drainsFinished
      else { throw registeredWorkerFailure() }
      try plan.revalidate(lock: lock)
      let history = try RuntimeHistoryCodec.decode(
        await files.readMetadata(at: directory.appendingPathComponent("runtime.json"), limit: 4096))
      let intent = try await files.readRuntimeIntent(in: directory)
      guard history.sessionID == owner.sessionID, !history.snapshot.backendActive,
        intent?.vmID == configuration.id, intent?.sessionID == owner.sessionID,
        intent?.state == .settled
      else { throw registeredWorkerFailure() }
      try records.publish(
        RegisteredWorkerResult(
          schemaVersion: 1, scope: "macopenvm-registered-qemu-runtime-result",
          vmID: configuration.id, sessionID: owner.sessionID, outcome: history.snapshot.outcome,
          qemuExit: q.exit?.status, tpmExit: t.exit?.status,
          qemuSignalled: q.exit?.wasSignalled ?? false,
          tpmSignalled: t.exit?.wasSignalled ?? false, drainsFinished: true,
          runtimeIntentSettled: true,
          resourcesRevalidated: true, platformStateFlushed: true,
          windowsCompatibilityVerified: false,
          guestFilesystemVerified: false), name: "result.json")
      await server.finishWhenIdle()
      custody.releaseAfterSettlement()
      withExtendedLifetime((lock, lease, backend, store, owner, coordinator, plan)) {}
    } catch {
      // Even preparation/publication errors after intent keep real custody. No
      // client EOF, cancellation, metadata/PID or timer can release this owner.
      try await finishFailedRun(error, custody: custody)
    }
  }
  static func finishFailedRun(_ error: Error, custody: RegisteredWorkerCustody) async throws {
    await custody.retainForRecovery()
    throw error
  }
}

@MainActor final class RegisteredWorkerCustody {
  let vmID: UUID
  private var lock: VMLock?
  private var lease: VMLock.InheritedLease?
  private var backend: (any BackendSettlementSource)?
  private var store: RegisteredWindowsRuntimeStore?
  let records: RegisteredWorkerRecords
  let ended = RegisteredWorkerEnd()
  var owner: RecordedRuntimeOwner?
  var coordinator: RuntimeWorkerCoordinator?
  var server: WorkerIPCServer?
  private var recovery = false
  private var lifetime: RegisteredWorkerCustody?
  private var recoveryWait: CheckedContinuation<Void, Never>?
  init(
    vmID: UUID, lock: VMLock, lease: VMLock.InheritedLease, backend: any BackendSettlementSource,
    store: RegisteredWindowsRuntimeStore, records: RegisteredWorkerRecords
  ) {
    self.vmID = vmID
    self.lock = lock
    self.lease = lease
    self.backend = backend
    self.store = store
    self.records = records
  }
  func retain() { lifetime = self }
  func handleProducerCapture(_ request: CaptureWorkerRequest, connectionID: UUID)
    async -> CaptureWorkerReply
  {
    guard !recovery, let coordinator else {
      return CaptureWorkerReply(
        binding: request.binding, requestID: request.requestID,
        revision: coordinator?.revision ?? 1, operation: request.operation,
        code: .unavailable, rejection: nil, status: nil, rows: [])
    }
    return await coordinator.handleProducerCapture(request, connectionID: connectionID)
  }
  func captureAttachmentEnded(_ connectionID: UUID, lostReply: Bool) {
    coordinator?.producerCaptureAttachmentEnded(connectionID: connectionID, lostReply: lostReply)
  }
  func handle(_ request: WorkerRequest) async -> WorkerResponse {
    if let coordinator {
      // Identity, observed revision, pending-operation and lifecycle admission
      // remain exclusively the actual Core coordinator's responsibility.
      let foreign = request.vmID != vmID || request.sessionID != owner?.sessionID
      let explicitRecovery =
        owner?.ownershipState == .unsettled && backend?.isActive == true
        && (request.command == .stop || request.command == .forceStop)
      if !recovery || foreign || request.command == .status || explicitRecovery {
        return await coordinator.handle(request)
      }
    }
    return WorkerResponse(
      vmID: vmID, sessionID: owner?.sessionID ?? request.sessionID,
      requestID: request.requestID, revision: coordinator?.revision ?? 1, state: 10, ownership: 3,
      backendActive: backend?.isActive == true, operationPending: false, error: .recovery)
  }
  func retainForRecovery() async {
    recovery = true
    lifetime = self
    try? records.publish(
      RegisteredWorkerRecovery(
        schemaVersion: 1, scope: "macopenvm-registered-qemu-recovery",
        vmID: vmID, sessionID: owner?.sessionID, actualCustodyRetained: true), name: "recovery.json"
    )
    // Only the actual coordinator's completed receipt transaction signals this.
    // A pre-owner failure has no coordinator and remains retained read-only.
    await ended.wait()
    guard owner?.ownershipState == .settled, backend?.isActive == false else {
      await withCheckedContinuation { recoveryWait = $0 }
      return
    }
    await server?.finishWhenIdle()
    _ = releaseAfterSettlement()
  }
  @discardableResult func releaseAfterSettlement() -> Bool {
    guard owner?.ownershipState == .settled, backend?.isActive == false else { return false }
    coordinator = nil
    owner = nil
    server = nil
    backend = nil
    store = nil
    lease = nil
    lock = nil
    lifetime = nil
    return true
  }

}

@MainActor final class RegisteredWorkerEnd {
  private var finished = false
  private var continuation: CheckedContinuation<Void, Never>?
  func complete() {
    finished = true
    continuation?.resume()
    continuation = nil
  }
  func wait() async { if !finished { await withCheckedContinuation { continuation = $0 } } }
}

struct RegisteredWorkerRecords {
  let directory: URL
  private let device: dev_t
  private let inode: ino_t
  init(directory: URL) throws {
    try WindowsExternalFileIO.privateDirectory(directory)
    var info = stat()
    guard lstat(directory.path, &info) == 0 else { throw registeredWorkerFailure() }
    self.directory = directory
    device = info.st_dev
    inode = info.st_ino
  }
  func verify() throws {
    try WindowsExternalFileIO.privateDirectory(directory)
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      info.st_dev == device, info.st_ino == inode
    else { throw registeredWorkerFailure() }
  }
  func publish<T: Encodable>(_ value: T, name: String, beforeOpenParent: (() throws -> Void)? = nil)
    throws
  {
    guard
      [
        "worker.json", "display.json", "surface.json", "agent.json", "result.json", "recovery.json",
        "capture.json",
      ]
      .contains(name)
    else {
      throw registeredWorkerFailure()
    }
    try verify()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard !data.isEmpty, data.count <= 4096 else { throw registeredWorkerFailure() }
    try beforeOpenParent?()
    let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw registeredWorkerFailure() }
    defer { close(parent) }
    var parentInfo = stat()
    guard fstat(parent, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR,
      parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o7777 == 0o700,
      parentInfo.st_dev == device, parentInfo.st_ino == inode
    else { throw registeredWorkerFailure() }
    let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw registeredWorkerFailure() }
    defer { close(fd) }
    guard fchmod(fd, 0o600) == 0 else { throw registeredWorkerFailure() }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw registeredWorkerFailure() }
        offset += count
      }
    }
    var opened = stat()
    var named = stat()
    guard fsync(fd) == 0, fstat(fd, &opened) == 0,
      fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == geteuid(), opened.st_nlink == 1,
      opened.st_mode & 0o7777 == 0o600, opened.st_size == data.count,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, fsync(parent) == 0
    else { throw registeredWorkerFailure() }
    guard fstat(parent, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR,
      parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o7777 == 0o700,
      parentInfo.st_dev == device, parentInfo.st_ino == inode
    else { throw registeredWorkerFailure() }
    try verify()
  }
}

enum RegisteredWorkerPreflight {
  static func readConfiguration(_ directory: URL) throws -> Data {
    try WindowsExternalFileIO.privateDirectory(directory)
    return try WindowsExternalFileIO.readPrivate(
      directory.appendingPathComponent("configuration.json"),
      maximum: ConfigurationCodec.maximumBytes)
  }
  static func prepare(directory: URL, runDirectory: URL, endpointDirectory: URL, lock: VMLock)
    throws -> RegisteredWorkerRecords
  {
    guard lock.owns(directory),
      runDirectory.deletingLastPathComponent().path == directory.path + "/.runtime",
      runDirectory.lastPathComponent.range(of: "^run-[0-9a-f]{32}$", options: .regularExpression)
        != nil,
      endpointDirectory.path.range(
        of: "^/private/tmp/mvo-qemu-[0-9a-f]{16}$", options: .regularExpression) != nil
    else { throw registeredWorkerFailure() }
    try WindowsExternalFileIO.privateDirectory(runDirectory.deletingLastPathComponent())
    let records = try RegisteredWorkerRecords(directory: runDirectory)
    let expected: Set<String> = ["parent-stdout.log", "parent-stderr.log"]
    guard Set(try FileManager.default.contentsOfDirectory(atPath: runDirectory.path)) == expected
    else { throw registeredWorkerFailure() }
    for name in expected {
      try WindowsExternalFileIO.requireRegular(
        runDirectory.appendingPathComponent(name), mode: 0o600, maximum: 16_777_216)
    }
    _ = try QemuRegisteredEndpoints(directory: endpointDirectory)
    let probe = runDirectory.appendingPathComponent(".preflight-" + UUID().uuidString.lowercased())
    let fd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw registeredWorkerFailure() }
    defer { close(fd) }
    var opened = stat()
    var named = stat()
    guard fchmod(fd, 0o600) == 0, fsync(fd) == 0, fstat(fd, &opened) == 0,
      lstat(probe.path, &named) == 0,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, named.st_nlink == 1,
      unlink(probe.path) == 0
    else { throw registeredWorkerFailure() }
    let parent = open(runDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw registeredWorkerFailure() }
    defer { close(parent) }
    guard fsync(parent) == 0, lock.owns(directory) else { throw registeredWorkerFailure() }
    try records.verify()
    return records
  }
  static func validateStreams(runDirectory: URL, input: Int32, output: Int32, error: Int32) throws {
    let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard null >= 0 else { throw registeredWorkerFailure() }
    defer { close(null) }
    var expected = stat()
    var actual = stat()
    guard fstat(null, &expected) == 0, fstat(input, &actual) == 0,
      actual.st_mode & S_IFMT == S_IFCHR, expected.st_rdev == actual.st_rdev
    else { throw registeredWorkerFailure() }
    var identities: [String] = []
    for (fd, name) in [(output, "parent-stdout.log"), (error, "parent-stderr.log")] {
      var info = stat()
      var named = stat()
      guard fstat(fd, &info) == 0,
        lstat(runDirectory.appendingPathComponent(name).path, &named) == 0,
        info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
        info.st_mode & 0o7777 == 0o600,
        info.st_dev == named.st_dev, info.st_ino == named.st_ino
      else { throw registeredWorkerFailure() }
      identities.append("\(info.st_dev):\(info.st_ino)")
    }
    guard Set(identities).count == 2 else { throw registeredWorkerFailure() }
  }
}

enum RegisteredWorkerPublication {
  /// A location bound to this selected session, never Windows driver or health
  /// evidence. The QEMU process owns the listener; publication adopts no owner.
  static func agent(vmID: UUID, sessionID: UUID, endpoints: QemuRegisteredEndpoints) throws
    -> RegisteredWorkerAgent
  {
    guard endpoints.agentChannel == .virtioSerialV1, let path = endpoints.agentSocket else {
      throw registeredWorkerFailure()
    }
    try endpoints.revalidateParent()
    var parent = stat()
    var socket = stat()
    guard lstat(endpoints.directory.path, &parent) == 0,
      lstat(path.path, &socket) == 0,
      socket.st_mode & S_IFMT == S_IFSOCK, socket.st_uid == geteuid(), socket.st_nlink == 1,
      socket.st_mode & 0o077 == 0, socket.st_mode & 0o600 == 0o600,
      socket.st_mode & 0o7000 == 0
    else { throw registeredWorkerFailure() }
    try endpoints.revalidateParent()
    return RegisteredWorkerAgent(
      schemaVersion: 1, scope: "macopenvm-registered-qemu-agent-route", vmID: vmID,
      sessionID: sessionID, controlSocket: endpoints.controlSocket.path,
      agentSocket: path.path,
      parentDevice: parent.st_dev, parentInode: parent.st_ino, socketDevice: socket.st_dev,
      socketInode: socket.st_ino)
  }
  static func display(
    vmID: UUID, sessionID: UUID, endpoints: QemuRegisteredEndpoints,
    sharedFrame: Bool = false
  ) throws
    -> RegisteredWorkerDisplay
  {
    try endpoints.revalidateParent()
    var parent = stat()
    var socket = stat()
    let path = sharedFrame ? endpoints.sharedFrameSocket : endpoints.displaySocket
    guard lstat(endpoints.directory.path, &parent) == 0,
      lstat(path.path, &socket) == 0,
      socket.st_mode & S_IFMT == S_IFSOCK, socket.st_uid == geteuid(), socket.st_nlink == 1,
      socket.st_mode & 0o077 == 0, socket.st_mode & 0o600 == 0o600,
      socket.st_mode & 0o7000 == 0
    else { throw registeredWorkerFailure() }
    return RegisteredWorkerDisplay(
      schemaVersion: 1,
      scope: sharedFrame
        ? "macopenvm-registered-qemu-shared-frame-route"
        : "macopenvm-registered-qemu-display-route", vmID: vmID,
      sessionID: sessionID, controlSocket: endpoints.controlSocket.path,
      displaySocket: path.path,
      parentDevice: parent.st_dev, parentInode: parent.st_ino, socketDevice: socket.st_dev,
      socketInode: socket.st_ino)
  }
}
struct RegisteredWorkerRoute: Encodable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let socket: String
}
struct RegisteredWorkerDisplay: Encodable {
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
struct RegisteredWorkerAgent: Encodable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let controlSocket: String
  let agentSocket: String
  let parentDevice: dev_t
  let parentInode: ino_t
  let socketDevice: dev_t
  let socketInode: ino_t
}
struct RegisteredWorkerResult: Encodable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let outcome: RuntimeOutcome
  let qemuExit: Int32?
  let tpmExit: Int32?
  let qemuSignalled: Bool
  let tpmSignalled: Bool
  let drainsFinished: Bool
  let runtimeIntentSettled: Bool
  let resourcesRevalidated: Bool
  let platformStateFlushed: Bool
  let windowsCompatibilityVerified: Bool
  let guestFilesystemVerified: Bool
}
struct RegisteredWorkerRecovery: Encodable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID
  let sessionID: UUID?
  let actualCustodyRetained: Bool
}
func registeredWorkerFailure() -> VMError {
  VMError(
    .storage, "The registered Windows worker could not confirm its preparation or settlement.",
    recovery: "Preserve the actual worker and VM files; reconnect status for recovery review.")
}
