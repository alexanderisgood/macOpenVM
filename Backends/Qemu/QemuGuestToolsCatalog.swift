// SPDX-License-Identifier: Apache-2.0
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
      hash = "ee29b3ee84a07c4c2a11b395397a474d0d59679da111d7b6d36a04d9eba90281"
    case .display:
      bytes = 921_600
      hash = "cce95cb18e0359e481104dc0f74ada85b19ede60df20a56645aa5d4a1322a2bf"
    case .accelerated:
      bytes = 7_055_360
      hash = "830cc06e072b4b0bd09314b8aca4355ef93676718166265c950af600c4a46ce6"
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
