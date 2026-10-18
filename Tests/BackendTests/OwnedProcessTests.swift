// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Qemu
import Testing

private enum OwnedFixtureError: Error {
  case posix(Int32)
  case unsettled
}

@Suite(.serialized) struct OwnedProcessTests {
  @Test func floodDrainsBothStreamsWithinCaps() async throws {
    try await withFixture { fixture in
      let process = fixture.makeProcess(
        executable: "/usr/bin/awk",
        arguments: [
          "BEGIN { for (i = 0; i < 100000; i++) { print \"0123456789abcdef\"; print \"fedcba9876543210\" > \"/dev/stderr\" } }"
        ], memoryLimit: 4096, logLimit: 8192)
      try await process.launch()
      let result = try await process.wait()
      #expect(result.termination.status == 0)
      #expect(result.termination.reason == .exit)
      #expect(result.stdout.bytesRead == 1_700_000)
      #expect(result.stderr.bytesRead == 1_700_000)
      #expect(result.stdout.data.count == 4096)
      #expect(result.stderr.data.count == 4096)
      #expect(result.stdout.memoryTruncated && result.stderr.memoryTruncated)
      #expect(result.stdout.logTruncated && result.stderr.logTruncated)
      #expect(
        result.stdout.eof && result.stderr.eof && result.stdout.finished && result.stderr.finished)
      #expect(!(await process.snapshot()).isActive)
      for name in ["stdout.log", "stderr.log"] {
        let attributes = try FileManager.default.attributesOfItem(
          atPath: fixture.directory.appendingPathComponent(name).path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 8192)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
      }
    }
  }

  @Test func failedLaunchHasNoOwnedChildAndPreservesExclusiveLogs() async throws {
    try await withFixture { fixture in
      let process = fixture.makeProcess(
        executable: "/nonexistent/macopenvm-owned-process-test", arguments: [])
      await #expect(throws: (any Error).self) { try await process.launch() }
      let state = await process.snapshot()
      #expect(!state.started && !state.isActive)
      #expect(state.firstError != nil)
      let another = fixture.makeProcess(executable: "/bin/cat", arguments: [])
      await #expect(throws: (any Error).self) { try await another.launch() }
      #expect(!(await another.snapshot()).isActive)
      let contents = try Data(contentsOf: fixture.directory.appendingPathComponent("stdout.log"))
      #expect(contents.isEmpty)
    }
  }

  @Test func nullInputAndPipeEOFCompleteWait() async throws {
    try await withFixture { fixture in
      let process = fixture.makeProcess(executable: "/bin/cat", arguments: [])
      try await process.launch()
      let result = try await process.wait()
      #expect(result.termination.status == 0)
      #expect(result.stdout.eof && result.stderr.eof)
      #expect(result.stdout.data.isEmpty && result.stderr.data.isEmpty)
      #expect((await process.snapshot()).drainsFinished)
      #expect(!(await process.snapshot()).isActive)
    }
  }

  @Test func cancelledWaitDoesNotTerminateChild() async throws {
    try await withFixture { fixture in
      let process = fixture.makeProcess(executable: "/bin/sleep", arguments: ["5"])
      try await process.launch()
      let waiter = Task { try await process.wait() }
      waiter.cancel()
      do {
        _ = try await waiter.value
        Issue.record("Cancelled waiter completed without cancellation.")
      } catch is CancellationError {
        // Cancellation applies to this waiter only.
      }
      let state = await process.snapshot()
      #expect(state.started && state.isActive && state.termination == nil)
      try await process.terminate()
      let result = try await process.wait()
      #expect(result.termination.reason == .uncaughtSignal)
      #expect(result.stdout.eof && result.stderr.eof)
    }
  }

  @Test(
    .enabled(
      if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
      "Requires the existing system Python for a local inherited-pipe fixture."))
  func terminalStatusPrecedesInheritedPipeEOF() async throws {
    try await withFixture { fixture in
      let process = fixture.makeProcess(
        executable: "/usr/bin/python3",
        arguments: [
          "-c", "import os,time; pid=os.fork(); time.sleep(1) if pid==0 else None; os._exit(0)",
        ])
      try await process.launch()
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      var state = await process.snapshot()
      while state.termination == nil && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        state = await process.snapshot()
      }
      #expect(state.termination?.status == 0)
      #expect(state.isActive)
      #expect(!state.stdoutCapture.eof && !state.stderrCapture.eof)
      let result = try await process.wait()
      #expect(result.stdout.eof && result.stderr.eof)
      #expect(!(await process.snapshot()).isActive)
    }
  }

  @Test func inheritedLeaseSurvivesCallerCloseUntilOwnedChildExit() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let flags = fcntl(lease, F_GETFD)
      var identity = stat()
      #expect(fstat(lease, &identity) == 0)
      let process = fixture.makeProcess(
        executable: "/usr/bin/python3",
        arguments: [
          "-c",
          "import os,time; assert os.fstat(40).st_ino==\(identity.st_ino); os.write(1,b'lease-ready\\n'); time.sleep(5)",
        ], inheritedDescriptors: [.init(source: lease, target: 40)])
      try await process.launch()
      let marker = Data("lease-ready\n".utf8)
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      var state = await process.snapshot()
      while state.stdout.range(of: marker) == nil && state.running && ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
        state = await process.snapshot()
      }
      #expect(state.stdout.range(of: marker) != nil && state.running)
      #expect(fcntl(lease, F_GETFD) == flags && flags & FD_CLOEXEC != 0)
      fixture.closeDescriptor(lease)
      #expect(try fixture.anotherWriterIsBusy())
      try await process.terminate()
      let exit = try await process.wait()
      #expect(exit.wasSignalled && exit.status == SIGTERM)
      #expect((await process.snapshot()).drainsFinished)
      #expect(!(await process.snapshot()).isActive)
      #expect(try !fixture.anotherWriterIsBusy())
    }
  }

  @Test func explicitForceKillWaitsForTerminalAndFinishedDrains() async throws {
    try await withFixture { fixture in
      let process = fixture.makeProcess(
        executable: "/usr/bin/python3",
        arguments: [
          "-c",
          "import os,time,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(1,b'kill-ready\\n'); os.write(2,b'bounded-stderr\\n'); time.sleep(5)",
        ])
      try await process.launch()
      let marker = Data("kill-ready\n".utf8)
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      var state = await process.snapshot()
      while state.stdout.range(of: marker) == nil && state.running && ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
        state = await process.snapshot()
      }
      #expect(state.stdout.range(of: marker) != nil && state.running)
      try await process.terminate()
      try await process.forceKill()
      let exit = try await process.wait()
      #expect(exit.wasSignalled && exit.status == SIGKILL)
      #expect(exit.stdout.eof && exit.stdout.finished && exit.stderr.eof && exit.stderr.finished)
      #expect((await process.snapshot()).drainsFinished)
      #expect(!(await process.snapshot()).isActive)
      try await process.forceKill()
    }
  }

  private func withFixture(_ operation: (OwnedProcessFixture) async throws -> Void) async throws {
    let fixture = try OwnedProcessFixture()
    do {
      try await operation(fixture)
    } catch {
      _ = await fixture.settle(preserve: true)
      throw error
    }
    guard await fixture.settle(preserve: false) else { throw OwnedFixtureError.unsettled }
  }
}

/// One test task owns all fixture descriptors and processes until actual exit and drain settlement.
private final class OwnedProcessFixture {
  let directory: URL
  private var descriptors: Set<Int32> = []
  private var processes: [OwnedProcess] = []

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "macopenvm-owned-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }

  deinit { for descriptor in descriptors { Darwin.close(descriptor) } }

  func makeProcess(
    executable: String, arguments: [String], memoryLimit: Int = 4096, logLimit: Int = 8192,
    inheritedDescriptors: [LeaseSpawn.DescriptorMapping] = []
  ) -> OwnedProcess {
    let process = OwnedProcess(
      configuration: .init(
        executable: URL(fileURLWithPath: executable), arguments: arguments,
        workingDirectory: directory, stdoutLog: directory.appendingPathComponent("stdout.log"),
        stderrLog: directory.appendingPathComponent("stderr.log"), memoryLimit: memoryLimit,
        logLimit: logLimit, inheritedDescriptors: inheritedDescriptors))
    processes.append(process)
    return process
  }

  func acquireLease() throws -> Int32 {
    let descriptor = Darwin.open(
      directory.appendingPathComponent("writer.lock").path,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw OwnedFixtureError.posix(errno) }
    descriptors.insert(descriptor)
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw OwnedFixtureError.posix(errno) }
    return descriptor
  }

  func closeDescriptor(_ descriptor: Int32) {
    guard descriptors.remove(descriptor) != nil else { return }
    Darwin.close(descriptor)
  }

  func anotherWriterIsBusy() throws -> Bool {
    let descriptor = Darwin.open(
      directory.appendingPathComponent("writer.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw OwnedFixtureError.posix(errno) }
    defer { Darwin.close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return false }
    guard errno == EWOULDBLOCK else { throw OwnedFixtureError.posix(errno) }
    return true
  }

  func settle(preserve: Bool) async -> Bool {
    let registered = processes
    let cleanup = Task {
      var settled = true
      for process in registered {
        let before = await process.snapshot()
        guard before.started else { continue }
        do {
          if before.running { try await process.terminate() }
          _ = try await Self.boundedWait(process)
          if await process.snapshot().isActive { settled = false }
        } catch { settled = false }
      }
      return settled
    }
    let settled = await cleanup.value
    for descriptor in Array(descriptors) { closeDescriptor(descriptor) }
    guard settled else { return false }
    if !preserve {
      do { try FileManager.default.removeItem(at: directory) } catch { return false }
    }
    return true
  }

  private static func boundedWait(_ process: OwnedProcess) async throws -> OwnedProcess.Exit {
    try await withThrowingTaskGroup(of: OwnedProcess.Exit.self) { group in
      group.addTask { try await process.wait() }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw OwnedFixtureError.unsettled
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw OwnedFixtureError.unsettled }
      return result
    }
  }
}
