// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMStorage

/// Recoverable deletion has no serialization or runtime authority.
public struct VMTrashResult: Sendable {
  public enum Status: Sendable { case moved, relocationUnverified, notMoved }
  public let status: Status
  public let trashURL: URL?
  public let cancellationObserved: Bool
  public init(status: Status, trashURL: URL?, cancellationObserved: Bool = false) {
    self.status = status
    self.trashURL = trashURL
    self.cancellationObserved = cancellationObserved
  }
}

/// Retains the actual exclusive writer until cancelled or committed. Dropping a
/// ticket closes only its own descriptors; it never stops or repairs a runtime.
public final class VMTrashTicket: Sendable {
  public let vmID: UUID
  public let name: String
  private let storage: StoppedVMTrashTicket
  package init(configuration: VMConfiguration, storage: StoppedVMTrashTicket) {
    vmID = configuration.id
    name = configuration.name
    self.storage = storage
  }
  public func cancel() async { await storage.cancel() }
  public func commit() async throws -> VMTrashResult {
    let result = try await storage.commit()
    let status: VMTrashResult.Status
    switch result.status {
    case .moved: status = .moved
    case .relocationUnverified: status = .relocationUnverified
    case .notMoved: status = .notMoved
    }
    return VMTrashResult(
      status: status, trashURL: result.trashURL,
      cancellationObserved: result.cancellationObserved)
  }
}

/// Only a stopped, identity-matching registration can reach the native Trash API.
public struct VMTrash: Sendable {
  private let files: VMFiles
  public init() { files = VMFiles() }
  package init(files: VMFiles) { self.files = files }
  public func prepare(in directory: URL, expected: VMConfiguration) async throws -> VMTrashTicket {
    let storage = try await files.prepareStoppedVMTrash(
      in: directory, vmID: expected.id,
      validate: { registration, history, intent in
        try Self.validateRegistration(registration, expected: expected)
        try Self.validateStopped(history: history, intent: intent, vmID: expected.id)
      })
    return VMTrashTicket(configuration: expected, storage: storage)
  }

  package static func validateRegistration(_ bytes: Data, expected: VMConfiguration) throws {
    let configuration = try StrictConfigurationDocument(bytes).configuration
    guard configuration == expected else {
      throw failure(.staleOperation, "The selected VM changed before confirmation.")
    }
    guard !configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      configuration.name.utf8.count <= 128,
      !configuration.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw failure(.corruptMetadata, "The VM name is unsuitable for confirmation.") }
  }

  package static func validateStopped(history: Data?, intent: RuntimeIntent?, vmID: UUID) throws {
    guard let history else {
      guard intent == nil else {
        throw failure(.busy, "Runtime ownership exists without matching terminal history.")
      }
      return
    }
    let record = try RuntimeHistoryCodec.decode(history)
    guard try RuntimeHistoryCodec.encode(record) == history,
      !record.snapshot.backendActive, record.snapshot.operation == nil,
      record.snapshot.outcome != .pending, let intent,
      intent.state == .settled, intent.vmID == vmID, intent.sessionID == record.sessionID
    else {
      throw failure(.busy, "This VM has no matching settled, inactive runtime record.")
    }
    // Forced stop and terminal failure are admissible. Moving a bundle does not
    // establish guest filesystem cleanliness or repair any prior failure.
  }

  private static func failure(_ code: VMError.Code, _ message: String) -> VMError {
    VMError(
      code, message, recovery: "Preserve the VM and review its stopped state before retrying.")
  }
}
