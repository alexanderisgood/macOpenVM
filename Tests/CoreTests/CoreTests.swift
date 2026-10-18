// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore

@Test(arguments: VMState.allCases, LifecycleOperation.allCases)
func transitionTable(state: VMState, operation: LifecycleOperation) throws {
  let accepted: [VMState: Set<LifecycleOperation>] = [
    .stopped: [.start], .running: [.pause, .stop, .forceStop],
    .paused: [.resume, .forceStop, .suspend], .suspended: [.restore], .failed: [.forceStop],
    .stopping: [.forceStop],
  ]
  var machine = VMStateMachine(state: state)
  if accepted[state]?.contains(operation) == true {
    let id = try machine.begin(operation)
    #expect(machine.state == VMStateMachine.destination(from: state, operation: operation))
    #expect(throws: VMError.self) { try machine.begin(operation) }
    try machine.complete(id: id)
    #expect(machine.operationID == nil)
  } else {
    #expect(throws: VMError.self) { try machine.begin(operation) }
    #expect(machine.state == state)
    #expect(machine.operationID == nil)
  }
}

@Test func staleAndGuestStop() throws {
  var m = VMStateMachine()
  let old = try m.begin(.start)
  m.backendStopped()
  let current = try m.begin(.start)
  #expect(throws: VMError.self) { try m.complete(id: old) }
  #expect(m.state == .starting)
  #expect(m.operationID == current)
  try m.complete(id: current)
  let pause = try m.begin(.pause)
  try m.complete(id: pause)
  let save = try m.begin(.suspend)
  try m.complete(id: save)
  #expect(m.state == .suspended)
  let restore = try m.begin(.restore)
  try m.fail(id: restore)
  #expect(m.state == .failed)
}

@Test func configurationRoundTrips() throws {
  let host = HostResources(cpuCount: 12, memoryBytes: 32 * 1_073_741_824)
  for _ in 0..<200 {
    let c = VMConfiguration(name: "Linux ✓", guest: .linux, backend: .appleVz)
    try ConfigurationValidator.validate(c, host: host)
    #expect(try ConfigurationCodec.decode(ConfigurationCodec.encode(c)) == c)
  }
}

@Test func rejectsHostExhaustionAndUnsafeMetadata() throws {
  let host = HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824)
  var c = VMConfiguration(name: "Linux", guest: .linux, backend: .appleVz)
  c.memoryBytes = 16 * 1_073_741_824
  #expect(throws: VMError.self) { try ConfigurationValidator.validate(c, host: host) }
  c.memoryBytes = 4 * 1_073_741_824
  c.cpuCount = 8
  #expect(throws: VMError.self) { try ConfigurationValidator.validate(c, host: host) }
  c.cpuCount = 2
  c.diskFile = "../host-file"
  #expect(throws: VMError.self) { try ConfigurationValidator.validate(c, host: host) }
  c.diskFile = "disk.raw"
  c.macAddress = "ff:ff:ff:ff:ff:ff"
  #expect(throws: VMError.self) { try ConfigurationValidator.validate(c, host: host) }
  c.schemaVersion = 99
  #expect(throws: VMError.self) { try ConfigurationCodec.encode(c) }
  #expect(throws: VMError.self) { try ConfigurationCodec.decode(Data(repeating: 0, count: 65_537)) }
  #expect(throws: VMError.self) { try ConfigurationCodec.decode(Data("{broken".utf8)) }
}

@Test(arguments: ["", ".", "..", "../disk", "a/b", "a\\b", "disk\0raw"])
func pathPolicyRejects(value: String) { #expect(!ConfigurationValidator.isSafeComponent(value)) }

@MainActor final class FakeBackend: MachineBackend {
  var terminationObservation = BackendTerminationObservation.notObserved
  let capabilities = BackendCapabilities(
    id: .appleVz, operations: [.start, .stop, .forceStop, .pause, .resume], limitations: [])
  var isActive = false
  var onGuestStopped: (@MainActor () -> Void)?
  var onFailure: (@MainActor (VMError) -> Void)?
  var failStop = false
  var pretendForceStopCompletion = false
  func start() async throws {
    terminationObservation = .notObserved
    isActive = true
  }
  func requestStop() throws {}
  func forceStop() async throws {
    if failStop { throw VMError(.backendFailure, "failed", recovery: "inspect") }
    if pretendForceStopCompletion { return }
    isActive = false
    terminationObservation = .explicitForcedTermination
    onGuestStopped?()
  }
  func pause() async throws {}
  func resume() async throws {}
  func guestShutdown() {
    isActive = false
    terminationObservation = .guestStopObserved
    onGuestStopped?()
  }
}

@Test @MainActor func shutdownRequiresObservationAndFailuresRetainOwnership() async throws {
  let backend = FakeBackend()
  let controller = VMController(backend: FakeBackend())
  #expect(controller.state == .stopped)
  let actual = VMController(backend: backend)
  var quiescent = false
  actual.onQuiescent = { quiescent = true }
  try await actual.perform(.start)
  try await actual.perform(.stop)
  #expect(actual.state == .stopping)
  #expect(!quiescent)
  backend.guestShutdown()
  #expect(actual.state == .stopped)
  #expect(quiescent)
  quiescent = false
  try await actual.perform(.start)
  backend.failStop = true
  await #expect(throws: VMError.self) { try await actual.perform(.forceStop) }
  #expect(actual.state == .failed)
  #expect(!quiescent)
  #expect(actual.isActive)
}

@Test @MainActor func unsupportedSuspendFailsBeforeStateChange() async throws {
  let backend = FakeBackend()
  let controller = VMController(backend: backend)
  try await controller.perform(.start)
  try await controller.perform(.pause)
  await #expect(throws: VMError.self) { try await controller.perform(.suspend) }
  #expect(controller.state == .paused)
}
