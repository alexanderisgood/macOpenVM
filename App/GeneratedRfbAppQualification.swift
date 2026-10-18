// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Darwin
import Foundation
import Qemu
import SwiftUI
import VMCore

struct GeneratedRfbAppQualificationRequest: Sendable {
  static let flag = "--generated-rfb-app-qualification"
  let socket: URL, nonce: UUID, output: URL
  static func parse(arguments: [String], environment: [String: String]) throws -> Self? {
    guard arguments.contains(flag) else { return nil }
    guard arguments.count == 9, arguments[1] == flag, arguments[2] == "--run",
      arguments[3] == "--display-socket", arguments[5] == "--nonce",
      arguments[7] == "--output-directory",
      environment["MVO_GENERATED_RFB_APP_QUALIFICATION"] == "1",
      arguments[4].range(
        of: "^/private/tmp/mvo-rfb-present-[0-9a-f]{32}/display[.]sock$",
        options: .regularExpression) != nil,
      let nonce = UUID(uuidString: arguments[6]), nonce.uuidString == arguments[6],
      nonce != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    else { throw GeneratedRfbFailure.invalid }
    let socket = URL(fileURLWithPath: arguments[4])
    let output = socket.deletingLastPathComponent().appendingPathComponent("evidence")
    guard output.path == arguments[8] else { throw GeneratedRfbFailure.invalid }
    return Self(socket: socket, nonce: nonce, output: output)
  }
}

struct GeneratedRfbPresentationLedger {
  struct Received: Encodable {
    let marker: Int, sequence: UInt64, width: Int, height: Int
    let requestMS: Double, receiveMS: Double, publishMS: Double
    let allPixelsMatched = true
  }
  struct Drawn: Encodable {
    let marker: Int, sequence: UInt64
    let drawMS: Double, publishToDrawMS: Double
  }
  private(set) var received: [Received] = []
  private(set) var drawn: [Drawn] = []
  private(set) var epoch: UUID?
  mutating func receive(
    epoch: UUID, sequence: UInt64, marker: Int, size: PixelSize, requestMS: Double,
    receiveMS: Double, publishMS: Double
  ) throws {
    let geometry = [(800, 600), (1920, 1080), (3840, 2160)]
    guard received.count < 18, marker == received.count + 1,
      sequence == UInt64(marker),
      self.epoch == nil || self.epoch == epoch, requestMS.isFinite, receiveMS.isFinite,
      publishMS.isFinite,
      requestMS >= (received.last?.publishMS ?? 0), receiveMS >= requestMS, publishMS >= receiveMS,
      size.width == geometry[(marker - 1) / 6].0, size.height == geometry[(marker - 1) / 6].1
    else { throw GeneratedRfbFailure.invalid }
    self.epoch = epoch
    received.append(
      Received(
        marker: marker, sequence: sequence, width: size.width, height: size.height,
        requestMS: requestMS, receiveMS: receiveMS, publishMS: publishMS))
  }
  mutating func draw(_ value: RfbQualificationPresentation, milliseconds: Double) throws {
    guard value.drawn, value.attached, value.visible else { return }
    guard value.epoch == epoch,
      let frame = received.first(where: { $0.sequence == value.sequence }),
      frame.width == value.width, frame.height == value.height, milliseconds.isFinite,
      milliseconds >= frame.publishMS
    else { throw GeneratedRfbFailure.invalid }
    if drawn.contains(where: { $0.sequence == value.sequence }) { return }
    guard value.sequence > (drawn.last?.sequence ?? 0), milliseconds >= (drawn.last?.drawMS ?? 0)
    else { throw GeneratedRfbFailure.invalid }
    drawn.append(
      Drawn(
        marker: frame.marker, sequence: value.sequence, drawMS: milliseconds,
        publishToDrawMS: milliseconds - frame.publishMS))
  }
  var complete: Bool {
    received.count == 18 && drawn.last?.sequence == received.last?.sequence
      && [0, 1, 2].allSatisfy { group in drawn.contains { ($0.marker - 1) / 6 == group } }
  }
  var coalesced: Int { received.count - drawn.count }
}

@MainActor final class GeneratedRfbAppQualification: ObservableObject {
  @Published private(set) var frame: RFBFrame?
  private let request: GeneratedRfbAppQualificationRequest
  private let canQuit: @MainActor () -> Bool
  private var client: RFBClient?
  private weak var view: RfbGuestView?
  private weak var owner: NSWindow?
  private var ledger = GeneratedRfbPresentationLedger()
  private var failure = false, started = false
  private var phase = "admission"
  private let began = ContinuousClock.now
  init(request: GeneratedRfbAppQualificationRequest, canQuit: @escaping @MainActor () -> Bool) {
    self.request = request
    self.canQuit = canQuit
  }
  private var ms: Double {
    let d = began.duration(to: .now)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
  }
  func attach(_ view: RfbGuestView) {
    guard self.view == nil || self.view === view, owner == nil || owner === view.window else {
      failure = true
      return
    }
    self.view = view
    owner = view.window
    view.onQualificationPresentation = { [weak self, weak view] value in
      guard let self, let view, self.view === view, self.owner === view.window else { return }
      do { try self.ledger.draw(value, milliseconds: self.ms) } catch { self.failure = true }
    }
  }
  func detach(_ view: RfbGuestView) {
    guard self.view === view else { return }
    view.onQualificationPresentation = nil
    failure = true
    self.view = nil
    if let client { Task { await client.close() } }
  }
  func run() async {
    guard !started else { return }
    started = true
    var output: GeneratedRfbOutput?
    var connectionAttempted = false
    var closeAwaitCompleted = false
    do {
      output = try GeneratedRfbOutput(request.output)
      let attachedDeadline = ContinuousClock.now + .seconds(10)
      while view?.window == nil || owner?.isVisible != true, ContinuousClock.now < attachedDeadline
      {
        try await Task.sleep(for: .milliseconds(25))
      }
      guard view?.window != nil, owner?.isVisible == true else { throw GeneratedRfbFailure.invalid }
      var parent = stat()
      var socket = stat()
      try LibraryNetworkQualificationAdmission.privateDirectory(
        request.socket.deletingLastPathComponent())
      guard lstat(request.socket.deletingLastPathComponent().path, &parent) == 0,
        lstat(request.socket.path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
        socket.st_uid == geteuid(), socket.st_nlink == 1, socket.st_mode & 0o7777 == 0o600
      else { throw GeneratedRfbFailure.invalid }
      let peer = RFBClient(
        socketURL: request.socket,
        expectedIdentity: RFBEndpointIdentity(
          parentDevice: parent.st_dev, parentInode: parent.st_ino, socketDevice: socket.st_dev,
          socketInode: socket.st_ino), timeout: .seconds(30))
      client = peer
      phase = "connect"
      connectionAttempted = true
      try await peer.connect()
      phase = "receive"
      for marker in 1...18 {
        guard ms < 120_000, !failure else { throw GeneratedRfbFailure.invalid }
        let requestedAt = ms
        let actual = try await peer.nextFrame()
        let receivedAt = ms
        try await Task.detached(priority: .utility) {
          try Self.validate(actual.rgbaData, marker: marker, size: actual.size)
        }.value
        try ledger.receive(
          epoch: actual.connectionEpoch, sequence: actual.sequence, marker: marker,
          size: actual.size, requestMS: requestedAt, receiveMS: receivedAt, publishMS: ms)
        frame = actual
      }
      let deadline = ContinuousClock.now + .seconds(10)
      phase = "draw"
      while !ledger.complete, !failure, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
      }
      guard ledger.complete, !failure, owner?.isVisible == true, view?.window === owner else {
        throw GeneratedRfbFailure.invalid
      }
      phase = "complete"
    } catch { failure = true }
    if let client {
      await client.close()
      closeAwaitCompleted = true
    }
    client = nil
    do {
      guard let output else { throw GeneratedRfbFailure.invalid }
      let bounds = view?.bounds ?? .zero
      let scale = owner?.backingScaleFactor ?? 0
      let fitted =
        frame.flatMap { try? GuestViewport(viewBounds: bounds, guestPixels: $0.size).fittedRect }
        ?? .zero
      let idleQuit = canQuit()
      let result = Result(
        schemaVersion: 1, scope: "generated-public-RFB-client-AppKit-presentation", phase: phase,
        nonce: request.nonce,
        passed: !failure && ledger.complete, received: ledger.received, drawn: ledger.drawn,
        sameOwner: view != nil && owner != nil && view?.window === owner,
        connectionEpoch: ledger.epoch,
        coalescedFrames: ledger.coalesced,
        bounds: [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].map(Double.init),
        backingScale: scale,
        fittedRect: [fitted.origin.x, fitted.origin.y, fitted.width, fitted.height].map(
          Double.init),
        connectionAttempted: connectionAttempted, closeAwaitCompleted: closeAwaitCompleted,
        physicalScanoutVerified: false, guestPerformanceVerified: false,
        inputSent: false,
        guestStarted: false, pixelsPersisted: false, idleQuitRequested: idleQuit,
        guestPixelsRead: false, generatedPixelsValidated: !ledger.received.isEmpty)
      try output.save(JSONEncoder().encode(result))
      if idleQuit { NSApp.terminate(nil) }
    } catch {
      // Keep this exact own app for inspection when result output fails.
    }
  }
  nonisolated static func validate(_ bytes: Data, marker: Int, size: PixelSize) throws {
    guard (1...18).contains(marker), (1...8192).contains(size.width),
      (1...8192).contains(size.height), size.width * size.height <= 16_777_216,
      bytes.count == size.width * size.height * 4
    else { throw GeneratedRfbFailure.invalid }
    try bytes.withUnsafeBytes { raw in
      let pixels = raw.bindMemory(to: UInt8.self)
      for i in stride(from: 0, to: pixels.count, by: 4) {
        guard pixels[i] == 0x80, pixels[i + 1] == 0x40, pixels[i + 2] == UInt8(marker),
          pixels[i + 3] == 255
        else { throw GeneratedRfbFailure.invalid }
      }
    }
  }
  private struct Result: Encodable {
    let schemaVersion: Int, scope: String, phase: String, nonce: UUID, passed: Bool
    let received: [GeneratedRfbPresentationLedger.Received],
      drawn: [GeneratedRfbPresentationLedger.Drawn]
    let sameOwner: Bool, connectionEpoch: UUID?
    let coalescedFrames: Int, bounds: [Double], backingScale: Double, fittedRect: [Double]
    let connectionAttempted: Bool, closeAwaitCompleted: Bool, physicalScanoutVerified: Bool,
      guestPerformanceVerified: Bool,
      inputSent: Bool
    let guestStarted: Bool, pixelsPersisted: Bool, idleQuitRequested: Bool
    let guestPixelsRead: Bool, generatedPixelsValidated: Bool
  }
}

struct GeneratedRfbQualificationView: View {
  @StateObject private var driver: GeneratedRfbAppQualification
  init(request: GeneratedRfbAppQualificationRequest, canQuit: @escaping @MainActor () -> Bool) {
    _driver = StateObject(
      wrappedValue: GeneratedRfbAppQualification(request: request, canQuit: canQuit))
  }
  var body: some View { GeneratedRfbSurface(driver: driver).task { await driver.run() } }
}
private struct GeneratedRfbSurface: NSViewRepresentable {
  @ObservedObject var driver: GeneratedRfbAppQualification
  func makeNSView(context: Context) -> RfbGuestView {
    let view = RfbGuestView()
    view.captured = false
    view.useGuestCursor = false
    view.onAttachment = driver.attach
    view.onDetach = driver.detach
    return view
  }
  func updateNSView(_ view: RfbGuestView, context: Context) { view.update(frame: driver.frame) }
  static func dismantleNSView(_ view: RfbGuestView, coordinator: ()) {
    view.onDetach?(view)
    view.onQualificationPresentation = nil
  }
}
private final class GeneratedRfbOutput {
  private let directory: URL, descriptor: Int32, device: dev_t, inode: ino_t
  init(_ directory: URL) throws {
    try LibraryNetworkQualificationAdmission.privateDirectory(directory)
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw GeneratedRfbFailure.invalid }
    var info = stat()
    var named = stat()
    guard fstat(fd, &info) == 0, lstat(directory.path, &named) == 0,
      info.st_dev == named.st_dev, info.st_ino == named.st_ino
    else {
      close(fd)
      throw GeneratedRfbFailure.invalid
    }
    self.directory = directory
    descriptor = fd
    device = info.st_dev
    inode = info.st_ino
  }
  deinit { close(descriptor) }
  private func verify() throws {
    try LibraryNetworkQualificationAdmission.privateDirectory(directory)
    var named = stat()
    guard lstat(directory.path, &named) == 0, named.st_dev == device, named.st_ino == inode else {
      throw GeneratedRfbFailure.invalid
    }
  }
  func save(_ bytes: Data) throws {
    guard !bytes.isEmpty, bytes.count <= 16384 else { throw GeneratedRfbFailure.invalid }
    try verify()
    let fd = openat(
      descriptor, "presentation-result.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600)
    guard fd >= 0 else { throw GeneratedRfbFailure.invalid }
    defer { close(fd) }
    try bytes.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { throw GeneratedRfbFailure.invalid }
      var offset = 0
      while offset < bytes.count {
        let n = write(fd, base.advanced(by: offset), bytes.count - offset)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw GeneratedRfbFailure.invalid }
        offset += n
      }
    }
    guard fsync(fd) == 0, fsync(descriptor) == 0 else { throw GeneratedRfbFailure.invalid }
    try verify()
  }
}
private enum GeneratedRfbFailure: Error { case invalid }
