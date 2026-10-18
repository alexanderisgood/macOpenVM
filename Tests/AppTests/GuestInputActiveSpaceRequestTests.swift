// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

/// Hidden windows override only collection behavior storage. These fixtures
/// never activate, order, move a Space, acquire input or connect to a guest.
@MainActor @Suite(.serialized) struct GuestInputActiveSpaceRequestTests {
  @Test func restoresOnlyItsAddedBitAndPreservesOtherChanges() {
    let window = fixture()
    let original = window.collectionBehavior
    let request = GuestInputActiveSpaceRequest(window: window)
    let began = request.begin()
    #expect(began && window.collectionBehavior == original.union(.moveToActiveSpace))
    window.collectionBehavior.insert(.fullScreenDisallowsTiling)
    request.finish()
    #expect(window.collectionBehavior == original.union(.fullScreenDisallowsTiling))
    request.finish()
    #expect(window.collectionBehavior == original.union(.fullScreenDisallowsTiling))
  }

  @Test func oldRequestCannotRestoreUnderAnOverlappingReplacement() {
    let window = fixture()
    let original = window.collectionBehavior
    let old = GuestInputActiveSpaceRequest(window: window)
    let replacement = GuestInputActiveSpaceRequest(window: window)
    let firstBegan = old.begin()
    let secondBegan = replacement.begin()
    #expect(firstBegan && secondBegan)
    old.finish()
    old.finish()
    #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    replacement.finish()
    #expect(window.collectionBehavior == original)
  }

  @Test func preservesExistingMoveAndAllSpacesPolicies() {
    let window = fixture()
    window.collectionBehavior.insert(.moveToActiveSpace)
    let originalMove = window.collectionBehavior
    let move = GuestInputActiveSpaceRequest(window: window)
    let moveBegan = move.begin()
    #expect(moveBegan)
    move.finish()
    #expect(window.collectionBehavior == originalMove)

    window.collectionBehavior.remove(.moveToActiveSpace)
    window.collectionBehavior.insert(.canJoinAllSpaces)
    let originalAllSpaces = window.collectionBehavior
    let allSpaces = GuestInputActiveSpaceRequest(window: window)
    let allSpacesBegan = allSpaces.begin()
    #expect(!allSpacesBegan)
    allSpaces.finish()
    #expect(window.collectionBehavior == originalAllSpaces)
  }

  @Test func passiveOrNativeFullscreenRequestsNeverChangeBehavior() {
    let window = fixture()
    let original = window.collectionBehavior
    let passive = GuestInputActiveSpaceRequest(window: window)
    let passiveBegan = passive.begin(allowMove: false)
    #expect(!passiveBegan && window.collectionBehavior == original)
    passive.finish()
    window.controlledFullscreen = true
    let fullscreen = GuestInputActiveSpaceRequest(window: window)
    let fullscreenBegan = fullscreen.begin()
    #expect(!fullscreenBegan && window.collectionBehavior == original)
    fullscreen.finish()
    #expect(window.collectionBehavior == original)
  }

  @Test func synchronousCancellationDuringTheSetterRestoresImmediately() {
    let window = fixture()
    let original = window.collectionBehavior
    let request = GuestInputActiveSpaceRequest(window: window)
    window.behaviorChanged = { [weak window, weak request] in
      window?.behaviorChanged = nil
      request?.finish()
    }
    let began = request.begin()
    #expect(!began && window.collectionBehavior == original)
    request.finish()
    #expect(window.collectionBehavior == original)
  }

  @Test func replacementStartedInsideTheSetterSurvivesOldCleanup() {
    let window = fixture()
    let original = window.collectionBehavior
    let old = GuestInputActiveSpaceRequest(window: window)
    var replacement: GuestInputActiveSpaceRequest?
    window.behaviorChanged = { [weak window, weak old] in
      guard let window else { return }
      window.behaviorChanged = nil
      let next = GuestInputActiveSpaceRequest(window: window)
      replacement = next
      next.begin()
      old?.finish()
    }
    let began = old.begin()
    #expect(!began && window.collectionBehavior.contains(.moveToActiveSpace))
    old.finish()
    #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    replacement?.finish()
    #expect(window.collectionBehavior == original)
  }

  @Test(arguments: ["release", "sheet", "detach", "replacement", "fullscreen"])
  func sessionEndsPlacementOnEveryLifecycleBoundary(boundary: String) throws {
    let window = fixture()
    let original = window.collectionBehavior
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    let view = RfbGuestView(frame: container.bounds)
    let capture = GuestHostPointerCapture()
    view.hostPointerCapture = capture
    container.addSubview(view)
    window.contentView = container
    defer { window.contentView = nil }
    let session = RfbLabSession(hostPointerCapture: capture)
    _ = try #require(session.beginInputActivationForValidation(view, moveToActiveSpace: true))
    #expect(window.collectionBehavior == original.union(.moveToActiveSpace))
    switch boundary {
    case "release": session.releaseInput()
    case "sheet":
      window.controlledSheet = NSWindow(
        contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
      session.focusChanged()
    case "detach": session.detach(view)
    case "replacement":
      let replacement = RfbGuestView(frame: container.bounds)
      replacement.hostPointerCapture = capture
      container.addSubview(replacement)
      session.attach(replacement)
    case "fullscreen": session.prepareFullscreen()
    default: Issue.record("Unknown lifecycle fixture")
    }
    #expect(window.collectionBehavior == original)
    #expect(!session.captured && !view.captured && !view.capturePending)
  }

  @Test func sessionCancellationInsideTheSetterCannotLeavePlacementEnabled() throws {
    let window = fixture()
    let original = window.collectionBehavior
    let view = RfbGuestView()
    let capture = GuestHostPointerCapture()
    view.hostPointerCapture = capture
    window.contentView = view
    defer { window.contentView = nil }
    let session = RfbLabSession(hostPointerCapture: capture)
    window.behaviorChanged = { [weak window, weak session] in
      window?.behaviorChanged = nil
      session?.releaseInput()
    }
    let attempt = try #require(
      session.beginInputActivationForValidation(view, moveToActiveSpace: true))
    #expect(!session.hasInputActivationForValidation(attempt))
    #expect(window.collectionBehavior == original && !session.captured && !view.captured)
  }

  @Test func deadlineRestoresPlacementWithoutGrantingCaptureOrRevivingTheRequest() throws {
    let window = fixture()
    let original = window.collectionBehavior
    let capture = GuestHostPointerCapture()
    let view = RfbGuestView()
    view.hostPointerCapture = capture
    window.contentView = view
    defer { window.contentView = nil }
    let session = RfbLabSession(hostPointerCapture: capture)
    let attempt = try #require(
      session.beginInputActivationForValidation(view, moveToActiveSpace: true))
    #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    session.refreshInputActivationForValidation(at: .now + .seconds(3))
    #expect(!session.hasInputActivationForValidation(attempt))
    #expect(window.collectionBehavior == original)
    #expect(!session.captured && !view.captured && !view.capturePending)
    session.refreshInputActivationForValidation(at: .now)
    #expect(window.collectionBehavior == original && !session.captured)
  }

  private func fixture() -> PlacementWindow {
    _ = NSApplication.shared
    let window = PlacementWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .titled,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.managed, .fullScreenPrimary, .participatesInCycle]
    return window
  }

  private final class PlacementWindow: NSWindow {
    var controlledBehavior: CollectionBehavior = []
    var controlledFullscreen = false
    var controlledSheet: NSWindow?
    var behaviorChanged: (@MainActor () -> Void)?
    override var isKeyWindow: Bool { false }
    override var isOnActiveSpace: Bool { false }
    override var attachedSheet: NSWindow? { controlledSheet }
    override var collectionBehavior: CollectionBehavior {
      get { controlledBehavior }
      set {
        controlledBehavior = newValue
        behaviorChanged?()
      }
    }
    override var styleMask: StyleMask {
      get { controlledFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
      set { super.styleMask = newValue }
    }
  }
}
