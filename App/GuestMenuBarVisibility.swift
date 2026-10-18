// SPDX-License-Identifier: Apache-2.0
import AppKit

/// A reversible public AppKit visibility override for the active VM owner.
/// Does not change system preferences or act while another app owns focus.
@MainActor struct GuestMenuBarVisibility {
  private let visible: @MainActor () -> Bool
  private let setVisible: @MainActor (Bool) -> Void
  private var saved: Bool?
  private var applied = false
  init(
    visible: @escaping @MainActor () -> Bool = { NSMenu.menuBarVisible() },
    setVisible: @escaping @MainActor (Bool) -> Void = { NSMenu.setMenuBarVisible($0) }
  ) {
    self.visible = visible
    self.setVisible = setVisible
  }
  mutating func prepare() {
    if saved == nil { saved = visible() }
  }
  mutating func show(activeOwner: Bool) {
    guard activeOwner, saved != nil else { return }
    if !visible() { setVisible(true) }
    applied = true
  }
  mutating func suspend(canChangeVisibility: Bool) {
    guard applied, let saved else { return }
    if canChangeVisibility, visible() != saved { setVisible(saved) }
    applied = false
  }
  mutating func finish(canChangeVisibility: Bool) {
    suspend(canChangeVisibility: canChangeVisibility)
    saved = nil
  }
}
