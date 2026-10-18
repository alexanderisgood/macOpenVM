// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing

@testable import Qemu

private enum LeaseFixtureError: Error {
  case posix(Int32)
  case notReady, unsettled
}

/// Fresh fake children deliberately retain a mapped lease. No QEMU/swtpm retention is inferred.
@Suite(.serialized) struct LeaseSpawnTests {
  @Test func parentCloseDoesNotReleaseChildsLeaseAndExitDoes() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let flags = fcntl(lease, F_GETFD)
      let child = try await fixture.spawnFake(source: lease)
      try child.awaitReady()
      #expect(fcntl(lease, F_GETFD) == flags && flags & FD_CLOEXEC != 0)
      fixture.closeDescriptor(lease)
      #expect(try fixture.anotherWriterIsBusy())
      try child.release()
      try await expectSuccess(child.process)
      #expect(try !fixture.anotherWriterIsBusy())
    }
  }

  @Test func eitherSurvivingChildKeepsTheSameLease() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let first = try await fixture.spawnFake(source: lease)
      let second = try await fixture.spawnFake(source: lease)
      try first.awaitReady()
      try second.awaitReady()
      fixture.closeDescriptor(lease)
      #expect(try fixture.anotherWriterIsBusy())
      try first.release()
      try await expectSuccess(first.process)
      #expect(try fixture.anotherWriterIsBusy())
      try second.release()
      try await expectSuccess(second.process)
      #expect(try !fixture.anotherWriterIsBusy())
    }
  }

  @Test func unrelatedNoncloexecDescriptorAndScratchCopiesDoNotLeak() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let unrelated = try fixture.openUnrelatedFile()
      #expect(fcntl(unrelated, F_SETFD, 0) == 0)
      var info = stat()
      #expect(fstat(unrelated, &info) == 0)
      let checks =
        "\nfor fd in range(3,128):\n if fd != 40:\n  try: value=os.fstat(fd)\n  except OSError: continue\n  assert (value.st_dev,value.st_ino) not in [lease_identity, (\(info.st_dev),\(info.st_ino))]\n"
      let child = try await fixture.spawnFake(source: lease, checks: checks)
      try child.awaitReady()
      try child.release()
      try await expectSuccess(child.process)
      #expect(fcntl(unrelated, F_GETFD) == 0)
    }
  }

  @Test func sourceEqualToChildTargetIsSafelyDuplicated() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let same = try fixture.duplicate(lease, minimum: 40)
      let child = try await fixture.spawnFake(source: same, target: same)
      try child.awaitReady()
      #expect(fcntl(same, F_GETFD) & FD_CLOEXEC != 0)
      fixture.closeDescriptor(same)
      fixture.closeDescriptor(lease)
      #expect(try fixture.anotherWriterIsBusy())
      try child.release()
      try await expectSuccess(child.process)
      #expect(try !fixture.anotherWriterIsBusy())
    }
  }

  @Test func cancelledWaitDoesNotSignalChildAndOwnerCanTerminate() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let child = try await fixture.spawnFake(source: lease)
      try child.awaitReady()
      fixture.closeDescriptor(lease)
      let waiter = Task { [process = child.process] in try await process.wait() }
      waiter.cancel()
      do {
        _ = try await waiter.value
        Issue.record("Cancelled lease waiter completed without cancellation.")
      } catch { #expect(error is CancellationError) }
      #expect(try fixture.anotherWriterIsBusy())
      try await child.process.terminate()
      let exit = try await child.process.wait()
      #expect(exit.wasSignalled && exit.status == SIGTERM)
      #expect(try !fixture.anotherWriterIsBusy())
      // A terminate after reaping is a no-op, never a signal to a recycled PID.
      try await child.process.terminate()
    }
  }

  @Test func explicitForceKillObservesSignalAndSurvivorKeepsLease() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let first = try await fixture.spawnFake(
        source: lease, checks: "\nimport signal\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
      let second = try await fixture.spawnFake(source: lease)
      try first.awaitReady()
      try second.awaitReady()
      fixture.closeDescriptor(lease)
      #expect(try fixture.anotherWriterIsBusy())
      try await first.process.terminate()
      try await first.process.forceKill()
      let exit = try await first.process.wait()
      #expect(exit.wasSignalled && exit.status == SIGKILL)
      #expect(try fixture.anotherWriterIsBusy())
      try await first.process.forceKill()
      try second.release()
      try await expectSuccess(second.process)
      #expect(try !fixture.anotherWriterIsBusy())
    }
  }

  @Test func failedSpawnPreservesCallerLeaseFlagsAndClosesScratchCopies() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let standardIO = try fixture.openUnrelatedFile()
      let leaseIdentity = try fixture.descriptorIdentity(lease)
      let flags = fcntl(lease, F_GETFD)
      let leaseCopies = try fixture.matchingDescriptors(lease)
      let standardIOCopies = try fixture.matchingDescriptors(standardIO)
      do {
        _ = try await LeaseSpawn.spawn(
          configuration: .init(
            executable: URL(fileURLWithPath: "/nonexistent/macopenvm-lease-spawn-test"),
            arguments: [], environment: [:], workingDirectory: fixture.directory,
            standardInput: standardIO, standardOutput: standardIO, standardError: standardIO,
            inheritedDescriptors: [.init(source: lease, target: 40)]))
        Issue.record("Nonexistent executable unexpectedly spawned.")
      } catch let error as LeaseSpawnError {
        #expect(error == .spawnFailure(ENOENT))
      }
      #expect(fcntl(lease, F_GETFD) == flags && flags & FD_CLOEXEC != 0)
      #expect(try fixture.matchingDescriptors(lease) == leaseCopies)
      #expect(try fixture.matchingDescriptors(standardIO) == standardIOCopies)
      #expect(try fixture.anotherWriterIsBusy())
      let closed = fixture.closeDescriptorReportingResult(lease)
      #expect(closed.tracked, "The fixture must own the lease descriptor before closing it.")
      #expect(
        closed.result == 0,
        "Darwin.close returned \(String(describing: closed.result)); failure errno \(String(describing: closed.failureErrno))."
      )
      let remainingLeaseCopies = fixture.matchingDescriptors(matching: leaseIdentity)
      #expect(
        remainingLeaseCopies.isEmpty,
        "Original lease inode still has parent descriptors in 0..<2048: \(remainingLeaseCopies.sorted())."
      )
      #expect(try !fixture.anotherWriterIsBusy())
    }
  }

  @Test(arguments: ["/usr/bin/true", "/usr/bin/false"])
  func immediateExitsReconcileWithoutLostWakeups(_ executable: String) async throws {
    try await withFixture { fixture in
      for _ in 0..<8 {
        let child = try await fixture.spawnDirect(executable: executable)
        let exit = try await child.wait()
        #expect(!exit.wasSignalled && exit.status == (executable.hasSuffix("true") ? 0 : 1))
        let diagnostics = await child.observationDiagnostics()
        #expect(diagnostics.terminal && !diagnostics.observing)
        #expect(diagnostics.sourceActivations == 1)
      }
    }
  }

  @Test func exitBeforeDelayedSourceRegistrationIsReaped() async throws {
    try await withFixture { fixture in
      let child = try await fixture.spawnDirect(
        executable: "/usr/bin/true", mode: .delayedRegistration(.milliseconds(100)))
      let before = await child.observationDiagnostics()
      #expect(before.sourceActivations == 0 && before.waitpidCalls == 0)
      try await expectSuccess(child)
      let after = await child.observationDiagnostics()
      #expect(after.sourceActivations == 1 && after.terminal && !after.observing)
    }
  }

  @Test func normalExitUsesOneNotification() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let child = try await fixture.spawnFake(source: lease)
      try child.awaitReady()
      try await awaitRegistration(child.process)
      try child.release()
      try await expectSuccess(child.process)
      let diagnostics = await child.process.observationDiagnostics()
      #expect(diagnostics.exitHints == 1 && diagnostics.sourceActivations == 1)
      #expect(diagnostics.terminal && !diagnostics.observing)
    }
  }

  @Test func idleAndCancelledWaitHaveNoRepeatingObservations() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let child = try await fixture.spawnFake(source: lease)
      try child.awaitReady()
      try await awaitRegistration(child.process)
      let before = await child.process.observationDiagnostics()
      let waiter = Task { [process = child.process] in try await process.wait() }
      waiter.cancel()
      do {
        _ = try await waiter.value
        Issue.record("Cancelled observation waiter succeeded.")
      } catch { #expect(error is CancellationError) }
      try await Task.sleep(for: .milliseconds(250))
      let after = await child.process.observationDiagnostics()
      #expect(after.waitpidCalls == before.waitpidCalls)
      #expect(after.observing && after.registered && !after.terminal && !after.uncertain)
      #expect(after.signals == 0 && after.exitHints == 0 && after.sourceActivations == 1)
      try child.release()
      try await expectSuccess(child.process)
    }
  }

  @Test func registrationFaultKeepsPendingWaiterAndExplicitRecoveryWorks() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let child = try await fixture.spawnFake(
        source: lease, mode: .omittedRegistration(deadline: .milliseconds(50)))
      try child.awaitReady()
      fixture.closeDescriptor(lease)
      let waiter = Task { [process = child.process] in try await process.wait() }
      try await awaitUncertainty(child.process)
      let fault = await child.process.observationDiagnostics()
      #expect(fault.uncertain && !fault.terminal && fault.observing && fault.signals == 0)
      #expect(try fixture.anotherWriterIsBusy())
      try await child.process.forceKill()
      let exit = try await waiter.value
      #expect(exit.wasSignalled && exit.status == SIGKILL)
      #expect(try !fixture.anotherWriterIsBusy())
      let recovered = await child.process.observationDiagnostics()
      #expect(recovered.terminal && recovered.exitHints == 0)
    }
  }

  @Test func earlyExitHintsHaveDeduplicatedBoundedRetries() async throws {
    try await withFixture { fixture in
      let lease = try fixture.acquireLease()
      let child = try await fixture.spawnFake(
        source: lease, mode: .shortExitReconciliation(deadline: .milliseconds(100)))
      try child.awaitReady()
      try await awaitRegistration(child.process)
      let before = await child.process.observationDiagnostics()
      await child.process.receiveExitHintForObservationTest()
      await child.process.receiveExitHintForObservationTest()
      try await awaitUncertainty(child.process)
      let fault = await child.process.observationDiagnostics()
      #expect(fault.exitHints == 1 && fault.waitpidCalls <= before.waitpidCalls + 9)
      #expect(fault.uncertain && !fault.terminal && fault.observing && fault.signals == 0)
      let waitCalls = fault.waitpidCalls
      try await Task.sleep(for: .milliseconds(75))
      #expect((await child.process.observationDiagnostics()).waitpidCalls == waitCalls)
      try await child.process.forceKill()
      let exit = try await child.process.wait()
      #expect(exit.wasSignalled && exit.status == SIGKILL)
    }
  }

  @Test func sourceCustodySurvivesCallerOwnerLoss() async throws {
    try await withFixture { fixture in
      let gate = try fixture.makeGate()
      var owner: LeaseSpawn.Child? = try await fixture.spawnDirect(
        executable: "/usr/bin/python3", arguments: ["-c", "import os; os.read(0,1)"],
        standardInput: gate.read)
      fixture.closeDescriptor(gate.read)
      try await awaitRegistration(try #require(owner))
      let witness = WeakLeaseChildOwner(owner)
      fixture.unregister(try #require(owner))
      withExtendedLifetime(owner) {}
      owner = nil
      try await Task.sleep(for: .milliseconds(50))
      let rescued = try #require(witness.value)
      fixture.register(rescued)
      #expect((await rescued.observationDiagnostics()).observing)
      var release: UInt8 = 1
      #expect(Darwin.write(gate.write, &release, 1) == 1)
      fixture.closeDescriptor(gate.write)
      try await expectSuccess(rescued)
      #expect(!(await rescued.observationDiagnostics()).observing)
    }
  }

  @Test func postReapForceKillDoesNotObserveOrSignalAgain() async throws {
    try await withFixture { fixture in
      let child = try await fixture.spawnDirect(executable: "/usr/bin/true")
      try await expectSuccess(child)
      let before = await child.observationDiagnostics()
      try await child.forceKill()
      try await child.terminate()
      let after = await child.observationDiagnostics()
      #expect(after.signals == before.signals && after.waitpidCalls == before.waitpidCalls)
      #expect(after.terminal && !after.observing)
    }
  }

  private func awaitRegistration(_ child: LeaseSpawn.Child) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      if await child.observationDiagnostics().registered { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw LeaseFixtureError.unsettled
  }

  private func awaitUncertainty(_ child: LeaseSpawn.Child) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      if await child.observationDiagnostics().uncertain { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw LeaseFixtureError.unsettled
  }

  private func expectSuccess(_ child: LeaseSpawn.Child) async throws {
    let exit = try await child.wait()
    #expect(exit.status == 0 && !exit.wasSignalled)
  }

  /// Cleanup is awaited even after test failure, and runs independently of test cancellation.
  /// Only actual settlement permits fixture removal; failed/uncertain fixtures stay private.
  private func withFixture(_ operation: (LeaseFixture) async throws -> Void) async throws {
    let fixture = try LeaseFixture()
    do {
      try await operation(fixture)
    } catch {
      _ = await fixture.settle(preserve: true)
      throw error
    }
    guard await fixture.settle(preserve: false) else {
      throw LeaseFixtureError.unsettled
    }
  }
}

/// Scoped to one serialized test task; raw parent descriptors are never transferred between tasks.
private final class LeaseFixture {
  let directory: URL
  private var descriptors: Set<Int32> = []
  private var children: [LeaseFakeChild] = []
  private var directChildren: [LeaseSpawn.Child] = []
  private var unregisteredOwners: [WeakLeaseChildOwner] = []

  init() throws {
    directory = URL(fileURLWithPath: "/private/tmp/mvo-lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }

  deinit { for descriptor in descriptors { Darwin.close(descriptor) } }

  func acquireLease() throws -> Int32 {
    let descriptor = Darwin.open(
      directory.appendingPathComponent("writer.lock").path,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw LeaseFixtureError.posix(errno) }
    descriptors.insert(descriptor)
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw LeaseFixtureError.posix(errno)
    }
    return descriptor
  }

  func closeDescriptor(_ descriptor: Int32) {
    guard descriptors.remove(descriptor) != nil else { return }
    Darwin.close(descriptor)
  }

  /// Report the actual close once; errno is meaningful only when that call fails.
  /// An untracked descriptor is never closed, and no retry or unlock masks the result.
  func closeDescriptorReportingResult(_ descriptor: Int32)
    -> (tracked: Bool, result: Int32?, failureErrno: Int32?)
  {
    guard descriptors.remove(descriptor) != nil else { return (false, nil, nil) }
    let result = Darwin.close(descriptor)
    let failureErrno: Int32? = result == 0 ? nil : errno
    return (true, result, failureErrno)
  }

  func duplicate(_ source: Int32, minimum: Int32) throws -> Int32 {
    let descriptor = fcntl(source, F_DUPFD_CLOEXEC, minimum)
    guard descriptor >= 0 else { throw LeaseFixtureError.posix(errno) }
    descriptors.insert(descriptor)
    return descriptor
  }

  func openUnrelatedFile() throws -> Int32 {
    let descriptor = Darwin.open(
      directory.appendingPathComponent("unrelated.bin").path,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw LeaseFixtureError.posix(errno) }
    descriptors.insert(descriptor)
    return descriptor
  }

  func openNull() throws -> Int32 {
    let descriptor = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { throw LeaseFixtureError.posix(errno) }
    descriptors.insert(descriptor)
    return descriptor
  }

  func anotherWriterIsBusy() throws -> Bool {
    let descriptor = Darwin.open(
      directory.appendingPathComponent("writer.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw LeaseFixtureError.posix(errno) }
    defer { Darwin.close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return false }
    guard errno == EWOULDBLOCK else { throw LeaseFixtureError.posix(errno) }
    return true
  }

  func descriptorIdentity(_ descriptor: Int32) throws -> stat {
    var identity = stat()
    guard fstat(descriptor, &identity) == 0 else { throw LeaseFixtureError.posix(errno) }
    return identity
  }

  /// Keep the existing bounded scan; the saved identity is also usable after close.
  func matchingDescriptors(_ descriptor: Int32) throws -> Set<Int32> {
    matchingDescriptors(matching: try descriptorIdentity(descriptor))
  }

  func matchingDescriptors(matching expected: stat) -> Set<Int32> {
    Set(
      (Int32(0)..<2048).filter { candidate in
        var actual = stat()
        return fstat(candidate, &actual) == 0 && actual.st_dev == expected.st_dev
          && actual.st_ino == expected.st_ino
      })
  }

  func register(_ child: LeaseSpawn.Child) {
    directChildren.append(child)
    unregisteredOwners.removeAll { $0.value === child }
  }

  func unregister(_ child: LeaseSpawn.Child) {
    directChildren.removeAll { $0 === child }
    unregisteredOwners.append(WeakLeaseChildOwner(child))
  }

  func makeGate() throws -> (read: Int32, write: Int32) {
    var gate: [Int32] = [-1, -1]
    guard pipe(&gate) == 0 else { throw LeaseFixtureError.posix(errno) }
    guard fcntl(gate[0], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(gate[1], F_SETFD, FD_CLOEXEC) == 0
    else {
      let code = errno
      Darwin.close(gate[0])
      Darwin.close(gate[1])
      throw LeaseFixtureError.posix(code)
    }
    descriptors.formUnion(gate)
    return (gate[0], gate[1])
  }

  func spawnDirect(
    executable: String, arguments: [String] = [], mode: LeaseSpawn.ObservationTestMode = .standard,
    standardInput: Int32? = nil
  ) async throws -> LeaseSpawn.Child {
    let null = try openNull()
    let child = try await LeaseSpawn.spawnForObservationTest(
      configuration: .init(
        executable: URL(fileURLWithPath: executable), arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], workingDirectory: directory,
        standardInput: standardInput ?? null, standardOutput: null, standardError: null,
        inheritedDescriptors: []),
      mode: mode)
    register(child)
    return child
  }

  func spawnFake(
    source: Int32, target: Int32 = 40, checks: String = "",
    mode: LeaseSpawn.ObservationTestMode = .standard
  ) async throws
    -> LeaseFakeChild
  {
    var control: [Int32] = [-1, -1]
    var ready: [Int32] = [-1, -1]
    guard pipe(&control) == 0 else { throw LeaseFixtureError.posix(errno) }
    guard pipe(&ready) == 0 else {
      Darwin.close(control[0])
      Darwin.close(control[1])
      throw LeaseFixtureError.posix(errno)
    }
    let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
    guard null >= 0 else {
      for descriptor in control + ready { Darwin.close(descriptor) }
      throw LeaseFixtureError.posix(errno)
    }
    defer {
      Darwin.close(control[0])
      Darwin.close(ready[1])
      Darwin.close(null)
    }
    let program =
      "import os\nlease=os.fstat(\(target))\nlease_identity=(lease.st_dev,lease.st_ino)\nassert os.getcwd()==\(pythonLiteral(directory.path))\nassert os.environ.get('MVO_LEASE_TEST')=='explicit'\n"
      + checks
      + "\nos.write(1,b'ready')\nos.read(0,1)\nos._exit(0)\n"
    do {
      let process = try await LeaseSpawn.spawnForObservationTest(
        configuration: .init(
          executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", program],
          environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "MVO_LEASE_TEST": "explicit"],
          workingDirectory: directory, standardInput: control[0], standardOutput: ready[1],
          standardError: null, inheritedDescriptors: [.init(source: source, target: target)]),
        mode: mode)
      let child = LeaseFakeChild(process: process, control: control[1], ready: ready[0])
      children.append(child)
      return child
    } catch {
      Darwin.close(control[1])
      Darwin.close(ready[0])
      throw error
    }
  }

  func settle(preserve: Bool) async -> Bool {
    for child in children { child.closePipes() }
    // Weak obligations record ownership loss without defeating the ownerless test interval.
    // Safely rescue a live Child when possible; a missing handle stays unresolved, not exited.
    let rescued = unregisteredOwners.compactMap(\.value)
    let unresolved = rescued.count != unregisteredOwners.count
    let registered = children.map(\.process) + directChildren + rescued
    let cleanup = Task {
      var settled = true
      for process in registered {
        do {
          try await process.terminate()
          _ = try await Self.boundedWait(process)
        } catch { settled = false }
      }
      return settled
    }
    let settled = await cleanup.value
    for descriptor in Array(descriptors) { closeDescriptor(descriptor) }
    guard settled, !unresolved else { return false }
    if !preserve {
      do { try FileManager.default.removeItem(at: directory) } catch { return false }
    }
    return true
  }

  private static func boundedWait(_ process: LeaseSpawn.Child) async throws -> LeaseSpawn.Exit {
    try await withThrowingTaskGroup(of: LeaseSpawn.Exit.self) { group in
      group.addTask { try await process.wait() }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw LeaseFixtureError.unsettled
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw LeaseFixtureError.unsettled }
      return result
    }
  }

  private func pythonLiteral(_ value: String) -> String {
    "'"
      + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'") + "'"
  }
}

private final class WeakLeaseChildOwner {
  weak var value: LeaseSpawn.Child?
  init(_ value: LeaseSpawn.Child?) { self.value = value }
}

private final class LeaseFakeChild {
  let process: LeaseSpawn.Child
  private let control: FileHandle
  private let ready: FileHandle

  init(process: LeaseSpawn.Child, control: Int32, ready: Int32) {
    self.process = process
    self.control = FileHandle(fileDescriptor: control, closeOnDealloc: true)
    self.ready = FileHandle(fileDescriptor: ready, closeOnDealloc: true)
  }

  func awaitReady() throws {
    var descriptor = pollfd(fd: ready.fileDescriptor, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&descriptor, 1, 3000) > 0,
      try ready.read(upToCount: 5) == Data("ready".utf8)
    else { throw LeaseFixtureError.notReady }
  }

  func release() throws {
    try control.write(contentsOf: Data([1]))
    try control.close()
  }

  func closePipes() {
    try? control.close()
    try? ready.close()
  }
}
