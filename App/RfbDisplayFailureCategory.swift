// SPDX-License-Identifier: Apache-2.0
import Foundation
import Qemu

/// A finite diagnostic only. Never format an error description or its associated payload.
enum RfbDisplayFailureCategory: String, CaseIterable, Sendable {
  case unsafeSocket, invalidTimeout, alreadyConnected, notConnected, closed, busy
  case malformedMessage, unsupportedMessage, limitExceeded, unexpectedMessage
  case disconnected, deadlineExceeded, unsupportedKey, invalidPointer, identifierExhausted
  case posix, cancelled, unknown

  init(error: any Error) {
    if error is CancellationError {
      self = .cancelled
      return
    }
    guard let failure = error as? RFBClientError else {
      self = .unknown
      return
    }
    switch failure {
    case .unsafeSocket: self = .unsafeSocket
    case .invalidTimeout: self = .invalidTimeout
    case .alreadyConnected: self = .alreadyConnected
    case .notConnected: self = .notConnected
    case .closed: self = .closed
    case .busy: self = .busy
    case .malformedMessage: self = .malformedMessage
    case .unsupportedMessage: self = .unsupportedMessage
    case .limitExceeded: self = .limitExceeded
    case .unexpectedMessage: self = .unexpectedMessage
    case .disconnected: self = .disconnected
    case .deadlineExceeded: self = .deadlineExceeded
    case .unsupportedKey: self = .unsupportedKey
    case .invalidPointer, .pointerModeChanged: self = .invalidPointer
    case .identifierExhausted: self = .identifierExhausted
    case .posix: self = .posix
    }
  }

  var displayMessage: String {
    "Display disconnected. Reconnect to check the runtime. (Experimental diagnostic: rfb.\(rawValue))"
  }
}
