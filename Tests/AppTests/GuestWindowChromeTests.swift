// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct GuestWindowChromeTests {
  @Test func replacingAViewCannotRestoreChromeUnderItsReplacement() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 90, width: 700, height: 500),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = .fullScreenPrimary
    let container = NSView()
    window.contentView = container
    let old = GuestWindowChromeView()
    container.addSubview(old)
    let replacement = GuestWindowChromeView()
    container.addSubview(replacement)
    old.restoreControls()
    #expect(window.collectionBehavior == .fullScreenPrimary)
    #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
    replacement.restoreControls()
    #expect(window.collectionBehavior == .fullScreenPrimary)
    #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
  }

  @Test func restoresButtonsAndOnlyOwnedFullscreenFlags() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 90, width: 700, height: 500),
      styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
    window.standardWindowButton(.closeButton)?.isHidden = true
    let chrome = GuestWindowChromeView()
    window.contentView = chrome
    chrome.hideControls()
    #expect(window.collectionBehavior == [.fullScreenPrimary, .canJoinAllSpaces])
    #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
    window.collectionBehavior.insert(.stationary)
    chrome.restoreControls()
    #expect(window.collectionBehavior == [.fullScreenPrimary, .canJoinAllSpaces, .stationary])
    #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
    #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
    chrome.restoreControls()
    #expect(window.collectionBehavior.contains(.stationary))
  }
}
