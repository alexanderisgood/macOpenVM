// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation
import Testing

@testable import VMStorage

private struct TrashFixture: Sendable {
  let root: URL
  let source: URL
  let trash: URL
  let configuration: VMConfiguration
  let bytes: Data
  var destination: URL { trash.appendingPathComponent("conflict-renamed.macopenvm") }
  var sink: StoppedVMTrashSink {
    .init(
      directory: { _ in trash },
      move: { path, validate in
        do {
          try validate(path)
          try FileManager.default.moveItem(at: path, to: destination)
          return .init(trashURL: destination, failed: false)
        } catch { return .init(trashURL: nil, failed: true) }
      })
  }
  func ticket(sink: StoppedVMTrashSink? = nil) async throws -> StoppedVMTrashTicket {
    try await VMFiles().prepareStoppedVMTrash(
      in: source, vmID: configuration.id, sink: sink ?? self.sink,
      validate: { registration, history, intent in
        guard registration == bytes, history == nil, intent == nil else {
          throw TrashIO.failure(.staleOperation)
        }
      })
  }
}

private func trashFixture() async throws -> TrashFixture {
  let root = URL(fileURLWithPath: "/private/tmp/macOpenVM-trash-tests-\(UUID().uuidString)")
  let source = root.appendingPathComponent("Original.macopenvm")
  let trash = root.appendingPathComponent("test-only-recoverable-destination")
  for directory in [root, source, trash] {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  let configuration = VMConfiguration(name: "preserved VM", guest: .linux, backend: .appleVz)
  let bytes = try JSONEncoder().encode(configuration)
  try await VMFiles().writeNewMetadata(
    bytes, at: source.appendingPathComponent("configuration.json"))
  try await VMFiles().writeNewMetadata(
    Data("disk bytes remain unchanged".utf8), at: source.appendingPathComponent("disk.raw"))
  let owner = try VMLock(directory: source, expectedVMID: configuration.id)
  withExtendedLifetime(owner) {}
  return .init(root: root, source: source, trash: trash, configuration: configuration, bytes: bytes)
}

private func trashAddACL(
  _ url: URL, tag: acl_tag_t = ACL_EXTENDED_ALLOW, permission: acl_perm_t = ACL_READ_DATA,
  flag: acl_flag_t? = nil
) throws {
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw TrashIO.failure(.storage) }
  defer { close(fd) }
  var acl = acl_init(1)
  defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
  var entry: acl_entry_t?
  guard acl_create_entry(&acl, &entry) == 0, let acl, let entry,
    acl_set_tag_type(entry, tag) == 0
  else { throw TrashIO.failure(.storage) }
  let qualifier = UUID().uuid
  let assigned = withUnsafeBytes(of: qualifier) { acl_set_qualifier(entry, $0.baseAddress) }
  var permissions: acl_permset_t?
  guard assigned == 0, acl_get_permset(entry, &permissions) == 0, let permissions,
    acl_clear_perms(permissions) == 0, acl_add_perm(permissions, permission) == 0
  else { throw TrashIO.failure(.storage) }
  if let flag {
    var flags: acl_flagset_t?
    guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
      acl_add_flag_np(flags, flag) == 0
    else { throw TrashIO.failure(.storage) }
  }
  guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw TrashIO.failure(.storage) }
}

private func trashACLBytes(_ acl: acl_t) throws -> Data {
  let size = acl_size(acl)
  guard size > 0, size <= 65_536 else { throw TrashIO.failure(.storage) }
  var bytes = Data(count: size)
  let count = bytes.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, size) }
  guard count == size else { throw TrashIO.failure(.storage) }
  return bytes
}

@Test func trashTicketHoldsWriterAndCancelConsumesWithoutMoving() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let ticket = try await f.ticket()
  #expect(await VMFiles().writerStatus(in: f.source) == .held)
  #expect(throws: VMError.self) {
    _ = try VMLock(directory: f.source, expectedVMID: f.configuration.id)
  }
  await ticket.cancel()
  #expect(await VMFiles().writerStatus(in: f.source) == .available)
  await #expect(throws: VMError.self) { _ = try await ticket.commit() }
  #expect(try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashMoveConfirmsConflictRenamedIdentityAndPreservesBytes() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  var before = stat()
  #expect(lstat(f.source.path, &before) == 0)
  let ticket = try await f.ticket()
  let result = try await ticket.commit()
  #expect(result.status == .moved && result.trashURL == f.destination)
  var after = stat()
  #expect(lstat(f.destination.path, &after) == 0)
  #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
  #expect(
    try Data(contentsOf: f.destination.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(
    try Data(contentsOf: f.destination.appendingPathComponent("disk.raw"))
      == Data("disk bytes remain unchanged".utf8))
  #expect(await VMFiles().writerStatus(in: f.destination) == .available)
  await #expect(throws: VMError.self) { _ = try await ticket.commit() }
}

@Test(arguments: ["configuration", "source", "parent", "permission", "writer"])
func trashRejectsChangedSelectionBeforeMove(_ change: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let ticket = try await f.ticket()
  var movedParent: URL?
  defer { if let movedParent { try? FileManager.default.removeItem(at: movedParent) } }
  switch change {
  case "configuration":
    try await VMFiles().atomicWrite(
      Data("changed registration".utf8), at: f.source.appendingPathComponent("configuration.json"))
  case "source":
    try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("preserved"))
    try FileManager.default.createDirectory(
      at: f.source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  case "parent":
    let preserved = f.root.appendingPathExtension("preserved")
    try FileManager.default.moveItem(at: f.root, to: preserved)
    movedParent = preserved
    try FileManager.default.createDirectory(
      at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  case "permission": #expect(chmod(f.source.path, 0o770) == 0)
  default:
    let writer = f.source.appendingPathComponent("writer.lock")
    try FileManager.default.moveItem(
      at: writer, to: f.source.appendingPathComponent("original-lock"))
    try await VMFiles().writeNewMetadata(Data("replacement".utf8), at: writer)
  }
  await #expect(throws: VMError.self) { _ = try await ticket.commit() }
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashReservationRefusesInheritanceRuntimeAndReuse() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let owner = try VMLock(existingDirectory: f.source, expectedVMID: f.configuration.id)
  try owner.reserveTrash(forVMID: f.configuration.id)
  #expect(throws: VMError.self) { _ = try owner.duplicateForInheritance() }
  #expect(throws: VMError.self) { try owner.reserveTrash(forVMID: f.configuration.id) }
  await #expect(throws: VMError.self) {
    _ = try await VMFiles().beginRuntimeSession(
      in: f.source, forVMID: f.configuration.id, lock: owner)
  }
  #expect(
    !FileManager.default.fileExists(
      atPath: f.source.appendingPathComponent(RuntimeIntent.filename).path))
}

@Test func trashMissingLockDoesNotCreateAnyFile() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let writer = f.source.appendingPathComponent("writer.lock")
  try FileManager.default.removeItem(at: writer)
  let names = try FileManager.default.contentsOfDirectory(atPath: f.source.path)
  await #expect(throws: VMError.self) { _ = try await f.ticket() }
  #expect(try FileManager.default.contentsOfDirectory(atPath: f.source.path) == names)
}

@Test(arguments: ["symlink", "acl", "foreign-intent", "unsettled", "growth"])
func trashRefusesUnsafeAdmissions(_ kind: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  var path = f.source
  switch kind {
  case "symlink":
    path = f.root.appendingPathComponent("Alias.macopenvm")
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: f.source)
  case "acl":
    try trashAddACL(f.source)
  case "growth":
    try await VMFiles().writeNewMetadata(
      Data("{}".utf8), at: f.source.appendingPathComponent(DiskGrowthIntent.filename))
  default:
    let id = kind == "foreign-intent" ? UUID() : f.configuration.id
    let bytes = Data(
      "{\"schemaVersion\":1,\"vmID\":\"\(id)\",\"sessionID\":\"\(UUID())\",\"state\":\"\(kind == "unsettled" ? "unsettled" : "settled")\"}"
        .utf8)
    try await VMFiles().writeNewMetadata(
      bytes, at: f.source.appendingPathComponent(RuntimeIntent.filename))
  }
  await #expect(throws: VMError.self) {
    _ = try await VMFiles().prepareStoppedVMTrash(
      in: path, vmID: f.configuration.id, sink: f.sink, validate: { _, _, _ in })
  }
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashCancellationBeforeMoveReleasesWriterWithoutEffects() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let ticket = try await f.ticket()
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await ticket.commit()
  }
  await #expect(throws: CancellationError.self) { _ = try await task.value }
  #expect(await VMFiles().writerStatus(in: f.source) == .available)
  #expect(try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashCancellationAfterMoveReportsCommittedLocationAndHoldsWriterThroughMove()
  async throws
{
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let sink = StoppedVMTrashSink(
    directory: { _ in f.trash },
    move: { source, validate in
      do {
        try validate(source)
        #expect(throws: VMError.self) {
          _ = try VMLock(directory: source, expectedVMID: f.configuration.id)
        }
        try FileManager.default.moveItem(at: source, to: f.destination)
        #expect(throws: VMError.self) {
          _ = try VMLock(directory: f.destination, expectedVMID: f.configuration.id)
        }
        withUnsafeCurrentTask { $0?.cancel() }
        return .init(trashURL: f.destination, failed: false)
      } catch { return .init(trashURL: nil, failed: true) }
    })
  let ticket = try await f.ticket(sink: sink)
  let task = Task { try await ticket.commit() }
  let result = try await task.value
  #expect(result.status == .moved && result.cancellationObserved)
  #expect(result.trashURL == f.destination)
  #expect(await VMFiles().writerStatus(in: f.destination) == .available)
}

@Test(arguments: ["configuration-acl", "trash-replacement", "intent-bytes"])
func trashCommitRevalidatesCriticalACLAndDestination(_ change: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let ticket = try await f.ticket()
  if change == "configuration-acl" {
    try trashAddACL(f.source.appendingPathComponent("configuration.json"))
  } else if change == "trash-replacement" {
    try FileManager.default.moveItem(at: f.trash, to: f.root.appendingPathComponent("saved-trash"))
    try FileManager.default.createDirectory(
      at: f.trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  } else {
    try await VMFiles().writeNewMetadata(
      Data("{}".utf8), at: f.source.appendingPathComponent(RuntimeIntent.filename))
  }
  await #expect(throws: VMError.self) { _ = try await ticket.commit() }
  #expect(FileManager.default.fileExists(atPath: f.source.path))
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashDestinationCannotBeNestedWithinSource() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let nested = f.source.appendingPathComponent("nested")
  try FileManager.default.createDirectory(
    at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let sink = StoppedVMTrashSink(
    directory: { _ in nested }, move: { _, _ in .init(trashURL: nil, failed: true) })
  await #expect(throws: VMError.self) { _ = try await f.ticket(sink: sink) }
  #expect(FileManager.default.fileExists(atPath: nested.path))
}

@Test func trashWrongReturnedLocationCannotClaimConfirmedMove() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let sink = StoppedVMTrashSink(
    directory: { _ in f.trash },
    move: { source, validate in
      do {
        try validate(source)
        try FileManager.default.moveItem(at: source, to: f.destination)
        return .init(trashURL: f.trash.appendingPathComponent("wrong.macopenvm"), failed: false)
      } catch { return .init(trashURL: nil, failed: true) }
    })
  let ticket = try await f.ticket(sink: sink)
  let result = try await ticket.commit()
  #expect(result.status == .relocationUnverified)
  #expect(result.trashURL?.lastPathComponent == "wrong.macopenvm")
  #expect(FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashFailedMoveRetainsAnyUnverifiedReturnedURL() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let uncertain = f.trash.appendingPathComponent("reported-but-unverified.macopenvm")
  let sink = StoppedVMTrashSink(
    directory: { _ in f.trash },
    move: { _, _ in .init(trashURL: uncertain, failed: true) })
  let ticket = try await f.ticket(sink: sink)
  let result = try await ticket.commit()
  #expect(result.status == .relocationUnverified && result.trashURL == uncertain)
  #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func trashDenyDeleteContainerACLIsPreservedAndAdmitted() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  try trashAddACL(f.trash, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let fd = open(f.trash.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  #expect(fd >= 0)
  defer { if fd >= 0 { close(fd) } }
  let before = try #require(acl_get_fd_np(fd, ACL_TYPE_EXTENDED))
  defer { acl_free(UnsafeMutableRawPointer(before)) }
  let ticket = try await f.ticket()
  let result = try await ticket.commit()
  #expect(result.status == .moved)
  let after = try #require(acl_get_fd_np(fd, ACL_TYPE_EXTENDED))
  defer { acl_free(UnsafeMutableRawPointer(after)) }
  #expect(try trashACLBytes(before) == trashACLBytes(after))
}

@Test(arguments: ["allow", "deny-flags", "late-allow"])
func trashContainerACLRejectsGrantsAndNonzeroFlags(_ condition: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  if condition == "late-allow" {
    try trashAddACL(f.trash, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
    let ticket = try await f.ticket()
    try trashAddACL(f.trash)
    await #expect(throws: VMError.self) { _ = try await ticket.commit() }
  } else {
    try trashAddACL(
      f.trash, tag: condition == "allow" ? ACL_EXTENDED_ALLOW : ACL_EXTENDED_DENY,
      permission: ACL_DELETE, flag: condition == "deny-flags" ? ACL_ENTRY_DIRECTORY_INHERIT : nil)
    await #expect(throws: VMError.self) { _ = try await f.ticket() }
  }
  #expect(FileManager.default.fileExists(atPath: f.source.path))
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test(arguments: [
  "writer-admission", "source-folder", "trash-location", "registration", "snapshot",
])
func trashPrepareErrorsIdentifyOnlyBoundedAdmissionPhase(_ expectedPhase: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  var sink = f.sink
  if expectedPhase == "writer-admission" {
    try FileManager.default.removeItem(at: f.source.appendingPathComponent("writer.lock"))
  } else if expectedPhase == "source-folder" {
    #expect(chmod(f.source.path, 0o750) == 0)
  } else if expectedPhase == "registration" {
    try trashAddACL(f.source.appendingPathComponent("configuration.json"))
  } else if expectedPhase == "trash-location" {
    sink = .init(
      directory: { _ in
        throw NSError(
          domain: "sensitive-user-path-and-ACL-details", code: 9,
          userInfo: [NSFilePathErrorKey: f.source.path])
      }, move: { _, _ in .init(trashURL: nil, failed: true) })
  }
  do {
    _ = try await VMFiles().prepareStoppedVMTrash(
      in: f.source, vmID: f.configuration.id, sink: sink,
      validate: { _, _, _ in
        if expectedPhase == "snapshot" {
          throw VMError(.busy, "sensitive metadata and identity bytes", recovery: f.source.path)
        }
      })
    Issue.record("The intended preflight refusal did not occur.")
  } catch let error as VMError {
    #expect(error.code == (expectedPhase == "snapshot" ? .busy : .storage))
    #expect(error.message == "VM Trash admission failed at \(expectedPhase).")
    #expect(error.message.utf8.count < 96)
    #expect(!error.localizedDescription.contains(f.source.path))
    #expect(!error.localizedDescription.contains("sensitive"))
  }
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashCommitErrorIdentifiesPreflightWithoutInvokingMove() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let ticket = try await f.ticket()
  #expect(chmod(f.source.path, 0o750) == 0)
  do {
    _ = try await ticket.commit()
    Issue.record("The changed source permission was admitted.")
  } catch let error as VMError {
    #expect(error.code == .storage)
    #expect(error.message == "VM Trash admission failed at commit-source.")
    #expect(!error.localizedDescription.contains(f.source.path))
  }
  #expect(FileManager.default.fileExists(atPath: f.source.path))
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashAdmissionPhaseDoesNotConvertCancellation() {
  #expect(throws: CancellationError.self) {
    try TrashIO.phase(.snapshot) { throw CancellationError() }
  }
}

@Test func trashMetadataUsesParentAnchorAndAllowsOrdinaryContainerContentChanges() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  try trashAddACL(f.trash, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let parent = try TrashIO.openAncestry(f.root)
  defer { close(parent) }
  var identity = stat()
  #expect(fstat(parent, &identity) == 0)
  let snapshot = try TrashIO.trashMetadata(
    parent: parent, parentIdentity: identity, location: f.trash)
  try Data("another private test item".utf8).write(to: f.trash.appendingPathComponent("other"))
  try TrashIO.trashMetadataMatches(
    parent: parent, parentIdentity: identity, location: f.trash, expected: snapshot)
  #expect(!snapshot.aclBytes.isEmpty)
}

@Test(arguments: ["parent", "leaf", "deny-acl-change", "allow-acl-change", "symlink"])
func trashMetadataReplacementAndACLChangesRefuseBeforeMove(_ change: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let separateParent = f.root.appendingPathComponent("separate-destination-parent")
  let leaf = separateParent.appendingPathComponent("metadata-only-trash")
  for directory in [separateParent, leaf] {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  try trashAddACL(leaf, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let sink = StoppedVMTrashSink(
    directory: { _ in leaf },
    move: { source, validate in
      do {
        try validate(source)
        let target = leaf.appendingPathComponent("unexpected-move.macopenvm")
        try FileManager.default.moveItem(at: source, to: target)
        return .init(trashURL: target, failed: false)
      } catch { return .init(trashURL: nil, failed: true) }
    })
  let ticket = try await f.ticket(sink: sink)
  switch change {
  case "parent":
    try FileManager.default.moveItem(
      at: separateParent, to: f.root.appendingPathComponent("preserved-parent"))
    for directory in [separateParent, leaf] {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
  case "leaf", "symlink":
    let saved = separateParent.appendingPathComponent("preserved-leaf")
    try FileManager.default.moveItem(at: leaf, to: saved)
    if change == "symlink" {
      try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: saved)
    } else {
      try FileManager.default.createDirectory(
        at: leaf, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
  case "deny-acl-change":
    // Still DENY-only, but a new qualifier changes the captured ACL bytes.
    try trashAddACL(leaf, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  default: try trashAddACL(leaf)
  }
  await #expect(throws: VMError.self) { _ = try await ticket.commit() }
  #expect(FileManager.default.fileExists(atPath: f.source.path))
  #expect(
    !FileManager.default.fileExists(
      atPath: leaf.appendingPathComponent("unexpected-move.macopenvm").path))
}

@Test func trashDestinationParentDenyACLIsAdmitted() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let separateParent = f.root.appendingPathComponent("home-like-parent")
  let leaf = separateParent.appendingPathComponent("trash")
  for directory in [separateParent, leaf] {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  #expect(chmod(separateParent.path, 0o750) == 0)
  try trashAddACL(separateParent, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  try trashAddACL(leaf, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let sink = StoppedVMTrashSink(
    directory: { _ in leaf }, move: { _, _ in .init(trashURL: nil, failed: true) })
  let ticket = try await f.ticket(sink: sink)
  await ticket.cancel()
  #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test(arguments: [0o700, 0o750])
func trashSourceParentDenyACLIsPreservedWithoutGrantingWrite(_ mode: Int) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  #expect(chmod(f.root.path, mode_t(mode)) == 0)
  try trashAddACL(f.root, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let fd = open(f.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  #expect(fd >= 0)
  defer { if fd >= 0 { close(fd) } }
  let before = try #require(acl_get_fd_np(fd, ACL_TYPE_EXTENDED))
  defer { acl_free(UnsafeMutableRawPointer(before)) }
  let ticket = try await f.ticket()
  #expect(await VMFiles().writerStatus(in: f.source) == .held)
  let result = try await ticket.commit()
  #expect(result.status == .moved)
  let after = try #require(acl_get_fd_np(fd, ACL_TYPE_EXTENDED))
  defer { acl_free(UnsafeMutableRawPointer(after)) }
  #expect(try trashACLBytes(before) == trashACLBytes(after))
  #expect(
    try Data(contentsOf: f.destination.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(
    try Data(contentsOf: f.destination.appendingPathComponent("disk.raw"))
      == Data("disk bytes remain unchanged".utf8))
  #expect(await VMFiles().writerStatus(in: f.destination) == .available)
}

@Test(arguments: ["allow", "deny-entry-flags", "group-write"])
func trashSourceParentUnsafePermissionsAreRefusedBeforeMove(_ condition: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  try trashAddACL(
    f.root, tag: condition == "allow" ? ACL_EXTENDED_ALLOW : ACL_EXTENDED_DENY,
    permission: ACL_DELETE,
    flag: condition == "deny-entry-flags" ? ACL_ENTRY_DIRECTORY_INHERIT : nil)
  if condition == "group-write" { #expect(chmod(f.root.path, 0o770) == 0) }
  await #expect(throws: VMError.self) { _ = try await f.ticket() }
  #expect(FileManager.default.fileExists(atPath: f.source.path))
  #expect(try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(await VMFiles().writerStatus(in: f.source) == .available)
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test(arguments: ["late-deny", "late-allow", "safe-mode-change", "replacement"])
func trashSourceParentSelectionChangesRefuseBeforeMove(_ change: String) async throws {
  let f = try await trashFixture()
  var preserved: URL?
  defer {
    try? FileManager.default.removeItem(at: f.root)
    if let preserved { try? FileManager.default.removeItem(at: preserved) }
  }
  try trashAddACL(f.root, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let ticket = try await f.ticket()
  if change == "replacement" {
    let saved = f.root.appendingPathExtension("preserved")
    try FileManager.default.moveItem(at: f.root, to: saved)
    preserved = saved
    try FileManager.default.createDirectory(
      at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try trashAddACL(f.root, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  } else if change == "safe-mode-change" {
    #expect(chmod(f.root.path, 0o750) == 0)
  } else {
    // The new random qualifier changes exact ACL bytes even for DENY/delete.
    try trashAddACL(
      f.root, tag: change == "late-deny" ? ACL_EXTENDED_DENY : ACL_EXTENDED_ALLOW,
      permission: ACL_DELETE)
  }
  await #expect(throws: VMError.self) { _ = try await ticket.commit() }
  let original = (preserved ?? f.root).appendingPathComponent(f.source.lastPathComponent)
  #expect(try Data(contentsOf: original.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(await VMFiles().writerStatus(in: original) == .available)
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test(arguments: ["coordinator-deny", "coordinator-allow", "after-move", "failed-move"])
func trashSourceParentACLIsRevalidatedAcrossMove(_ condition: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  try trashAddACL(f.root, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let sink = StoppedVMTrashSink(
    directory: { _ in f.trash },
    move: { source, validate in
      do {
        if condition.hasPrefix("coordinator-") {
          try trashAddACL(
            f.root, tag: condition == "coordinator-deny" ? ACL_EXTENDED_DENY : ACL_EXTENDED_ALLOW,
            permission: ACL_DELETE)
        }
        try validate(source)
        if condition != "failed-move" {
          try FileManager.default.moveItem(at: source, to: f.destination)
        }
        try trashAddACL(f.root, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
        return .init(
          trashURL: condition == "failed-move" ? nil : f.destination,
          failed: condition == "failed-move")
      } catch { return .init(trashURL: nil, failed: true) }
    })
  let ticket = try await f.ticket(sink: sink)
  let result = try await ticket.commit()
  #expect(result.status == .relocationUnverified)
  let moved = condition == "after-move"
  #expect(FileManager.default.fileExists(atPath: f.destination.path) == moved)
  let original = moved ? f.destination : f.source
  #expect(try Data(contentsOf: original.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(await VMFiles().writerStatus(in: original) == .available)
}

@Test(arguments: ["folder", "configuration", "history", "intent", "writer"])
func trashSourceParentDenyACLDoesNotRelaxVMItems(_ item: String) async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  try trashAddACL(f.root, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let target: URL
  switch item {
  case "folder": target = f.source
  case "configuration": target = f.source.appendingPathComponent("configuration.json")
  case "writer": target = f.source.appendingPathComponent("writer.lock")
  case "history":
    target = f.source.appendingPathComponent("runtime.json")
    try await VMFiles().writeNewMetadata(Data("{}".utf8), at: target)
  default:
    target = f.source.appendingPathComponent(RuntimeIntent.filename)
    let bytes = Data(
      "{\"schemaVersion\":1,\"vmID\":\"\(f.configuration.id)\",\"sessionID\":\"\(UUID())\",\"state\":\"settled\"}"
        .utf8)
    try await VMFiles().writeNewMetadata(bytes, at: target)
  }
  try trashAddACL(target, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  await #expect(throws: VMError.self) {
    _ = try await VMFiles().prepareStoppedVMTrash(
      in: f.source, vmID: f.configuration.id, sink: f.sink, validate: { _, _, _ in })
  }
  #expect(FileManager.default.fileExists(atPath: f.source.path))
  #expect(try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test func trashSourceParentDenyACLCancelReleasesWriterWithoutEffects() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  try trashAddACL(f.root, tag: ACL_EXTENDED_DENY, permission: ACL_DELETE)
  let ticket = try await f.ticket()
  await ticket.cancel()
  await #expect(throws: VMError.self) { _ = try await ticket.commit() }
  #expect(await VMFiles().writerStatus(in: f.source) == .available)
  #expect(try Data(contentsOf: f.source.appendingPathComponent("configuration.json")) == f.bytes)
  #expect(!FileManager.default.fileExists(atPath: f.destination.path))
}

@Test(arguments: ["unknown-entry-flag", "unknown-container-flag", "unknown-permission"])
func trashDenyPolicyRejectsUnknownPublicACLMasks(_ condition: String) throws {
  var acl = acl_init(1)
  defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
  var entry: acl_entry_t?
  #expect(acl_create_entry(&acl, &entry) == 0)
  let created = try #require(acl)
  let ace = try #require(entry)
  #expect(acl_set_tag_type(ace, ACL_EXTENDED_DENY) == 0)
  let qualifier = UUID().uuid
  #expect(withUnsafeBytes(of: qualifier) { acl_set_qualifier(ace, $0.baseAddress) } == 0)
  if condition == "unknown-permission" {
    // Some platforms reject unknown masks at the setter; others preserve them
    // for validation. Either path must refuse the unrecognized authority.
    if acl_set_permset_mask_np(ace, acl_permset_mask_t(1) << 63) != 0 {
      print("ACL unknown-permission: SDK setter rejected; policy input was not constructed.")
      return
    }
  } else {
    var permissions: acl_permset_t?
    #expect(acl_get_permset(ace, &permissions) == 0)
    let permissionSet = try #require(permissions)
    #expect(acl_add_perm(permissionSet, ACL_DELETE) == 0)
    var flags: acl_flagset_t?
    let object =
      condition == "unknown-container-flag"
      ? UnsafeMutableRawPointer(created) : UnsafeMutableRawPointer(ace)
    #expect(acl_get_flagset_np(object, &flags) == 0)
    let flagSet = try #require(flags)
    let unknown = acl_flag_t(rawValue: 1 << 30)
    if acl_add_flag_np(flagSet, unknown) != 0 {
      print("ACL \(condition): SDK setter rejected; policy input was not constructed.")
      return
    }
  }
  let before = try trashACLBytes(created)
  #expect(throws: VMError.self) { try TrashIO.denyOnlyTrashACL(created) }
  #expect(try trashACLBytes(created) == before)
  print("ACL \(condition): constructed through SDK; policy rejected and input bytes preserved.")
}

@Test func trashMoveFailureAndAmbiguousCommitAreHonest() async throws {
  let f = try await trashFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let rejected = StoppedVMTrashSink(
    directory: { _ in f.trash }, move: { _, _ in .init(trashURL: nil, failed: true) })
  let first = try await f.ticket(sink: rejected)
  #expect(try await first.commit().status == .notMoved)
  let uncertain = StoppedVMTrashSink(
    directory: { _ in f.trash },
    move: { source, validate in
      do {
        try validate(source)
        try FileManager.default.moveItem(at: source, to: f.destination)
        return .init(trashURL: nil, failed: true)
      } catch { return .init(trashURL: nil, failed: true) }
    })
  let second = try await f.ticket(sink: uncertain)
  let result = try await second.commit()
  #expect(result.status == .relocationUnverified && result.trashURL == nil)
  #expect(FileManager.default.fileExists(atPath: f.destination.path))
}
