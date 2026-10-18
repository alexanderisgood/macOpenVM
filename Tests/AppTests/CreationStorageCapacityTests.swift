// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import MacOpenVMApp

private actor CapacityProbeFixture {
  struct Request {
    let parent: URL
    let continuation: CheckedContinuation<UInt64, any Error>
  }
  private var requests: [Int: Request] = [:]
  private var nextID = 0
  func probe(_ parent: URL) async throws -> UInt64 {
    let id = nextID
    nextID += 1
    return try await withCheckedThrowingContinuation {
      requests[id] = Request(parent: parent, continuation: $0)
    }
  }
  var count: Int { requests.count }
  func finish(_ id: Int, bytes: UInt64) {
    requests.removeValue(forKey: id)?.continuation.resume(returning: bytes)
  }
  func fail(_ id: Int) {
    requests.removeValue(forKey: id)?.continuation.resume(throwing: ProbeFailure())
  }
  struct ProbeFailure: Error {}
}

@MainActor @Suite struct CreationStorageCapacityTests {
  private let first = URL(fileURLWithPath: "/private/tmp/first")
  private let second = URL(fileURLWithPath: "/private/tmp/second")
  private func pending(_ fixture: CapacityProbeFixture, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while await fixture.count < count, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await fixture.count == count)
  }

  @Test func unknownLoadingAndFailureNeverAdmitCreation() async throws {
    let fixture = CapacityProbeFixture()
    let advisor = CreationStorageAdvisor(provider: { try await fixture.probe($0) })
    #expect(!advisor.canCreate(in: nil) && !advisor.canCreate(in: first))
    let probe = Task { await advisor.refresh(parent: first) }
    try await pending(fixture, count: 1)
    #expect(advisor.reading == .loading && !advisor.canCreate(in: first))
    await fixture.fail(0)
    await probe.value
    #expect(advisor.reading == .unavailable && !advisor.canCreate(in: first))
    await advisor.refresh(parent: nil)
    #expect(advisor.reading == .unknown && advisor.parent == nil)
  }

  @Test func latestDestinationWinsWhenRepliesArriveOutOfOrder() async throws {
    let fixture = CapacityProbeFixture()
    let advisor = CreationStorageAdvisor(provider: { try await fixture.probe($0) })
    let old = Task { await advisor.refresh(parent: first) }
    try await pending(fixture, count: 1)
    let current = Task { await advisor.refresh(parent: second) }
    try await pending(fixture, count: 2)
    await fixture.finish(1, bytes: 8 << 30)
    await current.value
    #expect(advisor.parent == second && advisor.reading == .available(8 << 30))
    #expect(advisor.canCreate(in: second) && !advisor.canCreate(in: first))
    await fixture.finish(0, bytes: 0)
    await old.value
    #expect(advisor.parent == second && advisor.reading == .available(8 << 30))
  }

  @Test func sameDestinationRefreshInvalidatesItsPreviousReading() async throws {
    let fixture = CapacityProbeFixture()
    let advisor = CreationStorageAdvisor(provider: { try await fixture.probe($0) })
    let firstProbe = Task { await advisor.refresh(parent: first) }
    try await pending(fixture, count: 1)
    await fixture.finish(0, bytes: 10 << 30)
    await firstProbe.value
    #expect(advisor.canCreate(in: first))
    let revision = advisor.refreshRevision
    advisor.requestRefresh()
    #expect(advisor.refreshRevision != revision && advisor.reading == .loading)
    #expect(!advisor.canCreate(in: first))
    let refresh = Task { await advisor.refresh(parent: first) }
    try await pending(fixture, count: 1)
    #expect(advisor.reading == .loading && !advisor.canCreate(in: first))
    await fixture.finish(1, bytes: 512 << 20)
    await refresh.value
    #expect(!advisor.canCreate(in: first))
  }

  @Test func cancellationAndDisappearanceCannotPublishLateCapacity() async throws {
    let fixture = CapacityProbeFixture()
    let advisor = CreationStorageAdvisor(provider: { try await fixture.probe($0) })
    let cancelled = Task { await advisor.refresh(parent: first) }
    try await pending(fixture, count: 1)
    cancelled.cancel()
    await fixture.finish(0, bytes: 8 << 30)
    await cancelled.value
    #expect(advisor.reading == .loading && !advisor.canCreate(in: first))
    let disappeared = Task { await advisor.refresh(parent: second) }
    try await pending(fixture, count: 1)
    advisor.invalidate()
    await fixture.finish(1, bytes: 8 << 30)
    await disappeared.value
    #expect(advisor.reading == .unknown && advisor.parent == nil && !advisor.canCreate(in: second))
  }

  @Test func reserveAndVirtualGrowthAreSeparateAndSignedBoundsStaySafe() async {
    let gib = CreationStorageAdvisor.minimumCreationBytes
    let advisor = CreationStorageAdvisor(provider: { _ in gib })
    await advisor.refresh(parent: first)
    #expect(advisor.canCreate(in: first))
    #expect(advisor.growthDeficit(diskGiB: 64) == 63 * gib)
    #expect(advisor.growthDeficit(diskGiB: 1) == nil)
    for invalid in [Int.min, -1, 0, 2049, Int.max] {
      #expect(advisor.growthDeficit(diskGiB: invalid) == nil)
    }
    let below = CreationStorageAdvisor(provider: { _ in gib - 1 })
    await below.refresh(parent: first)
    #expect(!below.canCreate(in: first))
    let abundant = CreationStorageAdvisor(provider: { _ in UInt64.max })
    await abundant.refresh(parent: first)
    #expect(abundant.canCreate(in: first) && abundant.growthDeficit(diskGiB: 2048) == nil)
  }
}
