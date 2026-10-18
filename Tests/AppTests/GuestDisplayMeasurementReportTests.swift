// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite struct GuestDisplayMeasurementReportTests {
  private let epoch = UUID()
  private let size = PixelSize(width: 3456, height: 2168)

  private func result(metal: Bool = true) throws -> GuestFrameTiming.Result {
    var timing = GuestFrameTiming(epoch: epoch, size: size, presentationFeedback: metal)
    try timing.receive(epoch: epoch, size: size, sequence: 1, ms: 1)
    try timing.draw(epoch: epoch, size: size, sequence: 1, ms: 3)
    try timing.receive(epoch: epoch, size: size, sequence: 2, ms: 10)
    if metal { try timing.present(epoch: epoch, size: size, sequence: 1, ms: 5) }
    return try timing.result(elapsedMS: GuestFrameTiming.durationMS)
  }

  private func diagnostics(
    status: GuestFrameTimingCapture.Status = .complete,
    reason: GuestFrameTimingCapture.InvalidReason? = nil,
    tickets: Int = 0, stopped: Bool = true, metal: Bool = true
  ) -> GuestFrameTimingCapture.Diagnostics {
    GuestFrameTimingCapture.Diagnostics(
      sampleID: epoch, status: status, invalidReason: reason,
      received: 2, drawn: 1, presented: metal ? 1 : 0,
      issuedTickets: metal ? 1 : 0, unresolvedTickets: tickets, sourceStopped: stopped)
  }

  @Test func encodesExactCountsClockBoundsAndCompleteQualityWithoutFrameSamples() throws {
    let report = try #require(
      GuestDisplayMeasurementReport(
        result: try result(), diagnostics: diagnostics(),
        method: "Metal completion callback entry", origin: 1234.5))
    let data = Data(try report.jsonString().utf8)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["received"] as? Int == 2 && object["drawn"] as? Int == 1)
    #expect(object["receivedNotDrawn"] as? Int == 1 && object["presented"] as? Int == 1)
    #expect(object["receiveRate"] as? Double == 0.1 && object["drawRate"] as? Double == 0.05)
    #expect(object["width"] as? Int == 3456 && object["height"] as? Int == 2168)
    #expect(object["durationMS"] as? Double == 20_000)
    #expect(object["eventWindowStartHostSeconds"] as? Double == 1234.5)
    #expect(object["eventWindowEndHostSeconds"] as? Double == 1254.5)
    let quality = try #require(object["diagnostics"] as? [String: Any])
    #expect(quality["status"] as? String == "complete")
    #expect(quality["unresolvedTickets"] as? Int == 0 && quality["sourceStopped"] as? Bool == true)
    #expect(object["physicalScanoutMeasured"] as? Bool == false)
    #expect(object["samples"] == nil && object["pixels"] == nil && object["route"] == nil)
    #expect(report.presentationClock?.contains("not callback delivery time") == true)
  }

  @Test func refusesPartialMissingUnsettledOrMismatchedMetadata() throws {
    let complete = try result()
    let incomplete: [GuestFrameTimingCapture.Status] = [
      .sampling, .draining, .incompleteFeedback, .cancelled, .invalid,
    ]
    for status in incomplete {
      #expect(
        GuestDisplayMeasurementReport(
          result: complete, diagnostics: diagnostics(status: status),
          method: "Metal completion callback entry", origin: 1) == nil)
    }
    for quality in [
      diagnostics(reason: .changed), diagnostics(tickets: 1), diagnostics(stopped: false),
      diagnostics(metal: false),
    ] {
      #expect(
        GuestDisplayMeasurementReport(
          result: complete, diagnostics: quality,
          method: "Metal completion callback entry", origin: 1) == nil)
    }
    #expect(
      GuestDisplayMeasurementReport(
        result: nil, diagnostics: diagnostics(),
        method: "Metal completion callback entry", origin: 1) == nil)
    #expect(
      GuestDisplayMeasurementReport(
        result: complete, diagnostics: nil,
        method: "Metal completion callback entry", origin: 1) == nil)
    #expect(
      GuestDisplayMeasurementReport(
        result: complete, diagnostics: diagnostics(),
        method: "AppKit draw callbacks", origin: 1) == nil)
    #expect(
      GuestDisplayMeasurementReport(
        result: complete, diagnostics: diagnostics(), method: "other", origin: 1) == nil)
    for origin in [Double.nan, .infinity, -1] {
      #expect(
        GuestDisplayMeasurementReport(
          result: complete, diagnostics: diagnostics(),
          method: "Metal completion callback entry", origin: origin) == nil)
    }
  }

  @Test func appKitSummaryKeepsPresentationUnmeasured() throws {
    let report = try #require(
      GuestDisplayMeasurementReport(
        result: try result(metal: false), diagnostics: diagnostics(metal: false),
        method: "AppKit draw callbacks", origin: 1))
    #expect(report.presented == nil && report.presentationRate == nil)
    #expect(report.presentationGaps == nil && report.presentationClock == nil)
    #expect(report.drawClock == "AppKit post-image-draw observation (CACurrentMediaTime)")
    #expect(!report.physicalScanoutMeasured)
  }
}
