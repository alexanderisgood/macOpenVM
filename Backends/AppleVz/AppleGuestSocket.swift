// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Virtualization

/// A borrowed descriptor's owner. The native connection owns and closes its descriptor.
@MainActor
protocol AppleGuestSocketConnection: AnyObject {
  var fileDescriptor: Int32 { get }
  var sourcePort: UInt32 { get }
  var destinationPort: UInt32 { get }
  func close()
}

extension VZVirtioSocketConnection: AppleGuestSocketConnection {}

/// Owns a native transport connection, without inferring authentication or guest-agent health.
/// Native calls and lifecycle use the VM's main queue. The VM itself must remain retained by its owner.
@MainActor
public final class AppleGuestSocketSession {
  typealias Connector =
    @MainActor (
      UInt32, @escaping @MainActor (Result<any AppleGuestSocketConnection, any Error>) -> Void
    ) -> Void

  public let sourcePort: UInt32
  public let destinationPort: UInt32
  private var connection: (any AppleGuestSocketConnection)?
  private var borrowers = 0
  private var closeRequested = false

  init(connection: any AppleGuestSocketConnection) {
    self.connection = connection
    sourcePort = connection.sourcePort
    destinationPort = connection.destinationPort
  }

  /// Cancellation abandons this Swift waiter. The SDK has no native connect cancellation API;
  /// any later successful native completion is closed. No native deadline is implied.
  public static func connect(to device: VZVirtioSocketDevice, port: UInt32) async throws
    -> AppleGuestSocketSession
  {
    try await connect(port: port) { port, completion in
      device.connect(toPort: port) { result in
        completion(result.map { $0 as any AppleGuestSocketConnection })
      }
    }
  }

  static func connect(port: UInt32, using connector: Connector) async throws
    -> AppleGuestSocketSession
  {
    guard port != 0 else {
      throw VMError(
        .invalidConfiguration, "The guest socket destination port must be nonzero.",
        recovery: "Use the guest agent's configured listener port.")
    }
    let attempt = AppleGuestSocketConnectAttempt()
    let session = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if attempt.begin(continuation) {
          connector(port) { attempt.finish($0) }
        }
      }
    } onCancel: {
      Task { @MainActor in attempt.cancel() }
    }
    do { try Task.checkCancellation() } catch {
      session.close()
      throw error
    }
    return session
  }

  /// The descriptor is borrowed only for this operation; do not close it or retain its integer.
  /// The owner remains alive across suspension and cancellation. Cancellation requests close,
  /// but close waits for the operation to return and does not interrupt arbitrary descriptor I/O.
  public func withFileDescriptor<T>(
    _ operation: @MainActor (Int32) async throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    guard !closeRequested, let connection, connection.fileDescriptor >= 0 else {
      throw VMError(
        .invalidTransition, "The guest socket session is closed.",
        recovery: "Create a new connection after the previous operation has settled.")
    }
    borrowers += 1
    defer {
      borrowers -= 1
      if Task.isCancelled { closeRequested = true }
      finishCloseIfPossible()
      withExtendedLifetime(connection) {}
    }
    let result = try await withTaskCancellationHandler {
      try await operation(connection.fileDescriptor)
    } onCancel: {
      Task { @MainActor in self.close() }
    }
    try Task.checkCancellation()
    return result
  }

  /// Idempotently requests native close. Existing descriptor borrows retain the connection until
  /// they return, preventing closure and descriptor reuse while an operation is suspended.
  public func close() {
    closeRequested = true
    finishCloseIfPossible()
  }

  private func finishCloseIfPossible() {
    guard closeRequested, borrowers == 0 else { return }
    connection?.close()
    connection = nil
  }
}

@MainActor
private final class AppleGuestSocketConnectAttempt {
  private var continuation: CheckedContinuation<AppleGuestSocketSession, any Error>?
  private var finished = false

  func begin(_ continuation: CheckedContinuation<AppleGuestSocketSession, any Error>) -> Bool {
    guard !finished else {
      continuation.resume(throwing: CancellationError())
      return false
    }
    self.continuation = continuation
    return true
  }

  func finish(_ result: Result<any AppleGuestSocketConnection, any Error>) {
    guard !finished, let continuation else {
      if case .success(let connection) = result { connection.close() }
      return
    }
    finished = true
    self.continuation = nil
    switch result {
    case .success(let connection):
      continuation.resume(returning: AppleGuestSocketSession(connection: connection))
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }

  func cancel() {
    guard !finished else { return }
    finished = true
    let pending = continuation
    continuation = nil
    pending?.resume(throwing: CancellationError())
  }
}
