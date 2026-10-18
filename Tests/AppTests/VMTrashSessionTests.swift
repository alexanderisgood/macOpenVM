// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import Foundation
import Testing
import VMCore

@testable import MacOpenVMApp

@MainActor private final class TrashPreferences: VMLibraryPreferences {
  var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
}

private actor TrashTicketFixture: DesktopVMTrashTicket {
  nonisolated let vmID: UUID
  nonisolated let name: String
  var cancellations = 0
  var commits = 0
  var result: VMTrashResult
  var commitFailure = false
  init(configuration: VMConfiguration, status: VMTrashResult.Status = .moved) {
    vmID = configuration.id
    name = configuration.name
    result = VMTrashResult(status: status, trashURL: nil)
  }
  func cancel() { cancellations += 1 }
  func commit() throws -> VMTrashResult {
    commits += 1
    if commitFailure {
      throw VMError(.staleOperation, "The prepared VM changed.", recovery: "Preserve its files.")
    }
    return result
  }
  func failCommit() { commitFailure = true }
  func reportedDestination(_ url: URL) {
    result = VMTrashResult(status: result.status, trashURL: url)
  }
}

@MainActor private final class TrashServiceFixture: DesktopVMTrashService {
  let ticket: TrashTicketFixture
  var preparedEntries: [VMLibraryEntry] = []
  var paused = false
  var failure = false
  var continuation: CheckedContinuation<Void, Never>?
  init(ticket: TrashTicketFixture) { self.ticket = ticket }
  func prepare(entry: VMLibraryEntry) async throws -> any DesktopVMTrashTicket {
    preparedEntries.append(entry)
    if paused { await withCheckedContinuation { continuation = $0 } }
    if failure {
      throw VMError(.busy, "The VM has another writer.", recovery: "Preserve its current session.")
    }
    return ticket
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor private final class TrashConfirmationFixture: DesktopVMTrashConfirming {
  var canPresent = true
  var requests: [DesktopVMTrashConfirmation] = []
  var continuation: CheckedContinuation<Bool, Never>?
  func canPresent(on owner: NSWindow?, libraryPresented: Bool) -> Bool { canPresent }
  func confirm(_ request: DesktopVMTrashConfirmation, on owner: NSWindow?) async -> Bool {
    requests.append(request)
    return await withCheckedContinuation { continuation = $0 }
  }
  func answer(_ approved: Bool) {
    continuation?.resume(returning: approved)
    continuation = nil
  }
}

@MainActor @Suite struct VMTrashSessionTests {
  private func fixture(status: VMTrashResult.Status = .moved) throws -> (
    DesktopSession, VMLibraryEntry, TrashTicketFixture, TrashServiceFixture,
    TrashConfirmationFixture
  ) {
    let configuration = VMConfiguration(
      name: "Trash candidate", guest: .linux, backend: .appleVz, cpuCount: 1,
      memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let url = URL(fileURLWithPath: "/private/tmp/" + UUID().uuidString + ".macopenvm")
      .appendingPathComponent("configuration.json")
    let library = VMLibrary(preferences: TrashPreferences())
    library.remember(configuration, at: url)
    let entry = try VMLibraryEntry(configuration: configuration, at: url)
    let ticket = TrashTicketFixture(configuration: configuration, status: status)
    let service = TrashServiceFixture(ticket: ticket)
    let confirmation = TrashConfirmationFixture()
    let session = DesktopSession(
      library: library, trashService: service, trashConfirmation: confirmation)
    // The injected presenter accepts no owner. No native window, VM or Trash is touched.
    session.showingLibrary = true
    return (session, entry, ticket, service, confirmation)
  }

  private func eventually(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate())
  }

  @Test func preparePrecedesDismissalAndCancellationPreservesLibrary() async throws {
    let (session, entry, ticket, service, confirmation) = try fixture()
    service.paused = true
    #expect(session.canMoveSavedVMToTrash(entry))
    session.moveSavedVMToTrash(entry)
    try await eventually { service.continuation != nil }
    #expect(session.showingLibrary && session.isBusy && session.trashOperationInProgress)
    #expect(confirmation.requests.isEmpty)
    session.showLinuxCreation()
    session.openSavedVM(entry)
    #expect(!session.creating && session.showingLibrary)
    service.resume()
    try await eventually { !session.showingLibrary }
    #expect(confirmation.requests.isEmpty)
    session.libraryDismissed()
    try await eventually { confirmation.continuation != nil }
    #expect(
      confirmation.requests == [
        DesktopVMTrashConfirmation(
          vmID: entry.vmID, name: entry.name,
          directory: entry.configurationURL.deletingLastPathComponent())
      ])
    confirmation.answer(false)
    try await eventually { !session.trashOperationInProgress }
    #expect(await ticket.cancellations == 1)
    #expect(await ticket.commits == 0)
    #expect(session.library.entries == [entry])
    #expect(session.configuration == nil)
  }

  @Test func admittedMoveForgetsOnlyItsEntryAndPreservesForeignSelection() async throws {
    let (session, entry, ticket, _, confirmation) = try fixture()
    let foreign = VMConfiguration(
      name: "Another saved VM", guest: .linux, backend: .appleVz, cpuCount: 1,
      memoryBytes: 512 << 20, diskBytes: 1 << 30)
    session.configuration = foreign
    let foreignURL = URL(fileURLWithPath: "/private/tmp/" + UUID().uuidString)
      .appendingPathComponent("configuration.json")
    session.library.remember(foreign, at: foreignURL)
    session.moveSavedVMToTrash(entry)
    try await eventually { !session.showingLibrary }
    session.libraryDismissed()
    try await eventually { confirmation.continuation != nil }
    #expect(session.library.entries.contains(entry))
    #expect(await ticket.commits == 0)
    confirmation.answer(true)
    try await eventually { !session.trashOperationInProgress }
    #expect(await ticket.commits == 1)
    #expect(await ticket.cancellations == 0)
    #expect(session.library.entries.count == 1)
    #expect(session.library.entries.first?.vmID == foreign.id)
    #expect(session.configuration == foreign)
  }

  @Test func changedStateDuringConfirmationReleasesTicketWithoutCommit() async throws {
    let (session, entry, ticket, _, confirmation) = try fixture()
    session.moveSavedVMToTrash(entry)
    try await eventually { !session.showingLibrary }
    session.libraryDismissed()
    try await eventually { confirmation.continuation != nil }
    session.creating = true
    confirmation.answer(true)
    try await eventually { !session.trashOperationInProgress }
    #expect(await ticket.cancellations == 1)
    #expect(await ticket.commits == 0)
    #expect(session.creating)
    #expect(session.library.entries == [entry])
    #expect(session.errorMessage != nil)
  }

  @Test func busyOrOtherModalNeverPrepares() async throws {
    let (session, entry, _, service, confirmation) = try fixture()
    session.creating = true
    session.moveSavedVMToTrash(entry)
    #expect(service.preparedEntries.isEmpty)
    session.creating = false
    confirmation.canPresent = false
    session.moveSavedVMToTrash(entry)
    #expect(service.preparedEntries.isEmpty)
    #expect(session.showingLibrary && !session.trashOperationInProgress)
  }

  @Test func prepareRefusalLeavesSheetAndLibraryUnchanged() async throws {
    let (session, entry, _, service, confirmation) = try fixture()
    service.failure = true
    session.moveSavedVMToTrash(entry)
    try await eventually { !session.trashOperationInProgress }
    #expect(session.showingLibrary)
    #expect(session.library.entries == [entry])
    #expect(confirmation.requests.isEmpty)
    #expect(session.errorMessage != nil)
  }

  @Test(arguments: [VMTrashResult.Status.notMoved, .relocationUnverified])
  func unconfirmedResultPreservesRecordsAndReportsUncertainty(status: VMTrashResult.Status)
    async throws
  {
    let (session, entry, ticket, _, confirmation) = try fixture(status: status)
    session.moveSavedVMToTrash(entry)
    try await eventually { !session.showingLibrary }
    session.libraryDismissed()
    try await eventually { confirmation.continuation != nil }
    confirmation.answer(true)
    try await eventually { !session.trashOperationInProgress }
    #expect(await ticket.commits == 1)
    #expect(session.library.entries == [entry])
    #expect(
      session.errorMessage?.contains(status == .notMoved ? "did not move" : "may have moved")
        == true)
  }

  @Test func staleCommitFailurePreservesRecordsWithoutRetry() async throws {
    let (session, entry, ticket, _, confirmation) = try fixture()
    await ticket.failCommit()
    session.moveSavedVMToTrash(entry)
    try await eventually { !session.showingLibrary }
    session.libraryDismissed()
    try await eventually { confirmation.continuation != nil }
    confirmation.answer(true)
    try await eventually { !session.trashOperationInProgress }
    #expect(await ticket.commits == 1)
    #expect(session.library.entries == [entry])
    #expect(session.errorMessage != nil)
  }

  @Test func reportedUnverifiedDestinationSurvivesReopeningLibrary() async throws {
    let (session, entry, ticket, _, confirmation) = try fixture(status: .relocationUnverified)
    let reported = URL(fileURLWithPath: "/private/tmp/reported-trash-item.macopenvm")
    await ticket.reportedDestination(reported)
    session.moveSavedVMToTrash(entry)
    try await eventually { !session.showingLibrary }
    session.libraryDismissed()
    try await eventually { confirmation.continuation != nil }
    confirmation.answer(true)
    try await eventually { !session.trashOperationInProgress }
    #expect(session.trashRecoveryURL == reported)
    #expect(session.errorMessage?.contains(reported.path) == true)
    session.showLibrary()
    #expect(session.trashRecoveryURL == reported)
    #expect(session.library.entries == [entry])
  }

  @Test func libraryDismissedWhilePreparingCancelsInsteadOfAttachingAnotherSheet() async throws {
    let (session, entry, ticket, service, confirmation) = try fixture()
    service.paused = true
    session.moveSavedVMToTrash(entry)
    try await eventually { service.continuation != nil }
    session.showingLibrary = false
    session.libraryDismissed()
    service.resume()
    try await eventually { !session.trashOperationInProgress }
    #expect(await ticket.cancellations == 1)
    #expect(await ticket.commits == 0)
    #expect(confirmation.requests.isEmpty)
    #expect(session.library.entries == [entry])
  }

  @Test func newModalDuringPrepareReleasesTicketAndKeepsLibrary() async throws {
    let (session, entry, ticket, service, confirmation) = try fixture()
    service.paused = true
    session.moveSavedVMToTrash(entry)
    try await eventually { service.continuation != nil }
    confirmation.canPresent = false
    service.resume()
    try await eventually { !session.trashOperationInProgress }
    #expect(await ticket.cancellations == 1)
    #expect(await ticket.commits == 0)
    #expect(session.showingLibrary)
    #expect(confirmation.requests.isEmpty)
    #expect(session.library.entries == [entry])
  }

  @Test func onlyDedicatedBundleFoldersExposeTrash() throws {
    let (session, entry, _, _, _) = try fixture()
    let configuration = VMConfiguration(
      name: "Legacy folder", guest: .linux, backend: .appleVz, cpuCount: 1,
      memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let legacy = try VMLibraryEntry(
      configuration: configuration,
      at: URL(fileURLWithPath: "/private/tmp/legacy-folder/configuration.json"))
    #expect(session.canMoveSavedVMToTrash(entry))
    #expect(!session.canMoveSavedVMToTrash(legacy))
  }

  @Test func confirmedMoveClearsMatchingInactiveSelectionOnly() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString + ".macopenvm")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = VMConfiguration(
      name: "Selected trash candidate", guest: .linux, backend: .appleVz, cpuCount: 1,
      memoryBytes: 512 << 20, diskBytes: 1 << 30)
    let registration = root.appendingPathComponent("configuration.json")
    try ConfigurationCodec.encode(configuration).write(to: registration)
    let disk = root.appendingPathComponent("disk.raw")
    #expect(FileManager.default.createFile(atPath: disk.path, contents: nil))
    let handle = try FileHandle(forWritingTo: disk)
    try handle.truncate(atOffset: configuration.diskBytes)
    try handle.close()
    for file in [registration, disk] {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    let library = VMLibrary(preferences: TrashPreferences())
    let ticket = TrashTicketFixture(configuration: configuration)
    let service = TrashServiceFixture(ticket: ticket)
    let confirmation = TrashConfirmationFixture()
    let session = DesktopSession(
      library: library, trashService: service, trashConfirmation: confirmation)
    try await session.qualificationSelectVM(at: registration, expectedID: configuration.id)
    #expect(session.configuration == configuration)
    #expect(session.selectedConfigurationURL == registration)
    session.showLibrary()
    let entry = try #require(library.entries.first)
    session.moveSavedVMToTrash(entry)
    try await eventually { !session.showingLibrary }
    session.libraryDismissed()
    try await eventually { confirmation.continuation != nil }
    #expect(session.configuration == configuration)
    confirmation.answer(true)
    try await eventually { !session.trashOperationInProgress }
    #expect(session.configuration == nil && session.selectedConfigurationURL == nil)
    #expect(session.state == .stopped && session.backend == nil)
    #expect(library.entries.isEmpty)
    // The injected ticket never moves files. Selection cleanup does not delete them either.
    #expect(FileManager.default.fileExists(atPath: registration.path))
    #expect(FileManager.default.fileExists(atPath: disk.path))
  }
}
