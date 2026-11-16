// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import Qemu

struct QemuGuestToolsCatalogTests {
  private let root = URL(fileURLWithPath: "/private/tmp/macopenvm-tools-fixture")

  private func configuration(_ path: String) -> VMConfiguration {
    var c = VMConfiguration(
      name: "Tools", guest: .windows11, backend: .qemuHVF, cpuCount: 2,
      memoryBytes: 4 << 30, diskBytes: 64 << 30)
    c.supportMedia = path
    return c
  }

  private func resources(_ profile: QemuGuestToolsCatalog.Profile, path: String) throws
    -> ReviewedQemuLaunchResources
  {
    let c = configuration(path)
    switch profile {
    case .basic: return try QemuRegisteredCatalog.registeredEvaluation(for: c, projectRoot: root)
    case .display:
      return try QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(for: c, projectRoot: root)
    case .accelerated:
      return try QemuRegisteredCatalog.acceleratedDisplayEvaluation(for: c, projectRoot: root)
    }
  }

  @Test(arguments: QemuGuestToolsCatalog.Profile.allCases)
  func matchingProfileIsSelected(_ profile: QemuGuestToolsCatalog.Profile) throws {
    let image = try #require(
      QemuGuestToolsCatalog.images(for: profile, projectRoot: root, bundleResources: nil).first)
    let selected = try resources(profile, path: image.url.path)
    #expect(selected.supportImage == image)
    #expect(selected.supportsShared == false)
  }

  @Test(arguments: QemuGuestToolsCatalog.Profile.allCases, QemuGuestToolsCatalog.Profile.allCases)
  func wrongGraphicsProfileIsRefused(
    _ host: QemuGuestToolsCatalog.Profile, _ tools: QemuGuestToolsCatalog.Profile
  ) throws {
    guard host != tools else { return }
    let image = try #require(
      QemuGuestToolsCatalog.images(for: tools, projectRoot: root, bundleResources: nil).first)
    #expect(throws: (any Error).self) { try resources(host, path: image.url.path) }
  }

  @Test(arguments: QemuGuestToolsCatalog.Profile.allCases)
  func lookalikeAndMissingImagesAreNotAdmitted(_ profile: QemuGuestToolsCatalog.Profile) throws {
    let image = try #require(
      QemuGuestToolsCatalog.images(for: profile, projectRoot: root, bundleResources: nil).first)
    #expect(throws: (any Error).self) { try resources(profile, path: image.url.path + ".copy") }
    #expect(throws: (any Error).self) { try image.verify() }
  }
}
