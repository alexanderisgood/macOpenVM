import BackendAPI
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite(.serialized) struct SharedDrawableRetryTests {
  @Test @MainActor func lateSharpeningReadinessCancelsAnAlreadyStartedTimingSample() async throws {
    let barrier = CompilationBarrier()
    let renderer = try SharedFrameMetalRenderer()
    defer {
      barrier.release()
      renderer.close()
    }
    try await renderer.configureDrawableRetryValidation(
      acquire: { false }, beforeSharpeningInstall: { barrier.compiled() })
    renderer.setSharpeningEnabled(true)
    for _ in 0..<400 {
      if barrier.arrived { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(barrier.arrived)
    let capture = GuestFrameTimingCapture(
      epoch: UUID(), size: PixelSize(width: 64, height: 64), initialSequence: 1,
      presentationFeedback: true, origin: 0,
      clock: .init(now: { 1 }, schedule: { _, _ in }))
    renderer.beginTimingCapture(capture)
    _ = await renderer.drawableRetryStateForValidation()
    #expect(capture.diagnostics().status == .sampling)
    barrier.release()
    for _ in 0..<400 {
      if capture.diagnostics().status == .cancelled { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(capture.diagnostics().status == .cancelled)
  }

  private final class CompilationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var ready = false
    var arrived: Bool {
      lock.lock()
      defer { lock.unlock() }
      return ready
    }
    func compiled() {
      lock.lock()
      ready = true
      lock.unlock()
      _ = semaphore.wait(timeout: .now() + 2)
    }
    func release() { semaphore.signal() }
  }

  @Test(arguments: [false, true]) @MainActor
  func oldSizeDrawableCannotPresentTheNewViewport(shrinking: Bool) async throws {
    let first = DispatchSemaphore(value: 0)
    let initial = shrinking ? CGSize(width: 128, height: 96) : CGSize(width: 64, height: 64)
    let final = shrinking ? CGSize(width: 64, height: 64) : CGSize(width: 128, height: 96)
    let area =
      shrinking
      ? CGRect(x: 0, y: 0, width: 64, height: 64)
      : CGRect(x: 32, y: 16, width: 64, height: 64)
    let script = ResizingAcquisition(first: first, initial: initial, final: final)
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    defer {
      first.signal()
      renderer.close()
    }
    try await renderer.configureDrawableRetryValidation(
      acquire: { script.acquire() }, drawableSize: { script.size() })
    renderer.redraw(
      drawableSize: initial, viewport: CGRect(x: 0, y: 0, width: 64, height: 64))
    _ = try await wait(renderer) { $0.pending && $0.requests == 1 }
    renderer.redraw(drawableSize: final, viewport: area)
    _ = await renderer.drawableRetryStateForValidation()
    first.signal()
    let drawn = try await wait(renderer) { $0.draws == 1 && !$0.pending }
    #expect(drawn.requests == 2 && !drawn.wanted)
    let bytes = try #require(await renderer.generatedDrawableBytesForValidation())
    #expect(bytes.count == Int(final.width * final.height) * 4)
    for y in 0..<Int(final.height) {
      for x in 0..<Int(final.width) {
        let p = (y * Int(final.width) + x) * 4
        let inside = area.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
        #expect(bytes[p] == 0 && bytes[p + 1] == 0 && bytes[p + 3] == 255)
        #expect(bytes[p + 2] == (inside ? 255 : 0))
      }
    }
  }

  @Test @MainActor func sameSizeAcquisitionUsesLatestViewportWithoutDiscardingIt() async throws {
    let first = DispatchSemaphore(value: 0)
    let size = CGSize(width: 64, height: 64)
    let script = ResizingAcquisition(first: first, initial: size, final: size)
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    defer {
      first.signal()
      renderer.close()
    }
    try await renderer.configureDrawableRetryValidation(
      acquire: { script.acquire() }, drawableSize: { script.size() })
    redraw(renderer)
    _ = try await wait(renderer) { $0.pending && $0.requests == 1 }
    let area = CGRect(x: 16, y: 16, width: 32, height: 32)
    renderer.redraw(drawableSize: size, viewport: area)
    _ = await renderer.drawableRetryStateForValidation()
    first.signal()
    let drawn = try await wait(renderer) { $0.draws == 1 && !$0.pending }
    #expect(drawn.requests == 1 && !drawn.wanted)
    let bytes = try #require(await renderer.generatedDrawableBytesForValidation())
    for y in 0..<64 {
      for x in 0..<64 {
        let p = (y * 64 + x) * 4
        let inside = area.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
        #expect(bytes[p] == 0 && bytes[p + 1] == 0 && bytes[p + 3] == 255)
        #expect(bytes[p + 2] == (inside ? 255 : 0))
      }
    }
  }

  private final class ResizingAcquisition: @unchecked Sendable {
    private let lock = NSLock()
    private let first: DispatchSemaphore
    private let initial: CGSize
    private let final: CGSize
    private var count = 0
    init(first: DispatchSemaphore, initial: CGSize, final: CGSize) {
      self.first = first
      self.initial = initial
      self.final = final
    }
    func acquire() -> Bool {
      lock.lock()
      count += 1
      let initial = count == 1
      lock.unlock()
      return !initial || first.wait(timeout: .now() + 2) == .success
    }
    func size() -> CGSize {
      lock.lock()
      defer { lock.unlock() }
      return count == 1 ? initial : final
    }
  }

  @Test func finiteBudgetAndCancelledTicketsCannotReviveANewerBudget() {
    var policy = SharedDrawableRetryPolicy()
    let first = policy.next()
    #expect(first?.delayMS == 16)
    #expect(policy.next()?.delayMS == 50)
    #expect(policy.next()?.delayMS == 150)
    #expect(policy.next() == nil)
    policy.cancel()
    if let first { #expect(!policy.isCurrent(first)) }
    #expect(policy.next() == nil)
    policy.reset()
    let renewed = policy.next()
    #expect(renewed?.delayMS == 16)
    if let first { #expect(!policy.isCurrent(first)) }
    if let renewed { #expect(policy.isCurrent(renewed)) }
  }

  @Test @MainActor func transientNilRetriesTheStaticCacheAndActuallyDrawsGeneratedPixels()
    async throws
  {
    let script = AcquisitionScript([false, true])
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    defer { renderer.close() }
    try await configure(renderer, script)
    redraw(renderer)
    let waiting = try await wait(renderer) { $0.scheduled && !$0.pending }
    #expect(waiting.requests == 1 && waiting.wanted && waiting.draws == 0)
    #expect(script.delays == [16])
    #expect(script.fireNext())
    let drawn = try await wait(renderer) { $0.draws == 1 && !$0.pending }
    #expect(drawn.requests == 2 && !drawn.wanted && !drawn.scheduled)
    #expect(drawn.copies == 0)
    let output = try #require(await renderer.generatedDrawableBytesForValidation())
    #expect(output.count == 64 * 64 * 4)
    for pixel in 0..<(64 * 64) {
      #expect(output[pixel * 4] == 0 && output[pixel * 4 + 1] == 0)
      #expect(output[pixel * 4 + 2] == 255 && output[pixel * 4 + 3] == 255)
    }
  }

  @Test @MainActor func persistentNilStopsAfterThreeDelayedAttemptsAndRedrawResetsBudget()
    async throws
  {
    let script = AcquisitionScript([])
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    defer { renderer.close() }
    try await configure(renderer, script)
    redraw(renderer)
    for request in 1...3 {
      let waiting = try await wait(renderer) {
        $0.requests == request && $0.scheduled && !$0.pending
      }
      #expect(waiting.wanted)
      #expect(script.fireNext())
    }
    let exhausted = try await wait(renderer) { $0.requests == 4 && !$0.pending }
    #expect(exhausted.wanted && !exhausted.scheduled && exhausted.draws == 0)
    #expect(script.delays == [16, 50, 150])
    #expect(!script.fireNext())
    redraw(renderer)
    let renewed = try await wait(renderer) { $0.requests == 5 && $0.scheduled && !$0.pending }
    #expect(renewed.wanted)
    #expect(script.delays == [16, 50, 150, 16])
  }

  @Test @MainActor func inactiveCancellationRejectsAnOldCallbackWithoutCancellingTheNewRetry()
    async throws
  {
    let script = AcquisitionScript([false, false, true])
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    defer { renderer.close() }
    try await configure(renderer, script)
    redraw(renderer)
    _ = try await wait(renderer) { $0.requests == 1 && $0.scheduled }
    renderer.setPresentationActive(false)
    let inactive = await renderer.drawableRetryStateForValidation()
    #expect(!inactive.active && !inactive.scheduled)
    renderer.setPresentationActive(true)
    _ = try await wait(renderer) { $0.requests == 2 && $0.scheduled }
    #expect(script.fireNext())  // Cancelled first budget's callback.
    let stillWaiting = await renderer.drawableRetryStateForValidation()
    #expect(stillWaiting.requests == 2 && stillWaiting.scheduled)
    #expect(script.fireNext())  // Current budget's callback.
    let drawn = try await wait(renderer) { $0.draws == 1 && !$0.pending }
    #expect(drawn.requests == 3)
    #expect(script.delays == [16, 16])
  }

  @Test @MainActor func productionTimerWakesAndDrawsTheStaticCacheWithoutAnotherFrame() async throws
  {
    let script = AcquisitionScript([false, true])
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    defer { renderer.close() }
    // No scheduling injection: the real render-queue DispatchSource timer fires.
    try await renderer.configureDrawableRetryValidation(acquire: { script.acquire() })
    redraw(renderer)
    let drawn = try await wait(renderer) { $0.draws == 1 && !$0.pending }
    #expect(drawn.requests == 2 && drawn.copies == 0 && !drawn.scheduled && !drawn.wanted)
    #expect(script.attempts == 2 && script.delays.isEmpty)
    let output = try #require(await renderer.generatedDrawableBytesForValidation())
    #expect(output.count == 64 * 64 * 4)
    for pixel in 0..<(64 * 64) {
      #expect(output[pixel * 4] == 0 && output[pixel * 4 + 1] == 0)
      #expect(output[pixel * 4 + 2] == 255 && output[pixel * 4 + 3] == 255)
    }
  }

  @Test @MainActor func closeCancelsAPendingRetryAndStaleCallbacksCannotAcquire() async throws {
    let script = AcquisitionScript([false, true])
    let renderer = try SharedFrameMetalRenderer(presentationActive: true)
    try await configure(renderer, script)
    redraw(renderer)
    _ = try await wait(renderer) { $0.requests == 1 && $0.scheduled }
    renderer.close()
    let closed = await renderer.drawableRetryStateForValidation()
    #expect(closed.closed && !closed.scheduled && !closed.wanted)
    #expect(script.fireNext())
    let after = await renderer.drawableRetryStateForValidation()
    #expect(after.requests == 1 && after.draws == 0 && !after.scheduled)
    #expect(script.attempts == 1)
  }

  @MainActor private func configure(
    _ renderer: SharedFrameMetalRenderer, _ script: AcquisitionScript
  ) async throws {
    try await renderer.configureDrawableRetryValidation(
      acquire: { script.acquire() },
      schedule: { delay, callback in script.schedule(delay, callback) })
  }

  @MainActor private func redraw(_ renderer: SharedFrameMetalRenderer) {
    renderer.redraw(
      drawableSize: CGSize(width: 64, height: 64),
      viewport: CGRect(x: 0, y: 0, width: 64, height: 64))
  }

  @MainActor private func wait(
    _ renderer: SharedFrameMetalRenderer,
    until ready: (SharedFrameMetalRenderer.DrawableRetryValidationState) -> Bool
  ) async throws -> SharedFrameMetalRenderer.DrawableRetryValidationState {
    for _ in 0..<400 {
      let state = await renderer.drawableRetryStateForValidation()
      if ready(state) { return state }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw FixtureFailure.didNotSettle
  }

  private enum FixtureFailure: Error { case didNotSettle }

  private final class AcquisitionScript: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Bool]
    private var acquisitions = 0
    private var scheduledDelays: [Int] = []
    private var callbacks: [@Sendable () -> Void] = []

    init(_ outcomes: [Bool]) { self.outcomes = outcomes }

    func acquire() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      acquisitions += 1
      return outcomes.isEmpty ? false : outcomes.removeFirst()
    }

    func schedule(_ delay: Int, _ callback: @escaping @Sendable () -> Void) {
      lock.lock()
      defer { lock.unlock() }
      scheduledDelays.append(delay)
      callbacks.append(callback)
    }

    func fireNext() -> Bool {
      lock.lock()
      let callback = callbacks.isEmpty ? nil : callbacks.removeFirst()
      lock.unlock()
      callback?()
      return callback != nil
    }

    var delays: [Int] {
      lock.lock()
      defer { lock.unlock() }
      return scheduledDelays
    }

    var attempts: Int {
      lock.lock()
      defer { lock.unlock() }
      return acquisitions
    }
  }
}
