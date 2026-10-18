// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Correlation data only. A decoded binding is never runtime authority: later
/// admission must compare the actual accepted connection/bootstrap/owner state.
package struct CaptureBinding: Equatable, Sendable {
  package let vmID: UUID
  // Actual RecordedRuntimeOwner.sessionID: a newly minted launch generation.
  package let sessionID: UUID
  // Existing QMPClient epoch; never permission to create/reconnect a monitor.
  package let monitorEpoch: UUID

  package init(vmID: UUID, sessionID: UUID, monitorEpoch: UUID) {
    self.vmID = vmID
    self.sessionID = sessionID
    self.monitorEpoch = monitorEpoch
  }
}

package enum CaptureWorkerOperation: UInt8, Sendable {
  case hello, arm, status, stop, read
}

package struct CaptureWorkerRequest: Equatable, Sendable {
  package let binding: CaptureBinding
  package let requestID: UInt64
  package let observedRevision: UInt64
  package let operation: CaptureWorkerOperation
  package let capture: UInt64
  package let offset: UInt32
  package let count: UInt16

  package init(
    binding: CaptureBinding, requestID: UInt64, observedRevision: UInt64,
    operation: CaptureWorkerOperation, capture: UInt64, offset: UInt32,
    count: UInt16
  ) {
    self.binding = binding
    self.requestID = requestID
    self.observedRevision = observedRevision
    self.operation = operation
    self.capture = capture
    self.offset = offset
    self.count = count
  }

  package func validateShape() throws {
    guard (1...96).contains(requestID), capture <= UInt64(Int64.max) else {
      throw CaptureFault.limit
    }
    switch operation {
    case .hello:
      guard observedRevision == 0, capture == 0, offset == 0, count == 0 else {
        throw CaptureFault.malformed
      }
    case .arm:
      guard capture > 0, offset == 0, count == 0 else { throw CaptureFault.malformed }
    case .status, .stop:
      guard offset == 0, count == 0 else { throw CaptureFault.malformed }
    case .read:
      guard capture > 0, offset < 4096, (1...64).contains(count) else {
        throw CaptureFault.limit
      }
    }
  }
}

package enum CaptureWorkerCode: UInt16, Sendable {
  case ok, unavailable, identity, stale, busy, spent, malformed, unknownOutcome
  case rejected
}

package struct CaptureWorkerReply: Equatable, Sendable {
  package let binding: CaptureBinding
  package let requestID: UInt64
  package let revision: UInt64
  package let operation: CaptureWorkerOperation
  package let code: CaptureWorkerCode
  package let rejection: CaptureRejection?
  // Last validated producer snapshot, absent before the first status response.
  package let status: CaptureStatus?
  package let rows: [CaptureRow]

  package init(
    binding: CaptureBinding, requestID: UInt64, revision: UInt64,
    operation: CaptureWorkerOperation, code: CaptureWorkerCode,
    rejection: CaptureRejection?, status: CaptureStatus?, rows: [CaptureRow]
  ) {
    self.binding = binding
    self.requestID = requestID
    self.revision = revision
    self.operation = operation
    self.code = code
    self.rejection = rejection
    self.status = status
    self.rows = rows
  }
}
