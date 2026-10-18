// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Qemu
import VMCore
import VMStorage

/// A weak UI request binding only; never a writer lease or runtime permission.
@MainActor final class DesktopStoppedSettingsAdmission {
  weak var owner: NSWindow?
  let context: VMLibraryPickerContext
  let generation: UUID
  init(owner: NSWindow, context: VMLibraryPickerContext, generation: UUID) {
    self.owner = owner
    self.context = context
    self.generation = generation
  }
}

@MainActor protocol DesktopHardwareSettingsUpdating {
  func update(in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64)
    async throws -> VMConfiguration
}

struct NativeDesktopHardwareSettings: DesktopHardwareSettingsUpdating {
  func update(in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64)
    async throws -> VMConfiguration
  {
    try await HardwareSettings().update(
      in: directory, cpuCount: cpuCount, memoryBytes: memoryBytes, expected: expected
    ).configuration
  }
}

@MainActor protocol DesktopNetworkSettingsUpdating {
  func update(
    in directory: URL, expected: VMConfiguration, mode: NetworkMode,
    sharedPermission: SharedNetworkConfigurationPermission?
  ) async throws -> VMConfiguration
}

struct NativeDesktopNetworkSettings: DesktopNetworkSettingsUpdating {
  func update(
    in directory: URL, expected: VMConfiguration, mode: NetworkMode,
    sharedPermission: SharedNetworkConfigurationPermission?
  ) async throws -> VMConfiguration {
    try await NetworkSettings().update(
      in: directory, mode: mode, expected: expected, sharedPermission: sharedPermission
    ).configuration
  }
}

@MainActor protocol DesktopSharedNetworkPreparing {
  func permission(for configuration: VMConfiguration) async throws
    -> SharedNetworkConfigurationPermission
}

struct NativeDesktopSharedNetworkPreparation: DesktopSharedNetworkPreparing {
  func permission(for configuration: VMConfiguration) async throws
    -> SharedNetworkConfigurationPermission
  {
    try await Task.detached(priority: .utility) {
      let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
      return try QemuRegisteredCatalog.sharedNetworkConfigurationPermission(
        for: configuration, projectRoot: project)
    }.value
  }
}

/// Ordinary Core media changes retain their existing writer and exact-backup rules.
@MainActor protocol DesktopMediaSettingsUpdating {
  func update(
    in directory: URL, expected: VMConfiguration, selected: URL?, support: Bool
  ) async throws -> VMConfiguration
}

struct NativeDesktopMediaSettings: DesktopMediaSettingsUpdating {
  func update(
    in directory: URL, expected: VMConfiguration, selected: URL?, support: Bool
  ) async throws -> VMConfiguration {
    let media = InstallationMedia()
    return try await support
      ? media.updateSupport(in: directory, to: selected, expected: expected).configuration
      : media.update(in: directory, to: selected, expected: expected).configuration
  }
}

@MainActor protocol DesktopWindowsDriverDiscPreparing {
  func imageURL(accelerated: Bool, displayExperiment: Bool) async throws -> URL
}

struct NativeDesktopWindowsDriverDiscPreparation: DesktopWindowsDriverDiscPreparing {
  func imageURL(accelerated: Bool, displayExperiment: Bool) async throws -> URL {
    try await Task.detached(priority: .utility) {
      let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
      let reviewed =
        try accelerated
        ? QemuRegisteredCatalog.acceleratedDisplaySupportImage(projectRoot: project)
        : displayExperiment
          ? QemuRegisteredCatalog.displayDriverSupportImage(projectRoot: project)
          : QemuRegisteredCatalog.networkDriverSupportImage(projectRoot: project)
      try reviewed.verify()
      return reviewed.url
    }.value
  }
}
