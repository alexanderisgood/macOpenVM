import BackendAPI
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import Qemu

private func decoderGreeting(width: Int, height: Int) -> Data {
  Data("RFB 003.008\n".utf8)
    + Data([
      1, 1, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255),
      UInt8(height >> 8), UInt8(height & 255), 32, 24, 0, 1,
      0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0,
    ])
}

private func decoderDrain(_ decoder: inout RfbDecoder, _ bytes: Data) throws -> [RfbDecoder.Action]
{
  var current = try decoder.feed(bytes)
  var all = current
  while !current.isEmpty {
    current = try decoder.feed(Data())
    all.append(contentsOf: current)
  }
  return all
}

private func decoderRectangle(
  x: Int, y: Int, width: Int, height: Int, payload: [UInt8], encoding: Int32 = 0
) -> Data {
  var bytes = Data()
  for value in [x, y, width, height] {
    bytes.append(contentsOf: [UInt8(value >> 8), UInt8(value & 255)])
  }
  let value = UInt32(bitPattern: encoding)
  bytes.append(contentsOf: [
    UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255),
    UInt8(value & 255),
  ])
  bytes.append(contentsOf: payload)
  return bytes
}

@Suite("Synthetic RFB parser boundaries")
struct RfbDecoderTests {
  @Test func qemuPointerModeIsUnsolicitedControlAndNeverCompletesAPixelRequest() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 2, height: 2))
    for absolute in [1, 0, 1] {
      let actions = try decoderDrain(
        &decoder,
        Data([0, 0, 0, 1])
          + decoderRectangle(x: absolute, y: 0, width: 2, height: 2, payload: [], encoding: -257))
      #expect(decoder.relativePointer == (absolute == 0))
      #expect(!decoder.messageInProgress && !decoder.initialized)
      #expect(!actions.contains { if case .updateComplete = $0 { true } else { false } })
    }
    #expect(throws: RFBClientError.malformedMessage) {
      _ = try decoderDrain(
        &decoder,
        Data([0, 0, 0, 1])
          + decoderRectangle(x: 2, y: 0, width: 2, height: 2, payload: [], encoding: -257))
    }
  }
  @Test(arguments: [1, 3, 4, 7, 19, 65_536])
  func receiveBorrowOwnsEveryFragmentBeforeTheBufferIsOverwritten(fragmentSize: Int) throws {
    var decoder = RfbDecoder()
    let width = 17
    let height = 5
    var payload: [UInt8] = []
    var expected: [UInt8] = []
    for pixel in 0..<width * height {
      let red = UInt8(pixel & 255)
      let green = UInt8((pixel * 3) & 255)
      let blue = UInt8((pixel * 7) & 255)
      payload += [blue, green, red, 0]
      expected += [red, green, blue, 255]
    }
    let header =
      Data([0, 0, 0, 1])
      + decoderRectangle(x: 0, y: 0, width: width, height: height, payload: [])
    // An independent greeting/header stage also exercises one-byte copies.
    for message in [decoderGreeting(width: width, height: height), header, Data(payload)] {
      var offset = 0
      while offset < message.count {
        let length = min(fragmentSize, message.count - offset)
        var receive = [UInt8](message[offset..<offset + length])
        _ = try receive.withUnsafeBytes { try decoder.feedBorrowed($0) }
        _ = receive.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0xa5) }
        _ = try decoderDrain(&decoder, Data())
        offset += length
      }
    }
    #expect(decoder.initialized && !decoder.messageInProgress)
    let previous = decoder.pixels
    #expect(previous == Data(expected))
    // The final Raw receive also carries the following complete update. Its
    // header/body must survive overwrite, behind the current completion.
    _ = try decoderDrain(&decoder, header)
    var receive = payload + [UInt8](header) + payload.map { $0 ^ 0x55 }
    let actions = try receive.withUnsafeBytes { try decoder.feedBorrowed($0) }
    #expect(actions.count == 1)
    for action in actions {
      if case .updateComplete = action {} else { Issue.record("Completion boundary escaped") }
    }
    _ = receive.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0xa5) }
    _ = try decoderDrain(&decoder, Data())
    var changed = expected
    for index in changed.indices where index % 4 != 3 { changed[index] ^= 0x55 }
    #expect(decoder.pixels == Data(changed))
    #expect(previous == Data(expected))
  }

  @Test func receiveBorrowRetainsTheExistingFeedLimit() throws {
    var decoder = RfbDecoder()
    let receive = [UInt8](repeating: 0, count: 65_537)
    #expect(throws: RFBClientError.limitExceeded) {
      try receive.withUnsafeBytes { try decoder.feedBorrowed($0) }
    }
  }

  @Test func borrowedRawBodyPreservesTheFollowingUpdateAndImmutableSnapshot() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 2, height: 1))
    let header =
      Data([0, 0, 0, 1])
      + decoderRectangle(x: 0, y: 0, width: 2, height: 1, payload: [])
    _ = try decoderDrain(&decoder, header)
    let actions = try decoder.feed(
      Data([3, 2, 1, 0, 6, 5, 4, 0]) + header + Data([9, 8, 7, 0, 12, 11, 10, 0]))
    #expect(actions.count == 1)
    for action in actions {
      if case .updateComplete(let resized) = action {
        #expect(!resized)
      } else {
        Issue.record("Following update escaped the current completion boundary")
      }
    }
    let previous = decoder.pixels
    #expect(previous == Data([1, 2, 3, 255, 4, 5, 6, 255]))
    _ = try decoderDrain(&decoder, Data())
    #expect(decoder.pixels == Data([7, 8, 9, 255, 10, 11, 12, 255]))
    #expect(previous == Data([1, 2, 3, 255, 4, 5, 6, 255]))
    #expect(decoder.initialized && !decoder.messageInProgress)
  }

  @Test func borrowedRawBodyStillRejectsAnOversizedFeed() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 2, height: 1))
    _ = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1]) + decoderRectangle(x: 0, y: 0, width: 2, height: 1, payload: []))
    #expect(throws: RFBClientError.limitExceeded) {
      try decoder.feed(Data(repeating: 0, count: 65537))
    }
  }

  @Test func onlyValidatedRawPixelsAnnounceAnEarlyUpdate() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 2, height: 1))
    let empty = try decoderDrain(&decoder, Data([0, 0, 0, 0]))
    let resize = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(x: 0, y: 0, width: 2, height: 1, payload: [], encoding: -223))
    _ = try decoder.desktopSizeRequest(PixelSize(width: 2, height: 1))
    let acknowledgement = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(
          x: 1, y: 0, width: 2, height: 1,
          payload: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0],
          encoding: -308))
    for action in empty + resize + acknowledgement {
      if case .updateStarted = action { Issue.record("Non-pixel message started early prefetch") }
    }
    let header = decoderRectangle(x: 0, y: 0, width: 1, height: 1, payload: [])
    let incomplete = try decoderDrain(&decoder, Data([0, 0, 0, 2]) + header.dropLast())
    for action in incomplete {
      if case .updateStarted = action {
        Issue.record("Unvalidated rectangle started early prefetch")
      }
    }
    let first = try decoderDrain(&decoder, header.suffix(1) + Data([3]))
    let remainder = try decoderDrain(
      &decoder,
      Data([2, 1, 0])
        + decoderRectangle(x: 1, y: 0, width: 1, height: 1, payload: [6, 5, 4, 0]))
    var announcements = 0
    for action in first + remainder {
      if case .updateStarted = action { announcements += 1 }
    }
    #expect(announcements == 1)
    #expect(decoder.initialized && !decoder.messageInProgress)
    #expect(decoder.pixels == Data([1, 2, 3, 255, 4, 5, 6, 255]))
  }

  @Test(arguments: [4, 5, 7, 8, 9, 17])
  func packedConversionHandlesOddStridesFragmentsAndOpaqueAlpha(rectWidth: Int) throws {
    let width = rectWidth + 3
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: width, height: 5))
    let prefix =
      Data([0, 0, 0, 1])
      + decoderRectangle(
        x: 1, y: 1, width: rectWidth, height: 3, payload: [])
    _ = try decoderDrain(&decoder, prefix)
    var payload: [UInt8] = []
    var expected = [UInt8](repeating: 0, count: width * 5 * 4)
    for row in 0..<3 {
      for column in 0..<rectWidth {
        let blue = UInt8(column * 3 + row)
        let green = UInt8(100 + row)
        let red = UInt8(200 - column)
        payload += [blue, green, red, UInt8((row + column) & 255)]
        let offset = ((row + 1) * width + column + 1) * 4
        expected.replaceSubrange(offset..<offset + 4, with: [red, green, blue, 255])
      }
    }
    // All odd byte offsets exercise unaligned vector loads; chunks span rows
    // and force scalar tails as well as four-pixel groups.
    var offset = 0
    for limit in [1, 19, 33, 5, 17, payload.count] {
      let count = min(limit, payload.count - offset)
      let fragment = Data([0xaa]) + Data(payload[offset..<offset + count])
      _ = try decoderDrain(&decoder, fragment.dropFirst())
      offset += count
    }
    #expect(offset == payload.count && !decoder.messageInProgress)
    #expect(decoder.pixels == Data(expected))
  }

  @Test func desktopSizeForwardingDoesNotPretendTheGuestResized() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 5, height: 4))
    let request = try decoder.desktopSizeRequest(PixelSize(width: 3456, height: 2064))
    #expect(
      request
        == Data([
          251, 0, 13, 128, 8, 16, 1, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 13, 128, 8, 16, 0, 0, 0, 0,
        ]))
    #expect(throws: RFBClientError.self) {
      try decoder.desktopSizeRequest(PixelSize(width: 3456, height: 2064))
    }
    let reply =
      Data([0, 0, 0, 1])
      + decoderRectangle(
        x: 1, y: 4, width: 5, height: 4,
        payload: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 4, 0, 0, 0, 0],
        encoding: -308)
    for byte in reply { _ = try decoderDrain(&decoder, Data([byte])) }
    #expect(decoder.width == 5 && decoder.height == 4)
    #expect(!decoder.initialized)
    _ = try decoder.desktopSizeRequest(PixelSize(width: 3456, height: 2064))
  }

  @Test func unsolicitedDesktopSizeReplyAndExcessiveSizeAreRejected() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 5, height: 4))
    #expect(throws: RFBClientError.self) {
      try decoder.desktopSizeRequest(PixelSize(width: 8192, height: 8192))
    }
    #expect(throws: RFBClientError.self) {
      try decoderDrain(
        &decoder,
        Data([0, 0, 0, 1])
          + decoderRectangle(
            x: 1, y: 4, width: 5, height: 4, payload: [], encoding: -308))
    }
  }

  @Test func nonzeroOriginRowsDecodeAcrossIncompletePixelAndRowFragments() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 5, height: 4))
    _ = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(
          x: 1, y: 1, width: 3, height: 3,
          payload: []))
    let payload: [UInt8] = [
      1, 11, 21, 0, 2, 12, 22, 1, 3, 13, 23, 99,
      4, 14, 24, 255, 5, 15, 25, 7, 6, 16, 26, 8,
      7, 17, 27, 9, 8, 18, 28, 10, 9, 19, 29, 11,
    ]
    var offset = 0
    var completions = 0
    // Splits include incomplete pixels and chunks that cross rectangle rows.
    for count in [1, 2, 6, 8, 3, 9, 7] {
      var prefixed = Data([99, 98])
      prefixed.append(contentsOf: payload[offset..<offset + count])
      let fragment = prefixed.dropFirst(2)
      #expect(fragment.startIndex == 2)
      let actions = try decoderDrain(&decoder, fragment)
      completions +=
        actions.filter {
          if case .updateComplete(resized: false) = $0 { true } else { false }
        }.count
      offset += count
      #expect(completions == (offset == payload.count ? 1 : 0))
    }
    let rgba: [[UInt8]] = [
      [21, 11, 1, 255], [22, 12, 2, 255], [23, 13, 3, 255],
      [24, 14, 4, 255], [25, 15, 5, 255], [26, 16, 6, 255],
      [27, 17, 7, 255], [28, 18, 8, 255], [29, 19, 9, 255],
    ]
    var expected = [UInt8](repeating: 0, count: 5 * 4 * 4)
    for (pixel, bytes) in zip([6, 7, 8, 11, 12, 13, 16, 17, 18], rgba) {
      expected.replaceSubrange(pixel * 4..<pixel * 4 + 4, with: bytes)
    }
    #expect(decoder.pixels == Data(expected))
    #expect(!decoder.initialized && !decoder.messageInProgress)
  }

  @Test func overlappingCoverageFillsHolesBeforeSteadyUpdatesAndKeepsSnapshotsImmutable() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 3, height: 2))
    let top = decoderRectangle(
      x: 0, y: 0, width: 3, height: 1,
      payload: [1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0])
    let left = decoderRectangle(
      x: 0, y: 0, width: 1, height: 2, payload: [10, 11, 12, 0, 13, 14, 15, 0])
    _ = try decoderDrain(&decoder, Data([0, 0, 0, 2]) + top + left)
    #expect(!decoder.initialized)
    let partial = decoder.pixels
    #expect(
      partial
        == Data([
          12, 11, 10, 255, 6, 5, 4, 255, 9, 8, 7, 255,
          15, 14, 13, 255, 0, 0, 0, 0, 0, 0, 0, 0,
        ]))
    _ = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(
          x: 1, y: 1, width: 2, height: 1, payload: [16, 17, 18, 0, 19, 20, 21, 0]))
    #expect(decoder.initialized)
    let full = decoder.pixels
    #expect(
      full
        == Data([
          12, 11, 10, 255, 6, 5, 4, 255, 9, 8, 7, 255,
          15, 14, 13, 255, 18, 17, 16, 255, 21, 20, 19, 255,
        ]))
    _ = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(x: 2, y: 0, width: 1, height: 1, payload: [22, 23, 24, 0]))
    var dirtyExpected = full
    dirtyExpected.replaceSubrange(8..<12, with: [24, 23, 22, 255])
    #expect(decoder.initialized && decoder.pixels == dirtyExpected)
    #expect(partial[16..<24] == Data(repeating: 0, count: 8))
    #expect(full[8..<12] == Data([9, 8, 7, 255]))
  }

  @Test func resizeResetsCoverageAndStrideWithoutMutatingThePreviousFrame() throws {
    var decoder = RfbDecoder()
    _ = try decoderDrain(&decoder, decoderGreeting(width: 2, height: 1))
    _ = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(x: 0, y: 0, width: 2, height: 1, payload: [1, 2, 3, 0, 4, 5, 6, 0]))
    #expect(decoder.initialized)
    let previous = decoder.pixels
    let resized = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(x: 0, y: 0, width: 3, height: 2, payload: [], encoding: -223))
    #expect(
      resized.contains { if case .updateComplete(resized: true) = $0 { true } else { false } })
    #expect(decoder.width == 3 && decoder.height == 2 && !decoder.initialized)
    _ = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 1])
        + decoderRectangle(x: 2, y: 1, width: 1, height: 1, payload: [7, 8, 9, 0]))
    #expect(!decoder.initialized)
    #expect(decoder.pixels == Data(repeating: 0, count: 20) + Data([9, 8, 7, 255]))
    _ = try decoderDrain(
      &decoder,
      Data([0, 0, 0, 2])
        + decoderRectangle(
          x: 0, y: 0, width: 3, height: 1, payload: [10, 11, 12, 0, 13, 14, 15, 0, 16, 17, 18, 0])
        + decoderRectangle(
          x: 0, y: 1, width: 2, height: 1, payload: [19, 20, 21, 0, 22, 23, 24, 0]))
    #expect(decoder.initialized)
    #expect(
      decoder.pixels
        == Data([
          12, 11, 10, 255, 15, 14, 13, 255, 18, 17, 16, 255,
          21, 20, 19, 255, 24, 23, 22, 255, 9, 8, 7, 255,
        ]))
    #expect(previous == Data([3, 2, 1, 255, 6, 5, 4, 255]))
  }

  @Test func fragmented257RectanglesAndNextUpdateResetPixelBudget() throws {
    var decoder = RfbDecoder(pixelPayloadLimit: 257 * 4)
    _ = try decoderDrain(&decoder, decoderGreeting(width: 257, height: 1))
    var update = Data([0, 0, 1, 1])
    var expected = Data()
    for x in 0..<257 {
      let component = UInt8(x & 255)
      update.append(contentsOf: [
        UInt8(x >> 8), UInt8(x & 255), 0, 0, 0, 1, 0, 1, 0, 0, 0, 0,
        component, 2, 3, 99,
      ])
      expected.append(contentsOf: [3, 2, component, 255])
    }
    var completions = 0
    for byte in update {
      for action in try decoderDrain(&decoder, Data([byte])) {
        if case .updateComplete(resized: false) = action { completions += 1 }
      }
    }
    #expect(completions == 1 && decoder.initialized && !decoder.messageInProgress)
    #expect(decoder.pixels == expected)
    // First update exhausted the injected budget. A new update starts at zero.
    let second = Data([0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 8, 7, 6, 0])
    let actions = try decoderDrain(&decoder, second)
    #expect(
      actions.contains { if case .updateComplete(resized: false) = $0 { true } else { false } })
    expected.replaceSubrange(1024..<1028, with: [6, 7, 8, 255])
    #expect(decoder.pixels == expected && !decoder.messageInProgress)
  }

  @Test func wireCountMaximumHasFiniteHeaderWorkAndRejectsPixelBudgetOverflow() throws {
    var decoder = RfbDecoder(pixelPayloadLimit: 4)
    _ = try decoderDrain(&decoder, decoderGreeting(width: 1, height: 1))
    #expect(RfbDecoder.maximumRectangleHeaderBytes == 786_420)
    // Largest wire count is admitted without allocating rectangle metadata.
    _ = try decoderDrain(&decoder, Data([0, 0, 255, 255]))
    #expect(decoder.messageInProgress && !decoder.initialized)
    _ = try decoderDrain(
      &decoder, Data([0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 3, 2, 1, 0]))
    #expect(decoder.initialized && decoder.messageInProgress)
    #expect(throws: RFBClientError.limitExceeded) {
      // A second overlapping pixel would exceed the unchanged per-update bound.
      _ = try decoderDrain(&decoder, Data([0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0]))
    }
  }

  @Test func maximumCanvasRawHeaderIsAdmittedWithoutASecondPayloadAllocation() throws {
    var decoder = RfbDecoder()
    // Independent valid3.8/None/init fixture:8192x2048,32-bit true-color,empty name.
    let greeting =
      Data("RFB 003.008\n".utf8)
      + Data([
        1, 1, 0, 0, 0, 0, 32, 0, 8, 0, 32, 24, 0, 1, 0, 255, 0, 255,
        0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0,
      ])
    _ = try decoder.feed(greeting)
    #expect(decoder.ready && decoder.width == 8192 && decoder.height == 2048)
    // One full-size Raw rectangle header only. No64MiB source body is created.
    _ = try decoder.feed(Data([0, 0, 0, 1, 0, 0, 0, 0, 32, 0, 8, 0, 0, 0, 0, 0]))
    _ = try decoder.feed(Data())
    #expect(!decoder.initialized && decoder.messageInProgress)
  }
}
