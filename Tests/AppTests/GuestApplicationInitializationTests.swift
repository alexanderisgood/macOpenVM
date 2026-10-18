// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct GuestApplicationInitializationTests {
  @Test func unattachedInputRefreshPreservesTheApplicationInitializationState() async {
    // A fresh filtered helper sets this requirement. The full concurrent suite
    // may already own an application, whose identity must remain unchanged.
    let applicationBefore: NSApplication? = NSApp
    let requireNoApplication =
      ProcessInfo.processInfo.environment["MACOPENVM_TEST_REQUIRE_NO_APPLICATION"] == "1"
    if requireNoApplication {
      #expect(applicationBefore == nil)
    }
    let capture = GuestHostPointerCapture()
    let view = RfbGuestView()
    view.hostPointerCapture = capture
    var associationCalls = 0
    var warpCalls = 0
    view.associateHostPointer = { _ in
      associationCalls += 1
      return .success
    }
    view.warpHostPointer = { _ in
      warpCalls += 1
      return .success
    }
    view.setHostCursor = { _ in }

    view.captured = true
    view.relativeMouse = true
    view.updateRelativeMouseLock()
    view.update(frame: nil)
    #expect(!view.relativeMouseLocked && !capture.restorationPending)
    view.relativeMouse = false
    view.captured = false
    view.updateRelativeMouseLock()

    let session = RfbLabSession(hostPointerCapture: capture)
    #expect(!session.inputForeground)
    #expect(!session.canCopyDisplayMeasurement)
    session.copyDisplayMeasurement()
    #expect(session.displayMeasurementReport == nil)
    #expect(NSApp === applicationBefore)
    session.focusChanged()
    session.prepareFullscreen()
    session.fullscreenChanged(false)
    session.refreshFullscreenPresentation()
    #expect(NSApp === applicationBefore)

    let applicationBeforeDisconnect: NSApplication? = NSApp
    await session.disconnectDisplay()
    // Another full-suite fixture may legitimately initialize the application
    // while disconnect yields. The isolated helper forbids that ambiguity.
    if requireNoApplication || applicationBeforeDisconnect != nil {
      #expect(NSApp === applicationBeforeDisconnect)
    }
    #expect(!session.inputForeground)
    #expect(associationCalls == 0 && warpCalls == 0)
    print(
      "Unattached input application probe: initial_nil=\(applicationBefore == nil), final_nil=\(NSApp == nil)"
    )
  }
}
