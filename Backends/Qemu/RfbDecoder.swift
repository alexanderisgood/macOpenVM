import BackendAPI
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Original fixed-scope parser from RFC6143 sections7.1/7.3/7.5/7.6/7.8.
/// Raw B,G,R,X wire pixels normalize to opaque R,G,B,255. No guest text is logged.
package struct RfbDecoder {
  static let maximumPixels = 16_777_216
  static let maximumBytes = 67_108_864
  // RFC6143's UInt16 count bounds header work independently from pixel payload.
  // QEMU can emit more than256 nonmerging dirty runs in one ordinary update.
  static let maximumRectangleHeaderBytes = Int(UInt16.max) * 12
  package enum Action {
    case send(Data)
    case ready, messageStarted, messageComplete, updateStarted
    case updateComplete(resized: Bool)
  }
  private struct Rect {
    let x: Int, y: Int, width: Int, height: Int
  }
  private enum Stage {
    case version, securityCount
    case securityTypes(Int)
    case securityResult, serverHeader
    case serverName(Int)
    case messageType, updateHeader, rectangle
    case raw(Rect, Int)
    case desktopSizeReply(Rect)
    case clipboardHeader
    case clipboard(Int)
  }
  private var stage: Stage = .version
  private var buffer = Data()
  private var cursor = 0
  private var canvas: [UInt8] = []
  private var coverage: [UInt8] = []
  private var coveredPixels = 0
  private var rectanglesRemaining = 0
  private var rawUpdateAnnounced = false
  // Pixel payload<=64MiB; at most786420 header bytes plus the4-byte update
  // prefix. Headers stream without a rectangle list or a second canvas.
  private var pixelBytes = 0
  private let pixelPayloadLimit: Int
  private var resized = false
  private var desktopSizeReplyExpected = false
  package private(set) var width = 0
  package private(set) var height = 0
  package private(set) var ready = false
  package private(set) var relativePointer: Bool?
  package private(set) var messageInProgress = true
  package var initialized: Bool { coveredPixels == width * height && width > 0 }
  package var pixels: Data { Data(canvas) }

  package init(pixelPayloadLimit: Int = Self.maximumBytes) {
    // Only tighter budgets are injectable for independent parser boundary tests.
    self.pixelPayloadLimit = min(Self.maximumBytes, max(0, pixelPayloadLimit))
  }

  /// One bounded single-screen SetDesktopSize request. A forwarded reply is
  /// acknowledgement only; actual dimensions change through DesktopSize frames.
  package mutating func desktopSizeRequest(_ size: PixelSize) throws -> Data {
    guard ready, !desktopSizeReplyExpected, size.width > 0, size.height > 0,
      size.width <= 8192, size.height <= 8192,
      size.width * size.height <= Self.maximumPixels
    else { throw RFBClientError.invalidPointer }
    desktopSizeReplyExpected = true
    let w = UInt16(size.width)
    let h = UInt16(size.height)
    // RFB SetDesktopSize is client message 251 (QEMU ui/vnc.h and the
    // published extension); 254 is unknown and closes the connection.
    return Data([
      251, 0, UInt8(w >> 8), UInt8(truncatingIfNeeded: w),
      UInt8(h >> 8), UInt8(truncatingIfNeeded: h), 1, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
      UInt8(w >> 8), UInt8(truncatingIfNeeded: w),
      UInt8(h >> 8), UInt8(truncatingIfNeeded: h), 0, 0, 0, 0,
    ])
  }

  package mutating func feed(_ bytes: Data) throws -> [Action] {
    guard bytes.count <= 65_536, buffer.count - cursor <= 65_536 else {
      throw RFBClientError.limitExceeded
    }
    var actions: [Action] = []
    if buffer.count == cursor, case .raw(let rect, let offset) = stage, bytes.count >= 4 {
      // A body chunk with no buffered prefix can be borrowed directly. Retain
      // only its incomplete pixel or following headers, never the whole chunk.
      // Header validation and the same complete-pixel/rectangle bounds still
      // precede every write into the owned canvas.
      let total = rect.width * rect.height
      let count = min(bytes.count / 4, total - offset)
      Self.applyRaw(
        bytes, start: 0, count: count, rect: rect, offset: offset, stride: width,
        canvas: &canvas, coverage: &coverage, coveredPixels: &coveredPixels,
        trackCoverage: !initialized)
      buffer = Data(bytes.dropFirst(count * 4))
      cursor = 0
      if offset + count == total {
        rectanglesRemaining -= 1
        if rectanglesRemaining == 0 {
          // Preserve the transport's boundary: its waiter consumes this
          // completion before any following update is parsed.
          finishUpdate(&actions)
          return actions
        }
        stage = .rectangle
      } else {
        stage = .raw(rect, offset + count)
      }
    } else {
      if cursor > 0 {
        buffer = Data(buffer.dropFirst(cursor))
        cursor = 0
      }
      buffer.append(bytes)
    }
    while true {
      let available = buffer.count - cursor
      switch stage {
      case .version:
        guard available >= 12 else { return actions }
        guard take(12) == Data("RFB 003.008\n".utf8) else {
          throw RFBClientError.unsupportedMessage
        }
        actions.append(.send(Data("RFB 003.008\n".utf8)))
        stage = .securityCount
      case .securityCount:
        guard available >= 1 else { return actions }
        let count = Int(take(1)[0])
        guard count > 0, count <= 16 else { throw RFBClientError.limitExceeded }
        stage = .securityTypes(count)
      case .securityTypes(let count):
        guard available >= count else { return actions }
        guard take(count).contains(1) else { throw RFBClientError.unsupportedMessage }
        actions.append(.send(Data([1])))
        stage = .securityResult
      case .securityResult:
        guard available >= 4 else { return actions }
        guard integer(take(4), at: 0, count: 4) == 0 else {
          throw RFBClientError.unsupportedMessage
        }
        actions.append(.send(Data([1])))  // shared ClientInit
        stage = .serverHeader
      case .serverHeader:
        guard available >= 24 else { return actions }
        let header = take(24)
        let nameLength = integer(header, at: 20, count: 4)
        guard nameLength <= 4096 else { throw RFBClientError.limitExceeded }
        // Validate the declared native format before replacing it with ours.
        guard [8, 16, 32].contains(Int(header[4])), header[5] > 0, header[5] <= header[4],
          header[6] <= 1, header[7] <= 1, header[17...19].allSatisfy({ $0 == 0 })
        else { throw RFBClientError.malformedMessage }
        if header[7] == 1 {
          var mask: UInt64 = 0
          for (maximumOffset, shiftOffset) in [(8, 14), (10, 15), (12, 16)] {
            let maximum = integer(header, at: maximumOffset, count: 2)
            let shift = Int(header[shiftOffset])
            guard maximum > 0, maximum & (maximum + 1) == 0, shift < Int(header[4]) else {
              throw RFBClientError.malformedMessage
            }
            let component = UInt64(maximum) << shift
            guard component < (UInt64(1) << Int(header[4])), mask & component == 0 else {
              throw RFBClientError.malformedMessage
            }
            mask |= component
          }
        }
        try allocate(
          width: integer(header, at: 0, count: 2), height: integer(header, at: 2, count: 2))
        stage = .serverName(nameLength)
      case .serverName(let count):
        guard available >= count else { return actions }
        guard String(data: take(count), encoding: .utf8) != nil else {
          throw RFBClientError.malformedMessage
        }
        // SetPixelFormat:32bpp/depth24/little/true-color, maxima255/shifts16,8,0.
        actions.append(
          .send(Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])))
        // Raw, DesktopSize and the public QEMU Pointer Motion Change extension.
        actions.append(
          .send(Data([2, 0, 0, 3, 0, 0, 0, 0, 255, 255, 255, 33, 255, 255, 254, 255])))
        ready = true
        messageInProgress = false
        stage = .messageType
        actions.append(.ready)
        return actions
      case .messageType:
        guard available >= 1 else { return actions }
        messageInProgress = true
        switch take(1)[0] {
        case 0: stage = .updateHeader
        case 2:
          messageInProgress = false  // bounded one-byte Bell
          actions.append(.messageComplete)
          return actions
        case 3: stage = .clipboardHeader
        default: throw RFBClientError.unsupportedMessage
        }
        actions.append(.messageStarted)
        return actions
      case .updateHeader:
        guard available >= 3 else { return actions }
        let header = take(3)
        guard header[0] == 0 else { throw RFBClientError.malformedMessage }
        rectanglesRemaining = integer(header, at: 1, count: 2)
        guard rectanglesRemaining <= Self.maximumRectangleHeaderBytes / 12 else {
          throw RFBClientError.limitExceeded
        }
        pixelBytes = 0
        resized = false
        rawUpdateAnnounced = false
        if rectanglesRemaining == 0 {
          finishUpdate(&actions)
          return actions
        } else {
          stage = .rectangle
        }
      case .rectangle:
        guard available >= 12 else { return actions }
        let header = take(12)
        let rect = Rect(
          x: integer(header, at: 0, count: 2), y: integer(header, at: 2, count: 2),
          width: integer(header, at: 4, count: 2), height: integer(header, at: 6, count: 2))
        let encoding = Int32(bitPattern: UInt32(integer(header, at: 8, count: 4)))
        if encoding == -257 {
          guard rectanglesRemaining == 1, (0...1).contains(rect.x), rect.y == 0,
            rect.width == width, rect.height == height
          else { throw RFBClientError.malformedMessage }
          relativePointer = rect.x == 0
          rectanglesRemaining = 0
          stage = .messageType
          messageInProgress = false
          // This unsolicited control update does not consume a pixel request,
          // advance frame sequence, or manufacture a display frame.
          actions.append(.messageComplete)
          return actions
        } else if encoding == -308 {
          guard desktopSizeReplyExpected, rectanglesRemaining == 1,
            rect.x == 1, (0...4).contains(rect.y),
            rect.width == width, rect.height == height
          else { throw RFBClientError.malformedMessage }
          stage = .desktopSizeReply(rect)
        } else if encoding == -223 {
          guard rectanglesRemaining == 1 else { throw RFBClientError.malformedMessage }
          try allocate(width: rect.width, height: rect.height)
          resized = true
          rectanglesRemaining = 0
          finishUpdate(&actions)
          return actions
        } else {
          guard encoding == 0 else { throw RFBClientError.unsupportedMessage }
          guard rect.width > 0, rect.height > 0, rect.x <= width - rect.width,
            rect.y <= height - rect.height
          else { throw RFBClientError.malformedMessage }
          let count = rect.width * rect.height * 4
          guard count <= pixelPayloadLimit - pixelBytes else {
            throw RFBClientError.limitExceeded
          }
          pixelBytes += count
          stage = .raw(rect, 0)
          if !rawUpdateAnnounced {
            // Only a validated pixel rectangle starts early prefetch. A
            // resize acknowledgement must not be mistaken for the response
            // to a queued pixel request (RFB permits request coalescing).
            rawUpdateAnnounced = true
            actions.append(.updateStarted)
          }
        }
      case .desktopSizeReply(let rect):
        guard available >= 20 else { return actions }
        let payload = take(20)
        guard payload.prefix(12) == Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
          integer(payload, at: 12, count: 2) == rect.width,
          integer(payload, at: 14, count: 2) == rect.height,
          payload.suffix(4).allSatisfy({ $0 == 0 })
        else { throw RFBClientError.malformedMessage }
        desktopSizeReplyExpected = false
        rectanglesRemaining = 0
        // This response does not satisfy an outstanding pixel request and may
        // arrive before its caller starts waiting for a frame.
        stage = .messageType
        messageInProgress = false
        actions.append(.messageComplete)
        return actions
      case .raw(let rect, let offset):
        let total = rect.width * rect.height
        let count = min(available / 4, total - offset)
        guard count > 0 else { return actions }
        let trackCoverage = !initialized
        Self.applyRaw(
          buffer, start: cursor, count: count, rect: rect, offset: offset, stride: width,
          canvas: &canvas, coverage: &coverage, coveredPixels: &coveredPixels,
          trackCoverage: trackCoverage)
        cursor += count * 4
        if offset + count == total {
          rectanglesRemaining -= 1
          if rectanglesRemaining == 0 {
            finishUpdate(&actions)
            return actions
          } else {
            stage = .rectangle
          }
        } else {
          stage = .raw(rect, offset + count)
        }
      case .clipboardHeader:
        guard available >= 7 else { return actions }
        let header = take(7)
        guard header.prefix(3).allSatisfy({ $0 == 0 }) else {
          throw RFBClientError.malformedMessage
        }
        let count = integer(header, at: 3, count: 4)
        guard count <= 4096 else { throw RFBClientError.limitExceeded }
        stage = .clipboard(count)
      case .clipboard(let count):
        guard available >= count else { return actions }
        _ = take(count)  // clipboard disabled; never touches the host pasteboard
        stage = .messageType
        messageInProgress = false
        actions.append(.messageComplete)
        return actions
      }
    }
  }

  /// Synchronous receive-buffer borrow. Only an already validated Raw body
  /// bypasses materialization; incomplete pixels and following messages are
  /// copied before return, so the caller may immediately overwrite its buffer.
  package mutating func feedBorrowed(_ bytes: UnsafeRawBufferPointer) throws -> [Action] {
    guard bytes.count <= 65_536, buffer.count - cursor <= 65_536 else {
      throw RFBClientError.limitExceeded
    }
    guard !bytes.isEmpty, let base = bytes.baseAddress else { return try feed(Data()) }
    guard buffer.count == cursor, case .raw(let rect, let offset) = stage,
      bytes.count >= 4
    else {
      return try feed(Data(bytes: base, count: bytes.count))
    }
    let total = rect.width * rect.height
    let count = min(bytes.count / 4, total - offset)
    Self.applyRaw(
      bytes, start: 0, count: count, rect: rect, offset: offset, stride: width,
      canvas: &canvas, coverage: &coverage, coveredPixels: &coveredPixels,
      trackCoverage: !initialized)
    let consumed = count * 4
    // Data(bytes:count:) owns its copy. A Data slice/no-copy wrapper here could
    // retain the caller's reusable receive allocation across the next recv.
    buffer = Data(bytes: base.advanced(by: consumed), count: bytes.count - consumed)
    cursor = 0
    if offset + count == total {
      rectanglesRemaining -= 1
      if rectanglesRemaining == 0 {
        var actions: [Action] = []
        finishUpdate(&actions)
        return actions
      }
      stage = .rectangle
    } else {
      stage = .raw(rect, offset + count)
    }
    return try feed(Data())
  }

  private mutating func finishUpdate(_ actions: inout [Action]) {
    stage = .messageType
    messageInProgress = false
    actions.append(.updateComplete(resized: resized))
  }

  private static func applyRaw(
    _ bytes: Data, start: Int, count: Int, rect: Rect, offset: Int, stride: Int,
    canvas: inout [UInt8], coverage: inout [UInt8], coveredPixels: inout Int,
    trackCoverage: Bool
  ) {
    // The Raw stage already bounds count by complete available pixels and the
    // validated rectangle extent. Borrows never escape or mutate source bytes.
    bytes.withUnsafeBytes { source in
      applyRaw(
        source, start: start, count: count, rect: rect, offset: offset, stride: stride,
        canvas: &canvas, coverage: &coverage, coveredPixels: &coveredPixels,
        trackCoverage: trackCoverage)
    }
  }

  private static func applyRaw(
    _ source: UnsafeRawBufferPointer, start: Int, count: Int, rect: Rect, offset: Int, stride: Int,
    canvas: inout [UInt8], coverage: inout [UInt8], coveredPixels: inout Int,
    trackCoverage: Bool
  ) {
    canvas.withUnsafeMutableBufferPointer { destination in
      var sourceIndex = start
      var row = rect.y + offset / rect.width
      var column = offset % rect.width
      var remaining = count
      while remaining > 0 {
        let length = min(remaining, rect.width - column)
        let firstPixel = row * stride + rect.x + column
        var destinationIndex = firstPixel * 4
        var pixelsLeft = length
        // macOS hosts are little-endian. Load four wire pixels without an
        // alignment assumption; swap R/B together and force opaque alpha.
        // copyMemory also permits an unaligned byte-array destination.
        while pixelsLeft >= 4 {
          let wire = source.loadUnaligned(fromByteOffset: sourceIndex, as: SIMD4<UInt32>.self)
          let byteMask = SIMD4<UInt32>(repeating: 0x0000_00ff)
          let shift = SIMD4<UInt32>(repeating: 16)
          let blue = (wire & byteMask) &<< shift
          let green = wire & SIMD4<UInt32>(repeating: 0x0000_ff00)
          let red = (wire &>> shift) & byteMask
          var rgba = blue | green | red | SIMD4<UInt32>(repeating: 0xff00_0000)
          withUnsafeBytes(of: &rgba) { converted in
            UnsafeMutableRawBufferPointer(
              rebasing: UnsafeMutableRawBufferPointer(destination)[
                destinationIndex..<destinationIndex + 16]
            ).copyMemory(from: converted)
          }
          sourceIndex += 16
          destinationIndex += 16
          pixelsLeft -= 4
        }
        for _ in 0..<pixelsLeft {
          destination[destinationIndex] = source[sourceIndex + 2]
          destination[destinationIndex + 1] = source[sourceIndex + 1]
          destination[destinationIndex + 2] = source[sourceIndex]
          destination[destinationIndex + 3] = 255
          sourceIndex += 4
          destinationIndex += 4
        }
        if trackCoverage {
          for pixel in firstPixel..<firstPixel + length {
            let mask = UInt8(1 << (pixel & 7))
            if coverage[pixel >> 3] & mask == 0 {
              coverage[pixel >> 3] |= mask
              coveredPixels += 1
            }
          }
        }
        remaining -= length
        row += 1
        column = 0
      }
    }
  }

  private mutating func allocate(width: Int, height: Int) throws {
    guard (1...8192).contains(width), (1...8192).contains(height),
      width * height <= Self.maximumPixels
    else { throw RFBClientError.limitExceeded }
    self.width = width
    self.height = height
    canvas = [UInt8](repeating: 0, count: width * height * 4)
    coverage = [UInt8](repeating: 0, count: (width * height + 7) / 8)
    coveredPixels = 0
  }

  private mutating func take(_ count: Int) -> Data {
    let value = Data(buffer[cursor..<cursor + count])
    cursor += count
    return value
  }

  private func integer(_ bytes: Data, at offset: Int, count: Int) -> Int {
    bytes[offset..<offset + count].reduce(0) { ($0 << 8) | Int($1) }
  }
}
