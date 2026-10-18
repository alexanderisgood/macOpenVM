// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Dispatch
import Foundation
import Qemu
import Testing

@testable import MacOpenVMApp

enum RfbPeerError: Error {
  case posix(Int32)
  case wire, timeout, eof
}

private final class RfbClientWitness {
  weak var value: RFBClient?
  init(_ value: RFBClient?) { self.value = value }
}

/// Synthetic independent wire peer. Its dedicated blocking queue owns actual close;
/// stop only shuts down published descriptors under a lock, then joins the script.
final class RfbPeer: @unchecked Sendable {
  let directory: URL
  let socketURL: URL
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var stream: Int32 = -1
  private var stopped = false
  private let worker = DispatchQueue(label: "local.macOpenVM.synthetic-rfb-peer")
  private var result: Result<Void, Error>?
  private var waiters: [CheckedContinuation<Void, Error>] = []

  init(_ script: @escaping @Sendable (Int32) throws -> Void) throws {
    directory = URL(fileURLWithPath: "/private/tmp/mvo-rfb-\(UUID().uuidString)", isDirectory: true)
    socketURL = directory.appendingPathComponent("display.sock")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let value = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard value >= 0 else { throw RfbPeerError.posix(errno) }
    listener = value
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, chmod(socketURL.path, 0o700) == 0, Darwin.listen(value, 1) == 0 else {
      let code = errno
      Darwin.close(value)
      listener = -1
      try? FileManager.default.removeItem(at: directory)
      throw RfbPeerError.posix(code)
    }
    worker.async {
      let result: Result<Void, Error>
      do {
        var item = pollfd(fd: value, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&item, 1, 2_000) > 0 else { throw RfbPeerError.timeout }
        let fd = Darwin.accept(value, nil, nil)
        guard fd >= 0 else { throw RfbPeerError.posix(errno) }
        try self.publish(fd)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        guard
          setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            == 0,
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            == 0,
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            == 0
        else { throw RfbPeerError.posix(errno) }
        try script(fd)
        result = .success(())
      } catch { result = .failure(error) }
      self.finish()
      self.complete(result)
    }
  }

  private func publish(_ fd: Int32) throws {
    lock.lock()
    if stopped {
      lock.unlock()
      Darwin.close(fd)
      throw RfbPeerError.eof
    }
    stream = fd
    lock.unlock()
  }

  private func finish() {
    lock.lock()
    let oldStream = stream
    let oldListener = listener
    stream = -1
    listener = -1
    lock.unlock()
    if oldStream >= 0 { Darwin.close(oldStream) }
    if oldListener >= 0 { Darwin.close(oldListener) }
  }

  private func complete(_ result: Result<Void, Error>) {
    lock.lock()
    self.result = result
    let current = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in current { waiter.resume(with: result) }
  }

  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(with: result)
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
  func stop() async {
    lock.withLock {
      stopped = true
      if listener >= 0 { _ = Darwin.shutdown(listener, SHUT_RDWR) }
      if stream >= 0 { _ = Darwin.shutdown(stream, SHUT_RDWR) }
    }
    try? await wait()
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

func rfbRead(_ fd: Int32, _ count: Int) throws -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  var offset = 0
  while offset < count {
    let received = bytes.withUnsafeMutableBytes {
      Darwin.recv(fd, $0.baseAddress?.advanced(by: offset), count - offset, 0)
    }
    guard received > 0 else { throw RfbPeerError.eof }
    offset += received
  }
  return bytes
}

func rfbWrite(_ fd: Int32, _ bytes: [UInt8], fragmented: Bool = false) throws {
  var offset = 0
  while offset < bytes.count {
    let maximum = fragmented ? 1 : bytes.count - offset
    let written = bytes.withUnsafeBytes {
      Darwin.send(fd, $0.baseAddress?.advanced(by: offset), maximum, 0)
    }
    guard written > 0 else { throw RfbPeerError.eof }
    offset += written
  }
}

private let rfbVersion = Array("RFB 003.008\n".utf8)
private let rfbServerHeader: [UInt8] = [
  0, 2, 0, 1, 32, 24, 0, 1, 0, 255, 0, 255,
  0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 3,
]
private let rfbPixelRequest: [UInt8] = [
  0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255,
  0, 255, 16, 8, 0, 0, 0, 0,
]
private let rfbEncodings: [UInt8] = [2, 0, 0, 3, 0, 0, 0, 0, 255, 255, 255, 33, 255, 255, 254, 255]
private let rfbFullRequest: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 2, 0, 1]
private let rfbIncrementalRequest: [UInt8] = [3, 1, 0, 0, 0, 0, 0, 2, 0, 1]
private let rfbRawHeader: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0]
private let rfbRawPixels: [UInt8] = [3, 2, 1, 99, 30, 20, 10, 0]
private let rfbExpectedRGBA: [UInt8] = [1, 2, 3, 255, 10, 20, 30, 255]

func rfbExpectQuiet(_ fd: Int32, milliseconds: Int32) throws {
  var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
  guard Darwin.poll(&item, 1, milliseconds) == 0 else { throw RfbPeerError.wire }
}

func rfbExpectClosed(_ fd: Int32) throws {
  var byte: UInt8 = 0
  guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
}

private func rfbConsumerBridge(_ fd: Int32) throws {
  guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 99],
    try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 99]
  else { throw RfbPeerError.wire }
}

private func rfbSecondConsumer(_ client: RFBClient) async throws -> Task<RFBFrame, Error> {
  let pending = Task { try await client.nextFrame() }
  do {
    try await Task.sleep(for: .milliseconds(20))
    try await client.sendKey(keySym: 99, down: true)
    try await client.sendKey(keySym: 99, down: false)
    return pending
  } catch {
    pending.cancel()
    throw error
  }
}

private func rfbWaitPipeline(_ gate: DispatchSemaphore) -> Bool {
  gate.wait(timeout: .now() + 1) == .success
}

private func rfbHandshake(_ fd: Int32, header: [UInt8] = rfbServerHeader) throws {
  try rfbWrite(fd, rfbVersion, fragmented: true)
  guard try rfbRead(fd, 12) == rfbVersion else { throw RfbPeerError.wire }
  try rfbWrite(fd, [1, 1])
  guard try rfbRead(fd, 1) == [1] else { throw RfbPeerError.wire }
  try rfbWrite(fd, [0, 0, 0, 0])
  guard try rfbRead(fd, 1) == [1] else { throw RfbPeerError.wire }
  try rfbWrite(fd, header + Array("lab".utf8), fragmented: true)
}

private func rfbFormat(_ fd: Int32) throws {
  guard try rfbRead(fd, 20) == rfbPixelRequest, try rfbRead(fd, rfbEncodings.count) == rfbEncodings
  else {
    throw RfbPeerError.wire
  }
}

private func withRfbPeer(
  script: @escaping @Sendable (Int32) throws -> Void,
  body: @escaping @Sendable (RfbPeer) async throws -> Void
) async throws {
  let peer = try RfbPeer(script)
  defer { peer.remove() }
  do {
    try await body(peer)
    try await peer.wait()
  } catch {
    await peer.stop()
    throw error
  }
}

private actor RfbConsoleEpochWitness {
  private var epoch: UUID?
  func record(_ value: UUID) { epoch = value }
  func recorded() -> UUID? { epoch }
}

@Suite("Synthetic private RFB interoperability")
struct RfbClientTests {
  @Test(arguments: [UInt32(0x31), UInt32(0x32)])
  func consoleChordDoesNotSynthesizeAFramebufferOrGuestAcknowledgement(console: UInt32) async throws
  {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      let chord: [UInt32] = [0xffe3, 0xffe9, console]
      for (symbol, down) in chord.map({ ($0, true) }) + chord.reversed().map({ ($0, false) }) {
        let expected: [UInt8] = [
          4, down ? 1 : 0, 0, 0,
          UInt8((symbol >> 24) & 255), UInt8((symbol >> 16) & 255),
          UInt8((symbol >> 8) & 255), UInt8(symbol & 255),
        ]
        guard try rfbRead(fd, 8) == expected else { throw RfbPeerError.wire }
      }
      // A chord has no protocol ACK. Only the following real full response can
      // establish a framebuffer on this connection.
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels, fragmented: true)
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let chord: [UInt32] = [0xffe3, 0xffe9, console]
      for symbol in chord { try await client.sendKey(keySym: symbol, down: true) }
      for symbol in chord.reversed() { try await client.sendKey(keySym: symbol, down: false) }
      let first = try await client.nextFrame()
      #expect(first.sequence == 1 && first.rgbaData == Data(rfbExpectedRGBA))
      await client.close()
    }
  }

  @Test func closingAQuietIncrementalDisplayDrainsItsWaiterBeforeAFreshDisplayFrame() async throws {
    let epochs = RfbConsoleEpochWitness()
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      // No changed pixels arrive. Ordinary close, not a second request or a
      // replayed cached frame, must release this actual outstanding consumer.
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let first = try await client.nextFrame()
      await epochs.record(first.connectionEpoch)
      let pending = try await rfbSecondConsumer(client)
      await client.close()
      if case .success = await pending.result {
        Issue.record("Quiet old frame waiter unexpectedly succeeded")
      }
    }
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels, fragmented: true)
      try rfbExpectClosed(fd)
    } body: { peer in
      let fresh = RFBClient(socketURL: peer.socketURL)
      try await fresh.connect()
      let frame = try await fresh.nextFrame()
      let observedEpoch = await epochs.recorded()
      let oldEpoch = try #require(observedEpoch)
      #expect(frame.sequence == 1 && frame.connectionEpoch != oldEpoch)
      #expect(frame.rgbaData == Data(rfbExpectedRGBA))
      await fresh.close()
    }
  }

  @Test func relativeMotionUsesSignedDeltasAndReleaseNeverReplaysMotion() async throws {
    try await withRfbPeer(
      script: { fd in
        try rfbHandshake(fd)
        try rfbFormat(fd)
        guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
        try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
        try rfbWrite(fd, [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1, 255, 255, 254, 255])
        guard try rfbRead(fd, 6) == [5, 8, 127, 255, 127, 255],
          try rfbRead(fd, 6) == [5, 0, 127, 255, 127, 255],
          try rfbRead(fd, 6) == [5, 1, 128, 9, 127, 243],
          try rfbRead(fd, 6) == [5, 1, 128, 99, 127, 255],
          try rfbRead(fd, 6) == [5, 0, 127, 255, 127, 255]
        else { throw RfbPeerError.wire }
        try rfbExpectClosed(fd)
      },
      body: { peer in
        let client = RFBClient(socketURL: peer.socketURL)
        try await client.connect()
        let frame = try await client.nextFrame()
        try await client.waitForPointerMode(relative: true)
        await #expect(throws: RFBClientError.pointerModeChanged) {
          try await client.sendPointer(x: 1, y: 0, buttons: 1, frameSize: frame.size)
        }
        // The mismatched event wrote no bytes and cannot poison later input.
        try await client.waitForPointerMode(relative: true)
        try await client.sendScroll(x: 0, y: 0, steps: 1, frameSize: frame.size)
        try await client.sendRelativePointer(dx: 10, dy: -12, buttons: 1)
        try await client.sendRelativePointer(dx: 100, dy: 0, buttons: 1)
        await client.releaseInput()
        await client.close()
      })
  }

  @Test func menuShortcutWritesKeyUpBeforeTheNextFrameRequest() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      for bytes: [UInt8] in [
        [4, 1, 0, 0, 0, 0, 255, 235], [4, 1, 0, 0, 0, 0, 0, 105],
        [4, 0, 0, 0, 0, 0, 0, 105], [4, 0, 0, 0, 0, 0, 255, 235],
      ] {
        guard try rfbRead(fd, 8) == bytes else { throw RfbPeerError.wire }
      }
      _ = try rfbRead(fd, 10)
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      var keyboard = RFBKeyboardState()
      for stroke in try keyboard.shortcut(keyCode: 34, symbol: 0x69, modifiers: .command) {
        try await client.sendKey(keySym: stroke.symbol, down: stroke.down)
      }
      _ = try await client.nextFrame()
      await client.close()
    }
  }
  @Test func wheelPulsesPreserveHeldButtonsAndRejectUnboundedSteps() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      // Left held, two up-wheel detents, one down-wheel detent, all buttons up.
      let expected: [[UInt8]] = [
        [5, 1, 0, 0, 0, 0], [5, 9, 0, 1, 0, 0],
        [5, 1, 0, 1, 0, 0], [5, 9, 0, 1, 0, 0], [5, 1, 0, 1, 0, 0],
        [5, 17, 0, 0, 0, 0], [5, 1, 0, 0, 0, 0], [5, 0, 0, 0, 0, 0],
      ]
      for bytes in expected {
        guard try rfbRead(fd, 6) == bytes else { throw RfbPeerError.wire }
      }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let frame = try await client.nextFrame()
      for steps in [-9, 9, Int.min, Int.max] {
        await #expect(throws: RFBClientError.invalidPointer) {
          try await client.sendScroll(x: 0, y: 0, steps: steps, frameSize: frame.size)
        }
      }
      try await client.sendScroll(x: 0, y: 0, steps: 0, frameSize: frame.size)
      try await client.sendPointer(x: 0, y: 0, buttons: 1, frameSize: frame.size)
      try await client.sendScroll(x: 1, y: 0, steps: 2, frameSize: frame.size)
      try await client.sendScroll(x: 0, y: 0, steps: -1, frameSize: frame.size)
      await client.close()
    }
  }

  @Test func pointerUsesObservedPixelsAndCloseReleasesButtonsInInputOrder() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      // Left press, Ctrl press, right+left, Ctrl release, then all pointer up.
      for bytes: [UInt8] in [
        [5, 1, 0, 1, 0, 0], [4, 1, 0, 0, 0, 0, 255, 227],
        [5, 5, 0, 0, 0, 0], [4, 0, 0, 0, 0, 0, 255, 227], [5, 0, 0, 0, 0, 0],
      ] {
        guard try rfbRead(fd, bytes.count) == bytes else { throw RfbPeerError.wire }
      }
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      await #expect(throws: RFBClientError.invalidPointer) {
        try await client.sendPointer(x: 0, y: 0, buttons: 1, frameSize: .init(width: 2, height: 1))
      }
      let frame = try await client.nextFrame()
      for (x, y, buttons, size): (UInt16, UInt16, UInt8, PixelSize) in [
        (2, 0, 0, frame.size), (0, 1, 0, frame.size), (0, 0, 8, frame.size),
        (0, 0, 0, .init(width: 1, height: 2)),
      ] {
        await #expect(throws: RFBClientError.invalidPointer) {
          try await client.sendPointer(x: x, y: y, buttons: buttons, frameSize: size)
        }
      }
      try await client.sendPointer(x: 1, y: 0, buttons: 1, frameSize: frame.size)
      try await client.sendKey(keySym: 0xffe3, down: true)
      try await client.sendPointer(x: 0, y: 0, buttons: 5, frameSize: frame.size)
      await client.close()
    }
  }

  @Test func releaseInputClearsPointerWithoutClosingDisplay() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      for bytes: [UInt8] in [
        [5, 2, 0, 1, 0, 0], [5, 0, 0, 1, 0, 0],
        [5, 1, 0, 0, 0, 0], [5, 0, 0, 0, 0, 0],
      ] {
        guard try rfbRead(fd, 6) == bytes else { throw RfbPeerError.wire }
      }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let frame = try await client.nextFrame()
      try await client.sendPointer(x: 1, y: 0, buttons: 2, frameSize: frame.size)
      await client.releaseInput()
      try await client.sendPointer(x: 0, y: 0, buttons: 1, frameSize: frame.size)
      await client.close()
    }
  }

  @Test func fullWidthKeyboardWireAndDisconnectReleases() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      // Independently specified network bytes: Ctrl-A, Enter, Windows, Euro.
      let expected: [[UInt8]] = [
        [4, 1, 0, 0, 0, 0, 255, 227], [4, 1, 0, 0, 0, 0, 0, 97],
        [4, 0, 0, 0, 0, 0, 0, 97], [4, 0, 0, 0, 0, 0, 255, 227],
        [4, 1, 0, 0, 0, 0, 255, 13], [4, 0, 0, 0, 0, 0, 255, 13],
        [4, 1, 0, 0, 0, 0, 255, 235], [4, 1, 0, 0, 1, 0, 32, 172],
        [4, 0, 0, 0, 0, 0, 255, 235], [4, 0, 0, 0, 1, 0, 32, 172],
      ]
      for bytes in expected {
        guard try rfbRead(fd, 8) == bytes else { throw RfbPeerError.wire }
      }
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      for symbol: UInt32 in [0, 0x0100_d800, 0xffff_ffff] {
        await #expect(throws: RFBClientError.unsupportedKey) {
          try await client.sendKey(keySym: symbol, down: true)
        }
      }
      try await client.sendKey(keySym: 0xffe3, down: true)
      try await client.sendKey(keySym: 0x61, down: true)
      try await client.sendKey(keySym: 0x61, down: false)
      try await client.sendKey(keySym: 0xffe3, down: false)
      try await client.sendKey(keySym: 0xff0d, down: true)
      try await client.sendKey(keySym: 0xff0d, down: false)
      try await client.sendKey(keySym: 0xffeb, down: true)
      try await client.sendKey(keySym: 0x0100_20ac, down: true)
      await client.close()
    }
  }

  @Test func heldKeyBoundRejectsExcessWithoutLosingRelease() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      for down: UInt8 in [1, 0] {
        for key: UInt8 in 32..<96 {
          guard try rfbRead(fd, 8) == [4, down, 0, 0, 0, 0, 0, key] else {
            throw RfbPeerError.wire
          }
        }
      }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      for key: UInt32 in 32..<96 { try await client.sendKey(keySym: key, down: true) }
      await #expect(throws: RFBClientError.limitExceeded) {
        try await client.sendKey(keySym: 96, down: true)
      }
      await client.releaseKeys()
      await client.close()
    }
  }

  @Test func fragmentedGoldenFrameAndKeyWire() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels, fragmented: true)
      guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 49],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 49]
      else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let frame = try await client.nextFrame()
      #expect(frame.connectionEpoch == client.connectionEpoch)
      #expect(frame.sequence == 1 && frame.size.width == 2 && frame.size.height == 1)
      #expect(Array(frame.rgbaData) == rfbExpectedRGBA)
      try await client.sendKey(keySym: 49, down: true)
      try await client.sendKey(keySym: 49, down: true)  // repeat suppression
      await client.releaseKeys()
      await client.close()
    }
  }

  @Test func idleAndPartialFrameNeverStarveKeyUp() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      _ = try rfbRead(fd, 10)
      // Quiet idle exceeds the client's message deadline without any first byte.
      _ = Darwin.poll(nil, 0, 250)
      try rfbWrite(fd, rfbRawHeader + [3])  // an incomplete pixel body
      guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 50],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 50]
      else { throw RfbPeerError.wire }
      try rfbWrite(fd, Array(rfbRawPixels.dropFirst()))
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, timeout: .milliseconds(200))
      try await client.connect()
      let frame = Task { try await client.nextFrame() }
      try await Task.sleep(for: .milliseconds(280))
      try await client.sendKey(keySym: 50, down: true)
      try await client.sendKey(keySym: 50, down: false)
      #expect(try await Array(frame.value.rgbaData) == rfbExpectedRGBA)
      await client.close()
    }
  }

  @Test func quietSharedRecoveryRefreshesUnchangedPixelsOnTheOriginalInputConnection() async throws
  {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 50],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 50]
      else { throw RfbPeerError.wire }
      // No framebuffer change or unsolicited update enables recovery. The
      // policy's explicit full request must arrive on this original connection.
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let initial = try await client.nextFrame()
      var recovery = SharedDisplayRecovery()
      let retry = recovery.transientFailure(at: .now)
      #expect(retry)
      let request = recovery.nextFrameRequest()
      let deadline = try #require(request.retryDeadline)
      // Input writes remain independent of waiting for the retry deadline.
      try await client.sendKey(keySym: 50, down: true)
      try await client.sendKey(keySym: 50, down: false)
      try await Task.sleep(until: deadline, clock: .continuous)
      let refreshed = try await client.nextFrame(incremental: request.incremental)
      let ordinary = recovery.nextFrameRequest()
      let following = try await client.nextFrame(incremental: ordinary.incremental)
      #expect(refreshed.connectionEpoch == initial.connectionEpoch)
      #expect(following.connectionEpoch == initial.connectionEpoch)
      #expect(refreshed.sequence == 2 && following.sequence == 3)
      #expect(refreshed.rgbaData == initial.rgbaData && following.rgbaData == initial.rgbaData)
      #expect(ordinary.incremental && ordinary.retryDeadline == nil)
      await client.close()
    }
  }

  @Test func explicitFullRefreshDoesNotChangeFollowingIncrementalRequest() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      for incremental: UInt8 in [0, 0, 1] {
        guard try rfbRead(fd, 10) == [3, incremental, 0, 0, 0, 0, 0, 2, 0, 1] else {
          throw RfbPeerError.wire
        }
        try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let first = try await client.nextFrame()
      let full = try await client.nextFrame(incremental: false)
      let incremental = try await client.nextFrame()
      #expect(first.sequence == 1 && full.sequence == 2 && incremental.sequence == 3)
      #expect(full.rgbaData == first.rgbaData && incremental.rgbaData == first.rgbaData)
      await client.close()
    }
  }

  @Test func prefetchOverlapsPresentationButStopsAtOneUnconsumedFrame() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      // The consumer has not asked for its second frame yet.
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [50, 40, 30, 0, 50, 40, 30, 0])
      // No third request while the second immutable frame is unconsumed.
      try rfbExpectQuiet(fd, milliseconds: 100)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, prefetchFrames: true)
      try await client.connect()
      let first = try await client.nextFrame()
      try await Task.sleep(for: .milliseconds(200))
      let second = try await client.nextFrame()
      #expect(Array(first.rgbaData) == rfbExpectedRGBA)
      #expect(Array(second.rgbaData) == [30, 40, 50, 255, 30, 40, 50, 255])
      #expect(second.connectionEpoch == first.connectionEpoch && second.sequence > first.sequence)
      await client.close()
    }
  }

  @Test func forcedRefreshDiscardsAnAlreadyBufferedPrefetch() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [50, 40, 30, 0, 50, 40, 30, 0])
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [90, 80, 70, 0, 90, 80, 70, 0])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, prefetchFrames: true)
      try await client.connect()
      let first = try await client.nextFrame()
      try await Task.sleep(for: .milliseconds(100))
      let fresh = try await client.nextFrame(incremental: false)
      #expect(Array(fresh.rgbaData) == [70, 80, 90, 255, 70, 80, 90, 255])
      #expect(Array(first.rgbaData) == rfbExpectedRGBA)
      await client.close()
    }
  }

  @Test func forcedRefreshWaitsForThenDiscardsAnInFlightPrefetch() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      // The explicit full refresh must not create a second outstanding request.
      try rfbExpectQuiet(fd, milliseconds: 100)
      try rfbWrite(fd, rfbRawHeader + [50, 40, 30, 0, 50, 40, 30, 0])
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [90, 80, 70, 0, 90, 80, 70, 0])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, prefetchFrames: true)
      try await client.connect()
      _ = try await client.nextFrame()
      let fresh = try await client.nextFrame(incremental: false)
      #expect(Array(fresh.rgbaData) == [70, 80, 90, 255, 70, 80, 90, 255])
      await client.close()
    }
  }

  @Test func prefetchedResizeRequiresCompleteNewGeometryCoverage() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 255, 255, 255, 33])
      let full: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 2, 0, 2]
      guard try rfbRead(fd, 10) == full else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [9, 8, 7, 0, 9, 8, 7, 0])
      guard try rfbRead(fd, 10) == full else { throw RfbPeerError.wire }
      var bottom = rfbRawHeader
      bottom[7] = 1
      try rfbWrite(fd, bottom + [6, 5, 4, 0, 6, 5, 4, 0])
      guard try rfbRead(fd, 10) == [3, 1, 0, 0, 0, 0, 0, 2, 0, 2] else {
        throw RfbPeerError.wire
      }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, prefetchFrames: true)
      try await client.connect()
      let first = try await client.nextFrame()
      try await Task.sleep(for: .milliseconds(100))
      let resized = try await client.nextFrame()
      #expect(resized.size.width == 2 && resized.size.height == 2)
      #expect(Array(resized.rgbaData) == [7, 8, 9, 255, 7, 8, 9, 255, 4, 5, 6, 255, 4, 5, 6, 255])
      #expect(Array(first.rgbaData) == rfbExpectedRGBA)
      await client.close()
    }
  }

  @Test func cancellationClosesAnIdlePrefetchAndCannotReuseTheClient() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, prefetchFrames: true)
      try await client.connect()
      _ = try await client.nextFrame()
      let pending = Task { try await client.nextFrame() }
      try await Task.sleep(for: .milliseconds(20))
      pending.cancel()
      await #expect(throws: CancellationError.self) { try await pending.value }
      await #expect(throws: RFBClientError.closed) {
        try await client.sendKey(keySym: 49, down: true)
      }
      await client.close()
    }
  }

  @Test func partialPrefetchKeepsItsMessageDeadline() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [3])
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, timeout: .milliseconds(200), prefetchFrames: true)
      try await client.connect()
      _ = try await client.nextFrame()
      await #expect(throws: RFBClientError.deadlineExceeded) { try await client.nextFrame() }
      await client.close()
    }
  }

  @Test func prefetchedPartialFrameNeverStarvesKeyUp() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [3])
      guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 50],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 50]
      else { throw RfbPeerError.wire }
      try rfbWrite(fd, Array(rfbRawPixels.dropFirst()))
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, prefetchFrames: true)
      try await client.connect()
      _ = try await client.nextFrame()
      try await client.sendKey(keySym: 50, down: true)
      try await client.sendKey(keySym: 50, down: false)
      let frame = try await client.nextFrame()
      #expect(Array(frame.rgbaData) == rfbExpectedRGBA)
      await client.close()
    }
  }

  @Test func unsolicitedUpdateCannotOverflowTheReadyPrefetch() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      let packet = rfbRawHeader + rfbRawPixels
      try rfbWrite(fd, packet + packet)
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, prefetchFrames: true)
      try await client.connect()
      _ = try await client.nextFrame()
      try await Task.sleep(for: .milliseconds(100))
      await #expect(throws: RFBClientError.unexpectedMessage) { try await client.nextFrame() }
      await client.close()
    }
  }

  @Test func earlyPrefetchStartsBeforeBodyCompletionAndNeverQueuesAThirdRequest() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      // Start a valid rectangle, but withhold all but one body byte.
      try rfbWrite(fd, rfbRawHeader + [3])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectQuiet(fd, milliseconds: 50)
      let next = rfbRawHeader + [50, 40, 30, 0, 50, 40, 30, 0]
      try rfbWrite(fd, Array(rfbRawPixels.dropFirst()) + next)
      // A slow consumer holds one ready frame and sends no fourth request.
      try rfbExpectQuiet(fd, milliseconds: 50)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, prefetchFrames: true, prefetchAfterHeader: true)
      try await client.connect()
      let first = try await client.nextFrame()
      let waiting = try await rfbSecondConsumer(client)
      defer { waiting.cancel() }
      let second = try await waiting.value
      try await Task.sleep(for: .milliseconds(100))
      let third = try await client.nextFrame()
      #expect(Array(first.rgbaData) == rfbExpectedRGBA)
      #expect(Array(second.rgbaData) == rfbExpectedRGBA)
      #expect(Array(third.rgbaData) == [30, 40, 50, 255, 30, 40, 50, 255])
      #expect(first.sequence < second.sequence && second.sequence < third.sequence)
      await client.close()
    }
  }

  @Test func earlyPrefetchStillRequiresAFreshForcedResponse() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      try rfbWrite(fd, rfbRawHeader + [3])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, Array(rfbRawPixels.dropFirst()))
      try rfbExpectQuiet(fd, milliseconds: 100)
      try rfbWrite(fd, rfbRawHeader + [50, 40, 30, 0, 50, 40, 30, 0])
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [90, 80, 70, 0, 90, 80, 70, 0])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, prefetchFrames: true, prefetchAfterHeader: true)
      try await client.connect()
      _ = try await client.nextFrame()
      let waiting = try await rfbSecondConsumer(client)
      defer { waiting.cancel() }
      _ = try await waiting.value
      let fresh = try await client.nextFrame(incremental: false)
      #expect(Array(fresh.rgbaData) == [70, 80, 90, 255, 70, 80, 90, 255])
      await client.close()
    }
  }

  @Test func earlyResizeDrainsTheOldRequestBeforeRequestingNewCoverage() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      // One validated pixel rectangle followed by a DesktopSize rectangle.
      // The resize is last, as required by the protocol, and invalidates the
      // just-decoded old-size pixels while an early request is already queued.
      var prefix = rfbRawHeader
      prefix[3] = 2
      prefix[9] = 1
      try rfbWrite(fd, prefix + [3])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, [2, 1, 0] + [0, 0, 0, 0, 0, 2, 0, 2, 255, 255, 255, 33])
      try rfbExpectQuiet(fd, milliseconds: 30)
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == [3, 0, 0, 0, 0, 0, 0, 2, 0, 2] else {
        throw RfbPeerError.wire
      }
      var full = rfbRawHeader
      full[11] = 2
      try rfbWrite(fd, full + Array(repeating: [UInt8(9), 8, 7, 0], count: 4).flatMap { $0 })
      guard try rfbRead(fd, 10) == [3, 1, 0, 0, 0, 0, 0, 2, 0, 2] else {
        throw RfbPeerError.wire
      }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, prefetchFrames: true, prefetchAfterHeader: true)
      try await client.connect()
      let first = try await client.nextFrame()
      let waiting = try await rfbSecondConsumer(client)
      defer { waiting.cancel() }
      let resized = try await waiting.value
      #expect(resized.size.width == 2 && resized.size.height == 2)
      #expect(
        Array(resized.rgbaData) == Array(repeating: [UInt8(7), 8, 9, 255], count: 4).flatMap { $0 })
      #expect(Array(first.rgbaData) == rfbExpectedRGBA)
      await client.close()
    }
  }

  @Test func resizeAcknowledgementNeverStartsEarlyPixelPrefetch() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      guard
        try rfbRead(fd, 24)
          == [251, 0, 0, 2, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0]
      else { throw RfbPeerError.wire }
      // This positive update header acknowledges SetDesktopSize; it is not
      // the response to the existing pixel request. An early request here
      // could be coalesced with that request by the evaluated QEMU server.
      try rfbWrite(fd, [0, 0, 0, 1])
      try rfbExpectQuiet(fd, milliseconds: 30)
      try rfbWrite(fd, [0, 1, 0, 0, 0, 2, 0, 1, 255, 255, 254, 204])
      try rfbExpectQuiet(fd, milliseconds: 30)
      try rfbWrite(fd, [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0])
      try rfbExpectQuiet(fd, milliseconds: 30)
      try rfbWrite(fd, rfbRawHeader + [3])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, Array(rfbRawPixels.dropFirst()))
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, prefetchFrames: true, prefetchAfterHeader: true)
      try await client.connect()
      _ = try await client.nextFrame()
      let waiting = try await rfbSecondConsumer(client)
      defer { waiting.cancel() }
      try await client.requestDesktopSize(PixelSize(width: 2, height: 1))
      let next = try await waiting.value
      #expect(next.size == PixelSize(width: 2, height: 1))
      #expect(Array(next.rgbaData) == rfbExpectedRGBA)
      await client.close()
    }
  }

  @Test func earlyPartialPipelineKeepsItsDeadline() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      try rfbWrite(fd, rfbRawHeader + [3])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, timeout: .milliseconds(200), prefetchFrames: true,
        prefetchAfterHeader: true)
      try await client.connect()
      _ = try await client.nextFrame()
      let waiting = try await rfbSecondConsumer(client)
      defer { waiting.cancel() }
      await #expect(throws: RFBClientError.deadlineExceeded) { try await waiting.value }
      await client.close()
    }
  }

  @Test func earlyPipelineCancellationNeverStarvesKeyUp() async throws {
    let pipelined = DispatchSemaphore(value: 0)
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      try rfbWrite(fd, rfbRawHeader + [3])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      pipelined.signal()
      guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 50],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 50]
      else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, prefetchFrames: true, prefetchAfterHeader: true)
      try await client.connect()
      _ = try await client.nextFrame()
      let waiting = try await rfbSecondConsumer(client)
      defer { waiting.cancel() }
      let ready = await Task.detached { rfbWaitPipeline(pipelined) }.value
      #expect(ready)
      try await client.sendKey(keySym: 50, down: true)
      try await client.sendKey(keySym: 50, down: false)
      waiting.cancel()
      await #expect(throws: CancellationError.self) { try await waiting.value }
      await #expect(throws: RFBClientError.closed) {
        try await client.sendKey(keySym: 49, down: true)
      }
      await client.close()
    }
  }

  @Test func malformedEarlyRectanglePoisonsBothOutstandingRequests() async throws {
    let allowMalformed = DispatchSemaphore(value: 0)
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbConsumerBridge(fd)
      // Let the bridge key-up finish returning before deliberately poisoning
      // the connection; its delivery is a separate operation under test.
      guard rfbWaitPipeline(allowMalformed) else { throw RfbPeerError.timeout }
      var prefix = rfbRawHeader
      prefix[3] = 2
      prefix[9] = 1
      try rfbWrite(fd, prefix + [3])
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      var rectangle = Array(rfbRawHeader.dropFirst(4))
      rectangle[11] = 5
      try rfbWrite(fd, [2, 1, 0] + rectangle)
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, prefetchFrames: true, prefetchAfterHeader: true)
      try await client.connect()
      _ = try await client.nextFrame()
      let waiting = try await rfbSecondConsumer(client)
      defer { waiting.cancel() }
      allowMalformed.signal()
      await #expect(throws: RFBClientError.unsupportedMessage) { try await waiting.value }
      await client.close()
    }
  }

  @Test func earlyPrefetchDoesNotStartBeforeTheFirstConsumerRequest() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      try rfbExpectQuiet(fd, milliseconds: 30)
      guard try rfbRead(fd, 10) == rfbFullRequest else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == rfbIncrementalRequest else { throw RfbPeerError.wire }
      try rfbExpectClosed(fd)
    } body: { peer in
      let client = RFBClient(
        socketURL: peer.socketURL, prefetchFrames: true, prefetchAfterHeader: true)
      try await client.connect()
      try await Task.sleep(for: .milliseconds(80))
      let first = try await client.nextFrame()
      #expect(Array(first.rgbaData) == rfbExpectedRGBA)
      await client.close()
    }
  }

  @Test func resizeRequestsFullCoverageBeforePublishing() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      _ = try rfbRead(fd, 10)
      try rfbWrite(fd, rfbRawHeader + rfbRawPixels)
      guard try rfbRead(fd, 10) == [3, 1, 0, 0, 0, 0, 0, 2, 0, 1] else { throw RfbPeerError.wire }
      try rfbWrite(fd, [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 255, 255, 255, 33])
      guard try rfbRead(fd, 10) == [3, 0, 0, 0, 0, 0, 0, 2, 0, 2] else { throw RfbPeerError.wire }
      try rfbWrite(fd, rfbRawHeader + [9, 8, 7, 0, 9, 8, 7, 0])
      guard try rfbRead(fd, 10) == [3, 0, 0, 0, 0, 0, 0, 2, 0, 2] else { throw RfbPeerError.wire }
      var bottom = rfbRawHeader
      bottom[7] = 1
      try rfbWrite(fd, bottom + [6, 5, 4, 0, 6, 5, 4, 0])
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let first = try await client.nextFrame()
      let resized = try await client.nextFrame()
      #expect(first.connectionEpoch == resized.connectionEpoch && resized.sequence == 2)
      #expect(resized.size.width == 2 && resized.size.height == 2)
      #expect(Array(resized.rgbaData) == [7, 8, 9, 255, 7, 8, 9, 255, 4, 5, 6, 255, 4, 5, 6, 255])
      await client.close()
    }
  }

  @Test func fragmented257RectanglesStayWithinTransportActionBudgetAcrossFrames() async throws {
    try await withRfbPeer { fd in
      var header = rfbServerHeader
      header[0] = 1
      header[1] = 1
      try rfbHandshake(fd, header: header)
      try rfbFormat(fd)
      guard try rfbRead(fd, 10) == [3, 0, 0, 0, 0, 0, 1, 1, 0, 1] else {
        throw RfbPeerError.wire
      }
      var update: [UInt8] = [0, 0, 1, 1]
      for x in 0..<257 {
        update.append(contentsOf: [
          UInt8(x >> 8), UInt8(x & 255), 0, 0, 0, 1, 0, 1, 0, 0, 0, 0,
          UInt8(x & 255), 2, 3, 99,
        ])
      }
      try rfbWrite(fd, update, fragmented: true)
      guard try rfbRead(fd, 10) == [3, 1, 0, 0, 0, 0, 1, 1, 0, 1] else {
        throw RfbPeerError.wire
      }
      try rfbWrite(fd, [0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 8, 7, 6, 0])
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let first = try await client.nextFrame()
      var expected: [UInt8] = []
      for x in 0..<257 { expected.append(contentsOf: [3, 2, UInt8(x & 255), 255]) }
      #expect(first.size.width == 257 && first.size.height == 1 && first.sequence == 1)
      #expect(Array(first.rgbaData) == expected)
      let second = try await client.nextFrame()
      expected.replaceSubrange(1024..<1028, with: [6, 7, 8, 255])
      #expect(first.connectionEpoch == second.connectionEpoch && second.sequence == 2)
      #expect(Array(second.rgbaData) == expected)
      await client.close()
    }
  }

  @Test(arguments: ["geometry", "encoding", "partial"])
  func malformedOrStalledUpdatePoisonsConnection(_ mode: String) async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      _ = try rfbRead(fd, 10)
      var bytes = rfbRawHeader
      switch mode {
      case "geometry": bytes[5] = 2
      case "encoding": bytes[15] = 1
      default: bytes = [0]
      }
      try rfbWrite(fd, bytes)
      if mode == "partial" { _ = Darwin.poll(nil, 0, 300) }
      // Remain alive until the poisoned client actually closes its own connection.
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL, timeout: .milliseconds(150))
      try await client.connect()
      let expected: RFBClientError =
        switch mode {
        case "encoding": .unsupportedMessage
        case "partial": .deadlineExceeded
        default: .malformedMessage
        }
      await #expect(throws: expected) { try await client.nextFrame() }
      await #expect(throws: RFBClientError.closed) { try await client.nextFrame() }
      await client.close()
    }
  }

  @Test(arguments: ["dimension", "pixels", "name"])
  func initializationBoundsFailBeforeFrameAllocation(_ mode: String) async throws {
    try await withRfbPeer { fd in
      var header = rfbServerHeader
      switch mode {
      case "dimension":
        header[0] = 32
        header[1] = 1
      case "pixels":
        header[0] = 32
        header[1] = 0
        header[2] = 8
        header[3] = 1
      default:
        header[20] = 255
        header[21] = 255
        header[22] = 255
        header[23] = 255
      }
      try? rfbHandshake(fd, header: header)
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      await #expect(throws: RFBClientError.limitExceeded) { try await client.connect() }
      await client.close()
    }
  }

  @Test func closeReleasesHeldKeyAndCancelsOnlyFrameTransport() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      _ = try rfbRead(fd, 10)
      guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 49],
        try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 50],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 49],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 50]
      else { throw RfbPeerError.wire }
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let pending = Task { try await client.nextFrame() }
      try await Task.sleep(for: .milliseconds(20))
      try await client.sendKey(keySym: 49, down: true)
      try await client.sendKey(keySym: 50, down: true)
      async let firstClose: Void = client.close()
      async let secondClose: Void = client.close()
      _ = await (firstClose, secondClose)
      await #expect(throws: (any Error).self) { try await pending.value }
      await client.close()
    }
  }

  @Test func cancelledFrameWaitCannotBeReused() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      _ = try rfbRead(fd, 10)
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let pending = Task { try await client.nextFrame() }
      try await Task.sleep(for: .milliseconds(20))
      pending.cancel()
      await #expect(throws: CancellationError.self) { try await pending.value }
      await #expect(throws: RFBClientError.closed) {
        try await client.sendKey(keySym: 49, down: true)
      }
      await client.close()
    }
  }

  @Test func orderedOverlapUsesLastPixelsAndCoverageUnion() async throws {
    try await withRfbPeer { fd in
      var header = rfbServerHeader
      header[1] = 3
      try rfbHandshake(fd, header: header)
      try rfbFormat(fd)
      let full: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 3, 0, 1]
      guard try rfbRead(fd, 10) == full else { throw RfbPeerError.wire }
      var first = rfbRawHeader
      first[3] = 2
      let overlap: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 9, 8, 7, 0]
      try rfbWrite(fd, first + rfbRawPixels + overlap)
      // Two overlapping rectangles initialized only two of three pixels. The
      // client must request full coverage again instead of publishing a hole.
      guard try rfbRead(fd, 10) == full else { throw RfbPeerError.wire }
      try rfbWrite(fd, [0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 6, 5, 4, 0])
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      let frame = try await client.nextFrame()
      #expect(frame.size.width == 3 && frame.sequence == 1)
      #expect(Array(frame.rgbaData) == [1, 2, 3, 255, 7, 8, 9, 255, 4, 5, 6, 255])
      await client.close()
    }
  }

  @Test func droppingAnIdleClientClosesItsOwnedConnection() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      var bytes = [UInt8](repeating: 0, count: 128)
      var total = 0
      while true {
        let count = Darwin.recv(fd, &bytes, bytes.count, 0)
        guard count >= 0 else { throw RfbPeerError.timeout }
        if count == 0 { break }
        total += count
        guard total <= rfbPixelRequest.count + rfbEncodings.count else { throw RfbPeerError.wire }
      }
    } body: { peer in
      var client: RFBClient? = RFBClient(socketURL: peer.socketURL)
      let witness = RfbClientWitness(client)
      try await client?.connect()
      withExtendedLifetime(client) {}
      client = nil
      #expect(witness.value == nil)
    }
  }

  @Test func overlappingDownUpCallsRemainOrderedOnTheWire() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      guard try rfbRead(fd, 8) == [4, 1, 0, 0, 0, 0, 0, 49],
        try rfbRead(fd, 8) == [4, 0, 0, 0, 0, 0, 0, 49]
      else { throw RfbPeerError.wire }
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      async let down: Void = client.sendKey(keySym: 49, down: true)
      async let up: Void = client.sendKey(keySym: 49, down: false)
      _ = try await (down, up)
      // If up was admitted first it was a no-op; close must still release the
      // later down. Either actor admission order produces exactly down then up.
      await client.close()
    }
  }

  @Test func overflowRecoveryOnlyReleasesKeysAndLeavesNoTextPresses() async throws {
    try await withRfbPeer { fd in
      try rfbHandshake(fd)
      try rfbFormat(fd)
      var released = Set<UInt32>()
      for _ in 0..<113 {
        let bytes = try rfbRead(fd, 8)
        guard bytes.prefix(4) == [4, 0, 0, 0] else { throw RfbPeerError.wire }
        released.insert(bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
      }
      guard released.contains(0x35), released.contains(0xffe3), released.contains(0xffeb),
        released.count == 113
      else { throw RfbPeerError.wire }
      var byte: UInt8 = 0
      guard Darwin.recv(fd, &byte, 1, 0) == 0 else { throw RfbPeerError.wire }
    } body: { peer in
      let client = RFBClient(socketURL: peer.socketURL)
      try await client.connect()
      try await client.recoverKeyboardAfterOverflow()
      await client.close()
    }
  }

  @Test func capturedIdentityAndPrivatePathAreRequired() async throws {
    let peer = try RfbPeer { _ in }
    defer { peer.remove() }
    let incorrect = RFBEndpointIdentity(
      parentDevice: 0, parentInode: 0, socketDevice: 0, socketInode: 0)
    let client = RFBClient(socketURL: peer.socketURL, expectedIdentity: incorrect)
    await #expect(throws: RFBClientError.unsafeSocket) { try await client.connect() }
    await client.close()
    let alias = peer.directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: peer.directory)
    let unsafe = RFBClient(socketURL: alias.appendingPathComponent("display.sock"))
    await #expect(throws: RFBClientError.unsafeSocket) { try await unsafe.connect() }
    await unsafe.close()
    await peer.stop()
  }
}
