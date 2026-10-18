// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import RuntimeIPC

/// One worker-owned operation at a time. Connections observe this owner; they do not own
/// its task, permit or lease. Reconnect requires status, never an automatic command replay.
@MainActor package final class RuntimeWorkerCoordinator {
  package let vmID: UUID
  package let owner: RecordedRuntimeOwner
  package private(set) var revision: UInt64 = 1
  package private(set) var operationPending = false
  package var onSettled: (@MainActor () -> Void)?
  package var selectRelativeMouse: (@MainActor (Bool) async throws -> Void)?
  private var operation: Task<WorkerReplyCode, Never>?
  private var started = false
  private var revisionExhausted = false
  private var captureConfigured = false
  private var captureDisabled = false
  private var capture: CaptureOwnedSession?
  private var captureBinding: (@MainActor @Sendable () -> CaptureBinding?)?
  private var captureOperation: Task<CaptureWorkerReply, Never>?
  private var captureOperationID: UUID?

  /// Called once by the actual worker after fixed resources and this recorded
  /// owner/monitor are admitted. No frame or saved UUID can configure capture.
  package func configureProducerCapture(
    binding: CaptureBinding, capability: CaptureCapability,
    actualBinding: @escaping @MainActor @Sendable () -> CaptureBinding?,
    exchange:
      @escaping @MainActor @Sendable (CaptureCommand, CaptureStatus?, UInt64)
      async throws -> CaptureReply
  ) throws {
    guard !captureConfigured, !captureDisabled else { throw CaptureFault.alreadyUsed }
    captureConfigured = true
    guard started, !operationPending, owner.ownershipState == .unsettled,
      owner.controller.state == .running, owner.controller.isActive,
      binding.vmID == vmID, binding.sessionID == owner.sessionID,
      actualBinding() == binding, !revisionExhausted
    else { throw CaptureFault.unavailable }
    captureBinding = actualBinding
    capture = CaptureOwnedSession(binding: binding, capability: capability, exchange: exchange)
  }

  package var producerCaptureDiagnosticLost: Bool { capture?.diagnosticLost ?? false }

  package func disableProducerCapture() {
    captureDisabled = true
    capture?.closeAdmission()
  }

  package func producerCaptureAttachmentEnded(connectionID: UUID, lostReply: Bool = false) {
    capture?.attachmentEnded(connectionID: connectionID, lostReply: lostReply)
  }

  package func handleProducerCapture(_ request: CaptureWorkerRequest, connectionID: UUID)
    async -> CaptureWorkerReply
  {
    guard !captureDisabled, let capture, let captureBinding else {
      return captureResponse(to: request, code: .unavailable)
    }
    guard !operationPending else { return captureResponse(to: request, code: .busy) }
    guard started, !revisionExhausted, owner.ownershipState == .unsettled,
      owner.controller.state == .running, owner.controller.isActive,
      let actual = captureBinding(), actual.sessionID == owner.sessionID,
      actual.vmID == vmID
    else {
      capture.attachmentEnded(connectionID: connectionID)
      return captureResponse(to: request, code: .unavailable)
    }
    let observed = revision
    let command: CaptureCommand?
    do {
      command = try capture.prepare(
        request, connectionID: connectionID,
        actualBinding: actual, revision: observed, active: true, lifecyclePending: false)
    } catch {
      return captureResponse(to: request, code: captureCode(error))
    }
    // One coordinator gate covers lifecycle and capture before any suspension.
    operationPending = true
    advanceRevision()
    let accepted = Task { @MainActor [self, capture] in
      let code: CaptureWorkerCode
      var rejection: CaptureRejection?
      var rows: [CaptureRow] = []
      do {
        let result = try await capture.runPrepared(command)
        if case .rejected(let reason)? = result {
          code = .rejected
          rejection = reason
        } else {
          code = .ok
          if case .rows(let page)? = result { rows = page }
        }
      } catch {
        code = captureCode(error)
      }
      // No cancellation check: the accepted task must commit its cursor/outcome
      // before releasing admission, even when the requesting socket disappeared.
      await owner.controller.finishPersistence()
      if !owner.controller.isActive { try? await owner.settleOwnership() }
      operationPending = false
      advanceRevision()
      if owner.ownershipState == .settled { onSettled?() }
      let status = request.operation == .hello ? nil : capture.policy.snapshot
      return captureResponse(
        to: request, code: code, rejection: rejection,
        status: status, rows: rows)
    }
    let ticket = UUID()
    captureOperationID = ticket
    captureOperation = accepted
    let reply = await accepted.value
    if captureOperationID == ticket {
      captureOperation = nil
      captureOperationID = nil
    }
    return reply
  }

  private func captureCode(_ error: Error) -> CaptureWorkerCode {
    guard let fault = error as? CaptureFault else { return .unknownOutcome }
    return switch fault {
    case .identity: .identity
    case .stale: .stale
    case .busy: .busy
    case .alreadyUsed, .closed: .spent
    case .unavailable: .unavailable
    case .malformed, .limit, .notReady: .malformed
    default: .unknownOutcome
    }
  }

  private func captureResponse(
    to request: CaptureWorkerRequest, code: CaptureWorkerCode,
    rejection: CaptureRejection? = nil,
    status: CaptureStatus? = nil, rows: [CaptureRow] = []
  )
    -> CaptureWorkerReply
  {
    CaptureWorkerReply(
      binding: request.binding, requestID: request.requestID,
      revision: revision, operation: request.operation, code: code,
      rejection: rejection, status: status, rows: rows)
  }

  package init(owner: RecordedRuntimeOwner) {
    vmID = owner.vmID
    self.owner = owner
    owner.controller.onStateChange = { [weak self] _ in self?.advanceRevision() }
    owner.controller.onQuiescent = { [weak self] in
      guard let self, self.started, !self.operationPending,
        self.owner.ownershipState == .unsettled
      else { return }
      self.beginOperation(nil)
    }
  }

  /// The worker explicitly owns the initial launch before accepting lifecycle mutations.
  /// Failed partial launches remain controllable for explicit recovery, with status access.
  package func start() async {
    guard !started else { return }
    started = true
    beginOperation(.start)
    _ = await operation?.value
  }

  package func handle(_ request: WorkerRequest) async -> WorkerResponse {
    guard request.vmID == vmID, request.sessionID == owner.sessionID else {
      return response(to: request, code: .identity)
    }
    guard request.command != .status else { return response(to: request, code: statusCode) }
    guard started, owner.ownershipState == .unsettled, !revisionExhausted else {
      return response(to: request, code: .recovery)
    }
    guard !operationPending else { return response(to: request, code: .busy) }
    guard request.observedRevision == revision else {
      return response(to: request, code: .stale)
    }
    if request.command == .relativeMouse || request.command == .absoluteMouse {
      guard owner.controller.state == .running, let selectRelativeMouse else {
        return response(to: request, code: .operationFailed)
      }
      operationPending = true
      advanceRevision()
      // Worker custody retains this operation even if the requesting client leaves.
      let selection = Task { @MainActor in
        do {
          try await selectRelativeMouse(request.command == .relativeMouse)
          return WorkerReplyCode.none
        } catch { return WorkerReplyCode.operationFailed }
      }
      operation = selection
      var code = await selection.value
      await owner.controller.finishPersistence()
      if !owner.controller.isActive {
        do { try await owner.settleOwnership() } catch { code = .recovery }
      }
      operationPending = false
      advanceRevision()
      if owner.ownershipState == .settled { onSettled?() }
      return response(to: request, code: code)
    }
    let lifecycle: LifecycleOperation
    switch request.command {
    case .pause: lifecycle = .pause
    case .resume: lifecycle = .resume
    case .forceStop: lifecycle = .forceStop
    case .stop: lifecycle = .stop
    case .status: return response(to: request, code: statusCode)
    case .relativeMouse, .absoluteMouse: return response(to: request, code: .operationFailed)
    }
    // Reserve admission and the new revision before suspension. A second connection
    // cannot invoke the backend using the same observation while this call awaits.
    beginOperation(lifecycle)
    guard let operation else { return response(to: request, code: .operationFailed) }
    let code = await operation.value
    return response(to: request, code: code)
  }

  private func beginOperation(_ lifecycle: LifecycleOperation?) {
    operationPending = true
    advanceRevision()
    operation = Task { @MainActor [self] in
      var code = WorkerReplyCode.none
      if let lifecycle {
        do { try await owner.perform(lifecycle) } catch { code = .operationFailed }
      }
      await owner.controller.finishPersistence()
      if !owner.controller.isActive {
        do { try await owner.settleOwnership() } catch { code = .recovery }
      }
      operationPending = false
      advanceRevision()
      if owner.ownershipState == .settled { onSettled?() }
      return code
    }
  }

  private var statusCode: WorkerReplyCode {
    if revisionExhausted || owner.ownershipState == .recoveryRequired { return .recovery }
    if owner.controller.runtimeError != nil || owner.controller.historyError != nil {
      return .operationFailed
    }
    return .none
  }

  private func advanceRevision() {
    guard revision < UInt64.max else {
      revisionExhausted = true
      return
    }
    revision += 1
  }

  private func response(to request: WorkerRequest, code: WorkerReplyCode) -> WorkerResponse {
    let state: UInt8
    switch owner.controller.state {
    case .stopped: state = 0
    case .starting: state = 1
    case .running: state = 2
    case .pausing: state = 3
    case .paused: state = 4
    case .resuming: state = 5
    case .stopping: state = 6
    case .saving: state = 7
    case .suspended: state = 8
    case .restoring: state = 9
    case .failed: state = 10
    }
    let ownership: UInt8
    switch owner.ownershipState {
    case .unsettled: ownership = 0
    case .settling: ownership = 1
    case .settled: ownership = 2
    case .recoveryRequired: ownership = 3
    }
    return WorkerResponse(
      vmID: vmID, sessionID: owner.sessionID, requestID: request.requestID,
      revision: revision, state: state, ownership: ownership,
      backendActive: owner.controller.isActive, operationPending: operationPending, error: code)
  }
}
