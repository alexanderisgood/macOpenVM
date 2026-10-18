// SPDX-License-Identifier: Apache-2.0
// Copied into an isolated generated package by prepare_geometry.py. No GPU,
// AppKit, VM, display, socket, application or production-package entry point.
import BackendAPI
import BaselineGeometry
import CandidateGeometry
import Foundation

private struct Fixture: Sendable {
  let bounds: CGRect
  let pixels: PixelSize
}

private let fixtures = [
  Fixture(
    bounds: CGRect(x: 0, y: 0, width: 1728, height: 1084),
    pixels: PixelSize(width: 3456, height: 2168)),
  Fixture(
    bounds: CGRect(x: 0, y: 0, width: 1728, height: 1084),
    pixels: PixelSize(width: 1920, height: 1080)),
  Fixture(
    bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
    pixels: PixelSize(width: 2560, height: 1600)),
  Fixture(
    bounds: CGRect(x: 11.25, y: -5.5, width: 800, height: 600),
    pixels: PixelSize(width: 640, height: 480)),
  Fixture(
    bounds: CGRect(x: -20.25, y: 31.75, width: 800.8, height: 640.8),
    pixels: PixelSize(width: 320, height: 240)),
  Fixture(
    bounds: CGRect(x: -12.375, y: 43.625, width: 731.25, height: 1001.875),
    pixels: PixelSize(width: 640, height: 480)),
  Fixture(
    bounds: CGRect(x: 7, y: 13, width: 300, height: 200),
    pixels: PixelSize(width: 1920, height: 1080)),
  Fixture(
    bounds: CGRect(x: 1, y: 2, width: 8192, height: 2048),
    pixels: PixelSize(width: 8192, height: 2048)),
]

@inline(never) private func baseline(_ count: Int) throws -> Double {
  var checksum = 0.0
  for index in 0..<count {
    let fixture = fixtures[index % fixtures.count]
    let viewport = try BaselineGeometry.GuestViewport(
      viewBounds: fixture.bounds, guestPixels: fixture.pixels)
    let rect = viewport.fittedRect
    let point = viewport.map(viewPoint: CGPoint(x: rect.midX, y: rect.midY))
    checksum += Double(rect.minX + rect.minY + rect.width + rect.height)
    checksum += Double(point?.x ?? 0) + Double(point?.y ?? 0)
  }
  return checksum
}

@inline(never) private func candidate(_ count: Int) throws -> Double {
  var checksum = 0.0
  for index in 0..<count {
    let fixture = fixtures[index % fixtures.count]
    // This is the actual production default-fit initializer, as selected by
    // RfbGuestView's early return. Backing conversion is excluded in both arms.
    let viewport = try CandidateGeometry.GuestViewport(
      viewBounds: fixture.bounds, guestPixels: fixture.pixels)
    let rect = viewport.fittedRect
    let point = viewport.map(viewPoint: CGPoint(x: rect.midX, y: rect.midY))
    checksum += Double(rect.minX + rect.minY + rect.width + rect.height)
    checksum += Double(point?.x ?? 0) + Double(point?.y ?? 0)
  }
  return checksum
}

private func nanoseconds(_ duration: Duration) -> Double {
  let value = duration.components
  return Double(value.seconds) * 1e9 + Double(value.attoseconds) / 1e9
}

private func run() throws {
  let clock = ContinuousClock()
  let began = clock.now
  let warmCount = 20_000
  let measuredCount = 200_000
  let pairs = 8
  let baselineWarm = try baseline(warmCount)
  let candidateWarm = try candidate(warmCount)
  guard baselineWarm == candidateWarm else { fatalError("Default geometry/checksum changed") }
  var records = [[String: Any]]()
  for pair in 0..<pairs {
    let variants = pair % 2 == 0 ? ["baseline", "candidate"] : ["candidate", "baseline"]
    for (position, variant) in variants.enumerated() {
      guard began.duration(to: clock.now) < .seconds(45) else {
        fatalError("45s CPU fixture deadline")
      }
      let start = clock.now
      let checksum = try variant == "baseline" ? baseline(measuredCount) : candidate(measuredCount)
      let elapsed = nanoseconds(start.duration(to: clock.now))
      guard elapsed.isFinite, elapsed > 0 else { fatalError("Invalid monotonic duration") }
      records.append([
        "pair": pair, "position": position, "variant": variant,
        "iterations": measuredCount, "elapsedNS": elapsed,
        "nsPerIteration": elapsed / Double(measuredCount), "checksum": checksum,
      ])
    }
  }
  var ratios = [Double]()
  for pair in 0..<pairs {
    let rows = records.filter { ($0["pair"] as? Int) == pair }
    let baselineRow = rows.first(where: { ($0["variant"] as? String) == "baseline" })
    let candidateRow = rows.first(where: { ($0["variant"] as? String) == "candidate" })
    guard let before = baselineRow?["nsPerIteration"] as? Double,
      let after = candidateRow?["nsPerIteration"] as? Double,
      let beforeChecksum = baselineRow?["checksum"] as? Double,
      let afterChecksum = candidateRow?["checksum"] as? Double
    else { fatalError("Incomplete pair") }
    guard beforeChecksum == afterChecksum else {
      fatalError("Baseline/candidate checksum mismatch")
    }
    ratios.append(after / before)
  }
  let result: [String: Any] = [
    "schemaVersion": 1, "scope": "exact-production-default-geometry-and-point-map-CPU-component",
    "warmIterationsPerVariant": warmCount, "iterationsPerBlock": measuredCount, "pairs": pairs,
    "caseCount": fixtures.count, "blocks": records, "pairedCandidateToBaselineRatios": ratios,
    "liveFPSMeasured": false, "includesAppKitBackingConversion": false, "includesGPU": false,
    "checksumMatches": true, "elapsedMS": nanoseconds(began.duration(to: clock.now)) / 1e6,
    "warning":
      "Within-block iterations are not independent replicates; use paired blocks and live app qualification",
  ]
  let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}

try run()
