// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Metal
import Qemu
import QuartzCore

/// The render queue owns all mutable GPU state. MainActor only attaches and
/// sizes the layer. No command-buffer wait or drawable acquisition blocks UI.
final class SharedFrameMetalRenderer: @unchecked Sendable {
  struct Completion: Sendable {
    let gpuMS: Double?
  }
  enum Failure: Error, Equatable { case unavailable, closed, geometry, gpu, timeout }
  let metalLayer = CAMetalLayer()
  private let device: any MTLDevice
  private let render = DispatchQueue(label: "local.macOpenVM.metal-frame", qos: .userInteractive)
  private var commands: (any MTLCommandQueue)?
  private var pipeline: (any MTLRenderPipelineState)?
  private var sharpeningPipeline: (any MTLRenderPipelineState)?
  private let compiler = DispatchQueue(label: "local.macOpenVM.metal-compiler", qos: .utility)
  private var sharpeningPreparationStarted = false
  private var sharpeningEnabled = false
  private var drawableSize = CGSize.zero
  private var cache: (any MTLTexture)?
  private var imports: [ObjectIdentifier: any MTLTexture] = [:]
  private var closed = false
  private let acquire = DispatchQueue(
    label: "local.macOpenVM.metal-drawable", qos: .userInteractive,
    autoreleaseFrequency: .workItem)
  private var drawablePending = false
  private var presentationWanted = false
  private var presentationActive: Bool
  private var drawableRetryPolicy = SharedDrawableRetryPolicy()
  private var drawableRetryTicket: SharedDrawableRetryPolicy.Ticket?
  private var drawableRetryTimer: (any DispatchSourceTimer)?
  #if DEBUG
    private var acquireForValidation: (@Sendable () -> Bool)?
    private var drawableSizeForValidation: (@Sendable () -> CGSize)?
    private var scheduleForValidation: (@Sendable (Int, @escaping @Sendable () -> Void) -> Void)?
    private var outputForValidation: (any MTLTexture)?
    private var beforeSharpeningInstallForValidation: (@Sendable () -> Void)?
  #endif
  private var drawFeedbackEnabled = false
  private var presentationFeedbackEnabled = false
  private var timingCapture: GuestFrameTimingCapture?
  private var viewport: CGRect = .zero
  private var stamp: RfbQualificationPresentation?
  private let onDraw: @Sendable (RfbQualificationPresentation) -> Void
  private let onPresented: @Sendable (RfbQualificationPresentation, Double) -> Void
  private var slowAcquisitions = 0
  private var slowCopies = 0
  private var drawableRequests = 0
  private var completedCopies = 0
  private var completedDraws = 0
  private var presentationCallbacks = 0
  private var zeroPresentationTimes = 0
  private var positivePresentationTimes = 0
  private var visibilityReports = 0

  @MainActor init(
    presentationActive: Bool = false,
    onDraw: @escaping @Sendable (RfbQualificationPresentation) -> Void = { _ in },
    onPresented: @escaping @Sendable (RfbQualificationPresentation, Double) -> Void = { _, _ in }
  )
    throws
  {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
      throw Failure.unavailable
    }
    self.device = device
    self.presentationActive = presentationActive
    self.onDraw = onDraw
    self.onPresented = onPresented
    metalLayer.device = device
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metalLayer.isOpaque = true
    metalLayer.framebufferOnly = true
    metalLayer.maximumDrawableCount = 3
    metalLayer.displaySyncEnabled = true
    metalLayer.allowsNextDrawableTimeout = true
    metalLayer.presentsWithTransaction = false
  }

  /// Completion releases only the shared input slot. Screen acquisition and
  /// presentation are independent; their possible one-second wait cannot delay ACK.
  func present(_ frame: SharedFrame, drawableSize: CGSize, viewport: CGRect) async throws
    -> Completion
  {
    try await withCheckedThrowingContinuation { continuation in
      render.async { [self] in
        autoreleasepool {
          do {
            guard !closed else { throw Failure.closed }
            try prepare()
            try geometry(drawableSize, viewport)
            self.drawableSize = Self.pixelSize(drawableSize)
            guard let commands, let command = commands.makeCommandBuffer() else {
              throw Failure.unavailable
            }
            try encodeSharedCopy(frame, command: command)
            self.viewport = viewport
            stamp = RfbQualificationPresentation(
              epoch: frame.streamEpoch, sequence: frame.sequence,
              width: frame.size.width, height: frame.size.height, attached: true, visible: true,
              drawn: true)
            let pending = Pending(continuation)
            let deadline = DispatchSource.makeTimerSource(queue: render)
            deadline.schedule(deadline: .now() + 2)
            deadline.setEventHandler { pending.finish(.failure(Failure.timeout)) }
            deadline.activate()
            let began = ContinuousClock.now
            command.addCompletedHandler { [self, mapping = frame.mapping] value in
              let ok = value.status == .completed
              let ms =
                value.gpuStartTime > 0 && value.gpuEndTime >= value.gpuStartTime
                ? (value.gpuEndTime - value.gpuStartTime) * 1000 : nil
              render.async {
                _ = mapping
                deadline.cancel()
                if ok { self.completedCopies += 1 }
                let waitMS = Self.milliseconds(began.duration(to: .now))
                if waitMS > 50, self.slowCopies < 8 {
                  self.slowCopies += 1
                  NSLog("macOpenVM Metal cache completion: ms=%.3f", waitMS)
                }
                pending.finish(ok ? .success(Completion(gpuMS: ms)) : .failure(Failure.gpu))
              }
            }
            // One GPU queue orders cache writes and presentation reads. Neither
            // can overlap an overwrite; every submitted command retains resources.
            command.commit()
            resetDrawableRetry()
            presentationWanted = true
            requestDrawable()
          } catch { continuation.resume(throwing: error) }
        }
      }
    }
  }

  func redraw(drawableSize: CGSize, viewport: CGRect) {
    render.async { [self] in
      guard !closed, (try? geometry(drawableSize, viewport)) != nil else { return }
      self.drawableSize = Self.pixelSize(drawableSize)
      self.viewport = viewport
      resetDrawableRetry()
      presentationWanted = true
      requestDrawable()
    }
  }

  func setSharpeningEnabled(_ enabled: Bool) {
    render.async { [self] in
      guard !closed, sharpeningEnabled != enabled else { return }
      sharpeningEnabled = enabled
      if enabled { prepareSharpening() }
      presentationWanted = cache != nil
      resetDrawableRetry()
      requestDrawable()
    }
  }

  /// Hidden windows still copy and acknowledge producer slots. Defer screen
  /// acquisition until AppKit reports the window visible, then draw the latest
  /// cache instead of queuing obsolete frames while the layer is unavailable.
  func setPresentationActive(_ active: Bool) {
    render.async { [self] in
      guard !closed, presentationActive != active else { return }
      presentationActive = active
      if !active { timingCapture?.cancel() }
      cancelDrawableRetry()
      if visibilityReports < 8 {
        visibilityReports += 1
        NSLog(
          "macOpenVM Metal presentation visibility: active=%d drawable_pending=%d",
          active ? 1 : 0, drawablePending ? 1 : 0)
      }
      if active {
        drawableRetryPolicy.reset()
        presentationWanted = cache != nil
        requestDrawable()
      }
    }
  }

  /// Draw completion is always tracked, but the UI observer is opt-in.
  /// Ordinary presentation has no qualification or timing consumer to notify.
  func setDrawFeedbackEnabled(_ enabled: Bool) {
    render.async { [self] in drawFeedbackEnabled = enabled }
  }

  func beginTimingCapture(_ capture: GuestFrameTimingCapture) {
    render.async { [self] in
      guard !closed else {
        capture.cancel()
        return
      }
      guard capture.diagnostics().status == .sampling else { return }
      if timingCapture?.id != capture.id { timingCapture?.cancel() }
      timingCapture = capture
    }
  }

  func endTimingCapture(_ capture: GuestFrameTimingCapture) {
    render.async { [self] in
      if timingCapture?.id == capture.id { timingCapture = nil }
      capture.sourceDidStop()
    }
  }

  func setPresentationFeedbackEnabled(_ enabled: Bool) {
    render.async { [self] in presentationFeedbackEnabled = enabled }
  }

  /// Numeric state only, emitted at the boundaries of an opt-in sample.
  func reportMeasurementState(ending: Bool) {
    render.async { [self] in
      NSLog(
        "macOpenVM Metal sample state: end=%d active=%d pending=%d wanted=%d requests=%d copied=%d drawn=%d closed=%d",
        ending ? 1 : 0, presentationActive ? 1 : 0, drawablePending ? 1 : 0,
        presentationWanted ? 1 : 0, drawableRequests, completedCopies, completedDraws,
        closed ? 1 : 0)
      NSLog(
        "macOpenVM Metal sample callbacks: end=%d callbacks=%d zero=%d positive=%d feedback=%d",
        ending ? 1 : 0, presentationCallbacks, zeroPresentationTimes,
        positivePresentationTimes, presentationFeedbackEnabled || timingCapture != nil ? 1 : 0)
    }
  }

  private func requestDrawable() {
    guard !closed, presentationActive, !drawablePending, presentationWanted, cache != nil else {
      return
    }
    drawablePending = true
    drawableRequests += 1
    #if DEBUG
      let validationAcquire = acquireForValidation
      let validationSize = drawableSizeForValidation
    #endif
    acquire.async { [self] in
      autoreleasepool {
        let began = ContinuousClock.now
        let drawable: Drawable?
        #if DEBUG
          if let validationAcquire {
            if validationAcquire() {
              let size = validationSize?() ?? CGSize(width: 64, height: 64)
              let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height),
                mipmapped: false)
              descriptor.storageMode = .shared
              descriptor.usage = [.renderTarget]
              drawable = device.makeTexture(descriptor: descriptor).map { Drawable(texture: $0) }
            } else {
              drawable = nil
            }
          } else {
            drawable = metalLayer.nextDrawable().map { Drawable(value: $0) }
          }
        #else
          drawable = metalLayer.nextDrawable().map { Drawable(value: $0) }
        #endif
        let waitMS = Self.milliseconds(began.duration(to: .now))
        render.async { [self] in
          autoreleasepool {
            if waitMS > 50, slowAcquisitions < 8 {
              slowAcquisitions += 1
              NSLog("macOpenVM Metal drawable acquisition: ms=%.3f", waitMS)
            }
            guard !closed, presentationActive else {
              drawablePending = false
              return
            }
            guard let drawable else {
              drawablePending = false
              scheduleDrawableRetry()
              return
            }
            // Acquisition may have started before a resize. Never stretch an
            // obsolete-size drawable using the latest viewport or consume the
            // pending frame; Core Animation will supply the current size next.
            guard drawable.texture.width == Int(drawableSize.width),
              drawable.texture.height == Int(drawableSize.height)
            else {
              drawablePending = false
              scheduleDrawableRetry()
              return
            }
            guard let commands, let command = commands.makeCommandBuffer(),
              let drawn = stamp
            else {
              drawablePending = false
              return
            }
            // Coalesce to the latest cache/stamp after acquisition, without
            // keeping a queue of obsolete frames or borrowing the producer slot.
            do {
              try encodePlane(command, texture: drawable.texture, viewport: viewport)
              // Only immutable numeric state crosses the native boundary.
              // A ticket retains its sample owner until the real callbacks end.
              let feedback =
                drawable.value == nil
                ? nil
                : timingCapture?.issue(
                  epoch: drawn.epoch,
                  size: drawn.width.flatMap { width in
                    drawn.height.map { PixelSize(width: width, height: $0) }
                  }, sequence: drawn.sequence)
              if presentationFeedbackEnabled || feedback != nil, let screen = drawable.value {
                screen.addPresentedHandler { [weak self, feedback] shown in
                  let time = shown.presentedTime
                  feedback?.presented(hostTime: time)
                  // Metal reports zero for skipped/unpresented drawables. A
                  // completion callback alone cannot establish presentation.
                  guard let self else { return }
                  self.render.async { [weak self] in
                    guard let self else { return }
                    self.presentationCallbacks += 1
                    if time.isFinite, time > 0 {
                      self.positivePresentationTimes += 1
                    } else {
                      self.zeroPresentationTimes += 1
                    }
                    guard time.isFinite, time > 0, !self.closed, self.presentationActive,
                      self.presentationFeedbackEnabled
                    else { return }
                    self.onPresented(drawn, time)
                  }
                }
              }
              if let screen = drawable.value { command.present(screen) }
              #if DEBUG
                if drawable.value == nil { outputForValidation = drawable.texture }
              #endif
              command.addCompletedHandler { [self, feedback] value in
                let ok = value.status == .completed
                // This is native callback-entry time, not GPU-end/scanout time.
                feedback?.completed(success: ok, hostTime: CACurrentMediaTime())
                render.async {
                  if ok { self.completedDraws += 1 }
                  if !self.closed, self.presentationActive, ok, self.drawFeedbackEnabled {
                    self.onDraw(drawn)
                  }
                  self.drawablePending = false
                  self.requestDrawable()
                }
              }
              presentationWanted = false
              resetDrawableRetry()
              command.commit()
            } catch { drawablePending = false }
          }
        }
      }
    }
  }

  private func cancelDrawableRetry() {
    drawableRetryTimer?.cancel()
    drawableRetryTimer = nil
    drawableRetryTicket = nil
    drawableRetryPolicy.cancel()
  }

  private func resetDrawableRetry() {
    cancelDrawableRetry()
    drawableRetryPolicy.reset()
  }

  private func scheduleDrawableRetry() {
    guard !closed, presentationActive, presentationWanted, cache != nil,
      drawableRetryTicket == nil, let ticket = drawableRetryPolicy.next()
    else { return }
    drawableRetryTicket = ticket
    #if DEBUG
      if let scheduleForValidation {
        scheduleForValidation(ticket.delayMS) { [weak self] in
          self?.render.async { [weak self] in self?.performDrawableRetry(ticket) }
        }
        return
      }
    #endif
    let timer = DispatchSource.makeTimerSource(queue: render)
    timer.schedule(deadline: .now() + .milliseconds(ticket.delayMS))
    timer.setEventHandler { [weak self] in self?.performDrawableRetry(ticket) }
    drawableRetryTimer = timer
    timer.activate()
  }

  private func performDrawableRetry(_ ticket: SharedDrawableRetryPolicy.Ticket) {
    // Validate before clearing state: an old callback must not cancel a newer
    // budget's timer, even if cancellation races the callback's dispatch.
    guard drawableRetryTicket == ticket, drawableRetryPolicy.isCurrent(ticket) else { return }
    drawableRetryTimer?.cancel()
    drawableRetryTimer = nil
    drawableRetryTicket = nil
    requestDrawable()
  }

  func close() {
    render.async { [self] in
      closed = true
      timingCapture?.cancel()
      timingCapture = nil
      presentationWanted = false
      cancelDrawableRetry()
      imports.removeAll()
      cache = nil
      stamp = nil
      // A waiting acquisition may return later. Closed checks prevent presentation;
      // existing GPU commands retain all borrowed mappings through completion.
    }
  }
  private static func milliseconds(_ value: Duration) -> Double {
    let c = value.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
  }
  private struct Drawable: @unchecked Sendable {
    let value: (any CAMetalDrawable)?
    let texture: any MTLTexture
    init(value: any CAMetalDrawable) {
      self.value = value
      texture = value.texture
    }
    #if DEBUG
      init(texture: any MTLTexture) {
        value = nil
        self.texture = texture
      }
    #endif
  }
  private func geometry(_ size: CGSize, _ viewport: CGRect) throws {
    guard size.width.isFinite, size.height.isFinite,
      viewport.minX.isFinite, viewport.minY.isFinite,
      viewport.width.isFinite, viewport.height.isFinite,
      size.width > 0, size.height > 0, size.width <= 8192, size.height <= 8192,
      viewport.width > 0, viewport.height > 0, viewport.minX >= 0, viewport.minY >= 0,
      viewport.maxX <= size.width, viewport.maxY <= size.height
    else { throw Failure.geometry }
  }
  private static func pixelSize(_ size: CGSize) -> CGSize {
    CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
  }
  private func importTexture(_ frame: SharedFrame) throws -> any MTLTexture {
    let key = ObjectIdentifier(frame.mapping)
    if let existing = imports[key] { return existing }
    guard frame.rowBytes % device.minimumLinearTextureAlignment(for: .bgra8Unorm) == 0,
      frame.mapping.byteCount <= device.maxBufferLength
    else { throw Failure.geometry }
    let mapping = frame.mapping
    let buffer: (any MTLBuffer)? = mapping.withUnsafeBytes { bytes in
      guard let pointer = bytes.baseAddress else { return nil }
      return device.makeBuffer(
        bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer),
        length: bytes.count, options: .storageModeShared,
        deallocator: { _, _ in _ = mapping })
    }
    guard let buffer else { throw Failure.unavailable }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: frame.size.width, height: frame.size.height, mipmapped: false)
    desc.storageMode = .shared
    desc.usage = [.shaderRead]
    guard let texture = buffer.makeTexture(descriptor: desc, offset: 0, bytesPerRow: frame.rowBytes)
    else { throw Failure.unavailable }
    if imports.count >= 2 { imports.removeAll() }
    imports[key] = texture
    return texture
  }
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 p [[position]]; float2 uv; };
    vertex Vertex plane(uint i [[vertex_id]]) {
      float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
      return Vertex{float4(p[i],0,1),float2((p[i].x+1)/2,(1-p[i].y)/2)};
    }
    fragment half4 opaque(Vertex v [[stage_in]],texture2d<half> image [[texture(0)]]) {
      constexpr sampler points(coord::normalized,address::clamp_to_edge,filter::nearest);
      return half4(image.sample(points,v.uv).rgb,1);
    }
    """

  private static let sharpeningShader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 p [[position]]; float2 uv; };
    vertex Vertex plane(uint i [[vertex_id]]) {
      float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
      return Vertex{float4(p[i],0,1),float2((p[i].x+1)/2,(1-p[i].y)/2)};
    }
    fragment half4 lightSharp(Vertex v [[stage_in]],texture2d<half> image [[texture(0)]]) {
      constexpr sampler points(coord::normalized,address::clamp_to_edge,filter::nearest);
      float2 step = 1.0f / float2(image.get_width(), image.get_height());
      float3 c = float3(image.sample(points,v.uv).rgb);
      float3 l = float3(image.sample(points,v.uv-float2(step.x,0)).rgb);
      float3 r = float3(image.sample(points,v.uv+float2(step.x,0)).rgb);
      float3 u = float3(image.sample(points,v.uv-float2(0,step.y)).rgb);
      float3 d = float3(image.sample(points,v.uv+float2(0,step.y)).rgb);
      float3 lo = min(c,min(min(l,r),min(u,d)));
      float3 hi = max(c,max(max(l,r),max(u,d)));
      float3 sharpened = clamp(c + 0.15f * (4.0f*c-l-r-u-d),lo,hi);
      return half4(half3(clamp(sharpened,0.0f,1.0f)),1);
    }
    """

  private func prepare() throws {
    guard pipeline == nil else { return }
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "plane")
    desc.fragmentFunction = library.makeFunction(name: "opaque")
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm
    let prepared = try device.makeRenderPipelineState(descriptor: desc)
    guard let queue = device.makeCommandQueue() else { throw Failure.unavailable }
    pipeline = prepared
    commands = queue
  }

  /// Optional compilation never blocks display delivery or makes the baseline
  /// pipeline depend on the availability of the sharpening pipeline.
  private func prepareSharpening() {
    guard !sharpeningPreparationStarted else { return }
    sharpeningPreparationStarted = true
    #if DEBUG
      let beforeInstall = beforeSharpeningInstallForValidation
    #endif
    compiler.async { [self] in
      let prepared: PreparedPipeline?
      do {
        let library = try device.makeLibrary(source: Self.sharpeningShader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "plane")
        descriptor.fragmentFunction = library.makeFunction(name: "lightSharp")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        prepared = PreparedPipeline(try device.makeRenderPipelineState(descriptor: descriptor))
      } catch {
        NSLog("macOpenVM optional sharpening unavailable: %@", String(describing: error))
        prepared = nil
      }
      #if DEBUG
        beforeInstall?()
      #endif
      render.async { [self] in
        guard !closed else { return }
        // A sample may have started while this optional pipeline compiled.
        // Never combine opaque fallback and sharpening in one timing result.
        if sharpeningEnabled, prepared != nil { timingCapture?.cancel() }
        sharpeningPipeline = prepared?.value
        guard sharpeningEnabled, prepared != nil else { return }
        resetDrawableRetry()
        presentationWanted = cache != nil
        requestDrawable()
      }
    }
  }

  private final class PreparedPipeline: @unchecked Sendable {
    let value: any MTLRenderPipelineState
    init(_ value: any MTLRenderPipelineState) { self.value = value }
  }
  private func encodeSharedCopy(_ frame: SharedFrame, command: any MTLCommandBuffer) throws {
    let source = try importTexture(frame)
    if cache?.width != frame.size.width || cache?.height != frame.size.height {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: frame.size.width, height: frame.size.height, mipmapped: false)
      desc.storageMode = .private
      desc.usage = [.shaderRead]
      cache = device.makeTexture(descriptor: desc)
    }
    guard let cache, let blit = command.makeBlitCommandEncoder() else { throw Failure.unavailable }
    blit.copy(
      from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
      sourceSize: MTLSize(width: frame.size.width, height: frame.size.height, depth: 1),
      to: cache, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
    blit.endEncoding()
  }
  private func encodePlane(
    _ command: any MTLCommandBuffer, texture: any MTLTexture,
    viewport: CGRect
  ) throws {
    guard let cache, let pipeline else { throw Failure.unavailable }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw Failure.gpu
    }
    let enlarged = viewport.width > CGFloat(cache.width) && viewport.height > CGFloat(cache.height)
    encoder.setRenderPipelineState(
      sharpeningEnabled && enlarged ? (sharpeningPipeline ?? pipeline) : pipeline)
    encoder.setViewport(
      MTLViewport(
        originX: viewport.minX, originY: viewport.minY,
        width: viewport.width, height: viewport.height, znear: 0, zfar: 1))
    encoder.setFragmentTexture(cache, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }

  #if DEBUG
    /// Only generated64x64 bytes; no live input, window or drawable is captured.
    func configureDrawableRetryValidation(
      acquire: @escaping @Sendable () -> Bool,
      schedule: (@Sendable (Int, @escaping @Sendable () -> Void) -> Void)? = nil,
      drawableSize: (@Sendable () -> CGSize)? = nil,
      beforeSharpeningInstall: (@Sendable () -> Void)? = nil
    ) async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        render.async { [self] in
          do {
            guard !closed else { throw Failure.closed }
            try prepare()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
              pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let source = device.makeTexture(descriptor: descriptor) else {
              throw Failure.unavailable
            }
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            for pixel in 0..<(64 * 64) {
              pixels[pixel * 4 + 2] = 255
              pixels[pixel * 4 + 3] = 255
            }
            pixels.withUnsafeBytes { bytes in
              source.replace(
                region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: 64 * 4)
            }
            cache = source
            stamp = RfbQualificationPresentation(
              epoch: UUID(), sequence: 1, width: 64, height: 64,
              attached: true, visible: true, drawn: true)
            viewport = CGRect(x: 0, y: 0, width: 64, height: 64)
            acquireForValidation = acquire
            drawableSizeForValidation = drawableSize
            beforeSharpeningInstallForValidation = beforeSharpeningInstall
            scheduleForValidation = schedule
            continuation.resume()
          } catch { continuation.resume(throwing: error) }
        }
      }
    }

    struct DrawableRetryValidationState: Sendable {
      let requests: Int
      let draws: Int
      let copies: Int
      let scheduled: Bool
      let wanted: Bool
      let pending: Bool
      let active: Bool
      let closed: Bool
    }

    func drawableRetryStateForValidation() async -> DrawableRetryValidationState {
      await withCheckedContinuation { continuation in
        render.async { [self] in
          continuation.resume(
            returning: DrawableRetryValidationState(
              requests: drawableRequests, draws: completedDraws, copies: completedCopies,
              scheduled: drawableRetryTicket != nil, wanted: presentationWanted,
              pending: drawablePending, active: presentationActive, closed: closed))
        }
      }
    }

    func generatedDrawableBytesForValidation() async -> Data? {
      await withCheckedContinuation { continuation in
        render.async { [self] in
          guard completedDraws > 0, let outputForValidation else {
            continuation.resume(returning: nil)
            return
          }
          let width = outputForValidation.width
          let height = outputForValidation.height
          var bytes = Data(count: width * height * 4)
          bytes.withUnsafeMutableBytes { raw in
            outputForValidation.getBytes(
              raw.baseAddress!, bytesPerRow: width * 4,
              from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
          }
          continuation.resume(returning: bytes)
        }
      }
    }

    /// Generated fixture qualification uses the actual import, cache, and shader.
    /// Offscreen output is returned in memory; this has no live capture entry point.
    func renderGeneratedValidation(_ frame: SharedFrame, updateCache: Bool = true) async throws
      -> Data
    {
      try await withCheckedThrowingContinuation { continuation in
        render.async { [self] in
          do {
            guard !closed else { throw Failure.closed }
            try prepare()
            let desc = MTLTextureDescriptor.texture2DDescriptor(
              pixelFormat: .bgra8Unorm,
              width: frame.size.width, height: frame.size.height, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = [.renderTarget]
            guard let commands, let command = commands.makeCommandBuffer(),
              let output = device.makeTexture(descriptor: desc)
            else { throw Failure.unavailable }
            if updateCache { try encodeSharedCopy(frame, command: command) }
            try encodePlane(
              command, texture: output,
              viewport: CGRect(
                x: 0, y: 0,
                width: frame.size.width, height: frame.size.height))
            let completedOutput = CompletedOutput(texture: output)
            command.addCompletedHandler { [mapping = frame.mapping] value in
              _ = mapping
              guard value.status == .completed else {
                continuation.resume(throwing: Failure.gpu)
                return
              }
              var data = Data(count: frame.size.width * frame.size.height * 4)
              data.withUnsafeMutableBytes { bytes in
                if let pointer = bytes.baseAddress {
                  completedOutput.texture.getBytes(
                    pointer, bytesPerRow: frame.size.width * 4,
                    from: MTLRegionMake2D(0, 0, frame.size.width, frame.size.height), mipmapLevel: 0
                  )
                }
              }
              continuation.resume(returning: data)
            }
            command.commit()
          } catch { continuation.resume(throwing: error) }
        }
      }
    }
    // Only the completion handler reads this owned texture after actual completion.
    private struct CompletedOutput: @unchecked Sendable { let texture: any MTLTexture }

    func drawableRequestsForValidation() async -> Int {
      await withCheckedContinuation { continuation in
        render.async { [self] in continuation.resume(returning: drawableRequests) }
      }
    }
  #endif
  private final class Pending: @unchecked Sendable {
    private var continuation: CheckedContinuation<Completion, Error>?
    init(_ continuation: CheckedContinuation<Completion, Error>) {
      self.continuation = continuation
    }
    func finish(_ result: Result<Completion, Error>) {
      let current = continuation
      continuation = nil
      current?.resume(with: result)
    }
  }
}
