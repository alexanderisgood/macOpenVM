// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Darwin
import Foundation
import Qemu
import QuartzCore
import RuntimeIPC
import SwiftUI
import VMCore
import VMStorage

struct RfbQualificationPresentation: Sendable {
  let epoch: UUID?
  let sequence: UInt64
  let width: Int?
  let height: Int?
  let attached: Bool
  let visible: Bool
  let drawn: Bool
}

/// One original RFB renderer, using explicit lab admission or injected registered context.
/// It never constructs a backend, acquires a writer or replaces a missing worker.
@MainActor final class RfbLabSession: ObservableObject {
  let selected: Bool
  // Steady pixels go directly to the native surface. Publishing every frame
  // rebuilds the SwiftUI scene and its menus at the transport's frame rate.
  // Availability, size and epoch changes still invalidate declarative controls.
  private(set) var frame: RFBFrame? {
    willSet {
      if frame?.size != newValue?.size || frame?.connectionEpoch != newValue?.connectionEpoch {
        clearDisplayMeasurementReport()
        objectWillChange.send()
      }
    }
    didSet {
      view?.update(frame: frame)
      if frame?.size != oldValue?.size || frame?.connectionEpoch != oldValue?.connectionEpoch {
        refreshFullscreenPresentation()
      }
      resumeInputIfFocused()
    }
  }
  @Published private(set) var message = "Connecting to the original display fixture…"
  @Published private(set) var captured = false
  @Published private(set) var inputBacklogError: String?
  @Published private(set) var displayConnected = false
  @Published private(set) var state: UInt8 = 0
  @Published private(set) var fullscreen = false
  @Published private(set) var fullscreenMenuBarVisible: Bool?
  @Published private(set) var fullscreenPresentationFlags: String?
  @Published private(set) var desiredNativePixels: PixelSize?
  @Published private(set) var consoleSwitchPending = false
  @Published private(set) var consoleError: String?
  @Published private(set) var resizePending = false
  @Published private(set) var displayTimingRunning = false
  @Published private(set) var displayTimingResult: GuestFrameTiming.Result?
  @Published private(set) var displayTimingError: String?
  @Published private(set) var displayMeasurementReport: GuestDisplayMeasurementReport?
  @Published var presentationSettings = GuestPresentationSettings() {
    didSet {
      guard presentationSettings != oldValue else { return }
      invalidateDisplayTiming()
      suspendInput()
      view?.setPresentationSettings(presentationSettings)
    }
  }
  var canSharpenPresentation: Bool { frame != nil && sharedClient != nil && !sharedDisabled }
  private var displayMeasurementContext: (connection: UUID, frameEpoch: UUID, timingEpoch: UUID)?
  private var displayTiming: GuestFrameTimingMeasurement?
  @Published private(set) var displayTimingFeedbackDiagnostics: GuestFrameTimingCapture.Diagnostics?
  private var displayTimingBegan = ContinuousClock.now
  private var displayTimingAttempt: UUID?
  private var displayTimingTask: Task<Void, Never>?
  private var resizeAttempt: UUID?
  let canSelectDisplayConsole: Bool
  let canMatchMacResolution: Bool
  @Published var useGuestCursor = false {
    didSet { view?.useGuestCursor = windowsInstaller && useGuestCursor }
  }
  var canChooseGuestCursor: Bool { windowsInstaller && frame != nil }
  private var route: DisplayWorkerRoute?
  private var client: RFBClient?
  private var receiver: Task<Void, Never>?
  private var sharedClient: SharedFrameClient?
  private weak var sharedTarget: RfbGuestView?
  private var sharedReplacementStream: SharedFrameClient?
  private var sharedCleanup: Task<Void, Never>?
  private var sharedDisabled = false
  private var sharedRecovery = SharedDisplayRecovery()
  private var consoleSelection = GuestDisplayConsoleSelection()
  private var sharedFrameInfo: (epoch: UUID, sequence: UInt64, size: PixelSize)?
  @Published private(set) var displayTimingMethod = "AppKit draw callbacks"
  private var connectAttempt = UUID()
  private var captureAttempt: UUID?
  private var inputActivation: GuestInputActivationAttempt?
  private var inputSpaceRequest: GuestInputActiveSpaceRequest?
  private var automaticCaptureBlocked = false
  private var lifecycleInputSuspended = false
  private var capturePolicy = GuestInputCapturePolicy()
  private var pendingKeyboardCapture = GuestPendingKeyboardCapture()
  private var inputTail: Task<Void, Never>?
  private var pendingInput = 0
  private let pointerCoalescer = GuestPointerCoalescer()
  private let relativeCoalescer = GuestRelativePointerCoalescer()
  @Published private(set) var relativeMouse = false
  @Published private(set) var mouseModePending = false
  @Published private(set) var mouseModeError: String?
  var canChangeMouseMode: Bool {
    registeredContext != nil && displayConnected && !mouseModePending && !resizePending
      && !consoleSwitchPending
  }
  private var releasePending = false
  private var displayCleanup: Task<Void, Never>?
  private var cleanupEpoch = UUID()
  private var reconnectWhenAttached = false
  private weak var view: RfbGuestView?
  var qualificationPresentation: (@MainActor (RfbQualificationPresentation) -> Void)? {
    didSet { installQualificationPresentation() }
  }
  private weak var observedWindow: NSWindow?
  private let directoryPath: String?
  private var presentation = GuestFullscreenPresentation()
  private var menuBarVisibility = GuestMenuBarVisibility()
  private let inputPolicy: RfbLabInputPolicy
  private let externalInputPolicy: ExternalWindowsHumanInputPolicy
  private let registeredContext: RegisteredRfbDisplayContext?
  private let currentRegisteredLaunchGeneration: (@MainActor @Sendable () -> UUID?)?
  fileprivate let hostPointerCapture: GuestHostPointerCapture
  private let windowsInstaller: Bool
  let observationOnly: Bool
  private let networkContinuation: Bool
  let humanInput: Bool
  var canCaptureInput: Bool {
    if let context = registeredContext {
      return !lifecycleInputSuspended && !mouseModePending
        && currentRegisteredLaunchGeneration?() == context.launchGeneration
    }
    return externalInputPolicy.selected
      ? externalInputPolicy.canCaptureInput : inputPolicy.canCaptureInput
  }
  var canControlRuntime: Bool {
    if registeredContext != nil { return false }
    return externalInputPolicy.selected ? false : inputPolicy.canControlRuntime
  }

  init(hostPointerCapture: GuestHostPointerCapture = .shared) {
    self.hostPointerCapture = hostPointerCapture
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let policy = RfbLabInputPolicy(arguments: CommandLine.arguments, projectRoot: project)
    let external = ExternalWindowsHumanInputPolicy(arguments: CommandLine.arguments)
    inputPolicy = policy
    externalInputPolicy = external
    registeredContext = nil
    canSelectDisplayConsole = false
    canMatchMacResolution = false
    currentRegisteredLaunchGeneration = nil
    humanInput = external.selected ? external.canCaptureInput : policy.humanInput
    observationOnly = !external.selected && policy.observationOnly
    networkContinuation = !external.selected && policy.networkContinuation
    windowsInstaller = external.selected ? external.canCaptureInput : policy.windowsInstaller
    selected = external.selected || policy.selected
    directoryPath = external.selected ? external.directoryPath : policy.directoryPath
    useGuestCursor = windowsInstaller && humanInput
    if windowsInstaller { message = "Connecting to the Windows display…" }
  }

  init(
    registeredContext: RegisteredRfbDisplayContext,
    currentLaunchGeneration: @escaping @MainActor @Sendable () -> UUID?,
    displayConsoleSelection: Bool = false,
    nativeResolutionEvaluation: Bool = false,
    arguments: [String] = CommandLine.arguments,
    hostPointerCapture: GuestHostPointerCapture = .shared
  ) throws {
    self.hostPointerCapture = hostPointerCapture
    let flags = [
      "--rfb-display-lab", "--windows-installer-display-lab",
      "--windows-network-continuation-display-lab", RfbLabInputPolicy.humanFlag,
      ExternalWindowsHumanInputPolicy.flag,
    ]
    guard !arguments.contains(where: { flags.contains($0) }) else {
      throw RegisteredRfbDisplayContext.failure()
    }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    inputPolicy = RfbLabInputPolicy(arguments: [], projectRoot: project)
    externalInputPolicy = ExternalWindowsHumanInputPolicy(arguments: [])
    capturePolicy = GuestInputCapturePolicy(automatic: true)
    self.registeredContext = registeredContext
    canSelectDisplayConsole = displayConsoleSelection
    canMatchMacResolution = nativeResolutionEvaluation
    currentRegisteredLaunchGeneration = currentLaunchGeneration
    selected = false
    directoryPath = nil
    observationOnly = false
    networkContinuation = false
    windowsInstaller = true
    humanInput = true
    useGuestCursor = true
    message = "Connecting to \(registeredContext.configuration.name)…"
  }

  func connectDisplay(retryShared: Bool = true) async {
    if retryShared {
      sharedDisabled = false
      sharedRecovery = SharedDisplayRecovery()
      consoleError = nil
    }
    automaticCaptureBlocked = false
    inputBacklogError = nil
    let attempt = UUID()
    connectAttempt = attempt
    await closeCurrentDisplay()
    guard connectAttempt == attempt else { return }
    do {
      let admission = try await readRoute()
      let admitted = admission.route
      let status = try await inspectControl(admitted)
      guard connectAttempt == attempt, registeredLaunchIsCurrent else { return }
      guard status.backendActive else { throw Self.failure("The fixture worker is inactive.") }
      if networkContinuation || externalInputPolicy.selected || registeredContext != nil {
        guard status.ownership == 0, status.error == .none, !status.operationPending else {
          throw Self.failure("The continuation worker needs ownership review.")
        }
      }
      route = admitted
      state = status.state
      let peer = RFBClient(
        socketURL: URL(fileURLWithPath: admitted.displaySocket),
        expectedIdentity: RFBEndpointIdentity(
          parentDevice: admitted.parentDevice, parentInode: admitted.parentInode,
          socketDevice: admitted.socketDevice, socketInode: admitted.socketInode),
        prefetchFrames: canSelectDisplayConsole && registeredContext?.sharedRoute == nil,
        prefetchAfterHeader: canSelectDisplayConsole && registeredContext?.sharedRoute == nil)
      client = peer
      let epoch = peer.connectionEpoch
      try await peer.connect()
      guard connectAttempt == attempt, client === peer, registeredLaunchIsCurrent else {
        await peer.close()
        return
      }
      displayConnected = true
      if canMatchMacResolution && canSelectDisplayConsole {
        for symbol in WindowsDisplayConsole.gpu.chord {
          try await peer.sendKey(keySym: symbol, down: true)
        }
        for symbol in WindowsDisplayConsole.gpu.chord.reversed() {
          try await peer.sendKey(keySym: symbol, down: false)
        }
      }
      message = displayLabel
      receiver = Task { @MainActor [weak self, peer] in
        do {
          while !Task.isCancelled {
            let request = self?.sharedRecovery.nextFrameRequest()
            if let deadline = request?.retryDeadline {
              try await Task.sleep(until: deadline, clock: .continuous)
              guard let self, self.client === peer else { return }
              guard self.registeredLaunchIsCurrent else {
                self.beginClosingDisplay(
                  peer, message: "The selected VM changed. Reconnect its display.")
                return
              }
            }
            let next = try await peer.nextFrame(incremental: request?.incremental ?? true)
            guard let self, self.client === peer, next.connectionEpoch == epoch else { return }
            guard self.registeredLaunchIsCurrent else {
              self.beginClosingDisplay(
                peer, message: "The selected VM changed. Reconnect its display.")
              return
            }
            self.receiveDisplayTiming(next)
            self.frame = next
            // The same receiver pauses pixel requests while shared frames are
            // active. RFB input remains independent and uses its existing epoch.
            if await self.receiveSharedFrames(peer: peer) { return }
          }
        } catch {
          guard let self, self.client === peer else { return }
          self.beginClosingDisplay(
            peer, message: RfbDisplayFailureCategory(error: error).displayMessage)
        }
      }
    } catch {
      guard connectAttempt == attempt else { return }
      message = (error as? VMError)?.errorDescription ?? "The private display could not connect."
    }
  }

  /// Returns true when a failed shared stream scheduled a fresh RFB fallback.
  private func receiveSharedFrames(peer: RFBClient) async -> Bool {
    guard !sharedDisabled, sharedRecovery.canAttempt(at: .now),
      canSelectDisplayConsole, let context = registeredContext,
      context.sharedRoute != nil, let current = frame, let target = view,
      current.connectionEpoch == peer.connectionEpoch
    else { return false }
    do {
      guard
        let route = try context.readSharedAdmission(
          currentLaunchGeneration: currentRegisteredLaunchGeneration?())
      else { return false }
      let stream = SharedFrameClient(
        socketURL: URL(fileURLWithPath: route.displaySocket),
        expectedIdentity: RFBEndpointIdentity(
          parentDevice: route.parentDevice, parentInode: route.parentInode,
          socketDevice: route.socketDevice, socketInode: route.socketInode),
        connectionEpoch: peer.connectionEpoch)
      return try await consumeSharedFrames(stream, peer: peer, target: target)
    } catch {
      return await recoverSharedFrames(error, peer: peer)
    }
  }

  private func consumeSharedFrames(
    _ stream: SharedFrameClient, peer: RFBClient, target: RfbGuestView
  ) async throws -> Bool {
    sharedClient = stream
    sharedTarget = target
    sharedReplacementStream = nil
    do {
      try await stream.connect()
      while !Task.isCancelled {
        let next = try await stream.nextFrame()
        guard sharedClient === stream, client === peer, view === target,
          registeredLaunchIsCurrent, frame?.connectionEpoch == next.connectionEpoch,
          frame?.size == next.size
        else { throw SharedFrameMetalRenderer.Failure.geometry }
        if sharedFrameInfo?.epoch != next.streamEpoch || sharedFrameInfo?.size != next.size {
          invalidateDisplayTiming()
        }
        sharedFrameInfo = (next.streamEpoch, next.sequence, next.size)
        receiveSharedTiming(next)
        _ = try await target.presentShared(next)
        guard sharedClient === stream, client === peer, registeredLaunchIsCurrent else {
          await stream.close()
          return false
        }
        // The renderer copied this slot into its private GPU cache and the
        // actual command has completed. Only now may the producer reuse it.
        try await stream.acknowledge(next)
        sharedRecovery.completedFrame()
      }
    } catch {
      guard sharedClient === stream else {
        await stream.close()
        return false
      }
      throw error
    }
    return false
  }

  private func recoverSharedFrames(_ error: Error, peer: RFBClient) async -> Bool {
    guard client === peer, registeredLaunchIsCurrent else { return false }
    let replacementClosed =
      (error as? RFBClientError) == .closed && sharedReplacementStream != nil
      && sharedReplacementStream === sharedClient
    let transient =
      replacementClosed || (error as? RFBClientError) == .posix(ECONNRESET)
      || (error as? SharedFrameMetalRenderer.Failure) == .geometry
    let recover = transient && sharedRecovery.transientFailure(at: .now)
    await stopSharedFrames()?.value
    if recover {
      // Keep the admitted RFB input epoch through boot, unlock and game
      // surface changes. The receiver waits for this bounded retry deadline
      // and requests one full frame, so quiet Windows pixels cannot stall it.
      // Replenish the three-attempt budget only after120 completed copies.
      sharedDisabled = false
      return false
    }
    sharedDisabled = true
    let category =
      (error as? RFBClientError).map { String(describing: $0) }
      ?? (error as? SharedFrameMetalRenderer.Failure).map { String(describing: $0) }
      ?? "admission"
    consoleError = "Metal display unavailable (\(category)). Reconnecting the standard display."
    // Return before teardown joins this receiver; never await our own task.
    Task { @MainActor [weak self] in await self?.connectDisplay(retryShared: false) }
    return true
  }

  /// A replacement cannot display the old view's private cache. Wake its quiet
  /// shared receiver now; the normal guarded path owns backoff and full refresh.
  private func interruptSharedFramesForReplacement(_ candidate: RfbGuestView) {
    guard let stream = sharedClient, let target = sharedTarget, target !== candidate,
      sharedReplacementStream !== stream
    else { return }
    sharedReplacementStream = stream
    target.stopShared()
    let previous = sharedCleanup
    sharedCleanup = Task {
      await previous?.value
      await stream.close()
    }
  }

  @discardableResult private func stopSharedFrames() -> Task<Void, Never>? {
    invalidateDisplayTiming()
    let old = sharedClient
    let target = sharedTarget
    sharedClient = nil
    sharedTarget = nil
    sharedReplacementStream = nil
    sharedFrameInfo = nil
    target?.stopShared()
    if view !== target { view?.stopShared() }
    let previous = sharedCleanup
    let cleanup = Task {
      await previous?.value
      await old?.close()
    }
    sharedCleanup = cleanup
    return cleanup
  }

  #if DEBUG
    /// Disconnected native fixtures can exercise focus notifications without
    /// authorizing input, opening a display connection or activating the app.
    func beginInputActivationForValidation(
      _ candidate: RfbGuestView, moveToActiveSpace: Bool = false
    ) -> UUID? {
      guard registeredContext == nil, !selected, client == nil, frame == nil,
        !captured, pendingInput == 0, !releasePending, displayCleanup == nil,
        let window = candidate.window, window.attachedSheet == nil
      else { return nil }
      cancelPendingKeyboardCapture()
      attach(candidate)
      let attempt = UUID()
      captureAttempt = attempt
      inputActivation = GuestInputActivationAttempt(
        capture: attempt, window: window, applicationActive: NSApp?.isActive ?? false)
      if moveToActiveSpace {
        let request = GuestInputActiveSpaceRequest(window: window)
        inputSpaceRequest = request
        request.begin()
      }
      return attempt
    }

    func hasInputActivationForValidation(_ attempt: UUID) -> Bool {
      captureAttempt == attempt
        && inputActivation?.matches(capture: attempt, window: view?.window) == true
    }

    func refreshInputActivationForValidation(at now: ContinuousClock.Instant) {
      guard registeredContext == nil, !selected, client == nil, frame == nil else { return }
      if !preservePendingInputActivation(now: now) { suspendInput() }
    }

    private var sharedReplacementValidationFinished = false
    private var sharedReplacementValidationFallback = false

    struct SharedReplacementValidationState {
      let finished: Bool
      let fallbackScheduled: Bool
      let sharedActive: Bool
      let replacementPending: Bool
      let clientEpoch: UUID?
      let frameEpoch: UUID?
      let frameSequence: UInt64?
      let sharedSequence: UInt64?
    }

    func sharedReplacementStateForValidation() -> SharedReplacementValidationState {
      SharedReplacementValidationState(
        finished: sharedReplacementValidationFinished,
        fallbackScheduled: sharedReplacementValidationFallback,
        sharedActive: sharedClient != nil, replacementPending: sharedReplacementStream != nil,
        clientEpoch: client?.connectionEpoch, frameEpoch: frame?.connectionEpoch,
        frameSequence: frame?.sequence, sharedSequence: sharedFrameInfo?.sequence)
    }

    func sharedReplacementRequestForValidation() -> SharedDisplayRecovery.FrameRequest {
      sharedRecovery.nextFrameRequest()
    }

    /// Setup only: production admission is unchanged. The real controller
    /// receiver, attach/detach and recovery execute against a generated peer.
    func startSharedReplacementForValidation(
      peer: RFBClient, stream: SharedFrameClient, raster: RFBFrame, target: RfbGuestView
    ) throws -> Task<Void, Never> {
      guard registeredContext == nil, !selected, client == nil, sharedClient == nil,
        displayCleanup == nil, target.window != nil,
        raster.size == PixelSize(width: 64, height: 64), raster.rgbaData.count == 64 * 64 * 4,
        raster.rgbaData.allSatisfy({ $0 == 0 }),
        raster.connectionEpoch == peer.connectionEpoch,
        raster.connectionEpoch == stream.connectionEpoch
      else { throw Self.failure("The generated shared replacement fixture is invalid.") }
      sharedReplacementValidationFinished = false
      sharedReplacementValidationFallback = false
      client = peer
      frame = raster
      attach(target)
      target.update(frame: raster)
      let work = Task<Void, Never> { @MainActor [weak self, weak target] in
        guard let self, let target else { return }
        do {
          self.sharedReplacementValidationFallback = try await self.consumeSharedFrames(
            stream, peer: peer, target: target)
        } catch {
          self.sharedReplacementValidationFallback = await self.recoverSharedFrames(
            error, peer: peer)
        }
        self.sharedReplacementValidationFinished = true
      }
      receiver = work
      return work
    }
  #endif

  private func receiveSharedTiming(_ frame: SharedFrame) {
    guard displayTiming != nil else { return }
    do {
      guard NSApp.isActive, view?.window?.isKeyWindow == true,
        view?.window?.isOnActiveSpace == true, registeredLaunchIsCurrent
      else { throw GuestFrameTiming.Invalid.changed }
      try displayTiming?.capture.receive(
        epoch: frame.streamEpoch, size: frame.size, sequence: frame.sequence)
    } catch { invalidateDisplayTiming() }
  }

  func disconnectDisplay() async {
    let attempt = UUID()
    connectAttempt = attempt
    await closeCurrentDisplay()
    guard connectAttempt == attempt else { return }
    fullscreenChanged(false)
    observedWindow = nil
  }

  private func closeCurrentDisplay() async {
    invalidateDisplayTiming()
    displayConnected = false
    resizeAttempt = nil
    resizePending = false
    capturePolicy.suspend()
    cancelPendingKeyboardCapture()
    captureAttempt = nil
    mouseModePending = false
    pointerCoalescer.reset()
    relativeCoalescer.reset()
    captured = false
    view?.captured = false
    frame = nil
    if let old = client { beginClosingDisplay(old) } else { stopSharedFrames() }
    await sharedCleanup?.value
    // Concurrent reconnects join the same teardown before opening another peer.
    await displayCleanup?.value
  }

  private func beginClosingDisplay(_ peer: RFBClient, message: String? = nil) {
    guard client === peer else { return }
    consoleSelection.cancel()
    consoleSwitchPending = false
    invalidateDisplayTiming()
    displayConnected = false
    resizeAttempt = nil
    resizePending = false
    pointerCoalescer.reset()
    relativeCoalescer.reset()
    let oldReceiver = receiver
    let oldShared = stopSharedFrames()
    let oldInput = inputTail
    let token = UUID()
    cleanupEpoch = token
    capturePolicy.suspend()
    cancelPendingKeyboardCapture()
    captureAttempt = nil
    mouseModePending = false
    captured = false
    view?.captured = false
    frame = nil
    client = nil
    receiver = nil
    if let message { self.message = message }
    // A key failure may run inside oldInput. Its caller returns before this
    // separate task joins that tail; it never waits for itself or stops the worker.
    let cleanup = Task { @MainActor [weak self, peer] in
      await oldShared?.value
      await oldInput?.value
      await peer.releaseInput()
      await peer.close()
      oldReceiver?.cancel()
      if self?.cleanupEpoch == token { self?.displayCleanup = nil }
    }
    displayCleanup = cleanup
    inputTail = cleanup
  }

  func displayMeasurementInvalidated(_ candidate: RfbGuestView) {
    guard view === candidate else { return }
    invalidateDisplayTiming()
  }

  func nativeGeometryChanged(_ candidate: RfbGuestView, pixels: PixelSize?) {
    guard view === candidate, desiredNativePixels != pixels else { return }
    desiredNativePixels = pixels
  }

  func attach(_ candidate: RfbGuestView) {
    guard let window = candidate.window else {
      if view === candidate { detach(candidate) }
      return
    }
    if view !== candidate || observedWindow !== window {
      finishInputSpaceRequest()
      invalidateDisplayTiming()
    }
    view = candidate
    interruptSharedFramesForReplacement(candidate)
    resumeInputIfFocused()
    installQualificationPresentation()
    if observedWindow !== window {
      fullscreenChanged(false)
      observedWindow = window
      fullscreenChanged(window.styleMask.contains(.fullScreen))
    } else if window.styleMask.contains(.fullScreen), !fullscreen {
      fullscreenChanged(true)
    } else {
      // The same window may replace its representable before AppKit finishes
      // setting its native fullscreen style. Keep the prepared baseline then.
      refreshFullscreenPresentation()
    }
    if reconnectWhenAttached {
      reconnectWhenAttached = false
      Task { @MainActor [weak self, weak candidate] in
        await Task.yield()
        guard let self, let candidate, self.view === candidate, self.client == nil else { return }
        await self.connectDisplay()
      }
    }
  }

  private func installQualificationPresentation() {
    guard let view else { return }
    guard qualificationPresentation != nil else {
      view.onQualificationPresentation = nil
      return
    }
    view.onQualificationPresentation = { [weak self] value in
      self?.qualificationPresentation?(value)
    }
    view.reportQualificationPresentation(drawn: false)
    view.needsDisplay = true
  }

  /// Opt-in private graphics evaluation: no extra display connection, requests,
  /// hashes or pixels are retained. Count ordinary receive and draw events.
  func measureDisplayDelivery() {
    clearDisplayMeasurementReport()
    guard view?.window?.isOnActiveSpace == true else {
      displayTimingResult = nil
      displayTimingError = "Bring the Windows window to the current desktop before measuring."
      return
    }
    guard canSelectDisplayConsole, registeredLaunchIsCurrent, !displayTimingRunning,
      let frame, let view, view.window === observedWindow,
      observedWindow?.isKeyWindow == true, NSApp.isActive,
      !resizePending, !consoleSwitchPending, !lifecycleInputSuspended
    else { return }
    let frameEpoch = frame.connectionEpoch
    displayTimingBegan = .now
    displayTimingMethod =
      sharedFrameInfo == nil ? "AppKit draw callbacks" : "Metal completion callback entry"
    let capture = GuestFrameTimingCapture(
      epoch: sharedFrameInfo?.epoch ?? frame.connectionEpoch,
      size: sharedFrameInfo?.size ?? frame.size,
      initialSequence: sharedFrameInfo?.sequence ?? frame.sequence,
      presentationFeedback: sharedFrameInfo != nil, origin: CACurrentMediaTime())
    let measurement = GuestFrameTimingMeasurement(capture: capture, source: view)
    displayTiming = measurement
    displayTimingFeedbackDiagnostics = nil
    displayTimingResult = nil
    displayTimingError = nil
    displayTimingRunning = true
    let attempt = UUID()
    displayTimingAttempt = attempt
    view.reportSharedMeasurementState(ending: false)
    displayTimingTask = Task { @MainActor [weak self, frameEpoch] in
      try? await Task.sleep(for: .seconds(20))
      guard let self, self.displayTimingAttempt == attempt else { return }
      do {
        guard self.displayTiming === measurement, self.registeredLaunchIsCurrent,
          NSApp.isActive, self.view?.window === self.observedWindow,
          self.observedWindow?.isKeyWindow == true,
          self.observedWindow?.isOnActiveSpace == true
        else { throw GuestFrameTiming.Invalid.changed }
        let outcome = await measurement.finish()
        guard self.displayTimingAttempt == attempt, self.displayTiming === measurement else {
          return
        }
        guard self.registeredLaunchIsCurrent, NSApp.isActive,
          self.view?.window === self.observedWindow,
          self.observedWindow?.isKeyWindow == true,
          self.observedWindow?.isOnActiveSpace == true
        else { throw GuestFrameTiming.Invalid.changed }
        self.displayTimingFeedbackDiagnostics = outcome.diagnostics
        if outcome.diagnostics.status == .complete, let result = outcome.result {
          self.displayTimingResult = result
          self.displayMeasurementReport = GuestDisplayMeasurementReport(
            result: result, diagnostics: outcome.diagnostics,
            method: self.displayTimingMethod, origin: measurement.capture.origin)
          self.displayMeasurementContext = (
            self.connectAttempt, frameEpoch, measurement.capture.epoch
          )
        } else if outcome.diagnostics.status == .incompleteFeedback {
          self.displayTimingResult = nil
          self.displayTimingError =
            outcome.diagnostics.sourceStopped
            ? "Display measurement incomplete: \(outcome.diagnostics.unresolvedTickets) feedback tickets unresolved. Repeat the sample."
            : "Display measurement incomplete: feedback cutoff was not confirmed. Repeat the sample."
        } else {
          throw GuestFrameTiming.Invalid.changed
        }
        self.view?.reportSharedMeasurementState(ending: true)
        self.endDisplayTiming()
      } catch { self.invalidateDisplayTiming() }
    }
  }

  /// Menu availability is read-only and never initializes NSApplication or a pasteboard.
  var canCopyDisplayMeasurement: Bool {
    guard !displayTimingRunning, displayTimingError == nil,
      registeredLaunchIsCurrent, displayConnected,
      !resizePending, !consoleSwitchPending, !lifecycleInputSuspended,
      let report = displayMeasurementReport, let context = displayMeasurementContext,
      let frame, context.connection == connectAttempt,
      context.frameEpoch == frame.connectionEpoch,
      context.timingEpoch == (sharedFrameInfo?.epoch ?? frame.connectionEpoch),
      report.width == (sharedFrameInfo?.size ?? frame.size).width,
      report.height == (sharedFrameInfo?.size ?? frame.size).height
    else { return false }
    return true
  }

  /// The user explicitly requests one numeric clipboard write. No display or VM operation.
  func copyDisplayMeasurement() {
    guard canCopyDisplayMeasurement, let report = displayMeasurementReport,
      let application = NSApp, application.isActive,
      let window = view?.window, window === observedWindow,
      window.isKeyWindow, window.isOnActiveSpace,
      let text = try? report.jsonString()
    else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    _ = pasteboard.setString(text, forType: .string)
  }

  private func clearDisplayMeasurementReport() {
    displayMeasurementReport = nil
    displayMeasurementContext = nil
  }

  private var displayTimingMS: Double {
    let elapsed = displayTimingBegan.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }

  private func receiveDisplayTiming(_ frame: RFBFrame) {
    guard displayTiming != nil else { return }
    do {
      guard NSApp.isActive, view?.window?.isKeyWindow == true,
        view?.window?.isOnActiveSpace == true, registeredLaunchIsCurrent
      else { throw GuestFrameTiming.Invalid.changed }
      try displayTiming?.capture.receive(
        epoch: frame.connectionEpoch, size: frame.size, sequence: frame.sequence)
    } catch { invalidateDisplayTiming() }
  }

  private func endDisplayTiming() {
    displayTimingAttempt = nil
    displayTimingTask?.cancel()
    displayTimingTask = nil
    displayTiming?.cancel()
    displayTiming = nil
    displayTimingRunning = false
  }

  private func invalidateDisplayTiming() {
    clearDisplayMeasurementReport()
    guard displayTimingRunning else { return }
    NSLog("macOpenVM Metal sample cancelled: elapsed_ms=%.3f", displayTimingMS)
    view?.reportSharedMeasurementState(ending: true)
    displayTimingError = "Display measurement cancelled: the window, display or VM state changed."
    endDisplayTiming()
  }

  func detach(_ candidate: RfbGuestView) {
    guard view === candidate else { return }
    invalidateDisplayTiming()
    reconnectWhenAttached = client != nil || receiver != nil
    suspendInput()
    candidate.captured = false
    candidate.capturePending = false
    candidate.setRelativeMouseCapture(false, retryPending: false)
    view = nil
    // SwiftUI may replace its representable during a native window transition.
    // A replacement attachment in this actor turn keeps the display connection;
    // a genuinely dismantled observer closes it without touching the worker.
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, self.view == nil else { return }
      await self.disconnectDisplay()
    }
  }

  func fullscreenChanged(_ active: Bool) {
    if active { finishInputSpaceRequest() }
    fullscreen = active
    view?.refreshSharedPresentationVisibility()
    fullscreenMenuBarVisible = nil
    fullscreenPresentationFlags = nil
    guard let application = NSApp else {
      fullscreen = false
      return
    }
    if active {
      presentation.prepare(application.presentationOptions)
      menuBarVisibility.prepare()
      refreshFullscreenPresentation()
      // Observe our own completed native transition, rather than assuming an
      // accessible menu or accepted presentation assignment is visibly shown.
      if canSelectDisplayConsole {
        let owner = observedWindow
        Task { @MainActor [weak self, weak owner] in
          try? await Task.sleep(for: .seconds(1))
          guard let self, let owner, self.observedWindow === owner,
            self.fullscreen, owner.styleMask.contains(.fullScreen),
            owner.isKeyWindow, application.isActive
          else { return }
          self.refreshFullscreenPresentation()
          try? await Task.sleep(for: .milliseconds(100))
          guard self.observedWindow === owner, self.fullscreen,
            owner.isKeyWindow, application.isActive
          else { return }
          self.fullscreenMenuBarVisible = NSMenu.menuBarVisible()
          self.fullscreenPresentationFlags = String(
            format: "Native fullscreen · Requested 0x%lx · Effective 0x%lx",
            application.presentationOptions.rawValue,
            application.currentSystemPresentationOptions.rawValue)
        }
      }
    } else {
      let current = application.presentationOptions
      let desired = presentation.finish(current)
      if desired != current { application.presentationOptions = desired }
      menuBarVisibility.finish(canChangeVisibility: application.isActive)
    }
  }

  func prepareFullscreen() {
    finishInputSpaceRequest()
    guard let application = NSApp else { return }
    presentation.beginTransition(application.presentationOptions)
    menuBarVisibility.prepare()
  }

  func refreshFullscreenPresentation() {
    guard let application = NSApp else { return }
    let current = application.presentationOptions
    let effective = application.currentSystemPresentationOptions
    let active =
      fullscreen && frame != nil && application.isActive && view?.window?.isKeyWindow == true
      && view?.window?.isOnActiveSpace == true
    let desired =
      active ? presentation.applying(to: effective) : presentation.suspending(current)
    // AppKit can change the effective system mode without changing the app's
    // requested property during a native Space transition. Compare both.
    if desired != current || (active && desired != effective) {
      application.presentationOptions = desired
    }
    if active {
      menuBarVisibility.show(activeOwner: true)
    } else {
      menuBarVisibility.suspend(canChangeVisibility: application.isActive)
    }
  }

  func focusChanged() {
    view?.refreshSharedPresentationVisibility()
    refreshFullscreenPresentation()
    if inputForeground {
      if var activation = inputActivation {
        _ = activation.observe(applicationActive: true)
        inputActivation = activation
      }
      automaticCaptureBlocked = false
      resumeInputIfFocused()
    } else {
      invalidateDisplayTiming()
      // A cooperative handoff can report active/key/Space changes separately.
      // Preserve only the explicit, still-empty request; no guest event is
      // eligible until all ordinary foreground checks succeed below.
      if preservePendingInputActivation() { return }
      suspendInput()
    }
  }

  private func preservePendingInputActivation(now: ContinuousClock.Instant = .now) -> Bool {
    guard !captured, view?.captured != true, view?.capturePending != true,
      !releasePending, pendingInput == 0, displayCleanup == nil,
      !resizePending, !consoleSwitchPending,
      let window = view?.window, observedWindow === window, window.attachedSheet == nil,
      var activation = inputActivation,
      activation.matches(capture: captureAttempt, window: window)
    else { return false }
    let pending = activation.observe(applicationActive: NSApp?.isActive ?? false, now: now)
    inputActivation = pending ? activation : nil
    return pending
  }

  var inputForeground: Bool {
    GuestInputCapturePolicy.isForeground(
      applicationActive: NSApp?.isActive ?? false, keyWindow: view?.window?.isKeyWindow == true,
      onActiveSpace: view?.window?.isOnActiveSpace == true)
  }

  private func resumeInputIfFocused() {
    guard !automaticCaptureBlocked, !consoleSwitchPending, !resizePending,
      capturePolicy.wanted, !captured,
      captureAttempt == nil,
      !releasePending, pendingInput == 0, displayCleanup == nil,
      frame != nil, inputForeground, let view, let window = view.window,
      window.isKeyWindow, window.attachedSheet == nil,
      Self.canRestoreGuestResponder(view, in: window)
    else { return }
    captureInput(activate: false)
  }

  /// AppKit can restore the owning window during startup or native transitions.
  /// An editor or other control remains the host keyboard target.
  static func canRestoreGuestResponder(_ view: RfbGuestView, in window: NSWindow) -> Bool {
    guard view.window === window, window.attachedSheet == nil else { return false }
    guard let responder = window.firstResponder else { return true }
    if responder === window || responder === view { return true }
    // AppKit may restore the representable's non-editing container after a
    // fullscreen/focus transition. Restore its guest child, while sibling host
    // controls, editors and sheets keep their own keyboard focus.
    guard let container = responder as? NSView,
      !(container is NSControl), !(container is NSTextView)
    else { return false }
    return view.isDescendant(of: container)
  }

  func captureInput() {
    automaticCaptureBlocked = false
    inputBacklogError = nil
    captureInput(activate: true)
  }

  private func captureInput(activate: Bool) {
    guard canCaptureInput, !resizePending, !consoleSwitchPending else { return }
    capturePolicy.request()
    // Publish this request before restoring an older native placement lease.
    // A synchronous callback can cancel it or install a newer capture attempt.
    let attempt = UUID()
    captureAttempt = attempt
    cancelPendingKeyboardCapture()
    guard captureAttempt == attempt else { return }
    guard displayCleanup == nil, !releasePending, pendingInput == 0 else {
      captureAttempt = nil
      message = "The test keyboard is still settling. Capture it after release finishes."
      return
    }
    guard let frame, let client, frame.connectionEpoch == client.connectionEpoch,
      let view, let window = view.window, observedWindow === window, window.attachedSheet == nil
    else {
      captureAttempt = nil
      message = "Connect the display window, then capture its test input."
      return
    }
    let connection = connectAttempt
    let epoch = frame.connectionEpoch
    let keyboardIdentity = GuestPendingKeyboardCapture.Identity(
      connection: connection, frameEpoch: epoch, attempt: attempt,
      policyGeneration: capturePolicy.generation)
    if !activate, inputForeground, window.isKeyWindow,
      Self.canRestoreGuestResponder(view, in: window), window.makeFirstResponder(view),
      captureAttempt == attempt, self.view === view, view.window === window,
      window.firstResponder === view
    {
      pendingKeyboardCapture.begin(keyboardIdentity)
      view.capturePending = true
    }
    // Only this explicit action requests activation. AppKit may complete the
    // cooperative request later or refuse it; input still needs verified focus.
    message =
      humanInput
      ? "Checking this Windows session before capturing input…"
      : "Bringing the display window forward to capture its test input…"
    Task { @MainActor [weak self, weak view, weak window] in
      var spaceRequest: GuestInputActiveSpaceRequest?
      defer {
        spaceRequest?.finish()
        if self?.captureAttempt == attempt {
          self?.cancelPendingKeyboardCapture()
          self?.captureAttempt = nil
        }
      }
      await Task.yield()
      guard let self, let view, let window else { return }
      if self.humanInput {
        do { try await self.verifyHumanCapture() } catch {
          guard self.captureAttempt == attempt, self.connectAttempt == connection else { return }
          self.automaticCaptureBlocked = true
          self.suspendInput()
          self.message = "This Windows session could not be confirmed. Reconnect its display."
          return
        }
      }
      guard
        self.captureEpochStillCurrent(connection: connection, epoch: epoch, capture: attempt),
        self.client === client,
        self.view === view, view.window === window, self.observedWindow === window,
        self.displayCleanup == nil, !self.releasePending, self.pendingInput == 0,
        window.attachedSheet == nil
      else { return }
      if activate {
        self.inputActivation = GuestInputActivationAttempt(
          capture: attempt, window: window, applicationActive: NSApp?.isActive ?? false)
        let request = GuestInputActiveSpaceRequest(window: window)
        spaceRequest = request
        self.inputSpaceRequest = request
        request.begin(allowMove: !self.fullscreen)
        // Collection-behavior callbacks may cancel or replace this request.
        guard
          self.captureEpochStillCurrent(connection: connection, epoch: epoch, capture: attempt),
          self.inputSpaceRequest === request,
          self.inputActivation?.matches(capture: attempt, window: window) == true,
          self.client === client, self.view === view, view.window === window,
          self.observedWindow === window,
          self.displayCleanup == nil, !self.releasePending, self.pendingInput == 0,
          window.attachedSheet == nil
        else { return }
        if NSApp?.isActive == false { NSApp?.activate() }
      } else if !self.inputForeground {
        return
      }
      let deadline = ContinuousClock.now + .seconds(1)
      while true {
        guard
          self.captureEpochStillCurrent(connection: connection, epoch: epoch, capture: attempt),
          self.client === client,
          self.view === view, view.window === window, self.observedWindow === window,
          self.displayCleanup == nil, !self.releasePending, self.pendingInput == 0,
          window.attachedSheet == nil
        else { return }
        if activate {
          guard var activation = self.inputActivation,
            activation.matches(capture: attempt, window: window)
          else { return }
          let action = activation.next(
            applicationActive: NSApp?.isActive ?? false,
            keyWindow: window.isKeyWindow, onActiveSpace: window.isOnActiveSpace)
          // Store before native calls: their synchronous callbacks can revoke it.
          self.inputActivation = activation
          switch action {
          case .cancel:
            self.message = "The display could not take focus. Select its window and capture again."
            return
          case .orderOwnedWindow:
            if window.isMiniaturized { window.deminiaturize(nil) }
            guard
              self.captureEpochStillCurrent(connection: connection, epoch: epoch, capture: attempt),
              self.inputActivation?.matches(capture: attempt, window: window) == true,
              self.client === client, self.view === view, view.window === window,
              self.observedWindow === window, NSApp?.isActive == true,
              self.displayCleanup == nil, !self.releasePending, self.pendingInput == 0,
              window.attachedSheet == nil
            else { return }
            window.makeKeyAndOrderFront(nil)
            // Revalidate ownership and foreground state after native callbacks.
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            continue
          case .wait: break
          case .ready: break
          }
        }
        if self.inputForeground {
          guard window.makeFirstResponder(view), window.firstResponder === view else {
            self.message = "The display could not receive keyboard focus. Capture its input again."
            return
          }
          // Making a responder can synchronously invoke release/detach callbacks.
          guard
            self.captureEpochStillCurrent(connection: connection, epoch: epoch, capture: attempt),
            self.client === client,
            self.view === view, view.window === window, self.inputForeground,
            self.displayCleanup == nil, !self.releasePending, self.pendingInput == 0,
            window.attachedSheet == nil
          else { return }
          self.captured = true
          view.captured = true
          // Pointer custody can synchronously reject this view and release
          // input from the setter. Do not drain queued keys or overwrite that
          // release with a successful capture message.
          guard self.captured, view.captured,
            self.captureEpochStillCurrent(connection: connection, epoch: epoch, capture: attempt),
            self.client === client, self.view === view, view.window === window,
            self.inputForeground, window.firstResponder === view,
            self.displayCleanup == nil, !self.releasePending, self.pendingInput == 0,
            window.attachedSheet == nil
          else { return }
          let firstStrokes = self.pendingKeyboardCapture.finish(
            keyboardIdentity, verified: true,
            foreground: self.inputForeground && window.firstResponder === view)
          view.capturePending = false
          for stroke in firstStrokes { self.key(stroke.symbol, down: stroke.down) }
          guard self.captured, view.captured,
            self.captureEpochStillCurrent(connection: connection, epoch: epoch, capture: attempt)
          else { return }
          self.message = "Input captured • Control–Option–Escape releases input"
          return
        }
        guard activate || ContinuousClock.now < deadline else {
          self.message = "The display could not take focus. Select its window and capture again."
          return
        }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
      }
    }
  }

  private func captureEpochStillCurrent(connection: UUID, epoch: UUID, capture: UUID) -> Bool {
    if let context = registeredContext {
      return context.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connectAttempt, requestedEpoch: epoch,
        clientEpoch: client?.connectionEpoch, frameEpoch: frame?.connectionEpoch,
        requestedCapture: capture, currentCapture: captureAttempt,
        currentLaunchGeneration: currentRegisteredLaunchGeneration?())
    }
    if externalInputPolicy.selected {
      return externalInputPolicy.permitsCaptureEpoch(
        requestedConnection: connection, currentConnection: connectAttempt,
        requestedEpoch: epoch, clientEpoch: client?.connectionEpoch,
        frameEpoch: frame?.connectionEpoch, requestedCapture: capture,
        currentCapture: captureAttempt)
    }
    return inputPolicy.permitsCaptureEpoch(
      requestedConnection: connection, currentConnection: connectAttempt,
      requestedEpoch: epoch, clientEpoch: client?.connectionEpoch,
      frameEpoch: frame?.connectionEpoch, requestedCapture: capture, currentCapture: captureAttempt)
  }

  func releaseInput() {
    rejectCaptureInput()
    hostPointerCapture.retryPendingRestoration()
  }

  func rejectCaptureInput() {
    capturePolicy.release()
    suspendInput()
  }

  /// Keep the existing passive refusal and its pointer custody intact, while
  /// explaining the recovery action in the Input menu.
  func rejectUnavailableHostPointerCapture() {
    rejectCaptureInput()
    message =
      hostPointerCapture.restorationPending
      ? "Mouse restoration blocked input capture. Choose Release Input, then capture again."
      : "Another VM window blocked mouse capture. Release its input, then capture this window."
  }

  /// Lifecycle controls release held input without changing the user's capture
  /// preference. Paused guests remain gated; running/recovery states still need
  /// the usual fresh ownership and foreground verification before recapture.
  func suspendForLifecycleTransition() {
    invalidateDisplayTiming()
    lifecycleInputSuspended = true
    suspendInput()
  }

  func runtimeStateChanged(_ state: VMState) {
    let wasSuspended = lifecycleInputSuspended
    lifecycleInputSuspended = state != .running && state != .starting && state != .stopping
    if lifecycleInputSuspended {
      invalidateDisplayTiming()
      suspendInput()
    } else if wasSuspended {
      automaticCaptureBlocked = false
      resumeInputIfFocused()
    }
  }

  /// The available backing-pixel viewport is measured by the attached native
  /// view. A completed RFB write is insufficient: require a newer matching
  /// framebuffer on the same connection, with a bounded wait and no retry loop.
  func matchMacResolution() {
    guard canMatchMacResolution, registeredContext != nil, registeredLaunchIsCurrent,
      !consoleSwitchPending, !resizePending, displayCleanup == nil,
      let client, let frame, frame.connectionEpoch == client.connectionEpoch,
      let requested = desiredNativePixels,
      (64...8192).contains(requested.width), (64...8192).contains(requested.height),
      requested.width * requested.height <= 16_777_216
    else { return }
    invalidateDisplayTiming()
    if frame.size == requested {
      consoleError = nil
      return
    }
    let attempt = UUID()
    let connection = connectAttempt
    resizeAttempt = attempt
    resizePending = true
    consoleError = nil
    suspendInput()
    let previous = inputTail
    inputTail = Task { @MainActor [weak self, client] in
      await previous?.value
      guard let self else { return }
      defer {
        if self.resizeAttempt == attempt {
          self.resizeAttempt = nil
          self.resizePending = false
          self.resumeInputIfFocused()
        }
      }
      do {
        try await self.verifyHumanCapture()
        guard self.resizeAttempt == attempt, self.connectAttempt == connection,
          self.client === client, self.registeredLaunchIsCurrent
        else { return }
        if self.canSelectDisplayConsole {
          for symbol in WindowsDisplayConsole.gpu.chord {
            try await client.sendKey(keySym: symbol, down: true)
          }
          for symbol in WindowsDisplayConsole.gpu.chord.reversed() {
            try await client.sendKey(keySym: symbol, down: false)
          }
        }
        try await client.requestDesktopSize(requested)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
          guard self.resizeAttempt == attempt, self.connectAttempt == connection,
            self.client === client, self.registeredLaunchIsCurrent
          else { return }
          if let applied = self.frame, applied.connectionEpoch == frame.connectionEpoch,
            applied.sequence > frame.sequence, applied.size == requested
          {
            try await self.verifyHumanCapture()
            return
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard self.resizeAttempt == attempt, self.client === client else { return }
        self.consoleError =
          "Windows has not applied the Mac viewport of "
          + "\(requested.width) × \(requested.height) pixels."
      } catch {
        guard self.resizeAttempt == attempt, self.client === client else { return }
        self.consoleError = "The resolution request could not be confirmed. Reconnect the display."
      }
    }
  }

  func selectDisplayConsole(_ console: WindowsDisplayConsole) {
    guard canSelectDisplayConsole, displayConnected, let context = registeredContext,
      registeredLaunchIsCurrent,
      !consoleSwitchPending, !resizePending, displayCleanup == nil, let client,
      frame == nil || frame?.connectionEpoch == client.connectionEpoch,
      let selection = consoleSelection.begin(
        console, sharedRouteAvailable: context.sharedRoute != nil,
        sharedActive: !sharedDisabled && sharedClient != nil && sharedFrameInfo != nil)
    else { return }
    let connection = connectAttempt
    consoleSwitchPending = true
    consoleError = nil
    invalidateDisplayTiming()
    let sharedStop: Task<Void, Never>?
    if selection.sharedAction.stopsShared {
      sharedDisabled = true
      sharedStop = stopSharedFrames()
    } else {
      // A currently admitted GPU stream survives an explicit GPU selection.
      // The input console itself is still selected: no write is treated as ACK.
      sharedStop = nil
    }
    suspendInput()
    let previous = inputTail
    inputTail = Task { @MainActor [weak self, client] in
      await sharedStop?.value
      await previous?.value
      guard let self else { return }
      var didScheduleRetry = false
      defer {
        if self.consoleSelection.finish(selection) {
          self.consoleSwitchPending = false
          if !didScheduleRetry { self.resumeInputIfFocused() }
        }
      }
      do {
        try await self.verifyHumanCapture()
        guard self.consoleSelection.ownsPending(selection), self.connectAttempt == connection,
          self.client === client, self.registeredLaunchIsCurrent
        else { return }
        await client.releaseInput()
        for symbol in console.chord { try await client.sendKey(keySym: symbol, down: true) }
        for symbol in console.chord.reversed() {
          try await client.sendKey(keySym: symbol, down: false)
        }
        if selection.sharedAction == .retryAdmittedRoute {
          // Explicit GPU selection authorizes one ordinary display retry. Closing
          // the old pending incremental read guarantees a fresh first framebuffer
          // even when the selected console is quiet. Do not await our own inputTail.
          Task { @MainActor [weak self, client] in
            await Task.yield()
            guard let self, self.consoleSelection.permitsDeferredReconnect(selection),
              self.connectAttempt == connection, self.client === client,
              self.registeredLaunchIsCurrent, !self.consoleSwitchPending,
              !self.resizePending, self.displayCleanup == nil
            else { return }
            // Existing route/control/session/endpoint checks run again. This has
            // no relationship to the once-only worker producer-capture channel.
            await self.connectDisplay(retryShared: true)
          }
          didScheduleRetry = true
        }
      } catch {
        await client.releaseInput()
        guard self.consoleSelection.ownsPending(selection), self.client === client else { return }
        self.consoleError = "The display selection could not be confirmed. Reconnect the display."
      }
    }
  }

  func suspendInput() {
    capturePolicy.suspend()
    cancelPendingKeyboardCapture()
    let captureRequested = captureAttempt != nil
    captureAttempt = nil
    pointerCoalescer.reset()
    relativeCoalescer.reset()
    if captured || captureRequested {
      message = displayLabel
    }
    captured = false
    view?.captured = false
    guard let client, !releasePending else { return }
    releasePending = true
    let previous = inputTail
    inputTail = Task { @MainActor [weak self, client] in
      await previous?.value
      await client.releaseInput()
      self?.releasePending = false
      self?.resumeInputIfFocused()
    }
  }

  func key(_ symbol: UInt32, down: Bool) {
    guard canCaptureInput else { return }
    guard inputForeground else {
      suspendInput()
      return
    }
    if !captured {
      guard capturePolicy.wanted, let attempt = captureAttempt, !consoleSwitchPending,
        displayCleanup == nil, !releasePending, let client, let frame,
        frame.connectionEpoch == client.connectionEpoch,
        let view, view.capturePending, let window = view.window, observedWindow === window,
        window.attachedSheet == nil, window.firstResponder === view
      else { return }
      guard inputForeground else {
        suspendInput()
        return
      }
      let identity = GuestPendingKeyboardCapture.Identity(
        connection: connectAttempt, frameEpoch: frame.connectionEpoch, attempt: attempt,
        policyGeneration: capturePolicy.generation)
      guard
        pendingKeyboardCapture.append(
          RFBKeyStroke(symbol, down: down), for: identity,
          foreground: true)
      else {
        pauseForInputBacklog()
        return
      }
      return
    }
    guard !consoleSwitchPending, inputForeground, captured, let client,
      view?.window?.isKeyWindow == true
    else { return }
    pointerCoalescer.barrier()
    relativeCoalescer.barrier()
    guard reserveInputSlot() else { return }
    let generation = capturePolicy.generation
    let previous = inputTail
    inputTail = Task { @MainActor [weak self, client] in
      await previous?.value
      guard let self else { return }
      defer {
        self.pendingInput -= 1
        self.resumeInputIfFocused()
      }
      guard self.client === client,
        self.capturePolicy.permitsQueuedInput(
          generation, captured: self.captured,
          foreground: self.inputForeground)
      else { return }
      do { try await client.sendKey(keySym: symbol, down: down) } catch {
        guard self.client === client else { return }
        self.beginClosingDisplay(
          client, message: "Test keyboard input could not be sent. Reconnect its display.")
      }
    }
  }

  private func cancelPendingKeyboardCapture() {
    inputActivation = nil
    pendingKeyboardCapture.cancel()
    view?.capturePending = false
    finishInputSpaceRequest()
  }

  private func finishInputSpaceRequest() {
    let request = inputSpaceRequest
    inputSpaceRequest = nil
    request?.finish()
  }

  private func reserveInputSlot() -> Bool {
    guard pendingInput < GuestInputCapturePolicy.maximumPendingEvents else {
      pauseForInputBacklog()
      return false
    }
    pendingInput += 1
    return true
  }

  private func pauseForInputBacklog() {
    // Never resume into the suffix of an overlong burst and execute a truncated
    // command. Explicit capture starts a fresh transaction after held keys clear.
    releaseInput()
    let error = "Input paused: too many queued events. Choose Capture Input to continue."
    inputBacklogError = error
    message = error
  }

  func scroll(_ point: GuestPixelPoint, _ steps: Int, _ pixels: PixelSize, _ epoch: UUID) {
    guard canCaptureInput else { return }
    guard inputForeground, captured, let client, view?.window?.isKeyWindow == true,
      frame?.connectionEpoch == epoch, frame?.size == pixels, steps != 0
    else { return }
    pointerCoalescer.barrier()
    relativeCoalescer.barrier()
    guard reserveInputSlot() else { return }
    let generation = capturePolicy.generation
    let previous = inputTail
    inputTail = Task { @MainActor [weak self, client] in
      await previous?.value
      guard let self else { return }
      defer {
        self.pendingInput -= 1
        self.resumeInputIfFocused()
      }
      guard self.client === client,
        self.capturePolicy.permitsQueuedInput(
          generation, captured: self.captured,
          foreground: self.inputForeground)
      else { return }
      do {
        try await client.sendScroll(x: point.x, y: point.y, steps: steps, frameSize: pixels)
      } catch {
        guard self.client === client else { return }
        if self.repairMouseMode(error) { return }
        self.beginClosingDisplay(
          client, message: "Test scrolling could not be sent. Reconnect its display.")
      }
    }
  }

  func pointer(_ point: GuestPixelPoint, _ buttons: UInt8, _ pixels: PixelSize, _ epoch: UUID) {
    guard canCaptureInput else { return }
    guard inputForeground, captured, let client, view?.window?.isKeyWindow == true,
      frame?.connectionEpoch == epoch, frame?.size == pixels
    else { return }
    guard
      let batch = pointerCoalescer.enqueue(
        GuestPointerSample(point: point, buttons: buttons, pixels: pixels, epoch: epoch))
    else { return }
    guard reserveInputSlot() else { return }
    let generation = capturePolicy.generation
    let previous = inputTail
    inputTail = Task { @MainActor [weak self, client] in
      await previous?.value
      guard let self else { return }
      defer {
        self.pendingInput -= 1
        self.resumeInputIfFocused()
      }
      guard self.client === client,
        self.capturePolicy.permitsQueuedInput(
          generation, captured: self.captured,
          foreground: self.inputForeground),
        let sample = batch.take()
      else { return }
      do {
        try await client.sendPointer(
          x: sample.point.x, y: sample.point.y, buttons: sample.buttons, frameSize: sample.pixels)
      } catch {
        guard self.client === client else { return }
        if self.repairMouseMode(error) { return }
        self.beginClosingDisplay(
          client, message: "Test pointer input could not be sent. Reconnect its display.")
      }
    }
  }

  private func repairMouseMode(_ error: Error) -> Bool {
    guard error as? RFBClientError == .pointerModeChanged, canChangeMouseMode else { return false }
    // USB enumeration or a guest reset can change the selected device after an
    // earlier confirmation. Keep this display/input epoch, release held input,
    // then ask its original worker to restore and independently confirm the mode.
    suspendInput()
    setRelativeMouse(relativeMouse)
    return true
  }

  func setRelativeMouse(_ relative: Bool) {
    guard canChangeMouseMode, let route, let client else { return }
    mouseModePending = true
    mouseModeError = nil
    let attempt = connectAttempt
    let recapture = capturePolicy.wanted
    releaseInput()
    let previous = inputTail
    Task { @MainActor [weak self, client] in
      await previous?.value
      let peer = WorkerIPCClient(
        socketURL: URL(fileURLWithPath: route.controlSocket),
        vmID: route.vmID, sessionID: route.sessionID, timeout: .seconds(5))
      do {
        try await peer.connect()
        let before = try await peer.request(.status)
        guard before.state == 2, before.error == .none, !before.operationPending else {
          throw RFBClientError.busy
        }
        let after = try await peer.request(
          relative ? .relativeMouse : .absoluteMouse,
          observedRevision: before.revision)
        await peer.close()
        guard after.error == .none else { throw RFBClientError.invalidPointer }
        try await client.waitForPointerMode(relative: relative)
        guard let self, self.client === client, self.connectAttempt == attempt else { return }
        self.relativeMouse = relative
        self.view?.relativeMouse = relative
        self.mouseModePending = false
        if recapture {
          self.capturePolicy.request()
          self.resumeInputIfFocused()
        }
      } catch {
        await peer.close()
        guard let self, self.client === client, self.connectAttempt == attempt else { return }
        self.mouseModePending = false
        self.mouseModeError =
          "Mouse mode could not be confirmed. Select Desktop Mouse or reconnect the display."
      }
    }
  }

  func relativePointer(_ dx: Int, _ dy: Int, _ buttons: UInt8, _ epoch: UUID) {
    guard canCaptureInput, relativeMouse, !mouseModePending, inputForeground, captured,
      let client, view?.window?.isKeyWindow == true, frame?.connectionEpoch == epoch,
      (-32767...32767).contains(dx), (-32767...32767).contains(dy)
    else { return }
    guard let batch = relativeCoalescer.enqueue(dx: dx, dy: dy, buttons: buttons) else { return }
    pointerCoalescer.barrier()
    guard reserveInputSlot() else { return }
    let generation = capturePolicy.generation
    let previous = inputTail
    inputTail = Task { @MainActor [weak self, client] in
      await previous?.value
      guard let self else { return }
      defer {
        self.pendingInput -= 1
        self.resumeInputIfFocused()
      }
      guard self.client === client, self.relativeMouse,
        self.capturePolicy.permitsQueuedInput(
          generation, captured: self.captured,
          foreground: self.inputForeground),
        let motion = batch.take()
      else { return }
      do {
        try await client.sendRelativePointer(dx: motion.dx, dy: motion.dy, buttons: motion.buttons)
      } catch {
        guard self.client === client else { return }
        if self.repairMouseMode(error) { return }
        self.beginClosingDisplay(
          client, message: "Game mouse input disconnected. Reconnect the display.")
      }
    }
  }

  func control(_ command: WorkerCommand) {
    guard canControlRuntime else { return }
    guard let route else { return }
    let attempt = connectAttempt
    releaseInput()
    let releasedInput = inputTail
    Task { @MainActor [weak self] in
      await releasedInput?.value
      let peer = WorkerIPCClient(
        socketURL: URL(fileURLWithPath: route.controlSocket), vmID: route.vmID,
        sessionID: route.sessionID, timeout: .seconds(30))
      do {
        try await peer.connect()
        let before = try await peer.request(.status)
        let after = try await peer.request(command, observedRevision: before.revision)
        await peer.close()
        guard self?.connectAttempt == attempt, self?.route?.sessionID == route.sessionID else {
          return
        }
        self?.state = after.state
        self?.message =
          after.error == .none
          ? (after.backendActive
            ? "Original firmware display • Experimental" : "Fixture runtime stopped.")
          : "The runtime operation needs review; ownership remains with its worker."
      } catch {
        await peer.close()
        guard self?.connectAttempt == attempt, self?.route?.sessionID == route.sessionID else {
          return
        }
        self?.message = "The worker control connection is unavailable. Preserve its session."
      }
    }
  }

  func confirmForceStop() {
    guard canControlRuntime else { return }
    guard let owner = view?.window else { return }
    releaseInput()
    let alert = NSAlert()
    alert.messageText =
      windowsInstaller
      ? "Force stop this Windows installer test?" : "Force stop the original test fixture?"
    alert.informativeText =
      windowsInstaller
      ? "This ends the disposable installer VM. Display disconnect alone keeps it running."
      : "This explicitly ends its diskless runtime. Display disconnect alone keeps it running."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Force Stop")
    alert.beginSheetModal(for: owner) { [weak self] response in
      if response == .alertSecondButtonReturn { self?.control(.forceStop) }
    }
  }

  private func readRoute() async throws -> (route: DisplayWorkerRoute, data: Data) {
    if let context = registeredContext {
      let admission = try context.readAdmission(
        currentLaunchGeneration: currentRegisteredLaunchGeneration?())
      let files = VMFiles()
      guard let intent = try await files.readRuntimeIntent(in: context.directory),
        intent.vmID == context.configuration.id, intent.sessionID == context.sessionID,
        intent.state == .unsettled, await files.writerStatus(in: context.directory) == .held,
        currentRegisteredLaunchGeneration?() == context.launchGeneration
      else { throw RegisteredRfbDisplayContext.failure() }
      return admission
    }
    guard let directoryPath, directoryPath.hasPrefix("/") else {
      throw Self.failure("Select the explicit private display fixture.")
    }
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = windowsVMDirectory
    let expectedParent =
      externalInputPolicy.selected
      ? URL(fileURLWithPath: ExternalWindowsHumanInputPolicy.runParentPath, isDirectory: true)
      : networkContinuation
        ? project.appendingPathComponent(
          ".lab/windows-network-adoption-29f9184c17884f6996f0eb24681fe9c0")
        : project.appendingPathComponent(".lab")
    guard directory.standardizedFileURL.path == directoryPath,
      directory.deletingLastPathComponent().path == expectedParent.path,
      directory.lastPathComponent.range(
        of: networkContinuation || externalInputPolicy.selected
          ? "^run-[0-9a-f]{32}$"
          : windowsInstaller
            ? "^windows-installer-boot-[0-9a-f]{32}$"
            : "^windows-efi-probe-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$", options: .regularExpression)
        != nil
    else { throw Self.failure("The selected route is outside the original private lab.") }
    let files = VMFiles()
    var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
    for component in directory.pathComponents.dropFirst() {
      ancestor.appendPathComponent(component, isDirectory: true)
      var info = stat()
      guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o022 == 0
      else { throw Self.failure("The private fixture ancestry is unsafe.") }
    }
    let routeURL = directory.appendingPathComponent("swift-display-ready.json")
    var info = stat()
    guard lstat(routeURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600
    else { throw Self.failure("The display route is not a private owned record.") }
    let data = try await files.readMetadata(at: routeURL, limit: 4096)
    let decoded = try FlatDisplayRouteCodec.decode(
      data,
      profile: externalInputPolicy.selected
        ? .windowsExternalContinuation
        : networkContinuation ? .windowsNetworkContinuation : .existing)
    let parent = URL(fileURLWithPath: decoded.controlSocket).deletingLastPathComponent()
    guard decoded.schemaVersion == 1,
      decoded.scope
        == (externalInputPolicy.selected
          ? ExternalWindowsHumanInputPolicy.scope
          : networkContinuation
            ? "approved-windows-network-continuation-display-route"
            : windowsInstaller
              ? "approved-windows-installer-display-route" : "original-diskless-display-route"),
      parent.path.range(
        of: externalInputPolicy.selected
          ? "^/private/tmp/mvo-win-external-[0-9a-f]{16}$"
          : networkContinuation
            ? "^/private/tmp/mvo-win-net-[0-9a-f]{16}$"
            : windowsInstaller
              ? "^/private/tmp/mvo-win-[0-9a-f]{16}$"
              : "^/private/tmp/mvo-efi-[0-9a-f]{16}$", options: .regularExpression)
        != nil,
      decoded.controlSocket == parent.appendingPathComponent("worker.sock").path,
      decoded.displaySocket == parent.appendingPathComponent("vnc.sock").path
    else { throw Self.failure("The display route is not the original worker session.") }
    if networkContinuation || externalInputPolicy.selected {
      guard decoded.vmID == UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
        decoded.sessionID != UUID(uuidString: "33333333-3333-4333-8333-333333333333"),
        let intent = try await files.readRuntimeIntent(in: fixture),
        intent.state == .unsettled, intent.vmID == decoded.vmID,
        intent.sessionID == decoded.sessionID,
        await files.writerStatus(in: fixture) == .held
      else { throw Self.failure("The continuation does not match its current owned VM session.") }
    }
    if externalInputPolicy.selected {
      guard externalInputPolicy.validateRoute(decoded, data: data) else {
        throw Self.failure("The external display does not match its explicitly bound session.")
      }
    } else if humanInput, !inputPolicy.validateHumanRoute(decoded) {
      throw Self.failure("The human-input route is not the approved Windows session.")
    }
    return (decoded, data)
  }

  private func verifyHumanCapture() async throws {
    guard humanInput, let route else {
      throw Self.failure("Select the approved human-input Windows display.")
    }
    let admission = try await readRoute()
    let admitted = admission.route
    guard admitted == route else {
      throw Self.failure("The Windows display route changed before input capture.")
    }
    let status = try await inspectControl(admitted)
    let fixture = windowsVMDirectory
    let files = VMFiles()
    let intent = try await files.readRuntimeIntent(in: fixture)
    let writerHeld = await files.writerStatus(in: fixture) == .held
    let allowed: Bool
    if let context = registeredContext {
      allowed = context.allowsCapture(
        status: status, intent: intent, writerHeld: writerHeld,
        currentLaunchGeneration: currentRegisteredLaunchGeneration?(), allowRecoveryInput: true)
    } else {
      allowed =
        externalInputPolicy.selected
        ? externalInputPolicy.allowsHumanCapture(
          route: admitted, data: admission.data, status: status, intent: intent,
          writerHeld: writerHeld)
        : inputPolicy.allowsHumanCapture(
          route: admitted, status: status, intent: intent, writerHeld: writerHeld)
    }
    guard allowed
    else { throw Self.failure("The approved Windows session cannot accept human input now.") }
  }

  private var windowsVMDirectory: URL {
    if let context = registeredContext { return context.directory }
    if externalInputPolicy.selected { return ExternalWindowsHumanInputPolicy.vmDirectory }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    return project.appendingPathComponent(
      ".lab/windows-installer-boot-6223442a7c544aa8a7f17061aec76f80")
  }

  private var displayLabel: String {
    if let context = registeredContext { return "\(context.configuration.name) • Experimental" }
    return humanInput
      ? "Windows display • Human input • Experimental"
      : observationOnly
        ? "Windows display • Observation only • Experimental"
        : windowsInstaller
          ? "Windows installer • Experimental"
          : "Original firmware display • Experimental"
  }

  private var registeredLaunchIsCurrent: Bool {
    guard let context = registeredContext else { return true }
    return currentRegisteredLaunchGeneration?() == context.launchGeneration
  }

  private func inspectControl(_ route: DisplayWorkerRoute) async throws -> WorkerResponse {
    let peer = WorkerIPCClient(
      socketURL: URL(fileURLWithPath: route.controlSocket), vmID: route.vmID,
      sessionID: route.sessionID)
    do {
      try await peer.connect()
      let result = try await peer.request(.status)
      await peer.close()
      return result
    } catch {
      await peer.close()
      throw error
    }
  }

  private static func failure(_ text: String) -> VMError {
    VMError(
      .invalidConfiguration, text, recovery: "Preserve the fixture and inspect its actual worker.")
  }
}

struct RfbLabDesktopView: View {
  @ObservedObject var session: RfbLabSession
  var guestName: String? = nil
  var waitingForWindowsShutdown = false
  var body: some View {
    VStack(spacing: 0) {
      RfbGuestSurface(session: session)
        .accessibilityLabel(guestName.map { "\($0) guest display" } ?? "Experimental guest display")
      // A status footer changes the backing-pixel viewport after a resize
      // request. Keep a live guest's geometry stable; its status is in View.
      if session.frame == nil {
        VMGlassGroup {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              VMGlassBadge(
                title: waitingForWindowsShutdown
                  ? "Waiting for Windows to shut down" : (session.consoleError ?? session.message),
                symbol: waitingForWindowsShutdown ? "hourglass" : "display")
              Spacer()
              if let frame = session.frame {
                Text("\(frame.size.width) × \(frame.size.height)").font(.caption.monospacedDigit())
              }
            }
            if waitingForWindowsShutdown {
              Text("Keep this window open until shutdown is complete.")
                .font(.callout).vmSupportingText()
            }
          }.padding(12)
        }
      }
    }
    .navigationTitle("macOpenVM")
    .ignoresSafeArea(.container, edges: session.fullscreen ? [] : .top)
    .toolbar(.hidden, for: .windowToolbar)
    .background(GuestWindowChrome())
    .task { await session.connectDisplay() }
  }
}

private struct RfbGuestSurface: NSViewRepresentable {
  @ObservedObject var session: RfbLabSession
  func makeNSView(context: Context) -> RfbGuestView {
    let view = RfbGuestView()
    view.hostPointerCapture = session.hostPointerCapture
    view.onAttachment = session.attach
    view.onNativeGeometry = session.nativeGeometryChanged
    view.onDisplayMeasurementInvalidated = session.displayMeasurementInvalidated
    view.onKey = session.key
    view.onPointer = session.pointer
    view.onRelativePointer = session.relativePointer
    view.onScroll = session.scroll
    view.onRelease = session.releaseInput
    view.onCaptureRefused = session.rejectUnavailableHostPointerCapture
    view.onSuspend = session.suspendInput
    view.onCapture = session.captureInput
    view.onFullscreen = session.fullscreenChanged
    view.onPrepareFullscreen = session.prepareFullscreen
    view.onPresentationFocusChanged = session.focusChanged
    view.onDetach = session.detach
    return view
  }
  func updateNSView(_ view: RfbGuestView, context: Context) {
    view.setPresentationSettings(session.presentationSettings)
    view.relativeMouse = session.relativeMouse
    view.captured = session.captured
    view.useGuestCursor = session.canChooseGuestCursor && session.useGuestCursor
    view.update(frame: session.frame)
  }
  static func dismantleNSView(_ view: RfbGuestView, coordinator: ()) { view.onDetach?(view) }
}

/// AppKit owns the Metal backing layer through a dedicated view, rather than
/// flattening it into the raster view's cached drawing. Input stays on the
/// guest view; only producer-driven Metal commands update this surface.
@MainActor final class SharedFrameMetalSurface: NSView {
  private let renderer: SharedFrameMetalRenderer

  init(renderer: SharedFrameMetalRenderer) {
    self.renderer = renderer
    super.init(frame: .zero)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { return nil }
  override func makeBackingLayer() -> CALayer { renderer.metalLayer }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {}
  override var isOpaque: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class RfbGuestView: NSView, GuestFrameTimingSource {
  var onQualificationPresentation: (@MainActor (RfbQualificationPresentation) -> Void)? {
    didSet { updateSharedDrawFeedback() }
  }
  var onFrameTimingDraw: (@MainActor (RfbQualificationPresentation) -> Void)? {
    didSet { updateSharedDrawFeedback() }
  }
  var onFrameTimingPresented: (@MainActor (RfbQualificationPresentation, Double) -> Void)? {
    didSet { sharedRenderer?.setPresentationFeedbackEnabled(onFrameTimingPresented != nil) }
  }
  var captured = false {
    didSet {
      if oldValue && !captured {
        keyboard.reset()
        pointerButtons = 0
        scrollAccumulator.reset()
      }
      if captured != oldValue { refreshCursor() }
    }
  }
  var capturePending = false {
    didSet {
      if oldValue && !capturePending && !captured { keyboard.reset() }
    }
  }
  var useGuestCursor = false {
    didSet { if useGuestCursor != oldValue { refreshCursor() } }
  }
  var relativeMouse = false {
    didSet { if relativeMouse != oldValue { refreshCursor() } }
  }
  var associateHostPointer: (Bool) -> CGError = {
    CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0)
  }
  var warpHostPointer: (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) }
  // Tests use a private coordinator and injected pointer effects. Production
  // retains failed restoration independently of this view's lifetime.
  var hostPointerCapture = GuestHostPointerCapture.shared
  private let hostPointerOwner = UUID()
  var relativeMouseLocked: Bool { hostPointerCapture.isCaptured(by: hostPointerOwner) }
  private var menuTracking = false
  private var trackingMenus: Set<ObjectIdentifier> = []
  private var relativeRemainder = CGPoint.zero
  private var warpBefore: TimeInterval = 0
  // Platform boundary also lets hidden-view tests verify cursor repair without
  // changing the user's actual pointer or activating a test window.
  var setHostCursor: (NSCursor) -> Void = { $0.set() }
  private let transparentCursor: NSCursor = {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32), let bytes = bitmap.bitmapData
    else {
      return .arrow
    }
    bytes.initialize(repeating: 0, count: 4)
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.addRepresentation(bitmap)
    return NSCursor(image: image, hotSpot: .zero)
  }()
  private var scrollAccumulator = GuestScrollAccumulator()
  var onAttachment: (@MainActor (RfbGuestView) -> Void)?
  var onNativeGeometry: (@MainActor (RfbGuestView, PixelSize?) -> Void)?
  var onDisplayMeasurementInvalidated: (@MainActor (RfbGuestView) -> Void)?
  private var geometryReportPending = false
  var onKey: (@MainActor (UInt32, Bool) -> Void)?
  var onPointer: (@MainActor (GuestPixelPoint, UInt8, PixelSize, UUID) -> Void)?
  var onRelativePointer: (@MainActor (Int, Int, UInt8, UUID) -> Void)?
  var onScroll: (@MainActor (GuestPixelPoint, Int, PixelSize, UUID) -> Void)?
  private var pointerButtons: UInt8 = 0
  private var pointerTracking: NSTrackingArea?
  var onRelease: (@MainActor () -> Void)?
  var onCaptureRefused: (@MainActor () -> Void)?
  var onSuspend: (@MainActor () -> Void)?
  var onCapture: (@MainActor () -> Void)?
  var onFullscreen: (@MainActor (Bool) -> Void)?
  var onPrepareFullscreen: (@MainActor () -> Void)?
  var onPresentationFocusChanged: (@MainActor () -> Void)?
  var onDetach: (@MainActor (RfbGuestView) -> Void)?
  private var image: NSImage?
  private var pixels: PixelSize?
  private var epoch: UUID?
  private var sequence: UInt64 = 0
  private var keyWindowObserver: NSObjectProtocol?
  private var fullscreenObservers: [NSObjectProtocol] = []
  private var windowCloseObserver: NSObjectProtocol?
  private var appInactiveObserver: NSObjectProtocol?
  private var activeSpaceObserver: NSObjectProtocol?
  private var keyboard = RFBKeyboardState()
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  private var timingCapture: GuestFrameTimingCapture?
  private var sharedRenderer: SharedFrameMetalRenderer?
  private var sharedSurface: SharedFrameMetalSurface?
  private var sharedPresentation = false
  private var sharedRenderToken = UUID()
  private var presentationSettings = GuestPresentationSettings()

  private func guestViewport(_ pixels: PixelSize) -> GuestViewport? {
    if presentationSettings.scaling == .fit {
      return try? GuestViewport(viewBounds: bounds, guestPixels: pixels)
    }
    return try? GuestViewport(
      viewBounds: bounds, guestPixels: pixels, backingBounds: convertToBacking(bounds),
      scaling: presentationSettings.scaling)
  }

  func setPresentationSettings(_ settings: GuestPresentationSettings) {
    guard settings != presentationSettings else { return }
    invalidateTimingForPresentationChange()
    setRelativeMouseCapture(false)
    presentationSettings = settings
    sharedRenderer?.setSharpeningEnabled(settings.sharpeningEnabled)
    refreshCursor()
    resizeSharedLayer()
    needsDisplay = true
  }

  func presentShared(_ frame: SharedFrame) async throws -> SharedFrameMetalRenderer.Completion {
    guard epoch == frame.connectionEpoch, pixels == frame.size, window != nil,
      let viewport = guestViewport(frame.size)
    else { throw SharedFrameMetalRenderer.Failure.geometry }
    let renderer: SharedFrameMetalRenderer
    if let current = sharedRenderer {
      renderer = current
    } else {
      let token = UUID()
      sharedRenderToken = token
      renderer = try SharedFrameMetalRenderer(
        presentationActive: sharedPresentationVisible,
        onDraw: {
          [weak self] value in
          Task { @MainActor [weak self] in
            guard let self, self.sharedRenderToken == token, self.sharedPresentation else { return }
            self.onFrameTimingDraw?(
              RfbQualificationPresentation(
                epoch: value.epoch, sequence: value.sequence, width: value.width,
                height: value.height,
                attached: self.window != nil, visible: self.window?.isVisible == true, drawn: true))
            self.reportQualificationPresentation(drawn: true)
          }
        },
        onPresented: { [weak self] value, hostTime in
          Task { @MainActor [weak self] in
            guard let self, self.sharedRenderToken == token, self.sharedPresentation else { return }
            self.onFrameTimingPresented?(
              RfbQualificationPresentation(
                epoch: value.epoch, sequence: value.sequence, width: value.width,
                height: value.height, attached: self.window != nil,
                visible: self.window?.isVisible == true, drawn: true), hostTime)
          }
        })
      sharedRenderer = renderer
      renderer.setSharpeningEnabled(presentationSettings.sharpeningEnabled)
      if let timingCapture { renderer.beginTimingCapture(timingCapture) }
      updateSharedDrawFeedback()
      renderer.setPresentationFeedbackEnabled(onFrameTimingPresented != nil)
      let surface = SharedFrameMetalSurface(renderer: renderer)
      sharedSurface = surface
      addSubview(surface)
    }
    let backing = updateSharedLayerGeometry(renderer)
    // Visibility can change before a renderer exists, or during attachment.
    // Reconcile the current window on receipt as well as on notifications.
    renderer.setPresentationActive(sharedPresentationVisible)
    sharedPresentation = true
    let area = viewport.fittedBackingRect ?? convertToBacking(viewport.fittedRect)
    return try await renderer.present(
      frame, drawableSize: backing.size,
      viewport: area.offsetBy(dx: -backing.minX, dy: -backing.minY))
  }

  private func updateSharedDrawFeedback() {
    sharedRenderer?.setDrawFeedbackEnabled(
      onQualificationPresentation != nil || onFrameTimingDraw != nil)
  }

  func beginTimingCapture(_ capture: GuestFrameTimingCapture) {
    if timingCapture?.id != capture.id { timingCapture?.cancel() }
    timingCapture = capture
    sharedRenderer?.beginTimingCapture(capture)
  }

  func endTimingCapture(_ capture: GuestFrameTimingCapture) {
    // Keep the numeric lifecycle owner through draining. A resize, hidden
    // surface or detached view must still cancel this sample after cutoff.
    if let sharedRenderer {
      sharedRenderer.endTimingCapture(capture)
    } else {
      capture.sourceDidStop()
    }
  }

  func retireTimingCapture(_ capture: GuestFrameTimingCapture) {
    if timingCapture?.id == capture.id { timingCapture = nil }
  }

  func stopShared() {
    timingCapture?.cancel()
    let renderer = sharedRenderer
    sharedRenderer = nil
    sharedRenderToken = UUID()
    sharedPresentation = false
    sharedSurface?.removeFromSuperview()
    sharedSurface = nil
    renderer?.close()
    needsDisplay = true
  }

  func reportSharedMeasurementState(ending: Bool) {
    guard let sharedRenderer else { return }
    NSLog(
      "macOpenVM Metal sample view: end=%d visible=%d attached=%d presenting=%d layer_attached=%d",
      ending ? 1 : 0, sharedPresentationVisible ? 1 : 0, window != nil ? 1 : 0,
      sharedPresentation ? 1 : 0,
      sharedSurface?.layer === sharedRenderer.metalLayer && sharedSurface?.superview === self
        ? 1 : 0)
    NSLog(
      "macOpenVM Metal sample window: visible=%d minimized=%d occlusion=%lu fullscreen=%d key=%d app_active=%d active_space=%d",
      window?.isVisible == true ? 1 : 0, window?.isMiniaturized == true ? 1 : 0,
      window?.occlusionState.rawValue ?? 0, window?.styleMask.contains(.fullScreen) == true ? 1 : 0,
      window?.isKeyWindow == true ? 1 : 0, NSApp.isActive ? 1 : 0,
      window?.isOnActiveSpace == true ? 1 : 0)
    if let surface = sharedSurface {
      NSLog(
        "macOpenVM Metal sample surface: hidden=%d ancestor_hidden=%d visible_rect=%@ frame=%@ bounds=%@ drawable=%@",
        surface.isHidden ? 1 : 0, surface.isHiddenOrHasHiddenAncestor ? 1 : 0,
        NSStringFromRect(surface.visibleRect), NSStringFromRect(surface.frame),
        NSStringFromRect(surface.bounds), NSStringFromSize(sharedRenderer.metalLayer.drawableSize))
      var current: CALayer? = surface.layer
      for depth in 0..<8 {
        guard let layer = current else { break }
        NSLog(
          "macOpenVM Metal sample layer: depth=%d type=%@ hidden=%d opacity=%.3f frame=%@ bounds=%@ masks=%d",
          depth, NSStringFromClass(type(of: layer)), layer.isHidden ? 1 : 0,
          layer.opacity, NSStringFromRect(layer.frame), NSStringFromRect(layer.bounds),
          layer.masksToBounds ? 1 : 0)
        current = layer.superlayer
      }
    }
    sharedRenderer.reportMeasurementState(ending: ending)
  }

  #if DEBUG
    func sharedRendererForValidation() -> SharedFrameMetalRenderer? { sharedRenderer }

    func sharedDrawableRequestsForValidation() async -> Int? {
      await sharedRenderer?.drawableRequestsForValidation()
    }
  #endif

  private func resizeSharedLayer() {
    guard let renderer = sharedRenderer, let pixels,
      let viewport = guestViewport(pixels)
    else { return }
    let backing = updateSharedLayerGeometry(renderer)
    let area = viewport.fittedBackingRect ?? convertToBacking(viewport.fittedRect)
    renderer.redraw(
      drawableSize: backing.size,
      viewport: area.offsetBy(dx: -backing.minX, dy: -backing.minY))
  }

  /// Keep Core Animation mutations on the view's run loop. The GPU queues
  /// consume numeric geometry; they must not leave implicit layer transactions
  /// pending on dispatch worker threads that have no run loop.
  private func updateSharedLayerGeometry(_ renderer: SharedFrameMetalRenderer) -> CGRect {
    let backing = convertToBacking(bounds)
    let pixels = CGSize(width: backing.width.rounded(.up), height: backing.height.rounded(.up))
    let scale = window?.backingScaleFactor ?? 1
    // Read actual view/layer values on every receipt: backing, bounds origins,
    // reattachment or another layer mutation can invalidate otherwise stable geometry.
    guard
      sharedSurface?.frame != bounds || renderer.metalLayer.contentsScale != scale
        || renderer.metalLayer.drawableSize != pixels
    else { return backing }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if sharedSurface?.frame != bounds { sharedSurface?.frame = bounds }
    if renderer.metalLayer.contentsScale != scale { renderer.metalLayer.contentsScale = scale }
    if renderer.metalLayer.drawableSize != pixels { renderer.metalLayer.drawableSize = pixels }
    CATransaction.commit()
    return backing
  }

  private var sharedPresentationVisible: Bool {
    guard let window else { return false }
    return SharedPresentationVisibility.shouldPresent(
      visible: window.isVisible, miniaturized: window.isMiniaturized,
      onActiveSpace: window.isOnActiveSpace,
      occlusionVisible: window.occlusionState.contains(.visible),
      fullscreen: window.styleMask.contains(.fullScreen), keyWindow: window.isKeyWindow,
      applicationActive: NSApp.isActive)
  }

  private func invalidateTimingForPresentationChange() {
    timingCapture?.cancel()
    onDisplayMeasurementInvalidated?(self)
  }

  fileprivate func refreshSharedPresentationVisibility() {
    if !sharedPresentationVisible { invalidateTimingForPresentationChange() }
    sharedRenderer?.setPresentationActive(sharedPresentationVisible)
  }

  func update(frame: RFBFrame?) {
    guard let frame else {
      stopShared()
      image = nil
      pixels = nil
      epoch = nil
      sequence = 0
      refreshCursor()
      needsDisplay = true
      return
    }
    if epoch == frame.connectionEpoch, frame.sequence <= sequence { return }
    guard (1...8192).contains(frame.size.width), (1...8192).contains(frame.size.height),
      frame.size.width * frame.size.height <= 16_777_216,
      frame.rgbaData.count == frame.size.width * frame.size.height * 4,
      let provider = CGDataProvider(data: frame.rgbaData as CFData),
      let color = CGColorSpace(name: CGColorSpace.sRGB),
      let raster = CGImage(
        width: frame.size.width, height: frame.size.height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: frame.size.width * 4, space: color,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
          .union(.byteOrder32Big),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return }
    epoch = frame.connectionEpoch
    sequence = frame.sequence
    let geometryChanged = pixels != frame.size
    pixels = frame.size
    if geometryChanged { refreshCursor() }
    image = NSImage(
      cgImage: raster, size: NSSize(width: frame.size.width, height: frame.size.height))
    needsDisplay = true
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard captured, window?.isOnActiveSpace == true, useGuestCursor || relativeMouse, let pixels,
      let viewport = guestViewport(pixels)
    else { return }
    addCursorRect(viewport.fittedRect, cursor: transparentCursor)
  }

  private func refreshCursor() {
    updateRelativeMouseLock()
    window?.invalidateCursorRects(for: self)
    applyCursor()
  }

  func updateRelativeMouseLock(applicationActive: Bool? = nil) {
    guard !releaseCaptureForUnavailablePointer() else { return }
    let eligible =
      captured && relativeMouse && !menuTracking
      && GuestInputCapturePolicy.isForeground(
        applicationActive: applicationActive ?? NSApp?.isActive ?? false,
        keyWindow: window?.isKeyWindow == true,
        onActiveSpace: window?.isOnActiveSpace == true)
      && window?.firstResponder === self
      && pixels != nil && epoch != nil
    guard eligible != relativeMouseLocked else { return }
    if eligible, let window,
      let viewport = pixels.flatMap({ guestViewport($0) }),
      let primary = NSScreen.screens.first
    {
      let local = NSPoint(x: viewport.fittedRect.midX, y: viewport.fittedRect.midY)
      let screen = window.convertPoint(toScreen: convert(local, to: nil))
      let result = warpHostPointer(CGPoint(x: screen.x, y: primary.frame.maxY - screen.y))
      guard result == .success else {
        onRelease?()
        return
      }
      warpBefore = ProcessInfo.processInfo.systemUptime
    }
    setRelativeMouseCapture(eligible, retryPending: false)
    _ = releaseCaptureForUnavailablePointer()
  }

  private func releaseCaptureForUnavailablePointer() -> Bool {
    // Desktop Mouse also needs normal host association. A failed restoration
    // or a different view's lease must refuse capture before any guest input.
    guard captured || capturePending, !hostPointerCapture.canAcquire(for: hostPointerOwner) else {
      return false
    }
    capturePending = false
    captured = false
    (onCaptureRefused ?? onRelease)?()
    return true
  }

  /// Platform boundary can be checked without moving or capturing a real mouse.
  func setRelativeMouseCapture(_ eligible: Bool, retryPending: Bool = true) {
    if !eligible {
      hostPointerCapture.restore(for: hostPointerOwner, retryPending: retryPending)
      if !relativeMouseLocked { relativeRemainder = .zero }
      return
    }
    guard hostPointerCapture.acquire(for: hostPointerOwner, associate: associateHostPointer) else {
      onRelease?()
      return
    }
    relativeRemainder = .zero
  }

  func cursor(at viewPoint: NSPoint, applicationActive: Bool, keyWindow: Bool) -> NSCursor {
    // Cursor rectangles remain scoped to this view. No process/global hide count
    // is changed; release, focus loss, detach and termination restore host input.
    guard captured, useGuestCursor || relativeMouse, !menuTracking,
      GuestInputCapturePolicy.isForeground(
        applicationActive: applicationActive, keyWindow: keyWindow,
        onActiveSpace: window?.isOnActiveSpace == true),
      let pixels, let viewport = guestViewport(pixels),
      viewport.map(viewPoint: viewPoint) != nil
    else { return .arrow }
    return transparentCursor
  }

  private func applyCursor(at viewPoint: NSPoint? = nil) {
    guard let window else {
      setHostCursor(.arrow)
      return
    }
    let point = viewPoint ?? convert(window.mouseLocationOutsideOfEventStream, from: nil)
    setHostCursor(
      cursor(at: point, applicationActive: NSApp.isActive, keyWindow: window.isKeyWindow))
  }

  // AppKit calls this while updating structural regions. Invalidating cursor
  // rectangles here would recursively schedule another structural update.
  override func cursorUpdate(with event: NSEvent) {
    applyCursor(at: convert(event.locationInWindow, from: nil))
  }
  override func mouseEntered(with event: NSEvent) {
    applyCursor(at: convert(event.locationInWindow, from: nil))
  }
  override func mouseExited(with event: NSEvent) {
    if relativeMouseLocked { applyCursor() } else { setHostCursor(.arrow) }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.setFill()
    bounds.fill()
    guard !sharedPresentation else { return }
    guard let image, let pixels,
      let viewport = guestViewport(pixels)
    else { return }
    NSGraphicsContext.current?.imageInterpolation = .none
    image.draw(
      in: viewport.fittedRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
      hints: nil)
    reportQualificationPresentation(drawn: true)
    timingCapture?.appKitDraw(epoch: epoch, size: pixels, sequence: sequence)
    onFrameTimingDraw?(
      RfbQualificationPresentation(
        epoch: epoch, sequence: sequence, width: pixels.width, height: pixels.height,
        attached: window != nil, visible: window?.isVisible == true, drawn: true))
  }

  func reportQualificationPresentation(drawn: Bool) {
    guard let onQualificationPresentation else { return }
    onQualificationPresentation(
      RfbQualificationPresentation(
        epoch: epoch, sequence: sequence,
        width: pixels?.width, height: pixels?.height, attached: window != nil,
        visible: window?.isVisible == true, drawn: drawn))
  }

  private func scheduleNativeGeometry() {
    resizeSharedLayer()
    guard !geometryReportPending else { return }
    geometryReportPending = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.geometryReportPending = false
      let pixels =
        self.window == nil
        ? nil
        : GuestBackingGeometry.pixels(forBackingBounds: self.convertToBacking(self.bounds))
      self.onNativeGeometry?(self, pixels)
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    if frame.size != newSize { invalidateTimingForPresentationChange() }
    super.setFrameSize(newSize)
    scheduleNativeGeometry()
  }

  override func setBoundsSize(_ newSize: NSSize) {
    if bounds.size != newSize { invalidateTimingForPresentationChange() }
    super.setBoundsSize(newSize)
    scheduleNativeGeometry()
  }

  override func viewDidChangeBackingProperties() {
    invalidateTimingForPresentationChange()
    super.viewDidChangeBackingProperties()
    scheduleNativeGeometry()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshSharedPresentationVisibility()
    scheduleNativeGeometry()
    if window != nil {
      onAttachment?(self)
    } else {
      // The session's deferred detach joins a replacement in this actor turn.
      onDetach?(self)
    }
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if let window, newWindow !== window {
      invalidateTimingForPresentationChange()
      onSuspend?()
    }
    if relativeMouseLocked, newWindow !== window {
      setRelativeMouseCapture(false)
    }
    trackingMenus.removeAll()
    menuTracking = false
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    keyWindowObserver = nil
    if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    windowCloseObserver = nil
    if let appInactiveObserver { NotificationCenter.default.removeObserver(appInactiveObserver) }
    appInactiveObserver = nil
    if let activeSpaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
    }
    activeSpaceObserver = nil
    for observer in fullscreenObservers { NotificationCenter.default.removeObserver(observer) }
    fullscreenObservers.removeAll()
    if let newWindow {
      activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
      ) { [weak self, weak newWindow] _ in
        MainActor.assumeIsolated {
          guard let self, let newWindow, self.window === newWindow else { return }
          self.refreshSharedPresentationVisibility()
          self.onPresentationFocusChanged?()
        }
      }
      fullscreenObservers.append(
        NotificationCenter.default.addObserver(
          forName: NSWindow.didChangeOcclusionStateNotification, object: newWindow, queue: .main
        ) { [weak self, weak newWindow] _ in
          MainActor.assumeIsolated {
            guard let self, let newWindow, self.window === newWindow else { return }
            self.refreshSharedPresentationVisibility()
          }
        })
      for (name, tracking) in [
        (NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false),
      ] {
        fullscreenObservers.append(
          NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
          ) { [weak self, weak newWindow] notification in
            let identity = (notification.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
              guard let self, let newWindow, self.window === newWindow,
                let identity
              else { return }
              if tracking {
                self.trackingMenus.insert(identity)
              } else {
                self.trackingMenus.remove(identity)
              }
              self.menuTracking = !self.trackingMenus.isEmpty
              self.refreshCursor()
            }
          })
      }
      fullscreenObservers.append(
        NotificationCenter.default.addObserver(
          forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.relativeMouseLocked else { return }
            self.setRelativeMouseCapture(false)
          }
        })
      appInactiveObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.window != nil, !NSApp.isActive else { return }
          if let changed = self.onPresentationFocusChanged { changed() } else { self.onSuspend?() }
        }
      }
      windowCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
      ) { [weak self, weak newWindow] _ in
        MainActor.assumeIsolated {
          guard let self, let newWindow, self.window === newWindow else { return }
          self.onFullscreen?(false)
          self.onDetach?(self)
        }
      }
      keyWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main
      ) { [weak self, weak newWindow] _ in
        MainActor.assumeIsolated {
          guard let self, let newWindow, self.window === newWindow, !newWindow.isKeyWindow else {
            return
          }
          if let changed = self.onPresentationFocusChanged { changed() } else { self.onSuspend?() }
        }
      }
      fullscreenObservers.append(
        NotificationCenter.default.addObserver(
          forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.onPresentationFocusChanged?() }
        })
      for name in [
        NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
      ] {
        fullscreenObservers.append(
          NotificationCenter.default.addObserver(
            forName: name, object: newWindow, queue: .main
          ) { [weak self, weak newWindow] _ in
            MainActor.assumeIsolated {
              guard let self, let newWindow, self.window === newWindow else { return }
              if name == NSWindow.willEnterFullScreenNotification {
                self.onPrepareFullscreen?()
              } else if name == NSWindow.didBecomeKeyNotification {
                self.onPresentationFocusChanged?()
              } else {
                self.onFullscreen?(newWindow.styleMask.contains(.fullScreen))
              }
            }
          })
      }
    }
    super.viewWillMove(toWindow: newWindow)
  }
  override func resignFirstResponder() -> Bool {
    onSuspend?()
    return super.resignFirstResponder()
  }
  override func updateTrackingAreas() {
    if let pointerTracking { removeTrackingArea(pointerTracking) }
    let tracking = NSTrackingArea(
      rect: .zero,
      options: [
        .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect,
        .enabledDuringMouseDrag,
      ],
      owner: self,
      userInfo: nil)
    pointerTracking = tracking
    addTrackingArea(tracking)
    super.updateTrackingAreas()
    applyCursor()
  }
  override func scrollWheel(with event: NSEvent) {
    guard permitsInputOnCurrentSpace() else {
      scrollAccumulator.reset()
      return
    }
    let viewPoint = convert(event.locationInWindow, from: nil)
    applyCursor(at: viewPoint)
    guard captured, window?.isOnActiveSpace == true,
      window?.isKeyWindow == true, window?.firstResponder === self,
      let pixels, let epoch,
      let viewport = guestViewport(pixels),
      let point = viewport.map(viewPoint: viewPoint)
    else {
      scrollAccumulator.reset()
      return
    }
    guard forwardPointerModifiers(event.modifierFlags), self.pixels == pixels, self.epoch == epoch
    else { return }
    let steps = scrollAccumulator.consume(
      verticalDelta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
    if steps != 0 { onScroll?(point, steps, pixels, epoch) }
  }
  override func mouseMoved(with event: NSEvent) { forwardPointer(event) }
  override func mouseDragged(with event: NSEvent) { forwardPointer(event) }
  override func rightMouseDragged(with event: NSEvent) { forwardPointer(event) }
  override func otherMouseDragged(with event: NSEvent) { forwardPointer(event) }
  override func mouseDown(with event: NSEvent) { pointerButton(event, bit: 1, down: true) }
  override func mouseUp(with event: NSEvent) { pointerButton(event, bit: 1, down: false) }
  override func rightMouseDown(with event: NSEvent) { pointerButton(event, bit: 4, down: true) }
  override func rightMouseUp(with event: NSEvent) { pointerButton(event, bit: 4, down: false) }
  override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 { pointerButton(event, bit: 2, down: true) }
  }
  override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 { pointerButton(event, bit: 2, down: false) }
  }
  private func pointerButton(_ event: NSEvent, bit: UInt8, down: Bool) {
    guard permitsInputOnCurrentSpace() else { return }
    guard captured else {
      if down { onCapture?() }
      return
    }
    forwardPointer(event, button: (bit, down))
  }
  private func forwardPointer(_ event: NSEvent, button: (bit: UInt8, down: Bool)? = nil) {
    guard permitsInputOnCurrentSpace() else { return }
    if relativeMouse, captured {
      updateRelativeMouseLock()
      guard captured, relativeMouseLocked, !hostPointerCapture.restorationPending,
        let epoch, event.timestamp > warpBefore
      else { return }
      applyCursor()
      let motion = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        .contains(event.type)
      let x = (motion ? event.deltaX : 0) + relativeRemainder.x
      let y = (motion ? event.deltaY : 0) + relativeRemainder.y
      guard x.isFinite, y.isFinite, abs(x) <= 32767, abs(y) <= 32767 else {
        onRelease?()
        return
      }
      let dx = Int(x.rounded(.towardZero))
      let dy = Int(y.rounded(.towardZero))
      guard forwardPointerModifiers(event.modifierFlags), self.epoch == epoch,
        relativeMouse, relativeMouseLocked
      else { return }
      relativeRemainder = CGPoint(x: x - Double(dx), y: y - Double(dy))
      updatePointerButtons(button)
      onRelativePointer?(dx, dy, pointerButtons, epoch)
      return
    }
    let viewPoint = convert(event.locationInWindow, from: nil)
    // AppKit/hosting views can replace the current cursor after cursorUpdate.
    // Reassert this view's choice on real movement, dragging and button input.
    applyCursor(at: viewPoint)
    guard captured, window?.isOnActiveSpace == true,
      window?.isKeyWindow == true, window?.firstResponder === self,
      let pixels, let epoch
    else { return }
    guard let viewport = guestViewport(pixels),
      let point = viewport.map(viewPoint: viewPoint)
    else {
      // Exiting the usable viewport releases held input; never clamp a click in
      // the letterbox onto a guest control. The host cursor remains available.
      onSuspend?()
      return
    }
    guard forwardPointerModifiers(event.modifierFlags), self.pixels == pixels, self.epoch == epoch
    else { return }
    updatePointerButtons(button)
    onPointer?(point, pointerButtons, pixels, epoch)
  }

  private func updatePointerButtons(_ change: (bit: UInt8, down: Bool)?) {
    guard let change else { return }
    if change.down { pointerButtons |= change.bit } else { pointerButtons &= ~change.bit }
  }

  private func forwardPointerModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
    guard captured, window?.isKeyWindow == true, window?.firstResponder === self,
      forwardModifiers(flags)
    else { return false }
    // A modifier callback may synchronously suspend input or change pointer
    // custody. Never continue its original mouse event after that transition.
    return captured && window?.isKeyWindow == true && window?.firstResponder === self
      && permitsInputOnCurrentSpace()
  }

  override func keyDown(with event: NSEvent) {
    guard captured || capturePending, !event.isARepeat else { return }
    if isReleaseShortcut(event) {
      onRelease?()
      return
    }
    guard permitsInputOnCurrentSpace() else { return }
    guard forwardModifiers(event.modifierFlags) else { return }
    guard let symbol = RFBKeySymbol.appKitCharacters(event.charactersIgnoringModifiers) else {
      return
    }
    do { forward(try keyboard.press(keyCode: event.keyCode, symbol: symbol)) } catch {
      onRelease?()
    }
  }
  override func keyUp(with event: NSEvent) {
    guard captured || capturePending, permitsInputOnCurrentSpace() else { return }
    guard forward(keyboard.release(keyCode: event.keyCode)) else { return }
    forwardModifiers(event.modifierFlags)
  }
  override func flagsChanged(with event: NSEvent) {
    guard captured || capturePending, permitsInputOnCurrentSpace() else { return }
    forwardModifiers(event.modifierFlags)
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // The VM's real macOS fullscreen control remains a host command.
    if event.keyCode == 3,
      event.modifierFlags.intersection([.control, .option, .command, .shift]) == [
        .control, .command,
      ]
    {
      return false
    }
    // Switching applications must remain available while the guest owns input.
    if event.keyCode == 48,
      event.modifierFlags.intersection([.control, .option, .command]) == .command
    {
      return false
    }
    guard captured || capturePending, window?.isKeyWindow == true,
      window?.firstResponder === self
    else {
      return super.performKeyEquivalent(with: event)
    }
    if isReleaseShortcut(event) {
      onRelease?()
      return true
    }
    guard permitsInputOnCurrentSpace() else { return true }
    // Command/menu navigation may consume key-up. Ordinary Control/Option
    // movement must stay held until its physical release reaches keyUp.
    guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      !event.isARepeat,
      let symbol = RFBKeySymbol.appKitCharacters(event.charactersIgnoringModifiers)
    else { return super.performKeyEquivalent(with: event) }
    if !event.modifierFlags.contains(.command), event.keyCode != 48 {
      keyDown(with: event)
      return true
    }
    do {
      forward(
        try keyboard.shortcut(
          keyCode: event.keyCode, symbol: symbol,
          modifiers: Self.guestModifiers(event.modifierFlags)))
      return true
    } catch {
      onRelease?()
      return true
    }
  }
  private func permitsInputOnCurrentSpace() -> Bool {
    guard !releaseCaptureForUnavailablePointer() else { return false }
    guard window?.isOnActiveSpace == true else {
      // A missed Space notification must not retain a key whose physical up
      // arrived while the guest was invisible. The session releases its peer's
      // held state; local capture resets even when there is no connected owner.
      onSuspend?()
      captured = false
      capturePending = false
      setRelativeMouseCapture(false, retryPending: false)
      return false
    }
    if captured || capturePending {
      guard window?.isKeyWindow == true, window?.firstResponder === self else {
        // A missed focus notification must also discard queued pending keys
        // and a button whose physical release arrives while the guest is hidden.
        onSuspend?()
        capturePending = false
        captured = false
        keyboard.reset()
        setRelativeMouseCapture(false, retryPending: false)
        return false
      }
    }
    return true
  }
  private func isReleaseShortcut(_ event: NSEvent) -> Bool {
    // Escape is a physical host command even when a keyboard layout or input
    // method omits its character string. Never send the release key to Windows.
    event.keyCode == 53
      && event.modifierFlags.intersection([.control, .option, .command, .shift]) == [
        .control, .option,
      ]
  }
  @discardableResult private func forwardModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
    forward(keyboard.changeModifiers(Self.guestModifiers(flags)))
  }
  private static func guestModifiers(_ flags: NSEvent.ModifierFlags) -> RFBKeyboardModifiers {
    var modifiers: RFBKeyboardModifiers = []
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.option) { modifiers.insert(.alt) }
    if flags.contains(.command) { modifiers.insert(.command) }
    return modifiers
  }
  @discardableResult private func forward(_ strokes: [RFBKeyStroke]) -> Bool {
    for stroke in strokes {
      guard permitsKeyForwarding() else { return false }
      onKey?(stroke.symbol, stroke.down)
    }
    return permitsKeyForwarding()
  }

  private func permitsKeyForwarding() -> Bool {
    (captured || capturePending) && permitsInputOnCurrentSpace()
  }
}
