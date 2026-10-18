// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

public struct RFBEndpointIdentity: Equatable, Sendable {
  public let parentDevice: Int32
  public let parentInode: UInt64
  public let socketDevice: Int32
  public let socketInode: UInt64
  public init(parentDevice: Int32, parentInode: UInt64, socketDevice: Int32, socketInode: UInt64) {
    self.parentDevice = parentDevice
    self.parentInode = parentInode
    self.socketDevice = socketDevice
    self.socketInode = socketInode
  }
}

/// Opaque-alpha bytes in top-left row order: R,G,B,255; stride is width*4.
public struct RFBFrame: Sendable {
  public let connectionEpoch: UUID
  public let sequence: UInt64
  public let size: PixelSize
  public let rgbaData: Data
}

public enum RFBClientError: Error, Equatable, Sendable {
  case unsafeSocket, invalidTimeout, alreadyConnected, notConnected, closed, busy
  case malformedMessage, unsupportedMessage, limitExceeded, unexpectedMessage
  case disconnected, deadlineExceeded, unsupportedKey, invalidPointer, identifierExhausted
  case pointerModeChanged
  case posix(Int32)
}

/// One private display connection. VM/session binding is supplied by the worker
/// route; RFB desktop-name text never supplies ownership or identity authority.
public actor RFBClient {
  public nonisolated let connectionEpoch: UUID
  private enum State { case idle, connecting, ready, closed }
  private let transport: RfbTransport
  private let timeout: Duration
  private var state: State = .idle
  private var framePending = false
  private var heldKeys: Set<UInt32> = []
  private var frameSize: PixelSize?
  private var pointer: (x: UInt16, y: UInt16, buttons: UInt8)?
  private var relativePointer = false
  private enum InputWrite: Sendable {
    case key(UInt32, Bool)
    case pointer(UInt16, UInt16, UInt8, Bool)
  }
  private var releasingKeys = false
  private var pendingKeyWrites = 0
  private var keyTail: Task<Void, Error>?
  private var closeTask: Task<Void, Never>?

  public init(
    socketURL: URL, expectedIdentity: RFBEndpointIdentity? = nil, timeout: Duration = .seconds(3),
    prefetchFrames: Bool = false, prefetchAfterHeader: Bool = false
  ) {
    let epoch = UUID()
    connectionEpoch = epoch
    transport = RfbTransport(
      socketURL: socketURL, expectedIdentity: expectedIdentity, timeout: timeout, epoch: epoch,
      prefetchFrames: prefetchFrames, prefetchAfterHeader: prefetchAfterHeader)
    self.timeout = timeout
  }

  deinit { transport.signalClose() }

  public func connect() async throws {
    guard state != .closed else { throw RFBClientError.closed }
    guard state == .idle else { throw RFBClientError.alreadyConnected }
    guard timeout > .zero, timeout <= .seconds(30) else { throw RFBClientError.invalidTimeout }
    state = .connecting
    let transport = transport
    do {
      try Task.checkCancellation()
      try await withTaskCancellationHandler {
        try await transport.connect()
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      guard state != .closed else { throw RFBClientError.closed }
      state = .ready
    } catch {
      state = .closed
      await close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  /// One outstanding wire request by default. Experimental early prefetch is
  /// for the evaluated QEMU server, whose queued output already owns the
  /// current response; arbitrary RFB peers can coalesce requests differently.
  /// Early prefetch permits at most two (one current response and one next
  /// request), and both prefetch modes retain at most one ready immutable frame
  /// while the consumer presents the previous frame. An explicit
  /// full refresh discards that prefetch and requests a fresh complete update.
  /// Quiet incremental frames wait event-driven; key
  /// writes and close continue independently while this method is suspended.
  /// Set incremental to false for an explicit full refresh; ordinary rendering
  /// remains incremental and event-driven.
  public func nextFrame(incremental: Bool = true) async throws -> RFBFrame {
    try requireReady()
    guard !framePending else { throw RFBClientError.busy }
    framePending = true
    defer { framePending = false }
    let transport = transport
    do {
      try Task.checkCancellation()
      let frame = try await withTaskCancellationHandler {
        try await transport.nextFrame(incremental: incremental)
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      try requireReady()
      frameSize = frame.size
      return frame
    } catch {
      state = .closed
      heldKeys.removeAll()
      await close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  /// Request one screen size through the public RFB extension. This reports
  /// transport delivery only; the guest's resulting framebuffer is authoritative.
  public func requestDesktopSize(_ size: PixelSize) async throws {
    try requireReady()
    await releaseInput()
    try requireReady()
    try await transport.requestDesktopSize(size)
  }

  /// Explicit test recovery after a known remote keyboard-queue overflow.
  /// Releases a fixed physical key set; never generates a press or text.
  public func recoverKeyboardAfterOverflow() async throws {
    try requireReady()
    await releaseInput()
    try requireReady()
    let modifiers: [UInt32] = [0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe9, 0xffea, 0xffeb, 0xffec]
    let keys =
      modifiers + Array(UInt32(32)...UInt32(126))
      + [0xff08, 0xff09, 0xff0d, 0xff1b, 0xff50, 0xff51, 0xff52, 0xff53, 0xff54, 0xffff]
    for key in keys {
      try await transport.sendKey(key, down: false)
      try await Task.sleep(for: .milliseconds(8))
    }
  }

  /// Bounded printable, Unicode, navigation, function and modifier keysyms.
  /// Successful return means bytes were written, not that the guest accepted a key.
  public func sendKey(keySym: UInt32, down: Bool) async throws {
    try requireReady()
    guard !releasingKeys else { throw RFBClientError.busy }
    guard RFBKeySymbol.isSupported(keySym) else { throw RFBClientError.unsupportedKey }
    if down {
      guard !heldKeys.contains(keySym) else { return }
      guard heldKeys.count < 64 else { throw RFBClientError.limitExceeded }
      heldKeys.insert(keySym)
    } else {
      guard heldKeys.remove(keySym) != nil else { return }
    }
    let transport = transport
    do {
      try Task.checkCancellation()
      let write = try enqueueKeys([(keySym, down)])
      try await withTaskCancellationHandler {
        try await write.value
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      try requireReady()
    } catch {
      state = .closed
      heldKeys.removeAll()
      await close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  /// Absolute guest pixels bound to the last delivered framebuffer. Three mouse
  /// buttons only; a successful write is not a guest acknowledgement.
  public func sendPointer(x: UInt16, y: UInt16, buttons: UInt8, frameSize expected: PixelSize)
    async throws
  {
    try requireReady()
    guard !releasingKeys else { throw RFBClientError.busy }
    guard frameSize == expected, Int(x) < expected.width, Int(y) < expected.height,
      buttons & ~7 == 0
    else { throw RFBClientError.invalidPointer }
    do {
      try Task.checkCancellation()
      let write = try enqueueInput([.pointer(x, y, buttons, false)])
      pointer = (x, y, buttons)
      relativePointer = false
      let transport = transport
      try await withTaskCancellationHandler {
        try await write.value
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      try requireReady()
    } catch {
      if error as? RFBClientError == .pointerModeChanged {
        pointer = nil
        throw error
      }
      await close()
      throw error
    }
  }

  /// Confirms the independently received QEMU pointer-mode notification.
  public func waitForPointerMode(relative: Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      try requireReady()
      if await transport.pointerIsRelative() == relative {
        guard pointer?.buttons ?? 0 == 0 else { throw RFBClientError.busy }
        relativePointer = relative
        pointer = nil
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RFBClientError.deadlineExceeded
  }

  /// QEMU's published extension biases signed deltas by 0x7fff. Release state
  /// always stores zero motion so focus loss cannot replay the last camera turn.
  public func sendRelativePointer(dx: Int, dy: Int, buttons: UInt8) async throws {
    try requireReady()
    guard !releasingKeys, (-32767...32767).contains(dx), (-32767...32767).contains(dy),
      buttons & ~7 == 0
    else { throw RFBClientError.invalidPointer }
    do {
      let write = try enqueueInput([.pointer(UInt16(dx + 32767), UInt16(dy + 32767), buttons, true)]
      )
      pointer = (32767, 32767, buttons)
      relativePointer = true
      try await write.value
      try requireReady()
    } catch {
      if error as? RFBClientError == .pointerModeChanged {
        pointer = nil
        throw error
      }
      await close()
      throw error
    }
  }

  /// RFC 6143 vertical wheel pulses, bounded to eight detents per admission.
  /// Positive steps scroll upward. Every pulse restores the held mouse buttons.
  public func sendScroll(x: UInt16, y: UInt16, steps: Int, frameSize expected: PixelSize)
    async throws
  {
    try requireReady()
    guard !releasingKeys else { throw RFBClientError.busy }
    guard frameSize == expected, Int(x) < expected.width, Int(y) < expected.height,
      (-8...8).contains(steps)
    else { throw RFBClientError.invalidPointer }
    guard steps != 0 else { return }
    let buttons = pointer?.buttons ?? 0
    let wheel: UInt8 = steps > 0 ? 8 : 16
    var events: [InputWrite] = []
    for _ in 0..<abs(steps) {
      events.append(
        .pointer(
          relativePointer ? 32767 : x, relativePointer ? 32767 : y, buttons | wheel, relativePointer
        ))
      events.append(
        .pointer(relativePointer ? 32767 : x, relativePointer ? 32767 : y, buttons, relativePointer)
      )
    }
    do {
      try Task.checkCancellation()
      let write = try enqueueInput(events)
      pointer = (relativePointer ? 32767 : x, relativePointer ? 32767 : y, buttons)
      let transport = transport
      try await withTaskCancellationHandler {
        try await write.value
      } onCancel: {
        transport.signalClose()
      }
      try Task.checkCancellation()
      try requireReady()
    } catch {
      if error as? RFBClientError == .pointerModeChanged {
        pointer = nil
        throw error
      }
      await close()
      throw error
    }
  }

  /// Releases all held keyboard and pointer input before focus loss or detach.
  public func releaseInput() async {
    await releaseKeys()
    guard state == .ready, let pointer, pointer.buttons != 0 else { return }
    self.pointer = (pointer.x, pointer.y, 0)
    do {
      let write = try enqueueInput([.pointer(pointer.x, pointer.y, 0, relativePointer)])
      try await write.value
    } catch { await close() }
  }

  public func releaseKeys() async {
    guard state == .ready, !releasingKeys else { return }
    releasingKeys = true
    defer { releasingKeys = false }
    let keys = heldKeys.sorted()
    heldKeys.removeAll()
    do {
      let write = try enqueueKeys(keys.map { ($0, false) })
      try await write.value
    } catch { await close() }
  }

  /// Best-effort ordered key-ups precede descriptor shutdown. This connection has
  /// no runtime control, child-signaling, intent or worker-stop capability.
  public func close() async {
    if let closeTask {
      await closeTask.value
      return
    }
    let keys = heldKeys.sorted()
    heldKeys.removeAll()
    let wasReady = state == .ready
    state = .closed
    let prior = keyTail
    var releases = keys.map { InputWrite.key($0, false) }
    if let pointer, pointer.buttons != 0 {
      releases.append(.pointer(pointer.x, pointer.y, 0, relativePointer))
    }
    pointer = nil
    let write = wasReady ? try? enqueueInput(releases) : nil
    let transport = transport
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let task = Task {
      if let write {
        _ = try? await write.value
      } else {
        if let prior { _ = try? await prior.value }
        if wasReady {
          for release in releases {
            switch release {
            case .key(let key, let down):
              try? await transport.sendKey(key, down: down, deadline: deadline)
            case .pointer(let x, let y, let buttons, let relative):
              try? await transport.sendPointer(
                x: x, y: y, buttons: buttons, deadline: deadline, relative: relative)
            }
          }
        }
      }
      await transport.close()
    }
    closeTask = task
    await task.value
  }

  /// Admission is synchronous on this actor; the bounded tail preserves its
  /// order across generic-executor hops and joins close with prior key releases.
  private func enqueueKeys(_ keys: [(UInt32, Bool)]) throws -> Task<Void, Error> {
    try enqueueInput(keys.map { .key($0.0, $0.1) })
  }

  private func enqueueInput(_ input: [InputWrite]) throws -> Task<Void, Error> {
    guard pendingKeyWrites < 64 else { throw RFBClientError.limitExceeded }
    pendingKeyWrites += 1
    let prior = keyTail
    let transport = transport
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let write = Task { [self] in
      defer { pendingKeyWrites -= 1 }
      if let prior {
        do { try await prior.value } catch {
          guard error as? RFBClientError == .pointerModeChanged else { throw error }
        }
      }
      for event in input {
        switch event {
        case .key(let key, let down):
          try await transport.sendKey(key, down: down, deadline: deadline)
          // QEMU's USB keyboard consumes one queued HID event per 8 ms poll
          // and has only 16 slots. Socket delivery is not guest consumption.
          // Preserve press/release order during bursts instead of overflowing
          // that queue and leaving a key logically held in Windows.
          try await Task.sleep(for: .milliseconds(8))
        case .pointer(let x, let y, let buttons, let relative):
          try await transport.sendPointer(
            x: x, y: y, buttons: buttons, deadline: deadline, relative: relative)
        }
      }
    }
    keyTail = write
    return write
  }

  private func requireReady() throws {
    guard state != .closed else { throw RFBClientError.closed }
    guard state == .ready else { throw RFBClientError.notConnected }
  }
}
