// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu

/// Explicit choices for one selected VM. These values are
/// not VM metadata, resource admission or evidence of an installed guest driver.
struct WindowsGraphicsSettings: Equatable, Sendable {
  enum Mode: CaseIterable, Hashable, Identifiable, Sendable {
    case basic, accelerated
    var id: Self { self }
  }

  enum RefreshRate: CaseIterable, Hashable, Identifiable, Sendable {
    case hz60, hz120
    var id: Self { self }
    var reviewed: ReviewedQemuAcceleratedDisplay.RefreshRate {
      self == .hz120 ? .hz120 : .hz60
    }
  }

  var mode: Mode = .basic
  var initialWidth = 1920
  var initialHeight = 1080
  var refreshRate: RefreshRate = .hz60

  /// Validate only declarative values. A stored refresh request says nothing
  /// about the capabilities of the display currently containing the VM window.
  func validatedPreference() throws -> Self {
    guard mode == .accelerated else { return Self() }
    _ = try boundedInitialDisplay()
    return self
  }

  /// Basic display ignores accelerated fields and returns conservative defaults.
  /// The caller must obtain this capability from the current display again at start.
  func validated(canUse120: Bool) throws -> Self {
    let result = try validatedPreference()
    guard result.refreshRate != .hz120 || canUse120 else {
      throw VMError(
        .unsupported, "The selected Mac display does not provide 120 Hz.",
        recovery: "Choose 60 Hz, or move the VM window to a display that supports 120 Hz.")
    }
    return result
  }

  func reviewedInitialDisplay(hostMaximumFramesPerSecond: Int?) throws -> ReviewedQemu2DDisplay? {
    guard mode == .accelerated else { return nil }
    _ = try validated(canUse120: (hostMaximumFramesPerSecond ?? 0) >= 120)
    return try boundedInitialDisplay()
  }

  /// Construct only the existing bounded device recipe; the independently reviewed
  /// catalog, loader closure and worker still require their ordinary admission.
  func reviewedAcceleratedDisplay(hostMaximumFramesPerSecond: Int?) throws
    -> ReviewedQemuAcceleratedDisplay?
  {
    guard
      let display = try reviewedInitialDisplay(
        hostMaximumFramesPerSecond: hostMaximumFramesPerSecond)
    else { return nil }
    return try ReviewedQemuAcceleratedDisplay(
      initialPixels: display.initialPixels, separateFirmware: true, hostWindow: .fourGiB,
      refreshRate: refreshRate.reviewed)
  }

  private func boundedInitialDisplay() throws -> ReviewedQemu2DDisplay {
    do {
      return try ReviewedQemu2DDisplay(
        initialPixels: PixelSize(width: initialWidth, height: initialHeight))
    } catch { throw Self.invalidDimensions() }
  }

  fileprivate static func invalidDimensions() -> VMError {
    VMError(
      .invalidConfiguration, "Enter whole pixel dimensions without separators.",
      recovery:
        "Width must be 320–8,192 pixels, height 200–8,192 pixels, and the total must be at most 16,777,216 pixels."
    )
  }
}

/// Preserve exactly what was entered until validation succeeds. Integer text-field
/// formatters can otherwise accept or normalize an incomplete or fractional value.
struct WindowsGraphicsSettingsDraft: Equatable, Sendable {
  var settings: WindowsGraphicsSettings
  var widthText: String
  var heightText: String

  init(settings: WindowsGraphicsSettings = WindowsGraphicsSettings()) {
    self.settings = settings
    widthText = String(settings.initialWidth)
    heightText = String(settings.initialHeight)
  }

  func prepared(canUse120: Bool) throws -> WindowsGraphicsSettings {
    guard settings.mode == .accelerated else { return WindowsGraphicsSettings() }
    guard let width = Self.wholePixels(widthText), let height = Self.wholePixels(heightText) else {
      throw WindowsGraphicsSettings.invalidDimensions()
    }
    var result = settings
    result.initialWidth = width
    result.initialHeight = height
    return try result.validated(canUse120: canUse120)
  }

  private static func wholePixels(_ text: String) -> Int? {
    let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int(digits)
  }
}
