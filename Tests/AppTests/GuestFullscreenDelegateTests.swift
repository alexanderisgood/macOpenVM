// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

private final class FullscreenForwardedDelegate: NSObject, NSWindowDelegate {
  @MainActor var fullscreenCalls = 0
  @MainActor func window(
    _ window: NSWindow,
    willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    fullscreenCalls += 1
    return proposedOptions.union(.disableCursorLocationAssistance)
  }
  @MainActor func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }
}

@MainActor @Suite struct GuestFullscreenDelegateTests {
  @Test func installsOnCurrentHostAndForwardsInactiveAndForeignWindowMessages() {
    let original = FullscreenForwardedDelegate()
    let owner = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
    let foreign = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
    owner.isReleasedWhenClosed = false
    foreign.isReleasedWhenClosed = false
    let session = DesktopSession()
    owner.delegate = original
    session.window = owner
    guard let proxy = owner.delegate as? OwningWindowCloseDelegate else {
      Issue.record("The fullscreen delegate was not installed on this supported host.")
      return
    }
    let native: NSApplication.PresentationOptions = [
      .fullScreen, .autoHideDock, .autoHideMenuBar,
      .autoHideToolbar,
    ]
    #expect(
      proxy.window(owner, willUseFullScreenPresentationOptions: native)
        == native.union(.disableCursorLocationAssistance))
    #expect(
      proxy.window(foreign, willUseFullScreenPresentationOptions: native)
        == native.union(.disableCursorLocationAssistance))
    session.showingLibrary = true
    #expect(
      proxy.window(owner, willUseFullScreenPresentationOptions: native)
        == native.union(.disableCursorLocationAssistance))
    session.showingLibrary = false
    session.state = .stopped
    #expect(
      proxy.window(owner, willUseFullScreenPresentationOptions: native)
        == native.union(.disableCursorLocationAssistance))
    #expect(original.fullscreenCalls == 4)
    let zoom = #selector(NSWindowDelegate.windowShouldZoom(_:toFrame:))
    #expect(proxy.responds(to: zoom))
    #expect((proxy.forwardingTarget(for: zoom) as? FullscreenForwardedDelegate) === original)
    session.window = foreign
    #expect(owner.delegate === original)
    #expect(foreign.delegate is OwningWindowCloseDelegate)
  }
}
