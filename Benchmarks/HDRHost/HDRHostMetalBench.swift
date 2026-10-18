// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import Foundation
import Metal
import Qemu
import QuartzCore

/// Root-owned standalone native fixture. One generated socket is the ONLY
/// input. No VM, live desktop pixels, activation, pointer or network operations.
@main struct HDRHostMetalBench {
  @MainActor static func main() async throws {
    let expectRejection =
      CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--expect-rejection"
    guard CommandLine.arguments.count == 2 || expectRejection,
      let device = MTLCreateSystemDefaultDevice()
    else {
      throw BenchFailure.invalid
    }
    let socket = URL(fileURLWithPath: CommandLine.arguments[1])
    var parent = stat()
    var child = stat()
    guard lstat(socket.deletingLastPathComponent().path, &parent) == 0,
      lstat(socket.path, &child) == 0
    else {
      throw BenchFailure.invalid
    }
    let identity = RFBEndpointIdentity(
      parentDevice: parent.st_dev, parentInode: parent.st_ino,
      socketDevice: child.st_dev, socketInode: child.st_ino)
    let client = HDRFrameClient(
      socketURL: socket, expectedIdentity: identity,
      inputConnectionEpoch: UUID(), capabilities: try HDRFrameConsumerCapabilities(device: device))
    do {
      try await client.connect()
      guard !expectRejection else { throw BenchFailure.invalid }
      let frame = try await client.nextFrame()
      guard frame.message.descriptor.width == 31, frame.message.descriptor.height == 3 else {
        throw BenchFailure.invalid
      }
      let renderer = try HDRFrameMetalRenderer(device: device, first: frame.message)
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 31, height: 3), styleMask: .borderless,
        backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      let surface = GeneratedHDRSurface(renderer)
      window.contentView = surface
      guard surface.layer === renderer.metalLayer, renderer.metalLayer.pixelFormat == .rgba16Float,
        renderer.metalLayer.wantsExtendedDynamicRangeContent,
        renderer.metalLayer.edrMetadata != nil,
        let color = renderer.metalLayer.colorspace, let name = color.name,
        CFEqual(name, CGColorSpace.extendedLinearSRGB)
      else { throw BenchFailure.invalid }
      let output = try await renderer.renderGeneratedOffscreen(frame)
      try validate(output, latest: false)
      let second = try await client.nextFrame()
      guard second.message.sequence == 2, second.message.contentGeneration == 2 else {
        throw BenchFailure.invalid
      }
      let nextOutput = try await renderer.renderGeneratedOffscreen(second)
      try validate(nextOutput, latest: true)
      guard output != nextOutput else { throw BenchFailure.invalid }
      // Expected exact half bits, including negative and >1 RGB. Opaque alpha
      // legitimately replaces generated source alpha=-0 with1. No SDR gain.
      renderer.close()
      window.contentView = nil
      await client.close()
      print(
        "PASS real FD -> readonly Metal import -> private FP16 cache -> FP16 shader output; negative/above-one RGB exact; EDR layer attached with absolute80 profile"
      )
      print(
        "Generated fixture only: no Windows HDR, physical luminance, monitor capability or FPS claim"
      )
    } catch {
      await client.close()
      if expectRejection, (error as? RFBClientError) == .unsafeSocket {
        print("PASS duplicate backing slots rejected before ATTACH ACK/import/copy")
        return
      }
      throw error
    }
  }
  private static func validate(_ output: Data, latest: Bool) throws {
    guard output.count == 31 * 3 * 8 else { throw BenchFailure.invalid }
    for y in 0..<3 {
      for x in 0..<31 {
        let expected: [UInt16] = [
          UInt16(latest ? 0x3400 + x * 11 : 0xb800 + x * 17),
          UInt16(latest ? 0x3d00 + y * 0x80 : 0x4100 + y * 0x80),
          UInt16(latest ? 0x4400 + x * 5 + y * 0x40 : 0x4a40 + x * 3 + y * 0x20), 0x3c00,
        ]
        for channel in 0..<4 {
          let i = (y * 31 + x) * 8 + channel * 2
          let half = UInt16(output[i]) | (UInt16(output[i + 1]) << 8)
          guard half == expected[channel] else {
            throw BenchFailure.pixel(y * 31 + x, channel, half)
          }
        }
      }
    }
  }
  enum BenchFailure: Error {
    case invalid
    case pixel(Int, Int, UInt16)
  }
  @MainActor final class GeneratedHDRSurface: NSView {
    let renderer: HDRFrameMetalRenderer
    init(_ renderer: HDRFrameMetalRenderer) {
      self.renderer = renderer
      super.init(frame: NSRect(x: 0, y: 0, width: 31, height: 3))
      wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer { renderer.metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
  }
}
