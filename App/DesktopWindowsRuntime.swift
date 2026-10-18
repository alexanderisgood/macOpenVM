// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Qemu
import RuntimeIPC
import VMCore
import VMStorage

/// Regular parent logs have descriptor closure, not pipe EOF. Child EOF/drains
/// are admitted only from the exact registered producer's settlement record.
struct DesktopWindowsParentSnapshot: Sendable {
  let submitted: Bool
  let started: Bool
  let reaped: Bool
  let descriptorsClosed: Bool
  let exitStatus: Int32?
  let signalled: Bool
  let failure: VMError?
  var isActive: Bool { submitted && !(reaped && descriptorsClosed) }
}

/// One actual LeaseSpawn.Child owns waitpid and the exit event source. It does
/// not set a process group, so the proven worker can call setsid itself.
actor DesktopWindowsParent {
  private var child: LeaseSpawn.Child?
  private let executable: URL
  private let arguments: [String]
  private let directory: URL
  private let runDirectory: URL
  private var handles: [FileHandle] = []
  private var submitted = false
  private var started = false
  private var reaped = false
  private var closed = false
  private var status: Int32?
  private var signalled = false
  private var failure: VMError?
  private var reaper: Task<Void, Never>?
  private var waiters: [CheckedContinuation<DesktopWindowsParentSnapshot, Never>] = []

  init(executable: URL, arguments: [String], directory: URL, runDirectory: URL) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.runDirectory = runDirectory
  }
  func snapshot() -> DesktopWindowsParentSnapshot {
    DesktopWindowsParentSnapshot(
      submitted: submitted, started: started, reaped: reaped,
      descriptorsClosed: closed, exitStatus: status, signalled: signalled, failure: failure)
  }
  func launch() async throws {
    guard !submitted, handles.isEmpty else { throw desktopWindowsFailure() }
    do {
      try Task.checkCancellation()
      try DesktopWindowsIO.privateDirectory(directory)
      try DesktopWindowsIO.privateDirectory(runDirectory)
      let input = open("/dev/null", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard input >= 0 else { throw desktopWindowsFailure() }
      handles.append(FileHandle(fileDescriptor: input, closeOnDealloc: false))
      for name in ["parent-stdout.log", "parent-stderr.log"] {
        let fd = open(
          runDirectory.appendingPathComponent(name).path,
          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw desktopWindowsFailure() }
        handles.append(FileHandle(fileDescriptor: fd, closeOnDealloc: false))
        guard fchmod(fd, 0o600) == 0 else { throw desktopWindowsFailure() }
      }
      submitted = true
      let actual = try await LeaseSpawn.spawn(
        configuration: .init(
          executable: executable, arguments: arguments,
          environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
          workingDirectory: directory, standardInput: handles[0].fileDescriptor,
          standardOutput: handles[1].fileDescriptor, standardError: handles[2].fileDescriptor,
          inheritedDescriptors: []))
      child = actual
      started = true
      reaper = Task { [self, actual] in await observeTermination(actual) }
    } catch {
      failure = (error as? VMError) ?? desktopWindowsFailure()
      // The unchanged spawn helper returns a Child on every successful spawn,
      // even after waiter cancellation. These exact errors occur before that
      // ownership return and prove that no child was created.
      if !submitted || Self.provesNoChild(error) {
        submitted = false
        closeDescriptors()
        finishWaiters()
      }
      // An unknown spawn/observation failure remains owned. No PID/state guess,
      // failed waiter, cancellation or deinit can release actual child custody.
      throw error
    }
  }
  func waitForTermination() async -> DesktopWindowsParentSnapshot {
    if reaped || (!submitted && closed) { return snapshot() }
    return await withCheckedContinuation { waiters.append($0) }
  }
  private func observeTermination(_ actual: LeaseSpawn.Child) async {
    guard child === actual, submitted, !reaped else { return }
    do {
      let exit = try await actual.wait()
      guard child === actual else { return }
      status = exit.status
      signalled = exit.wasSignalled
      reaped = true
      closeDescriptors()
    } catch {
      // Keep the exact Child and its monitor/descriptor ownership. A failed
      // observation is never a terminal status and never permission to signal.
      failure = failure ?? desktopWindowsFailure()
    }
    finishWaiters()
    reaper = nil
  }
  private static func provesNoChild(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    guard let error = error as? LeaseSpawnError else { return false }
    switch error {
    case .invalidConfiguration, .invalidDescriptor, .descriptorFailure, .spawnFailure: return true
    default: return false
    }
  }
  private func closeDescriptors() {
    do {
      for (index, handle) in handles.enumerated() {
        if index > 0 {
          guard fsync(handle.fileDescriptor) == 0 else { throw desktopWindowsFailure() }
        }
        try handle.close()
      }
      handles.removeAll()
      closed = true
    } catch { failure = failure ?? desktopWindowsFailure() }
  }
  private func finishWaiters() {
    let value = snapshot()
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume(returning: value) }
  }
}

struct DesktopWindowsTermination: Sendable {
  let outcome: RuntimeOutcome
  let producerQualified: Bool
  let parentReaped: Bool
  let regularDescriptorsClosed: Bool
  let failed: Bool
}

/// The App retains this actual parent through terminal observation and storage
/// admission. A route only correlates the current worker; it never launches one.
@MainActor final class DesktopWindowsRuntime {
  private let runningActivity = RunningVMActivity()
  enum Phase { case idle, preparing, running, recoveryRequired, settled }
  let configuration: VMConfiguration
  let directory: URL
  let launchGeneration = UUID()
  private(set) var phase = Phase.idle
  private(set) var sessionID: UUID?
  private(set) var status: WorkerResponse?
  private(set) var displayContext: RegisteredRfbDisplayContext?
  private(set) var lastFailure: VMError?
  private(set) var termination: DesktopWindowsTermination?
  var isBusy: Bool { phase != .idle && phase != .settled }
  var isActive: Bool { status?.backendActive == true || (parent != nil && phase != .settled) }
  var state: VMState {
    if phase == .settled { return termination?.failed == true ? .failed : .stopped }
    if let status { return VMState.allCases[Int(status.state)] }
    return phase == .idle ? .stopped : (phase == .recoveryRequired ? .failed : .starting)
  }
  var onStateChange: (@MainActor (VMState) -> Void)?
  var onError: (@MainActor (VMError) -> Void)?
  var onChange: (@MainActor () -> Void)?
  var onSettled: (@MainActor (DesktopWindowsTermination) -> Void)?
  private let worker: ReviewedBundledWindowsWorker
  private let displayEvaluation: ReviewedQemu2DDisplay?
  private let acceleratedDisplay: ReviewedQemuAcceleratedDisplay?
  private let producerCapture: CaptureCapability?
  private var parent: DesktopWindowsParent?
  private var runDirectory: URL?
  private var endpoints: URL?
  private var priorSession: UUID?
  private var monitor: Task<Void, Never>?
  private var controlObservation: Task<Void, Never>?
  private var lifetime: DesktopWindowsRuntime?

  init(
    configuration: VMConfiguration, directory: URL, worker: ReviewedBundledWindowsWorker,
    displayEvaluation: ReviewedQemu2DDisplay? = nil,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay? = nil,
    producerCapture: CaptureCapability? = nil
  ) {
    self.configuration = configuration
    self.directory = directory
    self.worker = worker
    self.displayEvaluation = displayEvaluation
    self.acceleratedDisplay = acceleratedDisplay
    self.producerCapture = producerCapture
  }
  func launch() async throws {
    guard phase == .idle else { throw desktopWindowsFailure() }
    phase = .preparing
    lifetime = self
    notify()
    do {
      try await revalidateWorker()
      priorSession = try await Self.preflight(
        configuration: configuration, in: directory,
        displayEvaluation: displayEvaluation, acceleratedDisplay: acceleratedDisplay,
        producerCapture: producerCapture)
      let token = launchGeneration.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      let records = directory.appendingPathComponent(".runtime", isDirectory: true)
      if !FileManager.default.fileExists(atPath: records.path) {
        try FileManager.default.createDirectory(
          at: records, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
      try DesktopWindowsIO.privateDirectory(records)
      let run = records.appendingPathComponent("run-" + token, isDirectory: true)
      let endpoint = URL(
        fileURLWithPath: "/private/tmp/mvo-qemu-" + token.prefix(16), isDirectory: true)
      for path in [run, endpoint] {
        try FileManager.default.createDirectory(
          at: path, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        try DesktopWindowsIO.privateDirectory(path)
      }
      runDirectory = run
      endpoints = endpoint
      try await revalidateWorker()
      let workerArguments = try Self.workerArguments(
        directory: directory, runDirectory: run, endpointDirectory: endpoint,
        displayEvaluation: displayEvaluation, acceleratedDisplay: acceleratedDisplay,
        producerCapture: producerCapture)
      let actual = DesktopWindowsParent(
        executable: worker.executableURL,
        arguments: workerArguments, directory: directory, runDirectory: run)
      parent = actual
      monitor = Task { [self, actual] in
        let terminal = await actual.waitForTermination()
        await observeTermination(terminal, from: actual)
      }
      try await actual.launch()
      let deadline = ContinuousClock().now.advanced(by: .seconds(120))
      while ContinuousClock().now < deadline {
        try Task.checkCancellation()
        guard await actual.snapshot().isActive else { throw desktopWindowsFailure() }
        if let current = try await locateSession(), current.state == 2, current.error == .none,
          current.ownership == 0, current.backendActive, !current.operationPending
        {
          let url = run.appendingPathComponent("display.json")
          if FileManager.default.fileExists(atPath: url.path) {
            let data = try DesktopWindowsIO.read(url, maximum: FlatDisplayRouteCodec.maximumBytes)
            let route = try FlatDisplayRouteCodec.decode(data, profile: .registeredQemu)
            guard route.controlSocket == endpoint.appendingPathComponent("worker.sock").path,
              route.displaySocket == endpoint.appendingPathComponent("vnc.sock").path
            else { throw desktopWindowsFailure() }
            let actualState = await actual.snapshot()
            guard parent === actual, phase == .preparing, actualState.isActive
            else { throw desktopWindowsFailure() }
            let sharedURL = run.appendingPathComponent("surface.json")
            let sharedData =
              acceleratedDisplay != nil && FileManager.default.fileExists(atPath: sharedURL.path)
              ? try DesktopWindowsIO.read(sharedURL, maximum: FlatDisplayRouteCodec.maximumBytes)
              : nil
            displayContext = try RegisteredRfbDisplayContext(
              configuration: configuration,
              directory: directory, sessionID: current.sessionID,
              launchGeneration: launchGeneration,
              readinessDirectory: run, readinessURL: url, readinessData: data,
              expectedReadinessSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }
                .joined(),
              route: route, sharedReadinessData: sharedData)
            phase = .running
            notify()
            return
          }
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw desktopWindowsFailure()
    } catch {
      lastFailure = (error as? VMError) ?? desktopWindowsFailure()
      if phase == .settled {
        // Actual terminal settlement can precede the start awaiter returning.
      } else if parent == nil {
        // No native call or permit was submitted in the App preflight.
        phase = .settled
        lifetime = nil
      } else {
        phase = .recoveryRequired
      }
      onError?(lastFailure ?? desktopWindowsFailure())
      notify()
      throw error
    }
  }
  /// Every connection reconciles status and revision anew. Cancellation affects
  /// that IPC connection only, never the actual parent or its terminal monitor.
  func perform(_ operation: LifecycleOperation) async throws {
    let command: WorkerCommand
    switch operation {
    case .stop: command = .stop
    case .forceStop: command = .forceStop
    case .pause: command = .pause
    case .resume: command = .resume
    default: throw desktopWindowsFailure()
    }
    try await perform(command)
  }
  func perform(_ command: WorkerCommand) async throws {
    if command == .status {
      try await refreshStatus()
      return
    }
    guard phase == .running || phase == .recoveryRequired,
      command == .stop || command == .forceStop || phase == .running,
      let parent, await parent.snapshot().isActive,
      let current = try await locateSession(), let endpoints, let sessionID
    else { throw desktopWindowsFailure() }
    try await revalidateWorker()
    let client = WorkerIPCClient(
      socketURL: endpoints.appendingPathComponent("worker.sock"),
      vmID: configuration.id, sessionID: sessionID,
      timeout: command == .forceStop ? .seconds(30) : .seconds(3))
    do {
      try await client.connect()
      let fresh = try await client.request(.status)
      guard fresh.vmID == current.vmID, fresh.sessionID == current.sessionID,
        fresh.ownership == 0, fresh.backendActive, !fresh.operationPending
      else { throw desktopWindowsFailure() }
      let reply = try await client.request(command, observedRevision: fresh.revision)
      if Self.acceptsStatus(reply, after: status) { status = reply }
      await client.close()
      notify()
      observeControlCompletion()
    } catch {
      await client.close()
      throw error
    }
  }
  /// Pure closed argument recipe only. This cannot mint a reviewed worker,
  /// launch a process, adopt a saved owner, or supply an arbitrary monitor path.
  static func workerArguments(
    directory: URL, runDirectory: URL, endpointDirectory: URL,
    displayEvaluation: ReviewedQemu2DDisplay? = nil,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay? = nil,
    producerCapture: CaptureCapability? = nil
  ) throws -> [String] {
    try requireCaptureSelection(
      displayEvaluation: displayEvaluation,
      acceleratedDisplay: acceleratedDisplay, producerCapture: producerCapture)
    var workerArguments = [
      producerCapture != nil
        ? "windows-producer-capture-worker-lab"
        : acceleratedDisplay != nil
          ? "windows-gpu-worker-lab"
          : displayEvaluation == nil ? "windows-worker" : "windows-display-worker-lab",
      "--directory", directory.path, "--run-directory", runDirectory.path,
      "--endpoint-directory", endpointDirectory.path,
    ]
    if let displayEvaluation {
      workerArguments += [
        "--display-profile", "virtio-gpu-2d-evaluation",
        "--display-width", String(displayEvaluation.initialPixels.width),
        "--display-height", String(displayEvaluation.initialPixels.height),
      ]
    }
    if let acceleratedDisplay {
      workerArguments += [
        "--display-profile", "neptune-metal-evaluation",
        "--display-width", String(acceleratedDisplay.initialPixels.width),
        "--display-height", String(acceleratedDisplay.initialPixels.height),
        "--gpu-host-window", acceleratedDisplay.hostWindow.rawValue,
        "--gpu-refresh-millihertz", acceleratedDisplay.refreshRate.rawValue,
      ]
    }
    if producerCapture != nil {
      workerArguments += ["--capture-profile", "bounded-producer-v1-signed"]
    }
    return workerArguments
  }

  private static func requireCaptureSelection(
    displayEvaluation: ReviewedQemu2DDisplay?,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay?, producerCapture: CaptureCapability?
  ) throws {
    guard
      producerCapture == nil
        || (producerCapture == .boundedProducerV1
          && acceleratedDisplay != nil && displayEvaluation == nil)
    else { throw desktopWindowsFailure() }
  }

  static func acceptsStatus(_ next: WorkerResponse, after prior: WorkerResponse?) -> Bool {
    guard let prior else { return true }
    return next.vmID == prior.vmID && next.sessionID == prior.sessionID
      && next.revision >= prior.revision
  }

  private func observeControlCompletion() {
    guard controlObservation == nil, let expected = parent else { return }
    controlObservation = Task { @MainActor [weak self, expected] in
      defer { self?.controlObservation = nil }
      while let self, self.parent === expected, self.phase != .settled,
        let current = self.status, current.operationPending || current.state == 3
      {
        do {
          try await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled, self.parent === expected, self.phase != .settled else { return }
          try await self.refreshStatus()
        } catch {
          guard !Task.isCancelled, self.parent === expected, self.phase != .settled else { return }
          self.lastFailure = (error as? VMError) ?? desktopWindowsFailure()
          self.onError?(self.lastFailure ?? desktopWindowsFailure())
          self.notify()
          return
        }
      }
    }
  }

  func refreshStatus() async throws {
    _ = try await locateSession()
    notify()
  }
  private func locateSession() async throws -> WorkerResponse? {
    guard let actual = parent, await actual.snapshot().isActive, let endpoints else { return nil }
    let files = VMFiles()
    guard let intent = try await files.readRuntimeIntent(in: directory) else { return nil }
    guard
      let candidate = try Self.sessionCandidate(
        intent, vmID: configuration.id, priorSession: priorSession,
        adoptedSession: sessionID, preparing: phase == .preparing)
    else { return nil }
    guard await files.writerStatus(in: directory) == .held
    else { throw desktopWindowsFailure() }
    let client = WorkerIPCClient(
      socketURL: endpoints.appendingPathComponent("worker.sock"),
      vmID: configuration.id, sessionID: candidate)
    do {
      try await client.connect()
      let value = try await client.request(.status)
      await client.close()
      let actualState = await actual.snapshot()
      guard parent === actual, phase != .settled, actualState.isActive else {
        throw desktopWindowsFailure()
      }
      sessionID = candidate
      if Self.acceptsStatus(value, after: status) { status = value }
      return value
    } catch {
      await client.close()
      if sessionID == nil { return nil }  // Startup socket may not yet be published.
      throw error
    }
  }
  /// The exact preflight prior record can remain visible before the retained
  /// new parent publishes its intent. It is a bounded wait, never a current session.
  static func sessionCandidate(
    _ intent: RuntimeIntent, vmID: UUID, priorSession: UUID?, adoptedSession: UUID?, preparing: Bool
  ) throws -> UUID? {
    guard intent.vmID == vmID else { throw desktopWindowsFailure() }
    if preparing, adoptedSession == nil, intent.state == .settled,
      intent.sessionID == priorSession
    {
      return nil
    }
    guard intent.state == .unsettled, intent.sessionID != priorSession,
      adoptedSession == nil || adoptedSession == intent.sessionID
    else { throw desktopWindowsFailure() }
    return intent.sessionID
  }
  private func observeTermination(
    _ snapshot: DesktopWindowsParentSnapshot,
    from actual: DesktopWindowsParent
  ) async {
    guard parent === actual, let runDirectory else { return }
    do {
      try await revalidateWorker()
      let result = try await Self.qualifyTermination(
        configuration: configuration, in: directory,
        runDirectory: runDirectory, sessionID: sessionID, priorSessionID: priorSession,
        parent: snapshot)
      termination = result
      displayContext = nil
      phase = .settled
      controlObservation?.cancel()
      controlObservation = nil
      parent = nil
      monitor = nil
      onSettled?(result)
      notify()
      lifetime = nil
    } catch {
      lastFailure = (error as? VMError) ?? desktopWindowsFailure()
      phase = .recoveryRequired
      onError?(lastFailure ?? desktopWindowsFailure())
      notify()
      // Real parent, private paths and actual terminal evidence stay retained.
    }
  }
  private func revalidateWorker() async throws {
    let value = worker
    try await Task.detached(priority: .utility) { try value.revalidate() }.value
  }
  private func notify() {
    runningActivity.update(
      active: phase == .preparing
        || ((phase == .running || phase == .recoveryRequired) && state != .paused
          && status?.backendActive != false)
    )
    onStateChange?(state)
    onChange?()
  }
  static func preflight(
    configuration: VMConfiguration, in directory: URL,
    displayEvaluation: ReviewedQemu2DDisplay? = nil,
    acceleratedDisplay: ReviewedQemuAcceleratedDisplay? = nil,
    producerCapture: CaptureCapability? = nil
  ) async throws -> UUID? {
    try requireCaptureSelection(
      displayEvaluation: displayEvaluation,
      acceleratedDisplay: acceleratedDisplay, producerCapture: producerCapture)
    try DesktopWindowsIO.privateDirectory(directory)
    guard
      try ConfigurationCodec.decode(
        DesktopWindowsIO.read(
          directory.appendingPathComponent("configuration.json"), maximum: 65_536)) == configuration
    else { throw desktopWindowsFailure() }
    let lock = try VMLock(directory: directory, expectedVMID: configuration.id)
    let files = VMFiles()
    let intent = try await files.readRuntimeIntent(in: directory)
    guard intent == nil || (intent?.vmID == configuration.id && intent?.state == .settled)
    else { throw desktopWindowsFailure() }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    try await QemuRegisteredAdmission.validateStoredState(
      configuration: configuration, in: directory,
      platformIdentity: DesktopWindowsIO.read(
        directory.appendingPathComponent("qemu-platform.json"), maximum: 8192),
      resources: producerCapture != nil
        ? QemuRegisteredCatalog.producerCaptureEvaluation(
          for: configuration, projectRoot: project)
        : acceleratedDisplay != nil
          ? QemuRegisteredCatalog.acceleratedDisplayEvaluation(
            for: configuration, projectRoot: project)
          : displayEvaluation == nil
            ? QemuRegisteredCatalog.registeredEvaluation(for: configuration, projectRoot: project)
            : QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(
              for: configuration, projectRoot: project),
      lock: lock)
    withExtendedLifetime(lock) {}
    return intent?.sessionID
  }
  static func qualifyTermination(
    configuration: VMConfiguration, in directory: URL,
    runDirectory: URL, sessionID: UUID?, priorSessionID: UUID? = nil,
    parent: DesktopWindowsParentSnapshot
  ) async throws
    -> DesktopWindowsTermination
  {
    let neverInvoked =
      !parent.submitted && !parent.started && !parent.reaped && parent.exitStatus == nil
    guard parent.descriptorsClosed, !parent.isActive,
      neverInvoked
        || (parent.submitted && parent.started && parent.reaped && parent.exitStatus != nil
          && parent.failure == nil)
    else { throw desktopWindowsFailure() }
    try DesktopWindowsIO.privateDirectory(directory)
    let lock = try VMLock(directory: directory, expectedVMID: configuration.id)
    defer { withExtendedLifetime(lock) {} }
    guard
      try ConfigurationCodec.decode(
        DesktopWindowsIO.read(
          directory.appendingPathComponent("configuration.json"), maximum: 65_536)) == configuration
    else { throw desktopWindowsFailure() }
    let files = VMFiles()
    let intent = try await files.readRuntimeIntent(in: directory)
    if intent == nil || (sessionID == nil && intent?.sessionID == priorSessionID) {
      guard sessionID == nil,
        intent == nil || (intent?.vmID == configuration.id && intent?.state == .settled)
      else { throw desktopWindowsFailure() }
      for name in [
        "worker.json", "display.json", "surface.json", "capture.json", "result.json",
        "recovery.json",
        "qemu-stdout.log", "qemu-stderr.log", "tpm-stdout.log", "tpm-stderr.log",
      ] {
        guard (await files.status(at: runDirectory.appendingPathComponent(name))).kind == .missing
        else { throw desktopWindowsFailure() }
      }
      if intent == nil {
        guard
          (await files.status(at: directory.appendingPathComponent("runtime.json"))).kind
            == .missing
        else { throw desktopWindowsFailure() }
      } else {
        let previous = try RuntimeHistoryCodec.decode(
          DesktopWindowsIO.read(
            directory.appendingPathComponent("runtime.json"), maximum: 4096))
        guard previous.sessionID == priorSessionID, !previous.snapshot.backendActive,
          previous.snapshot.operation == nil, previous.snapshot.outcome != .pending
        else { throw desktopWindowsFailure() }
      }
      return DesktopWindowsTermination(
        outcome: .failed, producerQualified: false,
        parentReaped: parent.reaped, regularDescriptorsClosed: true, failed: true)
    }
    guard !neverInvoked, let intent, intent.vmID == configuration.id, intent.state == .settled,
      intent.sessionID != priorSessionID, sessionID == nil || sessionID == intent.sessionID
    else { throw desktopWindowsFailure() }
    let history = try RuntimeHistoryCodec.decode(
      DesktopWindowsIO.read(
        directory.appendingPathComponent("runtime.json"), maximum: 4096))
    guard history.sessionID == intent.sessionID, !history.snapshot.backendActive,
      history.snapshot.operation == nil, history.snapshot.outcome != .pending
    else { throw desktopWindowsFailure() }
    var qualified = false
    var childFailed = false
    do {
      let result: DesktopWindowsProducerResult = try DesktopWindowsIO.canonical(
        DesktopWindowsIO.read(runDirectory.appendingPathComponent("result.json"), maximum: 4096))
      guard result.schemaVersion == 1, result.scope == "macopenvm-registered-qemu-runtime-result",
        result.vmID == configuration.id, result.sessionID == intent.sessionID,
        result.outcome == history.snapshot.outcome, result.drainsFinished,
        result.runtimeIntentSettled,
        result.resourcesRevalidated, result.platformStateFlushed,
        !result.windowsCompatibilityVerified, !result.guestFilesystemVerified,
        result.qemuExit != nil, result.tpmExit != nil
      else { throw desktopWindowsFailure() }
      qualified = true
      childFailed =
        result.qemuExit != 0 || result.tpmExit != 0 || result.qemuSignalled || result.tpmSignalled
    } catch { qualified = false }
    return DesktopWindowsTermination(
      outcome: history.snapshot.outcome, producerQualified: qualified,
      parentReaped: true, regularDescriptorsClosed: true,
      failed: !qualified || childFailed || parent.exitStatus != 0 || parent.signalled
        || history.snapshot.outcome == .failed)
  }
}

private struct DesktopWindowsProducerResult: Codable {
  let schemaVersion: Int, scope: String
  let vmID: UUID, sessionID: UUID
  let outcome: RuntimeOutcome
  let qemuExit: Int32?, tpmExit: Int32?
  let qemuSignalled: Bool, tpmSignalled: Bool, drainsFinished: Bool
  let runtimeIntentSettled: Bool, resourcesRevalidated: Bool, platformStateFlushed: Bool
  let windowsCompatibilityVerified: Bool, guestFilesystemVerified: Bool
}

private enum DesktopWindowsIO {
  static func privateDirectory(_ url: URL) throws {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
      !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw desktopWindowsFailure() }
    var path = ""
    for part in url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
      guard !part.isEmpty, part != ".", part != ".." else { throw desktopWindowsFailure() }
      path += "/" + part
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == 0 || info.st_uid == geteuid(),
        info.st_mode & 0o022 == 0
          || (path == "/private/tmp" && info.st_uid == 0 && info.st_mode & S_ISVTX != 0)
      else { throw desktopWindowsFailure() }
    }
    var leaf = stat()
    guard lstat(url.path, &leaf) == 0, leaf.st_uid == geteuid(), leaf.st_mode & 0o7777 == 0o700
    else { throw desktopWindowsFailure() }
  }
  static func read(_ url: URL, maximum: Int) throws -> Data {
    let directory = url.deletingLastPathComponent()
    try privateDirectory(directory)
    let anchor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard anchor >= 0 else { throw desktopWindowsFailure() }
    defer { close(anchor) }
    var parent = stat()
    var namedParent = stat()
    guard fstat(anchor, &parent) == 0 else { throw desktopWindowsFailure() }
    let fd = openat(anchor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw desktopWindowsFailure() }
    defer { close(fd) }
    var before = stat()
    var after = stat()
    var named = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
      before.st_size > 0, before.st_size <= maximum
    else { throw desktopWindowsFailure() }
    let bytes =
      try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1)
      ?? Data()
    guard bytes.count == before.st_size, fstat(fd, &after) == 0,
      fstatat(anchor, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
      before.st_mode == after.st_mode, before.st_uid == after.st_uid,
      before.st_nlink == after.st_nlink,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      after.st_dev == named.st_dev, after.st_ino == named.st_ino, after.st_mode == named.st_mode,
      lstat(directory.path, &namedParent) == 0,
      parent.st_dev == namedParent.st_dev, parent.st_ino == namedParent.st_ino
    else { throw desktopWindowsFailure() }
    try privateDirectory(directory)
    return bytes
  }
  static func canonical<T: Codable>(_ data: Data) throws -> T {
    let value = try JSONDecoder().decode(T.self, from: data)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard try encoder.encode(value) == data else { throw desktopWindowsFailure() }
    return value
  }
}

private func desktopWindowsFailure() -> VMError {
  VMError(
    .storage, "The Windows worker session could not be confirmed.",
    recovery:
      "Preserve this window and its actual worker; inspect the selected session before recovery.")
}
