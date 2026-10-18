// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Qemu
import RuntimeIPC
import VMCore
import VMStorage

/// Explicit headless observer of the original no-OS display fixture. This never creates
/// a backend/writer, launches a worker or requests runtime shutdown.
@MainActor enum RfbObserverLab {
  static func run(directory: URL) async throws {
    let files = RfbObserverFiles()
    let route = try await files.admit(directory)
    let writer = try await files.verifyLive(directory, route: route)
    var peer: RFBClient?
    var frames: [RfbObserverFrame] = []
    var acknowledgements = 0
    var reconnected = false
    var finalSerialHash: String?
    var phase = RfbObserverPhase.initialStatus
    do {
      try await verifyStatus(route)
      phase = .claim
      try await files.claim(directory)
      var display = makeClient(route)
      peer = display
      phase = .initialDisplayConnect
      try await display.connect()

      phase = .firstReady
      let firstReady = try await waitSerial(
        files, directory, prefix: "mvo.display-input.ready stage=0 ",
        expression: readyExpression(stage: 0),
        timeout: .seconds(20))
      let firstMode = try appliedMode(firstReady, stage: 0)
      phase = .firstFrame
      frames.append(
        try await observe(display, stage: 0, width: firstMode.width, height: firstMode.height))
      phase = .firstKey
      try await send(
        display, symbol: 0x31, after: firstReady, absent: "mvo.display-input.ack stage=0 ")
      phase = .firstAcknowledgement
      _ = try await waitSerial(
        files, directory, prefix: "mvo.display-input.ack stage=0 ",
        expression: "^mvo\\.display-input\\.ack stage=0 key=1$")

      phase = .secondReady
      let secondReady = try await waitSerial(
        files, directory, prefix: "mvo.display-input.ready stage=1 ",
        expression: readyExpression(stage: 1))
      let secondMode = try appliedMode(secondReady, stage: 1)
      guard firstMode.number != secondMode.number, firstMode.width != secondMode.width,
        firstMode.height != secondMode.height
      else { throw observerFailure() }
      phase = .secondFrame
      frames.append(
        try await observe(display, stage: 1, width: secondMode.width, height: secondMode.height))
      phase = .secondKey
      try await send(
        display, symbol: 0x32, after: secondReady, absent: "mvo.display-input.ack stage=1 ")
      phase = .secondAcknowledgement
      _ = try await waitSerial(
        files, directory, prefix: "mvo.display-input.ack stage=1 ",
        expression: "^mvo\\.display-input\\.ack stage=1 key=2$")

      let previousEpoch = display.connectionEpoch
      phase = .reconnectDetach
      await display.releaseKeys()
      await display.close()
      phase = .reconnectWriter
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      phase = .reconnectStatus
      try await verifyStatus(route)
      display = makeClient(route)
      peer = display
      phase = .reconnectConnect
      try await display.connect()
      guard display.connectionEpoch != previousEpoch else { throw observerFailure() }
      phase = .reconnectFrame
      frames.append(
        try await observe(display, stage: 1, width: secondMode.width, height: secondMode.height))
      reconnected = true

      // The independently pinned EFI source declares this exact bounded sequence.
      for (index, symbol) in "11221122".utf8.enumerated() {
        phase = .repeatedReady
        let ready = try await waitSerial(
          files, directory, prefix: "mvo.display-input.key-ready index=\(index)",
          expression: "^mvo\\.display-input\\.key-ready index=\(index)$")
        phase = .repeatedKey
        try await send(
          display, symbol: UInt32(symbol), after: ready,
          absent: "mvo.display-input.key-ack index=\(index) ")
        phase = .repeatedAcknowledgement
        _ = try await waitSerial(
          files, directory, prefix: "mvo.display-input.key-ack index=\(index) ",
          expression: "^mvo\\.display-input\\.key-ack index=\(index) unicode=\(symbol) scan=0$")
        acknowledgements += 1
      }
      phase = .completion
      let completed = try await waitSerial(
        files, directory, prefix: "mvo.display-input.complete",
        expression: "^mvo\\.display-input\\.complete modes=2 keys=8$")
      try verifyComplete(completed, firstMode: firstMode, secondMode: secondMode)
      finalSerialHash = completed.digest
      phase = .finalWriter
      guard acknowledgements == 8, reconnected,
        try await files.verifyLive(directory, route: route) == writer
      else { throw observerFailure() }
      phase = .finalStatus
      try await verifyStatus(route)
      phase = .observerClose
      await display.releaseKeys()
      await display.close()
      phase = .record
      try await files.record(
        RfbObserverResult(
          status: "passed", vmID: route.vmID, sessionID: route.sessionID, frames: frames,
          actualAcknowledgements: acknowledgements, sameSessionWriterReconnectVerified: true,
          serialSHA256: finalSerialHash, failurePhase: nil, failureKind: nil), in: directory)
      print("Headless original RFB observer passed; visible window and Windows remain unverified.")
    } catch {
      // Cancellation/verification failure closes only observer connections. The caller's
      // separately authorized harness owns any later explicit worker stop.
      if let peer {
        await peer.releaseKeys()
        await peer.close()
      }
      try? await files.record(
        RfbObserverResult(
          status: "failed", vmID: route.vmID, sessionID: route.sessionID, frames: frames,
          actualAcknowledgements: acknowledgements,
          sameSessionWriterReconnectVerified: reconnected, serialSHA256: finalSerialHash,
          failurePhase: phase, failureKind: observerFailureKind(error)),
        in: directory)
      throw error
    }
  }

  private static func makeClient(_ route: DisplayWorkerRoute) -> RFBClient {
    RFBClient(
      socketURL: URL(fileURLWithPath: route.displaySocket),
      expectedIdentity: RFBEndpointIdentity(
        parentDevice: route.parentDevice, parentInode: route.parentInode,
        socketDevice: route.socketDevice, socketInode: route.socketInode))
  }

  private static func verifyStatus(_ route: DisplayWorkerRoute) async throws {
    // The worker's bounded idle timeout is shorter than EFI boot/milestone work.
    // Each observation therefore owns one fresh status-only connection.
    let control = WorkerIPCClient(
      socketURL: URL(fileURLWithPath: route.controlSocket), vmID: route.vmID,
      sessionID: route.sessionID)
    do {
      try await control.connect()
      let status = try await control.request(.status)
      guard status.backendActive, !status.operationPending, status.ownership == 0,
        status.state == 2, status.error == .none
      else { throw observerFailure() }
      await control.close()
    } catch {
      await control.close()
      throw error
    }
  }

  private static func send(
    _ peer: RFBClient, symbol: UInt32, after ready: RfbObserverSerial, absent prefix: String
  ) async throws {
    guard symbol == 0x31 || symbol == 0x32,
      ready.lines.filter({ $0 == "mvo.display-input.begin version=1" }).count == 1,
      !ready.lines.contains(where: {
        $0.hasPrefix(prefix) || $0.hasPrefix("mvo.display-input.complete")
      })
    else { throw observerFailure() }
    try Task.checkCancellation()
    try await peer.sendKey(keySym: symbol, down: true)
    try await peer.sendKey(keySym: symbol, down: false)
  }

  private static func waitSerial(
    _ files: RfbObserverFiles, _ directory: URL, prefix: String, expression: String,
    timeout: Duration = .seconds(5)
  ) async throws -> RfbObserverSerial {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      do {
        let snapshot = try await files.serial(directory)
        let rows = snapshot.lines.filter { $0.hasPrefix(prefix) }
        if !rows.isEmpty {
          guard rows.count == 1, rows[0].range(of: expression, options: .regularExpression) != nil
          else { throw observerFailure() }
          return snapshot
        }
      } catch let error as VMError where error.code == .busy {
        // The live serial writer can append during an observation; retry only the read.
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw observerFailure()
  }

  private static func readyExpression(stage: Int) -> String {
    "^mvo\\.display-input\\.ready stage=\(stage) (width=640 height=480|width=800 height=600) mode=([0-9]|[1-5][0-9]|6[0-3])$"
  }

  private static func appliedMode(_ serial: RfbObserverSerial, stage: Int) throws -> RfbObserverMode
  {
    let rows = serial.lines.filter { $0.hasPrefix("mvo.display-input.ready stage=\(stage) ") }
    guard rows.count == 1,
      rows[0].range(of: readyExpression(stage: stage), options: .regularExpression) != nil
    else { throw observerFailure() }
    let fields = rows[0].split(separator: " ")
    guard fields.count == 5, let width = Int(fields[2].dropFirst(6)),
      let height = Int(fields[3].dropFirst(7)), let number = Int(fields[4].dropFirst(5)),
      (width == 640 && height == 480) || (width == 800 && height == 600),
      (0...63).contains(number)
    else { throw observerFailure() }
    return RfbObserverMode(width: width, height: height, number: number)
  }

  private static func verifyComplete(
    _ serial: RfbObserverSerial, firstMode: RfbObserverMode, secondMode: RfbObserverMode
  ) throws {
    guard try appliedMode(serial, stage: 0) == firstMode,
      try appliedMode(serial, stage: 1) == secondMode
    else { throw observerFailure() }
    var expressions = [
      "^mvo\\.display-input\\.begin version=1$",
      readyExpression(stage: 0),
      "^mvo\\.display-input\\.ack stage=0 key=1$",
      readyExpression(stage: 1),
      "^mvo\\.display-input\\.ack stage=1 key=2$",
    ]
    for (index, symbol) in "11221122".utf8.enumerated() {
      expressions.append("^mvo\\.display-input\\.key-ready index=\(index)$")
      expressions.append("^mvo\\.display-input\\.key-ack index=\(index) unicode=\(symbol) scan=0$")
    }
    expressions.append("^mvo\\.display-input\\.complete modes=2 keys=8$")
    let rows = serial.lines.filter { $0.hasPrefix("mvo.display-input.") }
    guard rows.count == expressions.count,
      zip(rows, expressions).allSatisfy({ $0.range(of: $1, options: .regularExpression) != nil })
    else { throw observerFailure() }
  }

  private static func frameWithin(_ peer: RFBClient) async throws -> RFBFrame {
    try await withThrowingTaskGroup(of: RFBFrame.self) { group in
      group.addTask { try await peer.nextFrame() }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw observerFailure()
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw observerFailure() }
      return first
    }
  }

  private static func observe(_ peer: RFBClient, stage: Int, width: Int, height: Int) async throws
    -> RfbObserverFrame
  {
    // Independent semantic RGB palette read from the original EFI BLT source (B,G,R,0).
    let palette: [[UInt8]] = [
      [240, 32, 16, 255], [32, 224, 64, 255], [16, 64, 240, 255], [224, 192, 32, 255],
    ]
    for _ in 0..<8 {
      let frame = try await frameWithin(peer)
      guard frame.connectionEpoch == peer.connectionEpoch, frame.sequence > 0 else {
        throw observerFailure()
      }
      guard frame.size.width == width, frame.size.height == height else { continue }
      guard frame.rgbaData.count == width * height * 4 else { throw observerFailure() }
      let matched = frame.rgbaData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        for quadrant in 0..<4 {
          let centerX = (quadrant & 1) == 0 ? width / 4 : width * 3 / 4
          let centerY = (quadrant & 2) == 0 ? height / 4 : height * 3 / 4
          let expected = palette[(quadrant + stage) % 4]
          for y in centerY - 8..<centerY + 8 {
            for x in centerX - 8..<centerX + 8 {
              let offset = (y * width + x) * 4
              for channel in 0..<4 where bytes[offset + channel] != expected[channel] {
                return false
              }
            }
          }
        }
        return true
      }
      // Painting and the serial-ready flush need not reach the viewer together.
      // Acceptance still requires the exact palette within the bounded frame attempts.
      guard matched else { continue }
      return RfbObserverFrame(
        stage: stage, width: width, height: height, connectionEpoch: frame.connectionEpoch,
        sequence: frame.sequence, rgbaSHA256: observerDigest(frame.rgbaData), sampledPixels: 1024)
    }
    throw observerFailure()
  }
}

private struct RfbObserverFrame: Encodable, Sendable {
  let stage: Int
  let width: Int
  let height: Int
  let connectionEpoch: UUID
  let sequence: UInt64
  let rgbaSHA256: String
  let sampledPixels: Int
}

private struct RfbObserverResult: Encodable, Sendable {
  let schemaVersion = 1
  let scope = "original-headless-rfb-observer"
  let status: String
  let vmID: UUID
  let sessionID: UUID
  let frames: [RfbObserverFrame]
  let actualAcknowledgements: Int
  let sameSessionWriterReconnectVerified: Bool
  let serialSHA256: String?
  let failurePhase: RfbObserverPhase?
  let failureKind: String?
  let sourceSHA256 = "cee0e238cc8ca45392175a797fad9f41c2c081ee32c25472b99d183bd7d6f40b"
  let nativeVisibleWindowVerified = false
  let windowsCompatibilityVerified = false
  let retinaVerified = false
  let hostRequestedGuestResizeVerified = false
  let pointerForwardingVerified = false
  let fullKeyboardAcceptanceVerified = false
  let guestCleanShutdownVerified = false
  let runtimeIntentSettled = false
}

private enum RfbObserverPhase: String, Encodable, Sendable {
  case initialStatus, claim, initialDisplayConnect
  case firstReady, firstFrame, firstKey, firstAcknowledgement
  case secondReady, secondFrame, secondKey, secondAcknowledgement
  case reconnectDetach, reconnectWriter, reconnectStatus, reconnectConnect, reconnectFrame
  case repeatedReady, repeatedKey, repeatedAcknowledgement
  case completion, finalWriter, finalStatus, observerClose, record
}

private struct RfbObserverSerial: Sendable {
  let lines: [String]
  let digest: String
}

private struct RfbObserverMode: Equatable, Sendable {
  let width: Int
  let height: Int
  let number: Int
}

private struct RfbObserverWriter: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
}

private actor RfbObserverFiles {
  private let files = VMFiles()
  private var selectedIdentity: RfbObserverWriter?
  private var continuationRun: URL?
  private var continuationIdentity: RfbObserverWriter?
  private var continuationInputHash: String?

  func admit(_ directory: URL, windowsInstaller: Bool = false) async throws -> DisplayWorkerRoute {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    guard directory.isFileURL, directory.host == nil || directory.host == "",
      directory.path == directory.standardizedFileURL.path,
      directory.deletingLastPathComponent().path == project.appendingPathComponent(".lab").path
    else { throw observerFailure() }
    try await LabRuntimeFiles().validateSelection(directory)
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else { throw observerFailure() }
    selectedIdentity = RfbObserverWriter(device: info.st_dev, inode: info.st_ino)
    let input = try JSONDecoder().decode(
      LabRuntimeInput.self,
      from: read(
        directory.appendingPathComponent("swift-runtime-input.json"), limit: 65_536, mode: 0o600))
    guard input.schemaVersion == 1,
      input.scope
        == (windowsInstaller
          ? "approved-offline-windows-installer-fixture"
          : "new-owned-offline-no-os-display-fixture"),
      !input.guestLaunched, !input.windowsCompatibilityVerified
    else { throw observerFailure() }
    if !windowsInstaller {
      guard try await LabRuntimeFiles().verifyReadonly(directory, profile: .display) else {
        throw observerFailure()
      }
      let source = try read(
        project.appendingPathComponent(
          "Tests/EFI/MacOpenVMLabPkg/DisplayInputProbe/DisplayInputProbe.c"),
        limit: 32_768, mode: nil)
      guard
        observerDigest(source) == "cee0e238cc8ca45392175a797fad9f41c2c081ee32c25472b99d183bd7d6f40b"
      else {
        throw observerFailure()
      }
    }
    let route = try FlatDisplayRouteCodec.decode(
      read(directory.appendingPathComponent("swift-display-ready.json"), limit: 4096, mode: 0o600))
    let parent = URL(fileURLWithPath: route.controlSocket).deletingLastPathComponent()
    guard
      route.scope
        == (windowsInstaller
          ? "approved-windows-installer-display-route" : "original-diskless-display-route"),
      parent.path.range(
        of: windowsInstaller
          ? "^/private/tmp/mvo-win-[0-9a-f]{16}$" : "^/private/tmp/mvo-efi-[0-9a-f]{16}$",
        options: .regularExpression)
        != nil,
      route.controlSocket == parent.appendingPathComponent("worker.sock").path,
      route.displaySocket == parent.appendingPathComponent("vnc.sock").path,
      input.qmpSocket == parent.appendingPathComponent("qmp.sock").path,
      input.tpmSocket == parent.appendingPathComponent("tpm.sock").path
    else { throw observerFailure() }
    return route
  }

  func admitContinuation(_ directory: URL, run: URL) async throws -> DisplayWorkerRoute {
    // Existing immutable offline records remain the approved previous-session anchor.
    let previous = try await admit(directory, windowsInstaller: true)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let staging = project.appendingPathComponent(
      ".lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0")
    guard run.path == run.standardizedFileURL.path, run.deletingLastPathComponent() == staging,
      run.lastPathComponent.range(of: "^run-[0-9a-f]{32}$", options: .regularExpression) != nil
    else { throw observerFailure() }
    try await LabRuntimeFiles().checkAncestry(run)
    try await LabRuntimeFiles().checkDirectory(run)
    var info = stat()
    guard lstat(run.path, &info) == 0 else { throw observerFailure() }
    let planData = try read(staging.appendingPathComponent("plan.json"), limit: 65_536, mode: 0o600)
    guard
      observerDigest(planData) == "15ddb48ed4b2153957f48fc21ebadcd324800c40ef894f5e27c1417c3fb2ab12"
    else {
      throw observerFailure()
    }
    let plan = try JSONDecoder().decode(ContinuationDisplayPlan.self, from: planData)
    let approval = try networkControlApproval(
      directory, at: staging.appendingPathComponent("approval.json"), route: previous)
    guard approval.vmID == plan.vmID, approval.previousSessionID == plan.previousSessionID,
      let reviewed = approval.consoleReviewedSHA256
    else { throw observerFailure() }
    try approval.requireControl(action: "normal-shutdown", expectedFrame: reviewed)
    let inputData = try read(run.appendingPathComponent("input.json"), limit: 65_536, mode: 0o600)
    let input = try JSONDecoder().decode(LabRuntimeInput.self, from: inputData)
    let route = try FlatDisplayRouteCodec.decode(
      read(run.appendingPathComponent("swift-display-ready.json"), limit: 4096, mode: 0o600),
      profile: .windowsNetworkContinuation)
    let parent = URL(fileURLWithPath: route.controlSocket).deletingLastPathComponent()
    let expected = await WindowsContinuationFiles().rebound(plan.proposedInput, to: parent)
    guard route.vmID == plan.vmID, route.sessionID != plan.previousSessionID,
      parent.path.range(of: "^/private/tmp/mvo-win-net-[0-9a-f]{16}$", options: .regularExpression)
        != nil,
      route.controlSocket == parent.appendingPathComponent("worker.sock").path,
      route.displaySocket == parent.appendingPathComponent("vnc.sock").path,
      input == expected
    else { throw observerFailure() }
    continuationRun = run
    continuationIdentity = RfbObserverWriter(device: info.st_dev, inode: info.st_ino)
    continuationInputHash = observerDigest(inputData)
    return route
  }

  func verifyLive(_ directory: URL, route: DisplayWorkerRoute) async throws -> RfbObserverWriter {
    try selectedDirectory(directory)
    if let run = continuationRun {
      var info = stat()
      guard lstat(run.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
        continuationIdentity == RfbObserverWriter(device: info.st_dev, inode: info.st_ino),
        continuationInputHash
          == observerDigest(
            try read(run.appendingPathComponent("input.json"), limit: 65_536, mode: 0o600))
      else { throw observerFailure() }
    }
    let current = try FlatDisplayRouteCodec.decode(
      read(
        (continuationRun ?? directory).appendingPathComponent("swift-display-ready.json"),
        limit: 4096, mode: 0o600),
      profile: continuationRun == nil ? .existing : .windowsNetworkContinuation)
    guard current == route, let intent = try await files.readRuntimeIntent(in: directory),
      intent.state == .unsettled, intent.vmID == route.vmID, intent.sessionID == route.sessionID
    else { throw observerFailure() }
    let path = directory.appendingPathComponent("writer.lock").path
    var before = stat()
    var after = stat()
    guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
      await files.writerStatus(in: directory) == .held,
      lstat(path, &after) == 0, stable(before, after)
    else { throw observerFailure() }
    try selectedDirectory(directory)
    return RfbObserverWriter(device: before.st_dev, inode: before.st_ino)
  }

  func claim(_ directory: URL) async throws {
    try selectedDirectory(directory)
    try await LabRuntimeFiles().save(
      Data("original-headless-rfb-observer\n".utf8),
      at: directory.appendingPathComponent("swift-rfb-observer.claim"))
    try selectedDirectory(directory)
  }

  func serial(_ directory: URL) throws -> RfbObserverSerial {
    try selectedDirectory(directory)
    let data = try read(
      directory.appendingPathComponent("swift-qemu-stdout.log"), limit: 2_097_152, mode: 0o600)
    guard let raw = String(data: data, encoding: .utf8) else { throw observerFailure() }
    let clean = raw.replacingOccurrences(
      of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression
    ).replacingOccurrences(of: "\r", with: "")
    // UART drains can end a stable snapshot partway through a row. Every probe
    // milestone ends with a newline, so the unfinished suffix is never evidence.
    let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
      .dropLast().filter { !$0.isEmpty }.map(String.init)
    guard !lines.contains(where: { $0.contains("mvo.display-input.failure") }),
      lines.filter({ $0 == "mvo.display-input.begin version=1" }).count <= 1
    else { throw observerFailure() }
    return RfbObserverSerial(lines: lines, digest: observerDigest(data))
  }

  func record(_ result: RfbObserverResult, in directory: URL) async throws {
    try selectedDirectory(directory)
    let encoded = try JSONEncoder().encode(result)
    guard encoded.count <= 16_384 else { throw observerFailure() }
    try await LabRuntimeFiles().save(
      result, at: directory.appendingPathComponent("swift-rfb-observer-result.json"))
    try selectedDirectory(directory)
  }

  private func selectedDirectory(_ directory: URL) throws {
    var info = stat()
    guard let selectedIdentity, lstat(directory.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
      selectedIdentity == RfbObserverWriter(device: info.st_dev, inode: info.st_ino)
    else { throw observerFailure() }
  }

  func requireInstallationApproval(_ directory: URL) throws {
    try selectedDirectory(directory)
    let value =
      try JSONSerialization.jsonObject(
        with: read(directory.appendingPathComponent("recipe.json"), limit: 65_536, mode: 0o600))
      as? [String: Any]
    guard value?["humanApprovedIsolatedBoot"] as? Bool == true,
      value?["licenseAcceptanceAuthorized"] as? Bool == true,
      value?["credentialsAuthorized"] as? Bool == false
    else { throw observerFailure() }
  }

  func networkControlApproval(
    _ directory: URL, at approvalURL: URL, route: DisplayWorkerRoute
  ) throws -> WindowsNetworkLabApproval {
    try selectedDirectory(directory)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let parent = approvalURL.deletingLastPathComponent()
    var info = stat()
    guard approvalURL.isFileURL, approvalURL.path == approvalURL.standardizedFileURL.path,
      approvalURL.lastPathComponent == "approval.json",
      parent.deletingLastPathComponent().path == project.appendingPathComponent(".lab").path,
      parent.lastPathComponent.range(
        of: "^windows-network-adoption-[0-9a-f]{32}$", options: .regularExpression) != nil,
      lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else { throw observerFailure() }
    let plan = try read(parent.appendingPathComponent("plan.json"), limit: 65_536, mode: 0o600)
    let object = try JSONSerialization.jsonObject(with: plan) as? [String: Any]
    let bytes = withUnsafeBytes(of: route.vmID.uuid) { Array($0.prefix(5)) }
    let mac = ([UInt8(0x02)] + bytes).map { String(format: "%02x", $0) }.joined(separator: ":")
    guard object?["schemaVersion"] as? Int == 1,
      object?["scope"] as? String == "prepared-same-vm-windows-network-lab",
      object?["directory"] as? String == directory.path,
      (object?["vmID"] as? String).flatMap(UUID.init(uuidString:)) == route.vmID,
      (object?["previousSessionID"] as? String).flatMap(UUID.init(uuidString:)) == route.sessionID,
      object?["macAddress"] as? String == mac,
      object?["originalInputSHA256"] as? String
        == observerDigest(
          try read(
            directory.appendingPathComponent("swift-runtime-input.json"), limit: 65_536, mode: 0o600
          ))
    else { throw observerFailure() }
    return try WindowsNetworkLabApproval.validate(
      data: read(approvalURL, limit: 32_768, mode: 0o600), directory: directory.path,
      vmID: route.vmID, sessionID: route.sessionID, planSHA256: observerDigest(plan),
      macAddress: mac)
  }

  private func read(_ url: URL, limit: Int, mode: mode_t?) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw observerFailure() }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
      before.st_size >= 0, before.st_size <= limit,
      mode == nil || before.st_mode & 0o7777 == mode
    else { throw observerFailure() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var data = Data()
    while let chunk = try handle.read(upToCount: min(65_536, limit - data.count + 1)),
      !chunk.isEmpty
    {
      data.append(chunk)
      guard data.count <= limit else { throw observerFailure() }
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
      stable(before, after), stable(after, named), data.count == before.st_size
    else {
      throw VMError(
        .busy, "Observer metadata changed during its read.",
        recovery: "Retry only the bounded observation.")
    }
    return data
  }

  private func stable(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev && first.st_ino == second.st_ino
      && first.st_mode == second.st_mode && first.st_uid == second.st_uid
      && first.st_nlink == second.st_nlink && first.st_size == second.st_size
      && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
      && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
      && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
      && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
  }
}

private func observerDigest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func observerFailure() -> VMError {
  VMError(
    .backendFailure, "The original headless display observation could not be confirmed.",
    recovery:
      "Preserve its fixture; observer failure never authorizes runtime shutdown or replacement.")
}

/// Fixed app-owned classifications only: no error description or associated data.
private func observerFailureKind(_ error: any Error) -> String {
  if let error = error as? RFBClientError {
    switch error {
    case .unsafeSocket: return "rfb.unsafeSocket"
    case .invalidTimeout: return "rfb.invalidTimeout"
    case .alreadyConnected: return "rfb.alreadyConnected"
    case .notConnected: return "rfb.notConnected"
    case .closed: return "rfb.closed"
    case .busy: return "rfb.busy"
    case .malformedMessage: return "rfb.malformedMessage"
    case .unsupportedMessage: return "rfb.unsupportedMessage"
    case .limitExceeded: return "rfb.limitExceeded"
    case .unexpectedMessage: return "rfb.unexpectedMessage"
    case .disconnected: return "rfb.disconnected"
    case .deadlineExceeded: return "rfb.deadlineExceeded"
    case .unsupportedKey: return "rfb.unsupportedKey"
    case .invalidPointer: return "rfb.invalidPointer"
    case .pointerModeChanged: return "rfb.pointerModeChanged"
    case .identifierExhausted: return "rfb.identifierExhausted"
    case .posix: return "rfb.posix"
    }
  }
  if let error = error as? WorkerIPCError {
    switch error {
    case .malformedFrame: return "ipc.malformedFrame"
    case .limitExceeded: return "ipc.limitExceeded"
    case .unexpectedReply: return "ipc.unexpectedReply"
    case .statusRequired: return "ipc.statusRequired"
    case .invalidTimeout: return "ipc.invalidTimeout"
    case .unsafeSocket: return "ipc.unsafeSocket"
    case .alreadyConnected: return "ipc.alreadyConnected"
    case .notConnected: return "ipc.notConnected"
    case .closed: return "ipc.closed"
    case .busy: return "ipc.busy"
    case .deadlineExceeded: return "ipc.deadlineExceeded"
    case .disconnected: return "ipc.disconnected"
    case .posix: return "ipc.posix"
    }
  }
  if let error = error as? VMError { return "vm.\(error.code.rawValue)" }
  if error is CancellationError { return "cancelled" }
  return "unknown"
}

extension RfbObserverLab {
  /// Separate continuation route, with screenshot-bound click/navigation only.
  /// This observes the actual existing owner; it never creates or controls its lifecycle.
  static func windowsNetworkContinuationControl(
    directory: URL, runDirectory: URL, action: String, expectedFrame: String?, x: Int?, y: Int?,
    key: String?
  ) async throws {
    let navigation: [String: UInt32] = [
      "tab": 0xff09, "return": 0xff0d, "space": 0x20, "escape": 0xff1b,
      "up": 0xff52, "down": 0xff54, "home": 0xff50, "end": 0xff57,
      "pageup": 0xff55, "pagedown": 0xff56,
    ]
    guard ["snapshot", "click", "key"].contains(action),
      action == "click" ? x != nil && y != nil && key == nil : x == nil && y == nil,
      action == "key" ? key.flatMap({ navigation[$0] }) != nil : key == nil,
      action == "snapshot"
        ? expectedFrame == nil
        : expectedFrame?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw observerFailure() }
    let files = RfbObserverFiles()
    let route = try await files.admitContinuation(directory, run: runDirectory)
    try await files.requireInstallationApproval(directory)
    let writer = try await files.verifyLive(directory, route: route)
    try await verifyStatus(route)
    var display = makeClient(route)
    let prefix = "swift-network-control-\(UUID().uuidString.lowercased())"
    do {
      try await display.connect()
      let before = try await frameWithin(display)
      guard before.connectionEpoch == display.connectionEpoch,
        action == "snapshot" || observerDigest(ppm(before)) == expectedFrame
      else { throw observerFailure() }
      try await LabRuntimeFiles().saveBytes(
        ppm(before), at: runDirectory.appendingPathComponent(prefix + "-before.ppm"))
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      try await verifyStatus(route)
      if action == "click", let x, let y {
        guard x >= 0, y >= 0, x < before.size.width, y < before.size.height,
          let pointerX = UInt16(exactly: x), let pointerY = UInt16(exactly: y)
        else { throw observerFailure() }
        try await display.sendPointer(x: pointerX, y: pointerY, buttons: 1, frameSize: before.size)
        try await display.sendPointer(x: pointerX, y: pointerY, buttons: 0, frameSize: before.size)
      } else if action == "key", let key, let symbol = navigation[key] {
        try await display.sendKey(keySym: symbol, down: true)
        try await display.sendKey(keySym: symbol, down: false)
      }
      if action != "snapshot" { try await Task.sleep(for: .milliseconds(500)) }
      await display.releaseInput()
      await display.close()
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      try await verifyStatus(route)
      display = makeClient(route)
      try await display.connect()
      let after = try await frameWithin(display)
      let image = prefix + "-after.ppm"
      try await LabRuntimeFiles().saveBytes(
        ppm(after), at: runDirectory.appendingPathComponent(image))
      await display.close()
      try await verifyStatus(route)
      let record = WindowsNetworkControlRecord(
        vmID: route.vmID, sessionID: route.sessionID,
        action: action, x: x, y: y, key: key, beforeSHA256: observerDigest(ppm(before)),
        afterSHA256: observerDigest(ppm(after)), image: image, width: after.size.width,
        height: after.size.height)
      try await LabRuntimeFiles().save(
        record, at: runDirectory.appendingPathComponent(prefix + ".json"))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try FileHandle.standardOutput.write(contentsOf: encoder.encode(record))
      try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    } catch {
      await display.releaseInput()
      await display.close()
      throw error
    }
  }

  /// Two explicitly approved guest inputs only. A completed RFB write never establishes shutdown.
  static func windowsNetworkShutdownControl(
    directory: URL, approvalURL: URL, action: String, expectedFrame: String
  ) async throws {
    let files = RfbObserverFiles()
    let route = try await files.admit(directory, windowsInstaller: true)
    try await files.requireInstallationApproval(directory)
    let approval = try await files.networkControlApproval(directory, at: approvalURL, route: route)
    try approval.requireControl(action: action, expectedFrame: expectedFrame)
    let writer = try await files.verifyLive(directory, route: route)
    try await verifyStatus(route)
    var display = makeClient(route)
    let prefix = "swift-network-input-\(UUID().uuidString.lowercased())"
    do {
      try await display.connect()
      let before = try await frameWithin(display)
      guard before.connectionEpoch == display.connectionEpoch,
        observerDigest(ppm(before)) == expectedFrame
      else { throw observerFailure() }
      try await LabRuntimeFiles().saveBytes(
        ppm(before), at: directory.appendingPathComponent(prefix + "-before.ppm"))
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      try await verifyStatus(route)
      var image: String?
      if action == "open-console" {
        try await display.sendKey(keySym: 0xffe1, down: true)
        try await display.sendKey(keySym: 0xffc7, down: true)
        try await display.sendKey(keySym: 0xffc7, down: false)
        try await display.sendKey(keySym: 0xffe1, down: false)
        await display.releaseInput()
        await display.close()
        try await Task.sleep(for: .milliseconds(500))
        guard try await files.verifyLive(directory, route: route) == writer else {
          throw observerFailure()
        }
        try await verifyStatus(route)
        display = makeClient(route)
        try await display.connect()
        let after = try await frameWithin(display)
        let afterImage = prefix + "-after.ppm"
        image = afterImage
        try await LabRuntimeFiles().saveBytes(
          ppm(after), at: directory.appendingPathComponent(afterImage))
      } else {
        // Exact, reviewed normal OS command. No caller text, registry edits or bypass commands.
        for byte in "shutdown /s /t 0".utf8 {
          try await display.sendKey(keySym: UInt32(byte), down: true)
          try await display.sendKey(keySym: UInt32(byte), down: false)
        }
        try await display.sendKey(keySym: 0xff0d, down: true)
        try await display.sendKey(keySym: 0xff0d, down: false)
      }
      await display.releaseInput()
      await display.close()
      let record = WindowsNetworkInputRecord(
        vmID: route.vmID, sessionID: route.sessionID, action: action,
        reviewedFrameSHA256: expectedFrame, inputSequenceCompleted: true,
        fixedCommand: action == "normal-shutdown" ? "shutdown /s /t 0" : nil, image: image)
      try await LabRuntimeFiles().save(
        record, at: directory.appendingPathComponent(prefix + ".json"))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try FileHandle.standardOutput.write(contentsOf: encoder.encode(record))
      try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    } catch {
      await display.releaseInput()
      await display.close()
      throw error
    }
  }

  /// Explicit controls for the approved fresh installation. Only guest pixels and
  /// navigation keys are addressed; host focus, runtime ownership and credentials
  /// are outside this connection. Each action captures its result for visual review.
  static func windowsInstallationControl(
    directory: URL, action: String, x: Int?, y: Int?, key: String?
  ) async throws {
    let navigation: [String: UInt32] = [
      "tab": 0xff09, "return": 0xff0d, "space": 0x20,
      "escape": 0xff1b, "up": 0xff52, "down": 0xff54,
      "home": 0xff50, "end": 0xff57, "pageup": 0xff55, "pagedown": 0xff56,
    ]
    guard action == "snapshot" || action == "click" || action == "key",
      action == "click" ? x != nil && y != nil && key == nil : x == nil && y == nil,
      action == "key" ? key.flatMap({ navigation[$0] }) != nil : key == nil
    else { throw observerFailure() }
    let files = RfbObserverFiles()
    let route = try await files.admit(directory, windowsInstaller: true)
    try await files.requireInstallationApproval(directory)
    let writer = try await files.verifyLive(directory, route: route)
    try await verifyStatus(route)
    var display = makeClient(route)
    do {
      try await display.connect()
      let before = try await frameWithin(display)
      guard before.connectionEpoch == display.connectionEpoch,
        before.size.width > 0, before.size.height > 0,
        before.rgbaData.count == before.size.width * before.size.height * 4
      else { throw observerFailure() }
      let token = UUID().uuidString.lowercased()
      let prefix = "swift-installation-control-\(token)"
      try await LabRuntimeFiles().saveBytes(
        ppm(before), at: directory.appendingPathComponent(prefix + "-before.ppm"))
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      try await verifyStatus(route)
      if action == "click", let x, let y {
        guard x >= 0, y >= 0, x < before.size.width, y < before.size.height,
          let pointerX = UInt16(exactly: x), let pointerY = UInt16(exactly: y)
        else {
          throw observerFailure()
        }
        try await display.sendPointer(x: pointerX, y: pointerY, buttons: 1, frameSize: before.size)
        try await display.sendPointer(x: pointerX, y: pointerY, buttons: 0, frameSize: before.size)
      } else if action == "key", let key, let symbol = navigation[key] {
        try await display.sendKey(keySym: symbol, down: true)
        try await display.sendKey(keySym: symbol, down: false)
      }
      if action != "snapshot" { try await Task.sleep(for: .milliseconds(500)) }
      await display.releaseInput()
      await display.close()
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      try await verifyStatus(route)
      display = makeClient(route)
      try await display.connect()
      let after = try await frameWithin(display)
      let image = prefix + "-after.ppm"
      try await LabRuntimeFiles().saveBytes(ppm(after), at: directory.appendingPathComponent(image))
      await display.close()
      try await verifyStatus(route)
      let record = WindowsInstallationControlRecord(
        vmID: route.vmID, sessionID: route.sessionID, action: action, x: x, y: y, key: key,
        beforeSHA256: observerDigest(ppm(before)), afterSHA256: observerDigest(ppm(after)),
        image: image, width: after.size.width, height: after.size.height)
      try await LabRuntimeFiles().save(
        record, at: directory.appendingPathComponent(prefix + ".json"))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try FileHandle.standardOutput.write(contentsOf: encoder.encode(record))
      try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    } catch {
      await display.releaseInput()
      await display.close()
      throw error
    }
  }

  /// Explicit, individually reviewed setup-list actions. No Next, install or terms action.
  /// A full framebuffer equality check prevents input into an unreviewed guest screen.
  static func windowsInstallerInput(directory: URL, action: String, expectedFrame: String)
    async throws
  {
    guard ["open-format-list", "scroll-format-list", "close-format-list"].contains(action),
      expectedFrame.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw observerFailure() }
    let files = RfbObserverFiles()
    let route = try await files.admit(directory, windowsInstaller: true)
    let writer = try await files.verifyLive(directory, route: route)
    try await verifyStatus(route)
    var display = makeClient(route)
    do {
      try await display.connect()
      let before = try await frameWithin(display)
      guard before.size == PixelSize(width: 800, height: 600),
        observerDigest(ppm(before)) == expectedFrame
      else {
        let snapshot = "swift-input-mismatch-\(UUID().uuidString.lowercased()).ppm"
        try await LabRuntimeFiles().saveBytes(
          ppm(before), at: directory.appendingPathComponent(snapshot))
        throw VMError(
          .invalidConfiguration,
          "The live installer frame differs from the reviewed frame; no input was sent.",
          recovery: "Inspect \(snapshot) in the fixture before selecting another fixed action.")
      }
      try await LabRuntimeFiles().saveBytes(
        Data(expectedFrame.utf8),
        at: directory.appendingPathComponent("swift-input-\(action).claim"))
      switch action {
      case "open-format-list":
        try await display.sendPointer(x: 568, y: 226, buttons: 1, frameSize: before.size)
        try await display.sendPointer(x: 568, y: 226, buttons: 0, frameSize: before.size)
      case "scroll-format-list":
        try await display.sendScroll(x: 470, y: 290, steps: -3, frameSize: before.size)
      case "close-format-list":
        try await display.sendKey(keySym: 0xff1b, down: true)
        try await display.sendKey(keySym: 0xff1b, down: false)
      default: throw observerFailure()
      }
      // Reconnect for a full snapshot instead of treating the first incremental
      // update or a successful input write as guest acceptance.
      try await Task.sleep(for: .milliseconds(500))
      await display.releaseInput()
      await display.close()
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      try await verifyStatus(route)
      display = makeClient(route)
      try await display.connect()
      let after = try await frameWithin(display)
      guard after.size == before.size else { throw observerFailure() }
      let captured = ppm(after)
      try await LabRuntimeFiles().saveBytes(
        captured, at: directory.appendingPathComponent("swift-input-\(action).ppm"))
      await display.close()
      try await verifyStatus(route)
      try await LabRuntimeFiles().save(
        WindowsInstallerInputRecord(
          vmID: route.vmID, sessionID: route.sessionID, action: action,
          beforeSHA256: expectedFrame, afterSHA256: observerDigest(captured)),
        at: directory.appendingPathComponent("swift-input-\(action).json"))
      print("Fixed installer input sent; saved framebuffer requires visual review.")
    } catch {
      await display.releaseInput()
      await display.close()
      throw error
    }
  }

  /// One Space only after exact live boot-prompt pixels. No installer interaction.
  static func bootWindowsInstaller(directory: URL) async throws {
    let files = RfbObserverFiles()
    let route = try await files.admit(directory, windowsInstaller: true)
    let writer = try await files.verifyLive(directory, route: route)
    try await verifyStatus(route)
    var display = makeClient(route)
    do {
      try await display.connect()
      let prompt = try await withThrowingTaskGroup(of: RFBFrame.self) { group in
        group.addTask { [display] in
          while true {
            let frame = try await display.nextFrame()
            if matchesWindowsBootPrompt(frame) { return frame }
          }
        }
        group.addTask {
          try await Task.sleep(for: .seconds(20))
          throw observerFailure()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw observerFailure() }
        return first
      }
      try await LabRuntimeFiles().saveBytes(
        ppm(prompt), at: directory.appendingPathComponent("swift-boot-prompt.ppm"))
      try await display.sendKey(keySym: 32, down: true)
      try await Task.sleep(for: .milliseconds(100))
      try await display.sendKey(keySym: 32, down: false)
      await display.close()
      print("Matched live Windows boot prompt; sent one Space through native RFB.")
      try await Task.sleep(for: .seconds(35))
      guard try await files.verifyLive(directory, route: route) == writer else {
        throw observerFailure()
      }
      try await verifyStatus(route)
      display = makeClient(route)
      try await display.connect()
      let frame = try await frameWithin(display)
      try await LabRuntimeFiles().saveBytes(
        ppm(frame), at: directory.appendingPathComponent("swift-installer-frame.ppm"))
      await display.close()
      try await verifyStatus(route)
      try await LabRuntimeFiles().save(
        WindowsInstallerFrameRecord(
          scope: "approved-native-rfb-boot-prompt-and-frame-observation",
          vmID: route.vmID, sessionID: route.sessionID, promptSHA256: observerDigest(ppm(prompt)),
          frameSHA256: observerDigest(ppm(frame)), width: frame.size.width,
          height: frame.size.height,
          sameSessionWriterReconnectVerified: true, licenseAccepted: false, windowsInstalled: false),
        at: directory.appendingPathComponent("swift-installer-observer-result.json"))
    } catch {
      await display.releaseKeys()
      await display.close()
      throw error
    }
  }

  nonisolated private static func matchesWindowsBootPrompt(_ frame: RFBFrame) -> Bool {
    guard frame.size.width == 800, frame.size.height == 600,
      frame.rgbaData.count == 800 * 600 * 4
    else { return false }
    var prefix = Data()
    for y in 0..<24 {
      for x in 0..<260 {
        let offset = (y * 800 + x) * 4
        prefix.append(frame.rgbaData[offset..<(offset + 3)])
      }
    }
    guard
      observerDigest(prefix) == "8ee6493d8bf3c7a55a45e22bdebc902c046141602f5c7a1967f9f822058060ba"
    else { return false }
    for offset in stride(from: 800 * 30 * 4, to: frame.rgbaData.count, by: 4) {
      if frame.rgbaData[offset] != 0 || frame.rgbaData[offset + 1] != 0
        || frame.rgbaData[offset + 2] != 0
      {
        return false
      }
    }
    return true
  }

  nonisolated private static func ppm(_ frame: RFBFrame) -> Data {
    var result = Data("P6\n\(frame.size.width) \(frame.size.height)\n255\n".utf8)
    result.reserveCapacity(frame.size.width * frame.size.height * 3 + 80)
    for offset in stride(from: 0, to: frame.rgbaData.count, by: 4) {
      result.append(frame.rgbaData[offset..<(offset + 3)])
    }
    return result
  }
}

private struct WindowsInstallerFrameRecord: Encodable {
  let scope: String
  let vmID: UUID
  let sessionID: UUID
  let promptSHA256: String
  let frameSHA256: String
  let width: Int
  let height: Int
  let sameSessionWriterReconnectVerified: Bool
  let licenseAccepted: Bool
  let windowsInstalled: Bool
}

private struct WindowsInstallationControlRecord: Encodable, Sendable {
  let scope = "approved-fresh-windows-installation-input"
  let vmID: UUID
  let sessionID: UUID
  let action: String
  let x: Int?
  let y: Int?
  let key: String?
  let beforeSHA256: String
  let afterSHA256: String
  let image: String
  let width: Int
  let height: Int
}

private struct ContinuationDisplayPlan: Decodable {
  let vmID: UUID, previousSessionID: UUID
  let proposedInput: LabRuntimeInput
}

private struct WindowsNetworkControlRecord: Encodable, Sendable {
  let scope = "approved-continuation-click-navigation-frame-observation"
  let vmID: UUID, sessionID: UUID
  let action: String
  let x: Int?, y: Int?
  let key: String?
  let beforeSHA256: String, afterSHA256: String, image: String
  let width: Int, height: Int
  let guestDriverVerified = false
  let connectivityVerified = false
  let guestCleanShutdownVerified = false
}

private struct WindowsNetworkInputRecord: Encodable, Sendable {
  let scope = "approved-fixed-windows-network-shutdown-input"
  let vmID: UUID
  let sessionID: UUID
  let action: String
  let reviewedFrameSHA256: String
  let inputSequenceCompleted: Bool
  let fixedCommand: String?
  let image: String?
  let guestShutdownVerified = false
  let runtimeIntentSettled = false
  let ownerTerminated = false
  let forceStopUsed = false
  let networkExposed = false
}

private struct WindowsInstallerInputRecord: Encodable {
  let scope = "approved-installer-fixed-input-frame-observation"
  let vmID: UUID
  let sessionID: UUID
  let action: String
  let beforeSHA256: String
  let afterSHA256: String
  let visualReviewRequired = true
  let appKitInputVerified = false
  let licenseAccepted = false
  let windowsInstalled = false
}
