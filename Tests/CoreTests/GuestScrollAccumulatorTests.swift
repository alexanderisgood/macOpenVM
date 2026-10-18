// SPDX-License-Identifier: Apache-2.0
import Testing
import VMCore

@Suite struct GuestScrollAccumulatorTests {
  @Test func preciseFractionalMotionCarriesAndReverses() {
    var scroll = GuestScrollAccumulator()
    #expect(scroll.consume(verticalDelta: 9, precise: true) == 0)
    #expect(scroll.consume(verticalDelta: 9, precise: true) == 0)
    #expect(scroll.consume(verticalDelta: 4, precise: true) == 1)
    #expect(scroll.consume(verticalDelta: -22, precise: true) == -1)
    #expect(scroll.consume(verticalDelta: -10, precise: true) == 0)
    #expect(scroll.consume(verticalDelta: 10, precise: true) == 0)
  }

  @Test func releaseAndDeviceChangeDiscardOldCarry() {
    var scroll = GuestScrollAccumulator()
    #expect(scroll.consume(verticalDelta: 19, precise: true) == 0)
    scroll.reset()
    #expect(scroll.consume(verticalDelta: 2, precise: true) == 0)
    #expect(scroll.consume(verticalDelta: 0.5, precise: false) == 0)
    #expect(scroll.consume(verticalDelta: 0.5, precise: false) == 1)
    #expect(scroll.consume(verticalDelta: 19, precise: true) == 0)
  }

  @Test func hostileDeltasAndStormsStayBounded() {
    var scroll = GuestScrollAccumulator()
    for invalid in [Double.nan, .infinity, -.infinity, 10_001, -10_001] {
      #expect(scroll.consume(verticalDelta: 19, precise: true) == 0)
      #expect(scroll.consume(verticalDelta: invalid, precise: true) == 0)
      #expect(scroll.consume(verticalDelta: 1, precise: true) == 0)
      scroll.reset()
    }
    #expect(scroll.consume(verticalDelta: 10_000, precise: false) == 8)
    #expect(scroll.consume(verticalDelta: -10_000, precise: true) == -8)
    #expect(scroll.consume(verticalDelta: 0, precise: true) == 0)
  }
}
