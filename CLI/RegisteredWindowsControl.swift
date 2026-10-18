// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import RuntimeIPC
import VMCore
import VMStorage

/// Routes locate an existing peer; they never reconstruct its owner or writer lease.
enum RegisteredWindowsControl {
  enum Action: String, CaseIterable, Sendable {
    case status, pause, resume, stop
    case forceStop = "force-stop"
    var command: WorkerCommand {
      switch self {
      case .status: .status
      case .pause: .pause
      case .resume: .resume
      case .stop: .stop
      case .forceStop: .forceStop
      }
    }
  }
  struct Request: Sendable {
    let action: Action, directory: URL, runDirectory: URL, expectedSession: UUID
    init(
      action: Action, directory: URL, runDirectory: URL, expectedSession: UUID,
      confirmDataLoss: String? = nil
    ) throws {
      // Consent is checked before any path, record, socket or writer observation.
      guard action == .forceStop ? confirmDataLoss == "yes" : confirmDataLoss == nil else {
        throw failure(
          "Force stop requires --confirm-data-loss yes; other commands reject that option.")
      }
      guard validURL(directory), validURL(runDirectory),
        runDirectory.deletingLastPathComponent().path == directory.path + "/.runtime",
        runDirectory.lastPathComponent.range(of: "^run-[0-9a-f]{32}$", options: .regularExpression)
          != nil
      else { throw failure("Select an absolute registered VM and its explicit runtime directory.") }
      self.action = action
      self.directory = directory
      self.runDirectory = runDirectory
      self.expectedSession = expectedSession
    }
  }
  struct Result: Encodable, Sendable {
    let schemaVersion = 1
    let action: String, vmID: UUID, sessionID: UUID, revision: UInt64
    let state: UInt8, ownership: UInt8, backendActive: Bool, operationPending: Bool, error: UInt8
    /// A lifecycle ACK records request acceptance, never completed shutdown.
    let requestAcknowledged: Bool
    init(action: Action, response: WorkerResponse) {
      self.action = action.rawValue
      vmID = response.vmID
      sessionID = response.sessionID
      revision = response.revision
      state = response.state
      ownership = response.ownership
      backendActive = response.backendActive
      operationPending = response.operationPending
      error = response.error.rawValue
      requestAcknowledged = action != .status && response.error == .none
    }
  }
  static func run(_ request: Request) async throws -> Result {
    let admission = try await Admission(request)
    let client = WorkerIPCClient(
      socketURL: admission.socket, vmID: admission.vmID, sessionID: request.expectedSession,
      timeout: request.action == .forceStop ? .seconds(30) : .seconds(3))
    do {
      try await admission.revalidate()
      try await client.connect()
      let observed = try await client.request(.status)
      if request.action == .status {
        try await admission.revalidate()
        await client.close()
        return Result(action: .status, response: observed)
      }
      if request.action == .stop && observed.state == 4 {
        throw failure("Resume the paused guest before requesting normal stop.")
      }
      guard observed.ownership == 0, observed.backendActive, !observed.operationPending,
        request.action == .forceStop
          ? (observed.error == .none || observed.error == .operationFailed)
          : (observed.error == .none && observed.state == (request.action == .resume ? 4 : 2))
      else { throw failure("The current worker is not ready for this lifecycle request.") }
      try await admission.revalidate()
      let response = try await client.request(
        request.action.command, observedRevision: observed.revision)
      await client.close()
      return Result(action: request.action, response: response)
    } catch {
      await client.close()
      throw error
    }
  }
  struct DirectoryIdentity: Sendable {
    let url: URL, device: dev_t, inode: ino_t
    init(_ url: URL) throws {
      try WindowsExternalFileIO.privateDirectory(url)
      var info = stat()
      guard lstat(url.path, &info) == 0 else { throw failure("Runtime directory is unavailable.") }
      self.url = url
      device = info.st_dev
      inode = info.st_ino
    }
    func verify() throws {
      let actual = try DirectoryIdentity(url)
      guard actual.device == device, actual.inode == inode else {
        throw failure("Runtime directory changed.")
      }
    }
  }
  struct Admission: Sendable {
    let request: Request, vmID: UUID, socket: URL, configuration: Data, route: Data
    let directories: [DirectoryIdentity]
    init(_ request: Request) async throws {
      self.request = request
      var identities = try [
        request.directory, request.runDirectory.deletingLastPathComponent(), request.runDirectory,
      ]
      .map { try DirectoryIdentity($0) }
      configuration = try WindowsExternalFileIO.readPrivate(
        request.directory.appendingPathComponent("configuration.json"),
        maximum: ConfigurationCodec.maximumBytes)
      let c = try StrictConfigurationDocument(configuration).configuration
      guard c.guest == .windows11, c.backend == .qemuHVF, c.architecture == .arm64, c.boot == .efi
      else {
        throw failure("This control route supports registered Windows ARM EFI workers only.")
      }
      vmID = c.id
      route = try WindowsExternalFileIO.readPrivate(
        request.runDirectory.appendingPathComponent("worker.json"), maximum: 4096)
      socket = try decodeRoute(
        route, vmID: c.id, sessionID: request.expectedSession, expectedRun: request.runDirectory)
      identities.append(try DirectoryIdentity(socket.deletingLastPathComponent()))
      directories = identities
      try await revalidate()
    }
    func revalidate() async throws {
      for identity in directories { try identity.verify() }
      guard
        try WindowsExternalFileIO.readPrivate(
          request.directory.appendingPathComponent("configuration.json"), maximum: 65_536)
          == configuration,
        try WindowsExternalFileIO.readPrivate(
          request.runDirectory.appendingPathComponent("worker.json"), maximum: 4096) == route,
        let intent = try await VMFiles().readRuntimeIntent(in: request.directory),
        intent.vmID == vmID, intent.sessionID == request.expectedSession,
        intent.state == .unsettled,
        await VMFiles().writerStatus(in: request.directory) == .held
      else { throw failure("The route does not match a current worker with a held writer lease.") }
      for identity in directories { try identity.verify() }
    }
  }
  private struct Route: Codable {
    let schemaVersion: Int, scope: String, vmID: UUID, sessionID: UUID, socket: String
  }
  static func decodeRoute(_ data: Data, vmID: UUID, sessionID: UUID, expectedRun: URL) throws -> URL
  {
    guard !data.isEmpty, data.count <= 4096 else { throw failure("Worker route is malformed.") }
    let route = try JSONDecoder().decode(Route.self, from: data)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // The registered producer publishes these exact canonical bytes. Roundtrip
    // equality rejects duplicates, unknown fields, alternate types and escaped keys.
    guard try encoder.encode(route) == data, route.schemaVersion == 1,
      route.scope == "macopenvm-registered-qemu-worker-route", route.vmID == vmID,
      route.sessionID == sessionID,
      expectedRun.lastPathComponent.range(of: "^run-[0-9a-f]{32}$", options: .regularExpression)
        != nil,
      route.socket
        == "/private/tmp/mvo-qemu-\(expectedRun.lastPathComponent.dropFirst(4).prefix(16))/worker.sock"
    else { throw failure("Worker route is not the selected registered session.") }
    return URL(fileURLWithPath: route.socket)
  }
  private static func validURL(_ url: URL) -> Bool {
    let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
      .removingPercentEncoding
    return WindowsExternalFileIO.lexical(url) && (url.host == nil || url.host == "")
      && (decoded == url.path || (url.hasDirectoryPath && decoded == url.path + "/"))
  }
  private static func failure(_ message: String) -> VMError {
    VMError(
      .invalidConfiguration, message,
      recovery: "Inspect current worker status and preserve the VM. No retry or stop is automatic.")
  }
}
