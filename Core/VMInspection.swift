// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

public struct InspectionFile: Encodable, Equatable, Sendable {
  public let role: String
  public let status: VMFileStatus
}

public struct InspectionFinding: Encodable, Equatable, Sendable {
  public let code: String
  public let message: String
}

public struct VMInspectionReport: Encodable, Sendable {
  public enum Status: String, Encodable, Sendable {
    case unavailable, incomplete, needsReview, busy, filesMatchConfiguration
  }
  public let schemaVersion: Int
  public let status: Status
  public let writer: WriterStatus
  public let history: RuntimeHistoryStatus
  public let intent: RuntimeIntentInspectionStatus
  public let files: [InspectionFile]
  public let findings: [InspectionFinding]
  public let limitations: [String]
}

/// Fixed classifications only; never exports VM/session identifiers or grants authority.
public enum RuntimeIntentInspectionStatus: String, Encodable, Sendable {
  case unavailable, notRecorded, unsettled, settled, identityMismatch, invalid
}

/// Read-only structural inspection. It never opens a backend, creates a lock or repairs data.
public struct VMInspection: Sendable {
  private let files: VMFiles
  public init(files: VMFiles = VMFiles()) { self.files = files }

  public func inspect(at directory: URL, host: HostResources = .current) async -> VMInspectionReport
  {
    let limitations = [
      "Point-in-time file checks; cooperating lock availability does not prove a stopped guest.",
      "Intent classification is read-only; settled metadata does not prove guest shutdown or disk consistency.",
      "Native identity/EFI semantics, guest filesystem, installed data and crash consistency are not verified.",
      "POSIX permission bits only; ACLs, ancestor permissions and same-user replacement races remain open.",
      "No repairs, permission changes, identity replacement or guest actions are performed.",
    ]
    var entries: [InspectionFile] = []
    var findings: [InspectionFinding] = []
    var history = RuntimeHistoryStatus.notRecorded
    var intentStatus = RuntimeIntentInspectionStatus.unavailable
    var intentRecord: RuntimeIntent?
    var growthRecord: DiskGrowthIntent?
    func report(_ status: VMInspectionReport.Status, writer: WriterStatus) -> VMInspectionReport {
      VMInspectionReport(
        schemaVersion: 1, status: status, writer: writer, history: history, intent: intentStatus,
        files: entries,
        findings: findings,
        limitations: limitations)
    }
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.utf8.count <= 4096,
      !directory.path.contains("\0")
    else { return report(.unavailable, writer: .unavailable) }
    let directoryStatus = await files.status(at: directory)
    entries.append(InspectionFile(role: "directory", status: directoryStatus))
    guard directoryStatus.kind == .directory, directoryStatus.ownedByCurrentUser == true,
      directoryStatus.otherWriteBits == false
    else {
      findings.append(
        InspectionFinding(
          code: "directory-unavailable",
          message: "Choose an owned VM directory with safe write permissions."))
      return report(.unavailable, writer: .unavailable)
    }
    let writer = await files.writerStatus(in: directory)
    let growthFile = await files.status(
      at: directory.appendingPathComponent(DiskGrowthIntent.filename))
    entries.append(InspectionFile(role: "disk-growth-intent", status: growthFile))
    if growthFile.kind != .missing {
      do {
        guard let growth = try await files.readDiskGrowthIntent(in: directory) else {
          throw VMError(
            .corruptMetadata, "Growth intent changed during inspection.",
            recovery: "Preserve files.")
        }
        growthRecord = growth
        if growth.state == .pending {
          findings.append(
            InspectionFinding(
              code: "disk-growth-pending",
              message:
                "Disk growth is unfinished. Preserve its disk and metadata; ordinary VM writers are blocked until explicit validated completion."
            ))
        }
      } catch {
        findings.append(
          InspectionFinding(
            code: "disk-growth-invalid",
            message:
              "Disk growth intent is unsafe, unreadable, changed or unsupported. Preserve all files; no recovery or clearing is automatic."
          ))
      }
    }
    let intentFile = await files.status(
      at: directory.appendingPathComponent(RuntimeIntent.filename))
    entries.append(InspectionFile(role: "runtime-intent", status: intentFile))
    if intentFile.kind == .missing {
      intentStatus = .notRecorded
    } else {
      do {
        guard let record = try await files.readRuntimeIntent(in: directory) else {
          throw VMError(
            .corruptMetadata, "Intent changed during inspection.", recovery: "Preserve files.")
        }
        intentRecord = record
        intentStatus = record.state == .unsettled ? .unsettled : .settled
        if record.state == .unsettled {
          findings.append(
            InspectionFinding(
              code: "runtime-intent-unsettled",
              message:
                "Runtime ownership is unsettled. Preserve this session; a free writer lock does not authorize another launch or metadata change."
            ))
        }
      } catch {
        intentStatus = .invalid
        findings.append(
          InspectionFinding(
            code: "runtime-intent-invalid",
            message:
              "Runtime ownership intent is unsafe, changed, malformed or unsupported. Preserve it for review; it is not cleared automatically."
          ))
      }
    }
    let runtimeURL = directory.appendingPathComponent("runtime.json")
    let runtime = await files.status(at: runtimeURL)
    entries.append(InspectionFile(role: "runtime", status: runtime))
    if runtime.kind != .missing {
      do {
        guard runtime.kind == .regular, runtime.ownedByCurrentUser == true,
          runtime.otherWriteBits == false, runtime.links == 1
        else { throw VMError(.corruptMetadata, "Unsafe history.", recovery: "Preserve files.") }
        let record = try RuntimeHistoryCodec.decode(
          await files.readMetadata(at: runtimeURL, limit: RuntimeHistoryCodec.maximumBytes))
        history = RuntimeHistoryCodec.status(record, writer: writer)
      } catch { history = .invalid }
      if history == .invalid || history == .interruptedOrUnreconciled
        || history == .forcedStopRecorded || history == .failureRecorded
      {
        findings.append(
          InspectionFinding(
            code: "runtime-review",
            message:
              "Runtime history is invalid or has no recorded guest shutdown. Preserve files and review guest recovery; no repair is performed."
          ))
      }
    }
    let configurationURL = directory.appendingPathComponent("configuration.json")
    let configurationStatus = await files.status(at: configurationURL)
    entries.append(InspectionFile(role: "configuration", status: configurationStatus))
    if configurationStatus.kind == .missing {
      for (role, name) in [
        ("disk", "disk.raw"), ("identity", "machine-identity.bin"), ("efi", "efi-variables.bin"),
      ] {
        entries.append(
          InspectionFile(
            role: role, status: await files.status(at: directory.appendingPathComponent(name))))
      }
      findings.append(
        InspectionFinding(
          code: "registration-missing",
          message:
            "This directory is not registered. Preserve partial files; do not retry creation here.")
      )
      return report(.incomplete, writer: writer)
    }
    let c: VMConfiguration
    do {
      c = try ConfigurationCodec.decode(await files.readMetadata(at: configurationURL))
    } catch {
      findings.append(
        InspectionFinding(
          code: "configuration-unreadable",
          message:
            "Configuration is unsafe, malformed, oversized or has an unknown schema. Preserve all files."
        ))
      return report(.needsReview, writer: writer)
    }
    do { try ConfigurationValidator.validate(c, host: host) } catch {
      findings.append(
        InspectionFinding(
          code: "settings-review", message: "Saved settings do not pass validation on this host."))
    }
    if let record = intentRecord, record.vmID != c.id {
      intentStatus = .identityMismatch
      findings.append(
        InspectionFinding(
          code: "runtime-intent-identity-mismatch",
          message:
            "Runtime intent belongs to a different VM identity. Preserve configuration and intent; neither is replaced automatically."
        ))
    }
    if let growth = growthRecord {
      if growth.vmID != c.id {
        findings.append(
          InspectionFinding(
            code: "disk-growth-identity-mismatch",
            message:
              "Disk growth belongs to another VM identity. Preserve its disk and metadata; the record is not replaced automatically."
          ))
      } else if growth.state == .completed {
        do {
          try await files.verifyCompletedDiskGrowth(in: directory, expectedVMID: c.id)
        } catch {
          findings.append(
            InspectionFinding(
              code: "disk-growth-completion-mismatch",
              message:
                "Completed disk growth does not match the current disk and registration. Preserve all files and inspect before any write."
            ))
        }
      }
    }
    guard ConfigurationValidator.isSafeComponent(c.diskFile) else {
      findings.append(
        InspectionFinding(
          code: "unsafe-disk-path",
          message: "The configured disk path is unsafe and was not inspected."))
      return report(.needsReview, writer: writer)
    }
    let disk = await files.status(at: directory.appendingPathComponent(c.diskFile))
    entries.append(InspectionFile(role: "disk", status: disk))
    checkWritable(disk, role: "disk", findings: &findings)
    if disk.kind == .regular, disk.bytes != c.diskBytes {
      findings.append(
        InspectionFinding(
          code: "disk-size-mismatch",
          message:
            "Disk length differs from configuration. Do not resize or truncate it to hide the mismatch."
        ))
    }
    if c.backend == .appleVz {
      let identity = await files.status(
        at: directory.appendingPathComponent("machine-identity.bin"))
      entries.append(InspectionFile(role: "identity", status: identity))
      if identity.kind != .regular || identity.bytes == nil || identity.bytes == 0
        || (identity.bytes ?? 0) > 4096
      {
        findings.append(
          InspectionFinding(
            code: "identity-unavailable",
            message:
              "The original native machine identity is missing, unsafe or outside its bounds. Do not replace it automatically."
          ))
      }
      if c.boot == .efi {
        let efi = await files.status(at: directory.appendingPathComponent("efi-variables.bin"))
        entries.append(InspectionFile(role: "efi", status: efi))
        checkWritable(efi, role: "efi", findings: &findings)
      }
    } else {
      findings.append(
        InspectionFinding(
          code: "backend-platform-unverified",
          message:
            "Platform inspection for this backend is not implemented. Boot readiness remains unverified."
        ))
    }
    for (role, path) in [
      ("media", c.installationMedia), ("kernel", c.kernel), ("initrd", c.initialRamdisk),
      ("support-media", c.supportMedia),
    ] {
      guard let path else { continue }
      guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else {
        findings.append(
          InspectionFinding(
            code: "unsafe-media-path", message: "An unsafe media path was not inspected."))
        continue
      }
      let info = await files.status(at: URL(fileURLWithPath: path))
      entries.append(InspectionFile(role: role, status: info))
      if info.kind != .regular || info.bytes == nil || info.bytes == 0 {
        findings.append(
          InspectionFinding(
            code: "media-unavailable",
            message: "Selected boot media is missing, empty or not a regular file."))
      } else if role == "support-media" {
        do {
          _ = try await files.inspectReadOnlyImage(at: URL(fileURLWithPath: path))
        } catch {
          findings.append(
            InspectionFinding(
              code: "support-media-unavailable",
              message:
                "Selected support media is unreadable, changed or outside the raw image bounds."
            ))
        }
      }
    }
    if writer == .unavailable {
      findings.append(
        InspectionFinding(
          code: "writer-probe-unavailable",
          message:
            "Safe cooperating ownership could not be checked. Inspect the original lock and permissions."
        ))
    }
    if writer == .held { return report(.busy, writer: writer) }
    return report(findings.isEmpty ? .filesMatchConfiguration : .needsReview, writer: writer)
  }

  private func checkWritable(
    _ info: VMFileStatus, role: String, findings: inout [InspectionFinding]
  ) {
    if info.kind != .regular || info.bytes == nil || info.bytes == 0
      || info.ownedByCurrentUser != true || info.links != 1 || info.otherWriteBits != false
    {
      findings.append(
        InspectionFinding(
          code: "unsafe-\(role)",
          message:
            "A required writable file is missing, empty, non-regular, aliased or has unsafe ownership/write bits. Preserve it for review."
        ))
    }
  }
}
