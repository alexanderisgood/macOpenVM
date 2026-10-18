// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

/// Fresh inert metadata only. These bytes classify recorded facts; they do not
/// construct a RuntimeSessionPermit, writer lease, backend or growth permit.
struct VMReviewFixture {
  let root: URL
  let directory: URL
  let configuration: VMConfiguration
  var registration: URL { directory.appendingPathComponent("configuration.json") }
  var media: URL { directory.appendingPathComponent("fixture-media.iso") }
  static let host = HostResources(cpuCount: 8, memoryBytes: 16 << 30)

  static func create(id: UUID = UUID(), recordedIssues: Bool = false) throws -> Self {
    let root = URL(fileURLWithPath: "/private/tmp/macOpenVM-review-fixture-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("Review.macopenvm", isDirectory: true)
    for path in [root, directory] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var configuration = VMConfiguration(
      name: "Review fixture", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 64 << 30, id: id)
    configuration.installationMedia = directory.appendingPathComponent("fixture-media.iso").path
    let fixture = Self(root: root, directory: directory, configuration: configuration)
    try fixture.write(ConfigurationCodec.encode(configuration), name: "configuration.json")
    if recordedIssues {
      let transaction = UUID().uuidString
      try fixture.write(
        JSONSerialization.data(
          withJSONObject: [
            "schemaVersion": 1, "vmID": id.uuidString, "sessionID": UUID().uuidString,
            "state": "unsettled",
          ], options: [.sortedKeys]), name: RuntimeIntent.filename)
      try fixture.write(
        JSONSerialization.data(
          withJSONObject: [
            "schemaVersion": 1, "vmID": id.uuidString, "transactionID": transaction,
            "state": "pending", "diskFile": configuration.diskFile,
            "directoryDevice": 1, "directoryInode": 1, "diskDevice": 1, "diskInode": 2,
            "oldBytes": configuration.diskBytes, "targetBytes": configuration.diskBytes + (1 << 30),
            "originalConfigurationSHA256": String(repeating: "0", count: 64),
            "replacementConfigurationSHA256": String(repeating: "1", count: 64),
            "backupFile": "disk-growth-\(transaction)-original.json",
            "targetFile": "disk-growth-\(transaction)-target.json",
          ], options: [.sortedKeys]), name: DiskGrowthIntent.filename)
    }
    return fixture
  }

  func context(owner: ObjectIdentifier, generation: UUID = UUID()) -> VMReviewContext {
    VMReviewContext(
      configurationURL: registration, configuration: configuration,
      owner: owner, generation: generation)
  }

  func write(_ bytes: Data, name: String) throws {
    let destination = directory.appendingPathComponent(name)
    try bytes.write(to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  struct Stamp: Equatable {
    let inode: UInt64, size: Int64, uid: UInt32, mode: UInt16, links: UInt16
    let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    let bytes: Data
  }
  func inventory() throws -> [String: Stamp] {
    var result: [String: Stamp] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
      let url = directory.appendingPathComponent(name)
      var value = stat()
      guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
        value.st_size >= 0, value.st_size <= 65_536
      else {
        throw VMError(
          .storage, "The inert review fixture changed.", recovery: "Preserve its files.")
      }
      result[name] = Stamp(
        inode: value.st_ino, size: value.st_size, uid: value.st_uid,
        mode: value.st_mode, links: value.st_nlink,
        modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
        changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec,
        bytes: try Data(contentsOf: url))
    }
    return result
  }
}

actor DeferredVMReviewInspector: VMReviewInspecting {
  private let native = NativeVMReviewInspector(host: VMReviewFixture.host)
  private var next = 0
  private var releasedAll = false
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  func inspect(_ context: VMReviewContext) async throws -> VMInspectionReport {
    next += 1
    let request = next
    let report = try await native.inspect(context)
    await withCheckedContinuation {
      if releasedAll { $0.resume() } else { waiters[request] = $0 }
    }
    return report
  }
  var blocked: Set<Int> { Set(waiters.keys) }
  func release(_ request: Int) { waiters.removeValue(forKey: request)?.resume() }
  func releaseAll() {
    releasedAll = true
    let pending = Array(waiters.values)
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private final class VMReviewOwner {}

@MainActor @Suite(.serialized) struct VMReviewControllerTests {
  @Test func actualInspectionSurfacesPendingOwnershipAndMissingMediaWithoutChangingFiles()
    async throws
  {
    let fixture = try VMReviewFixture.create(recordedIssues: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let owner = VMReviewOwner()
    let context = fixture.context(owner: ObjectIdentifier(owner))
    let before = try fixture.inventory()
    let review = VMReviewController(inspector: NativeVMReviewInspector(host: VMReviewFixture.host))
    review.open(context)
    await review.refresh(context: context) { $0 == context }
    let presentation = try #require(review.presentation)
    let ids = Set(presentation.findings.map(\.id))
    #expect(ids.contains("disk-growth-pending"))
    #expect(ids.contains("runtime-intent-unsettled"))
    #expect(ids.contains("media-unavailable"))
    #expect(presentation.intent.contains("Unsettled"))
    #expect(presentation.writer == "No writer record found")
    #expect(!presentation.hasUnrecognizedFacts && !review.isLoading && review.error == nil)
    #expect(
      presentation.findings.first { $0.id == "disk-growth-pending" }?.guidance.contains("Preserve")
        == true)
    #expect(VMReviewPresentation.scope.contains("Guest health"))
    #expect(try fixture.inventory() == before)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent("writer.lock").path))
    withExtendedLifetime(owner) {}
  }

  @Test func mismatchedFullConfigurationCannotProduceAReviewForTheOldSelection() async throws {
    let fixture = try VMReviewFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let owner = VMReviewOwner()
    let context = fixture.context(owner: ObjectIdentifier(owner))
    var changed = fixture.configuration
    changed.name = "Changed saved configuration with the same UUID"
    try fixture.write(ConfigurationCodec.encode(changed), name: "configuration.json")
    let before = try fixture.inventory()
    let review = VMReviewController(inspector: NativeVMReviewInspector(host: VMReviewFixture.host))
    review.open(context)
    await review.refresh(context: context) { $0 == context }
    #expect(review.presentation == nil && review.error == .selectionChanged && !review.isLoading)
    #expect(try fixture.inventory() == before)
    withExtendedLifetime(owner) {}
  }

  @Test func aNewerRefreshWinsWhenTheSameContextCompletesOutOfOrder() async throws {
    let fixture = try VMReviewFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let owner = VMReviewOwner()
    let context = fixture.context(owner: ObjectIdentifier(owner))
    let gate = DeferredVMReviewInspector()
    defer { Task { await gate.releaseAll() } }
    let review = VMReviewController(inspector: gate)
    review.open(context)
    let first = Task { await review.refresh(context: context) { $0 == context } }
    try await blocked(gate, requests: [1])
    // Explicit fixture setup correction only, after the first real report is complete.
    try fixture.write(
      Data("inert image fixture; not boot or driver media".utf8), name: "fixture-media.iso")
    let second = Task { await review.refresh(context: context) { $0 == context } }
    try await blocked(gate, requests: [1, 2])
    await gate.release(2)
    await second.value
    let newest = try #require(review.presentation)
    #expect(!newest.findings.contains { $0.id == "media-unavailable" })
    await gate.release(1)
    await first.value
    #expect(review.presentation == newest && !review.isLoading && review.error == nil)
    withExtendedLifetime(owner) {}
  }

  @Test func closeAndReopenWithEqualValuesStillRevokesTheEarlierRequest() async throws {
    let fixture = try VMReviewFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let owner = VMReviewOwner()
    let context = fixture.context(owner: ObjectIdentifier(owner))
    let gate = DeferredVMReviewInspector()
    defer { Task { await gate.releaseAll() } }
    let review = VMReviewController(inspector: gate)
    review.open(context)
    let old = Task { await review.refresh(context: context) { $0 == context } }
    try await blocked(gate, requests: [1])
    review.invalidate()
    // Even a mistakenly reused value-equal context cannot revive the previous token.
    review.open(context)
    let reopened = Task { await review.refresh(context: context) { $0 == context } }
    try await blocked(gate, requests: [1, 2])
    await gate.release(1)
    await old.value
    #expect(review.presentation == nil && review.isLoading)
    await gate.release(2)
    await reopened.value
    #expect(review.presentation != nil && !review.isLoading)
    withExtendedLifetime(owner) {}
  }

  @Test(arguments: ["owner", "url-same-uuid", "configuration-same-uuid", "generation", "busy"])
  func lostAdmissionDiscardsAnActualCompletedReport(_ change: String) async throws {
    let fixture = try VMReviewFixture.create()
    let alternate = try VMReviewFixture.create(id: fixture.configuration.id)
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      try? FileManager.default.removeItem(at: alternate.root)
    }
    let owner = VMReviewOwner()
    let replacement = VMReviewOwner()
    let context = fixture.context(owner: ObjectIdentifier(owner))
    var accepted = context
    var busy = false
    let gate = DeferredVMReviewInspector()
    defer { Task { await gate.releaseAll() } }
    let review = VMReviewController(inspector: gate)
    review.open(context)
    let task = Task { await review.refresh(context: context) { !busy && $0 == accepted } }
    try await blocked(gate, requests: [1])
    var configuration = context.configuration
    if change == "configuration-same-uuid" { configuration.cpuCount += 1 }
    if change == "busy" { busy = true }
    accepted = VMReviewContext(
      configurationURL: change == "url-same-uuid"
        ? alternate.registration : context.configurationURL,
      configuration: configuration,
      owner: change == "owner" ? ObjectIdentifier(replacement) : context.owner,
      generation: change == "generation" ? UUID() : context.generation)
    await gate.release(1)
    await task.value
    #expect(
      review.context == nil && review.presentation == nil && !review.isLoading
        && review.error == nil)
    withExtendedLifetime((owner, replacement)) {}
  }

  private func blocked(_ gate: DeferredVMReviewInspector, requests: Set<Int>) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await gate.blocked != requests, ContinuousClock.now < deadline { await Task.yield() }
    try #require(await gate.blocked == requests)
  }
}
