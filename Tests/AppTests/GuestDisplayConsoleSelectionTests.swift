// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import MacOpenVMApp

@Suite struct GuestDisplayConsoleSelectionTests {
  @Test(arguments: [false, true], [false, true])
  func explicitGpuRequiresActualSharedEligibilityAndRetainsAnActiveStream(
    route: Bool, active: Bool
  ) throws {
    var selection = GuestDisplayConsoleSelection()
    let begun = selection.begin(.gpu, sharedRouteAvailable: route, sharedActive: active)
    let attempt = try #require(begun)
    let expected: GuestDisplayConsoleSelection.SharedAction =
      !route ? .rfbOnly : active ? .retainActive : .retryAdmittedRoute
    #expect(attempt.sharedAction == expected)
    #expect(attempt.sharedAction.stopsShared == (expected != .retainActive))
    #expect(!selection.permitsDeferredReconnect(attempt))
    let finished = selection.finish(attempt)
    #expect(finished)
    #expect(selection.permitsDeferredReconnect(attempt) == (expected == .retryAdmittedRoute))
  }

  @Test(arguments: [false, true], [false, true])
  func firmwareAlwaysStopsSharedWithoutAuthorizingAReconnect(route: Bool, active: Bool) throws {
    var selection = GuestDisplayConsoleSelection()
    let begun = selection.begin(.firmware, sharedRouteAvailable: route, sharedActive: active)
    let attempt = try #require(begun)
    #expect(attempt.sharedAction == .disableForFirmware && attempt.sharedAction.stopsShared)
    let finished = selection.finish(attempt)
    #expect(finished)
    #expect(!selection.permitsDeferredReconnect(attempt))
  }

  @Test func pendingChoiceCannotBeReplacedOrFinishedTwice() throws {
    var selection = GuestDisplayConsoleSelection()
    let begun = selection.begin(.gpu, sharedRouteAvailable: true, sharedActive: false)
    let first = try #require(begun)
    let replacement = selection.begin(.firmware, sharedRouteAvailable: true, sharedActive: false)
    #expect(replacement == nil)
    #expect(selection.ownsPending(first) && !selection.permitsDeferredReconnect(first))
    let firstFinish = selection.finish(first)
    #expect(firstFinish)
    let duplicateFinish = selection.finish(first)
    #expect(!duplicateFinish)
    #expect(selection.permitsDeferredReconnect(first))
  }

  @Test func aLaterFirmwareChoiceInvalidatesEvenAnAlreadyFinishedGpuRetry() throws {
    var selection = GuestDisplayConsoleSelection()
    let begunGpu = selection.begin(.gpu, sharedRouteAvailable: true, sharedActive: false)
    let gpu = try #require(begunGpu)
    let gpuFinished = selection.finish(gpu)
    #expect(gpuFinished && selection.permitsDeferredReconnect(gpu))
    let begunFirmware = selection.begin(.firmware, sharedRouteAvailable: true, sharedActive: false)
    let firmware = try #require(begunFirmware)
    #expect(!selection.permitsDeferredReconnect(gpu))
    let firmwareFinished = selection.finish(firmware)
    #expect(firmwareFinished)
    #expect(
      !selection.permitsDeferredReconnect(gpu) && !selection.permitsDeferredReconnect(firmware))
  }

  @Test func closingTheDisplayInvalidatesPendingAndDeferredSelectionTokens() throws {
    var selection = GuestDisplayConsoleSelection()
    let begunPending = selection.begin(.gpu, sharedRouteAvailable: true, sharedActive: false)
    let pending = try #require(begunPending)
    selection.cancel()
    let canceledFinish = selection.finish(pending)
    #expect(!canceledFinish && !selection.permitsDeferredReconnect(pending))
    let begunFinished = selection.begin(.gpu, sharedRouteAvailable: true, sharedActive: false)
    let finished = try #require(begunFinished)
    let didFinish = selection.finish(finished)
    #expect(didFinish)
    selection.cancel()
    #expect(!selection.permitsDeferredReconnect(finished))
  }

  @Test func firmwareThenGpuRestoresEligibilityWhileNoRouteRemainsRfbOnly() throws {
    var selection = GuestDisplayConsoleSelection()
    let begunFirmware = selection.begin(.firmware, sharedRouteAvailable: true, sharedActive: true)
    let firmware = try #require(begunFirmware)
    let firmwareFinished = selection.finish(firmware)
    #expect(firmwareFinished)
    let begunGpu = selection.begin(.gpu, sharedRouteAvailable: true, sharedActive: false)
    let gpu = try #require(begunGpu)
    #expect(gpu.sharedAction == .retryAdmittedRoute)
    let gpuFinished = selection.finish(gpu)
    #expect(gpuFinished)
    #expect(selection.permitsDeferredReconnect(gpu))
    let begunOrdinary = selection.begin(.gpu, sharedRouteAvailable: false, sharedActive: false)
    let ordinary = try #require(begunOrdinary)
    #expect(ordinary.sharedAction == .rfbOnly)
    let ordinaryFinished = selection.finish(ordinary)
    #expect(ordinaryFinished)
    #expect(
      !selection.permitsDeferredReconnect(ordinary) && !selection.permitsDeferredReconnect(gpu))
  }
}
