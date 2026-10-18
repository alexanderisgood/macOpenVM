// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu

/// Presentation of completed admission stages, never authority to launch a worker.
/// Callers classify a failure at its stage; arbitrary error descriptions are not displayed here.
enum WindowsLaunchReadiness: Equatable, Sendable {
  case notChecked, checking, ready
  case unavailable(Reason)

  enum Reason: CaseIterable, Equatable, Sendable {
    case unsupportedHost, unsupportedConfiguration
    case bundledWorkerUnavailable, reviewedRuntimeUnavailable
    case incompatibleSupportDisc, sharedRuntimeUnavailable

    var title: String {
      switch self {
      case .unsupportedHost: "This Mac cannot run this Windows runtime"
      case .unsupportedConfiguration: "This Windows VM needs a different runtime"
      case .bundledWorkerUnavailable: "The app’s Windows helper is unavailable"
      case .reviewedRuntimeUnavailable: "The matching Windows runtime is unavailable"
      case .incompatibleSupportDisc: "The driver disc does not match this runtime"
      case .sharedRuntimeUnavailable: "Shared Windows networking is unavailable"
      }
    }

    var message: String {
      switch self {
      case .unsupportedHost:
        "This development runtime requires Apple silicon and macOS \(WindowsLaunchReadiness.minimumHostMajorVersion) or later. Use a Mac that meets these requirements."
      case .unsupportedConfiguration:
        "Choose a Windows 11 ARM64 VM that uses the reviewed QEMU runtime and EFI boot. This check does not convert an existing VM."
      case .bundledWorkerUnavailable:
        "Open a complete verified macOpenVM app bundle. Its Windows helper is missing, changed or could not be verified."
      case .reviewedRuntimeUnavailable:
        "Restore the matching reviewed runtime files for this development build, then check again. The app cannot substitute an unverified runtime."
      case .incompatibleSupportDisc:
        "Detach the driver disc and check again. Use the matching disc supplied for this Windows runtime; detaching does not remove installed Windows drivers."
      case .sharedRuntimeUnavailable:
        "Choose Disconnected in Networking Settings, or restore the matching runtime for shared networking, then check again."
      }
    }
  }

  static let minimumHostMajorVersion = ReviewedQemuCreationResources.minimumHostMajorVersion

  static func supportsHost(architecture: GuestArchitecture, majorVersion: Int) -> Bool {
    architecture == .arm64 && majorVersion >= minimumHostMajorVersion
  }

  var isChecking: Bool { self == .checking }

  var title: String {
    switch self {
    case .notChecked: "Windows startup requirements have not been checked"
    case .checking: "Checking Windows startup requirements…"
    case .ready: "Windows runtime checks passed"
    case .unavailable(let reason): reason.title
    }
  }

  var message: String {
    switch self {
    case .notChecked:
      "Check this Mac, the app’s Windows helper and the selected runtime before starting."
    case .checking:
      "Checking this Mac, the app’s Windows helper and the runtime selected for this VM."
    case .ready:
      "The app’s Windows helper and matching runtime passed their checks. Windows installation and driver health have not been verified by these checks."
    case .unavailable(let reason): reason.message
    }
  }

  var symbol: String {
    switch self {
    case .notChecked: "info.circle"
    case .checking: "hourglass"
    case .ready: "checkmark.circle"
    case .unavailable: "exclamationmark.triangle"
    }
  }
}

/// Bind an asynchronous result to all selected facts that chose its admission recipe.
/// A matching result still grants no VM ownership and does not replace start-time revalidation.
struct WindowsLaunchReadinessRequest: Equatable, Sendable {
  enum Profile: CaseIterable, Equatable, Sendable {
    case basic, twoDimensional, accelerated, producerCapture
  }

  let generation: UUID
  let configurationURL: URL
  let configuration: VMConfiguration
  let profile: Profile

  init(
    generation: UUID = UUID(), configurationURL: URL,
    configuration: VMConfiguration, profile: Profile
  ) {
    self.generation = generation
    self.configurationURL = configurationURL
    self.configuration = configuration
    self.profile = profile
  }

  func canApply(
    generation currentGeneration: UUID?, selectedURL: URL?, configuration current: VMConfiguration?,
    profile currentProfile: Profile, hasOwnedWindowsRuntime: Bool
  ) -> Bool {
    !hasOwnedWindowsRuntime && generation == currentGeneration
      && configurationURL == selectedURL && configuration == current && profile == currentProfile
  }
}
