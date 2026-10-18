// SPDX-License-Identifier: Apache-2.0
import Foundation

/// In-memory permission to SAVE desired Windows networking after an independent
/// backend capability check. This is neither decodable metadata nor VM launch,
/// networking consent, guest connectivity or driver-health authority.
public struct SharedNetworkConfigurationPermission: Sendable {
  public let configuration: VMConfiguration
  package init(configuration: VMConfiguration) { self.configuration = configuration }

  public func allowsSharedConfiguration(_ current: VMConfiguration) -> Bool {
    configuration == current && current.guest == .windows11 && current.backend == .qemuHVF
      && current.architecture == .arm64 && current.boot == .efi
  }
}
