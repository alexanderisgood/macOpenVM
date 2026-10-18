// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum BackendLaunchDisposition: Equatable, Sendable {
  /// A failed attempt may have executed guest instructions; it only failed to establish startup.
  case neverInvoked, failedAttempt, completedAttempt
}

/// Trusted backend implementations seal their private launch/child state before issuing this.
@MainActor
package protocol BackendSettlementSource: MachineBackend, Sendable {
  func bindRecordedSession(sessionID: UUID) throws
  func freezeForSettlement(sessionID: UUID) async throws -> BackendQuiescenceReceipt
}

/// Opaque outside this package. It retains the actual source through durable settlement;
/// session/source identities provide correlation rather than a reconstructible disk credential.
package final class BackendQuiescenceReceipt: Sendable {
  package let sessionID: UUID
  package let sourceID: ObjectIdentifier
  package let launchDisposition: BackendLaunchDisposition
  package let terminationObservation: BackendTerminationObservation
  private let source: any BackendSettlementSource

  @MainActor
  package init(
    source: any BackendSettlementSource, sessionID: UUID,
    launchDisposition: BackendLaunchDisposition,
    terminationObservation: BackendTerminationObservation
  ) {
    self.source = source
    self.sessionID = sessionID
    sourceID = ObjectIdentifier(source)
    self.launchDisposition = launchDisposition
    self.terminationObservation = terminationObservation
  }
}
