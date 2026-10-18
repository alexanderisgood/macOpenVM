// SPDX-License-Identifier: Apache-2.0
import AppKit
import Qemu
import Testing

@testable import MacOpenVMApp

@MainActor private final class PendingCaptureWindow: NSWindow {
  var controlledKey = true
  override var isKeyWindow: Bool { controlledKey }
  override var isOnActiveSpace: Bool { true }
}

@Suite struct GuestPendingKeyboardCaptureTests {
  private func identity() -> GuestPendingKeyboardCapture.Identity {
    .init(connection: UUID(), frameEpoch: UUID(), attempt: UUID(), policyGeneration: UUID())
  }

  @Test func verifiedCapturePreservesModifierAndKeyOrderOnce() {
    var pending = GuestPendingKeyboardCapture()
    let token = identity()
    let strokes = [
      RFBKeyStroke(0xffe3, down: true), RFBKeyStroke(0x61, down: true),
      RFBKeyStroke(0x61, down: false), RFBKeyStroke(0xffe3, down: false),
    ]
    pending.begin(token)
    for stroke in strokes { #expect(pending.append(stroke, for: token, foreground: true) == true) }
    #expect(pending.finish(token, verified: true, foreground: true) == strokes)
    #expect(pending.finish(token, verified: true, foreground: true).isEmpty)
  }

  @Test func nativeBurstRetainsThousandCharacterPairsUntilCaptureVerified() {
    var pending = GuestPendingKeyboardCapture()
    let token = identity()
    var expected = [RFBKeyStroke(0xffe1, down: true)]
    for index in 0..<1000 {
      let symbol = UInt32(0x61 + index % 26)
      expected += [RFBKeyStroke(symbol, down: true), RFBKeyStroke(symbol, down: false)]
    }
    expected.append(RFBKeyStroke(0xffe1, down: false))
    pending.begin(token)
    for stroke in expected { #expect(pending.append(stroke, for: token, foreground: true) == true) }
    #expect(pending.finish(token, verified: true, foreground: true) == expected)
    #expect(pending.finish(token, verified: true, foreground: true).isEmpty)
  }

  @Test func changedIdentityCannotReplayEarlierInput() {
    let token = identity()
    let mismatches: [GuestPendingKeyboardCapture.Identity] = [
      .init(
        connection: UUID(), frameEpoch: token.frameEpoch, attempt: token.attempt,
        policyGeneration: token.policyGeneration),
      .init(
        connection: token.connection, frameEpoch: UUID(), attempt: token.attempt,
        policyGeneration: token.policyGeneration),
      .init(
        connection: token.connection, frameEpoch: token.frameEpoch, attempt: UUID(),
        policyGeneration: token.policyGeneration),
      .init(
        connection: token.connection, frameEpoch: token.frameEpoch, attempt: token.attempt,
        policyGeneration: UUID()),
    ]
    for mismatch in mismatches {
      var pending = GuestPendingKeyboardCapture()
      pending.begin(token)
      #expect(pending.append(RFBKeyStroke(0x61, down: true), for: token, foreground: true) == true)
      #expect(pending.finish(mismatch, verified: true, foreground: true).isEmpty)
      #expect(pending.finish(token, verified: true, foreground: true).isEmpty)
    }
  }

  @Test func failedVerificationOrFocusLossDiscardsInput() {
    for result in [(false, true), (true, false)] {
      var pending = GuestPendingKeyboardCapture()
      let token = identity()
      pending.begin(token)
      #expect(pending.append(RFBKeyStroke(0x61, down: true), for: token, foreground: true) == true)
      #expect(pending.finish(token, verified: result.0, foreground: result.1).isEmpty)
      #expect(pending.finish(token, verified: true, foreground: true).isEmpty)
    }
  }

  @Test func overflowDropsWholeTransactionIncludingHeldModifier() {
    var pending = GuestPendingKeyboardCapture(limit: 2)
    let token = identity()
    pending.begin(token)
    #expect(pending.append(RFBKeyStroke(0xffe3, down: true), for: token, foreground: true) == true)
    #expect(pending.append(RFBKeyStroke(0x61, down: true), for: token, foreground: true) == true)
    #expect(pending.append(RFBKeyStroke(0x61, down: false), for: token, foreground: true) == false)
    #expect(pending.finish(token, verified: true, foreground: true).isEmpty)
  }

  @Test func newCaptureAndExplicitCancellationDiscardEarlierKeys() {
    var pending = GuestPendingKeyboardCapture()
    let first = identity()
    let next = identity()
    pending.begin(first)
    #expect(pending.append(RFBKeyStroke(0x61, down: true), for: first, foreground: true) == true)
    pending.begin(next)
    #expect(pending.finish(next, verified: true, foreground: true).isEmpty)
    pending.begin(next)
    #expect(pending.append(RFBKeyStroke(0x62, down: true), for: next, foreground: true) == true)
    pending.cancel()
    #expect(pending.finish(next, verified: true, foreground: true).isEmpty)
  }

  @Test func backgroundOrStaleAppendCancelsTransaction() {
    let token = identity()
    for foreground in [false, true] {
      var pending = GuestPendingKeyboardCapture()
      pending.begin(token)
      #expect(pending.append(RFBKeyStroke(0x61, down: true), for: token, foreground: true) == true)
      #expect(
        pending.append(
          RFBKeyStroke(0x62, down: true),
          for: foreground ? identity() : token, foreground: foreground) == false)
      #expect(pending.finish(token, verified: true, foreground: true).isEmpty)
    }
  }

  @Test @MainActor func pendingViewKeepsKeyPairAcrossFrameRefreshAndCapture() throws {
    _ = NSApplication.shared
    let window = PendingCaptureWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
      styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView()
    view.hostPointerCapture = GuestHostPointerCapture()
    view.setHostCursor = { _ in }
    view.associateHostPointer = { _ in .success }
    view.warpHostPointer = { _ in .success }
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    #expect(window.isKeyWindow && window.firstResponder === view)
    defer { window.contentView = nil }
    var delivered: [RFBKeyStroke] = []
    view.onKey = { delivered.append(.init($0, down: $1)) }
    view.capturePending = true
    view.keyDown(with: try keyEvent(.keyDown))
    // SwiftUI assigns captured=false on every frame while verification is pending.
    view.captured = false
    view.captured = true
    view.capturePending = false
    view.keyUp(with: try keyEvent(.keyUp))
    #expect(delivered == [RFBKeyStroke(0x61, down: true), RFBKeyStroke(0x61, down: false)])
  }

  @Test @MainActor func cancelledPendingViewDoesNotKeepHeldKey() throws {
    _ = NSApplication.shared
    let window = PendingCaptureWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
      styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = RfbGuestView()
    view.hostPointerCapture = GuestHostPointerCapture()
    view.setHostCursor = { _ in }
    view.associateHostPointer = { _ in .success }
    view.warpHostPointer = { _ in .success }
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    #expect(window.isKeyWindow && window.firstResponder === view)
    defer { window.contentView = nil }
    var delivered: [RFBKeyStroke] = []
    view.onKey = { delivered.append(.init($0, down: $1)) }
    view.capturePending = true
    view.keyDown(with: try keyEvent(.keyDown))
    view.capturePending = false
    view.captured = true
    view.keyUp(with: try keyEvent(.keyUp))
    #expect(delivered == [RFBKeyStroke(0x61, down: true)])
  }

  private func keyEvent(_ type: NSEvent.EventType) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
        isARepeat: false, keyCode: 0))
  }
}
