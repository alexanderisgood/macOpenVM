// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// Numeric observations of ordinary receiver, draw callbacks and Metal feedback.
/// This does not measure guest renders, unique pixel content or physical scanout.
struct GuestFrameTiming: Sendable {
  struct Sample: Encodable, Sendable {
    let sequence: UInt64
    let receivedMS: Double
    var drawnMS: Double?
    var presentedMS: Double?
  }
  struct Distribution: Encodable, Sendable {
    let medianMS: Double, p95MS: Double, p99MS: Double, longestMS: Double
    let over120HzBudget: Int
    init(_ values: [Double]) {
      let sorted = values.sorted()
      func percentile(_ p: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)]
      }
      medianMS = percentile(0.5)
      p95MS = percentile(0.95)
      p99MS = percentile(0.99)
      longestMS = sorted.last ?? 0
      over120HzBudget = values.filter { $0 > 1000 / 120 }.count
    }
  }
  struct Result: Encodable, Sendable {
    let width: Int, height: Int, durationMS: Double
    let received: Int, drawn: Int, receivedNotDrawn: Int
    let receiveRate: Double, drawRate: Double
    let receiveGaps: Distribution, drawGaps: Distribution, receiveToDraw: Distribution
    let samples: [Sample]
    let presented: Int?
    let presentationRate: Double?
    let presentationGaps: Distribution?
    let physicalScanoutMeasured = false
  }
  let epoch: UUID, size: PixelSize
  private let initialSequence: UInt64
  private let presentationFeedback: Bool
  private(set) var samples: [Sample] = []
  private var lastDrawSequence: UInt64 = 0
  private var lastEventMS: Double = 0
  static let durationMS = 20_000.0
  static let sampleLimit = 4096

  init(
    epoch: UUID, size: PixelSize, initialSequence: UInt64 = 0,
    presentationFeedback: Bool = false
  ) {
    self.epoch = epoch
    self.size = size
    self.initialSequence = initialSequence
    self.presentationFeedback = presentationFeedback
    lastDrawSequence = initialSequence
  }

  mutating func receive(epoch: UUID, size: PixelSize, sequence: UInt64, ms: Double) throws {
    guard self.epoch == epoch, self.size == size, validTime(ms),
      sequence > (samples.last?.sequence ?? initialSequence)
    else { throw Invalid.changed }
    lastEventMS = ms
    guard ms < Self.durationMS else { return }
    guard samples.count < Self.sampleLimit else { throw Invalid.limit }
    samples.append(Sample(sequence: sequence, receivedMS: ms))
  }
  mutating func draw(epoch: UUID?, size: PixelSize?, sequence: UInt64, ms: Double) throws {
    guard self.epoch == epoch, self.size == size, validTime(ms) else { throw Invalid.changed }
    lastEventMS = ms
    guard ms < Self.durationMS, sequence > lastDrawSequence else { return }
    guard let index = samples.lastIndex(where: { $0.sequence == sequence }),
      ms >= samples[index].receivedMS
    else { throw Invalid.changed }
    samples[index].drawnMS = ms
    lastDrawSequence = sequence
  }
  /// A native completion callback carries an event timestamp captured before
  /// dispatcher delivery. Accept its order independently of newer receives.
  mutating func recordedDraw(epoch: UUID?, size: PixelSize?, sequence: UInt64, ms: Double) throws {
    guard self.epoch == epoch, self.size == size, ms.isFinite else { throw Invalid.changed }
    guard ms >= 0, ms < Self.durationMS, sequence > initialSequence else { return }
    guard let index = samples.lastIndex(where: { $0.sequence == sequence }),
      ms >= samples[index].receivedMS
    else { throw Invalid.changed }
    samples[index].drawnMS = min(samples[index].drawnMS ?? ms, ms)
  }
  /// Metal supplies the presentation's host timestamp, independently of when
  /// its callback reaches MainActor. Callbacks may arrive after newer receives
  /// or out of order; never substitute callback delivery time or count redraws.
  mutating func present(epoch: UUID?, size: PixelSize?, sequence: UInt64, ms: Double) throws {
    guard presentationFeedback, self.epoch == epoch, self.size == size, ms.isFinite else {
      throw Invalid.changed
    }
    guard ms >= 0, ms < Self.durationMS, sequence > initialSequence else { return }
    guard let index = samples.lastIndex(where: { $0.sequence == sequence }),
      ms >= samples[index].receivedMS
    else { throw Invalid.changed }
    guard samples[index].presentedMS == nil else { return }
    samples[index].presentedMS = ms
  }
  func result(elapsedMS: Double) throws -> Result {
    guard validTime(elapsedMS), elapsedMS >= Self.durationMS else { throw Invalid.changed }
    let drawn = samples.compactMap(\.drawnMS).sorted()
    let presented = samples.compactMap(\.presentedMS).sorted()
    func gaps(_ times: [Double]) -> [Double] {
      zip(times.dropFirst(), times).map { $0 - $1 }
    }
    return Result(
      width: size.width, height: size.height, durationMS: Self.durationMS,
      received: samples.count, drawn: drawn.count, receivedNotDrawn: samples.count - drawn.count,
      receiveRate: Double(samples.count) / 20, drawRate: Double(drawn.count) / 20,
      receiveGaps: Distribution(gaps(samples.map(\.receivedMS))),
      drawGaps: Distribution(gaps(drawn)),
      receiveToDraw: Distribution(
        samples.compactMap { sample in
          sample.drawnMS.map { $0 - sample.receivedMS }
        }), samples: samples,
      presented: presentationFeedback ? presented.count : nil,
      presentationRate: presentationFeedback ? Double(presented.count) / 20 : nil,
      presentationGaps: presentationFeedback ? Distribution(gaps(presented)) : nil)
  }
  private func validTime(_ ms: Double) -> Bool { ms.isFinite && ms >= lastEventMS }
  enum Invalid: Error { case changed, limit }
}
