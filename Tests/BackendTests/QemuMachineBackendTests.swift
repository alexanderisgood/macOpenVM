// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Qemu
import Testing

private enum PairFixtureFailure: Error { case deadline, incompleteCleanup }

/// The children are ordinary existing-system Python processes, never QEMU or guests.
/// Each child owns its private AF_UNIX listener; marker files coordinate wire events.
@MainActor
final class RuntimePairFixture {
  let directory: URL
  var backend: QemuMachineBackend?
  weak var weakBackend: QemuMachineBackend?
  private(set) var failures: [VMError.Code] = []
  private(set) var stoppedCount = 0
  private(set) var terminalQemu: OwnedProcess.Snapshot?
  private(set) var terminalTPM: OwnedProcess.Snapshot?

  init(mode: String) throws {
    directory = URL(
      fileURLWithPath: "/private/tmp/mvo-pair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let script = directory.appendingPathComponent("peer.py")
    try Data(Self.childScript.utf8).write(to: script, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
    func configuration(_ role: String) -> OwnedProcess.Configuration {
      .init(
        executable: URL(
          fileURLWithPath: role == "machine" && mode == "spawn-failure"
            ? "/nonexistent/macopenvm-pair-test-child" : "/usr/bin/python3"),
        arguments: [script.path, role, mode],
        workingDirectory: directory, stdoutLog: directory.appendingPathComponent("\(role)-out.log"),
        stderrLog: directory.appendingPathComponent("\(role)-err.log"), memoryLimit: 4096,
        logLimit: 8192)
    }
    let owner = QemuMachineBackend(
      plan: .init(
        qemu: configuration("machine"), tpm: configuration("daemon"),
        qmpSocket: directory.appendingPathComponent("qmp.sock"),
        tpmSocket: directory.appendingPathComponent("tpm.sock")))
    backend = owner
    weakBackend = owner
    owner.onFailure = { [weak self] error in self?.failures.append(error.code) }
    owner.onGuestStopped = { [weak self] in self?.recordStopped() }
  }

  private func recordStopped() {
    stoppedCount += 1
    terminalQemu = weakBackend?.qemuSnapshot
    terminalTPM = weakBackend?.tpmSnapshot
  }

  func mark(_ name: String) throws {
    try Data("ready\n".utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
  }

  func awaitMarker(_ name: String) async throws {
    try await until {
      FileManager.default.fileExists(atPath: self.directory.appendingPathComponent(name).path)
    }
  }

  func until(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(4)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
      guard ContinuousClock.now < deadline else { throw PairFixtureFailure.deadline }
      if let owner = weakBackend { await owner.refreshOutput() }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func requirePairRunning() async throws {
    let owner = try #require(weakBackend)
    await owner.refreshOutput()
    #expect(owner.qemuSnapshot?.running == true && owner.tpmSnapshot?.running == true)
    #expect(owner.qemuSnapshot?.isActive == true && owner.tpmSnapshot?.isActive == true)
    #expect(owner.isActive && stoppedCount == 0)
  }

  func forceStopAndCheck() async throws {
    let owner = try #require(weakBackend)
    try await owner.forceStop()
    await owner.refreshOutput()
    #expect(!owner.isActive)
    try Self.requireFinished(owner.qemuSnapshot)
    try Self.requireFinished(owner.tpmSnapshot)
    #expect(stoppedCount == 1)
  }

  static func requireFinished(_ snapshot: OwnedProcess.Snapshot?) throws {
    let state = try #require(snapshot)
    #expect(state.started && !state.running && !state.isActive)
    #expect(state.termination?.status == 0 && state.termination?.reason == .exit)
    #expect(state.stdoutCapture.eof && state.stdoutCapture.finished)
    #expect(state.stderrCapture.eof && state.stderrCapture.finished)
    #expect(state.drainsFinished && state.outputError == nil)
    #expect(String(decoding: state.stdout, as: UTF8.self).contains("-end"))
    #expect(String(decoding: state.stderr, as: UTF8.self).contains("-end"))
  }

  /// Called after the test's operation settles. Fallback cleanup explicitly asks
  /// these disposable children to exit; fixture deletion requires observed drains.
  func cleanup() async throws {
    if let owner = backend ?? weakBackend {
      if owner.isActive {
        try mark("finish-daemon")
        try mark("finish-machine")
        try await owner.forceStop()
      }
      await owner.refreshOutput()
      guard !owner.isActive else { throw PairFixtureFailure.incompleteCleanup }
    } else {
      guard stoppedCount == 1, terminalQemu?.drainsFinished == true,
        terminalTPM?.drainsFinished == true
      else { throw PairFixtureFailure.incompleteCleanup }
    }
    backend = nil
    try FileManager.default.removeItem(at: directory)
  }

  private static let childScript = #"""
    # SPDX-License-Identifier: Apache-2.0
    import json, os, signal, socket, sys, time
    role, mode = sys.argv[1:]
    if mode == "quit-ignores-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.umask(0o077)
    deadline = time.monotonic() + 30.0
    def exists(name):
        return os.path.isfile(name)
    def mark(name):
        with open(name, "x", encoding="ascii") as out:
            out.write("ready\n")
    def finish_daemon():
        if not exists("finish-daemon"):
            mark("finish-daemon")
    def send(peer, value):
        peer.sendall(json.dumps(value, separators=(",", ":")).encode("ascii") + b"\r\n")
    def shutdown_event(peer):
        global shutdown_sent
        shutdown_sent = True
        send(peer, {"event": "SHUTDOWN", "data": {
            "guest": mode != "guest-host",
            "reason": "host-qmp-quit" if mode == "guest-host" else "guest-shutdown"},
            "timestamp": {"seconds": 1, "microseconds": 0}})
        if mode in ("guest-auto", "guest-tpm-first", "powerdown-eof"):
            finish_daemon()
        mark("shutdown-sent")
    def receive(peer):
        global quit_requested
        data = bytearray()
        while len(data) < 512 and time.monotonic() < deadline:
            if exists("send-shutdown") and not shutdown_sent:
                shutdown_event(peer)
                if mode == "guest-auto":
                    quit_requested = True
                    return None
            try:
                byte = peer.recv(1)
            except socket.timeout:
                if exists("finish-machine"):
                    return None
                continue
            if not byte:
                return None
            data.extend(byte)
            if byte == b"\n":
                value = json.loads(data)
                if set(value) != {"execute", "id"} or type(value["id"]) is not int:
                    raise RuntimeError("unexpected command shape")
                return value
        raise RuntimeError("command bound exceeded")
    path = "tpm.sock" if role == "daemon" else "qmp.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.settimeout(0.05)
    listener.bind(path)
    os.chmod(path, 0o600)
    listener.listen(1)
    print(role + "-start", flush=True)
    print(role + "-start", file=sys.stderr, flush=True)
    first_greeting = True
    first_capability = True
    gate_query = mode == "daemon-startup-exit"
    quit_requested = False
    shutdown_sent = False
    try:
        if role == "daemon":
            while time.monotonic() < deadline and not exists("finish-daemon"):
                time.sleep(0.01)
        else:
            running = True
            while time.monotonic() < deadline and not quit_requested and not exists("finish-machine"):
                try:
                    peer, _ = listener.accept()
                except socket.timeout:
                    continue
                with peer:
                    peer.settimeout(0.05)
                    bad = mode == "greeting-failure" and first_greeting
                    first_greeting = False
                    send(peer, {"QMP": {"version": {"qemu": {"major": 11, "minor": 1,
                        "micro": 1 if bad else 0}, "package": "local-test"}, "capabilities": []}})
                    if bad:
                        mark("bad-greeting-sent")
                        while receive(peer) is not None:
                            pass
                        continue
                    while time.monotonic() < deadline:
                        command = receive(peer)
                        if command is None:
                            break
                        name, identifier = command["execute"], command["id"]
                        if name == "qmp_capabilities":
                            stall = mode == "cancel-start" and first_capability
                            first_capability = False
                            if stall:
                                mark("capabilities-seen")
                                while receive(peer) is not None:
                                    pass
                                break
                            send(peer, {"return": {}, "id": identifier})
                        elif name == "query-status":
                            if gate_query:
                                gate_query = False
                                mark("query-seen")
                                while not exists("release-query") and time.monotonic() < deadline:
                                    time.sleep(0.005)
                            send(peer, {"return": {"running": running,
                                "status": "running" if running else "paused"}, "id": identifier})
                        elif name in ("stop", "cont"):
                            selected = (name == "stop" and mode.endswith("pause")) or (
                                name == "cont" and mode.endswith("resume"))
                            if selected and mode.startswith("cancel-"):
                                mark("control-seen")
                                while receive(peer) is not None:
                                    pass
                                break
                            if selected and mode.startswith("fail-"):
                                mark("control-seen")
                                send(peer, {"error": {"class": "GenericError",
                                    "desc": "local fixture command failure"}, "id": identifier})
                                finish_daemon()
                                quit_requested = True
                                break
                            running = name == "cont"
                            send(peer, {"return": {}, "id": identifier})
                        elif name == "quit":
                            if mode == "quit-ignores-term":
                                mark("quit-seen")
                                while time.monotonic() < deadline:
                                    time.sleep(0.01)
                                break
                            send(peer, {"return": {}, "id": identifier})
                            finish_daemon()
                            quit_requested = True
                            break
                        elif name == "system_powerdown":
                            mark("powerdown-seen")
                            if mode == "powerdown-failure":
                                send(peer, {"error": {"class": "GenericError",
                                    "desc": "local fixture command failure"}, "id": identifier})
                            elif mode == "powerdown-eof":
                                shutdown_event(peer)
                                quit_requested = True
                                break
                            else:
                                send(peer, {"return": {}, "id": identifier})
                                mark("powerdown-ack-sent")
                        else:
                            raise RuntimeError("unexpected command")
    finally:
        listener.close()
        print(role + "-end", flush=True)
        print(role + "-end", file=sys.stderr, flush=True)
    """#
}

@Suite(
  "QemuMachineBackendTests", .serialized,
  .enabled(
    if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
    "Requires existing system Python for private local process/socket fixtures."))
@MainActor
struct QemuMachineBackendTests {
  @Test func powerdownAcknowledgementLeavesBothChildrenOwned() async throws {
    try await withFixture("powerdown-ack") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try owner.requestStop()
      #expect(throws: VMError.self) { try owner.requestStop() }
      try await fixture.awaitMarker("powerdown-ack-sent")
      try await fixture.until { !owner.isControlPending }
      try await fixture.requirePairRunning()
      #expect(owner.terminationObservation == .notObserved && owner.lastFailure == nil)
      try await fixture.forceStopAndCheck()
      #expect(owner.terminationObservation == .explicitForcedTermination)
    }
  }

  @Test func spontaneousShutdownSettlesMonitorAndOwnedPair() async throws {
    try await withFixture("guest-auto") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try fixture.mark("send-shutdown")
      try await fixture.until { fixture.stoppedCount == 1 }
      try RuntimePairFixture.requireFinished(owner.qemuSnapshot)
      try RuntimePairFixture.requireFinished(owner.tpmSnapshot)
      #expect(!owner.isActive && owner.lastFailure == nil)
      #expect(owner.terminationObservation == .guestStopObserved)
    }
  }

  @Test func shutdownBeforePowerdownReplyStillRequiresNaturalOwnedSettlement() async throws {
    try await withFixture("powerdown-eof") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try owner.requestStop()
      try await fixture.until { fixture.stoppedCount == 1 }
      try RuntimePairFixture.requireFinished(owner.qemuSnapshot)
      try RuntimePairFixture.requireFinished(owner.tpmSnapshot)
      #expect(!owner.isActive && owner.lastFailure == nil)
      #expect(owner.terminationObservation == .guestStopObserved)
    }
  }

  @Test func spontaneousEOFDuringAdmittedPowerdownKeepsExactShutdownEvidence() async throws {
    try await withFixture("guest-auto") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try owner.requestStop()
      try fixture.mark("send-shutdown")
      try await fixture.until { fixture.stoppedCount == 1 }
      #expect(owner.lastFailure == nil && owner.terminationObservation == .guestStopObserved)
      try RuntimePairFixture.requireFinished(owner.qemuSnapshot)
      try RuntimePairFixture.requireFinished(owner.tpmSnapshot)
    }
  }

  @Test func bufferedShutdownAllowsExpectedTPMFinalizationButRetainsQEMUSurvivor() async throws {
    try await withFixture("guest-tpm-first") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try fixture.mark("send-shutdown")
      try await fixture.awaitMarker("shutdown-sent")
      try await fixture.until { owner.tpmSnapshot?.termination != nil }
      #expect(owner.isActive && owner.qemuSnapshot?.running == true && fixture.stoppedCount == 0)
      #expect(owner.lastFailure == nil && owner.terminationObservation == .notObserved)
      try fixture.mark("finish-machine")
      try await fixture.until { fixture.stoppedCount == 1 }
      #expect(owner.terminationObservation == .guestStopObserved && owner.lastFailure == nil)
      try RuntimePairFixture.requireFinished(owner.qemuSnapshot)
      try RuntimePairFixture.requireFinished(owner.tpmSnapshot)
    }
  }

  @Test func earlierUnattributedTPMExitCannotBeRepairedByLaterShutdown() async throws {
    try await withFixture("guest-late") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try fixture.mark("finish-daemon")
      try await fixture.until { owner.lastFailure != nil }
      #expect(owner.isActive && fixture.stoppedCount == 0)
      try fixture.mark("send-shutdown")
      try await fixture.awaitMarker("shutdown-sent")
      try fixture.mark("finish-machine")
      try await fixture.until { fixture.stoppedCount == 1 }
      #expect(owner.lastFailure?.code == .backendFailure && fixture.failures == [.backendFailure])
      #expect(owner.terminationObservation == .runtimeExited)
    }
  }

  @Test func hostShutdownReasonCannotBecomeGuestStopEvenWithExitZero() async throws {
    try await withFixture("guest-host") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try fixture.mark("send-shutdown")
      try await fixture.awaitMarker("shutdown-sent")
      try fixture.mark("finish-machine")
      try await fixture.until { owner.qemuSnapshot?.termination != nil }
      #expect(owner.isActive && fixture.stoppedCount == 0)
      try fixture.mark("finish-daemon")
      try await fixture.until { fixture.stoppedCount == 1 }
      #expect(owner.terminationObservation == .runtimeExited)
    }
  }

  @Test func failedPowerdownPreservesOwnedPairAndStickyFailure() async throws {
    try await withFixture("powerdown-failure") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try owner.requestStop()
      try await fixture.until { !owner.isControlPending }
      try await fixture.requirePairRunning()
      #expect(owner.lastFailure?.code == .backendFailure && fixture.failures == [.backendFailure])
      try await fixture.forceStopAndCheck()
      #expect(owner.lastFailure?.code == .backendFailure)
    }
  }

  @Test func daemonExitDuringStartupKeepsSurvivingMachineOwned() async throws {
    try await withFixture("daemon-startup-exit") { fixture in
      let owner = try #require(fixture.backend)
      let startup = Task { try await owner.start() }
      try await settleOnFailure(startup) {
        try await fixture.awaitMarker("query-seen")
        try fixture.mark("finish-daemon")
        try await fixture.until { owner.tpmSnapshot?.termination != nil }
        try fixture.mark("release-query")
        await expectFailure { try await startup.value }
      }
      await owner.refreshOutput()
      #expect(owner.qemuSnapshot?.running == true && owner.isActive)
      #expect(owner.tpmSnapshot?.running == false && fixture.stoppedCount == 0)
      #expect(owner.lastFailure?.code == .backendFailure && fixture.failures == [.backendFailure])
      try await fixture.forceStopAndCheck()
    }
  }

  @Test func negotiationFailureRetainsPairUntilExplicitForceStop() async throws {
    try await withFixture("greeting-failure") { fixture in
      let owner = try #require(fixture.backend)
      await expectFailure(.unsupportedVersion) { try await owner.start() }
      try await fixture.awaitMarker("bad-greeting-sent")
      try await fixture.requirePairRunning()
      #expect(owner.lastFailure?.code == .backendFailure && fixture.failures == [.backendFailure])
      try await fixture.forceStopAndCheck()
    }
  }

  @Test func forceStopKillsOnlyOwnedChildrenIgnoringQuitAndTermination() async throws {
    try await withFixture("quit-ignores-term") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      try await fixture.requirePairRunning()
      try await owner.forceStop()
      await owner.refreshOutput()
      for snapshot in [owner.qemuSnapshot, owner.tpmSnapshot] {
        let child = try #require(snapshot)
        #expect(child.termination?.reason == .uncaughtSignal)
        #expect(child.termination?.status == SIGKILL)
        #expect(child.drainsFinished && !child.isActive && child.outputError == nil)
      }
      #expect(!owner.isActive && fixture.stoppedCount == 1)
    }
  }

  @Test func machineSpawnFailureRetainsAlreadyStartedDaemon() async throws {
    try await withFixture("spawn-failure") { fixture in
      let owner = try #require(fixture.backend)
      await expectFailure { try await owner.start() }
      await owner.refreshOutput()
      #expect(owner.qemuSnapshot?.started == false && owner.qemuSnapshot?.isActive == false)
      #expect(owner.qemuSnapshot?.pid == nil && owner.qemuSnapshot?.termination == nil)
      #expect(owner.tpmSnapshot?.running == true && owner.tpmSnapshot?.isActive == true)
      #expect(owner.isActive && fixture.stoppedCount == 0)
      #expect(owner.lastFailure?.code == .backendFailure && fixture.failures == [.backendFailure])
      try await owner.forceStop()
      await owner.refreshOutput()
      let daemon = try #require(owner.tpmSnapshot)
      #expect(
        daemon.termination?.reason == .uncaughtSignal && daemon.termination?.status == SIGTERM)
      #expect(daemon.drainsFinished && !daemon.isActive && daemon.outputError == nil)
      #expect(daemon.stdoutCapture.eof && daemon.stdoutCapture.finished)
      #expect(daemon.stderrCapture.eof && daemon.stderrCapture.finished)
      #expect(!owner.isActive && owner.qemuSnapshot?.started == false)
      #expect(fixture.stoppedCount == 1 && fixture.failures == [.backendFailure])
    }
  }

  @Test func cancelledStartupRetainsSpawnedPair() async throws {
    try await withFixture("cancel-start") { fixture in
      let owner = try #require(fixture.backend)
      let startup = Task { try await owner.start() }
      try await settleOnFailure(startup) {
        try await fixture.awaitMarker("capabilities-seen")
        startup.cancel()
        await expectCancellation { try await startup.value }
      }
      try await fixture.requirePairRunning()
      #expect(owner.lastFailure?.code == .cancelled && fixture.failures == [.cancelled])
      try await fixture.forceStopAndCheck()
    }
  }

  @Test(arguments: [false, true])
  func cancelledControlRetainsPair(resuming: Bool) async throws {
    try await withFixture(resuming ? "cancel-resume" : "cancel-pause") { fixture in
      let owner = try #require(fixture.backend)
      try await owner.start()
      if resuming { try await owner.pause() }
      let control = Task {
        if resuming { try await owner.resume() } else { try await owner.pause() }
      }
      try await settleOnFailure(control) {
        try await fixture.awaitMarker("control-seen")
        control.cancel()
        await expectCancellation { try await control.value }
      }
      try await fixture.requirePairRunning()
      #expect(owner.lastFailure?.code == .cancelled && fixture.failures == [.cancelled])
      try await fixture.forceStopAndCheck()
    }
  }

  @Test(arguments: [false, true])
  func failedControlWithPairExitSettlesCallbacksAndReleasesOwner(resuming: Bool) async throws {
    try await withFixture(resuming ? "fail-resume" : "fail-pause") { fixture in
      try await fixture.backend?.start()
      if resuming { try await fixture.backend?.pause() }
      fixture.backend = nil
      #expect(fixture.weakBackend != nil)
      try await failControl(try #require(fixture.weakBackend), resuming: resuming)
      try await fixture.until { fixture.stoppedCount == 1 }
      try RuntimePairFixture.requireFinished(fixture.terminalQemu)
      try RuntimePairFixture.requireFinished(fixture.terminalTPM)
      #expect(fixture.failures == [.backendFailure])
      try await fixture.until { fixture.weakBackend == nil }
      #expect(fixture.stoppedCount == 1)
    }
  }

  private func failControl(_ owner: QemuMachineBackend, resuming: Bool) async throws {
    await expectFailure(.commandRejected("GenericError")) {
      if resuming { try await owner.resume() } else { try await owner.pause() }
    }
  }

  private func expectFailure(
    _ expected: QMPClientError? = nil, _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected runtime operation failure")
    } catch {
      if let expected {
        #expect(error as? QMPClientError == expected)
      } else {
        #expect((error as? VMError)?.code == .backendFailure)
      }
    }
  }

  private func settleOnFailure(
    _ task: Task<Void, any Error>, _ operation: () async throws -> Void
  ) async throws {
    do { try await operation() } catch {
      task.cancel()
      _ = try? await task.value
      throw error
    }
  }

  private func expectCancellation(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected runtime operation cancellation")
    } catch { #expect(error is CancellationError) }
  }

  private func withFixture(
    _ mode: String, _ operation: (RuntimePairFixture) async throws -> Void
  ) async throws {
    let fixture = try RuntimePairFixture(mode: mode)
    do { try await operation(fixture) } catch {
      do { try await fixture.cleanup() } catch {
        Issue.record("Private fixture cleanup did not settle: \(error)")
      }
      throw error
    }
    try await fixture.cleanup()
  }
}
