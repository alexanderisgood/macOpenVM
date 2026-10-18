// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import MacOpenVMApp

@MainActor private final class NavigationPreferences: VMLibraryPreferences {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws {}
}

@MainActor private final class NavigationWindow: NSWindow {
  var controlledSheet: NSWindow?
  override var attachedSheet: NSWindow? { controlledSheet }
}

/// Hidden owner fixtures exercise the actual session without showing a picker,
/// creating files, starting a guest or changing application focus.
@MainActor @Suite(.serialized) struct VMLibraryNavigationTests {
  @Test func mainWindowCanBeginLinuxCreationWithoutASelectedVM() {
    let (session, owner) = fixture()
    defer {
      session.window = nil
      owner.contentView = nil
    }
    #expect(session.canRequestLibraryNavigation)
    session.requestLibraryNavigation(.newLinux)
    #expect(session.creating && !session.preparing && session.configuration == nil)
    #expect(!session.canRequestLibraryNavigation)
  }

  @Test func anUnpresentedLibraryCannotQueueAnActionThatWaitsForeverForDismissal() {
    let (session, owner) = fixture()
    defer {
      session.window = nil
      owner.contentView = nil
    }
    session.showLibrary()
    #expect(session.showingLibrary && !session.canRequestLibraryNavigation)
    session.requestLibraryNavigation(.newLinux)
    #expect(session.showingLibrary && !session.creating && !session.isBusy)
    session.showingLibrary = false
    session.libraryDismissed()
    #expect(!session.isBusy && !session.creating)
  }

  @Test func libraryCreationWaitsForDetachmentAndRunsOnlyOnce() async {
    let (session, owner) = fixture()
    defer {
      session.window = nil
      owner.contentView = nil
    }
    let sheet = attachLibrary(session, owner: owner)
    #expect(session.canRequestLibraryNavigation)
    session.requestLibraryNavigation(.newLinux)
    #expect(!session.showingLibrary && session.isBusy && !session.creating)
    session.requestLibraryNavigation(.open)
    owner.controlledSheet = nil
    session.registerLibraryWindow(nil)
    session.libraryDismissed()
    await finishDeferral(session)
    #expect(session.creating && !session.preparing)
    session.creating = false
    session.libraryDismissed()
    await finishDeferral(session)
    #expect(!session.creating && !session.isBusy && session.configuration == nil)
    withExtendedLifetime(sheet) {}
  }

  @Test func presentationAnnouncementBeforeAttachmentRefreshesNavigation() async {
    let (session, owner) = fixture()
    defer { session.window = nil }
    session.showLibrary()
    let sheet = makeWindow()
    session.registerLibraryWindow(sheet)
    #expect(!session.canRequestLibraryNavigation)
    NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: owner)
    owner.controlledSheet = sheet
    for _ in 0..<100 {
      if session.canRequestLibraryNavigation { break }
      await Task.yield()
    }
    #expect(session.canRequestLibraryNavigation)
    owner.controlledSheet = nil
    session.registerLibraryWindow(nil)
    withExtendedLifetime(sheet) {}
  }

  @Test func changedOwnerDiscardsDeferredCreation() async {
    let (session, owner) = fixture()
    let sheet = attachLibrary(session, owner: owner)
    session.requestLibraryNavigation(.newLinux)
    owner.controlledSheet = nil
    let replacement = makeWindow()
    session.window = replacement
    session.libraryDismissed()
    await finishDeferral(session)
    #expect(!session.creating && !session.isBusy)
    session.window = nil
    withExtendedLifetime((owner, replacement, sheet)) {}
  }

  @Test func anotherOperationOrRemainingSheetDiscardsDeferredCreation() async {
    for remainingSheet in [false, true] {
      let (session, owner) = fixture()
      let sheet = attachLibrary(session, owner: owner)
      session.requestLibraryNavigation(.newLinux)
      if !remainingSheet {
        owner.controlledSheet = nil
        session.editingHardware = true
      }
      session.libraryDismissed()
      await finishDeferral(session)
      #expect(!session.creating)
      session.editingHardware = false
      owner.controlledSheet = nil
      #expect(!session.isBusy)
      session.window = nil
      withExtendedLifetime((owner, sheet)) {}
    }
  }

  @Test func unrelatedSheetsAndMissingOwnersRejectNewOrOpen() {
    let (session, owner) = fixture()
    defer {
      session.window = nil
      owner.contentView = nil
    }
    let unrelated = makeWindow()
    owner.controlledSheet = unrelated
    for destination: VMLibraryNavigation in [.newLinux, .newWindows, .open] {
      #expect(!session.canRequestLibraryNavigation)
      session.requestLibraryNavigation(destination)
      #expect(!session.creating && !session.preparing && !session.isBusy)
    }
    owner.controlledSheet = nil
    session.window = nil
    #expect(!session.canRequestLibraryNavigation)
    session.requestLibraryNavigation(.newLinux)
    #expect(!session.creating)
  }

  @Test func aFailedAttemptWithoutOwnedResourcesDoesNotTrapNavigation() {
    let (session, owner) = fixture()
    defer {
      session.window = nil
      owner.contentView = nil
    }
    session.state = .failed
    #expect(!session.needsOwnershipRecovery && !session.isBusy)
    #expect(session.canRequestLibraryNavigation)
    session.requestLibraryNavigation(.newLinux)
    #expect(session.creating)
  }

  private func fixture() -> (DesktopSession, NavigationWindow) {
    _ = NSApplication.shared
    let owner = makeWindow()
    let session = DesktopSession(library: VMLibrary(preferences: NavigationPreferences()))
    session.window = owner
    return (session, owner)
  }

  private func makeWindow() -> NavigationWindow {
    let window = NavigationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: .titled, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  private func attachLibrary(_ session: DesktopSession, owner: NavigationWindow) -> NSWindow {
    session.showLibrary()
    let sheet = makeWindow()
    owner.controlledSheet = sheet
    session.registerLibraryWindow(sheet)
    return sheet
  }

  private func finishDeferral(_ session: DesktopSession) async {
    for _ in 0..<20 {
      await Task.yield()
      if !session.preparing { return }
    }
  }
}
