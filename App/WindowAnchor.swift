// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Track the scene's actual owning window independently of focus and activation.
struct WindowAnchor: NSViewRepresentable {
  let onWindow: @MainActor (NSWindow?) -> Void
  func makeNSView(context: Context) -> AnchorView { AnchorView(onWindow: onWindow) }
  func updateNSView(_ view: AnchorView, context: Context) {}
  @MainActor final class AnchorView: NSView {
    let onWindow: @MainActor (NSWindow?) -> Void
    init(onWindow: @escaping @MainActor (NSWindow?) -> Void) {
      self.onWindow = onWindow
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindow(window)
    }
  }
}
