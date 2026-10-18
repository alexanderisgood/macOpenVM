// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Foundation
import Qemu
import VMCore

/// Explicit bounded navigation of an existing registered owner, never lifecycle or text input.
enum RegisteredWindowsInputLab {
  struct Result: Encodable, Sendable {
    let scope = "macopenvm-registered-windows-bounded-navigation"
    let vmID: UUID, sessionID: UUID
    let action: String, beforeSHA256: String, afterSHA256: String
    let width: Int, height: Int
    /// PPM bytes for explicit snapshot/live view only. Never JSON/logged.
    let frameData: Data?
    enum CodingKeys: String, CodingKey {
      case scope, vmID, sessionID, action, beforeSHA256, afterSHA256, width, height
    }
  }
  enum RecoveryAction: String {
    case snapshot, inspect, liveView, liveGPUView, showDesktop, shutdownDialog, confirmShutdown
    case liveSeparateGPUView
    case wakeDisplay, selectGPUDisplay, selectFirmwareDisplay
    case projectionMenu
    case openGPUFileExplorer, focusGPUAddress, openGPUDisc
    case gpuContextMenu = "GPUContextMenu"
    case refreshGraphics, secureAttention
    case nativeDisplay, standardDisplay
    case openServices
    case openGraphicsDisc
    case openGPUCheckBrowser, openGPUCheckPage
    case openPerformanceRun, startCS2PerformanceSample, readCS2PerformanceSample
  }
  static func run(
    request: RegisteredWindowsControl.Request, action: String, expectedFrame: String?,
    x: Int?, y: Int?, key: String?, recovery: RecoveryAction? = nil,
    region: RegisteredInputRegion? = nil, selectGPU: Bool = false
  ) async throws -> Result {
    guard request.action == .status else { throw failure() }
    if let region {
      if recovery == .startCS2PerformanceSample || recovery == .readCS2PerformanceSample {
        guard region.x == 32, region.y == 1640, region.width == 620, region.height == 120
        else { throw failure() }
      } else if recovery != nil {
        throw failure()
      } else if action == "click" || action == "scrollDown" {
        guard let x, let y, region.contains(clickX: x, clickY: y) else { throw failure() }
      } else if action != "key" {
        throw failure()
      }
    }
    let input: WindowsExternalInputRequest
    if recovery != nil {
      guard x == nil, y == nil, key == nil else { throw failure() }
      if recovery == .snapshot || recovery == .inspect || recovery == .liveView
        || recovery == .liveGPUView
        || recovery == .liveSeparateGPUView
        || recovery == .nativeDisplay || recovery == .standardDisplay || recovery == .openServices
        || recovery == .openGraphicsDisc
        || recovery == .openGPUCheckBrowser || recovery == .openGPUCheckPage
        || recovery == .openPerformanceRun
      {
        guard expectedFrame == nil else { throw failure() }
      } else {
        guard let expectedFrame, expectedFrame.count == 64,
          expectedFrame.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw failure() }
      }
      input = try self.input(action: "snapshot", expectedFrame: nil, x: nil, y: nil, key: nil)
    } else {
      input = try self.input(
        action: action == "scrollDown" ? "click" : action,
        expectedFrame: expectedFrame, x: x, y: y, key: key)
    }
    let reference = try await RegisteredWindowsControl.run(request)
    try healthy(reference, reference: reference, recovery: recovery != nil)
    let path = request.runDirectory.appendingPathComponent("display.json")
    let bytes = try WindowsExternalFileIO.readPrivate(
      path, maximum: FlatDisplayRouteCodec.maximumBytes)
    let route = try decodeRoute(bytes, request: request, vmID: reference.vmID)
    let display = client(route)
    var observer: RFBClient?
    var inputAttempted = false
    do {
      try await display.connect()
      try await verify(
        request, reference: reference, path: path, bytes: bytes, recovery: recovery != nil)
      // Legacy combined-profile recovery actions use console zero. The explicit
      // selectGPU flag targets the app's separate firmware/GPU profile instead;
      // the reviewed frame/region must still match before any input is sent.
      if selectGPU || recovery == .liveGPUView || recovery == .openGPUFileExplorer
        || recovery == .focusGPUAddress || recovery == .openGPUDisc || recovery == .gpuContextMenu
      {
        let number: UInt32 = selectGPU ? 0x32 : 0x31
        for symbol: UInt32 in [0xffe3, 0xffe9, number] {
          try await display.sendKey(keySym: symbol, down: true)
        }
        for symbol: UInt32 in [number, 0xffe9, 0xffe3] {
          try await display.sendKey(keySym: symbol, down: false)
        }
      }
      // Explicit observation of the app's separate firmware/GPU profile.
      // Keep the combined profile's console-zero action unchanged. A fresh
      // observer otherwise starts on firmware and can show stale sign-in pixels.
      if recovery == .liveSeparateGPUView {
        for symbol: UInt32 in [0xffe3, 0xffe9, 0x32] {
          try await display.sendKey(keySym: symbol, down: true)
        }
        for symbol: UInt32 in [0x32, 0xffe9, 0xffe3] {
          try await display.sendKey(keySym: symbol, down: false)
        }
      }
      var before = try await frameWithin(display)
      if recovery == .liveView || recovery == .liveGPUView || recovery == .liveSeparateGPUView
        || expectedFrame != nil
      {
        try await verify(
          request, reference: reference, path: path, bytes: bytes, recovery: recovery != nil)
        before = try await frameWithin(display, incremental: false)
      }
      let beforeHash = try frameHash(
        before, epoch: display.connectionEpoch, input: region == nil ? input : nil)
      if let region {
        guard try region.digest(before, epoch: display.connectionEpoch) == expectedFrame else {
          throw VMError(
            .staleOperation, "The reviewed visual target changed before input.",
            recovery: "Observe its current pixels and geometry before another explicit action.")
        }
      }
      try await verify(
        request, reference: reference, path: path, bytes: bytes, recovery: recovery != nil)
      if let recovery, recovery != .snapshot, recovery != .inspect, recovery != .liveView,
        recovery != .liveGPUView, recovery != .liveSeparateGPUView
      {
        // A size request has no pointer/key target. Its authority is the exact
        // registered live owner and fixed dimensions, not an animated desktop.
        if region == nil && recovery != .nativeDisplay && recovery != .standardDisplay
          && recovery != .openServices
          && recovery != .openGraphicsDisc
          && recovery != .openGPUCheckBrowser && recovery != .openGPUCheckPage
          && recovery != .openPerformanceRun
        {
          guard beforeHash == expectedFrame else { throw failure() }
        }
        inputAttempted = true
        if recovery == .openGPUCheckPage {
          try await display.recoverKeyboardAfterOverflow()
        }
        let chord: [UInt32]
        switch recovery {
        case .showDesktop: chord = [0xffeb, 0x64]
        case .shutdownDialog: chord = [0xffe9, 0xffc1]
        case .confirmShutdown: chord = [0xff0d]
        case .wakeDisplay: chord = [0xffe1]
        case .selectGPUDisplay: chord = [0xffe3, 0xffe9, 0x32]
        case .selectFirmwareDisplay: chord = [0xffe3, 0xffe9, 0x31]
        case .projectionMenu: chord = [0xffeb, 0x70]
        case .openGPUFileExplorer: chord = [0xffeb, 0x65]
        case .focusGPUAddress: chord = [0xffe9, 0x64]
        case .openGPUDisc: chord = []
        case .gpuContextMenu: chord = [0xffe1, 0xffc7]
        case .refreshGraphics: chord = [0xffeb, 0xffe3, 0xffe1, 0x62]
        case .secureAttention: chord = [0xffe3, 0xffe9, 0xffff]
        case .nativeDisplay, .standardDisplay: chord = []
        case .openServices: chord = [0xffeb, 0x72]
        case .openGraphicsDisc: chord = [0xffeb, 0x72]
        case .openGPUCheckBrowser: chord = [0xffeb, 0x72]
        case .openGPUCheckPage: chord = [0xffe9, 0x64]
        case .openPerformanceRun: chord = [0xffeb, 0x72]
        case .startCS2PerformanceSample, .readCS2PerformanceSample: chord = []
        case .snapshot, .inspect, .liveView, .liveGPUView, .liveSeparateGPUView: chord = []
        }
        for symbol in chord { try await display.sendKey(keySym: symbol, down: true) }
        for symbol in chord.reversed() { try await display.sendKey(keySym: symbol, down: false) }
        if recovery == .startCS2PerformanceSample || recovery == .readCS2PerformanceSample {
          try await typeCS2PerformanceSample(
            display, request: request, reference: reference, path: path, bytes: bytes,
            before: before, read: recovery == .readCS2PerformanceSample)
        }
        if recovery == .nativeDisplay {
          try await display.requestDesktopSize(PixelSize(width: 3456, height: 2160))
        }
        if recovery == .standardDisplay {
          try await display.requestDesktopSize(PixelSize(width: 1280, height: 1024))
        }
        if recovery == .nativeDisplay || recovery == .standardDisplay {
          // Read the extension reply on the same connection before closing it.
          // A completed socket write alone does not prove server processing.
          _ = try await frameWithin(display, incremental: false)
          try await Task.sleep(for: .seconds(1))
          _ = try await frameWithin(display, incremental: false)
        }
        if recovery == .openGraphicsDisc {
          // Fixed reviewed support drive. Keep the currently selected console;
          // combined and separate-display trials have different console indices.
          try await Task.sleep(for: .milliseconds(500))
          for stroke in try FixedGuestASCII.strokes("d:/") {
            try await display.sendKey(keySym: stroke.symbol, down: stroke.down)
          }
          try await display.sendKey(keySym: 0xff0d, down: true)
          try await display.sendKey(keySym: 0xff0d, down: false)
        }
        if recovery == .openServices {
          // One fixed Windows administration UI. No arbitrary command, account
          // data, credential, privilege approval or service mutation is sent.
          try await Task.sleep(for: .milliseconds(500))
          for symbol in "services.msc".unicodeScalars {
            try await display.sendKey(keySym: symbol.value, down: true)
            try await display.sendKey(keySym: symbol.value, down: false)
          }
          try await display.sendKey(keySym: 0xff0d, down: true)
          try await display.sendKey(keySym: 0xff0d, down: false)
        }
        if recovery == .openGPUCheckBrowser || recovery == .openGPUCheckPage {
          let text: String
          if recovery == .openGPUCheckBrowser {
            try await Task.sleep(for: .milliseconds(500))
            text = "msedge"
          } else {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
              .deletingLastPathComponent()
            let html = try Data(
              contentsOf: root.appendingPathComponent("examples/windows-gpu-check.html"))
            guard html.count <= 8192,
              SHA256.hash(data: html).map({ String(format: "%02x", $0) }).joined()
                == "e4c002668200c586ced422ef86e17f9cccdd397398f7220e80891af73eeac33a"
            else { throw failure() }
            text = "data:text/html;base64," + html.base64EncodedString()
          }
          for stroke in try FixedGuestASCII.strokes(text) {
            try await display.sendKey(keySym: stroke.symbol, down: stroke.down)
          }
          try await display.sendKey(keySym: 0xff0d, down: true)
          try await display.sendKey(keySym: 0xff0d, down: false)
        }
        if recovery == .openGPUDisc {
          // Fixed reviewed installation-disc destination; no arbitrary text or credentials.
          for stroke in try FixedGuestASCII.strokes("d:/") {
            try await display.sendKey(keySym: stroke.symbol, down: stroke.down)
          }
          try await display.sendKey(keySym: 0xff0d, down: true)
          try await display.sendKey(keySym: 0xff0d, down: false)
        }
      } else {
        switch input.operation {
        case .snapshot: break
        case .click(let px, let py):
          inputAttempted = true
          if action == "scrollDown" {
            try await display.sendScroll(x: px, y: py, steps: -8, frameSize: before.size)
          } else {
            try await display.sendPointer(x: px, y: py, buttons: 1, frameSize: before.size)
            try await display.sendPointer(x: px, y: py, buttons: 0, frameSize: before.size)
          }
        case .key(let symbol):
          inputAttempted = true
          try await display.sendKey(keySym: symbol, down: true)
          try await display.sendKey(keySym: symbol, down: false)
        }
      }
      await display.releaseInput()
      await display.close()
      try await verify(
        request, reference: reference, path: path, bytes: bytes, recovery: recovery != nil)
      var after = before
      var afterHash = beforeHash
      if action != "snapshot" && recovery != .snapshot && recovery != .inspect
        && recovery != .liveView && recovery != .liveGPUView && recovery != .liveSeparateGPUView
      {
        let fresh = client(route)
        observer = fresh
        try await fresh.connect()
        if selectGPU || recovery == .openGPUFileExplorer || recovery == .focusGPUAddress
          || recovery == .openGPUDisc || recovery == .gpuContextMenu
        {
          for symbol: UInt32 in [0xffe3, 0xffe9, 0x31] {
            try await fresh.sendKey(keySym: symbol, down: true)
          }
          for symbol: UInt32 in [0x31, 0xffe9, 0xffe3] {
            try await fresh.sendKey(keySym: symbol, down: false)
          }
        }
        try await verify(
          request, reference: reference, path: path, bytes: bytes, recovery: recovery != nil)
        after = try await frameWithin(fresh)
        afterHash = try frameHash(after, epoch: fresh.connectionEpoch)
        await fresh.close()
      }
      try await verify(
        request, reference: reference, path: path, bytes: bytes, recovery: recovery != nil)
      return Result(
        vmID: route.vmID, sessionID: route.sessionID, action: action,
        beforeSHA256: beforeHash, afterSHA256: afterHash, width: after.size.width,
        height: after.size.height,
        frameData: action == "snapshot" || recovery == .snapshot || recovery == .liveView
          || recovery == .liveGPUView
          || recovery == .liveSeparateGPUView
          ? ppm(before) : nil)
    } catch {
      await display.releaseInput()
      await display.close()
      if let observer {
        await observer.releaseInput()
        await observer.close()
      }
      if inputAttempted {
        throw VMError(
          .backendFailure, "The input attempt could not be fully observed.",
          recovery:
            "Input may already have been applied. Observe a new framebuffer before another explicit request. No replay is automatic."
        )
      }
      throw error
    }
  }
  struct Observation: Encodable, Sendable {
    let scope = "macopenvm-registered-windows-read-only-display-observation"
    let vmID: UUID, sessionID: UUID
    let frameCount: Int, width: Int, height: Int
    let elapsedMilliseconds: Int
    let receiveIntervalsMilliseconds: [Double]
    let frameWaitMilliseconds: [Double]
    let connectionEpoch: UUID
    let completed: Bool, endedAt: String
  }
  /// Bounded incremental observation; pixels and guest text never leave the client.
  static func observe(request: RegisteredWindowsControl.Request, frames: Int) async throws
    -> Observation
  {
    guard request.action == .status, (1...120).contains(frames) else { throw failure() }
    let reference = try await RegisteredWindowsControl.run(request)
    try healthy(reference, reference: reference)
    let path = request.runDirectory.appendingPathComponent("display.json")
    let bytes = try WindowsExternalFileIO.readPrivate(
      path, maximum: FlatDisplayRouteCodec.maximumBytes)
    let route = try decodeRoute(bytes, request: request, vmID: reference.vmID)
    let peer = client(route)
    let clock = ContinuousClock()
    let start = clock.now
    var size = PixelSize(width: 0, height: 0)
    var sequence: UInt64 = 0
    var count = 0
    var lastReceive: ContinuousClock.Instant?
    var intervals: [Double] = []
    var waits: [Double] = []
    var phase = "connect"
    do {
      try await peer.connect()
      for _ in 0..<frames {
        try Task.checkCancellation()
        phase = "admission-window"
        guard start.duration(to: clock.now) < .seconds(30) else { throw failure() }
        phase = "status-route"
        try await verify(request, reference: reference, path: path, bytes: bytes)
        phase = "frame"
        let requested = clock.now
        let frame = try await frameWithin(peer)
        let received = clock.now
        guard frame.connectionEpoch == peer.connectionEpoch, frame.sequence > sequence,
          (1...8192).contains(frame.size.width), (1...8192).contains(frame.size.height),
          frame.size.width * frame.size.height <= 16_777_216,
          frame.rgbaData.count == frame.size.width * frame.size.height * 4
        else { throw failure() }
        sequence = frame.sequence
        size = frame.size
        count += 1
        waits.append(milliseconds(requested.duration(to: received)))
        if let lastReceive {
          intervals.append(milliseconds(lastReceive.duration(to: received)))
        }
        lastReceive = received
      }
      phase = "final-status-route"
      try await verify(request, reference: reference, path: path, bytes: bytes)
      await peer.close()
      let duration = start.duration(to: clock.now).components
      return Observation(
        vmID: route.vmID, sessionID: route.sessionID, frameCount: frames,
        width: size.width, height: size.height,
        elapsedMilliseconds: Int(
          duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000),
        receiveIntervalsMilliseconds: intervals, frameWaitMilliseconds: waits,
        connectionEpoch: peer.connectionEpoch, completed: true, endedAt: "complete")
    } catch {
      await peer.close()
      if Task.isCancelled { throw CancellationError() }
      let duration = start.duration(to: clock.now).components
      return Observation(
        vmID: route.vmID, sessionID: route.sessionID, frameCount: count,
        width: size.width, height: size.height,
        elapsedMilliseconds: Int(
          duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000),
        receiveIntervalsMilliseconds: intervals, frameWaitMilliseconds: waits,
        connectionEpoch: peer.connectionEpoch, completed: false, endedAt: phase)
    }
  }
  static func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
  }
  /// The operator first observes the Run dialog through openPerformanceRun.
  /// Pin its unchanged title/body chrome throughout paced entry; a lock, reboot,
  /// geometry change or closed dialog cancels before any further input/Return.
  private static func typeCS2PerformanceSample(
    _ display: RFBClient, request: RegisteredWindowsControl.Request,
    reference: RegisteredWindowsControl.Result, path: URL, bytes: Data,
    before: RFBFrame, read: Bool
  ) async throws {
    guard before.size == PixelSize(width: 3456, height: 2168) else { throw failure() }
    let chrome = try RegisteredInputRegion(x: 32, y: 1640, width: 620, height: 120)
    let expected = try chrome.digest(before, epoch: display.connectionEpoch)
    let deadline = ContinuousClock.now + .seconds(90)
    let text = WindowsCS2PerformanceSample.command(read: read)
    let strokes = try FixedGuestASCII.strokes(text)
    guard strokes.count < 6000 else { throw failure() }
    // Clear only the reviewed Run field. No clipboard or host key state is used.
    for key: UInt32 in [0xffe3, 0x61] { try await display.sendKey(keySym: key, down: true) }
    for key: UInt32 in [0x61, 0xffe3] { try await display.sendKey(keySym: key, down: false) }
    for (index, stroke) in strokes.enumerated() {
      try Task.checkCancellation()
      if index % 64 == 0 {
        guard ContinuousClock.now < deadline else { throw failure() }
        try await verify(request, reference: reference, path: path, bytes: bytes)
        let current = try await frameWithin(display, incremental: false)
        guard try chrome.digest(current, epoch: display.connectionEpoch) == expected else {
          throw failure()
        }
      }
      try await display.sendKey(keySym: stroke.symbol, down: stroke.down)
    }
    try await verify(request, reference: reference, path: path, bytes: bytes)
    let current = try await frameWithin(display, incremental: false)
    guard try chrome.digest(current, epoch: display.connectionEpoch) == expected else {
      throw failure()
    }
    try await display.sendKey(keySym: 0xff0d, down: true)
    try await display.sendKey(keySym: 0xff0d, down: false)
  }
  private static func client(_ route: DisplayWorkerRoute) -> RFBClient {
    RFBClient(
      socketURL: URL(fileURLWithPath: route.displaySocket),
      expectedIdentity: RFBEndpointIdentity(
        parentDevice: route.parentDevice, parentInode: route.parentInode,
        socketDevice: route.socketDevice, socketInode: route.socketInode))
  }
  static func input(action: String, expectedFrame: String?, x: Int?, y: Int?, key: String?) throws
    -> WindowsExternalInputRequest
  {
    do {
      return try WindowsExternalInputRequest(
        action: action, expectedFrame: expectedFrame, x: x, y: y, key: key)
    } catch { throw failure() }
  }
  static func decodeRoute(_ bytes: Data, request: RegisteredWindowsControl.Request, vmID: UUID)
    throws -> DisplayWorkerRoute
  {
    let route = try FlatDisplayRouteCodec.decode(bytes, profile: .registeredQemu)
    let parent =
      "/private/tmp/mvo-qemu-" + request.runDirectory.lastPathComponent.dropFirst(4).prefix(16)
    guard route.vmID == vmID, route.sessionID == request.expectedSession,
      route.controlSocket == parent + "/worker.sock", route.displaySocket == parent + "/vnc.sock",
      route.parentInode > 0, route.socketInode > 0
    else { throw failure() }
    return route
  }
  static func healthy(
    _ status: RegisteredWindowsControl.Result, reference: RegisteredWindowsControl.Result,
    recovery: Bool = false
  ) throws {
    guard status.action == "status", status.vmID == reference.vmID,
      status.sessionID == reference.sessionID,
      status.revision == reference.revision,
      status.state == 2 || (recovery && (status.state == 3 || status.state == 6)),
      status.ownership == 0,
      status.backendActive, !status.operationPending, status.error == 0
    else { throw failure() }
  }
  private static func verify(
    _ request: RegisteredWindowsControl.Request, reference: RegisteredWindowsControl.Result,
    path: URL, bytes: Data, recovery: Bool = false
  ) async throws {
    guard try WindowsExternalFileIO.readPrivate(path, maximum: 4096) == bytes else {
      throw failure()
    }
    try healthy(
      await RegisteredWindowsControl.run(request), reference: reference, recovery: recovery)
    guard try WindowsExternalFileIO.readPrivate(path, maximum: 4096) == bytes else {
      throw failure()
    }
  }
  static func frameHash(_ frame: RFBFrame, epoch: UUID, input: WindowsExternalInputRequest? = nil)
    throws -> String
  {
    guard frame.connectionEpoch == epoch, frame.sequence > 0,
      (1...8192).contains(frame.size.width), (1...8192).contains(frame.size.height),
      frame.size.width * frame.size.height <= 16_777_216,
      frame.rgbaData.count == frame.size.width * frame.size.height * 4
    else { throw failure() }
    let hash = SHA256.hash(data: ppm(frame)).map { String(format: "%02x", $0) }.joined()
    guard input?.admitsFrame(hash: hash, size: frame.size) ?? true else { throw failure() }
    return hash
  }
  static func ppm(_ frame: RFBFrame) -> Data {
    var bytes = Data("P6\n\(frame.size.width) \(frame.size.height)\n255\n".utf8)
    for offset in stride(from: 0, to: frame.rgbaData.count, by: 4) {
      bytes.append(frame.rgbaData[offset..<(offset + 3)])
    }
    return bytes
  }
  private static func frameWithin(_ display: RFBClient, incremental: Bool = true) async throws
    -> RFBFrame
  {
    try await withThrowingTaskGroup(of: RFBFrame.self) { group in
      group.addTask { try await display.nextFrame(incremental: incremental) }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw failure()
      }
      defer { group.cancelAll() }
      guard let frame = try await group.next() else { throw failure() }
      return frame
    }
  }
  private static func failure() -> VMError {
    VMError(
      .staleOperation, "The registered guest input request is invalid, stale, or not ready.",
      recovery:
        "Observe the current running session and framebuffer before another explicit request. Nothing is replayed automatically."
    )
  }
}
