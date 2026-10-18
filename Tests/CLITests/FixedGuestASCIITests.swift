import Qemu
// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import MacOpenVMCLI

struct FixedGuestASCIITests {
  @Test func punctuationAndUppercaseCarryActualShiftAndEndReleased() throws {
    #expect(
      try FixedGuestASCII.strokes("A+:a") == [
        RFBKeyStroke(0xffe1, down: true),
        RFBKeyStroke(65, down: true), RFBKeyStroke(65, down: false),
        RFBKeyStroke(43, down: true), RFBKeyStroke(43, down: false),
        RFBKeyStroke(58, down: true), RFBKeyStroke(58, down: false),
        RFBKeyStroke(0xffe1, down: false),
        RFBKeyStroke(97, down: true), RFBKeyStroke(97, down: false),
      ])
    #expect(try FixedGuestASCII.strokes("ABC").last == RFBKeyStroke(0xffe1, down: false))
  }
  @Test func incompatibleLayoutsAndUnboundedCompositionAreRefused() {
    for text in ["", "a\n", "a\\b", "a@b", "é", String(repeating: "a", count: 12001)] {
      #expect(throws: RFBClientError.self) { try FixedGuestASCII.strokes(text) }
    }
  }
}
