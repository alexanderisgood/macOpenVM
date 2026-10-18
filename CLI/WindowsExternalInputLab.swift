// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Foundation
import Qemu
import RuntimeIPC
import VMCore
import VMStorage

/// Bounded navigation of one actual approved owner. No lifecycle, text or frame export API.
enum WindowsExternalInputLab {
  static let runPath =
    WindowsExternalContinuationFiles.destinationPath
    + "/continuation-runs/run-55f33a355a41415c83dd74a4abdfe5e6"
  static let sessionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")
  static let routeSHA256 = "755241a71c04c4dc65bd2aa9653211b6b50f81c6a772628052d816438049b916"

  static func run(action: String, expectedFrame: String?, x: Int?, y: Int?, key: String?)
    async throws
  {
    let request = try WindowsExternalInputRequest(
      action: action, expectedFrame: expectedFrame, x: x, y: y, key: key)
    let directory = URL(
      fileURLWithPath: WindowsExternalContinuationFiles.destinationPath, isDirectory: true)
    let run = URL(fileURLWithPath: runPath, isDirectory: true)
    let routeURL = run.appendingPathComponent("swift-display-ready.json")
    try WindowsExternalFileIO.privateDirectory(run)
    let bytes = try WindowsExternalFileIO.readPrivate(
      routeURL, maximum: FlatDisplayRouteCodec.maximumBytes)
    let route = try FlatDisplayRouteCodec.decode(bytes, profile: .windowsExternalContinuation)
    guard windowsExternalDigest(bytes) == routeSHA256,
      route.vmID == WindowsExternalContinuationFiles.vmID,
      route.sessionID == sessionID, route.scope == WindowsExternalContinuationFiles.displayScope,
      route.controlSocket == "/private/tmp/mvo-win-external-55f33a355a41415c/worker.sock",
      route.displaySocket == "/private/tmp/mvo-win-external-55f33a355a41415c/vnc.sock"
    else { throw windowsExternalFailure() }
    try await verifyLive(route, directory: directory, routeURL: routeURL, bytes: bytes)
    let display = RFBClient(
      socketURL: URL(fileURLWithPath: route.displaySocket),
      expectedIdentity: RFBEndpointIdentity(
        parentDevice: route.parentDevice, parentInode: route.parentInode,
        socketDevice: route.socketDevice, socketInode: route.socketInode))
    do {
      try await display.connect()
      try await verifyLive(route, directory: directory, routeURL: routeURL, bytes: bytes)
      let frame = try await frameWithin(display)
      let hash = frameDigest(frame)
      guard frame.connectionEpoch == display.connectionEpoch,
        request.admitsFrame(hash: hash, size: frame.size)
      else { throw windowsExternalFailure() }
      try await verifyLive(route, directory: directory, routeURL: routeURL, bytes: bytes)
      switch request.operation {
      case .snapshot: break
      case .click(let x, let y):
        try await display.sendPointer(x: x, y: y, buttons: 1, frameSize: frame.size)
        try await display.sendPointer(x: x, y: y, buttons: 0, frameSize: frame.size)
      case .key(let symbol):
        try await display.sendKey(keySym: symbol, down: true)
        try await display.sendKey(keySym: symbol, down: false)
      }
      await display.releaseInput()
      await display.close()
      try await verifyLive(route, directory: directory, routeURL: routeURL, bytes: bytes)
      let result = Result(
        vmID: route.vmID, sessionID: route.sessionID, action: action,
        frameSHA256: hash, width: frame.size.width, height: frame.size.height)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try FileHandle.standardOutput.write(contentsOf: encoder.encode(result) + Data([10]))
    } catch {
      await display.releaseInput()
      await display.close()
      throw error
    }
  }

  private static func verifyLive(
    _ route: DisplayWorkerRoute, directory: URL, routeURL: URL, bytes: Data
  ) async throws {
    guard try WindowsExternalFileIO.readPrivate(routeURL, maximum: 4096) == bytes,
      let intent = try await VMFiles().readRuntimeIntent(in: directory), intent.state == .unsettled,
      intent.vmID == route.vmID, intent.sessionID == route.sessionID,
      await VMFiles().writerStatus(in: directory) == .held
    else { throw windowsExternalFailure() }
    let peer = WorkerIPCClient(
      socketURL: URL(fileURLWithPath: route.controlSocket), vmID: route.vmID,
      sessionID: route.sessionID)
    do {
      try await peer.connect()
      let status = try await peer.request(.status)
      await peer.close()
      guard status.vmID == route.vmID, status.sessionID == route.sessionID, status.state == 2,
        status.ownership == 0, status.backendActive, !status.operationPending, status.error == .none
      else { throw windowsExternalFailure() }
    } catch {
      await peer.close()
      throw error
    }
  }

  private static func frameWithin(_ display: RFBClient) async throws -> RFBFrame {
    try await withThrowingTaskGroup(of: RFBFrame.self) { group in
      group.addTask { try await display.nextFrame() }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw windowsExternalFailure()
      }
      defer { group.cancelAll() }
      guard let frame = try await group.next() else { throw windowsExternalFailure() }
      return frame
    }
  }
  private static func frameDigest(_ frame: RFBFrame) -> String {
    let header = Data(
      "macOpenVM public RFB frame v1\n\(frame.size.width) \(frame.size.height)\n".utf8)
    return SHA256.hash(data: header + frame.rgbaData).map { String(format: "%02x", $0) }.joined()
  }
  private struct Result: Encodable {
    let vmID: UUID, sessionID: UUID
    let action: String, frameSHA256: String
    let width: Int, height: Int
  }
}
