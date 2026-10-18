// SPDX-License-Identifier: Apache-2.0
import Foundation
import Qemu
import Testing

@testable import MacOpenVMApp

@Suite struct RfbDisplayFailureCategoryTests {
  @Test func typedFailuresKeepDistinctFiniteCodesAndTheReconnectAction() {
    let cases: [(RFBClientError, RfbDisplayFailureCategory)] = [
      (.unsafeSocket, .unsafeSocket), (.invalidTimeout, .invalidTimeout),
      (.alreadyConnected, .alreadyConnected), (.notConnected, .notConnected),
      (.closed, .closed), (.busy, .busy), (.malformedMessage, .malformedMessage),
      (.unsupportedMessage, .unsupportedMessage), (.limitExceeded, .limitExceeded),
      (.unexpectedMessage, .unexpectedMessage), (.disconnected, .disconnected),
      (.deadlineExceeded, .deadlineExceeded), (.unsupportedKey, .unsupportedKey),
      (.invalidPointer, .invalidPointer), (.identifierExhausted, .identifierExhausted),
      (.posix(13), .posix),
    ]
    for (error, expected) in cases {
      let category = RfbDisplayFailureCategory(error: error)
      #expect(category == expected)
      #expect(
        category.displayMessage.hasPrefix("Display disconnected. Reconnect to check the runtime."))
      #expect(category.displayMessage.contains("rfb.\(expected.rawValue)"))
    }
    #expect(Set(cases.map { $0.1.rawValue }).count == cases.count)
  }

  @Test func associatedSystemErrorAndUnknownDescriptionsNeverReachTheDisplay() {
    for number: Int32 in [0, 2, 13, -1, Int32.min, Int32.max] {
      let category = RfbDisplayFailureCategory(error: RFBClientError.posix(number))
      #expect(category == .posix)
      #expect(category.displayMessage == RfbDisplayFailureCategory.posix.displayMessage)
    }
    let privateDescription = "untrusted guest text /private/example-path numeric-error=314159"
    let arbitrary = NSError(
      domain: privateDescription, code: 314159,
      userInfo: [NSLocalizedDescriptionKey: privateDescription])
    let unknown = RfbDisplayFailureCategory(error: arbitrary)
    #expect(unknown == .unknown)
    #expect(!unknown.displayMessage.contains(privateDescription))
    #expect(!unknown.displayMessage.contains("314159"))
    #expect(!unknown.displayMessage.contains("/private/"))
    #expect(RfbDisplayFailureCategory(error: CancellationError()) == .cancelled)
  }
}
