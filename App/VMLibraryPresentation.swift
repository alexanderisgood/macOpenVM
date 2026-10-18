// SPDX-License-Identifier: Apache-2.0
import Foundation
import VMCore

/// Presentation facts only. A saved entry does not establish runtime ownership or availability.
enum VMLibraryPresentation {
  enum RowStatus: Equatable {
    case saved, selected, working, needsAttention, needsRecovery
    case active(VMState)

    var title: String {
      switch self {
      case .saved: "Saved VM"
      case .selected: "Selected VM"
      case .working: "Operation in progress"
      case .needsAttention: "Needs attention"
      case .needsRecovery: "Needs recovery"
      case .active(let state):
        switch state {
        case .starting: "Starting"
        case .running: "Running"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .resuming: "Resuming"
        case .stopping: "Shutdown pending"
        case .saving: "Saving"
        case .restoring: "Restoring"
        case .stopped, .suspended, .failed: "Active VM"
        }
      }
    }

    var symbol: String {
      switch self {
      case .saved: "desktopcomputer"
      case .selected: "checkmark.circle"
      case .working: "hourglass"
      case .needsAttention, .needsRecovery: "exclamationmark.triangle"
      case .active(let state):
        state == .paused ? "pause.circle" : state == .running ? "play.circle" : "hourglass"
      }
    }

    var guidance: String? {
      switch self {
      case .saved, .selected: nil
      case .working: "Wait for the current operation before opening another VM."
      case .needsAttention: "Close the library to review this VM’s last operation."
      case .needsRecovery:
        "Close the library to review recovery status. Preserve this VM’s files."
      case .active: "Close the library to return to this VM."
      }
    }
  }

  enum EmptyState: Equatable {
    case noSavedVMs, noMatches, unavailable

    var title: String {
      switch self {
      case .noSavedVMs: "No saved VMs yet"
      case .noMatches: "No matching VMs"
      case .unavailable: "The saved VM list needs attention"
      }
    }

    var message: String {
      switch self {
      case .noSavedVMs: "Create a VM or open an existing VM to add it to the library."
      case .noMatches: "Try another name or folder, or clear the search to show all saved VMs."
      case .unavailable:
        "Reload the library or use Open VM to select an existing VM. Your VM files are preserved."
      }
    }
  }

  static func hasSearch(_ query: String) -> Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func emptyState(
    savedCount: Int, matchingCount: Int, hasLibraryError: Bool
  ) -> EmptyState? {
    guard matchingCount == 0 else { return nil }
    if savedCount == 0 { return hasLibraryError ? .unavailable : .noSavedVMs }
    return .noMatches
  }

  static func rowStatus(
    entryURL: URL, entryID: UUID, selectedURL: URL?, selectedID: UUID?,
    state: VMState, isActive: Bool, isBusy: Bool, needsRecovery: Bool
  ) -> RowStatus {
    guard entryURL == selectedURL, entryID == selectedID else { return .saved }
    if needsRecovery { return .needsRecovery }
    if state == .failed { return .needsAttention }
    if isActive { return .active(state) }
    return isBusy ? .working : .selected
  }
}
