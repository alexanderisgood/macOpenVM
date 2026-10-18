// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// Scoped input/output mode for an interactive serial console. Pipes remain unchanged.
final class SerialTerminal {
  private let descriptor: Int32
  private var previous: termios?

  init(input: FileHandle = .standardInput) throws {
    descriptor = input.fileDescriptor
    guard isatty(descriptor) == 1 else { return }
    var saved = termios()
    guard tcgetattr(descriptor, &saved) == 0 else { throw Self.unavailable() }
    var raw = saved
    cfmakeraw(&raw)
    guard tcsetattr(descriptor, TCSANOW, &raw) == 0 else {
      _ = tcsetattr(descriptor, TCSANOW, &saved)
      throw Self.unavailable()
    }
    previous = saved
  }

  @discardableResult func restore() -> Bool {
    guard var saved = previous else { return true }
    guard tcsetattr(descriptor, TCSANOW, &saved) == 0 else { return false }
    previous = nil
    return true
  }
  deinit { restore() }

  private static func unavailable() -> VMError {
    VMError(
      .backendFailure, "Cannot prepare the interactive serial terminal.",
      recovery: "Use redirected serial pipes or another terminal. The VM has not started.")
  }
}
