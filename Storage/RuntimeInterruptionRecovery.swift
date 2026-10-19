// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// Explicit operator evidence is retained verbatim; it is not a backend/reaping receipt.
package enum RuntimeInterruptionEvidence: Encodable, Equatable, Sendable {
  case hostReboot(rebootObservation: Data, processObservation: Data)
  case abandonedOwner(ownerExitObservation: Data, processObservation: Data)

  package init(rebootObservation: Data, processObservation: Data) {
    self = .hostReboot(rebootObservation: rebootObservation, processObservation: processObservation)
  }

  package init(ownerExitObservation: Data, processObservation: Data) {
    self = .abandonedOwner(
      ownerExitObservation: ownerExitObservation, processObservation: processObservation)
  }

  package var basis: String {
    switch self {
    case .hostReboot: "operator-observed-host-reboot-and-reviewed-processes"
    case .abandonedOwner: "operator-reviewed-owner-exit-and-no-other-runtime"
    }
  }

  package var isBoundedNonempty: Bool {
    let observation: Data
    let processes: Data
    switch self {
    case .hostReboot(let reboot, let process):
      observation = reboot
      processes = process
    case .abandonedOwner(let ownerExit, let process):
      observation = ownerExit
      processes = process
    }
    return !observation.isEmpty && observation.count <= 65_536
      && !processes.isEmpty && processes.count <= 65_536
  }

  private enum CodingKeys: String, CodingKey {
    case rebootObservation, ownerExitObservation, processObservation
  }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hostReboot(let reboot, let process):
      // Preserve the existing reboot archive's exact evidence shape.
      try values.encode(reboot, forKey: .rebootObservation)
      try values.encode(process, forKey: .processObservation)
    case .abandonedOwner(let ownerExit, let process):
      try values.encode(ownerExit, forKey: .ownerExitObservation)
      try values.encode(process, forKey: .processObservation)
    }
  }
}

package struct RuntimeInterruptionKernel: Encodable, Equatable, Sendable {
  package let bootSessionID: UUID
  package let bootSeconds: Int64
  package let bootMicroseconds: Int32

  static func capture() throws -> Self {
    var bytes = [UInt8](repeating: 0, count: 128)
    var count = bytes.count
    let status = bytes.withUnsafeMutableBytes {
      sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &count, nil, 0)
    }
    guard status == 0, count == 36 || (count == 37 && bytes[36] == 0) else {
      throw interruptionFailure(.storage)
    }
    let text = String(decoding: bytes.prefix(36), as: UTF8.self)
    guard let id = UUID(uuidString: text), id.uuidString == text.uppercased(),
      id.uuidString != "00000000-0000-0000-0000-000000000000"
    else { throw interruptionFailure(.storage) }
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
      size == MemoryLayout<timeval>.size, boot.tv_sec > 0,
      boot.tv_usec >= 0, boot.tv_usec < 1_000_000
    else { throw interruptionFailure(.storage) }
    return .init(
      bootSessionID: id, bootSeconds: Int64(boot.tv_sec),
      bootMicroseconds: Int32(boot.tv_usec))
  }
}

/// Current mount numbers bind this live operation only. Historical route devices are archived,
/// never compared with a new APFS mount assignment or used to reconnect an old endpoint.
private struct InterruptionFact: Encodable, Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let mode: UInt16
  let owner: UInt32
  let links: UInt16
  let bytes: Int64
  let modifiedSeconds: Int64
  let modifiedNanos: Int64
  let changedSeconds: Int64
  let changedNanos: Int64

  init(_ value: stat, directory: Bool = false) {
    device = value.st_dev
    inode = value.st_ino
    mode = value.st_mode
    owner = value.st_uid
    links = directory ? 0 : value.st_nlink
    bytes = directory ? 0 : value.st_size
    modifiedSeconds = directory ? 0 : Int64(value.st_mtimespec.tv_sec)
    modifiedNanos = directory ? 0 : Int64(value.st_mtimespec.tv_nsec)
    changedSeconds = directory ? 0 : Int64(value.st_ctimespec.tv_sec)
    changedNanos = directory ? 0 : Int64(value.st_ctimespec.tv_nsec)
  }
}

private struct InterruptionEntry: Encodable, Equatable, Sendable {
  let name: String
  let bytes: Data?
  let fact: InterruptionFact?
}

/// Captured by the actual bounded reader. Digest/identities are observations, not authority.
package struct RuntimeInterruptionSnapshot: Encodable, Equatable, Sendable {
  package let vmID: UUID
  package let interruptedSessionID: UUID
  package let runName: String
  package let kernel: RuntimeInterruptionKernel
  fileprivate let directory: InterruptionFact
  fileprivate let writer: InterruptionFact
  fileprivate let disk: InterruptionFact
  fileprivate let runtimeDirectory: InterruptionFact
  fileprivate let runDirectory: InterruptionFact
  fileprivate let entries: [InterruptionEntry]
  package var configuration: Data { entries[0].bytes! }
  package var intentBytes: Data { entries[1].bytes! }
  package var history: Data { entries[2].bytes! }
  package var digest: String { get throws { try InterruptionIO.digest(self) } }
}

package enum RuntimeInterruptionFault: String, CaseIterable, Sendable {
  case afterArchive, afterPending, afterHistory, beforeFinal, afterFinal
}

/// Owns actual positive exclusive custody. No initializer, launch permit, inheritance API or
/// general writer API is exposed. Core retains this owner after any ambiguous commit failure.
package final class RuntimeInterruptionLease: Sendable {
  package let vmID: UUID
  package let interruptedSessionID: UUID
  package let recoveryID: UUID
  fileprivate let snapshot: RuntimeInterruptionSnapshot
  fileprivate let path: String
  fileprivate let anchor: Int32
  private let writer: Int32
  private let disk: Int32
  private let claim = InterruptionClaim()

  fileprivate init(
    directory: URL, snapshot: RuntimeInterruptionSnapshot, recoveryID: UUID
  ) throws {
    let parent = try DiskGrowthIO.openDirectory(directory)
    var kept = false
    defer { if !kept { close(parent) } }
    // A missing/replaced lock is never repaired or created by recovery.
    let fd = openat(parent, "writer.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw interruptionFailure(.storage) }
    var keptWriter = false
    defer { if !keptWriter { close(fd) } }
    var opened = stat()
    guard fstat(fd, &opened) == 0, DiskGrowthIO.safe(opened),
      InterruptionFact(opened) == snapshot.writer,
      flock(fd, LOCK_EX | LOCK_NB) == 0
    else { throw interruptionFailure(.busy) }
    let config = try DiskGrowthIO.decodeConfiguration(snapshot.configuration)
    let diskFD = try DiskGrowthIO.openDisk(config.diskFile, at: parent, writable: false)
    var keptDisk = false
    defer { if !keptDisk { close(diskFD) } }
    var diskInfo = stat()
    guard fstat(diskFD, &diskInfo) == 0, InterruptionFact(diskInfo) == snapshot.disk,
      recoveryID != snapshot.interruptedSessionID,
      recoveryID.uuidString != "00000000-0000-0000-0000-000000000000",
      try InterruptionIO.capture(
        at: parent, vmID: snapshot.vmID, sessionID: snapshot.interruptedSessionID,
        runName: snapshot.runName) == snapshot
    else { throw interruptionFailure(.staleOperation) }
    self.snapshot = snapshot
    vmID = snapshot.vmID
    interruptedSessionID = snapshot.interruptedSessionID
    self.recoveryID = recoveryID
    path = directory.standardizedFileURL.path
    anchor = parent
    writer = fd
    disk = diskFD
    kept = true
    keptWriter = true
    keptDisk = true
  }

  func checkedAnchor() throws -> Int32 {
    var parent = stat()
    var selected = stat()
    var held = stat()
    var named = stat()
    var diskInfo = stat()
    let config = try DiskGrowthIO.decodeConfiguration(snapshot.configuration)
    var namedDisk = stat()
    guard fstat(anchor, &parent) == 0, lstat(path, &selected) == 0,
      InterruptionIO.safeDirectory(parent), InterruptionIO.safeDirectory(selected),
      InterruptionFact(parent, directory: true) == snapshot.directory,
      InterruptionFact(selected, directory: true) == snapshot.directory,
      fstat(writer, &held) == 0,
      fstatat(anchor, "writer.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
      DiskGrowthIO.safe(held), DiskGrowthIO.safe(named),
      InterruptionFact(held) == snapshot.writer, InterruptionFact(named) == snapshot.writer,
      fstat(disk, &diskInfo) == 0,
      fstatat(anchor, config.diskFile, &namedDisk, AT_SYMLINK_NOFOLLOW) == 0,
      DiskGrowthIO.safe(diskInfo), DiskGrowthIO.safe(namedDisk),
      InterruptionFact(diskInfo) == snapshot.disk, InterruptionFact(namedDisk) == snapshot.disk
    else { throw interruptionFailure(.staleOperation) }
    return anchor
  }

  fileprivate func reserve() throws { try claim.reserve() }
  deinit {
    close(disk)
    close(writer)
    close(anchor)
  }
}

private final class InterruptionClaim: @unchecked Sendable {
  private let mutex = NSLock()
  private var attempted = false
  func reserve() throws {
    mutex.lock()
    defer { mutex.unlock() }
    guard !attempted else { throw interruptionFailure(.busy) }
    attempted = true
  }
}

private struct InterruptionArchive: Encodable, Sendable {
  let schemaVersion = 1
  let scope = "macopenvm-explicit-operator-interruption-recovery"
  let basis: String
  let recoveryID: UUID
  let oldSessionNormallySettled = false
  let oldChildReapingProved = false
  let oldBackendQuiescenceReceipt = false
  let prior: RuntimeInterruptionSnapshot
  let evidence: RuntimeInterruptionEvidence
  let newFailedHistory: Data

  init(
    recoveryID: UUID, prior: RuntimeInterruptionSnapshot, evidence: RuntimeInterruptionEvidence,
    newFailedHistory: Data
  ) {
    basis = evidence.basis
    self.recoveryID = recoveryID
    self.prior = prior
    self.evidence = evidence
    self.newFailedHistory = newFailedHistory
  }
}

extension VMFiles {
  package func inspectOperatorInterruption(
    in directory: URL, vmID: UUID, sessionID: UUID, runName: String
  ) throws -> RuntimeInterruptionSnapshot {
    let anchor = try DiskGrowthIO.openDirectory(directory)
    defer { close(anchor) }
    guard let intent = try RuntimeIntentIO.read(at: anchor), intent.vmID == vmID,
      intent.sessionID == sessionID, intent.state == .unsettled
    else { throw interruptionFailure(.staleOperation) }
    let observed = try InterruptionIO.capture(
      at: anchor, vmID: vmID, sessionID: sessionID, runName: runName)
    guard try RuntimeIntentIO.read(at: anchor) == intent else {
      throw interruptionFailure(.staleOperation)
    }
    try InterruptionIO.validateHistoricalBindings(observed)
    return observed
  }

  package func acquireOperatorInterruption(
    in directory: URL, observed: RuntimeInterruptionSnapshot, recoveryID: UUID
  ) throws -> RuntimeInterruptionLease {
    // Refuse an already-unadmitted growth journal before acquiring recovery custody.
    // Commit repeats this check under the retained lease before its first write.
    let preflight = try DiskGrowthIO.openDirectory(directory)
    defer { close(preflight) }
    try DiskGrowthIO.requireAdmission(at: preflight, expectedVMID: observed.vmID)
    let owner = try RuntimeInterruptionLease(
      directory: directory, snapshot: observed, recoveryID: recoveryID)
    _ = try owner.checkedAnchor()
    guard let intent = try RuntimeIntentIO.read(at: owner.anchor),
      intent.vmID == observed.vmID, intent.sessionID == observed.interruptedSessionID,
      intent.state == .unsettled
    else { throw interruptionFailure(.staleOperation) }
    return owner
  }

  /// Core supplies an independently encoded/validated new-ID failed history. No old permit,
  /// RuntimeSettlementReceipt, backend terminal result or normal-shutdown claim is fabricated.
  package func commitOperatorInterruption(
    lease: RuntimeInterruptionLease, evidence: RuntimeInterruptionEvidence,
    failedHistory: Data, fault: RuntimeInterruptionFault? = nil
  ) throws -> String {
    try lease.reserve()
    try Task.checkCancellation()
    guard !failedHistory.isEmpty, failedHistory.count <= 4096, evidence.isBoundedNonempty
    else { throw interruptionFailure(.invalidConfiguration) }
    let old = lease.snapshot
    let anchor = try lease.checkedAnchor()
    try InterruptionIO.requireCurrent(lease, intent: old.intentBytes, history: old.history)
    // Keep the existing disk-growth policy; recovery never waives a pending/unsafe journal.
    try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: lease.vmID)
    let archive = InterruptionArchive(
      recoveryID: lease.recoveryID, prior: old, evidence: evidence,
      newFailedHistory: failedHistory)
    let bytes = try InterruptionIO.encode(archive)
    guard bytes.count <= 262_144 else { throw interruptionFailure(.invalidConfiguration) }
    let name = "runtime-interruption-\(lease.recoveryID.uuidString.lowercased()).json"
    try DiskGrowthIO.exclusive(bytes, name: name, at: anchor)
    guard fsync(anchor) == 0,
      try DiskGrowthIO.readFile(name, at: anchor, limit: 262_144) == bytes
    else { throw interruptionFailure(.storage) }
    try InterruptionIO.requireCurrent(lease, intent: old.intentBytes, history: old.history)
    try InterruptionIO.checkpoint(.afterArchive, fault)
    try RuntimeIntentIO.commitOperatorInterruption(lease, settled: false)
    let pending = try DiskGrowthIO.readFile(RuntimeIntent.filename, at: anchor, limit: 4096)
    try InterruptionIO.requireCurrent(lease, intent: pending, history: old.history)
    try InterruptionIO.checkpoint(.afterPending, fault)
    try DiskGrowthIO.atomic(failedHistory, name: "runtime.json", at: anchor)
    try InterruptionIO.requireCurrent(lease, intent: pending, history: failedHistory)
    try InterruptionIO.checkpoint(.afterHistory, fault)
    // Archive readback is rechecked before the only transition admitting an ordinary new Start.
    guard try DiskGrowthIO.readFile(name, at: anchor, limit: 262_144) == bytes else {
      throw interruptionFailure(.storage)
    }
    try InterruptionIO.checkpoint(.beforeFinal, fault)
    try RuntimeIntentIO.commitOperatorInterruption(lease, settled: true)
    let settled = try DiskGrowthIO.readFile(RuntimeIntent.filename, at: anchor, limit: 4096)
    try InterruptionIO.requireCurrent(lease, intent: settled, history: failedHistory)
    try InterruptionIO.checkpoint(.afterFinal, fault)
    return name
  }
}

private enum InterruptionIO {
  static let runNames = [
    "worker.json", "display.json", "surface.json", "agent.json", "capture.json",
    "result.json", "recovery.json",
  ]
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  static func digest<T: Encodable>(_ value: T) throws -> String {
    DiskGrowthIO.digest(try encode(value))
  }
  static func safeDirectory(_ value: stat) -> Bool {
    value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid()
      && value.st_mode & 0o022 == 0
  }
  static func entry(_ name: String, at anchor: Int32, limit: Int) throws -> InterruptionEntry {
    var before = stat()
    if fstatat(anchor, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw interruptionFailure(.storage) }
      return .init(name: name, bytes: nil, fact: nil)
    }
    let bytes = try DiskGrowthIO.readFile(name, at: anchor, limit: limit)
    var after = stat()
    guard fstatat(anchor, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
      DiskGrowthIO.stable(before, after)
    else { throw interruptionFailure(.staleOperation) }
    return .init(name: name, bytes: bytes, fact: InterruptionFact(after))
  }
  static func child(_ name: String, at anchor: Int32) throws -> Int32 {
    let fd = openat(anchor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw interruptionFailure(.storage) }
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0, safeDirectory(opened),
      fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      InterruptionFact(opened, directory: true) == InterruptionFact(named, directory: true)
    else {
      close(fd)
      throw interruptionFailure(.storage)
    }
    return fd
  }
  static func capture(
    at anchor: Int32, vmID: UUID, sessionID: UUID, runName: String
  ) throws -> RuntimeInterruptionSnapshot {
    guard runName.hasPrefix("run-"), runName.utf8.count == 36,
      runName.dropFirst(4).allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw interruptionFailure(.invalidConfiguration) }
    try RuntimeIntentIO.validateDirectory(anchor)
    let runtime = try child(".runtime", at: anchor)
    defer { close(runtime) }
    let run = try child(runName, at: runtime)
    defer { close(run) }
    try requireKnownRunJSON(run)
    let configuration = try DiskGrowthIO.configuration(at: anchor)
    let config = try DiskGrowthIO.decodeConfiguration(configuration)
    guard config.id == vmID else { throw interruptionFailure(.staleOperation) }
    let disk = try DiskGrowthIO.openDisk(config.diskFile, at: anchor, writable: false)
    defer { close(disk) }
    var parentInfo = stat()
    var writerInfo = stat()
    var diskInfo = stat()
    var runtimeInfo = stat()
    var runInfo = stat()
    guard fstat(anchor, &parentInfo) == 0, safeDirectory(parentInfo),
      fstatat(anchor, "writer.lock", &writerInfo, AT_SYMLINK_NOFOLLOW) == 0,
      DiskGrowthIO.safe(writerInfo), fstat(disk, &diskInfo) == 0,
      DiskGrowthIO.safe(diskInfo), UInt64(diskInfo.st_size) == config.diskBytes,
      fstat(runtime, &runtimeInfo) == 0, fstat(run, &runInfo) == 0
    else { throw interruptionFailure(.storage) }
    var entries = try [
      entry("configuration.json", at: anchor, limit: 65_536),
      entry(RuntimeIntent.filename, at: anchor, limit: 4096),
      entry("runtime.json", at: anchor, limit: 4096),
    ]
    guard entries[0].bytes == configuration, entries[1].bytes != nil, entries[2].bytes != nil else {
      throw interruptionFailure(.storage)
    }
    entries += try runNames.map { try entry($0, at: run, limit: 4096) }
    guard entries[3].bytes != nil, entries[4].bytes != nil, entries[5].bytes != nil else {
      throw interruptionFailure(.storage)
    }
    let value = RuntimeInterruptionSnapshot(
      vmID: vmID, interruptedSessionID: sessionID, runName: runName,
      kernel: try RuntimeInterruptionKernel.capture(),
      directory: InterruptionFact(parentInfo, directory: true),
      writer: InterruptionFact(writerInfo),
      disk: InterruptionFact(diskInfo),
      runtimeDirectory: InterruptionFact(runtimeInfo, directory: true),
      runDirectory: InterruptionFact(runInfo, directory: true), entries: entries)
    let check =
      try [
        entry("configuration.json", at: anchor, limit: 65_536),
        entry(RuntimeIntent.filename, at: anchor, limit: 4096),
        entry("runtime.json", at: anchor, limit: 4096),
      ] + runNames.map { try entry($0, at: run, limit: 4096) }
    var namedRuntime = stat()
    var namedRun = stat()
    guard check == entries,
      fstatat(anchor, ".runtime", &namedRuntime, AT_SYMLINK_NOFOLLOW) == 0,
      fstatat(runtime, runName, &namedRun, AT_SYMLINK_NOFOLLOW) == 0,
      safeDirectory(namedRuntime), safeDirectory(namedRun),
      InterruptionFact(namedRuntime, directory: true) == value.runtimeDirectory,
      InterruptionFact(namedRun, directory: true) == value.runDirectory
    else { throw interruptionFailure(.staleOperation) }
    try requireKnownRunJSON(run)
    return value
  }
  static func requireCurrent(
    _ lease: RuntimeInterruptionLease, intent: Data, history: Data
  ) throws {
    let current = try capture(
      at: lease.checkedAnchor(), vmID: lease.vmID,
      sessionID: lease.interruptedSessionID, runName: lease.snapshot.runName)
    let old = lease.snapshot
    guard current.vmID == old.vmID, current.interruptedSessionID == old.interruptedSessionID,
      current.kernel == old.kernel, current.directory == old.directory,
      current.writer == old.writer, current.disk == old.disk,
      current.runtimeDirectory == old.runtimeDirectory, current.runDirectory == old.runDirectory,
      current.entries.enumerated().allSatisfy({ index, entry in
        if index == 1 { return entry.bytes == intent }
        if index == 2 { return entry.bytes == history }
        return entry == old.entries[index]
      })
    else { throw interruptionFailure(.staleOperation) }
    _ = try lease.checkedAnchor()
  }
  private struct HistoricalBinding: Decodable {
    let scope: String
    let vmID: UUID
    let sessionID: UUID
  }
  static func validateHistoricalBindings(_ snapshot: RuntimeInterruptionSnapshot) throws {
    let scopes = [
      "macopenvm-registered-qemu-worker-route",
      "macopenvm-registered-qemu-display-route",
      "macopenvm-registered-qemu-shared-frame-route",
    ]
    for (index, scope) in scopes.enumerated() {
      guard let bytes = snapshot.entries[index + 3].bytes else {
        throw interruptionFailure(.corruptMetadata)
      }
      let binding = try JSONDecoder().decode(HistoricalBinding.self, from: bytes)
      guard binding.scope == scope, binding.vmID == snapshot.vmID,
        binding.sessionID == snapshot.interruptedSessionID
      else { throw interruptionFailure(.staleOperation) }
    }
  }
  static func requireKnownRunJSON(_ fd: Int32) throws {
    let copy = fcntl(fd, F_DUPFD_CLOEXEC, 3)
    guard copy >= 0 else { throw interruptionFailure(.storage) }
    guard let stream = fdopendir(copy) else {
      close(copy)
      throw interruptionFailure(.storage)
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var count = 0
    while true {
      errno = 0
      guard let row = readdir(stream) else {
        guard errno == 0 else { throw interruptionFailure(.storage) }
        return
      }
      count += 1
      guard count <= 64 else { throw interruptionFailure(.invalidConfiguration) }
      let capacity = Int(row.pointee.d_namlen) + 1
      let name = withUnsafePointer(to: &row.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
      }
      if name.lowercased().hasSuffix(".json"), !runNames.contains(name) {
        throw interruptionFailure(.invalidConfiguration)
      }
    }
  }
  static func checkpoint(_ point: RuntimeInterruptionFault, _ fault: RuntimeInterruptionFault?)
    throws
  {
    if point == fault { throw interruptionFailure(.storage) }
  }
}

private func interruptionFailure(_ code: VMError.Code) -> VMError {
  VMError(
    code, "Explicit interrupted-session recovery could not be confirmed.",
    recovery:
      "Retain recovery custody and preserve the exact old/archive/current bytes. Never retry or infer normal shutdown automatically."
  )
}
