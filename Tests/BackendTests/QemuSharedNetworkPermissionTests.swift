// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu
import Testing

@Suite struct QemuSharedNetworkPermissionTests {
  @Test func permissionFactoryRequiresIndependentVerifiedRuntimeAndWindowsShape() throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/mvo-no-permission-catalog-\(UUID().uuidString)",
      isDirectory: true)
    var c = VMConfiguration(
      name: "Permission descriptor fixture", guest: .windows11,
      backend: .qemuHVF, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.sharedNetworkConfigurationPermission(for: c, projectRoot: root)
    }
    c.guest = .linux
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.sharedNetworkConfigurationPermission(for: c, projectRoot: root)
    }
    c.guest = .windows11
    c.backend = .appleVz
    #expect(throws: VMError.self) {
      try QemuRegisteredCatalog.sharedNetworkConfigurationPermission(for: c, projectRoot: root)
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }
  @Test func nativeReviewedSharedPermissionBindsExactBaselineOnlyWhenExplicitlyRequested() throws {
    guard ProcessInfo.processInfo.environment["MVO_VERIFY_SHARED_NETWORK_PERMISSION"] == "1" else {
      return
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let c = VMConfiguration(
      name: "Read-only native catalog permission", guest: .windows11,
      backend: .qemuHVF, memoryBytes: 4 << 30, diskBytes: 64 << 30)
    let value = try QemuRegisteredCatalog.sharedNetworkConfigurationPermission(
      for: c, projectRoot: root)
    #expect(value.configuration == c && value.allowsSharedConfiguration(c))
    var stale = c
    stale.cpuCount += 1
    #expect(!value.allowsSharedConfiguration(stale))
    stale = c
    stale.id = UUID()
    #expect(!value.allowsSharedConfiguration(stale))
  }
}
