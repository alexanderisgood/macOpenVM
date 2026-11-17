// SPDX-License-Identifier: LicenseRef-macOpenVM-Source-1.0
import Foundation

/// Exact bootstrap discs built from pinned packages. Profile selection is made
/// by the host runtime, never by guest-controlled metadata or an INF search.
public enum QemuGuestToolsCatalog {
  public enum Profile: String, CaseIterable, Sendable { case basic, display, accelerated }

  public static func images(
    for profile: Profile, projectRoot: URL, bundleResources: URL? = Bundle.main.resourceURL
  ) throws -> [ReviewedQemuSupportImage] {
    let bytes: UInt64
    let hash: String
    switch profile {
    case .basic:
      bytes = 921_600
      hash = "b96d6fe3781c5727fbf75e1cae488ad7a446a45c201ff634372fef6936edce86"
    case .display:
      bytes = 927_744
      hash = "28d6b781ce5d295b5de582d407621c427087db0e01e185a424610b4031ada3c4"
    case .accelerated:
      bytes = 7_061_504
      hash = "6b32a19afb81f0a5ae6cceed27a624ec85d36a39c39186c1143ecc028a1d4cb2"
    }
    let directories =
      [bundleResources?.appendingPathComponent("GuestTools")]
      .compactMap { $0 } + [projectRoot.appendingPathComponent("build/guest-tools")]
    return try directories.map {
      try ReviewedQemuSupportImage(
        url: $0.appendingPathComponent(profile.rawValue + ".iso"), byteCount: bytes, sha256: hash)
    }
  }

  public static func preparedImage(for profile: Profile, projectRoot: URL) throws
    -> ReviewedQemuSupportImage
  {
    for image in try images(for: profile, projectRoot: projectRoot) {
      if (try? image.verify()) != nil { return image }
    }
    throw registeredQemuFailure()
  }
}
