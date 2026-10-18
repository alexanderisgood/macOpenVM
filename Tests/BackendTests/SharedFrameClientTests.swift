// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Darwin
import Foundation
import SharedFrameFixture
import SharedFrameWire
import Testing

@testable import MacOpenVMApp
@testable import Qemu

@MainActor private final class SharedVisibilityWindow: NSWindow {
  var reportedVisible = false
  override var isVisible: Bool { reportedVisible }
  override var isOnActiveSpace: Bool { true }
  override var occlusionState: NSWindow.OcclusionState { reportedVisible ? [.visible] : [] }
}

@MainActor private final class SharedGeometryWindow: NSWindow {
  var reportedScale: CGFloat = 1
  override var backingScaleFactor: CGFloat { reportedScale }
  override var isVisible: Bool { false }
}

@MainActor private func exerciseSharedLayerGeometry(_ frame: SharedFrame) async throws {
  _ = NSApplication.shared
  let window = SharedGeometryWindow(
    contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
    backing: .buffered, defer: true)
  let replacement = SharedGeometryWindow(
    contentRect: NSRect(x: 0, y: 0, width: 96, height: 48), styleMask: .borderless,
    backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  replacement.isReleasedWhenClosed = false
  let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
  window.contentView = view
  view.update(
    frame: RFBFrame(
      connectionEpoch: frame.connectionEpoch, sequence: 1, size: frame.size,
      rgbaData: Data(repeating: 0, count: frame.size.width * frame.size.height * 4)))
  defer {
    view.stopShared()
    window.contentView = nil
    replacement.contentView = nil
  }
  _ = try await view.presentShared(frame)
  let renderer = try #require(view.sharedRendererForValidation())
  let surface = try #require(view.subviews.first as? SharedFrameMetalSurface)
  let layer = try #require(surface.layer as? CAMetalLayer)
  func expectGeometry(in window: SharedGeometryWindow) {
    #expect(surface.frame == view.bounds)
    #expect(layer.contentsScale == window.backingScaleFactor)
    #expect(layer.drawableSize == view.convertToBacking(view.bounds).size)
  }
  expectGeometry(in: window)
  // Stable frames must preserve actual layer geometry and independent GPU copies.
  _ = try await view.presentShared(frame)
  expectGeometry(in: window)
  #expect((await renderer.drawableRetryStateForValidation()).copies == 2)

  view.setFrameSize(NSSize(width: 80, height: 48))
  expectGeometry(in: window)
  view.setBoundsSize(NSSize(width: 40, height: 24))
  expectGeometry(in: window)
  // The next receipt must reconcile a bounds origin even without a size callback.
  view.setBoundsOrigin(NSPoint(x: 7, y: 11))
  _ = try await view.presentShared(frame)
  expectGeometry(in: window)
  #expect(surface.frame.origin == NSPoint(x: 7, y: 11))

  // Backing notifications and receipt both consult current scale, not cached geometry.
  window.reportedScale = 2
  view.viewDidChangeBackingProperties()
  expectGeometry(in: window)
  window.reportedScale = 3
  _ = try await view.presentShared(frame)
  expectGeometry(in: window)

  // Each mismatch independently needs repair even when view/window geometry is stable.
  surface.frame = surface.frame.offsetBy(dx: 1, dy: 2)
  _ = try await view.presentShared(frame)
  expectGeometry(in: window)
  layer.contentsScale = 9
  _ = try await view.presentShared(frame)
  expectGeometry(in: window)
  layer.drawableSize = CGSize(width: 1, height: 1)
  _ = try await view.presentShared(frame)
  expectGeometry(in: window)

  // Existing renderer, different window/backing context, then a new backing surface.
  window.contentView = nil
  replacement.reportedScale = 2
  replacement.contentView = view
  _ = try await view.presentShared(frame)
  expectGeometry(in: replacement)
  #expect(view.sharedRendererForValidation() === renderer)
  #expect(await renderer.drawableRequestsForValidation() == 0)
  view.stopShared()
  _ = try await view.presentShared(frame)
  let recreated = try #require(view.subviews.first as? SharedFrameMetalSurface)
  let recreatedLayer = try #require(recreated.layer as? CAMetalLayer)
  #expect(recreated !== surface)
  #expect(recreated.frame == view.bounds)
  #expect(recreatedLayer.contentsScale == replacement.backingScaleFactor)
  #expect(recreatedLayer.drawableSize == view.convertToBacking(view.bounds).size)
}

private final class SharedVisibilityAcquisition: @unchecked Sendable {
  private let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var timedOut = false
  private var schedules = 0
  private var completions = 0

  func acquire() -> Bool {
    let released = gate.wait(timeout: .now() + 5) == .success
    lock.withLock {
      timedOut = !released
      completions += 1
    }
    return false
  }

  func release() { gate.signal() }
  func recordSchedule() { lock.withLock { schedules += 1 } }
  var succeeded: Bool { lock.withLock { !timedOut && schedules == 0 && completions == 1 } }
}

@MainActor private func exerciseVisibilityReconciliation(_ frame: SharedFrame) async throws {
  _ = NSApplication.shared
  let window = SharedVisibilityWindow(
    contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
    backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  let view = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
  window.contentView = view
  view.update(
    frame: RFBFrame(
      connectionEpoch: frame.connectionEpoch, sequence: 1, size: frame.size,
      rgbaData: Data(repeating: 0, count: 64 * 64 * 4)))
  defer {
    view.stopShared()
    window.contentView = nil
  }
  _ = try await view.presentShared(frame)
  #expect(await view.sharedDrawableRequestsForValidation() == 0)
  let renderer = try #require(view.sharedRendererForValidation())
  let acquisition = SharedVisibilityAcquisition()
  defer { acquisition.release() }
  try await renderer.configureDrawableRetryValidation(
    acquire: { acquisition.acquire() }, schedule: { _, _ in acquisition.recordSchedule() })
  let hidden = await renderer.drawableRetryStateForValidation()
  #expect(!hidden.active && !hidden.pending && hidden.copies == 1)
  let surface = try #require(view.subviews.first as? SharedFrameMetalSurface)
  #expect(surface.frame == view.bounds)
  #expect(surface.layer is CAMetalLayer)
  #expect(view.hitTest(NSPoint(x: 32, y: 32)) === view)
  // No window is shown, and no occlusion notification is posted. The next
  // received frame must reconcile a visibility change missed at attachment.
  window.reportedVisible = true
  _ = try await view.presentShared(frame)
  let visible = await renderer.drawableRetryStateForValidation()
  #expect(visible.active && visible.pending && visible.requests == 1 && visible.copies == 2)
  view.setFrameSize(NSSize(width: 80, height: 48))
  #expect(surface.frame == view.bounds)
  #expect((surface.layer as? CAMetalLayer)?.drawableSize == view.convertToBacking(view.bounds).size)
  window.reportedVisible = false
  _ = try await view.presentShared(frame)
  let hiddenAgain = await renderer.drawableRetryStateForValidation()
  #expect(!hiddenAgain.active && hiddenAgain.requests == 1 && hiddenAgain.copies == 3)
  #expect(hiddenAgain.pending && !hiddenAgain.scheduled)
  acquisition.release()
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  var settled = await renderer.drawableRetryStateForValidation()
  while settled.pending && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(1))
    settled = await renderer.drawableRetryStateForValidation()
  }
  #expect(!settled.pending && !settled.active && !settled.scheduled)
  #expect(settled.requests == 1 && settled.draws == 0 && settled.copies == 3)
  #expect(acquisition.succeeded)
}

private func sharedWait(_ gate: DispatchSemaphore) -> Bool {
  gate.wait(timeout: .now() + 1) == .success
}

private func sharedWaitForCopiedFrame(_ gate: DispatchSemaphore) -> Bool {
  gate.wait(timeout: .now() + 3) == .success
}

private let sharedEpoch = Array(UInt8(1)...UInt8(16))
private func sharedWire(
  _ kind: UInt16, sequence: UInt64 = 0, generation: UInt64 = 0,
  width: UInt32 = 0, height: UInt32 = 0, stride: UInt32 = 0, bytes: UInt32 = 0,
  slot: UInt32 = 0, format: UInt32 = 0, sent: UInt64 = 0, epoch: [UInt8] = sharedEpoch
) -> [UInt8] {
  var result = [UInt8](repeating: 0, count: 80)
  func put(_ value: UInt64, _ offset: Int, _ count: Int) {
    for i in 0..<count { result[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
  }
  put(0x534f_564d, 0, 4)
  put(1, 4, 2)
  put(UInt64(kind), 6, 2)
  result.replaceSubrange(8..<24, with: epoch)
  put(sequence, 24, 8)
  put(generation, 32, 8)
  put(UInt64(width), 40, 4)
  put(UInt64(height), 44, 4)
  put(UInt64(stride), 48, 4)
  put(UInt64(bytes), 52, 4)
  put(UInt64(slot), 56, 4)
  put(UInt64(format), 60, 4)
  put(sent, 64, 8)
  return result
}
private func sharedKind(_ bytes: [UInt8], _ kind: UInt8) -> [UInt8] {
  var copy = bytes
  copy[6] = kind
  return copy
}
private func sharedIdentity(_ peer: RfbPeer) throws -> RFBEndpointIdentity {
  var parent = stat()
  var socket = stat()
  guard lstat(peer.directory.path, &parent) == 0, lstat(peer.socketURL.path, &socket) == 0
  else { throw RfbPeerError.posix(errno) }
  return RFBEndpointIdentity(
    parentDevice: parent.st_dev, parentInode: parent.st_ino,
    socketDevice: socket.st_dev, socketInode: socket.st_ino)
}
private func sharedSend(_ fd: Int32, _ bytes: [UInt8], descriptors: [Int32], fragment: Bool = false)
  throws
{
  let count = fragment ? 1 : bytes.count
  let written = bytes.withUnsafeBytes { b in
    descriptors.withUnsafeBufferPointer { d in
      mvo_fixture_send(fd, b.bindMemory(to: UInt8.self).baseAddress, count, d.baseAddress, d.count)
    }
  }
  guard written == count else { throw RfbPeerError.wire }
  if fragment { try rfbWrite(fd, Array(bytes.dropFirst()), fragmented: true) }
}
private func withSharedPeer(
  _ script: @escaping @Sendable (Int32) throws -> Void,
  body: (SharedFrameClient) async throws -> Void
) async throws {
  let peer = try RfbPeer(script)
  defer { peer.remove() }
  let client = SharedFrameClient(
    socketURL: peer.socketURL,
    expectedIdentity: try sharedIdentity(peer), connectionEpoch: UUID())
  do {
    try await body(client)
    await client.close()
    try await peer.wait()
  } catch {
    await client.close()
    await peer.stop()
    throw error
  }
}

private func sharedAwaitPartialAssembly(
  _ client: SharedFrameClient, receivedBytes: Int
) async throws -> ContinuousClock.Instant {
  let end = ContinuousClock.now.advanced(by: .seconds(1))
  repeat {
    let state = await client.receiveAssemblyStateForValidation()
    if state.receivedBytes == receivedBytes, let deadline = state.deadline { return deadline }
    try await Task.sleep(for: .milliseconds(5))
  } while ContinuousClock.now < end
  throw RfbPeerError.timeout
}

private func sharedAssemblyPeerEvent(_ fd: Int32) throws {
  var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
  guard Darwin.poll(&item, 1, 5_000) > 0 else { throw RfbPeerError.timeout }
}

@MainActor private func exerciseQuietSharedViewReplacement(_ transition: String) async throws {
  _ = NSApplication.shared
  let firstWindow = SharedGeometryWindow(
    contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
    backing: .buffered, defer: true)
  let secondWindow = SharedGeometryWindow(
    contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
    backing: .buffered, defer: true)
  firstWindow.isReleasedWhenClosed = false
  secondWindow.isReleasedWhenClosed = false
  let first = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
  let second = RfbGuestView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
  firstWindow.contentView = first
  secondWindow.contentView = second
  defer {
    first.stopShared()
    second.stopShared()
    firstWindow.contentView = nil
    secondWindow.contentView = nil
  }
  let copied = DispatchSemaphore(value: 0)
  let page = Int(getpagesize())
  let bytes = ((64 * 64 * 4 + page - 1) / page) * page
  let wire = try RfbPeer { fd in
    var pool = MVOFrameFixturePool()
    guard mvo_fixture_pool(&pool, bytes, 1) == 0 else { throw RfbPeerError.posix(errno) }
    defer { mvo_fixture_clear(&pool) }
    let attach = sharedWire(
      2, width: 64, height: 64, stride: 256, bytes: UInt32(bytes), slot: 2, format: 1)
    let frame = sharedWire(
      3, sequence: 1, generation: 1, width: 64, height: 64, stride: 256,
      bytes: UInt32(bytes), format: 1, sent: 123)
    try rfbWrite(fd, sharedWire(1))
    guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
    try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
    guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
    try rfbWrite(fd, frame)
    guard try rfbRead(fd, 80) == sharedKind(frame, 4) else { throw RfbPeerError.wire }
    guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
    copied.signal()
    // No further frame or pixel damage is sent. Only controller replacement or
    // explicit fixture cleanup can wake this quiet stream. No synthetic ACK is valid.
    var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&item, 1, 5_000) > 0 else { throw RfbPeerError.timeout }
    try rfbExpectClosed(fd)
  }
  defer { wire.remove() }
  // This input actor is an immutable connection-epoch witness, not a connected
  // RFB server or a bypass of human-input admission. Only the SHM wire is used.
  let peer = RFBClient(socketURL: wire.socketURL, expectedIdentity: try sharedIdentity(wire))
  let stream = SharedFrameClient(
    socketURL: wire.socketURL, expectedIdentity: try sharedIdentity(wire),
    connectionEpoch: peer.connectionEpoch)
  let session = RfbLabSession()
  var work: Task<Void, Never>?
  do {
    work = try session.startSharedReplacementForValidation(
      peer: peer, stream: stream,
      raster: RFBFrame(
        connectionEpoch: peer.connectionEpoch, sequence: 1,
        size: PixelSize(width: 64, height: 64), rgbaData: Data(repeating: 0, count: 64 * 64 * 4)),
      target: first)
    let acknowledged = await Task.detached {
      sharedWaitForCopiedFrame(copied)
    }.value
    guard acknowledged else { throw RfbPeerError.timeout }
    let active = session.sharedReplacementStateForValidation()
    #expect(active.sharedSequence == 1 && active.sharedActive && !active.finished)
    if transition == "same-view" {
      session.attach(first)
      await Task.yield()
      let unchanged = session.sharedReplacementStateForValidation()
      #expect(unchanged.sharedActive && !unchanged.replacementPending && !unchanged.finished)
    } else {
      if transition == "detached" { session.detach(first) }
      session.attach(second)
      if transition == "round-trip" { session.attach(first) }
      if transition == "disconnect" {
        await session.disconnectDisplay()
      } else {
        let deadline = ContinuousClock.now + .milliseconds(1_500)
        while !session.sharedReplacementStateForValidation().finished,
          ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(1))
        }
        guard session.sharedReplacementStateForValidation().finished else {
          throw RfbPeerError.timeout
        }
        let recovered = session.sharedReplacementStateForValidation()
        #expect(!recovered.fallbackScheduled && !recovered.sharedActive)
        #expect(!recovered.replacementPending && recovered.sharedSequence == nil)
        #expect(recovered.clientEpoch == peer.connectionEpoch)
        #expect(recovered.frameEpoch == peer.connectionEpoch && recovered.frameSequence == 1)
        // The older raster remains older. Recovery schedules a full refresh;
        // it never relabels that raster or copied SHM bytes as a new receipt.
        let request = session.sharedReplacementRequestForValidation()
        #expect(!request.incremental && request.retryDeadline != nil)
        let ordinary = session.sharedReplacementRequestForValidation()
        #expect(ordinary.incremental && ordinary.retryDeadline == nil)
      }
    }
    await session.disconnectDisplay()
    await work?.value
    await stream.close()
    await peer.close()
    try await wire.wait()
    if transition == "disconnect" {
      await Task.yield()
      let closed = session.sharedReplacementStateForValidation()
      #expect(closed.finished && closed.clientEpoch == nil && closed.frameEpoch == nil)
      #expect(!closed.sharedActive && !closed.replacementPending && !closed.fallbackScheduled)
      let request = session.sharedReplacementRequestForValidation()
      #expect(request.incremental && request.retryDeadline == nil)
    }
  } catch {
    await session.disconnectDisplay()
    await work?.value
    await stream.close()
    await peer.close()
    await wire.stop()
    throw error
  }
}

@Suite(.serialized) struct SharedFrameClientTests {
  @MainActor @Test(arguments: ["direct", "detached", "round-trip"])
  func quietSharedReceiverRecoversOnActualViewReplacementWithoutAnotherFrame(transition: String)
    async throws
  {
    try await exerciseQuietSharedViewReplacement(transition)
  }

  @MainActor @Test func reattachingTheSameViewKeepsItsQuietSharedReceiver() async throws {
    try await exerciseQuietSharedViewReplacement("same-view")
  }

  @MainActor @Test func disconnectWinsOverPendingSharedViewReplacementRecovery() async throws {
    try await exerciseQuietSharedViewReplacement("disconnect")
  }

  @Test(arguments: [1, 79]) func partialFrameStillHasABoundedAssemblyDeadline(
    _ byteCount: Int
  ) async throws {
    let observed = DispatchSemaphore(value: 0)
    let page = Int(getpagesize())
    let bytes = (64 * 64 * 4 + page - 1) / page * page
    try await withSharedPeer(
      { fd in
        var pool = MVOFrameFixturePool()
        guard mvo_fixture_pool(&pool, bytes, 1) == 0 else {
          throw RfbPeerError.posix(errno)
        }
        defer { mvo_fixture_clear(&pool) }
        let attach = sharedWire(
          2, width: 64, height: 64, stride: 256,
          bytes: UInt32(bytes), slot: 2, format: 1)
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
        guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
        let frame = sharedWire(
          3, sequence: 1, generation: 1, width: 64, height: 64, stride: 256,
          bytes: UInt32(bytes), format: 1, sent: 123)
        try rfbWrite(fd, Array(frame.prefix(byteCount)))
        guard observed.wait(timeout: .now() + 5) == .success else {
          throw RfbPeerError.timeout
        }
        try sharedAssemblyPeerEvent(fd)
        // Timeout closes the peer without acknowledging an incomplete frame.
        try rfbExpectClosed(fd)
      },
      body: { client in
        try await client.connect()
        let pending = Task { try await client.nextFrame() }
        do {
          _ = try await sharedAwaitPartialAssembly(client, receivedBytes: byteCount)
        } catch {
          observed.signal()
          await client.close()
          _ = try? await pending.value
          throw error
        }
        observed.signal()
        await #expect(throws: RFBClientError.deadlineExceeded) { _ = try await pending.value }
        let cleared = await client.receiveAssemblyStateForValidation()
        #expect(cleared.receivedBytes == 0 && cleared.deadline == nil)
      })
  }

  @Test func additionalFragmentDoesNotRenewTheAbsoluteAssemblyDeadline() async throws {
    let firstObserved = DispatchSemaphore(value: 0)
    let secondObserved = DispatchSemaphore(value: 0)
    let page = Int(getpagesize())
    let bytes = (64 * 64 * 4 + page - 1) / page * page
    try await withSharedPeer(
      { fd in
        var pool = MVOFrameFixturePool()
        guard mvo_fixture_pool(&pool, bytes, 1) == 0 else {
          throw RfbPeerError.posix(errno)
        }
        defer { mvo_fixture_clear(&pool) }
        let attach = sharedWire(
          2, width: 64, height: 64, stride: 256,
          bytes: UInt32(bytes), slot: 2, format: 1)
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
        guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
        let frame = sharedWire(
          3, sequence: 1, generation: 1, width: 64, height: 64, stride: 256,
          bytes: UInt32(bytes), format: 1, sent: 123)
        try rfbWrite(fd, Array(frame.prefix(1)))
        guard firstObserved.wait(timeout: .now() + 5) == .success else {
          throw RfbPeerError.timeout
        }
        try rfbWrite(fd, [frame[1]])
        guard secondObserved.wait(timeout: .now() + 5) == .success else {
          throw RfbPeerError.timeout
        }
        try sharedAssemblyPeerEvent(fd)
        try rfbExpectClosed(fd)
      },
      body: { client in
        try await client.connect()
        let pending = Task { try await client.nextFrame() }
        do {
          let first = try await sharedAwaitPartialAssembly(client, receivedBytes: 1)
          firstObserved.signal()
          let second = try await sharedAwaitPartialAssembly(client, receivedBytes: 2)
          #expect(second == first)
          secondObserved.signal()
        } catch {
          firstObserved.signal()
          secondObserved.signal()
          await client.close()
          _ = try? await pending.value
          throw error
        }
        await #expect(throws: RFBClientError.deadlineExceeded) { _ = try await pending.value }
      })
  }

  @Test func completedFragmentedFrameRetiresTheAssemblyTimerButKeepsExplicitAck()
    async throws
  {
    let observed = DispatchSemaphore(value: 0)
    let page = Int(getpagesize())
    let bytes = (64 * 64 * 4 + page - 1) / page * page
    try await withSharedPeer(
      { fd in
        var pool = MVOFrameFixturePool()
        guard mvo_fixture_pool(&pool, bytes, 1) == 0 else {
          throw RfbPeerError.posix(errno)
        }
        defer { mvo_fixture_clear(&pool) }
        let attach = sharedWire(
          2, width: 64, height: 64, stride: 256,
          bytes: UInt32(bytes), slot: 2, format: 1)
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
        guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
        let frame = sharedWire(
          3, sequence: 1, generation: 1, width: 64, height: 64, stride: 256,
          bytes: UInt32(bytes), format: 1, sent: 123)
        try rfbWrite(fd, Array(frame.prefix(1)))
        guard observed.wait(timeout: .now() + 5) == .success else {
          throw RfbPeerError.timeout
        }
        try rfbWrite(fd, Array(frame.dropFirst()))
        try sharedAssemblyPeerEvent(fd)
        guard try rfbRead(fd, 80) == sharedKind(frame, 4) else { throw RfbPeerError.wire }
      },
      body: { client in
        try await client.connect()
        let pending = Task { try await client.nextFrame() }
        let oldDeadline: ContinuousClock.Instant
        do {
          oldDeadline = try await sharedAwaitPartialAssembly(client, receivedBytes: 1)
        } catch {
          observed.signal()
          await client.close()
          _ = try? await pending.value
          throw error
        }
        observed.signal()
        let frame = try await pending.value
        #expect(frame.sequence == 1 && frame.size == PixelSize(width: 64, height: 64))
        let completed = await client.receiveAssemblyStateForValidation()
        #expect(completed.receivedBytes == 0 && completed.deadline == nil)
        frame.mapping.withUnsafeBytes { raw in
          #expect(raw.count == bytes)
          #expect(
            raw.indices.allSatisfy { index in
              raw[index] == UInt8(truncatingIfNeeded: index * 13 + (index / 1024) * 7)
            })
        }
        await #expect(throws: RFBClientError.busy) { _ = try await client.nextFrame() }
        // A completed packet no longer owns an assembly deadline. Keeping its
        // mapping beyond the old deadline still requires the caller's ACK.
        let proof = oldDeadline.advanced(by: .milliseconds(100))
        let remaining = ContinuousClock.now.duration(to: proof)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        try await client.acknowledge(frame)
      })
  }

  @Test func receivingFramesReconcilesVisibilityWithoutAnOcclusionNotification() async throws {
    try await withSharedPeer(
      { fd in
        var pool = MVOFrameFixturePool()
        guard mvo_fixture_pool(&pool, Int(getpagesize()), 1) == 0 else {
          throw RfbPeerError.posix(errno)
        }
        defer { mvo_fixture_clear(&pool) }
        let attach = sharedWire(
          2, width: 64, height: 64, stride: 256,
          bytes: UInt32(getpagesize()), slot: 2, format: 1)
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
        guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
        let frame = sharedWire(
          3, sequence: 1, generation: 1, width: 64, height: 64, stride: 256,
          bytes: UInt32(getpagesize()), format: 1, sent: 123)
        try rfbWrite(fd, frame)
        guard try rfbRead(fd, 80) == sharedKind(frame, 4) else { throw RfbPeerError.wire }
      },
      body: { client in
        try await client.connect()
        let frame = try await client.nextFrame()
        try await exerciseVisibilityReconciliation(frame)
        try await client.acknowledge(frame)
      })
  }

  @Test func sharedLayerGeometryReconcilesBoundsBackingAndReattachment() async throws {
    let finished = DispatchSemaphore(value: 0)
    try await withSharedPeer(
      { fd in
        var pool = MVOFrameFixturePool()
        guard mvo_fixture_pool(&pool, Int(getpagesize()), 1) == 0 else {
          throw RfbPeerError.posix(errno)
        }
        defer { mvo_fixture_clear(&pool) }
        let attach = sharedWire(
          2, width: 64, height: 64, stride: 256,
          bytes: UInt32(getpagesize()), slot: 2, format: 1)
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
        guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
        let frame = sharedWire(
          3, sequence: 1, generation: 1, width: 64, height: 64, stride: 256,
          bytes: UInt32(getpagesize()), format: 1, sent: 123)
        try rfbWrite(fd, frame)
        // Geometry/GPU lifecycle checks finish before the explicit consumer ACK.
        guard finished.wait(timeout: .now() + 5) == .success else { throw RfbPeerError.timeout }
        guard try rfbRead(fd, 80) == sharedKind(frame, 4) else { throw RfbPeerError.wire }
      },
      body: { client in
        defer { finished.signal() }
        try await client.connect()
        let frame = try await client.nextFrame()
        try await exerciseSharedLayerGeometry(frame)
        await #expect(throws: RFBClientError.busy) { _ = try await client.nextFrame() }
        try await client.acknowledge(frame)
      })
  }

  @Test func nativeAnd4KReadOnlyPoolsRemainValidAfterProducerExit() async throws {
    for size in [PixelSize(width: 3456, height: 2168), PixelSize(width: 3840, height: 2160)] {
      let stride = (size.width * 4 + 255) & ~255
      let bytes =
        (stride * size.height + Int(getpagesize()) - 1) / Int(getpagesize()) * Int(getpagesize())
      var retained: SharedFrame?
      try await withSharedPeer(
        { fd in
          var pool = MVOFrameFixturePool()
          guard mvo_fixture_pool(&pool, bytes, 1) == 0 else { throw RfbPeerError.posix(errno) }
          defer { mvo_fixture_clear(&pool) }
          let attach = sharedWire(
            2, width: UInt32(size.width), height: UInt32(size.height),
            stride: UInt32(stride), bytes: UInt32(bytes), slot: 2, format: 1)
          try rfbWrite(fd, sharedWire(1), fragmented: true)
          guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
          try sharedSend(
            fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1], fragment: true)
          guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
          for sequence in UInt64(1)...2 {
            let frame = sharedWire(
              3, sequence: sequence, generation: sequence + 4,
              width: UInt32(size.width), height: UInt32(size.height), stride: UInt32(stride),
              bytes: UInt32(bytes), slot: UInt32(sequence - 1), format: 1, sent: 123)
            try rfbWrite(fd, frame, fragmented: true)
            // Neither receipt nor a caller trying nextFrame permits early reuse.
            try rfbExpectQuiet(fd, milliseconds: 30)
            guard try rfbRead(fd, 80) == sharedKind(frame, 4) else { throw RfbPeerError.wire }
            if sequence == 1 {
              guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
            }
          }
        },
        body: { client in
          try await client.connect()
          for sequence in UInt64(1)...2 {
            let frame = try await client.nextFrame()
            #expect(frame.size == size)
            #expect(frame.sequence == sequence)
            #expect(frame.mapping.byteCount == bytes)
            frame.mapping.withUnsafeBytes { raw in
              #expect(
                mvo_fixture_check(
                  raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                  UInt32(sequence - 1), 0, 0, 0) == 1)
            }
            let renderer = try await SharedFrameMetalRenderer()
            // A hidden native layer must still finish the actual GPU copy so
            // the producer can reuse its slot, without acquiring a drawable.
            _ = try await renderer.present(
              frame, drawableSize: CGSize(width: size.width, height: size.height),
              viewport: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            #expect(await renderer.drawableRequestsForValidation() == 0)
            let rendered = try await renderer.renderGeneratedValidation(frame, updateCache: false)
            renderer.close()
            rendered.withUnsafeBytes { raw in
              #expect(
                mvo_fixture_check(
                  raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                  UInt32(sequence - 1), size.width, size.height, stride) == 1)
            }
            await #expect(throws: (any Error).self) { _ = try await client.nextFrame() }
            try await Task.sleep(for: .milliseconds(60))
            try await client.acknowledge(frame)
            await #expect(throws: (any Error).self) { try await client.acknowledge(frame) }
            retained = frame
          }
        })
      // Mapping ownership survives producer unmap/close, consumer close, and ACK.
      retained?.mapping.withUnsafeBytes { raw in
        #expect(raw[0] == 31)
        #expect(
          raw[bytes - 1]
            == UInt8(truncatingIfNeeded: (bytes - 1) * 13 + ((bytes - 1) / 1024) * 7 + 31))
      }
      retained = nil
    }
  }

  @Test(arguments: [0, 1, 2, 3, 4, 5, 6]) func malformedAndUnsafeAttachIsRejected(_ fault: Int)
    async throws
  {
    try await withSharedPeer(
      { fd in
        var pool = MVOFrameFixturePool()
        guard mvo_fixture_pool(&pool, Int(getpagesize()), fault == 0 ? 0 : 1) == 0 else {
          throw RfbPeerError.posix(errno)
        }
        defer { mvo_fixture_clear(&pool) }
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        var attach = sharedWire(
          2, width: 64, height: 64, stride: 256,
          bytes: UInt32(getpagesize()), slot: 2, format: 1)
        var descriptors = [pool.descriptors.0, pool.descriptors.1]
        if fault == 1 { attach[40] = 0 }  // zero width
        if fault == 2 { attach[72] = 1 }  // reserved byte
        if fault == 3 { attach[8] = 99 }  // first attach must match READY epoch
        if fault == 4 { descriptors.append(pool.descriptors.0) }
        // Ancillary truncation.
        if fault == 5 { descriptors = Array(repeating: pool.descriptors.0, count: 32) }
        if fault == 6 {
          // SCM_RIGHTS delivered after metadata has started is inadmissible.
          try rfbWrite(fd, [attach[0]])
          try rfbExpectQuiet(fd, milliseconds: 10)
          attach.removeFirst()
        }
        try sharedSend(fd, attach, descriptors: descriptors)
        try rfbExpectClosed(fd)
      },
      body: { client in
        try await client.connect()
        await #expect(throws: (any Error).self) { _ = try await client.nextFrame() }
      })
  }

  @Test func cancelQuietFrameReadClosesWithoutAcknowledging() async throws {
    let gate = DispatchSemaphore(value: 0)
    try await withSharedPeer(
      { fd in
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        gate.signal()
        try rfbExpectClosed(fd)
      },
      body: { client in
        try await client.connect()
        let pending = Task { try await client.nextFrame() }
        let gotRequest = await Task.detached { sharedWait(gate) }.value
        #expect(gotRequest)
        pending.cancel()
        await #expect(throws: (any Error).self) { _ = try await pending.value }
      })
  }

  @Test(arguments: [false, true]) func disconnectDuringConsumerCopyPreservesFailure(
    malformed: Bool
  ) async throws {
    let retire = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    try await withSharedPeer(
      { fd in
        var pool = MVOFrameFixturePool()
        guard mvo_fixture_pool(&pool, Int(getpagesize()), 1) == 0 else {
          throw RfbPeerError.posix(errno)
        }
        defer { mvo_fixture_clear(&pool) }
        let attach = sharedWire(
          2, width: 64, height: 64, stride: 256,
          bytes: UInt32(getpagesize()), slot: 2, format: 1)
        try rfbWrite(fd, sharedWire(1))
        guard try rfbRead(fd, 80) == sharedWire(5) else { throw RfbPeerError.wire }
        try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
        guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
        let frame = sharedWire(
          3, sequence: 1, generation: 1, width: 64, height: 64, stride: 256,
          bytes: UInt32(getpagesize()), format: 1, sent: 123)
        try rfbWrite(fd, frame)
        guard sharedWait(retire) else { throw RfbPeerError.timeout }
        if malformed {
          // An unsolicited second frame must remain fatal, never a retryable reset.
          try rfbWrite(fd, frame)
        } else {
          // A producer surface retirement can close while the consumer GPU owns a slot.
          guard Darwin.shutdown(fd, SHUT_WR) == 0 else { throw RfbPeerError.posix(errno) }
        }
        try rfbExpectClosed(fd)
        drained.signal()
      },
      body: { client in
        try await client.connect()
        let frame = try await client.nextFrame()
        retire.signal()
        #expect(await Task.detached { sharedWait(drained) }.value)
        let expected: RFBClientError = malformed ? .unexpectedMessage : .posix(ECONNRESET)
        await #expect(throws: expected) { try await client.acknowledge(frame) }
        // Cleanup must not overwrite the original failure with generic cancellation.
        await client.close()
        await #expect(throws: expected) { _ = try await client.nextFrame() }
        frame.mapping.withUnsafeBytes { #expect($0[0] == 0) }
      })
  }

  @Test func ackReconstructionPreservesEveryWireFieldAcrossSlotsAndReattach()
    async throws
  {
    let epochs = [sharedEpoch, (0..<16).map { UInt8(truncatingIfNeeded: $0 * 17 + 9) }]
    let shapes = [(width: 257, height: 3, stride: 1280), (width: 513, height: 5, stride: 2304)]
    let counts = [258, 2]
    let generations: [UInt64] = [0xfedc_ba98_7654_0000, 0x0123_4567_89ab_cd00]
    let timestamps: [UInt64] = [0x8123_4567_89ab_0000, 0xfedc_ba98_7654_0000]
    let page = Int(getpagesize())
    let poolSizes = shapes.map { ($0.stride * $0.height + page - 1) / page * page }
    let finished = DispatchSemaphore(value: 0)
    try await withSharedPeer(
      { fd in
        try rfbWrite(fd, sharedWire(1, epoch: epochs[0]))
        for stream in 0..<2 {
          let shape = shapes[stream]
          var pool = MVOFrameFixturePool()
          guard mvo_fixture_pool(&pool, poolSizes[stream], 1) == 0 else {
            throw RfbPeerError.posix(errno)
          }
          defer { mvo_fixture_clear(&pool) }
          let requestEpoch = stream == 0 ? epochs[0] : epochs[stream - 1]
          guard try rfbRead(fd, 80) == sharedWire(5, epoch: requestEpoch) else {
            throw RfbPeerError.wire
          }
          let attach = sharedWire(
            2, width: UInt32(shape.width), height: UInt32(shape.height),
            stride: UInt32(shape.stride), bytes: UInt32(poolSizes[stream]), slot: 2, format: 1,
            epoch: epochs[stream])
          try sharedSend(fd, attach, descriptors: [pool.descriptors.0, pool.descriptors.1])
          guard try rfbRead(fd, 80) == sharedKind(attach, 4) else { throw RfbPeerError.wire }
          for value in 1...counts[stream] {
            let sequence = UInt64(value)
            if value > 1 {
              guard try rfbRead(fd, 80) == sharedWire(5, epoch: epochs[stream]) else {
                throw RfbPeerError.wire
              }
            }
            // This scalar wire builder is independent of production encode/ACK.
            let frame = sharedWire(
              3, sequence: sequence, generation: generations[stream] + sequence,
              width: UInt32(shape.width), height: UInt32(shape.height),
              stride: UInt32(shape.stride), bytes: UInt32(poolSizes[stream]),
              slot: UInt32((sequence - 1) % 2), format: 1,
              sent: timestamps[stream] + sequence, epoch: epochs[stream])
            try rfbWrite(fd, frame)
            guard try rfbRead(fd, 80) == sharedKind(frame, 4) else { throw RfbPeerError.wire }
          }
        }
        // Keep the endpoint live for deterministic duplicate-ACK rejection.
        guard finished.wait(timeout: .now() + 5) == .success else { throw RfbPeerError.timeout }
      },
      body: { client in
        defer { finished.signal() }
        try await client.connect()
        var retained: SharedFrame?
        for stream in 0..<2 {
          let shape = shapes[stream]
          for value in 1...counts[stream] {
            let sequence = UInt64(value)
            let frame = try await client.nextFrame()
            #expect(frame.sequence == sequence)
            #expect(frame.generation == generations[stream] + sequence)
            #expect(frame.sentNanoseconds == timestamps[stream] + sequence)
            #expect(frame.size == PixelSize(width: shape.width, height: shape.height))
            #expect(frame.rowBytes == shape.stride && frame.mapping.byteCount == poolSizes[stream])
            if value == 1 || value == counts[stream] {
              let slot = Int((sequence - 1) % 2)
              frame.mapping.withUnsafeBytes { raw in
                #expect(
                  raw.indices.allSatisfy { index in
                    raw[index]
                      == UInt8(truncatingIfNeeded: index * 13 + (index / 1024) * 7 + slot * 31)
                  })
              }
            }
            if stream == 0 && value == 1 { retained = frame }
            if stream == 1 && value == 1 {
              let old = try #require(retained)
              #expect(old.sequence == frame.sequence && old.streamEpoch != frame.streamEpoch)
              await #expect(throws: RFBClientError.unexpectedMessage) {
                try await client.acknowledge(old)
              }
              // The producer has retired this original pool. Its fixed fixture
              // bytes remain readable through the independently retained mapping.
              old.mapping.withUnsafeBytes { raw in
                #expect(
                  raw.indices.allSatisfy { index in
                    raw[index] == UInt8(truncatingIfNeeded: index * 13 + (index / 1024) * 7)
                  })
              }
            }
            await #expect(throws: RFBClientError.busy) { _ = try await client.nextFrame() }
            try await client.acknowledge(frame)
            if value == 1 || value == counts[stream] {
              await #expect(throws: RFBClientError.unexpectedMessage) {
                try await client.acknowledge(frame)
              }
            }
          }
        }
      })
  }

  @Test func malformedReadyAndUnexpectedDescriptorsAreRejected() async throws {
    for fault in 0..<3 {
      try await withSharedPeer(
        { fd in
          var ready = sharedWire(1)
          if fault == 0 { ready[0] = 0 }
          if fault == 1 { ready[24] = 1 }
          if fault == 2 {
            let own = open("/dev/null", O_RDONLY)
            guard own >= 0 else { throw RfbPeerError.posix(errno) }
            defer { Darwin.close(own) }
            try sharedSend(fd, ready, descriptors: [own])
          } else {
            try rfbWrite(fd, ready)
          }
          try rfbExpectClosed(fd)
        },
        body: { client in
          await #expect(throws: (any Error).self) { try await client.connect() }
        })
    }
  }
}
