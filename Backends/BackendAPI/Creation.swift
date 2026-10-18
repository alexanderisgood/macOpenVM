// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Created filesystem entries only; empty directories establish no guest or device health.
public struct CreatedPlatformIdentity: Equatable, Sendable {
  public let files: [String]
  public let emptyPrivateDirectories: [String]

  public init(files: [String], emptyPrivateDirectories: [String] = []) {
    self.files = files
    self.emptyPrivateDirectories = emptyPrivateDirectories
  }
}

/// Platform work required before a new VM can be atomically registered.
@MainActor public protocol VMCreationPlatform {
  var backend: BackendID { get }
  /// Reject unavailable hardware, entitlements, guests and native resource limits before file creation.
  func validateHost(for configuration: VMConfiguration) throws
  /// Create new contained identity for the actual registration, without replacing existing entries.
  func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
}
