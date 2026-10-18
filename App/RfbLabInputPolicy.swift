// SPDX-License-Identifier: Apache-2.0
import Foundation
import RuntimeIPC
import VMCore
import VMStorage

/// Mode selection and correlation only. This never grants agent credentials,
/// runtime control, writer ownership or authority from a saved route alone.
struct RfbLabInputPolicy: Sendable {
  enum Mode: Equatable, Sendable {
    case none, invalid, firmware, windowsInstaller, windowsNetworkObserver, windowsNetworkHumanInput
  }

  static let humanFlag = "--windows-network-human-input-display-lab"
  static let humanRun =
    ".lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0/run-4805dfc7548144148c98a3ff9870e30e"
  static let humanVMID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  static let humanSessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  let mode: Mode
  let directoryPath: String?
  private let expectedHumanDirectory: String?

  init(arguments: [String], projectRoot: URL) {
    let flags: [String: Mode] = [
      "--rfb-display-lab": .firmware,
      "--windows-installer-display-lab": .windowsInstaller,
      "--windows-network-continuation-display-lab": .windowsNetworkObserver,
      Self.humanFlag: .windowsNetworkHumanInput,
    ]
    let matches = arguments.enumerated().filter { flags[$0.element] != nil }
    let projectPath = projectRoot.path
    expectedHumanDirectory =
      projectRoot.isFileURL
        && (projectRoot.host == nil || projectRoot.host == ""
          || projectRoot.host == "localhost")
        && projectRoot.query == nil
        && projectRoot.fragment == nil && Self.lexicalDirectory(projectPath)
      ? projectPath + "/" + Self.humanRun : nil
    guard !matches.isEmpty else {
      mode = .none
      directoryPath = nil
      return
    }
    guard matches.count == 1, let match = matches.first,
      match.offset + 1 < arguments.count,
      let chosen = flags[match.element]
    else {
      mode = .invalid
      directoryPath = nil
      return
    }
    let path = arguments[match.offset + 1]
    guard Self.lexicalDirectory(path),
      chosen != .windowsNetworkHumanInput || path == expectedHumanDirectory
    else {
      mode = .invalid
      directoryPath = nil
      return
    }
    mode = chosen
    directoryPath = path
  }

  var selected: Bool { mode != .none }
  var networkContinuation: Bool {
    mode == .windowsNetworkObserver || mode == .windowsNetworkHumanInput
  }
  var humanInput: Bool { mode == .windowsNetworkHumanInput }
  var observationOnly: Bool { mode == .windowsNetworkObserver }
  var windowsInstaller: Bool { mode == .windowsInstaller || networkContinuation }
  var canCaptureInput: Bool {
    mode == .firmware || mode == .windowsInstaller || humanInput
  }
  var canControlRuntime: Bool { mode == .firmware || mode == .windowsInstaller }

  func validateHumanRoute(_ route: DisplayWorkerRoute) -> Bool {
    humanInput && directoryPath == expectedHumanDirectory && route.schemaVersion == 1
      && route.scope == "approved-windows-network-continuation-display-route"
      && route.vmID == Self.humanVMID && route.sessionID == Self.humanSessionID
  }

  func allowsHumanCapture(
    route: DisplayWorkerRoute, status: WorkerResponse, intent: RuntimeIntent?, writerHeld: Bool
  ) -> Bool {
    guard validateHumanRoute(route), status.vmID == route.vmID,
      status.sessionID == route.sessionID, status.state == 2, status.ownership == 0,
      status.backendActive, status.error == .none, !status.operationPending,
      let intent, intent.schemaVersion == 1, intent.state == .unsettled,
      intent.vmID == route.vmID, intent.sessionID == route.sessionID, writerHeld
    else { return false }
    return true
  }

  /// Rechecked after each suspension and first-responder change. Actual object,
  /// focus, queue and cleanup checks remain in the native view's caller.
  func permitsCaptureEpoch(
    requestedConnection: UUID, currentConnection: UUID,
    requestedEpoch: UUID, clientEpoch: UUID?, frameEpoch: UUID?,
    requestedCapture: UUID, currentCapture: UUID?
  ) -> Bool {
    canCaptureInput && requestedConnection == currentConnection
      && requestedEpoch == clientEpoch && requestedEpoch == frameEpoch
      && requestedCapture == currentCapture
  }

  private static func lexicalDirectory(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path.utf8.count <= 4096,
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}
