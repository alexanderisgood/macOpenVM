// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import VMCore

@MainActor protocol DesktopDiskGrowing {
  func grow(in directory: URL, expected: VMConfiguration, targetBytes: UInt64) async throws
    -> VMConfiguration
}

struct NativeDesktopDiskGrowth: DesktopDiskGrowing {
  func grow(in directory: URL, expected: VMConfiguration, targetBytes: UInt64) async throws
    -> VMConfiguration
  {
    try await DiskGrowth().grow(in: directory, toBytes: targetBytes, expected: expected)
      .configuration
  }
}
