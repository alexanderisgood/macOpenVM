// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation
import Qemu

/// Generated public pixels only. No VM, socket, window, or screen files.
@main struct RfbReceiveBenchmark {
  enum Failure: Error { case arguments, correctness, budget }
  struct Sample: Codable {
    let pair: Int
    let order: Int
    let mode: String
    let feedMS: Double
    let snapshotMS: Double
  }
  struct Case: Codable {
    let width: Int
    let height: Int
    let chunks: Int
    let frameSHA256: String
    let warmups: [Sample]
    let samples: [Sample]
  }
  struct Result: Encodable {
    let schemaVersion = 1
    let scope = "generated-receive-materialization-component"
    let maximumFeedBytes = 65_536
    let fragmentPattern = [1, 3, 7, 65_536, 65_533, 31]
    let warmupPairs = 2
    let measuredAlternatingPairs = 10
    let oracleOutsideTiming = true
    let snapshotMeasuredSeparately = true
    let guestPerformanceVerified = false
    let hostOS: String
    let cases: [Case]
  }
  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data("Generated receive experiment failed.\n".utf8))
      exit(1)
    }
  }
  static func run() throws {
    guard Array(CommandLine.arguments.dropFirst()) == ["--run"] else { throw Failure.arguments }
    let deadline = ContinuousClock.now + .seconds(120)
    var results: [Case] = []
    for (width, height) in [(3456, 2168), (3840, 2160)] {
      var payload = [UInt8](repeating: 0, count: width * height * 4)
      var expected = payload
      for pixel in 0..<width * height {
        let at = pixel * 4
        let red = UInt8(truncatingIfNeeded: pixel)
        let green = UInt8(truncatingIfNeeded: pixel >> 7)
        let blue = UInt8(truncatingIfNeeded: pixel >> 15)
        payload[at] = blue
        payload[at + 1] = green
        payload[at + 2] = red
        payload[at + 3] = UInt8(truncatingIfNeeded: pixel >> 3)
        expected[at] = red
        expected[at + 1] = green
        expected[at + 2] = blue
        expected[at + 3] = 255
      }
      let expectedData = Data(expected)
      let expectedHash = hash(expectedData)
      let header =
        Data([0, 0, 0, 1]) + Data(word(0) + word(0) + word(width) + word(height))
        + Data([0, 0, 0, 0])
      let wire = header + Data(payload)
      let pattern = [1, 3, 7, 65_536, 65_533, 31]
      var fragments: [Data] = []
      var offset = 0
      while offset < wire.count {
        let length = min(pattern[fragments.count % pattern.count], wire.count - offset)
        fragments.append(Data(wire[offset..<offset + length]))
        offset += length
      }
      var decoder = RfbDecoder()
      let greeting =
        Data("RFB 003.008\n".utf8) + Data([1, 1, 0, 0, 0, 0])
        + Data(word(width) + word(height))
        + Data([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0])
      _ = try feed(&decoder, [greeting], borrowed: false)
      _ = try feed(&decoder, fragments, borrowed: false)
      guard decoder.initialized, decoder.pixels == expectedData else { throw Failure.correctness }
      var previous = decoder.pixels
      var warmups: [Sample] = []
      var samples: [Sample] = []
      for pair in -2..<10 {
        for (order, borrowed) in (pair % 2 == 0 ? [false, true] : [true, false]).enumerated() {
          guard ContinuousClock.now < deadline else { throw Failure.budget }
          let start = ContinuousClock.now
          let updates = try feed(&decoder, fragments, borrowed: borrowed)
          let end = ContinuousClock.now
          let snapshot = decoder.pixels
          let snapshotEnd = ContinuousClock.now
          guard updates == 1, decoder.initialized, !decoder.messageInProgress,
            snapshot == expectedData, previous == expectedData,
            hash(snapshot) == expectedHash
          else { throw Failure.correctness }
          previous = snapshot
          let sample = Sample(
            pair: pair, order: order, mode: borrowed ? "borrowed-receive" : "materialized-receive",
            feedMS: ms(start.duration(to: end)), snapshotMS: ms(end.duration(to: snapshotEnd)))
          if pair < 0 { warmups.append(sample) } else { samples.append(sample) }
        }
      }
      results.append(
        Case(
          width: width, height: height, chunks: fragments.count, frameSHA256: expectedHash,
          warmups: warmups, samples: samples))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let output = try encoder.encode(
      Result(hostOS: ProcessInfo.processInfo.operatingSystemVersionString, cases: results))
    guard output.count <= 32_768 else { throw Failure.budget }
    FileHandle.standardOutput.write(output + Data([10]))
  }
  static func feed(_ decoder: inout RfbDecoder, _ fragments: [Data], borrowed: Bool) throws -> Int {
    var updates = 0
    for fragment in fragments {
      var actions = try fragment.withUnsafeBytes { bytes in
        if borrowed { return try decoder.feedBorrowed(bytes) }
        // Exactly the pre-change transport materialization, inside timing.
        return try decoder.feed(Data(bytes: bytes.baseAddress!, count: bytes.count))
      }
      var drains = 0
      while !actions.isEmpty {
        for action in actions {
          if case .updateComplete(let resized) = action {
            guard !resized else { throw Failure.correctness }
            updates += 1
          }
        }
        drains += 1
        guard drains <= 16 else { throw Failure.budget }
        actions = try decoder.feed(Data())
      }
    }
    return updates
  }
  static func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
  static func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
      + Double(duration.components.attoseconds) / 1e15
  }
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
