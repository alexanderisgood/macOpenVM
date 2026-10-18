// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import SwiftUI
import VMCore
import VMStorage

/// A point-in-time presentation binding, never a writer lease or launch permit.
struct VMReviewContext: Equatable, Sendable {
  let configurationURL: URL
  let configuration: VMConfiguration
  let owner: ObjectIdentifier
  let generation: UUID
}

protocol VMReviewInspecting: Sendable {
  func inspect(_ context: VMReviewContext) async throws -> VMInspectionReport
}

/// Read the exact normal registration before and after Core's read-only inspection.
/// Neither metadata read, report nor context reconstructs runtime/storage authority.
struct NativeVMReviewInspector: VMReviewInspecting {
  private let host: HostResources
  private let files = VMFiles()
  init(host: HostResources = .current) { self.host = host }

  func inspect(_ context: VMReviewContext) async throws -> VMInspectionReport {
    try await requireConfiguration(context)
    let report = await VMInspection(files: files).inspect(
      at: context.configurationURL.deletingLastPathComponent(), host: host)
    try await requireConfiguration(context)
    return report
  }

  private func requireConfiguration(_ context: VMReviewContext) async throws {
    let current = try await VMLibrarySelection.readForEditing(
      at: context.configurationURL, expectedID: context.configuration.id, files: files)
    guard current == context.configuration else {
      throw VMError(
        .staleOperation, "The saved configuration changed during review.",
        recovery: "Close the review and reopen the VM from its saved location.")
    }
  }
}

@MainActor final class VMReviewController: ObservableObject {
  enum Failure: String {
    case selectionChanged =
      "This review no longer matches the selected VM. Close it and reopen the VM before reviewing again."
    case unavailable =
      "The structural review could not be completed. Preserve the VM’s files, check its location and try Refresh."
  }
  @Published private(set) var context: VMReviewContext?
  @Published private(set) var presentation: VMReviewPresentation?
  @Published private(set) var isLoading = false
  @Published private(set) var error: Failure?
  private let inspector: any VMReviewInspecting
  private var request: UUID?

  init(inspector: any VMReviewInspecting = NativeVMReviewInspector()) {
    self.inspector = inspector
  }

  func open(_ context: VMReviewContext) {
    invalidate()
    self.context = context
  }

  func invalidate() {
    request = nil
    context = nil
    presentation = nil
    isLoading = false
    error = nil
  }

  /// Each refresh has its own token, even for a value-equal selection and context.
  /// The owner supplies fresh admission both before and after every suspension.
  func refresh(
    context: VMReviewContext,
    accepting: @MainActor (VMReviewContext) -> Bool
  ) async {
    guard self.context == context else { return }
    guard accepting(context) else {
      invalidate()
      return
    }
    let token = UUID()
    request = token
    isLoading = true
    presentation = nil
    error = nil
    do {
      let report = try await inspector.inspect(context)
      guard request == token, self.context == context else { return }
      guard !Task.isCancelled, accepting(context) else {
        invalidate()
        return
      }
      presentation = VMReviewPresentation(report)
      isLoading = false
      request = nil
    } catch {
      guard request == token, self.context == context else { return }
      guard !Task.isCancelled, accepting(context) else {
        invalidate()
        return
      }
      self.error = (error as? VMError)?.code == .staleOperation ? .selectionChanged : .unavailable
      isLoading = false
      request = nil
    }
  }
}

/// Known bounded classifications only. Inspector exception/message strings are not UI text.
struct VMReviewPresentation: Equatable {
  struct Finding: Equatable, Identifiable {
    let id: String
    let title: String
    let guidance: String
  }
  struct File: Equatable, Identifiable {
    let id: String
    let title: String
    let status: String
  }
  static let scope =
    "This reviews files and recorded metadata at one point in time. Guest health, installed drivers, a clean shutdown and disk consistency remain unverified. This result does not authorize starting or changing the VM."
  let summary: String
  let writer: String
  let intent: String
  let findings: [Finding]
  let files: [File]
  let hasUnrecognizedFacts: Bool

  init(_ report: VMInspectionReport) {
    var unknown = report.schemaVersion != 1 || report.findings.count > 64 || report.files.count > 64
    var codes = Set<DiagnosticReport.VM.Finding>()
    for finding in report.findings.prefix(64) {
      if let code = DiagnosticReport.VM.Finding(rawValue: finding.code) {
        codes.insert(code)
      } else {
        unknown = true
      }
    }
    findings = DiagnosticReport.VM.Finding.allCases.filter { codes.contains($0) }.map(Self.finding)
    var entries: [DiagnosticReport.VM.FileRole: File] = [:]
    for file in report.files.prefix(64) {
      guard let role = DiagnosticReport.VM.FileRole(rawValue: file.role), entries[role] == nil
      else {
        unknown = true
        continue
      }
      entries[role] = File(
        id: role.rawValue, title: Self.fileTitle(role), status: Self.fileStatus(file.status.kind))
    }
    files = DiagnosticReport.VM.FileRole.allCases.compactMap { entries[$0] }
    hasUnrecognizedFacts = unknown
    if unknown {
      summary = "Some structural checks need further review"
    } else {
      summary =
        switch report.status {
        case .unavailable: "The VM’s files could not be checked"
        case .incomplete: "The VM’s registration is incomplete"
        case .needsReview: "Structural findings need review"
        case .busy: "A cooperating session holds this VM"
        case .filesMatchConfiguration: "Files matched the saved configuration at this check"
        }
    }
    writer =
      switch report.writer {
      case .missing: "No writer record found"
      case .available: "Cooperating writer lock available at this check"
      case .held: "Cooperating writer lock held"
      case .unavailable: "Cooperating ownership could not be checked"
      }
    intent =
      switch report.intent {
      case .unavailable: "Not checked"
      case .notRecorded: "No runtime intent recorded"
      case .unsettled: "Unsettled — preserve this session’s files"
      case .settled: "Settled metadata recorded; guest shutdown is unverified"
      case .identityMismatch: "Recorded intent belongs to another VM"
      case .invalid: "Recorded runtime intent needs review"
      }
  }

  private static func finding(_ code: DiagnosticReport.VM.Finding) -> Finding {
    let text: (String, String) =
      switch code {
      case .directoryUnavailable:
        (
          "VM folder unavailable",
          "Locate the original owned VM folder and check its permissions. Preserve its files; this review does not change access permissions."
        )
      case .diskGrowthPending:
        (
          "Disk expansion is unfinished",
          "Preserve the disk, configuration and growth records. Completion requires an explicit validated storage workflow; this sheet does not finish or clear it."
        )
      case .diskGrowthInvalid:
        (
          "Disk expansion record needs review",
          "Preserve every growth record and sidecar. Do not delete records, shrink the disk or retry expansion to hide an uncertain result."
        )
      case .runtimeIntentUnsettled:
        (
          "Runtime ownership is unsettled",
          "Preserve the original session and its files. A free writer lock does not authorize another start or metadata change. Review the owning session before proceeding."
        )
      case .runtimeIntentInvalid:
        (
          "Runtime ownership record needs review",
          "Preserve the intent and configuration. Do not clear or replace the record to allow another start."
        )
      case .runtimeReview:
        (
          "Previous runtime needs review",
          "No clean guest shutdown has been established. Preserve the disk and review guest recovery before the next start; this sheet performs no repair."
        )
      case .registrationMissing:
        (
          "Registration is missing",
          "Preserve partial files and locate the original configuration. Do not create a replacement VM in this folder."
        )
      case .configurationUnreadable:
        (
          "Configuration could not be read",
          "Preserve the configuration and backups. Select the VM’s original configuration from Open VM; an unknown schema is not upgraded here."
        )
      case .settingsReview:
        (
          "Saved settings need review",
          "Check this Mac’s capabilities and the saved CPU, memory and device settings before starting. This sheet does not save new settings."
        )
      case .runtimeIntentIdentityMismatch:
        (
          "Runtime identity does not match",
          "Preserve both configuration and runtime intent. Reopen the original VM; neither identity is replaced here."
        )
      case .diskGrowthIdentityMismatch:
        (
          "Disk expansion belongs to another VM",
          "Preserve the original disk, configuration and growth records. Do not transplant or replace identity records."
        )
      case .diskGrowthCompletionMismatch:
        (
          "Disk expansion completion does not match",
          "Preserve the disk and registration together. Review the complete growth record before any write; do not resize or truncate the disk."
        )
      case .unsafeDiskPath:
        (
          "Saved disk location is unsafe",
          "Preserve the current configuration and locate the original disk. The unsafe path was not inspected or followed."
        )
      case .diskSizeMismatch:
        (
          "Disk length differs from its settings",
          "Preserve the disk and any growth records. Do not shrink, truncate or change saved capacity to hide a mismatch."
        )
      case .identityUnavailable:
        (
          "Original machine identity is unavailable",
          "Locate the original native machine identity and preserve the VM. Creating a replacement identity can change the guest’s machine."
        )
      case .backendPlatformUnverified:
        (
          "Backend platform remains unverified",
          "This structural review does not check this backend’s firmware, TPM or driver state. Use the separate launch prerequisites and guest checks."
        )
      case .unsafeMediaPath:
        (
          "Saved media location is unsafe",
          "Locate the original boot or tools image and review its saved location. The unsafe path was not inspected or followed."
        )
      case .mediaUnavailable:
        (
          "Boot or tools media is unavailable",
          "Locate the original boot or tools image. For an attached installation image, use Machine → Attach Installation Image… to choose it again before starting."
        )
      case .supportMediaUnavailable:
        (
          "Tools image could not be checked",
          "Locate the correct reviewed tools or Windows driver disc, then use this VM’s tools-image controls to attach it. This review does not install or verify guest drivers."
        )
      case .writerProbeUnavailable:
        (
          "Cooperating ownership could not be checked",
          "Preserve the existing lock and permissions. Resolve the owning session explicitly; do not delete a lock to force another start."
        )
      case .unsafeDisk:
        (
          "Disk file needs review",
          "Preserve the original disk. It may be missing, empty, aliased or have unsafe permissions. This sheet does not replace it or alter permissions."
        )
      case .unsafeEFI:
        (
          "EFI variables need review",
          "Preserve the original firmware variables and VM identity. Do not generate replacement firmware state to bypass this finding."
        )
      }
    return Finding(id: code.rawValue, title: text.0, guidance: text.1)
  }

  private static func fileTitle(_ role: DiagnosticReport.VM.FileRole) -> String {
    switch role {
    case .directory: "VM folder"
    case .configuration: "Configuration"
    case .disk: "Disk"
    case .identity: "Machine identity"
    case .efi: "EFI variables"
    case .runtime: "Runtime history"
    case .media: "Installation image"
    case .kernel: "Kernel"
    case .initrd: "Initial RAM disk"
    case .runtimeIntent: "Runtime ownership record"
    case .diskGrowthIntent: "Disk expansion record"
    case .supportMedia: "Tools image"
    }
  }

  private static func fileStatus(_ kind: VMFileStatus.Kind) -> String {
    switch kind {
    case .missing: "Missing"
    case .regular: "Regular file observed"
    case .directory: "Folder observed"
    case .symlink: "Symbolic link observed"
    case .other: "Other file type observed"
    case .unreadable: "Could not be read"
    }
  }
}
