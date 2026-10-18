// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import Testing

@testable import MacOpenVMApp

@MainActor private final class DesktopInitializationLibraryPreferences: VMLibraryPreferences {
  private(set) var writes = 0
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { writes += 1 }
}

@MainActor @Suite struct DesktopApplicationInitializationTests {
  @Test func inactivePresentationAndStateChangesDoNotInitializeAnApplication() throws {
    let applicationBefore: NSApplication? = NSApp
    let requireNoApplication =
      ProcessInfo.processInfo.environment["MACOPENVM_TEST_REQUIRE_NO_APPLICATION"] == "1"
    if requireNoApplication {
      try #require(applicationBefore == nil)
    }
    // A running full suite may already own an application. Avoid modifying its
    // presentation; the fresh filtered helper qualifies the absent-app branch.
    guard applicationBefore == nil else {
      #expect(NSApp === applicationBefore)
      print("Desktop application probe: absent-app branch not reached in this process")
      return
    }

    let libraryPreferences = DesktopInitializationLibraryPreferences()
    let graphicsPreferences = MemoryWindowsGraphicsPreferences()
    let session = DesktopSession(
      library: VMLibrary(preferences: libraryPreferences),
      graphicsPreferences: WindowsGraphicsPreferenceStore(preferences: graphicsPreferences))
    try #require(NSApp == nil)
    #expect(session.window == nil && session.configuration == nil && !session.isActive)

    // The real state setter reaches the presentation refresh without a window.
    session.state = .failed
    try #require(NSApp == nil)
    session.refreshFullscreenPresentation()
    try #require(NSApp == nil)
    session.enteringFullscreen()
    try #require(NSApp == nil)
    session.enteredFullscreen()
    try #require(NSApp == nil)
    session.leavingFullscreen()
    try #require(NSApp == nil)
    session.state = .stopped
    try #require(NSApp == nil)

    #expect(!session.fullscreen && !session.isActive && session.backend == nil)
    #expect(!session.isBusy && !session.canStartSelected)
    #expect(!session.canInspectDiskMetadata && !session.canRefreshDiskMetadataUpgrade)
    #expect(!session.canConfirmDiskMetadataUpgrade && session.diskMetadataDraftNonce == nil)
    session.showDiskMetadataUpgrade(draft: session.diskCapacityDraftNonce)
    #expect(!session.showingDiskMetadataUpgrade && session.diskMetadataInspection == nil)
    try #require(NSApp == nil)
    #expect(libraryPreferences.writes == 0)
    #expect(graphicsPreferences.reads == 0 && graphicsPreferences.writes == 0)
    print("Desktop application probe: initial_nil=true, final_nil=\(NSApp == nil)")
  }
}
