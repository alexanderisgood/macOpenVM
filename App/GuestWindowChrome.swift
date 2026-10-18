// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Guest windows use the real menus instead of controls over guest pixels.
/// Restore this window's original button visibility when its display detaches.
struct GuestWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> GuestWindowChromeView { GuestWindowChromeView() }
  func updateNSView(_ view: GuestWindowChromeView, context: Context) { view.hideControls() }
  static func dismantleNSView(_ view: GuestWindowChromeView, coordinator: ()) {
    view.restoreControls()
  }
}

@MainActor final class GuestWindowChromeView: NSView {
  private weak var owner: NSWindow?
  private let token = UUID()
  private static var owners: [ObjectIdentifier: ChromeOwner] = [:]
  @MainActor private final class ChromeOwner {
    weak var window: NSWindow?
    let buttons: [(NSWindow.ButtonType, Bool)]
    var leases: Set<UUID> = []
    init(_ window: NSWindow) {
      self.window = window
      buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
        kind in window.standardWindowButton(kind).map { (kind, $0.isHidden) }
      }
    }
    func apply() {
      guard let window else { return }
      for (kind, _) in buttons { window.standardWindowButton(kind)?.isHidden = true }
    }
    func restore() {
      if let window {
        for (kind, hidden) in buttons { window.standardWindowButton(kind)?.isHidden = hidden }
      }
    }
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== owner { restoreControls() }
    super.viewWillMove(toWindow: newWindow)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    hideControls()
  }
  func hideControls() {
    guard let window else { return }
    if owner !== window {
      restoreControls()
      owner = window
    }
    Self.owners = Self.owners.filter { $0.value.window != nil }
    let identity = ObjectIdentifier(window)
    let record = Self.owners[identity] ?? ChromeOwner(window)
    Self.owners[identity] = record
    record.leases.insert(token)
    record.apply()
  }
  func restoreControls() {
    if let owner {
      let identity = ObjectIdentifier(owner)
      if let record = Self.owners[identity] {
        record.leases.remove(token)
        if record.leases.isEmpty {
          record.restore()
          Self.owners.removeValue(forKey: identity)
        } else {
          record.apply()
        }
      }
    }
    owner = nil
  }
}
