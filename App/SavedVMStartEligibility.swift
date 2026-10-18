// SPDX-License-Identifier: Apache-2.0
import BackendAPI

/// UI eligibility only. Actual start still obtains ordinary runtime/writer admission
/// and strictly validates the reread registration; an eligible flag grants no authority.
enum SavedVMStartEligibility {
  static func permits(_ configuration: VMConfiguration, host: HostResources = .current) -> Bool {
    do {
      try ConfigurationValidator.validate(configuration, host: host)
      return true
    } catch { return false }
  }
}
