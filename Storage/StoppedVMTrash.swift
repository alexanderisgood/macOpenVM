// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

package struct StoppedVMTrashResult: Sendable {
  package enum Status: Sendable { case moved, relocationUnverified, notMoved }
  package let status: Status
  package let trashURL: URL?
  package let cancellationObserved: Bool
}

/// The production mover is fixed to Foundation's recoverable Trash operation.
/// Only tests inside VMStorage can inject a private-folder move.
struct StoppedVMTrashSink: Sendable {
  let directory: @Sendable (URL) throws -> URL
  let move: @Sendable (URL, @Sendable (URL) throws -> Void) -> StoppedVMTrashMove
  static let system = Self(
    directory: { source in
      try FileManager.default.url(
        for: .trashDirectory, in: .userDomainMask, appropriateFor: source, create: false)
    },
    move: { source, validate in
      var result: NSURL?
      var coordinationError: NSError?
      var failed = false
      var entered = false
      NSFileCoordinator().coordinate(
        writingItemAt: source, options: .forMoving, error: &coordinationError
      ) { coordinated in
        do {
          try validate(coordinated)
          entered = true
          try FileManager.default.trashItem(at: coordinated, resultingItemURL: &result)
        } catch { failed = true }
      }
      return .init(
        trashURL: result as URL?, failed: failed || coordinationError != nil || !entered)
    })
}

struct StoppedVMTrashMove: Sendable {
  let trashURL: URL?
  let failed: Bool
}

/// Private, non-serializable metadata only. No Trash directory is opened or listed.
struct TrashContainerMetadata: Sendable {
  let identity: stat
  let aclBytes: Data
}

package actor StoppedVMTrashTicket {
  private var owner: VMLock?
  private let source: URL
  private let vmID: UUID
  private let sourceAnchor: Int32
  private let parentAnchor: Int32
  private let trashParentAnchor: Int32
  private let parent: URL
  private let trash: URL
  private let sourceIdentity: stat
  private let parentIdentity: stat
  private let parentACLBytes: Data
  private let trashParentIdentity: stat
  private let trashMetadata: TrashContainerMetadata
  private let writerIdentity: stat
  private let registration: Data
  private let history: Data?
  private let intent: RuntimeIntent?
  private let intentBytes: Data?
  private let growthBytes: Data?
  private let sink: StoppedVMTrashSink
  private var attempted = false

  init(
    owner: VMLock, source: URL, vmID: UUID, sourceAnchor: Int32, parentAnchor: Int32,
    trashParentAnchor: Int32, sourceIdentity: stat, parentIdentity: stat, trashParentIdentity: stat,
    trashMetadata: TrashContainerMetadata, parentACLBytes: Data,
    writerIdentity: stat, trash: URL, registration: Data, history: Data?, intent: RuntimeIntent?,
    intentBytes: Data?, growthBytes: Data?, sink: StoppedVMTrashSink
  ) {
    self.owner = owner
    self.source = source
    self.vmID = vmID
    self.sourceAnchor = sourceAnchor
    self.parentAnchor = parentAnchor
    self.trashParentAnchor = trashParentAnchor
    self.sourceIdentity = sourceIdentity
    self.parentIdentity = parentIdentity
    self.parentACLBytes = parentACLBytes
    self.trashParentIdentity = trashParentIdentity
    self.trashMetadata = trashMetadata
    self.writerIdentity = writerIdentity
    self.trash = trash
    parent = source.deletingLastPathComponent()
    self.registration = registration
    self.history = history
    self.intent = intent
    self.intentBytes = intentBytes
    self.growthBytes = growthBytes
    self.sink = sink
  }
  deinit {
    close(sourceAnchor)
    close(parentAnchor)
    close(trashParentAnchor)
  }
  package func cancel() {
    attempted = true
    owner = nil
  }
  package func commit() throws -> StoppedVMTrashResult {
    let owner = try TrashIO.phase(.commitTicket) {
      guard !attempted, let owner else { throw TrashIO.failure(.staleOperation) }
      return owner
    }
    attempted = true
    defer { self.owner = nil }
    try Task.checkCancellation()
    try TrashIO.phase(.commitSourceAncestry) { try TrashIO.ancestry(source) }
    try TrashIO.phase(.commitTrashAncestry) {
      try TrashIO.ancestry(trash.deletingLastPathComponent())
    }
    try TrashIO.phase(.commitOwner) {
      guard owner.owns(source) else { throw TrashIO.failure(.staleOperation) }
    }
    try TrashIO.phase(.commitParent) {
      try revalidateParent()
    }
    try TrashIO.phase(.commitSource) {
      try TrashIO.matches(sourceAnchor, path: source, expected: sourceIdentity, privateMode: true)
    }
    try TrashIO.phase(.commitTrash) {
      try revalidateTrash()
    }
    try TrashIO.phase(.commitMetadata) { try revalidateMetadata() }
    try Task.checkCancellation()

    // Foundation accepts a path, not an inode-conditioned rename. These checks
    // detect prior replacements and post-move identity mismatches; they cannot
    // exclude a hostile same-UID rename in the final check-to-call interval.
    // There is deliberately no retry, rollback, permanent deletion or fallback.
    let move = sink.move(source) { coordinated in
      guard TrashIO.lexical(coordinated), coordinated.path == self.source.path else {
        throw TrashIO.failure(.staleOperation)
      }
      try TrashIO.ancestry(coordinated)
      guard owner.owns(coordinated) else { throw TrashIO.failure(.staleOperation) }
      try TrashIO.matches(
        self.parentAnchor, path: self.parent, expected: self.parentIdentity,
        denyOnlyACLBytes: self.parentACLBytes)
      try TrashIO.matches(
        self.sourceAnchor, path: coordinated, expected: self.sourceIdentity, privateMode: true)
      try TrashIO.trashMetadataMatches(
        parent: self.trashParentAnchor, parentIdentity: self.trashParentIdentity,
        location: self.trash, expected: self.trashMetadata)
      try Self.metadata(
        at: self.sourceAnchor, vmID: self.vmID, registration: self.registration,
        history: self.history, intent: self.intent, intentBytes: self.intentBytes,
        growthBytes: self.growthBytes, writer: self.writerIdentity)
      try Task.checkCancellation()
    }
    let returned = move.trashURL
    let cancelled = Task.isCancelled
    if let returned, (try? verifyRelocation(returned)) != nil {
      return .init(status: .moved, trashURL: returned, cancellationObserved: cancelled)
    }
    if move.failed, returned == nil, (try? verifyOriginal()) != nil {
      return .init(status: .notMoved, trashURL: nil, cancellationObserved: cancelled)
    }
    return .init(
      status: .relocationUnverified, trashURL: returned, cancellationObserved: cancelled)
  }

  private func revalidateMetadata() throws {
    try Self.metadata(
      at: sourceAnchor, vmID: vmID, registration: registration,
      history: history, intent: intent, intentBytes: intentBytes,
      growthBytes: growthBytes, writer: writerIdentity)
  }
  private func revalidateParent() throws {
    try TrashIO.matches(
      parentAnchor, path: parent, expected: parentIdentity, denyOnlyACLBytes: parentACLBytes)
  }
  private func revalidateTrash() throws {
    try TrashIO.trashMetadataMatches(
      parent: trashParentAnchor, parentIdentity: trashParentIdentity,
      location: trash, expected: trashMetadata)
  }
  fileprivate static func metadata(
    at anchor: Int32, vmID: UUID, registration: Data, history: Data?, intent: RuntimeIntent?,
    intentBytes: Data?, growthBytes: Data?, writer: stat
  ) throws {
    try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: vmID)
    try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: vmID)
    guard try TrashIO.read("configuration.json", at: anchor, limit: 65_536) == registration,
      try TrashIO.optionalRead("runtime.json", at: anchor, limit: 4096) == history,
      try RuntimeIntentIO.read(at: anchor) == intent,
      try TrashIO.optionalRead(RuntimeIntent.filename, at: anchor, limit: 4096) == intentBytes,
      try TrashIO.optionalRead(DiskGrowthIntent.filename, at: anchor, limit: 4096) == growthBytes
    else { throw TrashIO.failure(.staleOperation) }
    try TrashIO.writerMatches(at: anchor, expected: writer)
  }
  private func verifyOriginal() throws {
    try revalidateParent()
    try TrashIO.matches(sourceAnchor, path: source, expected: sourceIdentity, privateMode: true)
    try revalidateMetadata()
  }
  private func verifyRelocation(_ location: URL) throws {
    guard TrashIO.lexical(location), location.deletingLastPathComponent().path == trash.path,
      location.path != source.path
    else { throw TrashIO.failure(.staleOperation) }
    try revalidateParent()
    try revalidateTrash()
    try TrashIO.matches(sourceAnchor, path: location, expected: sourceIdentity, privateMode: true)
    var named = stat()
    guard fstatat(parentAnchor, source.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == -1,
      errno == ENOENT
    else { throw TrashIO.failure(.staleOperation) }
    try revalidateMetadata()
  }
}

extension VMFiles {
  package func prepareStoppedVMTrash(
    in directory: URL, vmID: UUID,
    validate: @Sendable (Data, Data?, RuntimeIntent?) throws -> Void
  ) throws -> StoppedVMTrashTicket {
    try prepareStoppedVMTrash(in: directory, vmID: vmID, sink: .system, validate: validate)
  }

  func prepareStoppedVMTrash(
    in directory: URL, vmID: UUID, sink: StoppedVMTrashSink,
    validate: @Sendable (Data, Data?, RuntimeIntent?) throws -> Void
  ) throws -> StoppedVMTrashTicket {
    try TrashIO.phase(.selection) {
      guard TrashIO.lexical(directory), directory.pathExtension.lowercased() == "macopenvm" else {
        throw TrashIO.failure(.invalidConfiguration)
      }
    }
    try Task.checkCancellation()
    try TrashIO.phase(.sourceAncestry) { try TrashIO.ancestry(directory) }
    let owner = try TrashIO.phase(.writerAdmission) {
      try VMLock(existingDirectory: directory, expectedVMID: vmID)
    }
    try TrashIO.phase(.writerReservation) { try owner.reserveTrash(forVMID: vmID) }
    var anchor: Int32 = -1
    var retained = false
    defer { if !retained, anchor >= 0 { close(anchor) } }
    try TrashIO.phase(.sourceAnchor) {
      try owner.withRuntimeIntentDirectory { directory in
        anchor = fcntl(directory, F_DUPFD_CLOEXEC, 3)
        guard anchor >= 0 else { throw TrashIO.failure(.storage) }
      }
    }
    let sourceIdentity = try TrashIO.phase(.sourceFolder) {
      try TrashIO.info(anchor, privateMode: true)
    }
    let parent = directory.deletingLastPathComponent()
    let parentFD = try TrashIO.phase(.sourceParent) {
      try TrashIO.openDirectory(parent, allowDenyOnlyACL: true)
    }
    defer { if !retained { close(parentFD) } }
    let parentMetadata = try TrashIO.phase(.sourceParent) {
      try TrashIO.sourceParentMetadata(parentFD, path: parent)
    }
    let trash = try TrashIO.phase(.trashLocation) {
      let location = try sink.directory(directory)
      guard TrashIO.lexical(location), location.path != directory.path,
        !directory.path.hasPrefix(location.path + "/"),
        !location.path.hasPrefix(directory.path + "/")
      else { throw TrashIO.failure(.unsupported) }
      return location
    }
    let trashParentFD = try TrashIO.phase(.trashAncestry) {
      try TrashIO.openAncestry(trash.deletingLastPathComponent())
    }
    defer { if !retained { close(trashParentFD) } }
    let trashParentIdentity = try TrashIO.phase(.trashAncestry) {
      var identity = stat()
      guard fstat(trashParentFD, &identity) == 0 else { throw TrashIO.failure(.storage) }
      return identity
    }
    let trashMetadata = try TrashIO.phase(.trashContainer) {
      try TrashIO.trashMetadata(
        parent: trashParentFD, parentIdentity: trashParentIdentity, location: trash)
    }
    try TrashIO.phase(.sameVolume) {
      guard sourceIdentity.st_dev == trashMetadata.identity.st_dev else {
        throw TrashIO.failure(.unsupported)
      }
    }
    try TrashIO.phase(.trashIdentity) {
      try TrashIO.trashMetadataMatches(
        parent: trashParentFD, parentIdentity: trashParentIdentity,
        location: trash, expected: trashMetadata)
    }
    let registration = try TrashIO.phase(.registration) {
      try TrashIO.read("configuration.json", at: anchor, limit: 65_536)
    }
    let history = try TrashIO.phase(.history) {
      try TrashIO.optionalRead("runtime.json", at: anchor, limit: 4096)
    }
    let intent = try TrashIO.phase(.intent) { try RuntimeIntentIO.read(at: anchor) }
    let intentBytes = try TrashIO.phase(.intent) {
      try TrashIO.optionalRead(RuntimeIntent.filename, at: anchor, limit: 4096)
    }
    let growthBytes = try TrashIO.phase(.growth) {
      try TrashIO.optionalRead(DiskGrowthIntent.filename, at: anchor, limit: 4096)
    }
    try TrashIO.phase(.snapshot) { try validate(registration, history, intent) }
    let writer = try TrashIO.phase(.writerIdentity) { try TrashIO.writerInfo(at: anchor) }
    try TrashIO.phase(.metadataRevalidation) {
      try StoppedVMTrashTicket.metadata(
        at: anchor, vmID: vmID, registration: registration, history: history, intent: intent,
        intentBytes: intentBytes, growthBytes: growthBytes, writer: writer)
    }
    try TrashIO.phase(.sourceIdentity) {
      try TrashIO.matches(
        parentFD, path: parent, expected: parentMetadata.identity,
        denyOnlyACLBytes: parentMetadata.aclBytes)
      try TrashIO.matches(anchor, path: directory, expected: sourceIdentity, privateMode: true)
      guard owner.owns(directory) else { throw TrashIO.failure(.staleOperation) }
    }
    try Task.checkCancellation()
    let ticket = StoppedVMTrashTicket(
      owner: owner, source: directory, vmID: vmID, sourceAnchor: anchor, parentAnchor: parentFD,
      trashParentAnchor: trashParentFD, sourceIdentity: sourceIdentity,
      parentIdentity: parentMetadata.identity,
      trashParentIdentity: trashParentIdentity, trashMetadata: trashMetadata,
      parentACLBytes: parentMetadata.aclBytes,
      writerIdentity: writer, trash: trash,
      registration: registration, history: history, intent: intent,
      intentBytes: intentBytes, growthBytes: growthBytes, sink: sink)
    retained = true
    return ticket
  }
}

enum TrashIO {
  enum Phase: String {
    case selection
    case sourceAncestry = "source-ancestry"
    case writerAdmission = "writer-admission"
    case writerReservation = "writer-reservation"
    case sourceAnchor = "source-anchor"
    case sourceFolder = "source-folder"
    case sourceParent = "source-parent"
    case trashLocation = "trash-location"
    case trashAncestry = "trash-ancestry"
    case trashContainer = "trash-container"
    case sameVolume = "same-volume"
    case trashIdentity = "trash-identity"
    case registration
    case history
    case intent
    case growth
    case snapshot
    case writerIdentity = "writer-identity"
    case metadataRevalidation = "metadata-revalidation"
    case sourceIdentity = "source-identity"
    case commitTicket = "commit-ticket"
    case commitSourceAncestry = "commit-source-ancestry"
    case commitTrashAncestry = "commit-trash-ancestry"
    case commitOwner = "commit-owner"
    case commitParent = "commit-parent"
    case commitSource = "commit-source"
    case commitTrash = "commit-trash"
    case commitMetadata = "commit-metadata"
  }
  /// Preflight errors retain their typed category, but never underlying paths,
  /// NSError text, ACL qualifiers or metadata. Native admitted moves bypass this.
  static func phase<Result>(_ phase: Phase, _ body: () throws -> Result) throws -> Result {
    do { return try body() } catch is CancellationError { throw CancellationError() } catch {
      throw VMError(
        (error as? VMError)?.code ?? .storage,
        "VM Trash admission failed at \(phase.rawValue).",
        recovery:
          "The move was not admitted. Preserve the VM and use read-only inspection before retrying."
      )
    }
  }
  static func lexical(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && url.path.hasPrefix("/") && url.path.utf8.count <= 4096
      && url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
      && !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
  static func ancestry(_ url: URL) throws {
    let fd = try openAncestry(url)
    close(fd)
  }
  /// Trash calls this for its parent, never its protected leaf. Each directory
  /// hop still rejects aliases and additional permission grants.
  static func openAncestry(_ url: URL) throws -> Int32 {
    guard lexical(url) else { throw failure(.invalidConfiguration) }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw failure(.storage) }
    var retained = false
    defer { if !retained { close(fd) } }
    for component in url.path.split(separator: "/") {
      let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard next >= 0 else { throw failure(.storage) }
      close(fd)
      fd = next
      var value = stat()
      guard fstat(fd, &value) == 0, value.st_uid == geteuid() || value.st_uid == 0,
        value.st_mode & 0o022 == 0
          || (value.st_uid == 0 && value.st_mode & S_ISVTX != 0)
      else { throw failure(.storage) }
      try safeAncestorACL(fd)
    }
    retained = true
    return fd
  }
  /// Deny-only ACLs (including macOS home-folder delete protection) grant no
  /// additional rename/write authority. Any allow ACE is refused conservatively.
  static func safeAncestorACL(_ fd: Int32) throws {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
      guard errno == ENOENT else { throw failure(.storage) }
      return
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_valid(acl) == 0 else { throw failure(.storage) }
    var entry: acl_entry_t?
    var selector = ACL_FIRST_ENTRY.rawValue
    for index in 0...128 {
      errno = 0
      let result = acl_get_entry(acl, selector, &entry)
      if result == -1, errno == EINVAL { return }
      guard result == 0, index < 128, let entry else { throw failure(.storage) }
      var tag = ACL_UNDEFINED_TAG
      guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
        throw failure(.storage)
      }
      selector = ACL_NEXT_ENTRY.rawValue
    }
    throw failure(.storage)
  }
  static func openDirectory(_ url: URL, allowDenyOnlyACL: Bool = false) throws -> Int32 {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw failure(.storage) }
    do { _ = try info(fd, allowDenyOnlyACL: allowDenyOnlyACL) } catch {
      close(fd)
      throw error
    }
    return fd
  }
  static func info(
    _ fd: Int32, privateMode: Bool = false, allowDenyOnlyACL: Bool = false
  ) throws
    -> stat
  {
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
      value.st_uid == geteuid(), value.st_mode & 0o022 == 0,
      !privateMode || value.st_mode & 0o7777 == 0o700
    else { throw failure(.storage) }
    if allowDenyOnlyACL {
      _ = try denyOnlyACLBytes(fd)
    } else {
      try StoppedDiskCloneIO.noACL(fd)
    }
    return value
  }
  static func matches(
    _ fd: Int32, path: URL, expected: stat, privateMode: Bool = false,
    denyOnlyACLBytes expectedACL: Data? = nil
  ) throws {
    let opened = try info(fd, privateMode: privateMode, allowDenyOnlyACL: expectedACL != nil)
    var named = stat()
    guard lstat(path.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
      opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino,
      named.st_dev == expected.st_dev, named.st_ino == expected.st_ino,
      named.st_mode == opened.st_mode, named.st_uid == opened.st_uid
    else { throw failure(.staleOperation) }
    if let expectedACL {
      guard sameDirectory(opened, expected), try denyOnlyACLBytes(fd) == expectedACL else {
        throw failure(.staleOperation)
      }
    }
  }

  /// The source parent may retain standard macOS DENY/delete protection. Its
  /// exact ACL is pinned; source bundles and their metadata retain no-ACL rules.
  static func sourceParentMetadata(_ fd: Int32, path: URL) throws -> TrashContainerMetadata {
    let before = try info(fd, allowDenyOnlyACL: true)
    let aclBytes = try denyOnlyACLBytes(fd)
    try matches(fd, path: path, expected: before, denyOnlyACLBytes: aclBytes)
    let after = try info(fd, allowDenyOnlyACL: true)
    guard sameDirectory(before, after),
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw failure(.staleOperation) }
    return TrashContainerMetadata(identity: after, aclBytes: aclBytes)
  }

  private static func denyOnlyACLBytes(_ fd: Int32) throws -> Data {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
      guard errno == ENOENT else { throw failure(.storage) }
      return Data()
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    let bytes = try externalACL(acl)
    try denyOnlyTrashACL(acl)
    return bytes
  }

  static func trashMetadata(
    parent: Int32, parentIdentity: stat, location: URL
  ) throws -> TrashContainerMetadata {
    let parentURL = location.deletingLastPathComponent()
    try ancestryMatches(parent, path: parentURL, expected: parentIdentity)
    let before = try trashLeaf(parent: parent, location: location)
    let aclBytes: Data
    if let acl = acl_get_link_np(location.path, ACL_TYPE_EXTENDED) {
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      aclBytes = try externalACL(acl)
      try denyOnlyTrashACL(acl)
    } else {
      // ACL absence is admissible only between two matching existing directory
      // samples. Permission errors never fall back to POSIX mode alone.
      guard errno == ENOENT else { throw failure(.storage) }
      aclBytes = Data()
    }
    let after = try trashLeaf(parent: parent, location: location)
    guard sameDirectory(before, after),
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw failure(.staleOperation) }
    try ancestryMatches(parent, path: parentURL, expected: parentIdentity)
    return TrashContainerMetadata(identity: after, aclBytes: aclBytes)
  }

  static func trashMetadataMatches(
    parent: Int32, parentIdentity: stat, location: URL, expected: TrashContainerMetadata
  ) throws {
    let actual = try trashMetadata(
      parent: parent, parentIdentity: parentIdentity, location: location)
    // Inserting a moved bundle legitimately changes directory size and times.
    // Across operations only identity, safe ownership/mode and the ACL are pinned.
    guard sameDirectory(actual.identity, expected.identity), actual.aclBytes == expected.aclBytes
    else { throw failure(.staleOperation) }
  }

  private static func ancestryMatches(_ fd: Int32, path: URL, expected: stat) throws {
    try ancestry(path)
    try safeAncestorACL(fd)
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0, lstat(path.path, &named) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid() || opened.st_uid == 0,
      opened.st_mode & 0o022 == 0
        || (opened.st_uid == 0 && opened.st_mode & S_ISVTX != 0),
      opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino,
      sameDirectory(opened, named)
    else { throw failure(.staleOperation) }
  }

  private static func trashLeaf(parent: Int32, location: URL) throws -> stat {
    guard lexical(location) else { throw failure(.invalidConfiguration) }
    var anchored = stat()
    var named = stat()
    guard fstatat(parent, location.lastPathComponent, &anchored, AT_SYMLINK_NOFOLLOW) == 0,
      lstat(location.path, &named) == 0,
      anchored.st_mode & S_IFMT == S_IFDIR, anchored.st_uid == geteuid(),
      anchored.st_mode & 0o7777 == 0o700, sameDirectory(anchored, named)
    else { throw failure(.storage) }
    return anchored
  }

  private static func sameDirectory(_ first: stat, _ second: stat) -> Bool {
    first.st_mode & S_IFMT == S_IFDIR && second.st_mode & S_IFMT == S_IFDIR
      && first.st_dev == second.st_dev && first.st_ino == second.st_ino
      && first.st_uid == second.st_uid && first.st_mode == second.st_mode
  }

  /// macOS's ordinary Trash may protect itself with a DENY/delete ACL. This
  /// container/source-parent policy preserves ACLs and admits no permission grants.
  /// Source folders and VM files continue to require no extended ACL at all.
  static func denyOnlyTrashACL(_ acl: acl_t) throws {
    guard let validated = acl_dup(acl) else { throw failure(.storage) }
    defer { acl_free(UnsafeMutableRawPointer(validated)) }
    // acl_valid may reorder its argument. Validate a separate duplicate so the
    // sampled ACL and the flag comparison retain their original external order.
    guard acl_valid(validated) == 0, let stripped = acl_dup(acl) else {
      throw failure(.storage)
    }
    defer { acl_free(UnsafeMutableRawPointer(stripped)) }
    var maximal: acl_permset_mask_t = 0
    guard acl_maximal_permset_mask_np(&maximal) == 0 else { throw failure(.storage) }
    var containerFlags: acl_flagset_t?
    guard acl_get_flagset_np(UnsafeMutableRawPointer(stripped), &containerFlags) == 0,
      let containerFlags, acl_clear_flags_np(containerFlags) == 0
    else { throw failure(.storage) }
    var entry: acl_entry_t?
    var selector = ACL_FIRST_ENTRY.rawValue
    var ended = false
    for index in 0...128 {
      errno = 0
      let result = acl_get_entry(stripped, selector, &entry)
      if result == -1, errno == EINVAL {
        ended = true
        break
      }
      guard result == 0, index < 128, let entry else { throw failure(.storage) }
      var tag = ACL_UNDEFINED_TAG
      var permissions: acl_permset_mask_t = 0
      var flags: acl_flagset_t?
      guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY,
        acl_get_permset_mask_np(entry, &permissions) == 0, permissions & ~maximal == 0,
        acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
        acl_clear_flags_np(flags) == 0
      else { throw failure(.storage) }
      selector = ACL_NEXT_ENTRY.rawValue
    }
    // Public external representations are compared without reading any private
    // ACL structure. Clearing the duplicate detects all flag bits, including
    // unknown flags, without modifying the user's actual filesystem ACL.
    guard ended, try externalACL(acl) == externalACL(stripped) else { throw failure(.storage) }
  }
  private static func externalACL(_ acl: acl_t) throws -> Data {
    let size = acl_size(acl)
    guard size > 0, size <= 65_536 else { throw failure(.storage) }
    var bytes = Data(count: size)
    let count = bytes.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, size) }
    guard count == size else { throw failure(.storage) }
    return bytes
  }
  static func read(_ name: String, at anchor: Int32, limit: Int) throws -> Data {
    let fd = openat(anchor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw failure(.storage) }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, DiskGrowthIO.safe(before),
      before.st_size > 0, before.st_size <= limit
    else { throw failure(.storage) }
    try StoppedDiskCloneIO.noACL(fd)
    var bytes = Data()
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    while let chunk = try handle.read(upToCount: limit - bytes.count + 1), !chunk.isEmpty {
      bytes.append(chunk)
      guard bytes.count <= limit else { throw failure(.corruptMetadata) }
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0,
      fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      DiskGrowthIO.stable(before, after), DiskGrowthIO.stable(after, named),
      bytes.count == before.st_size
    else { throw failure(.staleOperation) }
    try StoppedDiskCloneIO.noACL(fd)
    return bytes
  }
  static func optionalRead(_ name: String, at anchor: Int32, limit: Int) throws -> Data? {
    var value = stat()
    guard fstatat(anchor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw failure(.storage)
    }
    return try read(name, at: anchor, limit: limit)
  }
  static func writerInfo(at anchor: Int32) throws -> stat {
    let fd = openat(anchor, "writer.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw failure(.storage) }
    defer { close(fd) }
    try StoppedDiskCloneIO.noACL(fd)
    var value = stat()
    guard fstat(fd, &value) == 0, DiskGrowthIO.safe(value) else { throw failure(.storage) }
    return value
  }
  static func writerMatches(at anchor: Int32, expected: stat) throws {
    let current = try writerInfo(at: anchor)
    guard current.st_dev == expected.st_dev, current.st_ino == expected.st_ino else {
      throw failure(.staleOperation)
    }
  }
  static func failure(_ code: VMError.Code) -> VMError {
    VMError(
      code, "The stopped VM cannot be safely moved to Trash.",
      recovery: "Preserve the VM. Use a private stopped bundle and an available same-volume Trash.")
  }
}
