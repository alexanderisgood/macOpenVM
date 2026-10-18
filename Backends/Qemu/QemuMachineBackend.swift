// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// Executable runtime inputs are prepared and validated by the guest-specific launcher.
/// This process contract does not assert Windows platform or driver support.
public struct QemuRuntimePlan: Sendable {
  public let qemu: OwnedProcess.Configuration
  public let tpm: OwnedProcess.Configuration
  public let qmpSocket: URL
  public let tpmSocket: URL

  public init(
    qemu: OwnedProcess.Configuration, tpm: OwnedProcess.Configuration,
    qmpSocket: URL, tpmSocket: URL
  ) {
    self.qemu = qemu
    self.tpm = tpm
    self.qmpSocket = qmpSocket
    self.tpmSocket = tpmSocket
  }
}

/// A process/QMP owner. Active includes every launched child and unfinished drain.
/// Callers retain their writer lease until isActive becomes false.
@MainActor
public final class QemuMachineBackend: MachineBackend {
  public let capabilities = BackendCapabilities(
    id: .qemuHVF, operations: [.start, .stop, .forceStop, .pause, .resume],
    limitations: [
      "Experimental process runtime; Windows installation and devices are unverified.",
      "Experimental shutdown requires monitor provenance and complete owned-process settlement.",
      "Suspend, display and snapshot integrity are not implemented here.",
      "Caller-only writer lease; owner-crash protection requires a guardian before production disks.",
    ])
  public var onGuestStopped: (@MainActor () -> Void)?
  public var onFailure: (@MainActor (VMError) -> Void)?
  public private(set) var lastFailure: VMError?
  public private(set) var lastStatus: QMPStatus?
  public private(set) var qemuSnapshot: OwnedProcess.Snapshot?
  public private(set) var tpmSnapshot: OwnedProcess.Snapshot?
  public private(set) var terminationObservation: BackendTerminationObservation = .notObserved
  public var isActive: Bool {
    starting || normalStopPending || tpmAssessmentPending || monitorPending
      || qemuSnapshot?.isActive == true || tpmSnapshot?.isActive == true
  }
  package var isControlPending: Bool { operationPending }
  /// Private lab evidence from this exact finished reader; live/foreign observations
  /// are never exported and this snapshot grants no lifecycle or writer authority.
  package var settledMonitorObservation: QMPMonitorObservation? {
    guard !isActive, let observation = monitorObservation, observation.readerDrained,
      observation.connectionEpoch == monitorEpoch
    else { return nil }
    return observation
  }

  private let plan: QemuRuntimePlan
  private let producerCaptureVMID: UUID?
  private let producerCaptureCapability: CaptureCapability?
  private var producerArmAttempted = false
  private var producerStopAttempted = false
  private var producerDiagnosticClosed = false
  private var producerCaptureID: UInt64 = 0
  private var qemu: OwnedProcess?
  private var tpm: OwnedProcess?
  private var qmp: QMPClient?
  private var monitorEpoch: UUID?
  private var monitorObservation: QMPMonitorObservation?
  private var monitorPending = false
  private var monitorSettlementTask: Task<Void, Never>?
  private var normalStopTask: Task<Void, Never>?
  private var normalStopPending = false
  private var tpmAssessmentTask: Task<Void, Never>?
  private var tpmAssessmentPending = false
  private var tpmAssessmentAttempted = false
  private var starting = false
  private var operationPending = false
  private var startedOnce = false
  private var startAttemptCompleted = false
  private var startEstablished = false
  private var settlementSealed = false
  private var recordedSessionID: UUID?
  private var operationAttempted = false
  private var forceRequested = false
  private var stoppedNotified = false
  private var activeLifetime: QemuMachineBackend?

  public init(plan: QemuRuntimePlan) {
    self.plan = plan
    producerCaptureVMID = nil
    producerCaptureCapability = nil
  }

  /// The private registered worker supplies this only after fixed signed
  /// resources have passed actual admission. Wire/configuration data cannot.
  package init(
    plan: QemuRuntimePlan, producerCaptureVMID: UUID,
    producerCaptureCapability: CaptureCapability
  ) {
    self.plan = plan
    self.producerCaptureVMID = producerCaptureVMID
    self.producerCaptureCapability = producerCaptureCapability
  }

  package func producerCaptureBinding(vmID: UUID, sessionID: UUID) throws -> CaptureBinding {
    guard producerCaptureCapability == .boundedProducerV1,
      producerCaptureVMID == vmID, recordedSessionID == sessionID,
      !producerDiagnosticClosed, !settlementSealed, startEstablished,
      !starting, !normalStopPending, qemuSnapshot?.running == true,
      tpmSnapshot?.running == true, lastStatus?.running == true, lastFailure == nil,
      monitorPending, let qmp, qmp.connectionEpoch == monitorEpoch
    else { throw CaptureFault.unavailable }
    return CaptureBinding(vmID: vmID, sessionID: sessionID, monitorEpoch: qmp.connectionEpoch)
  }

  /// Same monitor and pending-operation owner; no reconnect or lifecycle action
  /// is available from any capture result/error/unknown outcome.
  package func exchangeProducerCapture(
    _ command: CaptureCommand, binding: CaptureBinding,
    expectedCapture: UInt64, terminal: CaptureStatus?
  )
    async throws -> CaptureReply
  {
    let actual = try producerCaptureBinding(vmID: binding.vmID, sessionID: binding.sessionID)
    guard actual == binding else { throw CaptureFault.identity }
    guard !operationPending, let qmp else { throw CaptureFault.busy }
    operationPending = true
    defer {
      operationPending = false
      finishIfInactive()
    }
    do {
      let result: CaptureReply
      switch command {
      case .arm(let capture):
        guard !producerArmAttempted, capture > 0, capture == expectedCapture,
          capture <= UInt64(Int64.max)
        else { throw CaptureFault.alreadyUsed }
        producerArmAttempted = true  // consumed before await/send, including unknown outcome
        producerCaptureID = capture
        result = try await qmp.producerCaptureArm(capture)
      case .status:
        guard expectedCapture == producerCaptureID else { throw CaptureFault.identity }
        result = try await qmp.producerCaptureStatus(expectedCapture: expectedCapture)
      case .stop:
        guard producerArmAttempted, !producerStopAttempted,
          expectedCapture == producerCaptureID
        else { throw CaptureFault.alreadyUsed }
        producerStopAttempted = true
        result = try await qmp.producerCaptureStop(expectedCapture: expectedCapture)
      case .read(let offset, let count):
        guard let terminal, terminal.terminal, terminal.capture == producerCaptureID,
          terminal.capture == expectedCapture, terminal.cursor == offset
        else {
          throw CaptureFault.notReady
        }
        result = try await qmp.producerCaptureRead(terminalStatus: terminal, count: count)
      }
      if case .rejected = result { producerDiagnosticClosed = true }
      return result
    } catch {
      producerDiagnosticClosed = true
      throw error
    }
  }

  /// Refresh capped output snapshots without transferring an unbounded chunk stream.
  public func refreshOutput() async { await refreshSnapshots() }

  public func start() async throws {
    operationAttempted = true
    guard !settlementSealed, !startedOnce, !operationPending, !isActive else {
      throw Self.invalidOperation()
    }
    startedOnce = true
    forceRequested = false
    operationPending = true
    starting = true
    activeLifetime = self
    defer {
      startAttemptCompleted = true
      starting = false
      operationPending = false
      finishIfInactive()
    }
    do {
      try Task.checkCancellation()
      let daemon = OwnedProcess(configuration: plan.tpm) { [weak self] snapshot in
        self?.changed(snapshot, daemon: true)
      }
      tpm = daemon
      try await daemon.launch()
      changed(await daemon.snapshot(), daemon: true)
      try await waitForSocket(plan.tpmSocket, daemon: daemon, timeout: .seconds(5))
      try Task.checkCancellation()
      let machine = OwnedProcess(configuration: plan.qemu) { [weak self] snapshot in
        self?.changed(snapshot, daemon: false)
      }
      qemu = machine
      try await machine.launch()
      changed(await machine.snapshot(), daemon: false)
      try await waitForSocket(plan.qmpSocket, daemon: machine, timeout: .seconds(5))
      try Task.checkCancellation()
      let client: QMPClient
      if let producerCaptureCapability {
        client = QMPClient(
          socketURL: plan.qmpSocket,
          producerCaptureCapability: producerCaptureCapability
        ) { [weak self] observation in
          self?.monitorChanged(observation)
        }
      } else {
        client = QMPClient(socketURL: plan.qmpSocket) { [weak self] observation in
          self?.monitorChanged(observation)
        }
      }
      monitorEpoch = client.connectionEpoch
      monitorPending = true
      qmp = client
      try await client.connect()
      let status = try await client.queryStatus()
      guard status.running, status.status == "running" else {
        throw Self.failure("QEMU did not report a running machine.")
      }
      lastStatus = status
      await refreshSnapshots()
      guard qemuSnapshot?.running == true, tpmSnapshot?.running == true, lastFailure == nil else {
        throw Self.failure("The QEMU runtime pair did not remain active through startup.")
      }
      try Task.checkCancellation()
      startEstablished = true
    } catch {
      if let qmp {
        await qmp.close()
        monitorChanged(await qmp.settledObservation())
      }
      qmp = nil
      report(Self.diagnostic(error))
      // Cancellation or failed control is not authority to stop an active guest.
      // Even a partial TPM-only launch remains owned for explicit recovery.
      throw error
    }
  }

  public func requestStop() throws {
    operationAttempted = true
    guard !settlementSealed, !operationPending, !starting, qemuSnapshot?.running == true,
      monitorPending, let qmp, qmp.connectionEpoch == monitorEpoch
    else { throw Self.invalidOperation() }
    operationPending = true
    normalStopPending = true
    activeLifetime = self
    // MachineBackend admits a synchronous request. This retained task owns the bounded
    // exchange independently of its caller; acknowledgement never marks the guest stopped.
    normalStopTask = Task { @MainActor [self, qmp] in
      defer {
        operationPending = false
        normalStopPending = false
        normalStopTask = nil
        finishIfInactive()
      }
      do {
        try await qmp.powerdown()
      } catch {
        if Self.permitsNaturalPowerdownSettlement(for: error as? QMPClientError) {
          let observation = await qmp.settledObservation()
          monitorChanged(observation)
          if observation.connectionEpoch == monitorEpoch, observation.guestShutdownObserved,
            observation.naturalEOF, observation.readerDrained, !observation.intentionalClose,
            observation.failure == nil, lastFailure == nil, !forceRequested
          {
            // A spontaneous guest stop can close the monitor before its request ACK.
            // Final classification still requires both owned children to settle cleanly.
            return
          }
        }
        report(Self.diagnostic(error))
        await qmp.close()
        monitorChanged(await qmp.settledObservation())
        if self.qmp === qmp { self.qmp = nil }
      }
    }
  }

  public func pause() async throws {
    try await changeExecution(pausing: true)
  }

  /// Uses this backend's existing monitor; never connects a competing reader.
  public func selectRelativeMouse(_ relative: Bool) async throws {
    guard !settlementSealed, !operationPending, !starting, !normalStopPending,
      qemuSnapshot?.running == true, lastStatus?.running == true, let qmp
    else { throw Self.invalidOperation() }
    operationPending = true
    defer {
      operationPending = false
      finishIfInactive()
    }
    try await qmp.selectRelativeMouse(relative)
  }

  public func resume() async throws {
    try await changeExecution(pausing: false)
  }

  public func forceStop() async throws {
    operationAttempted = true
    guard !settlementSealed, !operationPending, !starting else { throw Self.invalidOperation() }
    operationPending = true
    defer {
      operationPending = false
      finishIfInactive()
    }
    await refreshSnapshots()
    if qemuSnapshot?.running == true || tpmSnapshot?.running == true { forceRequested = true }
    // Only this explicit operation authorizes terminating the registered children.
    if qemuSnapshot?.running == true {
      do {
        let client: QMPClient
        if let qmp {
          client = qmp
        } else {
          client = QMPClient(socketURL: plan.qmpSocket)
          qmp = client
          try await client.connect()
        }
        try await client.quit()
      } catch {
        if let qmp { await qmp.close() }
        qmp = nil
      }
    }
    let gracefulDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while isActive, ContinuousClock.now < gracefulDeadline {
      await refreshSnapshots()
      if isActive { try await Task.sleep(for: .milliseconds(50)) }
    }
    for child in [qemu, tpm].compactMap({ $0 }) {
      if await child.snapshot().running { try await child.terminate() }
    }
    let finalDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while isActive, ContinuousClock.now < finalDeadline {
      await refreshSnapshots()
      if isActive { try await Task.sleep(for: .milliseconds(50)) }
    }
    // Force Stop already authorizes loss of unsaved guest state. A deadlocked
    // child may not handle SIGTERM; escalate only through its retained Child.
    // Actual terminal status and both finished drains still govern ownership.
    for child in [qemu, tpm].compactMap({ $0 }) {
      if await child.snapshot().running { try await child.forceKill() }
    }
    let killDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while isActive, ContinuousClock.now < killDeadline {
      await refreshSnapshots()
      if isActive { try await Task.sleep(for: .milliseconds(50)) }
    }
    guard !isActive else {
      let error = Self.failure("QEMU runtime cleanup remains active.")
      report(error)
      throw error
    }
    if let qmp { await qmp.close() }
    qmp = nil
  }

  private func changeExecution(pausing: Bool) async throws {
    operationAttempted = true
    guard !settlementSealed, !operationPending, !starting, qemuSnapshot?.running == true, let qmp
    else {
      throw Self.invalidOperation()
    }
    try Task.checkCancellation()
    operationPending = true
    defer {
      operationPending = false
      finishIfInactive()
    }
    do {
      if pausing { try await qmp.stop() } else { try await qmp.cont() }
      let status = try await qmp.queryStatus()
      guard status.status == (pausing ? "paused" : "running"), status.running == !pausing else {
        throw Self.failure("QEMU did not confirm the requested execution state.")
      }
      lastStatus = status
      try Task.checkCancellation()
    } catch {
      await qmp.close()
      monitorChanged(await qmp.settledObservation())
      self.qmp = nil
      report(Self.diagnostic(error))
      throw error
    }
  }

  private func waitForSocket(_ url: URL, daemon: OwnedProcess, timeout: Duration) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      let state = await daemon.snapshot()
      guard state.running, state.outputError == nil else {
        throw Self.failure("A runtime child ended before its control socket was ready.")
      }
      var info = stat()
      if lstat(url.path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0, info.st_nlink == 1
        else { throw Self.failure("A runtime control socket is unsafe.") }
        return
      }
      guard errno == ENOENT else { throw Self.failure("A runtime control socket is unreadable.") }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw Self.failure("A runtime control socket did not become ready.")
  }

  private func refreshSnapshots() async {
    if let qemu { changed(await qemu.snapshot(), daemon: false) }
    if let tpm { changed(await tpm.snapshot(), daemon: true) }
  }

  private func changed(_ snapshot: OwnedProcess.Snapshot, daemon: Bool) {
    let previous = daemon ? tpmSnapshot : qemuSnapshot
    guard previous == nil || snapshot.sequence >= (previous?.sequence ?? 0) else { return }
    if let previous {
      guard !(previous.started && !snapshot.started),
        !(previous.exit != nil && snapshot.exit == nil),
        !(previous.stdoutCapture.eof && !snapshot.stdoutCapture.eof),
        !(previous.stderrCapture.eof && !snapshot.stderrCapture.eof),
        !(previous.stdoutCapture.finished && !snapshot.stdoutCapture.finished),
        !(previous.stderrCapture.finished && !snapshot.stderrCapture.finished),
        !(previous.outputError != nil && snapshot.outputError == nil),
        snapshot.stdoutCapture.bytesRead >= previous.stdoutCapture.bytesRead,
        snapshot.stderrCapture.bytesRead >= previous.stderrCapture.bytesRead,
        snapshot.stdoutCapture.bytesLogged >= previous.stdoutCapture.bytesLogged,
        snapshot.stderrCapture.bytesLogged >= previous.stderrCapture.bytesLogged,
        !(previous.stdoutCapture.memoryTruncated && !snapshot.stdoutCapture.memoryTruncated),
        !(previous.stderrCapture.memoryTruncated && !snapshot.stderrCapture.memoryTruncated),
        !(previous.stdoutCapture.logTruncated && !snapshot.stdoutCapture.logTruncated),
        !(previous.stderrCapture.logTruncated && !snapshot.stderrCapture.logTruncated),
        !(previous.stdoutCapture.failed && !snapshot.stdoutCapture.failed),
        !(previous.stderrCapture.failed && !snapshot.stderrCapture.failed)
      else { return }
    }
    if daemon { tpmSnapshot = snapshot } else { qemuSnapshot = snapshot }
    if let error = snapshot.outputError { report(error) }
    if !forceRequested, let exit = snapshot.exit,
      exit.status != 0 || exit.wasSignalled
    {
      report(Self.failure("A QEMU runtime child exited with a failure."))
    }
    if daemon, snapshot.started, !snapshot.running, qemuSnapshot?.running == true,
      !forceRequested
    {
      if starting || !Self.naturalTerminalExit(snapshot) {
        report(Self.failure("The TPM daemon exited while QEMU remains active."))
      } else {
        assessTPMExit()
      }
    }
    finishIfInactive()
  }

  private func monitorChanged(_ observation: QMPMonitorObservation) {
    guard !settlementSealed, observation.connectionEpoch == monitorEpoch,
      observation.sequence >= (monitorObservation?.sequence ?? 0)
    else { return }
    monitorObservation = observation
    if observation.failure != nil {
      report(Self.failure("The QEMU monitor could not preserve shutdown provenance."))
    }
    if observation.readerDrained {
      monitorPending = false
      monitorSettlementTask?.cancel()
      monitorSettlementTask = nil
    }
    finishIfInactive()
  }

  private func assessTPMExit() {
    guard !tpmAssessmentAttempted else { return }
    tpmAssessmentAttempted = true
    guard let qmp, qmp.connectionEpoch == monitorEpoch else {
      report(Self.failure("The TPM daemon exited without current shutdown provenance."))
      return
    }
    tpmAssessmentPending = true
    tpmAssessmentTask = Task { @MainActor [self, qmp] in
      defer {
        tpmAssessmentPending = false
        tpmAssessmentTask = nil
        finishIfInactive()
      }
      do {
        // Drain frames available at this reader boundary, without waiting for a new
        // event or a future reply that could hide an earlier unexpected TPM exit.
        let observation = try await qmp.drainObservation()
        monitorChanged(observation)
        guard observation.connectionEpoch == monitorEpoch, observation.guestShutdownObserved,
          observation.failure == nil, !observation.intentionalClose
        else {
          report(Self.failure("The TPM daemon exited without current shutdown provenance."))
          return
        }
      } catch {
        report(Self.failure("The TPM daemon shutdown could not be attributed to the guest."))
      }
    }
  }

  private func boundMonitorSettlementIfChildrenEnded() {
    guard monitorPending, monitorSettlementTask == nil, !starting,
      qemuSnapshot?.started == true, qemuSnapshot?.isActive == false,
      tpmSnapshot?.started == true, tpmSnapshot?.isActive == false,
      let qmp, qmp.connectionEpoch == monitorEpoch
    else { return }
    monitorSettlementTask = Task { @MainActor [self, qmp] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard monitorPending else { return }
      report(Self.failure("The terminal QEMU monitor did not settle naturally."))
      // Only our monitor is closed. A deadline never authorizes signalling a child.
      await qmp.close()
      monitorChanged(await qmp.settledObservation())
      monitorSettlementTask = nil
      finishIfInactive()
    }
  }

  private static func naturalTerminalExit(_ snapshot: OwnedProcess.Snapshot) -> Bool {
    snapshot.started && snapshot.termination?.reason == .exit && snapshot.termination?.status == 0
  }

  private static func cleanTerminal(_ snapshot: OwnedProcess.Snapshot?) -> Bool {
    guard let snapshot else { return false }
    return naturalTerminalExit(snapshot) && !snapshot.running && !snapshot.isActive
      && snapshot.drainsFinished && snapshot.outputError == nil
      && !snapshot.stdoutCapture.failed && !snapshot.stderrCapture.failed
      && !snapshot.stdoutCapture.memoryTruncated && !snapshot.stderrCapture.memoryTruncated
      && !snapshot.stdoutCapture.logTruncated && !snapshot.stderrCapture.logTruncated
  }

  private func currentTerminationObservation() -> BackendTerminationObservation {
    let observation = monitorObservation
    return Self.classifyTermination(
      launched: qemuSnapshot?.started == true || tpmSnapshot?.started == true,
      forced: forceRequested, priorFailure: lastFailure != nil,
      guestShutdownWitness: observation?.connectionEpoch == monitorEpoch
        && observation?.guestShutdownObserved == true,
      monitorSettledNaturally: observation?.naturalEOF == true && observation?.readerDrained == true
        && observation?.intentionalClose == false && observation?.failure == nil,
      childrenClean: Self.cleanTerminal(qemuSnapshot) && Self.cleanTerminal(tpmSnapshot))
  }

  private func finishIfInactive() {
    boundMonitorSettlementIfChildrenEnded()
    guard !isActive, !starting, !operationPending else { return }
    if !stoppedNotified, qemuSnapshot?.started == true || tpmSnapshot?.started == true {
      terminationObservation = currentTerminationObservation()
      stoppedNotified = true
      onGuestStopped?()
    }
    activeLifetime = nil
  }

  package func bindRecordedSession(sessionID: UUID) throws {
    guard recordedSessionID == nil, !settlementSealed, !operationAttempted,
      !startedOnce, !starting, !operationPending, qemu == nil, tpm == nil
    else { throw Self.invalidOperation() }
    recordedSessionID = sessionID
  }

  /// Actor-owned state is refreshed and sealed before receipt publication. A receipt cannot
  /// authorize another launch, and notification/output failures never substitute for exit.
  package func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt {
    guard recordedSessionID == sessionID, !settlementSealed, !starting, !operationPending,
      !startedOnce || startAttemptCompleted
    else { throw Self.invalidOperation() }
    try Task.checkCancellation()
    operationPending = true
    defer {
      operationPending = false
      finishIfInactive()
    }
    for (child, daemon) in [(qemu, false), (tpm, true)] {
      guard let child else { continue }
      let snapshot = await child.snapshot()
      changed(snapshot, daemon: daemon)
      if snapshot.started {
        guard snapshot.termination != nil, snapshot.drainsFinished,
          !snapshot.running, !snapshot.isActive
        else { throw Self.invalidOperation() }
      } else {
        guard startedOnce, startAttemptCompleted, !snapshot.isActive else {
          throw Self.invalidOperation()
        }
      }
    }
    guard !isActive else { throw Self.invalidOperation() }
    qmp = nil
    try Task.checkCancellation()
    let observed = currentTerminationObservation()
    terminationObservation = observed
    settlementSealed = true
    return BackendQuiescenceReceipt(
      source: self, sessionID: sessionID,
      launchDisposition: startedOnce
        ? (startEstablished ? .completedAttempt : .failedAttempt) : .neverInvoked,
      terminationObservation: observed)
  }

  private func report(_ error: VMError) {
    guard lastFailure == nil else { return }
    lastFailure = error
    onFailure?(error)
  }

  private static func diagnostic(_ error: Error) -> VMError {
    if let error = error as? VMError { return error }
    if error is CancellationError {
      return VMError(
        .cancelled, "The QEMU operation was cancelled.",
        recovery: "Active processes remain owned. Inspect state and explicitly choose recovery.")
    }
    return failure("QEMU process or control operation failed.")
  }

  /// One predicate governs both callback and frozen receipt classification. Its inputs
  /// come only from this retained monitor and directly owned children, never saved records.
  package static func classifyTermination(
    launched: Bool, forced: Bool, priorFailure: Bool, guestShutdownWitness: Bool,
    monitorSettledNaturally: Bool, childrenClean: Bool
  ) -> BackendTerminationObservation {
    guard launched else { return .notObserved }
    if forced { return .explicitForcedTermination }
    return !priorFailure && guestShutdownWitness && monitorSettledNaturally && childrenClean
      ? .guestStopObserved : .runtimeExited
  }

  /// EOF can end either an already pending request or the available-frame drain before
  /// registration. Both still require exact settled monitor and child evidence above.
  package static func permitsNaturalPowerdownSettlement(for error: QMPClientError?) -> Bool {
    error == .disconnected || error == .closed
  }

  private static func failure(_ message: String) -> VMError {
    VMError(
      .backendFailure, message,
      recovery: "Preserve VM files and logs. Active ownership is retained until confirmed cleanup.")
  }

  private static func invalidOperation() -> VMError {
    VMError(
      .invalidTransition, "The QEMU runtime cannot perform that operation now.",
      recovery: "Wait for the pending operation and inspect the current state.")
  }
}

extension QemuMachineBackend: BackendSettlementSource {}
