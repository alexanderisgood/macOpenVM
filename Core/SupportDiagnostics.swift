// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import VMStorage

/// Numeric public host facts only. Unknown capability facts remain unknown.
public struct DiagnosticHostFacts: Encodable, Sendable {
  public struct Version: Encodable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
  }
  public let architecture: GuestArchitecture
  public let cpuCount: Int?
  public let memoryMiB: UInt64?
  public let osVersion: Version?
  public let virtualizationSupported: Bool?
  public let virtualizationEntitled: Bool?

  public init(
    resources: HostResources = .current,
    osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    virtualizationSupported: Bool? = nil, virtualizationEntitled: Bool? = nil
  ) {
    architecture = resources.architecture
    cpuCount = (1...4096).contains(resources.cpuCount) ? resources.cpuCount : nil
    memoryMiB =
      resources.memoryBytes >= 256 * 1_048_576 && resources.memoryBytes <= 16 * 1_099_511_627_776
        && resources.memoryBytes % 1_048_576 == 0 ? resources.memoryBytes / 1_048_576 : nil
    self.osVersion =
      [osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion].allSatisfy {
        (0...999).contains($0)
      }
      ? Version(
        major: osVersion.majorVersion, minor: osVersion.minorVersion,
        patch: osVersion.patchVersion) : nil
    self.virtualizationSupported = virtualizationSupported
    self.virtualizationEntitled = virtualizationEntitled
  }

  public static var current: Self { Self() }
  fileprivate var inspectionResources: HostResources {
    HostResources(
      cpuCount: cpuCount ?? 0, memoryBytes: (memoryMiB ?? 0) * 1_048_576,
      architecture: architecture)
  }
}

public struct DiagnosticReport: Encodable, Sendable {
  public static let maximumBytes = 16_384
  public let schemaVersion = 1
  public let format = "macOpenVM-support-diagnostics"
  public let product = "macOpenVM"
  public let scope =
    "Structural inspection only; backend operation and guest health are unverified."
  public let host: DiagnosticHostFacts
  public let vm: VM?
  public let excludedContent = [
    "paths", "names", "VM and session identifiers", "usernames", "MAC and IP addresses",
    "guest content", "raw configuration", "logs", "exception text",
  ]

  public struct VM: Encodable, Sendable {
    public enum FileRole: String, Encodable, CaseIterable, Sendable {
      case directory, configuration, disk, identity, efi, runtime, media, kernel, initrd
      case runtimeIntent = "runtime-intent"
      case diskGrowthIntent = "disk-growth-intent"
      case supportMedia = "support-media"
    }
    public enum Finding: String, Encodable, CaseIterable, Sendable {
      case directoryUnavailable = "directory-unavailable"
      case diskGrowthPending = "disk-growth-pending"
      case diskGrowthInvalid = "disk-growth-invalid"
      case runtimeIntentUnsettled = "runtime-intent-unsettled"
      case runtimeIntentInvalid = "runtime-intent-invalid"
      case runtimeReview = "runtime-review"
      case registrationMissing = "registration-missing"
      case configurationUnreadable = "configuration-unreadable"
      case settingsReview = "settings-review"
      case runtimeIntentIdentityMismatch = "runtime-intent-identity-mismatch"
      case diskGrowthIdentityMismatch = "disk-growth-identity-mismatch"
      case diskGrowthCompletionMismatch = "disk-growth-completion-mismatch"
      case unsafeDiskPath = "unsafe-disk-path"
      case diskSizeMismatch = "disk-size-mismatch"
      case identityUnavailable = "identity-unavailable"
      case backendPlatformUnverified = "backend-platform-unverified"
      case unsafeMediaPath = "unsafe-media-path"
      case mediaUnavailable = "media-unavailable"
      case supportMediaUnavailable = "support-media-unavailable"
      case writerProbeUnavailable = "writer-probe-unavailable"
      case unsafeDisk = "unsafe-disk"
      case unsafeEFI = "unsafe-efi"
    }
    public struct File: Encodable, Sendable {
      public let role: FileRole
      public let kind: VMFileStatus.Kind
      public let links: UInt64?
      public let ownedByCurrentUser: Bool?
      public let otherWriteBits: Bool?
    }
    public let status: VMInspectionReport.Status
    public let writer: WriterStatus
    public let history: RuntimeHistoryStatus
    public let intent: RuntimeIntentInspectionStatus
    public let files: [File]
    public let findings: [Finding]
    public let unrecognizedInspectionFields: Bool
  }

  /// Readable deterministic JSON. No raw inspector strings participate in encoding.
  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var bytes = try encoder.encode(self)
    bytes.append(0x0A)
    guard bytes.count <= Self.maximumBytes else { throw diagnosticsFailure(.storage) }
    return bytes
  }
}

/// Locally generated support facts. It reads structural metadata and performs no
/// guest, runtime, pairing, network, log collection or permission-repair operation.
public struct SupportDiagnostics: Sendable {
  private let inspect: @Sendable (URL, HostResources) async -> VMInspectionReport
  private let exporter = DiagnosticExporter()
  public init(files: VMFiles = VMFiles()) {
    inspect = { directory, resources in
      await VMInspection(files: files).inspect(at: directory, host: resources)
    }
  }
  package init(inspect: @escaping @Sendable (URL, HostResources) async -> VMInspectionReport) {
    self.inspect = inspect
  }

  public static func make(directory: URL? = nil, host: DiagnosticHostFacts = .current) async
    -> DiagnosticReport
  {
    await Self().make(directory: directory, host: host)
  }

  public static func export(_ report: DiagnosticReport, to destination: URL) async throws {
    try await Self().export(report, to: destination)
  }

  public func make(directory: URL? = nil, host: DiagnosticHostFacts = .current) async
    -> DiagnosticReport
  {
    let report: DiagnosticReport.VM?
    if let directory {
      let original = await inspect(directory, host.inspectionResources)
      var files: [DiagnosticReport.VM.FileRole: DiagnosticReport.VM.File] = [:]
      var findings: Set<DiagnosticReport.VM.Finding> = []
      var unknown =
        original.schemaVersion != 1 || original.files.count > 64
        || original.findings.count > 64
      for file in original.files.prefix(64) {
        guard let role = DiagnosticReport.VM.FileRole(rawValue: file.role) else {
          unknown = true
          continue
        }
        if files[role] != nil {
          unknown = true
          continue
        }
        files[role] = .init(
          role: role, kind: file.status.kind, links: file.status.links,
          ownedByCurrentUser: file.status.ownedByCurrentUser,
          otherWriteBits: file.status.otherWriteBits)
      }
      for finding in original.findings.prefix(64) {
        guard let known = DiagnosticReport.VM.Finding(rawValue: finding.code) else {
          unknown = true
          continue
        }
        findings.insert(known)
      }
      report = .init(
        status: original.status, writer: original.writer, history: original.history,
        intent: original.intent,
        files: DiagnosticReport.VM.FileRole.allCases.compactMap { files[$0] },
        findings: DiagnosticReport.VM.Finding.allCases.filter { findings.contains($0) },
        unrecognizedInspectionFields: unknown)
    } else {
      report = nil
    }
    return DiagnosticReport(host: host, vm: report)
  }

  /// The caller must explicitly select a new local JSON file. Existing files,
  /// symlinks and VM artifacts are never replaced or repaired.
  public func export(_ report: DiagnosticReport, to destination: URL) async throws {
    try await exporter.write(report.jsonData(), to: destination)
  }
}

private actor DiagnosticExporter {
  func write(_ bytes: Data, to destination: URL) throws {
    guard destination.isFileURL,
      destination.host == nil || destination.host == "" || destination.host == "localhost",
      destination.user == nil, destination.password == nil, destination.query == nil,
      destination.fragment == nil, destination.path.hasPrefix("/"),
      destination.path.utf8.count <= 4096, destination.standardizedFileURL.path == destination.path,
      !destination.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      destination.pathExtension.lowercased() == "json",
      !["configuration.json", "runtime.json", "runtime-intent.json", "disk-growth-intent.json"]
        .contains(destination.lastPathComponent.lowercased()),
      !destination.lastPathComponent.hasPrefix("."), bytes.count <= DiagnosticReport.maximumBytes
    else { throw diagnosticsFailure(.invalidConfiguration) }
    try Task.checkCancellation()
    let parent = destination.deletingLastPathComponent()
    let anchor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard anchor >= 0 else { throw diagnosticsFailure(.storage) }
    defer { close(anchor) }
    var original = stat()
    guard fstat(anchor, &original) == 0, original.st_mode & S_IFMT == S_IFDIR,
      original.st_uid == geteuid(), original.st_mode & 0o022 == 0
    else { throw diagnosticsFailure(.storage) }
    let fd = openat(
      anchor, destination.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw diagnosticsFailure(.storage) }
    defer { close(fd) }
    // Partial new exports remain inspectable after I/O or cancellation failure.
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        try Task.checkCancellation()
        guard let base = buffer.baseAddress else { throw diagnosticsFailure(.storage) }
        let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw diagnosticsFailure(.storage) }
        offset += count
      }
    }
    var actual = stat()
    var named = stat()
    var selectedParent = stat()
    guard fsync(fd) == 0, fsync(anchor) == 0, fstat(fd, &actual) == 0,
      fstatat(anchor, destination.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
      actual.st_mode & S_IFMT == S_IFREG, actual.st_mode & 0o7777 == 0o600,
      actual.st_uid == geteuid(), actual.st_nlink == 1, actual.st_size == bytes.count,
      named.st_dev == actual.st_dev, named.st_ino == actual.st_ino,
      lstat(parent.path, &selectedParent) == 0, selectedParent.st_dev == original.st_dev,
      selectedParent.st_ino == original.st_ino
    else { throw diagnosticsFailure(.storage) }
  }
}

private func diagnosticsFailure(_ code: VMError.Code) -> VMError {
  VMError(
    code, "The support report export could not be confirmed.",
    recovery:
      "Choose a new local JSON file. Existing files are preserved; keep any partial new export.")
}
