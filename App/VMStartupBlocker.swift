// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMCore

/// Selection-bound presentation and an additional UI refusal, never runtime custody,
/// recovery authority or proof that a guest has stopped.
struct VMStartupBlocker: Equatable {
  let configuration: VMConfiguration
  let configurationURL: URL
  let intent: RuntimeIntentInspectionStatus

  init?(configuration: VMConfiguration, at url: URL, intent: RuntimeIntentInspectionStatus) {
    switch intent {
    case .unsettled, .invalid, .identityMismatch: break
    default: return nil
    }
    self.configuration = configuration
    configurationURL = url
    self.intent = intent
  }

  func matches(configuration: VMConfiguration?, at url: URL?) -> Bool {
    self.configuration == configuration && configurationURL == url
  }

  var title: String {
    switch intent {
    case .unsettled: "Previous session needs review"
    case .identityMismatch: "Session record does not match this VM"
    default: "Session record needs review"
    }
  }

  var message: String {
    switch intent {
    case .unsettled:
      "The previous session has no confirmed completion and may have been interrupted. Preserve this VM’s files and review recovery before starting again. After recovery, reopen this VM to refresh its status."
    case .identityMismatch:
      "The saved session record belongs to a different VM. Preserve the configuration and session record, and review recovery before starting. After recovery, reopen this VM to refresh its status."
    default:
      "This VM’s saved session record cannot be read safely. Preserve the VM and its record, and review recovery before starting. After recovery, reopen this VM to refresh its status."
    }
  }
}
