// SPDX-License-Identifier: Apache-2.0
import AppleVz
import BackendAPI
import Foundation
import VMCore
import VMStorage

/// One CLI invocation retains its actual writer through native terminal evidence,
/// relay cleanup and durable intent settlement. Caller cancellation does not cancel
/// the owned transaction or authorize a force stop.
@MainActor
enum AppleRecordedCLI {
  static func run(
    directory: URL, vmID: UUID, lock: VMLock, backend: AppleVirtualMachine,
    files: VMFiles, duration: Int,
    startRelay: (@MainActor () -> Task<Void, any Error>)? = nil
  ) async throws {
    let transaction = Task { @MainActor in
      let owner: RecordedRuntimeOwner
      do {
        // This binds the exact backend before startRelay may expose its native handle.
        owner = try await RecordedRuntimeOwner.open(
          in: directory, vmID: vmID, lock: lock, backend: backend, files: files)
      } catch {
        Self.note(
          "Recorded runtime preparation failed; actual writer ownership is retained for read-only recovery."
        )
        await RecoveryCustody(lock: lock, backend: backend, owner: nil).hold()
      }
      let terminal = TerminalSignal()
      owner.controller.onQuiescent = { terminal.complete() }
      owner.controller.onError = { error in
        Self.note(error.errorDescription ?? "Recorded lifecycle persistence failed.")
      }
      var launchFailure: (any Error)?
      var relay: Task<Void, any Error>?
      var shutdownRequest: Task<Void, Never>?
      do {
        try await owner.perform(.start)
        relay = startRelay?()
        if let elapsed = backend.lastFrameworkStartDuration {
          let parts = elapsed.components
          let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
          Self.note("vm.framework-start.completed ms=\(milliseconds) (not guest readiness)")
        }
        // Duration authorizes one normal shutdown request. It never provides stop
        // evidence and cannot bypass an outstanding native terminal callback.
        shutdownRequest = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(duration)) } catch { return }
          guard !terminal.completed, owner.controller.runtimeError == nil else { return }
          guard backend.machine.canRequestStop else {
            Self.note(
              "Awaiting the actual native terminal callback; writer ownership remains retained.")
            return
          }
          do { try await owner.perform(.stop) } catch {
            Self.note(
              "Guest shutdown request failed; actual ownership is retained for guest recovery.")
          }
        }
      } catch {
        launchFailure = error
        Self.note(
          "VM start failed; actual ownership is retained until native cleanup and durable settlement."
        )
      }

      // Only controller quiescence after its exact native callback/completions and
      // ordered writes wakes this gate. Native .state == stopped cannot wake it.
      await terminal.wait()
      shutdownRequest?.cancel()
      if let shutdownRequest { await shutdownRequest.value }
      relay?.cancel()
      if let relay {
        do { try await relay.value } catch { Self.note("mvo.host-agent.relay-settled-with-error") }
      }
      do {
        try await owner.settleOwnership()
      } catch {
        Self.note(
          "Recorded settlement failed; the actual session and writer lease remain retained for read-only recovery."
        )
        await RecoveryCustody(lock: lock, backend: backend, owner: owner).hold()
      }
      withExtendedLifetime((lock, backend, owner)) {}
      if let failure = launchFailure ?? owner.controller.runtimeError { throw failure }
    }
    try await transaction.value
  }

  private static func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  @MainActor
  private final class TerminalSignal {
    private(set) var completed = false
    private var waiter: CheckedContinuation<Void, Never>?

    func complete() {
      guard !completed else { return }
      completed = true
      let pending = waiter
      waiter = nil
      pending?.resume()
    }

    func wait() async {
      if completed { return }
      await withCheckedContinuation { waiter = $0 }
    }
  }

  /// No retry, PID reconstruction or metadata repair can consume these objects.
  /// This dormant in-memory lifetime keeps the CLI/lease alive even while inactive.
  @MainActor
  private final class RecoveryCustody {
    private let lock: VMLock
    private let backend: AppleVirtualMachine
    private let owner: RecordedRuntimeOwner?
    private var retainedLifetime: RecoveryCustody?
    private var parked: CheckedContinuation<Void, Never>?

    init(lock: VMLock, backend: AppleVirtualMachine, owner: RecordedRuntimeOwner?) {
      self.lock = lock
      self.backend = backend
      self.owner = owner
    }

    func hold() async -> Never {
      retainedLifetime = self
      while true {
        // A private never-resumed continuation has no cancellation handler that
        // can release this actual owner. No timer or native command runs here.
        await withCheckedContinuation { parked = $0 }
        withExtendedLifetime((lock, backend, owner)) {}
      }
    }
  }
}
