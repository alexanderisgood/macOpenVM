// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

/// A new explicit operator policy, not a claim to possess the old session's backend receipt.
/// There is deliberately no default acknowledgement or automatic Start/adoption route.
public enum RuntimeInterruptionAcknowledgement: Sendable {
  case observedHostRebootAndReviewedNoOtherRuntime
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
    guard !attempted else { throw Self.failure(.busy) }
    attempted = true
    switch acknowledgement {
    case .observedHostRebootAndReviewedNoOtherRuntime: break
    }
    guard expectedMetadataSHA256.utf8.count == 64,
      expectedMetadataSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
      !rebootObservation.isEmpty, rebootObservation.count <= 65_536,
      !processObservation.isEmpty, processObservation.count <= 65_536
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
      lease: owner,
      evidence: .init(rebootObservation: rebootObservation, processObservation: processObservation),
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
