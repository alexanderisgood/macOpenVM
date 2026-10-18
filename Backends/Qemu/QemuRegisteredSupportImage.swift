// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Independent caller/code-reviewed public data image, never decoded from a VM
/// path or minted by hashing a user selection. This is not driver-health,
/// executable-signature, enrollment, autorun or released setup-tool authority.
public struct ReviewedQemuSupportImage: Equatable, Sendable {
  public let url: URL
  public let byteCount: UInt64
  public let sha256: String

  public init(url: URL, byteCount: UInt64, sha256: String) throws {
    guard QemuCreationLocalPath.isValid(url, maximumBytes: 4096),
      (512...134_217_728).contains(byteCount), byteCount % 512 == 0,
      registeredDigestShape(sha256)
    else { throw registeredQemuFailure() }
    self.url = url
    self.byteCount = byteCount
    self.sha256 = sha256
  }
  public func verify() throws {
    // The existing pinned reader checks no-follow ancestry/regular type,
    // owner/link/write modes, exact length/hash and stable named/FD identity.
    _ = try RegisteredQemuIO.reviewed(url, count: byteCount, sha256: sha256)
  }
}
