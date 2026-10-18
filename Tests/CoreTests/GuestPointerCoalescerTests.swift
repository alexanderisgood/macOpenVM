// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore

@Suite @MainActor struct GuestPointerCoalescerTests {
  private let epoch = UUID()
  private func sample(
    _ x: UInt16, buttons: UInt8 = 0, width: Int = 800, epoch otherEpoch: UUID? = nil
  ) -> GuestPointerSample {
    GuestPointerSample(
      point: GuestPixelPoint(x: x, y: 100), buttons: buttons,
      pixels: PixelSize(width: width, height: 600), epoch: otherEpoch ?? epoch)
  }

  @Test func unsentMotionStormUsesOneSlotAndKeepsLastPosition() throws {
    let coalescer = GuestPointerCoalescer()
    let batch = try #require(coalescer.enqueue(sample(0)))
    for index in 1...10_000 {
      #expect(coalescer.enqueue(sample(UInt16(index % 800))) == nil)
    }
    #expect(batch.take() == sample(400))
    #expect(batch.take() == nil)
    let next = try #require(coalescer.enqueue(sample(401)))
    #expect(next !== batch)
    #expect(next.take() == sample(401))
  }

  @Test func everyButtonEdgeAndDragEndpointSurvives() throws {
    let coalescer = GuestPointerCoalescer()
    let move = try #require(coalescer.enqueue(sample(10)))
    let down = try #require(coalescer.enqueue(sample(20, buttons: 1)))
    let drag = try #require(coalescer.enqueue(sample(30, buttons: 1)))
    #expect(coalescer.enqueue(sample(35, buttons: 1)) == nil)
    let up = try #require(coalescer.enqueue(sample(40)))
    let moveAfter = try #require(coalescer.enqueue(sample(45)))
    let rightDown = try #require(coalescer.enqueue(sample(50, buttons: 4)))
    let rightUp = try #require(coalescer.enqueue(sample(60)))
    #expect(move.take() == sample(10))
    #expect(down.take() == sample(20, buttons: 1))
    #expect(drag.take() == sample(35, buttons: 1))
    #expect(up.take() == sample(40))
    #expect(moveAfter.take() == sample(45))
    #expect(rightDown.take() == sample(50, buttons: 4))
    #expect(rightUp.take() == sample(60))
  }

  @Test func barriersKeepPositionsOnTheirOriginalSideOfOtherInput() throws {
    let coalescer = GuestPointerCoalescer()
    let beforeKey = try #require(coalescer.enqueue(sample(10)))
    coalescer.barrier()
    let afterKey = try #require(coalescer.enqueue(sample(20)))
    coalescer.barrier()
    let afterScroll = try #require(coalescer.enqueue(sample(30)))
    coalescer.reset()
    let afterRelease = try #require(coalescer.enqueue(sample(40)))
    #expect(beforeKey.take() == sample(10))
    #expect(afterKey.take() == sample(20))
    #expect(afterScroll.take() == sample(30))
    #expect(afterRelease.take() == sample(40))
  }

  @Test func geometryAndConnectionChangesNeverMerge() throws {
    let coalescer = GuestPointerCoalescer()
    let old = try #require(coalescer.enqueue(sample(10)))
    let resized = try #require(coalescer.enqueue(sample(20, width: 640)))
    let newEpoch = UUID()
    let reconnected = try #require(
      coalescer.enqueue(sample(30, width: 640, epoch: newEpoch)))
    #expect(old.take() == sample(10))
    #expect(resized.take() == sample(20, width: 640))
    #expect(reconnected.take() == sample(30, width: 640, epoch: newEpoch))
  }
}
