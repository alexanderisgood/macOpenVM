// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// Package tags retain trusted producers without introducing Storage/Core dependencies.
package protocol RuntimeHistoryReceiptSource: AnyObject, Sendable {}
package protocol RuntimeSettlementReceiptSource: AnyObject, Sendable {}

/// Core mints this only after sealing actual ordered history and verifying final readback.
/// Source identity comes from the strongly retained object, not a caller-supplied UUID.
package final class RuntimeHistoryCommitReceipt: Sendable {
  package let sourceID: ObjectIdentifier
  package let permit: RuntimeSessionPermit
  package let sequence: UInt64
  package let finalBytes: Data
  private let source: any RuntimeHistoryReceiptSource

  package init(
    source: any RuntimeHistoryReceiptSource, permit: RuntimeSessionPermit,
    sequence: UInt64, finalBytes: Data
  ) throws {
    guard sequence > 0, !finalBytes.isEmpty, finalBytes.count <= RuntimeIntent.maximumBytes else {
      throw settlementError(.invalidConfiguration)
    }
    self.source = source
    sourceID = ObjectIdentifier(source)
    self.permit = permit
    self.sequence = sequence
    self.finalBytes = finalBytes
  }

  package func isFrom(_ expected: any RuntimeHistoryReceiptSource) -> Bool { source === expected }
}

/// Only the trusted Core owner combines actual backend/history receipts. This is not a public
/// checklist or launch capability and cannot be reconstructed from disk record fields.
package final class RuntimeSettlementReceipt: Sendable {
  package let sourceID: ObjectIdentifier
  package let permit: RuntimeSessionPermit
  package let backend: BackendQuiescenceReceipt
  package let history: RuntimeHistoryCommitReceipt
  private let source: any RuntimeSettlementReceiptSource

  package init(
    source: any RuntimeSettlementReceiptSource, permit: RuntimeSessionPermit,
    backend: BackendQuiescenceReceipt, history: RuntimeHistoryCommitReceipt
  ) throws {
    guard history.permit === permit, backend.sessionID == permit.sessionID else {
      throw settlementError(.invalidConfiguration)
    }
    self.source = source
    sourceID = ObjectIdentifier(source)
    self.permit = permit
    self.backend = backend
    self.history = history
  }

  package func isFrom(_ expected: any RuntimeSettlementReceiptSource) -> Bool {
    source === expected
  }
}

extension VMFiles {
  /// Actual same-anchor history bytes are flushed before settled intent is written. A failed
  /// attempt consumes the permit claim and may be ambiguous after rename; never retry/rollback.
  package func commitRuntimeSettlement(in directory: URL, receipt: RuntimeSettlementReceipt) throws
  {
    try Task.checkCancellation()
    let permit = receipt.permit
    try permit.reserveSettlement()
    try permit.withSettlementDirectory(in: directory) { anchor in
      try RuntimeSettlementIO.requireUnsettled(permit, at: anchor)
      try RuntimeSettlementIO.withDurableHistory(receipt.history.finalBytes, at: anchor) {
        try RuntimeSettlementIO.requireUnsettled(permit, at: anchor)
        try RuntimeIntentIO.commitSettlement(for: permit, at: anchor)
      }
    }
  }
}

private enum RuntimeSettlementIO {
  static func requireUnsettled(_ permit: RuntimeSessionPermit, at anchor: Int32) throws {
    guard let record = try RuntimeIntentIO.read(at: anchor), record.state == .unsettled,
      record.vmID == permit.vmID, record.sessionID == permit.sessionID
    else { throw settlementError(.busy) }
  }

  static func withDurableHistory(
    _ expected: Data, at anchor: Int32, _ body: () throws -> Void
  ) throws {
    let fd = openat(anchor, "runtime.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw settlementError(.storage) }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, safe(before), before.st_size == expected.count,
      !expected.isEmpty, expected.count <= RuntimeIntent.maximumBytes
    else { throw settlementError(.storage) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var actual = Data()
    do {
      while let bytes = try handle.read(upToCount: RuntimeIntent.maximumBytes - actual.count + 1),
        !bytes.isEmpty
      {
        actual.append(bytes)
        guard actual.count <= RuntimeIntent.maximumBytes else { throw settlementError(.storage) }
      }
    } catch {
      throw settlementError(.storage)
    }
    guard actual == expected else { throw settlementError(.corruptMetadata) }
    try verifyIdentity(fd, at: anchor, expected: before)
    guard fsync(fd) == 0 else { throw settlementError(.storage) }
    try verifyIdentity(fd, at: anchor, expected: before)
    try body()
    try verifyIdentity(fd, at: anchor, expected: before)
  }

  private static func verifyIdentity(_ fd: Int32, at anchor: Int32, expected: stat) throws {
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0,
      fstatat(anchor, "runtime.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
      stable(expected, opened), stable(opened, named)
    else { throw settlementError(.storage) }
  }

  private static func safe(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
      && info.st_mode & 0o7777 == 0o600
  }

  private static func stable(_ before: stat, _ after: stat) -> Bool {
    safe(after) && before.st_dev == after.st_dev && before.st_ino == after.st_ino
      && before.st_size == after.st_size
      && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
      && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
      && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
      && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
  }
}

private func settlementError(_ code: VMError.Code) -> VMError {
  VMError(
    code, "Runtime settlement could not be confirmed.",
    recovery:
      "Retain ownership and preserve intent/history. Bytes may have changed; never retry, unlock or remove an uncertain record automatically."
  )
}
