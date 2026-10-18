// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite(.serialized) struct SharedDrawFeedbackTests {
  @Test @MainActor func observersAreOptInAndCanToggleWithoutPausingGeneratedDraws() async throws {
    let observations = DrawObservations()
    let renderer = try SharedFrameMetalRenderer(
      presentationActive: true, onDraw: { observations.record($0) })
    defer { renderer.close() }
    try await renderer.configureDrawableRetryValidation(acquire: { true })

    // No setter: successful ordinary draws must remain silent by default.
    redraw(renderer)
    _ = try await wait(renderer) { $0.draws == 1 && !$0.pending }
    #expect(observations.sequences.isEmpty)

    renderer.setDrawFeedbackEnabled(true)
    redraw(renderer)
    _ = try await wait(renderer) { $0.draws == 2 && !$0.pending }
    #expect(observations.sequences == [1])

    renderer.setDrawFeedbackEnabled(false)
    redraw(renderer)
    _ = try await wait(renderer) { $0.draws == 3 && !$0.pending }
    #expect(observations.sequences == [1])

    renderer.setDrawFeedbackEnabled(true)
    redraw(renderer)
    let final = try await wait(renderer) { $0.draws == 4 && !$0.pending }
    #expect(observations.sequences == [1, 1])
    #expect(final.requests == 4 && final.copies == 0 && !final.wanted && !final.scheduled)
    let bytes = try #require(await renderer.generatedDrawableBytesForValidation())
    #expect(bytes.count == 64 * 64 * 4)
    for pixel in 0..<(64 * 64) {
      #expect(bytes[pixel * 4] == 0 && bytes[pixel * 4 + 1] == 0)
      #expect(bytes[pixel * 4 + 2] == 255 && bytes[pixel * 4 + 3] == 255)
    }
  }

  @Test @MainActor func removingObserverWhileDrawableIsPendingSuppressesItsLaterCallback()
    async throws
  {
    let observations = DrawObservations()
    let acquisition = PendingAcquisition()
    defer { acquisition.release() }
    let renderer = try SharedFrameMetalRenderer(
      presentationActive: true, onDraw: { observations.record($0) })
    defer { renderer.close() }
    try await renderer.configureDrawableRetryValidation(acquire: { acquisition.acquire() })
    renderer.setDrawFeedbackEnabled(true)
    redraw(renderer)
    _ = try await wait(renderer) { $0.requests == 1 && $0.pending }

    // The acquisition queue is held while the observer is removed. The real
    // render-queue draw completion must consult the current observer state.
    renderer.setDrawFeedbackEnabled(false)
    _ = await renderer.drawableRetryStateForValidation()
    acquisition.release()
    let final = try await wait(renderer) { $0.draws == 1 && !$0.pending }
    #expect(!acquisition.timedOut)
    #expect(observations.sequences.isEmpty)
    #expect(final.requests == 1 && final.copies == 0 && !final.wanted && !final.scheduled)
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

  private final class DrawObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []

    func record(_ stamp: RfbQualificationPresentation) {
      lock.withLock { recorded.append(stamp.sequence) }
    }

    var sequences: [UInt64] { lock.withLock { recorded } }
  }

  private final class PendingAcquisition: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var expired = false

    func acquire() -> Bool {
      let released = gate.wait(timeout: .now() + 5) == .success
      lock.withLock { expired = !released }
      return released
    }

    func release() { gate.signal() }
    var timedOut: Bool { lock.withLock { expired } }
  }
}
