// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation
import Qemu

/// Original generated public pixels, not a VM, screen capture or RFB connection.
@main struct RfbDecodeBenchmark {
  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data("RFB component measurement failed.\n".utf8))
      exit(1)
    }
  }
  private static func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 3, arguments[0] == "--run", arguments[1] == "--trials",
      let trials = Int(arguments[2]), trials == 5
    else { throw Failure.arguments }
    let deadline = ContinuousClock.now + .seconds(120)
    var cases: [CaseResult] = []
    for (width, height) in [(1280, 720), (2560, 1440), (3840, 2160)] {
      let full = raw(
        width: width, height: height, x: 0, y: 0, rectWidth: width, rectHeight: height, seed: 0)
      let dirty = raw(
        width: width, height: height, x: 17, y: 23, rectWidth: 48, rectHeight: 32, seed: 1)
      let fullChunks = chunks(full)
      let dirtyChunks = chunks(dirty)
      var fullSamples: [Sample] = []
      var steadySamples: [Sample] = []
      var dirtySamples: [Sample] = []
      var fullHash = ""
      var dirtyHash = ""
      for _ in 0..<trials {
        guard ContinuousClock.now < deadline else { throw Failure.limit }
        var decoder = RfbDecoder()
        let greetingActions = try feed(&decoder, chunks(greeting(width: width, height: height)))
        guard decoder.ready, !decoder.initialized, decoder.width == width, decoder.height == height,
          greetingActions.ready == 1, greetingActions.updates == 0
        else { throw Failure.correctness }
        let fullStart = ContinuousClock.now
        let fullActions = try feed(&decoder, fullChunks)
        let fullEnd = ContinuousClock.now
        let copyStart = ContinuousClock.now
        let previous = decoder.pixels
        let copyEnd = ContinuousClock.now
        try validate(previous, width: width, height: height, dirty: false)
        guard fullActions.updates == 1, fullActions.started == 1, decoder.initialized,
          !decoder.messageInProgress
        else { throw Failure.correctness }
        fullHash = hash(previous)
        fullSamples.append(
          Sample(
            decodeMS: ms(fullStart.duration(to: fullEnd)),
            snapshotMS: ms(copyStart.duration(to: copyEnd))))
        let steadyStart = ContinuousClock.now
        let steadyActions = try feed(&decoder, fullChunks)
        let steadyEnd = ContinuousClock.now
        let steadyCopyStart = ContinuousClock.now
        let steady = decoder.pixels
        let steadyCopyEnd = ContinuousClock.now
        try validate(steady, width: width, height: height, dirty: false)
        guard steadyActions.updates == 1, steadyActions.started == 1, decoder.initialized,
          !decoder.messageInProgress, hash(previous) == fullHash, hash(steady) == fullHash
        else { throw Failure.correctness }
        steadySamples.append(
          Sample(
            decodeMS: ms(steadyStart.duration(to: steadyEnd)),
            snapshotMS: ms(steadyCopyStart.duration(to: steadyCopyEnd))))
        let dirtyStart = ContinuousClock.now
        let dirtyActions = try feed(&decoder, dirtyChunks)
        let dirtyEnd = ContinuousClock.now
        let dirtyCopyStart = ContinuousClock.now
        let current = decoder.pixels
        let dirtyCopyEnd = ContinuousClock.now
        try validate(current, width: width, height: height, dirty: true)
        try validate(previous, width: width, height: height, dirty: false)
        try validate(steady, width: width, height: height, dirty: false)
        guard dirtyActions.updates == 1, dirtyActions.started == 1, decoder.initialized,
          !decoder.messageInProgress, hash(previous) == fullHash, hash(steady) == fullHash
        else { throw Failure.correctness }
        dirtyHash = hash(current)
        dirtySamples.append(
          Sample(
            decodeMS: ms(dirtyStart.duration(to: dirtyEnd)),
            snapshotMS: ms(dirtyCopyStart.duration(to: dirtyCopyEnd))))
        guard ContinuousClock.now < deadline else { throw Failure.limit }
      }
      cases.append(
        CaseResult(
          name: "initial-full", width: width, height: height, rectangleWidth: width,
          rectangleHeight: height, rectangles: 1, wireBytes: full.count, chunks: fullChunks.count,
          snapshotBytes: width * height * 4, frameSHA256: fullHash, samples: fullSamples))
      cases.append(
        CaseResult(
          name: "steady-full", width: width, height: height,
          rectangleWidth: width, rectangleHeight: height, rectangles: 1, wireBytes: full.count,
          chunks: fullChunks.count, snapshotBytes: width * height * 4, frameSHA256: fullHash,
          samples: steadySamples))
      cases.append(
        CaseResult(
          name: "dirty", width: width, height: height, rectangleWidth: 48,
          rectangleHeight: 32, rectangles: 1, wireBytes: dirty.count, chunks: dirtyChunks.count,
          snapshotBytes: width * height * 4, frameSHA256: dirtyHash, samples: dirtySamples))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(
      Result(
        schemaVersion: 1, scope: "generated-public-RFB-decoder-component",
        decodeScope: "feed-dispatch-buffering-and-empty-feed-drain",
        cachePolicy: "sequential-process-trials-no-cache-reset",
        hostOS: ProcessInfo.processInfo.operatingSystemVersionString, trials: trials,
        maximumFeedBytes: 65536,
        fragmentPattern: [1, 3, 7, 65536, 65533, 31], workloadWallBudgetSeconds: 120,
        correctnessOutsideTiming: true,
        snapshotMeasuredSeparately: true, guestPerformanceVerified: false,
        uiFramePacingVerified: false,
        cases: cases))
    guard data.count <= 16384 else { throw Failure.limit }
    FileHandle.standardOutput.write(data + Data([10]))
  }
  private struct Actions {
    var ready = 0
    var started = 0
    var updates = 0
  }
  private static func feed(_ decoder: inout RfbDecoder, _ fragments: [Data]) throws -> Actions {
    var result = Actions()
    for fragment in fragments {
      var actions = try decoder.feed(fragment)
      for _ in 0..<16 {
        guard !actions.isEmpty else { break }
        for action in actions {
          switch action {
          case .ready: result.ready += 1
          case .messageStarted: result.started += 1
          case .updateStarted: break
          case .updateComplete(let resized):
            guard !resized else { throw Failure.correctness }
            result.updates += 1
          case .send, .messageComplete: break
          }
        }
        actions = try decoder.feed(Data())
      }
      guard actions.isEmpty else { throw Failure.limit }
    }
    return result
  }
  private static func chunks(_ bytes: Data) -> [Data] {
    let sizes = [1, 3, 7, 65536, 65533, 31]
    var result: [Data] = []
    var offset = 0
    var index = 0
    while offset < bytes.count {
      let count = min(sizes[index % sizes.count], bytes.count - offset)
      result.append(Data(bytes[offset..<offset + count]))
      offset += count
      index += 1
    }
    return result
  }
  private static func greeting(width: Int, height: Int) -> Data {
    var data = Data("RFB 003.008\n".utf8)
    data.append(contentsOf: [1, 1, 0, 0, 0, 0])
    data.append(contentsOf: u16(width) + u16(height))
    data.append(contentsOf: [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0])
    return data
  }
  private static func raw(
    width: Int, height: Int, x: Int, y: Int, rectWidth: Int, rectHeight: Int, seed: Int
  ) -> Data {
    var data = Data([0, 0, 0, 1])
    data.append(contentsOf: u16(x) + u16(y) + u16(rectWidth) + u16(rectHeight) + [0, 0, 0, 0])
    data.reserveCapacity(16 + rectWidth * rectHeight * 4)
    for row in y..<y + rectHeight {
      for column in x..<x + rectWidth {
        data.append(contentsOf: [
          UInt8((column + row + seed * 7) & 255), UInt8((row + seed * 11) & 255),
          UInt8((column + seed * 17) & 255), UInt8((column ^ row) & 255),
        ])
      }
    }
    return data
  }
  private static func validate(_ pixels: Data, width: Int, height: Int, dirty: Bool) throws {
    guard pixels.count == width * height * 4 else { throw Failure.correctness }
    try pixels.withUnsafeBytes { buffer in
      let values = buffer.bindMemory(to: UInt8.self)
      for y in 0..<height {
        for x in 0..<width {
          let seed = dirty && (17..<65).contains(x) && (23..<55).contains(y) ? 1 : 0
          let at = (y * width + x) * 4
          guard values[at] == UInt8((x + seed * 17) & 255),
            values[at + 1] == UInt8((y + seed * 11) & 255),
            values[at + 2] == UInt8((x + y + seed * 7) & 255), values[at + 3] == 255
          else { throw Failure.correctness }
        }
      }
    }
  }
  private static func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
  private enum Failure: Error { case arguments, correctness, limit }
  private struct Sample: Encodable { let decodeMS: Double, snapshotMS: Double }
  private struct CaseResult: Encodable {
    let name: String, width: Int, height: Int, rectangleWidth: Int, rectangleHeight: Int
    let rectangles: Int, wireBytes: Int, chunks: Int, snapshotBytes: Int, frameSHA256: String
    let samples: [Sample]
  }
  private struct Result: Encodable {
    let schemaVersion: Int, scope: String
    let decodeScope: String, cachePolicy: String
    let hostOS: String, trials: Int, maximumFeedBytes: Int
    let fragmentPattern: [Int], workloadWallBudgetSeconds: Int
    let correctnessOutsideTiming: Bool, snapshotMeasuredSeparately: Bool
    let guestPerformanceVerified: Bool, uiFramePacingVerified: Bool, cases: [CaseResult]
  }
}
