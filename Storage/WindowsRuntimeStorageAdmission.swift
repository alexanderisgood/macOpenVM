// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// Startup headroom for an existing sparse Windows disk, not its full capacity
/// or a reservation. Four GiB avoids starting with critically little writable
/// space; Windows and other host activity can still exhaust the volume later.
package enum WindowsRuntimeStorageAdmission {
  package typealias CapacityProvider = @Sendable (URL) async throws -> UInt64
  package static let minimumAvailableBytes: UInt64 = 4 * 1_073_741_824

  package static func requireCapacity(
    in directory: URL, capacity: CapacityProvider = readCapacity
  ) async throws {
    let available: UInt64
    do {
      available = try await capacity(directory)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw VMError(
        .storage, "Available space on this VM’s volume could not be checked.",
        recovery: "Check that the VM location is available and try again. Windows was not started.")
    }
    guard available >= minimumAvailableBytes else {
      throw VMError(
        .storage, "Windows needs more free space before it can start.",
        recovery:
          "Make at least 4 GiB available on the volume containing this VM, then try again. Sparse VM disks keep using host space as Windows writes data; this check does not reserve space."
      )
    }
  }

  package static func readCapacity(at directory: URL) async throws -> UInt64 {
    try Task.checkCancellation()
    return try await VMFiles().availableStorageCapacity(at: directory)
  }
}
