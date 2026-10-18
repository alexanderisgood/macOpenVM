// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation

public enum LeaseSpawnError: Error, Equatable, Sendable {
  case invalidConfiguration, invalidDescriptor, tooManyWaiters, observationUnavailable
  case descriptorFailure(Int32)
  case spawnFailure(Int32)
  case waitFailure(Int32)
  case signalFailure(Int32)
}

/// An explicit 64-bit Darwin/macOS 14 process boundary. This proves descriptor inheritance;
/// it does not prove that a particular third-party executable retains its inherited lease.
public enum LeaseSpawn {
  public struct DescriptorMapping: Sendable {
    public let source: Int32
    public let target: Int32
    public init(source: Int32, target: Int32) {
      self.source = source
      self.target = target
    }
  }

  public struct Configuration: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public let standardInput: Int32
    public let standardOutput: Int32
    public let standardError: Int32
    public let inheritedDescriptors: [DescriptorMapping]

    public init(
      executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
      standardInput: Int32, standardOutput: Int32, standardError: Int32,
      inheritedDescriptors: [DescriptorMapping]
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory
      self.standardInput = standardInput
      self.standardOutput = standardOutput
      self.standardError = standardError
      self.inheritedDescriptors = inheritedDescriptors
    }
  }

  public struct Exit: Equatable, Sendable {
    public let status: Int32
    public let wasSignalled: Bool
  }

  /// The caller keeps every source descriptor valid and exclusively owned until spawn returns.
  /// Sources are duplicated, never modified/closed/unlocked by this helper. The child alone owns
  /// its mapped copies; nobody else may reap this child with wait/waitpid.
  public static func spawn(configuration: Configuration) async throws -> Child {
    try await executor.spawn(configuration)
  }

  /// Internal test timing control; normal public launches always use the standard monitor.
  enum ObservationTestMode: Sendable {
    case standard
    case delayedRegistration(Duration)
    case omittedRegistration(deadline: Duration)
    case shortExitReconciliation(deadline: Duration)
  }

  static func spawnForObservationTest(
    configuration: Configuration, mode: ObservationTestMode
  ) async throws -> Child {
    try await executor.spawn(configuration, observationMode: mode)
  }

  private static let executor = SpawnExecutor()

  /// All waitpid and signal operations are serialized here. A PID cannot be reused before
  /// this actor reaps its child, and the reaped/uncertain state is stored before another call.
  public actor Child {
    public nonisolated let pid: Int32
    private var result: Result<Exit, LeaseSpawnError>?
    private let observationMode: ObservationTestMode
    private var exitSource: (any DispatchSourceProcess)?
    private var delayedRegistration: Task<Void, Never>?
    private var registrationDeadline: Task<Void, Never>?
    private var exitRetry: Task<Void, Never>?
    private var monitoringStarted = false
    private var registered = false
    private var exitHintSeen = false
    private var observationFault: LeaseSpawnError?
    private var waitpidCalls = 0
    private var sourceActivations = 0
    private var exitHints = 0
    private var signals = 0
    private var waiters: [UUID: CheckedContinuation<Exit, any Error>] = [:]

    fileprivate init(pid: Int32, observationMode: ObservationTestMode) {
      self.pid = pid
      self.observationMode = observationMode
    }

    fileprivate func startMonitoring() {
      guard !monitoringStarted else { return }
      monitoringStarted = true
      if case .delayedRegistration(let delay) = observationMode {
        delayedRegistration = Task { [self] in
          do { try await Task.sleep(for: delay) } catch { return }
          installExitSource()
        }
      } else {
        installExitSource()
      }
    }

    public func wait() async throws -> Exit {
      try Task.checkCancellation()
      // After a monitor fault, explicit owner recovery can make one fresh observation.
      // This is never a lifetime poll and never infers exit from source data or timeout.
      if result == nil, observationFault != nil { _ = observeOnce() }
      if let result { return try result.get() }
      guard waiters.count < 64 else { throw LeaseSpawnError.tooManyWaiters }
      let id = UUID()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          // Cancellation can arrive before this registration closure is entered. Checking
          // again here prevents its earlier cancellation hop from losing the continuation.
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else if let result {
            switch result {
            case .success(let exit): continuation.resume(returning: exit)
            case .failure(let error): continuation.resume(throwing: error)
            }
          } else {
            waiters[id] = continuation
          }
        }
      } onCancel: {
        Task { await self.cancelWaiter(id) }
      }
    }

    /// Explicit owner action only. There is no signal on cancellation, disconnect or deinit.
    public func terminate() throws {
      try sendOwnedSignal(SIGTERM)
    }

    /// Explicit destructive action for the registered child only; never an automatic fallback.
    public func forceKill() throws {
      try sendOwnedSignal(SIGKILL)
    }

    private func sendOwnedSignal(_ signal: Int32) throws {
      // Reconcile before an explicit signal, including after an observation-registration
      // fault. Zero still identifies our unreaped child; ECHILD is never signal permission.
      if result == nil { _ = observeOnce() }
      if let result {
        if case .failure(let error) = result { throw error }
        return
      }
      // No await between state check and kill. Only this actor can reap the registered child.
      // An already-exited, unreaped child still reserves its PID; ESRCH is left to waitpid.
      signals += 1
      if Darwin.kill(pid, signal) != 0, errno != ESRCH {
        throw LeaseSpawnError.signalFailure(errno)
      }
      if observationFault != nil { scheduleBoundedReconciliation() }
    }

    private func cancelWaiter(_ id: UUID) {
      waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func installExitSource() {
      guard result == nil, exitSource == nil else { return }
      delayedRegistration = nil
      let source = DispatchSource.makeProcessSource(
        identifier: pid, eventMask: .exit,
        queue: DispatchQueue(label: "local.macOpenVM.child-exit", qos: .userInitiated))
      // Strong handler custody keeps this child/source alive after callers or waiters leave.
      // The cycle is broken only by observed terminal state or actual waitpid ownership loss.
      source.setEventHandler(handler: makeExitBridge())
      source.setRegistrationHandler(handler: makeRegistrationBridge())
      exitSource = source
      sourceActivations += 1
      source.activate()
      let duration: Duration
      if case .omittedRegistration(let deadline) = observationMode {
        duration = deadline
      } else {
        duration = .seconds(2)
      }
      registrationDeadline = Task { [self] in
        do { try await Task.sleep(for: duration) } catch { return }
        registrationExpired()
      }
      // Covers a child already exited before dispatch registration. Reaping always stores
      // result before canceling the source, so any late handler cannot touch a reused PID.
      _ = observeOnce()
    }

    /// Dispatch's block-typed handler API must not infer this actor's outer callback isolation.
    /// Only the explicitly Sendable, nonisolated bridge runs on its queue; observation hops back.
    private nonisolated func makeExitBridge() -> @Sendable () -> Void {
      { [self] in Task { await self.receivedExitHint() } }
    }

    private nonisolated func makeRegistrationBridge() -> @Sendable () -> Void {
      { [self] in Task { await self.sourceRegistered() } }
    }

    private func sourceRegistered() {
      guard result == nil else { return }
      if case .omittedRegistration = observationMode { return }
      registered = true
      registrationDeadline?.cancel()
      registrationDeadline = nil
      if !observeOnce(), exitHintSeen { scheduleExitReconciliation() }
    }

    private func receivedExitHint() {
      guard result == nil else { return }
      // Internal fault injection omits notification delivery, not actual child execution.
      // Explicit owner reconciliation must recover without a normal exit callback helping it.
      if case .omittedRegistration = observationMode { return }
      if !exitHintSeen {
        exitHintSeen = true
        exitHints += 1
      } else if observationFault == nil {
        return
      }
      // An actual notification is also evidence that this source registered, even if its
      // registration-handler actor hop is delayed. It is never terminal-status evidence.
      registered = true
      registrationDeadline?.cancel()
      registrationDeadline = nil
      if !observeOnce() { scheduleExitReconciliation() }
    }

    private func scheduleExitReconciliation() {
      guard exitHintSeen else { return }
      scheduleBoundedReconciliation()
    }

    private func scheduleBoundedReconciliation() {
      guard result == nil, exitRetry == nil else { return }
      // XNU NOTE_EXIT may precede SZOMB/waitpid readiness. Only that one hint authorizes
      // these bounded short retries. Explicit owner signals after a notification fault also
      // authorize one such reconciliation; a living idle child has no repeating task.
      exitRetry = Task { [self] in
        let budget: Duration
        if case .shortExitReconciliation(let deadline) = observationMode {
          budget = deadline
        } else {
          budget = .seconds(5)
        }
        let deadline = ContinuousClock.now.advanced(by: budget)
        var delay = 5
        while ContinuousClock.now < deadline {
          do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
          guard result == nil else { return }
          if observeOnce() { return }
          delay = min(50, delay * 2)
        }
        failObservation()
      }
    }

    private func registrationExpired() {
      guard result == nil, !registered else { return }
      if !observeOnce() { failObservation() }
    }

    /// Every authoritative observation and publication stays in one actor turn with no await.
    @discardableResult private func observeOnce() -> Bool {
      guard result == nil else { return true }
      waitpidCalls += 1
      var status: Int32 = 0
      let observed = Darwin.waitpid(pid, &status, WNOHANG)
      if observed == pid {
        let signal = status & 0x7f
        if signal == 0 {
          finish(.success(Exit(status: (status >> 8) & 0xff, wasSignalled: false)))
        } else if signal != 0x7f {
          finish(.success(Exit(status: signal, wasSignalled: true)))
        } else {
          finish(.failure(.waitFailure(EINVAL)))
        }
        return true
      }
      if observed < 0, errno != EINTR {
        // ECHILD/lost-parent evidence forbids further reaping or signaling.
        finish(.failure(.waitFailure(errno)))
        return true
      }
      return false
    }

    private func failObservation() {
      guard result == nil else { return }
      observationFault = .observationUnavailable
      registrationDeadline = nil
      exitRetry = nil
      // The child may still be live. No automatic signal, fabricated exit or lease release
      // follows. Preserve source custody and actual-status waiters for late notification or
      // bounded explicit owner reconciliation, including OwnedProcess's terminal waiter.
    }

    private func stopObservation() {
      delayedRegistration?.cancel()
      delayedRegistration = nil
      registrationDeadline?.cancel()
      registrationDeadline = nil
      exitRetry?.cancel()
      exitRetry = nil
      exitSource?.setEventHandler(handler: nil)
      exitSource?.setRegistrationHandler(handler: nil)
      exitSource?.cancel()
      exitSource = nil
    }

    private func finish(_ value: Result<Exit, LeaseSpawnError>) {
      guard result == nil else { return }
      result = value
      observationFault = nil
      stopObservation()
      let pending = waiters.values
      waiters.removeAll()
      for waiter in pending {
        switch value {
        case .success(let exit): waiter.resume(returning: exit)
        case .failure(let error): waiter.resume(throwing: error)
        }
      }
    }

    struct ObservationDiagnostics: Sendable {
      let waitpidCalls: Int
      let sourceActivations: Int
      let exitHints: Int
      let signals: Int
      let registered: Bool
      let uncertain: Bool
      let terminal: Bool
      let observing: Bool
    }

    func observationDiagnostics() -> ObservationDiagnostics {
      let terminal: Bool
      let uncertain: Bool
      switch result {
      case .success?:
        terminal = true
        uncertain = false
      case .failure?:
        terminal = false
        uncertain = true
      case nil:
        terminal = false
        uncertain = observationFault != nil
      }
      return ObservationDiagnostics(
        waitpidCalls: waitpidCalls, sourceActivations: sourceActivations, exitHints: exitHints,
        signals: signals, registered: registered, uncertain: uncertain, terminal: terminal,
        observing: exitSource != nil || delayedRegistration != nil)
    }

    /// Test-only synthetic early hint checks readiness/retry limits without inventing status.
    func receiveExitHintForObservationTest() { receivedExitHint() }
  }
}

/// Spawn preparation is off the UI actor. Every temporary is CLOEXEC and above all child
/// targets, so ordered dup actions cannot clobber another mapping's source or leak a scratch FD.
private actor SpawnExecutor {
  func spawn(
    _ configuration: LeaseSpawn.Configuration,
    observationMode: LeaseSpawn.ObservationTestMode = .standard
  ) async throws -> LeaseSpawn.Child {
    try Task.checkCancellation()
    try validate(configuration)
    let mappings =
      [
        LeaseSpawn.DescriptorMapping(source: configuration.standardInput, target: 0),
        LeaseSpawn.DescriptorMapping(source: configuration.standardOutput, target: 1),
        LeaseSpawn.DescriptorMapping(source: configuration.standardError, target: 2),
      ] + configuration.inheritedDescriptors
    let scratchMinimum = (mappings.map(\.target).max() ?? 2) + 1
    var copies: [Int32] = []
    defer { for descriptor in copies { Darwin.close(descriptor) } }
    for mapping in mappings {
      let duplicate = fcntl(mapping.source, F_DUPFD_CLOEXEC, scratchMinimum)
      guard duplicate >= 0 else { throw LeaseSpawnError.descriptorFailure(errno) }
      copies.append(duplicate)
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    var signalMask = sigset_t()
    var signalDefaults = sigset_t()
    sigemptyset(&signalMask)
    sigemptyset(&signalDefaults)
    for signal in [SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGPIPE, SIGCHLD] {
      sigaddset(&signalDefaults, signal)
    }
    try check(posix_spawnattr_setsigmask(&attributes, &signalMask))
    try check(posix_spawnattr_setsigdefault(&attributes, &signalDefaults))
    try check(
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
    let cwdCode = configuration.workingDirectory.path.withCString { path in
      if #available(macOS 26, *) {
        return posix_spawn_file_actions_addchdir(&actions, path)
      } else {
        return posix_spawn_file_actions_addchdir_np(&actions, path)
      }
    }
    try check(cwdCode)
    for (mapping, copy) in zip(mappings, copies) {
      try check(posix_spawn_file_actions_adddup2(&actions, copy, mapping.target))
      try check(posix_spawn_file_actions_addinherit_np(&actions, mapping.target))
    }
    for copy in copies { try check(posix_spawn_file_actions_addclose(&actions, copy)) }
    let argumentStrings = [configuration.executable.path] + configuration.arguments
    let environmentStrings = configuration.environment.keys.sorted().map {
      "\($0)=\(configuration.environment[$0]!)"
    }
    var arguments = try cStrings(argumentStrings)
    defer { for pointer in arguments { free(pointer) } }
    var environment = try cStrings(environmentStrings)
    defer { for pointer in environment { free(pointer) } }
    var pid: pid_t = 0
    try Task.checkCancellation()
    let code = configuration.executable.path.withCString { path in
      arguments.withUnsafeMutableBufferPointer { argv in
        environment.withUnsafeMutableBufferPointer { envp in
          posix_spawn(&pid, path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
        }
      }
    }
    try check(code)
    let child = LeaseSpawn.Child(pid: pid, observationMode: observationMode)
    await child.startMonitoring()
    // A successful spawn owns a real child even if its caller has since been cancelled.
    return child
  }

  private func validate(_ configuration: LeaseSpawn.Configuration) throws {
    guard MemoryLayout<Int>.size == 8,
      localAbsolute(configuration.executable), localAbsolute(configuration.workingDirectory),
      configuration.arguments.count <= 256,
      configuration.arguments.allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") }),
      configuration.arguments.reduce(0, { $0 + $1.utf8.count }) <= 131_072,
      configuration.environment.count <= 32,
      configuration.environment.allSatisfy({ key, value in
        !key.isEmpty && key.utf8.count <= 128 && !key.contains("=") && !key.contains("\0")
          && value.utf8.count <= 4096 && !value.contains("\0")
      }),
      configuration.environment.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count })
        <= 16_384,
      configuration.inheritedDescriptors.count <= 16,
      configuration.inheritedDescriptors.allSatisfy({ (3...1023).contains($0.target) }),
      Set(configuration.inheritedDescriptors.map(\.target)).count
        == configuration.inheritedDescriptors.count
    else { throw LeaseSpawnError.invalidConfiguration }
    let sources =
      [configuration.standardInput, configuration.standardOutput, configuration.standardError]
      + configuration.inheritedDescriptors.map(\.source)
    guard sources.allSatisfy({ $0 >= 0 && fcntl($0, F_GETFD) >= 0 }) else {
      throw LeaseSpawnError.invalidDescriptor
    }
  }

  private func localAbsolute(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.query == nil && url.fragment == nil && url.path.hasPrefix("/")
      && url.path.utf8.count <= 4096 && !url.path.contains("\0")
  }

  private func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for string in strings {
      guard let pointer = strdup(string) else {
        for allocated in pointers { free(allocated) }
        throw LeaseSpawnError.spawnFailure(ENOMEM)
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    return pointers
  }

  /// POSIX spawn APIs return their error code directly rather than setting errno.
  private func check(_ code: Int32) throws {
    guard code == 0 else { throw LeaseSpawnError.spawnFailure(code) }
  }
}
