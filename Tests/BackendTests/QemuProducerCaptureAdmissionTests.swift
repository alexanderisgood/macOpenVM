// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu
import Testing

@Suite @MainActor struct QemuProducerCaptureAdmissionTests {
  @Test func defaultOrUnstartedProfileCannotMintAnActualMonitorBinding() async throws {
    let none = URL(fileURLWithPath: "/nonexistent/macopenvm-no-capture-test")
    let process = OwnedProcess.Configuration(
      executable: none, arguments: [], workingDirectory: none,
      stdoutLog: none.appendingPathComponent("out"), stderrLog: none.appendingPathComponent("err"))
    let plan = QemuRuntimePlan(
      qemu: process, tpm: process,
      qmpSocket: none.appendingPathComponent("qmp"), tpmSocket: none.appendingPathComponent("tpm"))
    let vmID = UUID()
    let sessionID = UUID()
    let binding = CaptureBinding(vmID: vmID, sessionID: sessionID, monitorEpoch: UUID())
    let ordinary = QemuMachineBackend(plan: plan)
    let unstarted = QemuMachineBackend(
      plan: plan, producerCaptureVMID: vmID,
      producerCaptureCapability: .boundedProducerV1)
    for backend in [ordinary, unstarted] {
      #expect(throws: CaptureFault.unavailable) {
        try backend.producerCaptureBinding(vmID: vmID, sessionID: sessionID)
      }
      for command in [CaptureCommand.status, .arm(1), .stop, .read(offset: 0, count: 1)] {
        var rejected = false
        do {
          _ = try await backend.exchangeProducerCapture(
            command, binding: binding,
            expectedCapture: 1, terminal: nil)
        } catch CaptureFault.unavailable { rejected = true }
        #expect(rejected)
      }
      #expect(!backend.isActive && backend.qemuSnapshot == nil && backend.tpmSnapshot == nil)
    }
    // Constructors/data only: no start, process, socket, fake verification or resource waiver.
  }
}
