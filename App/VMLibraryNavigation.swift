// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI

enum VMLibraryNavigation: Equatable {
  case newWindows, newLinux, open
}

/// A picker result belongs to the owner and draft/selection that opened it.
/// Equal VM names or UUIDs alone cannot identify a replacement selection.
struct VMLibraryPickerContext: Equatable {
  let owner: ObjectIdentifier
  let configurationURL: URL?
  let configuration: VMConfiguration?
  let creationGeneration: UUID
}

/// Keep sheet eligibility and display-dependent controls tied to the real owner.
/// Sheet attachment can follow the SwiftUI content's initial window callback.
final class DesktopWindowObservation {
  enum Change: Sendable { case sheet, screen }
  private let tokens: [NSObjectProtocol]

  @MainActor init(owner: NSWindow, onChange: @escaping @MainActor @Sendable (Change) -> Void) {
    tokens = [
      NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
      NSWindow.didChangeScreenNotification,
    ].map { name in
      let change: Change = name == NSWindow.didChangeScreenNotification ? .screen : .sheet
      return NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) {
        _ in
        // AppKit announces presentation before attachedSheet is populated.
        // Sample on the next actor turn, after attachment/detachment settles.
        Task { @MainActor in
          await Task.yield()
          onChange(change)
        }
      }
    }
  }

  deinit {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
  }
}
