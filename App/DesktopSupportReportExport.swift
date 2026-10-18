// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import UniformTypeIdentifiers
import VMCore

/// Weak UI/context custody only; never a VM lease, file permission or export result.
@MainActor final class DesktopSupportReportExportAdmission {
  weak var owner: NSWindow?
  let context: VMLibraryPickerContext
  let selectionGeneration: UUID
  let errorGeneration: UUID
  var preparationGeneration: UUID?
  var waitingForDestination = true

  init(
    owner: NSWindow, context: VMLibraryPickerContext, selectionGeneration: UUID,
    errorGeneration: UUID
  ) {
    self.owner = owner
    self.context = context
    self.selectionGeneration = selectionGeneration
    self.errorGeneration = errorGeneration
  }
}

/// Only destination choice and asynchronous delivery are substitutable in fixtures.
/// The native implementation retains the ordinary panel and Core export semantics.
@MainActor protocol DesktopSupportReportExporting {
  func chooseDestination(
    on owner: NSWindow, willPresent: () -> Bool,
    selected: @escaping @MainActor (URL?) -> Void)
  func makeAndExport(directory: URL?, host: DiagnosticHostFacts, to destination: URL) async throws
}

/// Fieldless construction creates no application, panel, catalog or native resource.
@MainActor struct NativeDesktopSupportReportExport: DesktopSupportReportExporting {
  func chooseDestination(
    on owner: NSWindow, willPresent: () -> Bool,
    selected: @escaping @MainActor (URL?) -> Void
  ) {
    let panel = NSSavePanel()
    panel.title = "Export Support Report"
    panel.message =
      "Save host capabilities and structural VM status. Review the file before sharing."
    panel.nameFieldStringValue = "macOpenVM-support.json"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    // The request already owns preparation; revalidate after panel construction.
    guard willPresent() else { return }
    panel.beginSheetModal(for: owner) { response in
      selected(response == .OK ? panel.url : nil)
    }
  }

  func makeAndExport(directory: URL?, host: DiagnosticHostFacts, to destination: URL) async throws {
    let report = await SupportDiagnostics.make(directory: directory, host: host)
    try await SupportDiagnostics.export(report, to: destination)
  }
}
