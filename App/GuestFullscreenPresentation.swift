// SPDX-License-Identifier: Apache-2.0
import AppKit

/// Own only visibility flags. AppKit retains its fullscreen state and transitions.
struct GuestFullscreenPresentation {
  typealias Options = NSApplication.PresentationOptions
  private static let owned: Options = [
    .hideDock, .autoHideDock, .hideMenuBar, .autoHideMenuBar, .autoHideToolbar,
  ]
  private var saved: Options?
  private var applied = false

  mutating func beginTransition(_ current: Options) {
    // A failed entry may have prepared without ever applying. A fresh native
    // entry starts from its current baseline, not the failed attempt's snapshot.
    if !applied { saved = current.intersection(Self.owned) }
  }

  mutating func prepare(_ current: Options) {
    if saved == nil { saved = current.intersection(Self.owned) }
  }

  mutating func applying(to current: Options) -> Options {
    guard saved != nil else { return current }
    applied = true
    // Keep the native menu policy; toolbar visibility is controlled separately.
    return Self.guestOptions(current)
  }

  /// Also supply these options in AppKit's transition delegate callback. A
  /// post-transition assignment alone can be replaced by the native defaults.
  static func guestOptions(_ proposed: Options) -> Options {
    var result = proposed.subtracting(Self.owned).union(.autoHideDock)
    // In a native Space, AppKit turns omission of this standard option into
    // hideMenuBar/hideDock, even if the system preference is Never. Retaining
    // it lets macOS honor that preference and keeps the normal menu reachable.
    if result.contains(.fullScreen) { result.insert(.autoHideMenuBar) }
    return result
  }

  mutating func suspending(_ current: Options) -> Options {
    guard applied, let saved else { return current }
    var restored = current.subtracting(Self.owned).union(saved)
    if !restored.contains(.fullScreen) || !restored.contains(.autoHideMenuBar) {
      restored.remove(.autoHideToolbar)
    }
    // Another presentation owner may have added kiosk flags while fullscreen.
    // Do not produce an invalid AppKit combination or remove another owner's flags.
    let requiresDock: Options = [
      .disableProcessSwitching, .disableForceQuit, .disableSessionTermination,
      .disableMenuBarTransparency,
    ]
    if !restored.intersection(requiresDock).isEmpty,
      restored.intersection([.hideDock, .autoHideDock]).isEmpty
    {
      return current
    }
    applied = false
    return restored
  }

  mutating func finish(_ current: Options) -> Options {
    defer {
      saved = nil
      applied = false
    }
    return suspending(current)
  }
}
