// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Filesystem identity from the retained descriptor, never a pathname or mount number.
/// Unsupported, missing, truncated and default-valued UUID replies fail closed.
enum DiskGrowthVolumeIdentity {
  static let responseBytes = 40

  static func read(from descriptor: Int32) throws -> UUID {
    var before = stat()
    guard fstat(descriptor, &before) == 0 else { throw diskGrowthError(.storage) }
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    attributes.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
    var bytes = [UInt8](repeating: 0, count: responseBytes)
    let result = bytes.withUnsafeMutableBytes { buffer in
      fgetattrlist(
        descriptor, &attributes, buffer.baseAddress, buffer.count, UInt32(FSOPT_REPORT_FULLSIZE))
    }
    var after = stat()
    guard result == 0, fstat(descriptor, &after) == 0,
      sameNode(before, after)
    else { throw diskGrowthError(.storage) }
    return try decodeResponse(bytes)
  }

  /// Internal parser seam for hostile/unsupported kernel-response regressions.
  static func decodeResponse(_ bytes: [UInt8]) throws -> UUID {
    guard bytes.count == responseBytes else { throw diskGrowthError(.storage) }
    let words = bytes.withUnsafeBytes { buffer in
      stride(from: 0, to: 24, by: 4).map {
        buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self)
      }
    }
    guard words[0] == UInt32(responseBytes),
      words[1] == UInt32(ATTR_CMN_RETURNED_ATTRS), words[2] == UInt32(ATTR_VOL_UUID),
      words[3] == 0, words[4] == 0, words[5] == 0,
      bytes[24..<40].contains(where: { $0 != 0 })
    else { throw diskGrowthError(.storage) }
    return UUID(
      uuid: (
        bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30], bytes[31],
        bytes[32], bytes[33], bytes[34], bytes[35], bytes[36], bytes[37], bytes[38], bytes[39]
      ))
  }

  private static func sameNode(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev && first.st_ino == second.st_ino
      && first.st_mode == second.st_mode && first.st_uid == second.st_uid
      && first.st_nlink == second.st_nlink
  }
}

/// Persistent v2 identity tolerates a new mount number. An opened operation still
/// pins its current mount numbers and inodes for its entire retained-descriptor lifetime.
struct DiskGrowthOpenedIdentity: Sendable {
  let directoryDevice: Int32
  let directoryInode: UInt64
  let diskDevice: Int32
  let diskInode: UInt64

  init(directory: Int32, disk: Int32) throws {
    var parent = stat()
    var file = stat()
    guard fstat(directory, &parent) == 0, fstat(disk, &file) == 0 else {
      throw diskGrowthError(.storage)
    }
    directoryDevice = parent.st_dev
    directoryInode = parent.st_ino
    diskDevice = file.st_dev
    diskInode = file.st_ino
  }

  func requireMatches(directory: Int32, disk: Int32) throws {
    var parent = stat()
    var file = stat()
    guard fstat(directory, &parent) == 0, fstat(disk, &file) == 0,
      matches(directory: parent, disk: file)
    else { throw diskGrowthError(.storage) }
  }

  /// Pure comparison seam; production inputs always come from the retained FDs above.
  func matches(directory parent: stat, disk file: stat) -> Bool {
    parent.st_dev == directoryDevice && parent.st_ino == directoryInode
      && file.st_dev == diskDevice && file.st_ino == diskInode
  }
}
