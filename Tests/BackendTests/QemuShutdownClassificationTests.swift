// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Qemu
import Testing

@Suite("QemuShutdownClassificationTests")
@MainActor
struct QemuShutdownClassificationTests {
  @Test func guestEventNeedsNaturalMonitorSettlementAndCleanOwnedChildren() {
    #expect(
      QemuMachineBackend.classifyTermination(
        launched: true, forced: false, priorFailure: false, guestShutdownWitness: true,
        monitorSettledNaturally: true, childrenClean: true) == .guestStopObserved)
  }

  @Test(arguments: [0, 1, 2, 3])
  func missingOrFailedEvidenceCannotBecomeGuestShutdown(boundary: Int) {
    #expect(
      QemuMachineBackend.classifyTermination(
        launched: true, forced: false, priorFailure: boundary == 0,
        guestShutdownWitness: boundary != 1, monitorSettledNaturally: boundary != 2,
        childrenClean: boundary != 3) == .runtimeExited)
  }

  @Test func unlaunchedAndForcedSessionsKeepTheirDistinctProvenance() {
    #expect(
      QemuMachineBackend.classifyTermination(
        launched: false, forced: false, priorFailure: false, guestShutdownWitness: true,
        monitorSettledNaturally: true, childrenClean: true) == .notObserved)
    #expect(
      QemuMachineBackend.classifyTermination(
        launched: true, forced: true, priorFailure: false, guestShutdownWitness: true,
        monitorSettledNaturally: true, childrenClean: true) == .explicitForcedTermination)
  }

  @Test func onlyEOFErrorsPermitCheckingNaturalPowerdownEvidence() {
    #expect(QemuMachineBackend.permitsNaturalPowerdownSettlement(for: .disconnected))
    #expect(QemuMachineBackend.permitsNaturalPowerdownSettlement(for: .closed))
    for error: QMPClientError? in [
      nil, .busy, .deadlineExceeded, .malformedMessage, .unexpectedReply,
      .commandRejected("GenericError"), .ioFailure(5),
    ] {
      #expect(!QemuMachineBackend.permitsNaturalPowerdownSettlement(for: error))
    }
  }
}
