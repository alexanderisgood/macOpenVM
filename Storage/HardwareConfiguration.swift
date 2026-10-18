// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

enum HardwareConfigurationFault: Sendable { case afterBackup, afterRename, afterCommit }

extension VMFiles {
  package func commitHardwareConfiguration(
    in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64,
    host: HostResources, backupID: UUID, lock: VMLock
  ) throws -> String? {
    try commitHardwareConfiguration(
      in: directory, expected: expected, cpuCount: cpuCount, memoryBytes: memoryBytes,
      host: host, backupID: backupID, lock: lock, fault: nil)
  }

  /// Keep the entire admission, exact-token replacement and durable backup on the I/O actor.
  func commitHardwareConfiguration(
    in directory: URL, expected: VMConfiguration, cpuCount: Int, memoryBytes: UInt64,
    host: HostResources, backupID: UUID, lock: VMLock, fault: HardwareConfigurationFault?
  ) throws -> String? {
    guard lock.owns(directory) else { throw diskGrowthError(.busy) }
    try lock.reserveConfigurationChange(forVMID: expected.id)
    try Task.checkCancellation()
    return try lock.withRuntimeIntentDirectory { anchor in
      try RuntimeIntentIO.requireAdmission(at: anchor, expectedVMID: expected.id)
      try DiskGrowthIO.requireAdmission(at: anchor, expectedVMID: expected.id)
      let original = try DiskGrowthIO.configuration(at: anchor)
      guard try DiskGrowthIO.decodeConfiguration(original) == expected else {
        throw diskGrowthError(.staleOperation)
      }
      let replacement = try DiskGrowthIO.replacingHardware(
        original, cpuCount: cpuCount, memoryBytes: memoryBytes, host: host)
      if expected.cpuCount == cpuCount && expected.memoryBytes == memoryBytes { return nil }
      let disk = try DiskGrowthIO.openDisk(expected.diskFile, at: anchor, writable: false)
      defer { close(disk) }
      guard
        try DiskGrowthIO.diskInfo(disk, name: expected.diskFile, at: anchor).st_size
          == expected.diskBytes
      else { throw diskGrowthError(.corruptMetadata) }
      try DiskGrowthIO.requireFreeSpace(at: anchor)
      let backup = "configuration-hardware-backup-\(backupID.uuidString).json"
      try DiskGrowthIO.exclusive(original, name: backup, at: anchor)
      guard fsync(anchor) == 0,
        try DiskGrowthIO.readFile(backup, at: anchor, limit: DiskGrowthIO.configurationLimit)
          == original, fault != .afterBackup
      else { throw diskGrowthError(.storage) }
      try Task.checkCancellation()
      guard try DiskGrowthIO.configuration(at: anchor) == original else {
        throw diskGrowthError(.staleOperation)
      }
      try DiskGrowthIO.atomic(
        replacement, name: DiskGrowthIO.configurationFile, at: anchor,
        afterRename: { if fault == .afterRename { throw diskGrowthError(.storage) } })
      guard try DiskGrowthIO.configuration(at: anchor) == replacement,
        try DiskGrowthIO.readFile(backup, at: anchor, limit: DiskGrowthIO.configurationLimit)
          == original, fault != .afterCommit
      else { throw diskGrowthError(.storage) }
      return backup
    }
  }
}
