// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A bounded numeric summary. No frame samples, pixels, route or VM paths.
/// Construction and encoding are pure; only the explicit menu action copies it.
struct GuestDisplayMeasurementReport: Encodable, Sendable {
  let schemaVersion = 1
  let method: String
  let hostClock = "CACurrentMediaTime seconds; host monotonic clock, not wall time"
  let eventWindowStartHostSeconds: Double
  let eventWindowEndHostSeconds: Double
  let eventWindow = "0 <= eventMS < durationMS; feedback may drain for up to 2 seconds"
  let receiveClock = "Host receipt time (CACurrentMediaTime)"
  let drawClock: String
  let presentationClock: String?
  let diagnostics: GuestFrameTimingCapture.Diagnostics
  let width: Int, height: Int, durationMS: Double
  let received: Int, drawn: Int, receivedNotDrawn: Int
  let receiveRate: Double, drawRate: Double
  let receiveGaps: GuestFrameTiming.Distribution
  let drawGaps: GuestFrameTiming.Distribution
  let receiveToDraw: GuestFrameTiming.Distribution
  let presented: Int?
  let presentationRate: Double?
  let presentationGaps: GuestFrameTiming.Distribution?
  let physicalScanoutMeasured = false

  init?(
    result: GuestFrameTiming.Result?, diagnostics: GuestFrameTimingCapture.Diagnostics?,
    method: String, origin: Double
  ) {
    guard let result, let diagnostics,
      diagnostics.status == .complete, diagnostics.invalidReason == nil,
      diagnostics.sourceStopped, diagnostics.unresolvedTickets == 0,
      result.durationMS == GuestFrameTiming.durationMS, origin.isFinite, origin >= 0,
      result.width > 0, result.height > 0,
      diagnostics.received == result.received, diagnostics.drawn == result.drawn,
      diagnostics.presented == (result.presented ?? 0)
    else { return nil }
    switch method {
    case "AppKit draw callbacks":
      guard result.presented == nil, result.presentationRate == nil,
        result.presentationGaps == nil, diagnostics.issuedTickets == 0
      else { return nil }
      drawClock = "AppKit post-image-draw observation (CACurrentMediaTime)"
      presentationClock = nil
    case "Metal completion callback entry":
      guard result.presented != nil, result.presentationRate != nil,
        result.presentationGaps != nil
      else { return nil }
      drawClock = "Metal completion callback entry (CACurrentMediaTime)"
      presentationClock = "Metal supplied host presentation timestamp; not callback delivery time"
    default: return nil
    }
    self.method = method
    eventWindowStartHostSeconds = origin
    eventWindowEndHostSeconds = origin + result.durationMS / 1000
    self.diagnostics = diagnostics
    width = result.width
    height = result.height
    durationMS = result.durationMS
    received = result.received
    drawn = result.drawn
    receivedNotDrawn = result.receivedNotDrawn
    receiveRate = result.receiveRate
    drawRate = result.drawRate
    receiveGaps = result.receiveGaps
    drawGaps = result.drawGaps
    receiveToDraw = result.receiveToDraw
    presented = result.presented
    presentationRate = result.presentationRate
    presentationGaps = result.presentationGaps
  }

  func jsonString() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}
