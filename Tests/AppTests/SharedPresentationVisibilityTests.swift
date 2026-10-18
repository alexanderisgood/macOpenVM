// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import MacOpenVMApp

@Suite struct SharedPresentationVisibilityTests {
  @Test func activeFullscreenOwnerRemainsEligibleWithoutAnOcclusionBit() {
    #expect(
      SharedPresentationVisibility.shouldPresent(
        visible: true, miniaturized: false, onActiveSpace: true, occlusionVisible: false,
        fullscreen: true, keyWindow: true, applicationActive: true))
  }

  @Test func hiddenMinimizedBackgroundAndNonKeyOwnersDoNotUseTheFullscreenException() {
    for field in 0..<5 {
      #expect(
        !SharedPresentationVisibility.shouldPresent(
          visible: field != 0, miniaturized: field == 1, onActiveSpace: true,
          occlusionVisible: false,
          fullscreen: field != 2, keyWindow: field != 3, applicationActive: field != 4))
    }
  }

  @Test func visibleBackgroundWindowStillPresentsWhileAMinimizedOneDoesNot() {
    for miniaturized in [false, true] {
      #expect(
        SharedPresentationVisibility.shouldPresent(
          visible: true, miniaturized: miniaturized, onActiveSpace: true, occlusionVisible: true,
          fullscreen: false, keyWindow: false, applicationActive: false) == !miniaturized)
    }
  }

  @Test func keyActiveFullscreenOnAnotherSpaceDoesNotRequestPresentations() {
    for occlusionVisible in [false, true] {
      #expect(
        !SharedPresentationVisibility.shouldPresent(
          visible: true, miniaturized: false, onActiveSpace: false,
          occlusionVisible: occlusionVisible,
          fullscreen: true, keyWindow: true, applicationActive: true))
    }
  }
}
