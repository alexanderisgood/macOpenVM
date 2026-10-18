// SPDX-License-Identifier: Apache-2.0
import AppKit
import AppleVz
import BackendAPI
import Foundation
import Qemu
import UniformTypeIdentifiers
import VMCore

/// A weak UI request only. It confers no writer, executable or runtime permission.
@MainActor final class DesktopCreationAdmission {
  weak var owner: NSWindow?
  let context: VMLibraryPickerContext
  let selectionGeneration: UUID
  let nonce: UUID
  let resources: ReviewedQemuCreationResources?
  let catalog: Bool
  let errorGeneration: UUID
  var preparationGeneration: UUID?

  init(
    owner: NSWindow, context: VMLibraryPickerContext, selectionGeneration: UUID,
    nonce: UUID, resources: ReviewedQemuCreationResources?, catalog: Bool,
    errorGeneration: UUID
  ) {
    self.owner = owner
    self.context = context
    self.selectionGeneration = selectionGeneration
    self.nonce = nonce
    self.resources = resources
    self.catalog = catalog
    self.errorGeneration = errorGeneration
  }
}

/// These adapters keep the existing ordinary Core transactions and real platforms.
@MainActor protocol DesktopVMCreating {
  func createLinux(_ configuration: VMConfiguration, at destination: URL) async throws
  func createWindows(
    _ configuration: VMConfiguration, at destination: URL,
    resources: ReviewedQemuCreationResources
  ) async throws
}

struct NativeDesktopVMCreation: DesktopVMCreating {
  func createLinux(_ configuration: VMConfiguration, at destination: URL) async throws {
    try await VMCreation().create(
      configuration, at: destination, platform: AppleCreationPlatform())
  }
  func createWindows(
    _ configuration: VMConfiguration, at destination: URL,
    resources: ReviewedQemuCreationResources
  ) async throws {
    try await VMCreation().create(
      configuration, at: destination, platform: QemuCreationPlatform(resources: resources))
  }
}

@MainActor protocol DesktopWindowsCreationPreparing {
  func resources() async throws -> ReviewedQemuCreationResources
}

struct NativeDesktopWindowsCreationPreparation: DesktopWindowsCreationPreparing {
  func resources() async throws -> ReviewedQemuCreationResources {
    try await Task.detached {
      let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
      let reviewed = try QemuRegisteredCatalog.offlineEvaluation(projectRoot: project)
      try reviewed.verify()
      return reviewed.creation
    }.value
  }
}

/// Plain selections only; generic saved-VM installation/support pickers are separate.
@MainActor protocol DesktopCreationLocationPresenting {
  func select(folder: Bool, title: String?, on owner: NSWindow?) async -> URL?
}

struct NativeDesktopCreationLocationPresentation: DesktopCreationLocationPresenting {
  func select(folder: Bool, title: String?, on owner: NSWindow?) async -> URL? {
    guard let owner, owner.attachedSheet == nil else { return nil }
    let panel = NSOpenPanel()
    panel.title =
      title ?? (folder ? "Choose a folder for the new VM" : "Choose your ARM64 Linux ISO")
    panel.canChooseFiles = !folder
    panel.canChooseDirectories = folder
    panel.canCreateDirectories = folder
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data] }
    return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
      panel.beginSheetModal(for: owner) { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
