// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

@Suite struct GuestFullscreenPresentationTests {
  @Test func retainsNativeMenuPolicyWithoutChangingFullscreenOrShowingToolbar() {
    var policy = GuestFullscreenPresentation()
    policy.prepare([])
    let native: NSApplication.PresentationOptions = [
      .fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar,
      .disableCursorLocationAssistance,
    ]
    #expect(
      policy.applying(to: native)
        == [.fullScreen, .autoHideDock, .autoHideMenuBar, .disableCursorLocationAssistance])
    #expect(policy.applying(to: []) == .autoHideDock)
  }

  @Test func exitPreservesCurrentNativeAndUnownedFlags() {
    var policy = GuestFullscreenPresentation()
    policy.prepare([.disableCursorLocationAssistance])
    _ = policy.applying(to: [.fullScreen, .autoHideDock, .autoHideMenuBar])
    // The system removed fullscreen; another component changed an unowned flag.
    let afterExit: NSApplication.PresentationOptions = [.hideDock, .disableHideApplication]
    #expect(policy.finish(afterExit) == [.disableHideApplication])
    #expect(policy.finish([.autoHideDock]) == [.autoHideDock])
    #expect(policy.applying(to: [.autoHideDock]) == [.autoHideDock])
  }

  @Test func suspensionAndRepeatedEntryKeepOriginalVisibility() {
    var policy = GuestFullscreenPresentation()
    let baseline: NSApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
    policy.prepare(baseline)
    _ = policy.applying(to: baseline.union(.fullScreen))
    policy.prepare([.fullScreen, .hideDock])
    #expect(policy.suspending([.fullScreen, .hideDock]) == baseline.union(.fullScreen))
    #expect(
      policy.applying(to: baseline.union(.fullScreen))
        == [.fullScreen, .autoHideDock, .autoHideMenuBar])
    #expect(policy.finish([.hideDock]) == baseline)
    policy.prepare([])
    _ = policy.applying(to: [.fullScreen])
    #expect(policy.finish([.hideDock]) == [])
  }

  @Test func neverRestoresToolbarWithoutRequiredNativeState() {
    var policy = GuestFullscreenPresentation()
    policy.prepare([.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar])
    _ = policy.applying(to: [.fullScreen])
    #expect(policy.finish([.hideDock]) == [.autoHideDock, .autoHideMenuBar])
  }

  @Test func respectsOtherOwnersPresentationConstraints() {
    var policy = GuestFullscreenPresentation()
    policy.prepare([])
    _ = policy.applying(to: [.fullScreen])
    let anotherOwner: NSApplication.PresentationOptions = [.hideDock, .disableProcessSwitching]
    #expect(policy.suspending(anotherOwner) == anotherOwner)
    #expect(policy.finish(anotherOwner) == anotherOwner)
  }

  @Test func preparationNeverFightsAnUnfinishedNativeTransition() {
    var policy = GuestFullscreenPresentation()
    policy.beginTransition([])
    let transition: NSApplication.PresentationOptions = [
      .fullScreen, .autoHideDock, .autoHideMenuBar,
    ]
    #expect(policy.suspending(transition) == transition)
    // First entry failed; the second begins with a different valid app baseline.
    policy.beginTransition([.autoHideDock])
    _ = policy.applying(to: transition)
    #expect(policy.finish([]) == [.autoHideDock])
  }

  @Test func replacesLateHardHidingWithTheNativeMenuPolicy() {
    let hidden: NSApplication.PresentationOptions = [.fullScreen, .hideDock, .hideMenuBar]
    #expect(
      GuestFullscreenPresentation.guestOptions(hidden)
        == [.fullScreen, .autoHideDock, .autoHideMenuBar])
    // Do not impose the fullscreen menu option on ordinary desktop windows.
    #expect(GuestFullscreenPresentation.guestOptions([.hideDock, .hideMenuBar]) == .autoHideDock)
  }
}
