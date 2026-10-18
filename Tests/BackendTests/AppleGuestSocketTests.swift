// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Testing

@testable import AppleVz

private enum SyntheticGuestSocketError: Error { case connectFailed, operationFailed }

@MainActor
private final class SocketCloseObservation {
  var calls = 0
  weak var connection: SyntheticGuestSocketConnection?
}

/// Synthetic ownership/event fixture only; it has no real descriptor or native guest.
@MainActor
private final class SyntheticGuestSocketConnection: AppleGuestSocketConnection {
  var fileDescriptor: Int32 = 41
  let sourcePort: UInt32 = 50_000
  let destinationPort: UInt32 = 4050
  let observation: SocketCloseObservation

  init(observation: SocketCloseObservation = SocketCloseObservation()) {
    self.observation = observation
  }

  func close() {
    observation.calls += 1
    fileDescriptor = -1
  }
}

@MainActor
private final class SyntheticGuestSocketConnector {
  private(set) var ports: [UInt32] = []
  private var completion: (@MainActor (Result<any AppleGuestSocketConnection, any Error>) -> Void)?
  private var entered: CheckedContinuation<Void, Never>?

  func connect(
    port: UInt32,
    completion: @escaping @MainActor (Result<any AppleGuestSocketConnection, any Error>) -> Void
  ) {
    ports.append(port)
    self.completion = completion
    entered?.resume()
    entered = nil
  }

  func waitUntilRequested() async {
    if completion == nil { await withCheckedContinuation { entered = $0 } }
  }

  func finish(_ result: Result<any AppleGuestSocketConnection, any Error>) {
    let pending = completion
    completion = nil
    pending?(result)
  }
}

@MainActor
private final class SuspendedDescriptorOperation {
  private var completion: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?

  func suspend() async {
    await withCheckedContinuation { continuation in
      completion = continuation
      entered?.resume()
      entered = nil
    }
  }

  func waitUntilEntered() async {
    if completion == nil { await withCheckedContinuation { entered = $0 } }
  }

  func finish() {
    let pending = completion
    completion = nil
    pending?.resume()
  }
}

@Suite(.serialized)
@MainActor
struct AppleGuestSocketTests {
  @Test func zeroPortAndPrecancelledTaskNeverInvokeConnector() async {
    let connector = SyntheticGuestSocketConnector()
    do {
      _ = try await AppleGuestSocketSession.connect(port: 0, using: connector.connect)
      Issue.record("A zero agent destination must reject before native invocation")
    } catch let error as VMError {
      #expect(error.code == .invalidConfiguration)
    } catch { Issue.record("Expected a configuration error") }
    #expect(connector.ports.isEmpty)

    let operation = Task {
      try await AppleGuestSocketSession.connect(port: 4050, using: connector.connect)
    }
    operation.cancel()
    do {
      _ = try await operation.value
      Issue.record("A pre-cancelled task must reject before native invocation")
    } catch { #expect(error is CancellationError) }
    #expect(connector.ports.isEmpty)
  }

  @Test func successRetainsConnectionAndExposesBorrowedMetadata() async throws {
    let connector = SyntheticGuestSocketConnector()
    let connection = SyntheticGuestSocketConnection()
    let operation = Task {
      try await AppleGuestSocketSession.connect(port: 4050, using: connector.connect)
    }
    await connector.waitUntilRequested()
    connector.finish(.success(connection))
    let session = try await operation.value
    #expect(connector.ports == [4050])
    #expect(session.sourcePort == 50_000 && session.destinationPort == 4050)
    let descriptor = try await session.withFileDescriptor { $0 }
    #expect(descriptor == 41 && connection.observation.calls == 0)
    session.close()
    session.close()
    #expect(connection.observation.calls == 1 && connection.fileDescriptor == -1)
    do {
      _ = try await session.withFileDescriptor { $0 }
      Issue.record("A closed session must not lend its descriptor")
    } catch let error as VMError { #expect(error.code == .invalidTransition) }
  }

  @Test func nativeConnectFailurePreservesErrorType() async {
    let connector = SyntheticGuestSocketConnector()
    let operation = Task {
      try await AppleGuestSocketSession.connect(port: 4050, using: connector.connect)
    }
    await connector.waitUntilRequested()
    connector.finish(.failure(SyntheticGuestSocketError.connectFailed))
    do {
      _ = try await operation.value
      Issue.record("Native connection failure must reach its waiter")
    } catch { #expect(error is SyntheticGuestSocketError) }
  }

  @Test func cancellationSettlesWaiterAndClosesLateNativeSuccess() async {
    let connector = SyntheticGuestSocketConnector()
    let operation = Task {
      try await AppleGuestSocketSession.connect(port: 4050, using: connector.connect)
    }
    await connector.waitUntilRequested()
    operation.cancel()
    do {
      _ = try await operation.value
      Issue.record("Cancellation must settle the Swift waiter without a native callback")
    } catch { #expect(error is CancellationError) }
    let connection = SyntheticGuestSocketConnection()
    connector.finish(.success(connection))
    #expect(connection.observation.calls == 1 && connection.fileDescriptor == -1)
  }

  @Test func cancellationAfterNativeSuccessClosesBeforeReturningSession() async {
    let connection = SyntheticGuestSocketConnection()
    let operation = Task {
      try await AppleGuestSocketSession.connect(port: 4050) { _, completion in
        completion(.success(connection))
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    do {
      _ = try await operation.value
      Issue.record("Cancellation before returning a native success must not leak the connection")
    } catch { #expect(error is CancellationError) }
    #expect(connection.observation.calls == 1)
  }

  @Test func explicitCloseWaitsForSuspendedBorrowAndRejectsNewBorrows() async throws {
    let connection = SyntheticGuestSocketConnection()
    let session = AppleGuestSocketSession(connection: connection)
    let suspended = SuspendedDescriptorOperation()
    let operation = Task {
      try await session.withFileDescriptor { descriptor in
        #expect(descriptor == 41)
        await suspended.suspend()
        #expect(connection.fileDescriptor == descriptor)
      }
    }
    await suspended.waitUntilEntered()
    session.close()
    #expect(connection.observation.calls == 0)
    do {
      _ = try await session.withFileDescriptor { $0 }
      Issue.record("A session closing after an existing borrow must reject new borrows")
    } catch let error as VMError { #expect(error.code == .invalidTransition) }
    suspended.finish()
    try await operation.value
    #expect(connection.observation.calls == 1)
  }

  @Test func cancelledBorrowRetainsOwnerUntilOperationReturns() async {
    let observation = SocketCloseObservation()
    var connection: SyntheticGuestSocketConnection? = SyntheticGuestSocketConnection(
      observation: observation)
    observation.connection = connection
    var session: AppleGuestSocketSession? = AppleGuestSocketSession(connection: connection!)
    connection = nil
    let suspended = SuspendedDescriptorOperation()
    var operation: Task<Void, any Error>? = Task { [retainedSession = session!] in
      try await retainedSession.withFileDescriptor { descriptor in
        #expect(descriptor == 41)
        await suspended.suspend()
      }
    }
    session = nil
    await suspended.waitUntilEntered()
    #expect(observation.connection != nil && observation.calls == 0)
    operation?.cancel()
    #expect(observation.connection != nil && observation.calls == 0)
    suspended.finish()
    do {
      try await operation?.value
      Issue.record("A cancelled borrowed operation must return cancellation")
    } catch { #expect(error is CancellationError) }
    operation = nil
    #expect(observation.calls == 1 && observation.connection == nil)
  }

  @Test func operationFailureKeepsOwnerUntilExplicitClose() async {
    let connection = SyntheticGuestSocketConnection()
    let session = AppleGuestSocketSession(connection: connection)
    do {
      try await session.withFileDescriptor { _ in
        throw SyntheticGuestSocketError.operationFailed
      }
      Issue.record("A descriptor operation failure must reach its caller")
    } catch { #expect(error is SyntheticGuestSocketError) }
    #expect(connection.observation.calls == 0)
    session.close()
    #expect(connection.observation.calls == 1)
  }
}
