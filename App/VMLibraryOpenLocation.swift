// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import VMCore
import VMStorage

@MainActor final class VMLibraryOpeningRequest {
  weak var owner: NSWindow?
  let context: VMLibraryPickerContext
  let selectionGeneration: UUID
  init(owner: NSWindow, context: VMLibraryPickerContext, selectionGeneration: UUID) {
    self.owner = owner
    self.context = context
    self.selectionGeneration = selectionGeneration
  }
}

struct DesktopVMSelectionObservation {
  let configuration: VMConfiguration
  let report: VMInspectionReport
}

@MainActor protocol DesktopVMSelectionInspecting {
  func inspect(at registration: URL, expectedID: UUID?) async throws
    -> DesktopVMSelectionObservation
}

struct NativeDesktopVMSelectionInspector: DesktopVMSelectionInspecting {
  private let files = VMFiles()
  func inspect(at registration: URL, expectedID: UUID?) async throws
    -> DesktopVMSelectionObservation
  {
    let configuration = try await VMLibrarySelection.readForEditing(
      at: registration, expectedID: expectedID, files: files)
    let report = await VMInspection(files: files).inspect(
      at: registration.deletingLastPathComponent())
    let current = try await VMLibrarySelection.readForEditing(
      at: registration, expectedID: configuration.id, files: files)
    guard current == configuration else {
      throw VMError(
        .staleOperation, "The saved VM settings changed while it was being opened.",
        recovery: "Open the VM again to review its current settings.")
    }
    return DesktopVMSelectionObservation(configuration: configuration, report: report)
  }
}

/// Resolves the user's explicit location choice. Ordinary selection still validates
/// the registration and identity; a directory/type observation confers no authority.
enum VMLibraryOpenLocation {
  static func validateLocation(_ url: URL) throws {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .percentEncodedPath.removingPercentEncoding,
      decoded == url.path || (url.hasDirectoryPath && decoded == url.path + "/"),
      url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
      !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw invalidLocation() }
  }

  static func registration(for url: URL, kind: VMFileStatus.Kind) throws -> URL {
    try validateLocation(url)
    let registration: URL
    switch kind {
    case .directory: registration = url.appendingPathComponent("configuration.json")
    case .regular: registration = url
    default: throw invalidLocation()
    }
    try VMLibraryEntry.validateURL(registration)
    return registration
  }

  private static func invalidLocation() -> VMError {
    VMError(
      .invalidConfiguration, "Choose the VM folder or its configuration.json file.",
      recovery:
        "Open the VM’s saved folder. Shortcuts and symbolic links are not selected automatically.")
  }
}
