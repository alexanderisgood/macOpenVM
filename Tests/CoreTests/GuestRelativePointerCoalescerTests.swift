// SPDX-License-Identifier: Apache-2.0
import Testing
import VMCore

@MainActor struct GuestRelativePointerCoalescerTests {
  @Test func motionAddsAndCanContinueBeyondEveryDisplayEdge() throws {
    let queue = GuestRelativePointerCoalescer()
    let first = try #require(queue.enqueue(dx: 1, dy: -1, buttons: 0))
    for _ in 0..<10_000 { #expect(queue.enqueue(dx: 1, dy: -1, buttons: 0) == nil) }
    let motion = try #require(first.take())
    #expect(motion.dx == 10_001 && motion.dy == -10_001 && motion.buttons == 0)
    #expect(first.take() == nil)
    let next = try #require(queue.enqueue(dx: 10_001, dy: 0, buttons: 0))
    #expect(next !== first && next.take()?.dx == 10_001)
  }

  @Test func overflowSplitsWithoutLosingMotionAndEdgesNeverMerge() throws {
    let queue = GuestRelativePointerCoalescer()
    let large = try #require(queue.enqueue(dx: 32_000, dy: 0, buttons: 0))
    let split = try #require(queue.enqueue(dx: 1000, dy: 0, buttons: 0))
    let down = try #require(queue.enqueue(dx: 3, dy: 4, buttons: 1))
    let drag = try #require(queue.enqueue(dx: 5, dy: 6, buttons: 1))
    #expect(queue.enqueue(dx: 7, dy: 8, buttons: 1) == nil)
    let up = try #require(queue.enqueue(dx: 9, dy: 10, buttons: 0))
    queue.barrier()
    let afterKey = try #require(queue.enqueue(dx: 11, dy: 12, buttons: 0))
    #expect(large.take()?.dx == 32_000 && split.take()?.dx == 1000)
    #expect(down.take()?.dx == 3 && drag.take()?.dx == 12 && up.take()?.dx == 9)
    #expect(afterKey.take()?.dx == 11)
  }
}
