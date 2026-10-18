// SPDX-License-Identifier: Apache-2.0
import AppKit
import Metal
import Qemu
import QuartzCore

/// One negotiated HDR pool/profile per renderer and layer. Replacing the pool
/// requires a new instance; old drawables can never inherit new color meaning.
/// The independent SDR renderer/layer remains the fallback owner.
final class HDRFrameMetalRenderer: @unchecked Sendable {
  enum Failure: Error { case unavailable, closed, geometry, incompatible, gpu }
  let metalLayer = CAMetalLayer()
  private let device: any MTLDevice
  private let commands: any MTLCommandQueue
  private let profile: HDRMetalPresentationProfile
  private let render = DispatchQueue(label: "local.macOpenVM.hdr-render", qos: .userInteractive)
  private let acquire = DispatchQueue(label: "local.macOpenVM.hdr-drawable", qos: .userInteractive)
  private var pipeline: (any MTLRenderPipelineState)?
  private var cache: (any MTLTexture)?
  private var closed = false
  private var active = false
  private var pending = false
  private var wanted = false
  private var size = CGSize.zero
  private var viewport = CGRect.zero
  private var stamp: HDRFrameMessage?
  private var retryTimer: (any DispatchSourceTimer)?
  private var retryTicket: UUID?
  private var retryBudget = HDRDrawableRetryBudget()
  private var callbackGate: HDRPresentationCallbackGate
  private let onPresented: @Sendable (HDRFrameMessage, Double) -> Void
  private let onFailure: @Sendable (Failure) -> Void

  @MainActor init(
    device: any MTLDevice, first: HDRFrameMessage,
    callbackOwner: HDRPresentationCallbackGate.Owner = .init(),
    onPresented: @escaping @Sendable (HDRFrameMessage, Double) -> Void = { _, _ in },
    onFailure: @escaping @Sendable (Failure) -> Void = { _ in }
  ) throws {
    guard device.hasUnifiedMemory, let commands = device.makeCommandQueue() else {
      throw Failure.unavailable
    }
    let profile = HDRMetalPresentationProfile(message: first)
    let config = try profile.makeLayerConfiguration()
    self.device = device
    self.commands = commands
    self.profile = profile
    callbackGate = HDRPresentationCallbackGate(first: first, owner: callbackOwner)
    self.onPresented = onPresented
    self.onFailure = onFailure
    metalLayer.device = device
    metalLayer.pixelFormat = config.pixelFormat
    metalLayer.colorspace = config.colorSpace
    metalLayer.edrMetadata = config.edrMetadata
    metalLayer.wantsExtendedDynamicRangeContent = config.wantsExtendedDynamicRangeContent
    metalLayer.isOpaque = config.isOpaque
    metalLayer.framebufferOnly = true
    metalLayer.maximumDrawableCount = 3
    metalLayer.displaySyncEnabled = true
    metalLayer.allowsNextDrawableTimeout = true
    metalLayer.presentsWithTransaction = false
  }

  @MainActor func present(
    _ frame: HDRSharedFrame, drawableSize: CGSize, viewport: CGRect, contentsScale: CGFloat
  ) async throws
    -> HDRFrameCopyTiming
  {
    try configureLayer(drawableSize: drawableSize, contentsScale: contentsScale)
    let target: Resource = try await withCheckedThrowingContinuation { continuation in
      render.async { [self] in
        do {
          try prepare(frame.message)
          try geometry(drawableSize, viewport)
          let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: frame.message.descriptor.width, height: frame.message.descriptor.height,
            mipmapped: false)
          desc.storageMode = .private
          desc.usage = .shaderRead
          guard let next = device.makeTexture(descriptor: desc) else { throw Failure.unavailable }
          try profile.validateTextureFormats(
            source: .rgba16Float, cache: next.pixelFormat, output: .rgba16Float)
          size = drawableSize
          self.viewport = viewport
          continuation.resume(returning: Resource(next))
        } catch { continuation.resume(throwing: error) }
      }
    }
    // This method itself encodes the actual readonly mapping->private-cache
    // blit and emits ACK only after the successful real GPU completion.
    let timing = try await frame.copyToPrivateCache(target.value, commands: commands)
    render.async { [self] in
      guard !closed, profile.matches(frame.message) else { return }
      // Cache and message become visible atomically after the real copy.
      // The in-flight next frame never overwrites this immutable cache.
      cache = target.value
      stamp = frame.message
      wanted = true
      _ = retryBudget.apply(.content)
      requestDrawable()
    }
    return timing
  }
  @MainActor func redraw(drawableSize: CGSize, viewport: CGRect, contentsScale: CGFloat) throws {
    try configureLayer(drawableSize: drawableSize, contentsScale: contentsScale)
    render.async { [self] in
      guard !closed, (try? geometry(drawableSize, viewport)) != nil else { return }
      size = drawableSize
      self.viewport = viewport
      wanted = cache != nil
      _ = retryBudget.apply(.redraw)
      requestDrawable()
    }
  }
  @MainActor private func configureLayer(drawableSize: CGSize, contentsScale: CGFloat) throws {
    guard contentsScale.isFinite, contentsScale > 0, contentsScale <= 16 else {
      throw Failure.geometry
    }
    try geometry(drawableSize, CGRect(origin: .zero, size: drawableSize))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    metalLayer.contentsScale = contentsScale
    metalLayer.drawableSize = drawableSize
    CATransaction.commit()
  }
  func setPresentationActive(_ active: Bool) {
    render.async { [self] in
      guard !closed, self.active != active else { return }
      self.active = active
      callbackGate.setActive(active)
      _ = retryBudget.apply(.activation(active))
      cancelRetry()
      if active {
        wanted = cache != nil
        requestDrawable()
      }
    }
  }
  func close() {
    render.async { [self] in
      closed = true
      active = false
      wanted = false
      stamp = nil
      cache = nil
      callbackGate.retire()
      _ = retryBudget.apply(.activation(false))
      cancelRetry()
      // Real submitted commands/native callbacks retain their resources.
    }
  }
  private final class Resource: @unchecked Sendable {
    // Immutable ownership across executors. Private-cache writes complete
    // before publication; generated readback targets belong to one command
    // and are read only on render after its actual completion callback.
    let value: any MTLTexture
    init(_ value: any MTLTexture) { self.value = value }
  }
  private final class Drawable: @unchecked Sendable {
    let value: any CAMetalDrawable
    init(_ value: any CAMetalDrawable) { self.value = value }
  }
  private func geometry(_ size: CGSize, _ viewport: CGRect) throws {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width <= 16384, size.height <= 16384, size.width.rounded() == size.width,
      size.height.rounded() == size.height, viewport.minX.isFinite, viewport.minY.isFinite,
      viewport.width.isFinite, viewport.height.isFinite, viewport.minX >= 0, viewport.minY >= 0,
      viewport.width > 0, viewport.height > 0, viewport.maxX <= size.width,
      viewport.maxY <= size.height
    else { throw Failure.geometry }
  }
  private func prepare(_ message: HDRFrameMessage) throws {
    guard !closed, profile.matches(message) else { throw Failure.incompatible }
    if pipeline == nil {
      let library = try device.makeLibrary(source: Self.shader, options: nil)
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = library.makeFunction(name: "hdrPlane")
      desc.fragmentFunction = library.makeFunction(name: "hdrOpaque")
      desc.colorAttachments[0].pixelFormat = .rgba16Float
      pipeline = try device.makeRenderPipelineState(descriptor: desc)
    }
  }
  private func encode(_ command: any MTLCommandBuffer, output: any MTLTexture, viewport: CGRect)
    throws
  {
    guard let cache, let pipeline, output.pixelFormat == .rgba16Float else {
      throw Failure.unavailable
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = output
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw Failure.gpu
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setViewport(
      MTLViewport(
        originX: viewport.minX, originY: viewport.minY,
        width: viewport.width, height: viewport.height, znear: 0, zfar: 1))
    encoder.setFragmentTexture(cache, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }
  private func requestDrawable() {
    guard !closed, active, wanted, !pending, cache != nil, retryTimer == nil else { return }
    pending = true
    acquire.async { [self] in
      let drawable = metalLayer.nextDrawable().map { Drawable($0) }
      render.async { [self] in
        guard !closed, active else {
          pending = false
          return
        }
        guard let drawable else {
          pending = false
          scheduleRetry()
          return
        }
        guard drawable.value.texture.width == Int(size.width),
          drawable.value.texture.height == Int(size.height),
          drawable.value.texture.pixelFormat == .rgba16Float,
          let stamp, profile.matches(stamp), let command = commands.makeCommandBuffer()
        else {
          pending = false
          scheduleRetry()
          return
        }
        do {
          try encode(command, output: drawable.value.texture, viewport: viewport)
          let drawn = stamp
          guard let callback = callbackGate.ticket(for: drawn) else { throw Failure.incompatible }
          drawable.value.addPresentedHandler { [self] value in
            let time = value.presentedTime
            guard time.isFinite, time > 0 else { return }
            render.async { [self] in
              guard !closed, active,
                callbackGate.accepts(callback, message: drawn, currentOwner: callbackGate.owner)
              else { return }
              _ = retryBudget.apply(.presented)
              cancelRetry()
              onPresented(drawn, time)
              requestDrawable()
            }
          }
          wanted = false
          command.present(drawable.value)
          command.addCompletedHandler { [self] completed in
            let succeeded = completed.status == .completed
            render.async { [self] in
              pending = false
              guard !closed else { return }
              if succeeded { requestDrawable() } else { failPresentation(.gpu) }
            }
          }
          command.commit()
        } catch {
          pending = false
          failPresentation((error as? Failure) ?? .gpu)
        }
      }
    }
  }
  private func failPresentation(_ reason: Failure) {
    guard !closed else { return }
    closed = true
    active = false
    wanted = false
    cache = nil
    stamp = nil
    callbackGate.retire()
    _ = retryBudget.apply(.activation(false))
    cancelRetry()
    // Root's controller owns SDR fallback. The already successful private-copy
    // ACK is not rolled back and no guest fence waits for screen presentation.
    onFailure(reason)
  }
  private func cancelRetry() {
    retryTimer?.cancel()
    retryTimer = nil
    retryTicket = nil
  }
  private func scheduleRetry() {
    guard !closed, active, wanted, !pending, cache != nil, retryTimer == nil else { return }
    let delay: Int
    switch retryBudget.apply(.failedAcquisition) {
    case .retry(let milliseconds): delay = milliseconds
    case .exhausted:
      failPresentation(.unavailable)
      return
    case .none: return
    }
    let ticket = UUID()
    retryTicket = ticket
    let timer = DispatchSource.makeTimerSource(queue: render)
    retryTimer = timer
    timer.schedule(deadline: .now() + .milliseconds(delay))
    timer.setEventHandler { [weak self] in
      guard let self, retryTicket == ticket else { return }
      retryTimer?.cancel()
      retryTimer = nil
      retryTicket = nil
      requestDrawable()
    }
    timer.activate()
  }

  /// Generated fixtures only: real import/copy/shader/FP16 output, without a
  /// screen drawable or luminance claim. The caller owns the finite test run.
  func renderGeneratedOffscreen(_ frame: HDRSharedFrame) async throws -> Data {
    let d = frame.message.descriptor
    let timing = try await present(
      frame, drawableSize: CGSize(width: d.width, height: d.height),
      viewport: CGRect(x: 0, y: 0, width: d.width, height: d.height), contentsScale: 1)
    _ = timing
    return try await withCheckedThrowingContinuation { continuation in
      render.async { [self] in
        do {
          guard !closed else { throw Failure.closed }
          let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: d.width, height: d.height, mipmapped: false)
          desc.storageMode = .shared
          desc.usage = .renderTarget
          guard let texture = device.makeTexture(descriptor: desc),
            let command = commands.makeCommandBuffer()
          else {
            throw Failure.unavailable
          }
          try encode(
            command, output: texture, viewport: CGRect(x: 0, y: 0, width: d.width, height: d.height)
          )
          let output = Resource(texture)
          command.addCompletedHandler { [self, output] completed in
            let succeeded = completed.status == .completed
            render.async { [self, output] in
              guard succeeded else {
                continuation.resume(throwing: Failure.gpu)
                return
              }
              guard !closed else {
                continuation.resume(throwing: Failure.closed)
                return
              }
              var data = Data(count: d.width * d.height * 8)
              data.withUnsafeMutableBytes { bytes in
                output.value.getBytes(
                  bytes.baseAddress!, bytesPerRow: d.width * 8,
                  from: MTLRegionMake2D(0, 0, d.width, d.height), mipmapLevel: 0)
              }
              continuation.resume(returning: data)
            }
          }
          command.commit()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 p [[position]]; float2 uv; };
    vertex Vertex hdrPlane(uint i [[vertex_id]]) {
      float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
      return Vertex{float4(p[i],0,1),float2((p[i].x+1)/2,(1-p[i].y)/2)};
    }
    fragment half4 hdrOpaque(Vertex v [[stage_in]], texture2d<half> image [[texture(0)]]) {
      constexpr sampler s(filter::linear,address::clamp_to_edge);
      half4 c = image.sample(s,v.uv);
      return half4(c.rgb,1.0h);
    }
    """
}
