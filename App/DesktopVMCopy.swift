// SPDX-License-Identifier: Apache-2.0
import AppKit
import AppleVz
import BackendAPI
import Foundation
import VMCore
import VMStorage

@MainActor protocol DesktopVMCopying {
  func copy(from source: URL, to destination: URL, name: String, expected: VMConfiguration)
    async throws -> VMCloneResult
}

struct NativeDesktopVMCopy: DesktopVMCopying {
  func copy(from source: URL, to destination: URL, name: String, expected: VMConfiguration)
    async throws -> VMCloneResult
  {
    try await VMClone().copy(
      from: source, to: destination, name: name, platform: AppleCreationPlatform(),
      expected: expected)
  }
}

/// Presentation results are plain name/folder choices, never writer or runtime authority.
@MainActor protocol DesktopVMCopyPresenting {
  func name(for configuration: VMConfiguration, on owner: NSWindow?) async -> String?
  func parentDirectory(for source: URL, on owner: NSWindow?) async -> URL?
}

struct NativeDesktopVMCopyPresentation: DesktopVMCopyPresenting {
  func name(for configuration: VMConfiguration, on owner: NSWindow?) async -> String? {
    guard let owner, owner.attachedSheet == nil else { return nil }
    var suggestedName = configuration.name
    while suggestedName.utf8.count > 123 { suggestedName.removeLast() }
    let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
    nameField.stringValue = suggestedName + " Copy"
    nameField.placeholderString = "Name for the VM copy"
    nameField.setAccessibilityLabel("Name for the VM copy")
    let alert = NSAlert()
    alert.messageText = "Copy VM · Experimental"
    alert.informativeText =
      "Choose a name for a separate VM with its own disk and identity. The copy starts disconnected. Choose a new folder on the same volume in the next step."
    alert.accessoryView = nameField
    alert.addButton(withTitle: "Choose Folder…")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = nameField
    return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      alert.beginSheetModal(for: owner) { response in
        continuation.resume(
          returning: response == .alertFirstButtonReturn ? nameField.stringValue : nil)
      }
    }
  }

  func parentDirectory(for source: URL, on owner: NSWindow?) async -> URL? {
    guard let owner, owner.attachedSheet == nil else { return nil }
    let panel = NSOpenPanel()
    panel.title = "Choose a folder for the VM copy"
    panel.directoryURL = source.deletingLastPathComponent()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
      panel.beginSheetModal(for: owner) { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
