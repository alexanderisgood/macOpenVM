// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum LifecycleOperation: String, CaseIterable, Codable, Sendable {
  case start, stop, forceStop, pause, resume, suspend, restore
}

/// Observed runtime termination is distinct from a guest-initiated stop or disk health.
public enum BackendTerminationObservation: String, Codable, Sendable {
  case notObserved, runtimeExited, explicitForcedTermination, guestStopObserved
}

public struct BackendCapabilities: Sendable {
  public let id: BackendID
  public let operations: Set<LifecycleOperation>
  public let limitations: [String]
  public init(id: BackendID, operations: Set<LifecycleOperation>, limitations: [String]) {
    self.id = id
    self.operations = operations
    self.limitations = limitations
  }
}

/// Runtime calls are actor isolated. Completion means observed backend completion,
/// never guest-agent readiness or disk consistency. Storage/import operations are separate.
@MainActor
public protocol MachineBackend: AnyObject {
  var capabilities: BackendCapabilities { get }
  var isActive: Bool { get }
  var terminationObservation: BackendTerminationObservation { get }
  var onGuestStopped: (@MainActor () -> Void)? { get set }
  var onFailure: (@MainActor (VMError) -> Void)? { get set }
  func start() async throws
  func requestStop() throws
  func forceStop() async throws
  func pause() async throws
  func resume() async throws
}

extension MachineBackend {
  /// Existing adapters cannot establish guest shutdown merely by reporting inactivity.
  public var terminationObservation: BackendTerminationObservation { .runtimeExited }
}
