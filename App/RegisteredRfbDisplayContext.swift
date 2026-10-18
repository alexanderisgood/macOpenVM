// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import RuntimeIPC
import VMCore
import VMStorage

/// Current parent-supplied display correlation. No saved record can launch a worker,
/// acquire its lease or reconstruct ownership through this value.
struct RegisteredRfbDisplayContext: Sendable {
  static let scope = "macopenvm-registered-qemu-display-route"
  let configuration: VMConfiguration
  let directory: URL
  let sessionID: UUID
  let launchGeneration: UUID
  let readinessDirectory: URL
  let readinessURL: URL
  let readinessData: Data
  let readinessSHA256: String
  let route: DisplayWorkerRoute
  let sharedReadinessData: Data?
  let sharedRoute: DisplayWorkerRoute?

  init(
    configuration: VMConfiguration, directory: URL, sessionID: UUID, launchGeneration: UUID,
    readinessDirectory: URL, readinessURL: URL, readinessData: Data,
    expectedReadinessSHA256: String, route: DisplayWorkerRoute, sharedReadinessData: Data? = nil
  ) throws {
    guard configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi,
      RegisteredRfbContextIO.local(directory), RegisteredRfbContextIO.local(readinessDirectory),
      RegisteredRfbContextIO.local(readinessURL),
      readinessDirectory.deletingLastPathComponent().path == directory.path + "/.runtime",
      readinessDirectory.lastPathComponent.range(
        of: "^run-[0-9a-f]{32}$", options: .regularExpression) != nil,
      readinessURL.deletingLastPathComponent().path == readinessDirectory.path,
      readinessURL.lastPathComponent == "display.json",
      !readinessData.isEmpty, readinessData.count <= FlatDisplayRouteCodec.maximumBytes,
      expectedReadinessSHA256.utf8.count == 64,
      expectedReadinessSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }
      ),
      Self.digest(readinessData) == expectedReadinessSHA256,
      try FlatDisplayRouteCodec.decode(readinessData, profile: .registeredQemu) == route,
      route.schemaVersion == 1, route.scope == Self.scope,
      route.vmID == configuration.id, route.sessionID == sessionID,
      let parent = route.controlSocket.split(separator: "/").dropLast().last.map({ String($0) }),
      parent.range(of: "^mvo-qemu-[0-9a-f]{16}$", options: .regularExpression) != nil,
      route.controlSocket == "/private/tmp/" + parent + "/worker.sock",
      route.displaySocket == "/private/tmp/" + parent + "/vnc.sock"
    else { throw Self.failure() }
    self.configuration = configuration
    self.directory = directory
    self.sessionID = sessionID
    self.launchGeneration = launchGeneration
    self.readinessDirectory = readinessDirectory
    self.readinessURL = readinessURL
    self.readinessData = readinessData
    readinessSHA256 = expectedReadinessSHA256
    self.route = route
    if let bytes = sharedReadinessData {
      let shared = try FlatDisplayRouteCodec.decode(bytes, profile: .registeredSharedFrame)
      guard shared.vmID == configuration.id, shared.sessionID == sessionID,
        shared.controlSocket == route.controlSocket,
        shared.parentDevice == route.parentDevice, shared.parentInode == route.parentInode,
        shared.displaySocket == "/private/tmp/" + parent + "/surface.sock"
      else { throw Self.failure() }
      self.sharedReadinessData = bytes
      sharedRoute = shared
    } else {
      self.sharedReadinessData = nil
      sharedRoute = nil
    }
  }

  func readAdmission(currentLaunchGeneration: UUID?) throws -> (
    route: DisplayWorkerRoute, data: Data
  ) {
    guard currentLaunchGeneration == launchGeneration else { throw Self.failure() }
    try RegisteredRfbContextIO.privateDirectory(directory)
    let stored = try ConfigurationCodec.decode(
      RegisteredRfbContextIO.read(
        directory.appendingPathComponent("configuration.json"), in: directory,
        maximum: ConfigurationCodec.maximumBytes))
    guard stored.id == configuration.id, stored.guest == .windows11, stored.backend == .qemuHVF,
      stored.architecture == .arm64, stored.boot == .efi
    else { throw Self.failure() }
    let bytes = try RegisteredRfbContextIO.read(readinessURL, in: readinessDirectory)
    guard bytes == readinessData, Self.digest(bytes) == readinessSHA256,
      try FlatDisplayRouteCodec.decode(bytes, profile: .registeredQemu) == route
    else { throw Self.failure() }
    return (route, bytes)
  }

  func allowsCapture(
    status: WorkerResponse, intent: RuntimeIntent?, writerHeld: Bool,
    currentLaunchGeneration: UUID?, allowRecoveryInput: Bool = false
  ) -> Bool {
    currentLaunchGeneration == launchGeneration && status.vmID == configuration.id
      && status.sessionID == sessionID
      && (status.state == 2 || (allowRecoveryInput && (status.state == 3 || status.state == 6)))
      && status.ownership == 0
      && status.backendActive && status.error == .none && !status.operationPending
      && intent?.schemaVersion == 1 && intent?.vmID == configuration.id
      && intent?.sessionID == sessionID && intent?.state == .unsettled && writerHeld
  }

  func readSharedAdmission(currentLaunchGeneration: UUID?) throws -> DisplayWorkerRoute? {
    _ = try readAdmission(currentLaunchGeneration: currentLaunchGeneration)
    guard let sharedReadinessData, let sharedRoute else { return nil }
    let bytes = try RegisteredRfbContextIO.read(
      readinessDirectory.appendingPathComponent("surface.json"), in: readinessDirectory)
    guard bytes == sharedReadinessData,
      try FlatDisplayRouteCodec.decode(bytes, profile: .registeredSharedFrame) == sharedRoute
    else { throw Self.failure() }
    return sharedRoute
  }

  func permitsCaptureEpoch(
    requestedConnection: UUID, currentConnection: UUID, requestedEpoch: UUID,
    clientEpoch: UUID?, frameEpoch: UUID?, requestedCapture: UUID, currentCapture: UUID?,
    currentLaunchGeneration: UUID?
  ) -> Bool {
    currentLaunchGeneration == launchGeneration && requestedConnection == currentConnection
      && requestedEpoch == clientEpoch && requestedEpoch == frameEpoch
      && requestedCapture == currentCapture
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func failure() -> VMError {
    VMError(
      .staleOperation, "The registered VM display could not be confirmed.",
      recovery: "Preserve its actual worker and reconnect after reviewing the selected session.")
  }
}

private enum RegisteredRfbContextIO {
  static func local(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && url.path.hasPrefix("/") && url.path.utf8.count <= 4096
      && !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
  }
  static func privateDirectory(_ url: URL) throws {
    guard local(url) else { throw RegisteredRfbDisplayContext.failure() }
    var path = ""
    for component in url.path.split(separator: "/") {
      path += "/" + component
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == 0 || info.st_uid == geteuid(),
        info.st_mode & 0o022 == 0
          || (path == "/private/tmp" && info.st_uid == 0 && info.st_mode & S_ISVTX != 0)
      else { throw RegisteredRfbDisplayContext.failure() }
    }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else { throw RegisteredRfbDisplayContext.failure() }
  }
  static func read(_ url: URL, in directory: URL, maximum: Int = FlatDisplayRouteCodec.maximumBytes)
    throws -> Data
  {
    try privateDirectory(directory)
    let anchor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard anchor >= 0 else { throw RegisteredRfbDisplayContext.failure() }
    defer { close(anchor) }
    var beforeDirectory = stat()
    guard fstat(anchor, &beforeDirectory) == 0, beforeDirectory.st_uid == geteuid(),
      beforeDirectory.st_mode & S_IFMT == S_IFDIR, beforeDirectory.st_mode & 0o7777 == 0o700
    else { throw RegisteredRfbDisplayContext.failure() }
    let descriptor = openat(
      anchor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw RegisteredRfbDisplayContext.failure() }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
      before.st_size > 0, before.st_size <= maximum
    else { throw RegisteredRfbDisplayContext.failure() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data = try handle.read(upToCount: maximum + 1) ?? Data()
    var after = stat()
    var named = stat()
    var afterDirectory = stat()
    var namedDirectory = stat()
    guard fstat(descriptor, &after) == 0,
      fstatat(anchor, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, named), data.count == before.st_size,
      fstat(anchor, &afterDirectory) == 0, lstat(directory.path, &namedDirectory) == 0,
      beforeDirectory.st_dev == afterDirectory.st_dev,
      beforeDirectory.st_ino == afterDirectory.st_ino,
      afterDirectory.st_dev == namedDirectory.st_dev,
      afterDirectory.st_ino == namedDirectory.st_ino,
      afterDirectory.st_uid == geteuid(), namedDirectory.st_uid == geteuid(),
      afterDirectory.st_mode == beforeDirectory.st_mode,
      namedDirectory.st_mode == beforeDirectory.st_mode
    else { throw RegisteredRfbDisplayContext.failure() }
    return data
  }
  private static func stable(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode
      && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
      && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
}
