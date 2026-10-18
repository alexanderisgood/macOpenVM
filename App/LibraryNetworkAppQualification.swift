// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import VMCore
import VMStorage

struct LibraryNetworkAppQualificationRequest: Sendable {
  static let flag = "--library-network-app-qualification"
  static let networkSheetIdentifier = NSUserInterfaceItemIdentifier("macOpenVM.networkSettings")
  let directory: URL
  let vmID: UUID
  let outputDirectory: URL

  static func parse(arguments: [String], environment: [String: String]) throws -> Self? {
    guard arguments.contains(flag) else { return nil }
    guard environment["MVO_LIBRARY_NETWORK_APP_QUALIFICATION"] == "1", arguments.count == 9,
      arguments[1] == flag, arguments[2] == "--run", arguments[3] == "--directory",
      arguments[5] == "--expected-vm", arguments[7] == "--output-directory",
      let vmID = UUID(uuidString: arguments[6]), vmID.uuidString == arguments[6],
      vmID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
      arguments[4].range(
        of: "^/private/tmp/mvo-library-network-[0-9a-f]{32}/Library Network[.]macopenvm$",
        options: .regularExpression) != nil
    else { throw libraryNetworkQualificationFailure() }
    let directory = URL(fileURLWithPath: arguments[4], isDirectory: true)
    let output = directory.deletingLastPathComponent().appendingPathComponent("evidence")
    guard arguments[8] == output.path else { throw libraryNetworkQualificationFailure() }
    return Self(directory: directory, vmID: vmID, outputDirectory: output)
  }
}

@MainActor final class LibraryNetworkQualificationPreferences: VMLibraryPreferences {
  private var bytes: Data?
  func read() throws -> Data? { bytes }
  func write(_ data: Data) throws { bytes = data }
}

enum LibraryNetworkQualificationAdmission {
  struct FileFacts: Equatable {
    let device: dev_t, inode: ino_t, bytes: off_t, blocks: blkcnt_t
  }
  static func validate(_ configuration: VMConfiguration, expectedID: UUID) throws {
    guard configuration.id == expectedID, configuration.name == "Library Network",
      configuration.guest == .linux, configuration.backend == .appleVz,
      configuration.architecture == .arm64, configuration.boot == .efi,
      configuration.network == .disconnected, configuration.installationMedia == nil,
      configuration.supportMedia == nil, configuration.kernel == nil,
      configuration.initialRamdisk == nil
    else { throw libraryNetworkQualificationFailure() }
  }
  static func privateDirectory(_ url: URL) throws {
    var path = ""
    for part in url.path.split(separator: "/") {
      path += "/" + part
      var ancestor = stat()
      guard lstat(path, &ancestor) == 0, ancestor.st_mode & S_IFMT == S_IFDIR,
        ancestor.st_uid == 0 || ancestor.st_uid == geteuid(),
        ancestor.st_mode & 0o022 == 0
          || path == "/private/tmp" && ancestor.st_uid == 0 && ancestor.st_mode & S_ISVTX != 0
      else { throw libraryNetworkQualificationFailure() }
    }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else { throw libraryNetworkQualificationFailure() }
  }
  static func snapshot(in directory: URL, configuration: VMConfiguration) throws -> [String:
    FileFacts]
  {
    try privateDirectory(directory)
    let lock = try VMLock(existingDirectory: directory, expectedVMID: configuration.id)
    defer { withExtendedLifetime(lock) {} }
    let required: Set<String> = [
      "configuration.json", configuration.diskFile, "writer.lock", "machine-identity.bin",
      "efi-variables.bin",
    ]
    let names = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
    let backups = names.subtracting(required)
    guard required.isSubset(of: names), backups.count <= 1,
      backups.allSatisfy({
        $0.range(
          of:
            "^configuration-media-backup-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]json$",
          options: .regularExpression) != nil
      })
    else { throw libraryNetworkQualificationFailure() }
    var result: [String: FileFacts] = [:]
    for name in names {
      var info = stat()
      guard lstat(directory.appendingPathComponent(name).path, &info) == 0,
        info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
        info.st_mode & 0o7777 == 0o600, info.st_size >= 0
      else { throw libraryNetworkQualificationFailure() }
      if name == configuration.diskFile {
        guard UInt64(info.st_size) == configuration.diskBytes, info.st_blocks == 0
        else { throw libraryNetworkQualificationFailure() }
      }
      result[name] = FileFacts(
        device: info.st_dev, inode: info.st_ino, bytes: info.st_size, blocks: info.st_blocks)
    }
    guard lock.owns(directory) else { throw libraryNetworkQualificationFailure() }
    return result
  }
}

private final class LibraryNetworkResultOutput {
  private let directory: URL
  private let descriptor: Int32
  private let identity: stat
  init(directory: URL) throws {
    try LibraryNetworkQualificationAdmission.privateDirectory(directory)
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    var info = stat()
    var named = stat()
    guard fd >= 0 else { throw libraryNetworkQualificationFailure() }
    guard fstat(fd, &info) == 0, lstat(directory.path, &named) == 0,
      info.st_dev == named.st_dev, info.st_ino == named.st_ino
    else {
      close(fd)
      throw libraryNetworkQualificationFailure()
    }
    self.directory = directory
    descriptor = fd
    identity = info
  }
  deinit { close(descriptor) }
  private func verify() throws {
    try LibraryNetworkQualificationAdmission.privateDirectory(directory)
    var named = stat()
    var held = stat()
    guard lstat(directory.path, &named) == 0, fstat(descriptor, &held) == 0,
      named.st_dev == identity.st_dev, named.st_ino == identity.st_ino,
      held.st_dev == identity.st_dev, held.st_ino == identity.st_ino
    else { throw libraryNetworkQualificationFailure() }
  }
  func save(_ bytes: Data) throws {
    guard !bytes.isEmpty, bytes.count <= 4096 else { throw libraryNetworkQualificationFailure() }
    try verify()
    let fd = openat(
      descriptor, "sdk-result.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw libraryNetworkQualificationFailure() }
    defer { close(fd) }
    try bytes.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { throw libraryNetworkQualificationFailure() }
      var offset = 0
      while offset < bytes.count {
        let count = write(fd, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw libraryNetworkQualificationFailure() }
        offset += count
      }
    }
    guard fsync(fd) == 0, fsync(descriptor) == 0 else { throw libraryNetworkQualificationFailure() }
    try verify()
  }
}

/// SDK sheet observations with ordinary controller actuation. This does not
/// synthesize a mouse click, prove a context-menu action, or read guest pixels.
@MainActor final class LibraryNetworkAppQualification {
  private let request: LibraryNetworkAppQualificationRequest
  private let session: DesktopSession
  private var started = false
  private var phase = "admission"
  private var owner: NSWindow?
  private var baseline = Data()
  private var events: [String] = []
  private var output: LibraryNetworkResultOutput?
  init(request: LibraryNetworkAppQualificationRequest, session: DesktopSession) {
    self.request = request
    self.session = session
  }
  func run() async {
    guard !started else { return }
    started = true
    var passed = false
    do {
      try LibraryNetworkQualificationAdmission.privateDirectory(
        request.directory.deletingLastPathComponent())
      try LibraryNetworkQualificationAdmission.privateDirectory(request.directory)
      try LibraryNetworkQualificationAdmission.privateDirectory(request.outputDirectory)
      output = try LibraryNetworkResultOutput(directory: request.outputDirectory)
      let files = VMFiles()
      let location = request.directory.appendingPathComponent("configuration.json")
      baseline = try await files.readMetadata(at: location, limit: ConfigurationCodec.maximumBytes)
      let configuration = try ConfigurationCodec.decode(baseline)
      try LibraryNetworkQualificationAdmission.validate(configuration, expectedID: request.vmID)
      let snapshot = try LibraryNetworkQualificationAdmission.snapshot(
        in: request.directory, configuration: configuration)
      guard session.library.entries.isEmpty, idle else {
        throw libraryNetworkQualificationFailure()
      }
      phase = "owner-window"
      try await wait { self.session.window != nil }
      owner = session.window
      guard owner?.isVisible == true, owner?.attachedSheet == nil else {
        throw libraryNetworkQualificationFailure()
      }
      events.append("sdk-owner-visible")
      session.library.remember(configuration, at: location)
      let entry = try VMLibraryEntry(configuration: configuration, at: location)
      phase = "library-sheet"
      session.showLibrary()
      try await wait {
        self.sameOwner
          && self.owner?.attachedSheet?.identifier == DesktopSession.librarySheetIdentifier
      }
      guard session.showingLibrary, session.canOpenSavedNetworkSettings(entry) else {
        throw libraryNetworkQualificationFailure()
      }
      events.append("sdk-library-attached-to-owner")
      phase = "network-route"
      // The real SwiftUI sheet onDismiss invokes libraryDismissed; do not call it here.
      session.openSavedNetworkSettings(entry)
      try await wait {
        self.sameOwner && self.session.editingNetwork
          && self.owner?.attachedSheet?.identifier
            == LibraryNetworkAppQualificationRequest.networkSheetIdentifier
      }
      guard session.configuration == configuration, session.networkConfiguration == configuration,
        session.selectedConfigurationURL == location, session.networkError == nil,
        session.state == .stopped, !session.isActive, session.qualificationWindowsRuntime == nil
      else { throw libraryNetworkQualificationFailure() }
      events.append("sdk-network-sheet-attached-same-owner")
      phase = "cancel"
      // Same controller mutation as Cancel. This is not a native button-press claim.
      session.editingNetwork = false
      try await wait { self.sameOwner && self.owner?.attachedSheet == nil && !self.session.isBusy }
      guard session.networkConfiguration == nil, session.networkError == nil,
        session.configuration == configuration, idle,
        try await files.readMetadata(at: location, limit: ConfigurationCodec.maximumBytes)
          == baseline,
        try LibraryNetworkQualificationAdmission.snapshot(
          in: request.directory, configuration: configuration) == snapshot
      else { throw libraryNetworkQualificationFailure() }
      events.append("sdk-network-sheet-detached-after-controller-cancel")
      phase = "complete"
      passed = true
    } catch { events.append("qualification-refused") }
    let canQuit = idle && session.window?.attachedSheet == nil
    do {
      let record = Result(
        phase: phase, passed: passed, events: events, vmID: request.vmID,
        sameOwner: sameOwner, controllerActuation: true, guestStarted: false,
        networkSaved: false, pixelsRead: false, idleQuitRequested: canQuit,
        configurationSHA256: SHA256.hash(data: baseline).map { String(format: "%02x", $0) }.joined()
      )
      let bytes = try JSONEncoder().encode(record)
      guard let output else { throw libraryNetworkQualificationFailure() }
      try output.save(bytes)
      if canQuit { NSApp.terminate(nil) }
    } catch {
      // Keep this exact app available for inspection when result persistence fails.
    }
  }
  private var sameOwner: Bool { owner != nil && session.window === owner }
  private var idle: Bool {
    !session.isBusy && !session.isActive && !session.creating && !session.showingLibrary
      && session.state == .stopped && session.qualificationWindowsRuntime == nil
  }
  private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
      guard ContinuousClock.now < deadline else { throw libraryNetworkQualificationFailure() }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
  private struct Result: Encodable {
    let phase: String, passed: Bool, events: [String], vmID: UUID
    let sameOwner: Bool, controllerActuation: Bool, guestStarted: Bool, networkSaved: Bool
    let pixelsRead: Bool, idleQuitRequested: Bool, configurationSHA256: String
  }
}

private func libraryNetworkQualificationFailure() -> VMError {
  VMError(
    .invalidConfiguration, "The private library networking UI check could not be confirmed.",
    recovery: "Preserve this test app and its fresh fixture for inspection.")
}
