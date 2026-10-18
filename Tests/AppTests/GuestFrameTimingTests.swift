// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite struct GuestFrameTimingTests {
  private let epoch = UUID()
  private let size = PixelSize(width: 3456, height: 2168)

  @Test func countsCoalescedFramesAndDuplicateDrawsWithoutClaimingScanout() throws {
    var timing = GuestFrameTiming(epoch: epoch, size: size, initialSequence: 10)
    try timing.draw(epoch: epoch, size: size, sequence: 10, ms: 0.5)
    try timing.receive(epoch: epoch, size: size, sequence: 11, ms: 1)
    try timing.receive(epoch: epoch, size: size, sequence: 12, ms: 3)
    try timing.draw(epoch: epoch, size: size, sequence: 12, ms: 5)
    try timing.draw(epoch: epoch, size: size, sequence: 12, ms: 7)
    try timing.receive(epoch: epoch, size: size, sequence: 13, ms: 9)
    try timing.draw(epoch: epoch, size: size, sequence: 13, ms: 15)
    let result = try timing.result(elapsedMS: 20_100)
    #expect(result.received == 3 && result.drawn == 2 && result.receivedNotDrawn == 1)
    #expect(result.drawRate == 0.1 && result.receiveRate == 0.15)
    #expect(result.drawGaps.p95MS == 10 && result.drawGaps.over120HzBudget == 1)
    #expect(result.receiveToDraw.medianMS == 2 && result.receiveToDraw.p95MS == 6)
    #expect(result.samples[0].drawnMS == nil && result.samples[1].drawnMS == 5)
    #expect(!result.physicalScanoutMeasured && result.width == 3456 && result.height == 2168)
  }

  @Test func excludesEventsOutsideTheFixedWindowAndAcceptsAnIdleDisplay() throws {
    var timing = GuestFrameTiming(epoch: epoch, size: size)
    try timing.receive(epoch: epoch, size: size, sequence: 1, ms: 19_999)
    try timing.draw(epoch: epoch, size: size, sequence: 1, ms: 20_000)
    try timing.receive(epoch: epoch, size: size, sequence: 2, ms: 20_001)
    let result = try timing.result(elapsedMS: 20_030)
    #expect(result.received == 1 && result.drawn == 0 && result.durationMS == 20_000)
    #expect(result.drawGaps.longestMS == 0)
    #expect(try GuestFrameTiming(epoch: epoch, size: size).result(elapsedMS: 20_000).received == 0)
  }

  @Test func rejectsReconnectResizeStaleOrMissingSequenceAndInvalidClock() throws {
    var timing = GuestFrameTiming(epoch: epoch, size: size)
    try timing.receive(epoch: epoch, size: size, sequence: 1, ms: 10)
    for other in [UUID(), epoch] {
      let changed = other == epoch ? PixelSize(width: 1280, height: 1024) : size
      #expect(throws: GuestFrameTiming.Invalid.self) {
        try timing.receive(epoch: other, size: changed, sequence: 2, ms: 11)
      }
    }
    #expect(throws: GuestFrameTiming.Invalid.self) {
      try timing.receive(epoch: epoch, size: size, sequence: 1, ms: 11)
    }
    #expect(throws: GuestFrameTiming.Invalid.self) {
      try timing.draw(epoch: epoch, size: size, sequence: 2, ms: 11)
    }
    for ms in [9, Double.nan, Double.infinity, -1] {
      #expect(throws: GuestFrameTiming.Invalid.self) {
        try timing.receive(epoch: epoch, size: size, sequence: 2, ms: ms)
      }
    }
    #expect(throws: GuestFrameTiming.Invalid.self) { try timing.result(elapsedMS: 19_999) }
  }

  @Test func boundsMemoryDuringAnExcessiveUpdateStream() throws {
    var timing = GuestFrameTiming(epoch: epoch, size: size)
    for index in 1...GuestFrameTiming.sampleLimit {
      try timing.receive(epoch: epoch, size: size, sequence: UInt64(index), ms: Double(index))
    }
    #expect(throws: GuestFrameTiming.Invalid.self) {
      try timing.receive(epoch: epoch, size: size, sequence: 4097, ms: 4097)
    }
    #expect(timing.samples.count == GuestFrameTiming.sampleLimit)
  }

  @Test func separatesPresentationFromGPUCompletionAndCallbackOrder() throws {
    var timing = GuestFrameTiming(
      epoch: epoch, size: size, initialSequence: 10,
      presentationFeedback: true)
    try timing.receive(epoch: epoch, size: size, sequence: 11, ms: 1)
    try timing.draw(epoch: epoch, size: size, sequence: 11, ms: 2)
    try timing.receive(epoch: epoch, size: size, sequence: 12, ms: 3)
    try timing.draw(epoch: epoch, size: size, sequence: 12, ms: 4)
    try timing.receive(epoch: epoch, size: size, sequence: 13, ms: 30)
    // Timestamp order is independent of callback delivery and newer receives.
    try timing.present(epoch: epoch, size: size, sequence: 12, ms: 20)
    try timing.present(epoch: epoch, size: size, sequence: 11, ms: 10)
    try timing.present(epoch: epoch, size: size, sequence: 11, ms: 15)
    try timing.present(epoch: epoch, size: size, sequence: 13, ms: 20_000)
    try timing.present(epoch: epoch, size: size, sequence: 10, ms: -1)
    let result = try timing.result(elapsedMS: 20_000)
    #expect(result.drawn == 2 && result.presented == 2)
    #expect(result.presentationRate == 0.1)
    #expect(result.presentationGaps?.longestMS == 10)
    #expect(result.samples[0].presentedMS == 10)
    #expect(result.samples[2].presentedMS == nil)
    #expect(!result.physicalScanoutMeasured)
  }

  @Test func absentFeedbackAndSkippedDrawablesDoNotBecomePresentations() throws {
    var appKit = GuestFrameTiming(epoch: epoch, size: size)
    try appKit.receive(epoch: epoch, size: size, sequence: 1, ms: 1)
    try appKit.draw(epoch: epoch, size: size, sequence: 1, ms: 2)
    let plain = try appKit.result(elapsedMS: 20_000)
    #expect(plain.presented == nil && plain.presentationRate == nil)
    var metal = GuestFrameTiming(epoch: epoch, size: size, presentationFeedback: true)
    try metal.receive(epoch: epoch, size: size, sequence: 1, ms: 1)
    try metal.draw(epoch: epoch, size: size, sequence: 1, ms: 2)
    let skipped = try metal.result(elapsedMS: 20_000)
    #expect(skipped.drawn == 1 && skipped.presented == 0)
    #expect(skipped.presentationRate == 0)
    #expect(throws: GuestFrameTiming.Invalid.self) {
      try metal.present(epoch: UUID(), size: size, sequence: 1, ms: 3)
    }
    #expect(throws: GuestFrameTiming.Invalid.self) {
      try metal.present(epoch: epoch, size: size, sequence: 2, ms: 3)
    }
    #expect(throws: GuestFrameTiming.Invalid.self) {
      try metal.present(epoch: epoch, size: size, sequence: 1, ms: .nan)
    }
    #expect(throws: GuestFrameTiming.Invalid.self) {
      try metal.present(epoch: epoch, size: size, sequence: 1, ms: 0.5)
    }
  }
}
