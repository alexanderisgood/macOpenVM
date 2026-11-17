// SPDX-License-Identifier: LicenseRef-macOpenVM-Source-1.0
import AppKit

/// Reveals the menu for the active fullscreen VM. AppKit owns the menu policy
/// once the fullscreen window loses focus or exits.
@MainActor struct GuestMenuBarVisibility {
  private let visible: @MainActor () -> Bool
  private let setVisible: @MainActor (Bool) -> Void
  init(
    visible: @escaping @MainActor () -> Bool = { NSMenu.menuBarVisible() },
    setVisible: @escaping @MainActor (Bool) -> Void = { NSMenu.setMenuBarVisible($0) }
  ) {
    self.visible = visible
    self.setVisible = setVisible
  }
  func show(activeOwner: Bool) {
    // The visibility getter can report a transient hidden state during a
    // Space transition. Restoring it as a policy can hide the desktop menu.
    if activeOwner, !visible() { setVisible(true) }
  }
}
