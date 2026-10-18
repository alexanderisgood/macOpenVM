// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

@Suite struct GeneratedRfbAppQualificationTests {
  private let nonce = UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
  private let parent = "/private/tmp/mvo-rfb-present-0123456789abcdef0123456789abcdef"
  private var arguments: [String] {
    [
      "app", GeneratedRfbAppQualificationRequest.flag, "--run",
      "--display-socket", parent + "/display.sock", "--nonce", nonce.uuidString,
      "--output-directory", parent + "/evidence",
    ]
  }
  @Test func closedRequestRefusesForeignRoutesIdentityAndOtherModes() throws {
    let environment = ["MVO_GENERATED_RFB_APP_QUALIFICATION": "1"]
    let value = try #require(
      try GeneratedRfbAppQualificationRequest.parse(arguments: arguments, environment: environment))
    #expect(value.nonce == nonce && value.socket.path == parent + "/display.sock")
    #expect(
      try GeneratedRfbAppQualificationRequest.parse(arguments: ["app"], environment: environment)
        == nil)
    var faults = [
      arguments + ["--extra"], Array(arguments.dropLast()),
      arguments + [RegisteredWindowsAppQualificationRequest.flag],
    ]
    for (index, value) in [
      (4, "/tmp/display.sock"), (6, "00000000-0000-0000-0000-000000000000"),
      (6, nonce.uuidString.lowercased()), (8, parent + "/other"),
    ] {
      var fault = arguments
      fault[index] = value
      faults.append(fault)
    }
    for fault in faults {
      #expect(throws: (any Error).self) {
        try GeneratedRfbAppQualificationRequest.parse(arguments: fault, environment: environment)
      }
    }
    #expect(throws: (any Error).self) {
      try GeneratedRfbAppQualificationRequest.parse(arguments: arguments, environment: [:])
    }
  }
  private func receive(_ ledger: inout GeneratedRfbPresentationLedger, marker: Int, epoch: UUID)
    throws
  {
    let geometry = [(800, 600), (1920, 1080), (3840, 2160)][(marker - 1) / 6]
    try ledger.receive(
      epoch: epoch, sequence: UInt64(marker), marker: marker,
      size: PixelSize(width: geometry.0, height: geometry.1), requestMS: Double(marker * 100 - 10),
      receiveMS: Double(marker * 100 - 5), publishMS: Double(marker * 100))
  }
  private func presentation(marker: Int, epoch: UUID) -> RfbQualificationPresentation {
    let geometry = [(800, 600), (1920, 1080), (3840, 2160)][(marker - 1) / 6]
    return RfbQualificationPresentation(
      epoch: epoch, sequence: UInt64(marker), width: geometry.0, height: geometry.1,
      attached: true, visible: true, drawn: true)
  }
  @Test func coalescedFramesCountOnlyMatchingNaturalDrawObservations() throws {
    var ledger = GeneratedRfbPresentationLedger()
    let epoch = UUID()
    for marker in 1...18 { try receive(&ledger, marker: marker, epoch: epoch) }
    for marker in [6, 12, 18] {
      try ledger.draw(
        presentation(marker: marker, epoch: epoch), milliseconds: Double(marker * 100 + 7))
      try ledger.draw(
        presentation(marker: marker, epoch: epoch), milliseconds: Double(marker * 100 + 9))
    }
    #expect(ledger.complete && ledger.drawn.count == 3 && ledger.coalesced == 15)
    #expect(ledger.drawn.allSatisfy { $0.publishToDrawMS == 7 })
  }
  @Test func staleEpochGeometrySequenceAndNegativeDelayAreRefused() throws {
    var ledger = GeneratedRfbPresentationLedger()
    let epoch = UUID()
    try receive(&ledger, marker: 1, epoch: epoch)
    #expect(throws: (any Error).self) {
      try ledger.receive(
        epoch: UUID(), sequence: 2, marker: 2, size: PixelSize(width: 800, height: 600),
        requestMS: 190, receiveMS: 195, publishMS: 200)
    }
    #expect(throws: (any Error).self) {
      try ledger.receive(
        epoch: epoch, sequence: 1, marker: 2, size: PixelSize(width: 800, height: 600),
        requestMS: 190, receiveMS: 195, publishMS: 200)
    }
    #expect(throws: (any Error).self) {
      try ledger.receive(
        epoch: epoch, sequence: 2, marker: 2, size: PixelSize(width: 1920, height: 1080),
        requestMS: 190, receiveMS: 195, publishMS: 200)
    }
    #expect(throws: (any Error).self) {
      try ledger.draw(presentation(marker: 1, epoch: UUID()), milliseconds: 105)
    }
    #expect(throws: (any Error).self) {
      try ledger.draw(presentation(marker: 1, epoch: epoch), milliseconds: 99)
    }
    #expect(!ledger.complete && ledger.drawn.isEmpty)
  }
  @Test func incompleteGeometryCoverageAndInvalidPublicationTimesCannotComplete() throws {
    var ledger = GeneratedRfbPresentationLedger()
    let epoch = UUID()
    for marker in 1...18 { try receive(&ledger, marker: marker, epoch: epoch) }
    try ledger.draw(presentation(marker: 18, epoch: epoch), milliseconds: 1810)
    #expect(!ledger.complete && ledger.coalesced == 17)
    var empty = GeneratedRfbPresentationLedger()
    for times in [(Double.nan, 95.0, 100.0), (90.0, 89.0, 100.0), (90.0, 95.0, 94.0)] {
      #expect(throws: (any Error).self) {
        try empty.receive(
          epoch: epoch, sequence: 1, marker: 1, size: PixelSize(width: 800, height: 600),
          requestMS: times.0, receiveMS: times.1, publishMS: times.2)
      }
    }
    #expect(empty.received.isEmpty)
  }
  @MainActor @Test func allPixelMarkersAndOpaqueAlphaAreCheckedWithoutNativeRenderer() throws {
    let size = PixelSize(width: 2, height: 2)
    let bytes = Data([
      0x80, 0x40, 1, 255, 0x80, 0x40, 1, 255, 0x80, 0x40, 1, 255, 0x80, 0x40, 1, 255,
    ])
    try GeneratedRfbAppQualification.validate(bytes, marker: 1, size: size)
    for index in 0..<bytes.count {
      var changed = bytes
      changed[index] ^= 0xff
      #expect(throws: (any Error).self) {
        try GeneratedRfbAppQualification.validate(changed, marker: 1, size: size)
      }
    }
    #expect(throws: (any Error).self) {
      try GeneratedRfbAppQualification.validate(bytes, marker: 0, size: size)
    }
    #expect(throws: (any Error).self) {
      try GeneratedRfbAppQualification.validate(
        bytes, marker: 1, size: PixelSize(width: Int.max, height: Int.max))
    }
  }
}
