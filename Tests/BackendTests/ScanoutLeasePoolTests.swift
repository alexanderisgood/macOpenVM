// SPDX-License-Identifier: Apache-2.0
import SharedFrameWire
import Testing

@Suite struct ScanoutLeasePoolTests {
  @Test func writerCompletionCanArriveOutOfOrder() throws {
    var pool = MVOScanoutLeasePool()
    var first = MVOScanoutLease()
    var second = MVOScanoutLease()
    var third = MVOScanoutLease()
    var scratch = MVOScanoutLease()
    try #require(mvo_scanout_lease_init(&pool, 1))
    try #require(mvo_scanout_lease_begin_write(&pool, &first))
    try #require(mvo_scanout_lease_begin_write(&pool, &second))
    try #require(mvo_scanout_lease_begin_write(&pool, &third))
    #expect(!mvo_scanout_lease_begin_write(&pool, &scratch))
    #expect(!mvo_scanout_lease_take_latest(&pool, &scratch))

    try #require(mvo_scanout_lease_finish_write(&pool, second, true))
    try #require(mvo_scanout_lease_take_latest(&pool, &scratch))
    #expect(scratch.sequence == second.sequence)
    #expect(scratch.slot == second.slot)
    #expect(mvo_scanout_lease_finish_write(&pool, first, true))
    #expect(mvo_scanout_lease_finish_write(&pool, third, false))
    #expect(!mvo_scanout_lease_take_latest(&pool, &scratch))
    #expect(!mvo_scanout_lease_finish_write(&pool, second, true))
    #expect(mvo_scanout_lease_release_read(&pool, second))
    #expect(mvo_scanout_lease_is_drained(&pool))
  }

  @Test func retiringAConnectionRequiresOutstandingGpuWorkToDrain() throws {
    var pool = MVOScanoutLeasePool()
    var oldFrame = MVOScanoutLease()
    var borrowed = MVOScanoutLease()
    var pending = MVOScanoutLease()
    var writing = MVOScanoutLease()
    try #require(mvo_scanout_lease_init(&pool, 41))
    try #require(mvo_scanout_lease_begin_write(&pool, &oldFrame))
    try #require(mvo_scanout_lease_finish_write(&pool, oldFrame, true))
    try #require(mvo_scanout_lease_take_latest(&pool, &borrowed))
    try #require(mvo_scanout_lease_begin_write(&pool, &pending))
    try #require(mvo_scanout_lease_begin_write(&pool, &writing))
    try #require(mvo_scanout_lease_finish_write(&pool, pending, true))

    mvo_scanout_lease_retire(&pool)
    #expect(!mvo_scanout_lease_take_latest(&pool, &pending))
    #expect(!mvo_scanout_lease_begin_write(&pool, &pending))
    #expect(!mvo_scanout_lease_is_drained(&pool))
    #expect(mvo_scanout_lease_finish_write(&pool, writing, true))
    #expect(!mvo_scanout_lease_is_drained(&pool))
    #expect(mvo_scanout_lease_release_read(&pool, borrowed))
    #expect(mvo_scanout_lease_is_drained(&pool))

    var replacement = MVOScanoutLeasePool()
    try #require(mvo_scanout_lease_init(&replacement, 42))
    try #require(mvo_scanout_lease_begin_write(&replacement, &writing))
    try #require(mvo_scanout_lease_finish_write(&replacement, writing, true))
    try #require(mvo_scanout_lease_take_latest(&replacement, &pending))
    #expect(pending.sequence == borrowed.sequence)
    #expect(pending.slot == borrowed.slot)
    #expect(!mvo_scanout_lease_release_read(&replacement, borrowed))
    #expect(mvo_scanout_lease_release_read(&replacement, pending))
  }
}
