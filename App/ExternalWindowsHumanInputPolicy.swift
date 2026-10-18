// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import RuntimeIPC
import VMCore
import VMStorage

/// Explicit display correlation from the retained parent, never launch or credential authority.
/// The fresh session and route digest are supplied independently of the readiness file.
struct ExternalWindowsHumanInputPolicy: Sendable {
  static let flag = "--windows-external-human-input-display-lab"
  static let scope = "approved-windows-external-continuation-display-route"
  static let vmDirectoryPath =
    "/Users/developer/Library/Application Support/macOpenVM/PrivateEvaluation/11111111-1111-4111-8111-111111111111"
  static let runParentPath = vmDirectoryPath + "/continuation-runs"
  static var vmDirectory: URL { URL(fileURLWithPath: vmDirectoryPath, isDirectory: true) }

  struct Binding: Equatable, Sendable {
    let runDirectoryPath: String
    let sessionID: UUID
    let routeSHA256: String
  }

  let selected: Bool
  let binding: Binding?
  var canCaptureInput: Bool { binding != nil }
  var canControlRuntime: Bool { false }
  var directoryPath: String? { binding?.runDirectoryPath }

  init(arguments: [String]) {
    selected = arguments.contains(Self.flag)
    let flags = [
      Self.flag, "--rfb-display-lab", "--windows-installer-display-lab",
      "--windows-network-continuation-display-lab", RfbLabInputPolicy.humanFlag,
    ]
    let matches = arguments.enumerated().filter { flags.contains($0.element) }
    guard selected, matches.count == 1, let index = arguments.firstIndex(of: Self.flag),
      index + 3 < arguments.count
    else {
      binding = nil
      return
    }
    let run = arguments[index + 1]
    let sessionText = arguments[index + 2]
    let digest = arguments[index + 3]
    guard Self.validRun(run), sessionText.utf8.count == 36,
      let session = UUID(uuidString: sessionText),
      session.uuidString.lowercased() == sessionText.lowercased(),
      session != RfbLabInputPolicy.humanSessionID,
      session.uuidString != "33333333-3333-4333-8333-333333333333",
      digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      binding = nil
      return
    }
    binding = Binding(runDirectoryPath: run, sessionID: session, routeSHA256: digest)
  }

  func validateRoute(_ route: DisplayWorkerRoute, data: Data) -> Bool {
    guard let binding, !data.isEmpty, data.count <= FlatDisplayRouteCodec.maximumBytes,
      route.schemaVersion == 1, route.scope == Self.scope,
      route.vmID == RfbLabInputPolicy.humanVMID, route.sessionID == binding.sessionID,
      Self.digest(data) == binding.routeSHA256,
      let parent = route.controlSocket.split(separator: "/").dropLast().last.map({ String($0) }),
      parent.range(of: "^mvo-win-external-[0-9a-f]{16}$", options: .regularExpression) != nil
    else { return false }
    let endpoint = "/private/tmp/" + parent
    return route.controlSocket == endpoint + "/worker.sock"
      && route.displaySocket == endpoint + "/vnc.sock"
  }

  func allowsHumanCapture(
    route: DisplayWorkerRoute, data: Data, status: WorkerResponse,
    intent: RuntimeIntent?, writerHeld: Bool
  ) -> Bool {
    guard validateRoute(route, data: data), status.vmID == route.vmID,
      status.sessionID == route.sessionID, status.state == 2, status.ownership == 0,
      status.backendActive, status.error == .none, !status.operationPending,
      let intent, intent.schemaVersion == 1, intent.state == .unsettled,
      intent.vmID == route.vmID, intent.sessionID == route.sessionID, writerHeld
    else { return false }
    return true
  }

  func permitsCaptureEpoch(
    requestedConnection: UUID, currentConnection: UUID,
    requestedEpoch: UUID, clientEpoch: UUID?, frameEpoch: UUID?,
    requestedCapture: UUID, currentCapture: UUID?
  ) -> Bool {
    canCaptureInput && requestedConnection == currentConnection
      && requestedEpoch == clientEpoch && requestedEpoch == frameEpoch
      && requestedCapture == currentCapture
  }

  private static func validRun(_ path: String) -> Bool {
    guard path.utf8.count <= 4096, path.hasPrefix(runParentPath + "/"),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return false }
    let name = String(path.dropFirst(runParentPath.utf8.count + 1))
    return name.range(of: "^run-[0-9a-f]{32}$", options: .regularExpression) != nil
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
