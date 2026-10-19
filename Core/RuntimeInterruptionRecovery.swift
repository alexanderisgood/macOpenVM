// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

/// A new explicit operator policy, not a claim to possess the old session's backend receipt.
/// There is deliberately no default acknowledgement or automatic Start/adoption route.
public enum RuntimeInterruptionAcknowledgement: Sendable {
  case observedHostRebootAndReviewedNoOtherRuntime
}

/// A separate operator basis for an exited owner, including within the current boot.
/// This attestation does not prove child reaping, disk-holder absence or guest shutdown.
public enum RuntimeAbandonedOwnerAcknowledgement: Sendable {
  case reviewedOwnerExitAndNoOtherRuntime
}

public struct RuntimeInterruptionInspection: Encodable, Sendable {
  public let vmID: UUID
  public let interruptedSessionID: UUID
  public let metadataSHA256: String
  public let currentBootSessionID: UUID
  public let currentKernelBootSeconds: Int64
  public let readOnly = true
}

public struct RuntimeInterruptionRecoveryResult: Encodable, Sendable {
  public let vmID: UUID
  public let interruptedSessionID: UUID
  public let recoverySessionID: UUID
  public let archiveFile: String
  public let newOutcome = RuntimeOutcome.failed
  public let oldSessionNormallySettled = false
  public let oldChildReapingProved = false
  public let operatorAttestedInterruption = true
}

/// A purpose-only owner retained after any attempted ambiguous write. Product routing must
/// retain/report this owner and refuse normal exit while custodyRetained is true.
@MainActor public final class RegisteredWindowsInterruptionRecovery {
  public private(set) var custodyRetained = false
  private let files = VMFiles()
  private var attempted = false
  private var lease: RuntimeInterruptionLease?
  private var retainedLifetime: RegisteredWindowsInterruptionRecovery?
  private let validationFault: RuntimeInterruptionFault?
  private let validationRecoveryID: UUID?

  public init() {
    validationFault = nil
    validationRecoveryID = nil
  }
  package init(fault: RuntimeInterruptionFault?, recoveryID: UUID? = nil) {
    validationFault = fault
    validationRecoveryID = recoveryID
  }

  public func inspect(
    in directory: URL, expectedVMID: UUID, expectedSessionID: UUID, runName: String
  ) async throws -> RuntimeInterruptionInspection {
    let observed = try await observation(
      directory, vmID: expectedVMID, sessionID: expectedSessionID, runName: runName)
    return .init(
      vmID: expectedVMID, interruptedSessionID: expectedSessionID,
      metadataSHA256: try observed.digest,
      currentBootSessionID: observed.kernel.bootSessionID,
      currentKernelBootSeconds: observed.kernel.bootSeconds)
  }

  public func recover(
    in directory: URL, expectedVMID: UUID, expectedSessionID: UUID, runName: String,
    expectedMetadataSHA256: String, rebootObservation: Data, processObservation: Data,
    acknowledgement: RuntimeInterruptionAcknowledgement
  ) async throws -> RuntimeInterruptionRecoveryResult {
    switch acknowledgement {
    case .observedHostRebootAndReviewedNoOtherRuntime: break
    }
    return try await recover(
      in: directory, expectedVMID: expectedVMID, expectedSessionID: expectedSessionID,
      runName: runName, expectedMetadataSHA256: expectedMetadataSHA256,
      evidence: .init(rebootObservation: rebootObservation, processObservation: processObservation))
  }

  /// Explicit same-boot owner-exit review, never a substitute reboot observation.
  /// The operator must independently review the old owner and all other runtimes;
  /// existing-lock custody and unchanged metadata remain mandatory, not sufficient alone.
  public func recoverAbandonedOwner(
    in directory: URL, expectedVMID: UUID, expectedSessionID: UUID, runName: String,
    expectedMetadataSHA256: String, ownerExitObservation: Data, processObservation: Data,
    acknowledgement: RuntimeAbandonedOwnerAcknowledgement
  ) async throws -> RuntimeInterruptionRecoveryResult {
    switch acknowledgement {
    case .reviewedOwnerExitAndNoOtherRuntime: break
    }
    return try await recover(
      in: directory, expectedVMID: expectedVMID, expectedSessionID: expectedSessionID,
      runName: runName, expectedMetadataSHA256: expectedMetadataSHA256,
      evidence: .init(
        ownerExitObservation: ownerExitObservation, processObservation: processObservation))
  }

  private func recover(
    in directory: URL, expectedVMID: UUID, expectedSessionID: UUID, runName: String,
    expectedMetadataSHA256: String, evidence: RuntimeInterruptionEvidence
  ) async throws -> RuntimeInterruptionRecoveryResult {
    guard !attempted else { throw Self.failure(.busy) }
    attempted = true
    guard expectedMetadataSHA256.utf8.count == 64,
      expectedMetadataSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
      evidence.isBoundedNonempty
    else { throw Self.failure(.invalidConfiguration) }
    let observed = try await observation(
      directory, vmID: expectedVMID, sessionID: expectedSessionID, runName: runName)
    guard try observed.digest == expectedMetadataSHA256 else {
      throw Self.failure(.staleOperation)
    }
    let id = validationRecoveryID ?? UUID()
    let owner = try await files.acquireOperatorInterruption(
      in: directory, observed: observed, recoveryID: id)
    lease = owner
    retainedLifetime = self
    custodyRetained = true
    // This new transaction never launches a backend; false refers to its own backendActive.
    // The original pending/active history remains exact in the durable archive.
    let record = RuntimeRecord(
      sessionID: id, sequence: 1, recordedAt: Date().timeIntervalSince1970,
      snapshot: RuntimeSnapshot(
        state: .failed, operation: nil, backendActive: false, outcome: .failed))
    let bytes = try RuntimeHistoryCodec.encode(record)
    guard try RuntimeHistoryCodec.decode(bytes) == record else { throw Self.failure(.storage) }
    let archive = try await files.commitOperatorInterruption(
      lease: owner, evidence: evidence,
      failedHistory: bytes, fault: validationFault)
    let result = RuntimeInterruptionRecoveryResult(
      vmID: expectedVMID, interruptedSessionID: expectedSessionID,
      recoverySessionID: id, archiveFile: archive)
    // Only successful durable final readback releases this purpose-only owner.
    lease = nil
    custodyRetained = false
    retainedLifetime = nil
    return result
  }

  private func observation(
    _ directory: URL, vmID: UUID, sessionID: UUID, runName: String
  ) async throws -> RuntimeInterruptionSnapshot {
    try Task.checkCancellation()
    let zero = "00000000-0000-0000-0000-000000000000"
    guard vmID.uuidString != zero, sessionID.uuidString != zero else {
      throw Self.failure(.invalidConfiguration)
    }
    let value = try await files.inspectOperatorInterruption(
      in: directory, vmID: vmID, sessionID: sessionID, runName: runName)
    let configuration = try StrictConfigurationDocument(value.configuration).configuration
    let previous = try RuntimeHistoryCodec.decode(value.history)
    guard configuration.id == vmID, configuration.guest == .windows11,
      configuration.backend == .qemuHVF, previous.sessionID == sessionID,
      previous.snapshot.outcome == .pending
    else { throw Self.failure(.staleOperation) }
    return value
  }

  private static func failure(_ code: VMError.Code) -> VMError {
    VMError(
      code, "Explicit Windows interruption recovery is unavailable for this observation.",
      recovery:
        "Preserve the VM, old history and any recovery archive. Ordinary Start admission remains unchanged."
    )
  }
}
