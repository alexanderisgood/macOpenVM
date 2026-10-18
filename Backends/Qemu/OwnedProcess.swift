// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// Owns one directly launched child and its output readers. Cancellation of a waiter never
/// signals the child. The runtime owner must retain this object until `isActive` becomes false.
public actor OwnedProcess {
  public struct Configuration: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let stdoutLog: URL
    public let stderrLog: URL
    public let memoryLimitBytes: Int
    public let logLimitBytes: Int
    public let environment: [String: String]
    /// The caller retains each valid source descriptor until launch returns.
    public let inheritedDescriptors: [LeaseSpawn.DescriptorMapping]

    public init(
      executable: URL, arguments: [String], workingDirectory: URL,
      stdoutLog: URL, stderrLog: URL, environment: [String: String] = [:],
      memoryLimit: Int = 2_097_152, logLimit: Int = 2_097_152,
      inheritedDescriptors: [LeaseSpawn.DescriptorMapping] = []
    ) {
      self.executable = executable
      self.arguments = arguments
      self.workingDirectory = workingDirectory
      self.stdoutLog = stdoutLog
      self.stderrLog = stderrLog
      self.memoryLimitBytes = memoryLimit
      self.logLimitBytes = logLimit
      self.environment = environment
      self.inheritedDescriptors = inheritedDescriptors
    }
  }

  public struct Termination: Equatable, Sendable {
    public enum Reason: String, Sendable { case exit, uncaughtSignal }
    public let status: Int32
    public let reason: Reason
  }

  public struct Output: Equatable, Sendable {
    public let data: Data
    public let bytesRead: UInt64
    public let bytesLogged: Int
    public let memoryTruncated: Bool
    public let logTruncated: Bool
    public let eof: Bool
    public let finished: Bool
    public let failed: Bool
  }

  public struct Snapshot: Sendable {
    /// Callback snapshots are monotonically numbered; ordinary reads preserve that number.
    public let sequence: UInt64
    public let started: Bool
    public let isActive: Bool
    public let pid: Int32?
    public let termination: Termination?
    public let stdoutCapture: Output
    public let stderrCapture: Output
    public let firstError: VMError?
    public var running: Bool { started && termination == nil }
    public var drainsFinished: Bool {
      stdoutCapture.eof && stdoutCapture.finished && stderrCapture.eof && stderrCapture.finished
    }
    public var stdout: Data { stdoutCapture.data }
    public var stderr: Data { stderrCapture.data }
    public var outputError: VMError? { firstError }
    /// Terminal status is available before inherited output descriptors reach EOF.
    public var exit: Exit? {
      guard let termination else { return nil }
      return Exit(
        termination: termination, stdout: stdoutCapture, stderr: stderrCapture,
        firstError: firstError)
    }
  }

  public struct Exit: Sendable {
    public let termination: Termination
    public let stdout: Output
    public let stderr: Output
    public let firstError: VMError?
    public var status: Int32 { termination.status }
    public var wasSignalled: Bool { termination.reason == .uncaughtSignal }
    public var outputError: VMError? { firstError }
  }

  public enum Change: Sendable {
    case started, terminalStatus, stdoutFinished, stderrFinished, outputError, launchFailed
    case observationFailed
  }

  public typealias StateChange = @MainActor @Sendable (Snapshot) -> Void

  private let configuration: Configuration
  private let onStateChange: StateChange?
  private var process: LeaseSpawn.Child?
  private var terminalMonitor: Task<Void, Never>?
  private var stdoutReader: ProcessOutputReader?
  private var stderrReader: ProcessOutputReader?
  private var launchAttempted = false
  private var started = false
  private var termination: Termination?
  private var firstError: VMError?
  private var observationFailure: VMError?
  private var sequence: UInt64 = 0
  private var callbackTail: Task<Void, Never>?
  private var waiters: [UUID: CheckedContinuation<Exit, any Error>] = [:]

  public init(configuration: Configuration, onStateChange: StateChange? = nil) {
    self.configuration = configuration
    self.onStateChange = onStateChange
  }

  /// Process creation runs on this actor's executor, never synchronously on the UI actor.
  public func launch() async throws {
    guard !launchAttempted else {
      throw Self.failure(.invalidTransition, "This owned process has already attempted launch.")
    }
    try Task.checkCancellation()
    launchAttempted = true
    do {
      try validateConfiguration()
      let stdoutPipe = try Self.makePipe()
      let stderrPipe: (read: Int32, write: Int32)
      do { stderrPipe = try Self.makePipe() } catch {
        close(stdoutPipe.read)
        close(stdoutPipe.write)
        throw error
      }
      // The parent write ends must close even when launch or log creation fails.
      defer {
        close(stdoutPipe.write)
        close(stderrPipe.write)
      }
      do {
        stdoutReader = try ProcessOutputReader(
          readDescriptor: stdoutPipe.read, logURL: configuration.stdoutLog,
          memoryLimit: configuration.memoryLimitBytes, logLimit: configuration.logLimitBytes,
          report: { [weak self] event in
            Task { await self?.readerEvent(event, stdout: true) }
          })
      } catch {
        close(stdoutPipe.read)
        close(stderrPipe.read)
        throw error
      }
      do {
        stderrReader = try ProcessOutputReader(
          readDescriptor: stderrPipe.read, logURL: configuration.stderrLog,
          memoryLimit: configuration.memoryLimitBytes, logLimit: configuration.logLimitBytes,
          report: { [weak self] event in
            Task { await self?.readerEvent(event, stdout: false) }
          })
      } catch {
        stdoutReader?.closeBeforeStarting()
        close(stderrPipe.read)
        throw error
      }
      let child: LeaseSpawn.Child
      do {
        let nullInput = open("/dev/null", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard nullInput >= 0 else {
          throw Self.failure(.backendFailure, "The child null input could not be opened.")
        }
        defer { close(nullInput) }
        child = try await LeaseSpawn.spawn(
          configuration: .init(
            executable: configuration.executable, arguments: configuration.arguments,
            environment: try sanitizedEnvironment(),
            workingDirectory: configuration.workingDirectory,
            standardInput: nullInput, standardOutput: stdoutPipe.write,
            standardError: stderrPipe.write,
            inheritedDescriptors: configuration.inheritedDescriptors))
      } catch {
        stdoutReader?.closeBeforeStarting()
        stderrReader?.closeBeforeStarting()
        if error is CancellationError { throw error }
        throw Self.failure(.backendFailure, "The owned process could not be launched.")
      }
      process = child
      started = true
      emit(.started)
      stdoutReader?.start()
      stderrReader?.start()
      // This owned task does not inherit launch/waiter cancellation. Only Child owns waitpid.
      terminalMonitor = Task { [weak self, child] in
        do {
          let exit = try await child.wait()
          await self?.didTerminate(
            Termination(
              status: exit.status, reason: exit.wasSignalled ? .uncaughtSignal : .exit))
        } catch {
          await self?.lostTerminalObservation()
        }
      }
      // No cancellation check here: a successful spawn owns a real child. Its owner receives
      // the started state and decides what to do; cancellation is never force-stop permission.
    } catch {
      let failure =
        (error as? VMError)
        ?? Self.failure(
          error is CancellationError ? .cancelled : .backendFailure,
          error is CancellationError ? "Process launch was cancelled." : "Process launch failed.")
      firstError = firstError ?? failure
      emit(.launchFailed)
      if error is CancellationError { throw error }
      throw failure
    }
  }

  public func snapshot() -> Snapshot {
    let stdout = stdoutReader?.snapshot() ?? Self.emptyOutput
    let stderr = stderrReader?.snapshot() ?? Self.emptyOutput
    return Snapshot(
      sequence: sequence, started: started,
      isActive: started
        && !(termination != nil && stdout.eof && stdout.finished && stderr.eof && stderr.finished),
      pid: started ? process?.pid : nil,
      termination: termination, stdoutCapture: stdout, stderrCapture: stderr,
      firstError: firstError
        ?? ((stdout.failed || stderr.failed)
          ? Self.failure(.storage, "Process output could not be fully saved or read.") : nil))
  }

  /// A cancelled waiter is removed; the process and both drain workers continue independently.
  public func wait() async throws -> Exit {
    try Task.checkCancellation()
    guard started else {
      throw Self.failure(.invalidTransition, "No launched process is available to wait for.")
    }
    if let observationFailure { throw observationFailure }
    if let result = completedExit() { return result }
    guard waiters.count < 64 else {
      throw Self.failure(.busy, "Too many process waiters are registered.")
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if let observationFailure {
          continuation.resume(throwing: observationFailure)
        } else {
          waiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  /// Signals only this registered Child, never a stored PID or process group.
  /// It does not release ownership; `wait()` still requires actual terminal status and both EOFs.
  public func terminate() async throws {
    guard let process, started else {
      throw Self.failure(.invalidTransition, "No launched process can be terminated.")
    }
    guard termination == nil else { return }
    try await process.terminate()
  }

  /// Explicit registered-child fault/recovery action only. Terminal status and finished EOF
  /// drains still govern completion; cancellation and deinit never invoke this operation.
  public func forceKill() async throws {
    guard let process, started else {
      throw Self.failure(.invalidTransition, "No launched process can be force killed.")
    }
    guard termination == nil else { return }
    try await process.forceKill()
  }

  private func didTerminate(_ result: Termination) {
    guard termination == nil, started else { return }
    termination = result
    terminalMonitor = nil
    emit(.terminalStatus)
    finishWaitersIfReady()
  }

  private func lostTerminalObservation() {
    guard termination == nil, observationFailure == nil else { return }
    let error = Self.failure(
      .backendFailure, "The owned child's terminal status could not be observed.")
    observationFailure = error
    firstError = firstError ?? error
    terminalMonitor = nil
    emit(.observationFailed)
    let pending = waiters.values
    waiters.removeAll()
    for waiter in pending { waiter.resume(throwing: error) }
    // No terminal status is fabricated: ownership stays active even if output has reached EOF.
  }

  private func readerEvent(_ event: ProcessOutputReader.Event, stdout: Bool) {
    switch event {
    case .failure:
      guard firstError == nil else { return }
      firstError = Self.failure(.storage, "Process output could not be fully saved or read.")
      emit(.outputError)
    case .finished:
      emit(stdout ? .stdoutFinished : .stderrFinished)
      finishWaitersIfReady()
    }
  }

  private func completedExit() -> Exit? {
    let state = snapshot()
    guard let termination = state.termination, state.drainsFinished else { return nil }
    return Exit(
      termination: termination, stdout: state.stdoutCapture, stderr: state.stderrCapture,
      firstError: state.firstError)
  }

  private func finishWaitersIfReady() {
    guard let result = completedExit() else { return }
    let pending = waiters.values
    waiters.removeAll()
    for continuation in pending { continuation.resume(returning: result) }
  }

  private func cancelWaiter(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  private func emit(_ change: Change) {
    sequence += 1
    guard let onStateChange else { return }
    let state = snapshot()
    let previous = callbackTail
    // At most launch, terminal status, two reader completions and one first error are queued.
    // Chaining these few callbacks preserves their actor-observed order without chunk tasks.
    callbackTail = Task {
      if let previous { await previous.value }
      await onStateChange(state)
    }
  }

  private func validateConfiguration() throws {
    guard Self.isLocalAbsolute(configuration.executable),
      Self.isLocalAbsolute(configuration.workingDirectory),
      Self.isLocalAbsolute(configuration.stdoutLog), Self.isLocalAbsolute(configuration.stderrLog),
      configuration.stdoutLog.standardizedFileURL != configuration.stderrLog.standardizedFileURL,
      (0...4_194_304).contains(configuration.memoryLimitBytes),
      (0...16_777_216).contains(configuration.logLimitBytes),
      configuration.arguments.count <= 256,
      configuration.arguments.allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") }),
      configuration.arguments.reduce(0, { $0 + $1.utf8.count }) <= 131_072,
      configuration.inheritedDescriptors.count <= 16,
      configuration.inheritedDescriptors.allSatisfy({
        (3...1023).contains($0.target) && $0.source >= 0 && fcntl($0.source, F_GETFD) >= 0
      }),
      Set(configuration.inheritedDescriptors.map(\.target)).count
        == configuration.inheritedDescriptors.count
    else {
      throw Self.failure(.invalidConfiguration, "Owned process configuration exceeds its bounds.")
    }
    _ = try sanitizedEnvironment()
  }

  private func sanitizedEnvironment() throws -> [String: String] {
    let allowed: Set<String> = ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"]
    guard
      configuration.environment.allSatisfy({ key, value in
        allowed.contains(key) && value.utf8.count <= 4096 && !value.contains("\0")
      })
    else {
      throw Self.failure(
        .invalidConfiguration, "The child environment contains unsupported values.")
    }
    var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
    for (key, value) in configuration.environment { result[key] = value }
    return result
  }

  private static func isLocalAbsolute(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.path.hasPrefix("/") && url.path.utf8.count <= 4096 && !url.path.contains("\0")
  }

  private static func makePipe() throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
      throw failure(.backendFailure, "The child output pipe could not be created.")
    }
    guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0
    else {
      close(descriptors[0])
      close(descriptors[1])
      throw failure(.backendFailure, "The child output pipe could not be configured.")
    }
    return (descriptors[0], descriptors[1])
  }

  private static var emptyOutput: Output {
    Output(
      data: Data(), bytesRead: 0, bytesLogged: 0, memoryTruncated: false,
      logTruncated: false, eof: false, finished: false, failed: false)
  }

  private static func failure(_ code: VMError.Code, _ message: String) -> VMError {
    VMError(
      code, message,
      recovery:
        "Preserve private process logs. Process ownership remains until terminal status and output EOF."
    )
  }
}

/// The two descriptors belong solely to one dedicated blocking reader thread after `start`.
/// Only the capped snapshot is shared, and every access to it is protected by `lock`.
/// This narrowly scoped unchecked conformance avoids sending Foundation handles or per-chunk
/// work across actors; no process state, lifecycle decision or child signaling lives here.
private final class ProcessOutputReader: @unchecked Sendable {
  enum Event: Sendable { case failure, finished }
  private let readDescriptor: Int32
  private let logDescriptor: Int32
  private let memoryLimit: Int
  private let logLimit: Int
  private let report: @Sendable (Event) -> Void
  private let lock = NSLock()
  private var data = Data()
  private var bytesRead: UInt64 = 0
  private var bytesLogged = 0
  private var memoryTruncated = false
  private var logTruncated = false
  private var eof = false
  private var finished = false
  private var failed = false

  init(
    readDescriptor: Int32, logURL: URL, memoryLimit: Int, logLimit: Int,
    report: @escaping @Sendable (Event) -> Void
  ) throws {
    let fd = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw VMError(
        .storage, "A private exclusive process log could not be created.",
        recovery: "Choose new private log paths; existing logs are never replaced.")
    }
    guard fchmod(fd, 0o600) == 0 else {
      close(fd)
      throw VMError(
        .storage, "Private process log permissions could not be set.",
        recovery: "Preserve the new log and review its directory permissions.")
    }
    self.readDescriptor = readDescriptor
    logDescriptor = fd
    self.memoryLimit = memoryLimit
    self.logLimit = logLimit
    self.report = report
  }

  func start() {
    Thread.detachNewThread { [self] in drain() }
  }

  /// Used only by the owner before any reader thread is started.
  func closeBeforeStarting() {
    close(readDescriptor)
    close(logDescriptor)
  }

  func snapshot() -> OwnedProcess.Output {
    lock.lock()
    defer { lock.unlock() }
    return OwnedProcess.Output(
      data: data, bytesRead: bytesRead, bytesLogged: bytesLogged,
      memoryTruncated: memoryTruncated, logTruncated: logTruncated, eof: eof,
      finished: finished, failed: failed)
  }

  private func drain() {
    defer {
      close(readDescriptor)
      close(logDescriptor)
      lock.lock()
      finished = true
      lock.unlock()
      report(.finished)
    }
    var buffer = [UInt8](repeating: 0, count: 8192)
    var logFailed = false
    var errorReported = false
    var logged = 0
    func reportFirstError() {
      guard !errorReported else { return }
      errorReported = true
      lock.lock()
      failed = true
      lock.unlock()
      report(.failure)
    }
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(readDescriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0 {
        if errno == EINTR { continue }
        reportFirstError()
        return
      }
      if count == 0 {
        lock.lock()
        eof = true
        lock.unlock()
        return
      }
      lock.lock()
      let (next, overflow) = bytesRead.addingReportingOverflow(UInt64(count))
      bytesRead = overflow ? UInt64.max : next
      let retained = min(count, memoryLimit - data.count)
      if retained > 0 { data.append(contentsOf: buffer.prefix(retained)) }
      if retained < count { memoryTruncated = true }
      if count > logLimit - logged { logTruncated = true }
      lock.unlock()
      if !logFailed {
        let length = min(count, logLimit - logged)
        var offset = 0
        while offset < length {
          let written = buffer.withUnsafeBytes { bytes in
            Darwin.write(logDescriptor, bytes.baseAddress?.advanced(by: offset), length - offset)
          }
          if written < 0 && errno == EINTR { continue }
          if written <= 0 {
            logFailed = true
            reportFirstError()
            break
          }
          offset += written
          logged += written
        }
        lock.lock()
        bytesLogged = logged
        lock.unlock()
      }
      // A full or failed log is never a reason to stop draining the child's pipe.
    }
  }
}
