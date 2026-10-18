// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite(.serialized) @MainActor struct GuestFrameTimingMeasurementTests {
  private let epoch = UUID()
  private let size = PixelSize(width: 3456, height: 2168)

  @Test func cutoffAndRendererSnapshotPrecedeDelayedNativeDeliveryWithoutLosingItsTimestamp()
    async throws
  {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    clock.set(19.990)
    try measurement.capture.receive(epoch: epoch, size: size, sequence: 11)
    let feedback = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    clock.set(19.998)
    feedback.completed(success: true, hostTime: 19.998)
    clock.set(20)
    let finish = Task { await measurement.finish() }
    try await waitForStop(source)
    source.snapshot()
    // Completion entered before cutoff, but the presentation callback has not
    // arrived. A queue snapshot cannot settle that pending native feedback.
    #expect(measurement.capture.diagnostics().status == .draining)
    #expect(measurement.capture.diagnostics().unresolvedTickets == 1)
    #expect(source.submit(epoch: epoch, size: size, sequence: 12) == nil)
    #expect(source.submissions == 2)
    clock.set(20.001)
    feedback.presented(hostTime: 19.999)
    let outcome = await finish.value
    let result = try #require(outcome.result)
    #expect(outcome.diagnostics.status == .complete && outcome.diagnostics.unresolvedTickets == 0)
    #expect(result.durationMS == 20_000 && result.received == 1 && result.drawn == 1)
    #expect(result.presented == 1 && result.presentationRate == 0.05)
    #expect(result.samples[0].presentedMS == 19_999 && result.samples[0].drawnMS == 19_998)
    #expect(!result.physicalScanoutMeasured)
  }

  @Test func deadlineFreezesIncompleteCountsAndLateCallbacksCannotChangePublishedState()
    async throws
  {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    clock.set(19.990)
    try measurement.capture.receive(epoch: epoch, size: size, sequence: 11)
    let feedback = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    feedback.completed(success: true, hostTime: 19.995)
    clock.set(20)
    let finish = Task { await measurement.finish() }
    try await waitForStop(source)
    source.snapshot()
    clock.set(22)
    #expect(clock.fireNext())
    let outcome = await finish.value
    #expect(outcome.diagnostics.status == .incompleteFeedback && outcome.result == nil)
    #expect(outcome.diagnostics.drawn == 1 && outcome.diagnostics.presented == 0)
    #expect(outcome.diagnostics.issuedTickets == 1 && outcome.diagnostics.unresolvedTickets == 1)
    feedback.presented(hostTime: 19.999)
    feedback.completed(success: true, hostTime: 19.995)
    let after = measurement.capture.diagnostics()
    #expect(
      after.status == .incompleteFeedback && after.presented == 0 && after.unresolvedTickets == 1)
    #expect(clock.scheduledDelays == [2])
  }

  @Test(arguments: [20.5, 22.0]) func delayedCutoffCannotRestartTheTwoSecondDrainBudget(
    cutoff: Double
  ) async throws {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    clock.set(19.990)
    try measurement.capture.receive(epoch: epoch, size: size, sequence: 11)
    let feedback = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    clock.set(cutoff)
    let finish = Task { await measurement.finish() }
    try await waitForStop(source)
    source.snapshot()
    if cutoff < 22 {
      #expect(clock.scheduledDelays == [1.5])
    } else {
      #expect(clock.scheduledDelays.isEmpty)
    }
    clock.set(22)
    feedback.presented(hostTime: 19.999)
    let outcome = await finish.value
    #expect(outcome.diagnostics.status == .incompleteFeedback && outcome.result == nil)
    #expect(outcome.diagnostics.unresolvedTickets == 1)
  }

  @Test func overduePresentationCannotBeatTheCutoffTaskWhileStillSampling() async throws {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    clock.set(19.990)
    try measurement.capture.receive(epoch: epoch, size: size, sequence: 11)
    let feedback = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    // MainActor has not run finish at all. A late native presentation receipt
    // must enforce origin+22s even while the capture still reports sampling.
    #expect(measurement.capture.diagnostics().status == .sampling)
    clock.set(22.1)
    feedback.presented(hostTime: 19.999)
    let frozen = measurement.capture.diagnostics()
    #expect(frozen.status == .incompleteFeedback)
    #expect(frozen.received == 1 && frozen.drawn == 0 && frozen.presented == 0)
    #expect(frozen.issuedTickets == 1 && frozen.unresolvedTickets == 1 && !frozen.sourceStopped)
    #expect(clock.scheduledDelays.isEmpty)
    clock.set(23)
    let finish = Task { await measurement.finish() }
    try await waitForStop(source)
    source.snapshot()
    let outcome = await finish.value
    #expect(outcome.diagnostics.status == .incompleteFeedback && outcome.result == nil)
    #expect(outcome.diagnostics.drawn == 0 && outcome.diagnostics.presented == 0)
    #expect(outcome.diagnostics.unresolvedTickets == 1 && !outcome.diagnostics.sourceStopped)
    feedback.completed(success: true, hostTime: 23)
    feedback.presented(hostTime: 19.999)
    let after = measurement.capture.diagnostics()
    #expect(after.status == frozen.status && after.received == frozen.received)
    #expect(after.drawn == frozen.drawn && after.presented == frozen.presented)
    #expect(after.issuedTickets == frozen.issuedTickets)
    #expect(after.unresolvedTickets == frozen.unresolvedTickets && !after.sourceStopped)
    #expect(clock.scheduledDelays.isEmpty)
  }

  @Test func overdueCallbackCannotBeatADelayedDeadlineTimer() async throws {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    clock.set(19.990)
    try measurement.capture.receive(epoch: epoch, size: size, sequence: 11)
    let feedback = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    clock.set(20)
    let finish = Task { await measurement.finish() }
    try await waitForStop(source)
    source.snapshot()
    // The timer itself is deliberately not delivered. Native receipt must
    // enforce the absolute deadline before accepting an old event timestamp.
    clock.set(22.001)
    feedback.completed(success: true, hostTime: 19.998)
    feedback.presented(hostTime: 19.999)
    let outcome = await finish.value
    #expect(outcome.diagnostics.status == .incompleteFeedback && outcome.result == nil)
    #expect(outcome.diagnostics.drawn == 0 && outcome.diagnostics.presented == 0)
    #expect(outcome.diagnostics.unresolvedTickets == 1)
    #expect(clock.fireNext())
    #expect(measurement.capture.diagnostics().unresolvedTickets == 1)
  }

  @Test
  func reverseCallbacksRedrawsZeroBoundaryAndFailedCommandsSettleWithoutInventedPresentations()
    async throws
  {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    var feedback: [GuestFrameTimingCapture.Ticket] = []
    for sequence in UInt64(11)...15 {
      clock.set(Double(sequence - 10) / 1000)
      try measurement.capture.receive(epoch: epoch, size: size, sequence: sequence)
      feedback.append(try #require(source.submit(epoch: epoch, size: size, sequence: sequence)))
    }
    let redraw = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    clock.set(20)
    let finish = Task { await measurement.finish() }
    try await waitForStop(source)
    source.snapshot()
    clock.set(20.1)
    redraw.presented(hostTime: 0.011)
    redraw.completed(success: true, hostTime: 0.009)
    // A positive presented timestamp alone cannot make a failed command count.
    feedback[4].presented(hostTime: 0.015)
    feedback[4].completed(success: false, hostTime: 0.014)
    feedback[3].presented(hostTime: 0)
    feedback[3].completed(success: true, hostTime: 0.008)
    feedback[2].presented(hostTime: 20)
    feedback[2].completed(success: true, hostTime: 0.007)
    feedback[1].presented(hostTime: 19.999)
    feedback[1].completed(success: true, hostTime: 0.006)
    feedback[0].completed(success: true, hostTime: 0.005)
    feedback[0].presented(hostTime: 0.010)
    feedback[0].presented(hostTime: 0.012)  // An identical ticket is exactly once.
    let outcome = await finish.value
    let result = try #require(outcome.result)
    #expect(outcome.diagnostics.status == .complete && outcome.diagnostics.issuedTickets == 6)
    #expect(outcome.diagnostics.unresolvedTickets == 0)
    #expect(result.received == 5 && result.drawn == 4 && result.presented == 2)
    #expect(result.samples[0].presentedMS == 10 && result.samples[0].drawnMS == 5)
    #expect(result.samples[2].presentedMS == nil && result.samples[3].presentedMS == nil)
    #expect(result.samples[4].drawnMS == nil && result.samples[4].presentedMS == nil)
    #expect(result.drawGaps.longestMS >= 0 && result.durationMS == 20_000)
  }

  @Test(arguments: [0, 1, 2]) func cancellationOrSourceReplacementRetiresOnlyItsOwnSample(
    cancellation: Int
  ) async throws {
    let clock = ControlledClock()
    let source = ControlledSource()
    let old = make(clock, source)
    clock.set(1)
    try old.capture.receive(epoch: epoch, size: size, sequence: 11)
    let stale = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    clock.set(20)
    let oldFinish = Task { await old.finish() }
    try await waitForStop(source)
    if cancellation == 1 {
      source.invalidateOwner()
    } else if cancellation == 2 {
      oldFinish.cancel()
    } else {
      old.cancel()
    }
    let oldOutcome = await oldFinish.value
    #expect(oldOutcome.diagnostics.status == .cancelled && oldOutcome.result == nil)
    // A later sample has the same numeric sequence, epoch and geometry. Only
    // immutable sample ownership prevents an old callback from attaching to it.
    let fresh = make(clock, source, origin: 20)
    clock.set(21)
    try fresh.capture.receive(epoch: epoch, size: size, sequence: 11)
    let current = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    stale.presented(hostTime: 1.2)
    stale.completed(success: true, hostTime: 1.1)
    #expect(fresh.capture.diagnostics().presented == 0)
    // The delayed old renderer snapshot cannot detach a newer source binding.
    source.snapshot()
    #expect(source.activeID == fresh.capture.id)
    source.snapshotAll()
    current.completed(success: true, hostTime: 21.1)
    current.presented(hostTime: 21.2)
    clock.set(40)
    let freshFinish = Task { await fresh.finish() }
    try await waitForStop(source)
    source.snapshotAll()
    let freshOutcome = await freshFinish.value
    #expect(freshOutcome.diagnostics.status == .complete && freshOutcome.result?.presented == 1)
    #expect(old.capture.diagnostics().status == .cancelled)
  }

  @Test(arguments: [0, 1, 2])
  func actualGuestViewLifecycleCancelsDuringPendingDrainWithoutARenderer(
    change: Int
  ) async throws {
    let clock = ControlledClock()
    let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    let capture = GuestFrameTimingCapture(
      epoch: epoch, size: size, initialSequence: 10,
      presentationFeedback: true, origin: 0, clock: clock.interface)
    let measurement = GuestFrameTimingMeasurement(capture: capture, source: view)
    clock.set(1)
    try capture.receive(epoch: epoch, size: size, sequence: 11)
    let feedback = try #require(capture.issue(epoch: epoch, size: size, sequence: 11))
    clock.set(20)
    let finish = Task { await measurement.finish() }
    for _ in 0..<1000 {
      if capture.diagnostics().sourceStopped { break }
      await Task.yield()
    }
    #expect(capture.diagnostics().sourceStopped && capture.diagnostics().status == .draining)
    if change == 0 {
      view.setFrameSize(NSSize(width: 80, height: 64))
    } else if change == 1 {
      view.stopShared()
    } else {
      // There is no owning window. The actual attachment callback reconciles
      // the inactive owner while its submitted numeric ticket is draining.
      view.viewDidMoveToWindow()
    }
    let outcome = await finish.value
    #expect(outcome.diagnostics.status == .cancelled && outcome.result == nil)
    #expect(outcome.diagnostics.issuedTickets == 1)
    #expect(view.sharedRendererForValidation() == nil)
    feedback.presented(hostTime: 1.2)
    feedback.completed(success: true, hostTime: 1.1)
    #expect(capture.diagnostics().status == .cancelled && capture.diagnostics().presented == 0)
  }

  @Test func missingRendererSnapshotIsIncompleteEvenWhenAllTicketCallbacksAlreadySettled()
    async throws
  {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    clock.set(1)
    try measurement.capture.receive(epoch: epoch, size: size, sequence: 11)
    let feedback = try #require(source.submit(epoch: epoch, size: size, sequence: 11))
    feedback.completed(success: true, hostTime: 1.1)
    feedback.presented(hostTime: 1.2)
    clock.set(20)
    let finish = Task { await measurement.finish() }
    try await waitForStop(source)
    #expect(measurement.capture.diagnostics().unresolvedTickets == 0)
    #expect(!measurement.capture.diagnostics().sourceStopped)
    clock.set(22)
    #expect(clock.fireNext())
    let outcome = await finish.value
    #expect(outcome.diagnostics.status == .incompleteFeedback && outcome.result == nil)
    #expect(!outcome.diagnostics.sourceStopped)
    source.snapshot()
    #expect(!measurement.capture.diagnostics().sourceStopped)
  }

  @Test(arguments: [false, true]) func exactNumericLimitsAndOverflowInvalidateOnlyTelemetry(
    overflowTickets: Bool
  ) async throws {
    let clock = ControlledClock()
    let source = ControlledSource()
    let measurement = make(clock, source)
    for index in 0..<GuestFrameTiming.sampleLimit {
      clock.set(Double(index + 1) / 1000)
      let sequence = UInt64(index + 11)
      try measurement.capture.receive(epoch: epoch, size: size, sequence: sequence)
      #expect(source.submit(epoch: epoch, size: size, sequence: sequence) != nil)
    }
    let exact = measurement.capture.diagnostics()
    #expect(exact.status == .sampling && exact.received == 4096 && exact.issuedTickets == 4096)
    if overflowTickets {
      #expect(source.submit(epoch: epoch, size: size, sequence: 11) == nil)
    } else {
      clock.set(5)
      #expect(throws: GuestFrameTiming.Invalid.self) {
        try measurement.capture.receive(epoch: epoch, size: size, sequence: 5000)
      }
    }
    let overflow = measurement.capture.diagnostics()
    #expect(overflow.status == .invalid)
    #expect(overflow.invalidReason == (overflowTickets ? .ticketLimit : .receiveLimit))
    // The source continues its ordinary draw operation even when this sample
    // refuses more tickets; no rendering/ACK authority exists in the collector.
    #expect(source.submit(epoch: epoch, size: size, sequence: 11) == nil)
    #expect(source.submissions >= 4097)
    clock.set(20)
    let outcome = await measurement.finish()
    #expect(outcome.diagnostics.status == .invalid && outcome.result == nil)
    #expect(outcome.diagnostics.received == 4096 && outcome.diagnostics.issuedTickets == 4096)
  }

  private func make(
    _ clock: ControlledClock, _ source: ControlledSource, origin: Double = 0
  ) -> GuestFrameTimingMeasurement {
    GuestFrameTimingMeasurement(
      capture: GuestFrameTimingCapture(
        epoch: epoch, size: size, initialSequence: 10,
        presentationFeedback: true, origin: origin, clock: clock.interface), source: source)
  }

  private func waitForStop(_ source: ControlledSource) async throws {
    for _ in 0..<1000 {
      if !source.stops.isEmpty { return }
      await Task.yield()
    }
    throw FixtureFailure.noSnapshotRequested
  }
  private enum FixtureFailure: Error { case noSnapshotRequested }

  /// Uses the production controller/source interface and immutable ticket API.
  /// Snapshot delivery and native completion are separately controlled.
  private final class ControlledSource: GuestFrameTimingSource {
    private var active: GuestFrameTimingCapture?
    private var owner: GuestFrameTimingCapture?
    private(set) var stops: [GuestFrameTimingCapture] = []
    private(set) var submissions = 0
    var activeID: UUID? { active?.id }
    func beginTimingCapture(_ capture: GuestFrameTimingCapture) {
      if owner?.id != capture.id { owner?.cancel() }
      owner = capture
      active = capture
    }
    func endTimingCapture(_ capture: GuestFrameTimingCapture) { stops.append(capture) }
    func retireTimingCapture(_ capture: GuestFrameTimingCapture) {
      if owner?.id == capture.id { owner = nil }
      if active?.id == capture.id { active = nil }
    }
    func submit(epoch: UUID, size: PixelSize, sequence: UInt64) -> GuestFrameTimingCapture.Ticket? {
      submissions += 1
      return active?.issue(epoch: epoch, size: size, sequence: sequence)
    }
    func snapshot() {
      guard !stops.isEmpty else { return }
      let capture = stops.removeFirst()
      if active?.id == capture.id { active = nil }
      capture.sourceDidStop()
    }
    func snapshotAll() { while !stops.isEmpty { snapshot() } }
    func invalidateOwner() {
      owner?.cancel()
      owner = nil
      active = nil
    }
  }

  private final class ControlledClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    private var callbacks: [@Sendable () -> Void] = []
    private var delays: [Double] = []
    var interface: GuestFrameTimingCapture.Clock {
      GuestFrameTimingCapture.Clock(
        now: { self.lock.withLock { self.time } },
        schedule: { delay, callback in
          self.lock.withLock {
            self.delays.append(delay)
            self.callbacks.append(callback)
          }
        })
    }
    func set(_ value: Double) { lock.withLock { time = value } }
    var scheduledDelays: [Double] { lock.withLock { delays } }
    func fireNext() -> Bool {
      let callback = lock.withLock { callbacks.isEmpty ? nil : callbacks.removeFirst() }
      callback?()
      return callback != nil
    }
  }
}
