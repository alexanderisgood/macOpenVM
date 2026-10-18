// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct GuestDisplayMeasurementInvalidationTests {
  @Test
  func actualViewPropagatesNativeGeometryAndDetachedPresentationInvalidationWithoutAnApplication() {
    let applicationBefore: NSApplication? = NSApp
    let view = RfbGuestView()
    var invalidations = 0
    view.onDisplayMeasurementInvalidated = { candidate in
      #expect(candidate === view)
      invalidations += 1
    }
    view.setFrameSize(NSSize(width: 64, height: 32))
    #expect(invalidations > 0)
    let afterResize = invalidations
    view.setFrameSize(NSSize(width: 64, height: 32))
    #expect(invalidations == afterResize)
    view.setBoundsSize(NSSize(width: 32, height: 16))
    #expect(invalidations > afterResize)
    let afterBounds = invalidations
    view.setBoundsSize(NSSize(width: 32, height: 16))
    #expect(invalidations == afterBounds)
    view.viewDidChangeBackingProperties()
    #expect(invalidations > afterBounds)
    let afterBacking = invalidations
    // A detached view cannot present. Exercise the native lifecycle entry
    // into visibility invalidation without constructing an application.
    #expect(view.window == nil)
    view.viewDidMoveToWindow()
    #expect(invalidations == afterBacking + 1)
    #expect(NSApp === applicationBefore)
  }
}
