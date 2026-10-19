// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import VMStorage

@Suite struct WindowsRuntimeStorageAdmissionTests: Sendable {
  private let directory = URL(fileURLWithPath: "/private/tmp/unused-windows-capacity")

  @Test(arguments: [UInt64(0), WindowsRuntimeStorageAdmission.minimumAvailableBytes - 1])
  func lowCapacityHasActionableError(bytes: UInt64) async throws {
    do {
      try await WindowsRuntimeStorageAdmission.requireCapacity(in: directory) { selected in
        #expect(selected == directory)
        return bytes
      }
      Issue.record("Low startup capacity was admitted.")
    } catch let error as VMError {
      #expect(error.code == .storage)
      #expect(error.message == "Windows needs more free space before it can start.")
      #expect(error.recovery.contains("4 GiB"))
      #expect(error.recovery.contains("volume containing this VM"))
      #expect(error.recovery.contains("does not reserve space"))
      #expect(error.recovery.contains("Windows writes data"))
    }
  }

  @Test(arguments: [
    WindowsRuntimeStorageAdmission.minimumAvailableBytes,
    WindowsRuntimeStorageAdmission.minimumAvailableBytes + 1, UInt64.max,
  ])
  func reserveBoundaryDoesNotRequireBackingWholeVirtualDisk(bytes: UInt64) async throws {
    #expect(WindowsRuntimeStorageAdmission.minimumAvailableBytes == 4 << 30)
    try await WindowsRuntimeStorageAdmission.requireCapacity(in: directory) { _ in bytes }
  }

  @Test func unknownCapacityFailsClosedWithReadableError() async throws {
    do {
      try await WindowsRuntimeStorageAdmission.requireCapacity(in: directory) { _ in
        throw CocoaError(.fileReadUnknown)
      }
      Issue.record("Unknown startup capacity was admitted.")
    } catch let error as VMError {
      #expect(error.code == .storage)
      #expect(error.message == "Available space on this VM’s volume could not be checked.")
      #expect(error.recovery.contains("Windows was not started"))
      #expect(!error.localizedDescription.contains(directory.path))
    }
  }

  @Test func cancellationRemainsCancellation() async throws {
    await #expect(throws: CancellationError.self) {
      try await WindowsRuntimeStorageAdmission.requireCapacity(in: directory) { _ in
        throw CancellationError()
      }
    }
  }
}
