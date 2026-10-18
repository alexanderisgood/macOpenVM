// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Dispatch
import Foundation
import QuartzCore

/// The source starts/stops numeric feedback only. Neither operation waits for
/// a drawable, a command buffer, producer ACK or an application event loop.
@MainActor protocol GuestFrameTimingSource: AnyObject {
  func beginTimingCapture(_ capture: GuestFrameTimingCapture)
  func endTimingCapture(_ capture: GuestFrameTimingCapture)
  func retireTimingCapture(_ capture: GuestFrameTimingCapture)
}

/// Controller lifetime is separate from submitted native callbacks. A source
/// stop is an ordering boundary; the capture still owns its finite ticket set.
@MainActor final class GuestFrameTimingMeasurement {
  let capture: GuestFrameTimingCapture
  private weak var source: (any GuestFrameTimingSource)?

  init(capture: GuestFrameTimingCapture, source: any GuestFrameTimingSource) {
    self.capture = capture
    self.source = source
    source.beginTimingCapture(capture)
  }

  func finish() async -> GuestFrameTimingCapture.Outcome {
    capture.beginDraining()
    if let source { source.endTimingCapture(capture) } else { capture.cancel() }
    let outcome = await capture.outcome()
    source?.retireTimingCapture(capture)
    return outcome
  }

  func cancel() {
    capture.cancel()
    source?.endTimingCapture(capture)
    source?.retireTimingCapture(capture)
  }
}

/// One immutable sample identity and numeric observations only. Submitted
/// tickets retain this owner through their real callback lifetime, including
/// after a deadline. No frame, mapping, texture, view or session is retained.
final class GuestFrameTimingCapture: @unchecked Sendable {
  struct Clock: Sendable {
    let now: @Sendable () -> Double
    let schedule: @Sendable (Double, @escaping @Sendable () -> Void) -> Void
    static let host = Clock(
      now: { CACurrentMediaTime() },
      schedule: { delay, action in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
      })
  }
  enum Status: String, Encodable, Equatable, Sendable {
    case sampling, draining, complete, incompleteFeedback, cancelled, invalid
  }
  enum InvalidReason: String, Encodable, Equatable, Sendable {
    case changed, receiveLimit, ticketLimit, earlyCutoff, concurrentFinalizers
  }
  struct Diagnostics: Encodable, Sendable {
    let sampleID: UUID
    let status: Status
    let invalidReason: InvalidReason?
    let received: Int, drawn: Int, presented: Int
    let issuedTickets: Int, unresolvedTickets: Int
    let sourceStopped: Bool
  }
  struct Outcome: Encodable, Sendable {
    let diagnostics: Diagnostics
    /// Partial counts are diagnostics only when status is not complete.
    let result: GuestFrameTiming.Result?
  }
  struct Ticket: Sendable {
    private let owner: GuestFrameTimingCapture
    fileprivate let number: Int
    fileprivate let sequence: UInt64
    fileprivate init(owner: GuestFrameTimingCapture, number: Int, sequence: UInt64) {
      self.owner = owner
      self.number = number
      self.sequence = sequence
    }
    func completed(success: Bool, hostTime: Double) {
      owner.completed(self, success: success, hostTime: hostTime)
    }
    func presented(hostTime: Double) { owner.presented(self, hostTime: hostTime) }
  }
  private struct Record: Sendable {
    let sequence: UInt64
    let receivedMS: Double
    var drawnMS: Double?
    var presentedMS: Double?
  }
  private struct Pending {
    let sequence: UInt64
    var completionReceived = false
    var presentationReceived = false
    var drawnMS: Double?
    var presentedMS: Double?
  }
  private struct Snapshot: Sendable {
    let records: [Record]
    let diagnostics: Diagnostics
  }
  static let drainSeconds = 2.0
  static let ticketLimit = 4096
  let id = UUID()
  let epoch: UUID
  let size: PixelSize
  let origin: Double
  let presentationFeedback: Bool
  private let initialSequence: UInt64
  private let clock: Clock
  private let lock = NSLock()
  private var status: Status = .sampling
  private var invalidReason: InvalidReason?
  private var records: [Record] = []
  private var indices: [UInt64: Int] = [:]
  private var tickets: [Int: Pending] = [:]
  private var issued = 0
  private var drawnCount = 0
  private var presentedCount = 0
  private var sourceStopped = false
  private let deadline: Double
  private var frozen: Snapshot?
  private var waiters: [CheckedContinuation<Snapshot, Never>] = []

  init(
    epoch: UUID, size: PixelSize, initialSequence: UInt64 = 0,
    presentationFeedback: Bool, origin: Double, clock: Clock = .host
  ) {
    self.epoch = epoch
    self.size = size
    self.initialSequence = initialSequence
    self.presentationFeedback = presentationFeedback
    self.origin = origin
    deadline = origin + GuestFrameTiming.durationMS / 1000 + Self.drainSeconds
    self.clock = clock
    records.reserveCapacity(GuestFrameTiming.sampleLimit)
    indices.reserveCapacity(GuestFrameTiming.sampleLimit)
    tickets.reserveCapacity(Self.ticketLimit)
    waiters.reserveCapacity(2)
  }

  /// Receipt time is host delivery time, as in the original receiver metric.
  func receive(epoch: UUID, size: PixelSize, sequence: UInt64) throws {
    let ms = (clock.now() - origin) * 1000
    lock.lock()
    guard status == .sampling else {
      lock.unlock()
      return
    }
    guard self.epoch == epoch, self.size == size, ms.isFinite, ms >= 0,
      sequence > (records.last?.sequence ?? initialSequence),
      ms >= (records.last?.receivedMS ?? 0)
    else {
      sealLocked(.invalid)
      unlockAndResume()
      throw GuestFrameTiming.Invalid.changed
    }
    guard ms < GuestFrameTiming.durationMS else {
      lock.unlock()
      return
    }
    guard records.count < GuestFrameTiming.sampleLimit else {
      sealLocked(.invalid, reason: .receiveLimit)
      unlockAndResume()
      throw GuestFrameTiming.Invalid.limit
    }
    indices[sequence] = records.count
    records.append(Record(sequence: sequence, receivedMS: ms))
    lock.unlock()
  }

  /// Called at actual drawable submission, before registering its callbacks.
  /// No ticket is issued for initial/out-of-window/unreceived content.
  func issue(epoch: UUID?, size: PixelSize?, sequence: UInt64) -> Ticket? {
    let ms = (clock.now() - origin) * 1000
    lock.lock()
    guard status == .sampling else {
      lock.unlock()
      return nil
    }
    guard ms.isFinite, ms >= 0 else {
      sealLocked(.invalid)
      unlockAndResume()
      return nil
    }
    guard ms < GuestFrameTiming.durationMS, sequence > initialSequence, indices[sequence] != nil
    else {
      lock.unlock()
      return nil
    }
    guard self.epoch == epoch, self.size == size, issued < Self.ticketLimit else {
      sealLocked(.invalid, reason: issued >= Self.ticketLimit ? .ticketLimit : .changed)
      unlockAndResume()
      return nil
    }
    issued += 1
    tickets[issued] = Pending(sequence: sequence)
    let ticket = Ticket(owner: self, number: issued, sequence: sequence)
    lock.unlock()
    return ticket
  }

  /// The AppKit path is synchronous at draw entry and has no native tickets.
  func appKitDraw(epoch: UUID?, size: PixelSize?, sequence: UInt64) {
    let ms = (clock.now() - origin) * 1000
    lock.lock()
    guard status == .sampling, !presentationFeedback, sequence > initialSequence,
      let index = indices[sequence]
    else {
      lock.unlock()
      return
    }
    guard self.epoch == epoch, self.size == size, ms.isFinite, ms >= records[index].receivedMS
    else {
      sealLocked(.invalid)
      unlockAndResume()
      return
    }
    if ms < GuestFrameTiming.durationMS {
      if records[index].drawnMS == nil { drawnCount += 1 }
      records[index].drawnMS = min(records[index].drawnMS ?? ms, ms)
    }
    lock.unlock()
  }

  func beginDraining() {
    lock.lock()
    guard status == .sampling else {
      lock.unlock()
      return
    }
    let now = clock.now()
    guard now.isFinite, (now - origin) * 1000 >= GuestFrameTiming.durationMS else {
      sealLocked(.invalid, reason: .earlyCutoff)
      unlockAndResume()
      return
    }
    status = .draining
    // Dispatcher delay cannot restart or extend the drain budget. The event
    // interval ends at20s and this sample's absolute grace deadline is22s.
    expireLocked()
    let remaining: Double? = status == .draining ? max(0, deadline - now) : nil
    unlockAndResume()
    if let remaining { scheduleDeadline(remaining) }
  }

  /// Renderer-queue snapshot: older ticket issuance precedes this receipt.
  /// This never asserts that callbacks have originated or completed.
  func sourceDidStop() {
    lock.lock()
    expireLocked()
    sourceStopped = true
    if status == .draining, tickets.isEmpty { sealLocked(.complete) }
    unlockAndResume()
  }

  func cancel() {
    lock.lock()
    if frozen == nil { sealLocked(.cancelled) }
    unlockAndResume()
  }

  func diagnostics() -> Diagnostics {
    lock.lock()
    defer { lock.unlock() }
    return frozen?.diagnostics ?? diagnosticsLocked(status)
  }

  func outcome() async -> Outcome {
    let snapshot: Snapshot = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.lock()
        // One controller waits in production. Bound accidental concurrent
        // finalizers as well; they cannot grow a second unbounded collector.
        waiters.append(continuation)
        if waiters.count > 1, frozen == nil { sealLocked(.invalid, reason: .concurrentFinalizers) }
        expireLocked()
        unlockAndResume()
      }
    } onCancel: {
      cancel()
    }
    guard snapshot.diagnostics.status == .complete else {
      return Outcome(diagnostics: snapshot.diagnostics, result: nil)
    }
    // Reduction/sorting is outside the lock and every native callback. Native
    // handoff acceptance is O(1); no GPU/display queue waits on this final work.
    var reducer = GuestFrameTiming(
      epoch: epoch, size: size, initialSequence: initialSequence,
      presentationFeedback: presentationFeedback)
    do {
      for record in snapshot.records {
        try reducer.receive(
          epoch: epoch, size: size, sequence: record.sequence, ms: record.receivedMS)
      }
      for record in snapshot.records {
        if let ms = record.drawnMS {
          try reducer.recordedDraw(epoch: epoch, size: size, sequence: record.sequence, ms: ms)
        }
        if let ms = record.presentedMS {
          try reducer.present(epoch: epoch, size: size, sequence: record.sequence, ms: ms)
        }
      }
      return Outcome(
        diagnostics: snapshot.diagnostics,
        result: try reducer.result(elapsedMS: GuestFrameTiming.durationMS))
    } catch {
      return Outcome(diagnostics: snapshot.diagnostics, result: nil)
    }
  }

  private func completed(_ ticket: Ticket, success: Bool, hostTime: Double) {
    lock.lock()
    expireLocked()
    guard frozen == nil, var pending = tickets[ticket.number],
      pending.sequence == ticket.sequence, !pending.completionReceived
    else {
      unlockAndResume()
      return
    }
    guard success else {
      tickets.removeValue(forKey: ticket.number)
      finishIfReadyLocked()
      unlockAndResume()
      return
    }
    pending.completionReceived = true
    let ms = (hostTime - origin) * 1000
    guard ms.isFinite, let index = indices[pending.sequence], ms >= records[index].receivedMS else {
      sealLocked(.invalid)
      unlockAndResume()
      return
    }
    if ms < GuestFrameTiming.durationMS {
      pending.drawnMS = ms
      if records[index].drawnMS == nil { drawnCount += 1 }
      records[index].drawnMS = min(records[index].drawnMS ?? ms, ms)
    }
    acceptLocked(pending, number: ticket.number)
    unlockAndResume()
  }

  private func presented(_ ticket: Ticket, hostTime: Double) {
    lock.lock()
    expireLocked()
    guard frozen == nil, var pending = tickets[ticket.number],
      pending.sequence == ticket.sequence, !pending.presentationReceived
    else {
      unlockAndResume()
      return
    }
    guard hostTime.isFinite else {
      sealLocked(.invalid)
      unlockAndResume()
      return
    }
    pending.presentationReceived = true
    // Zero, skipped and out-of-window events settle without a presentation.
    let ms = (hostTime - origin) * 1000
    if hostTime.isFinite, hostTime > 0, ms >= 0, ms < GuestFrameTiming.durationMS,
      let index = indices[pending.sequence]
    {
      guard ms >= records[index].receivedMS else {
        sealLocked(.invalid)
        unlockAndResume()
        return
      }
      pending.presentedMS = ms
    }
    acceptLocked(pending, number: ticket.number)
    unlockAndResume()
  }

  private func acceptLocked(_ pending: Pending, number: Int) {
    if pending.completionReceived, pending.presentationReceived {
      if let index = indices[pending.sequence] {
        if let ms = pending.presentedMS {
          if records[index].presentedMS == nil { presentedCount += 1 }
          records[index].presentedMS = min(records[index].presentedMS ?? ms, ms)
        }
      }
      tickets.removeValue(forKey: number)
    } else {
      tickets[number] = pending
    }
    finishIfReadyLocked()
  }

  private func finishIfReadyLocked() {
    if status == .draining, sourceStopped, tickets.isEmpty { sealLocked(.complete) }
  }

  private func expireLocked() {
    // Native receipts must honor the absolute bound even if MainActor has not
    // run the20s cutoff yet. Delayed cutoff cannot admit feedback after22s.
    if status == .sampling || status == .draining, clock.now() >= deadline {
      sealLocked(.incompleteFeedback)
    }
  }

  private func scheduleDeadline(_ delay: Double) {
    clock.schedule(delay) { [weak self] in self?.deadlineReached() }
  }

  private func deadlineReached() {
    lock.lock()
    expireLocked()
    let remaining: Double? = status == .draining ? max(0, deadline - clock.now()) : nil
    unlockAndResume()
    if let remaining { scheduleDeadline(remaining) }
  }

  private func diagnosticsLocked(_ terminal: Status) -> Diagnostics {
    Diagnostics(
      sampleID: id, status: terminal, invalidReason: invalidReason, received: records.count,
      drawn: drawnCount, presented: presentedCount,
      issuedTickets: issued, unresolvedTickets: tickets.count, sourceStopped: sourceStopped)
  }

  private func sealLocked(_ terminal: Status, reason: InvalidReason = .changed) {
    guard frozen == nil else { return }
    status = terminal
    if terminal == .invalid { invalidReason = reason }
    frozen = Snapshot(records: records, diagnostics: diagnosticsLocked(terminal))
  }

  /// The lock is held on entry. Acceptance has already happened before any
  /// waiter is resumed; enqueueing another UI task never counts as settlement.
  private func unlockAndResume() {
    let completed = frozen
    let ready = completed == nil ? [] : waiters
    if completed != nil { waiters.removeAll() }
    lock.unlock()
    if let completed { for waiter in ready { waiter.resume(returning: completed) } }
  }
}
