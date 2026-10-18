// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Foundation
import Qemu

/// Explicit visual target guard. Unrelated clocks/animations cannot invalidate
/// a click, but geometry or any pixel in the selected target does.
struct RegisteredInputRegion: Sendable {
  let x: Int, y: Int, width: Int, height: Int
  init(x: Int, y: Int, width: Int, height: Int) throws {
    guard (0...8191).contains(x), (0...8191).contains(y),
      (64...2048).contains(width), (64...2048).contains(height),
      x + width <= 8192, y + height <= 8192
    else { throw Self.failure() }
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  func digest(_ frame: RFBFrame, epoch: UUID) throws -> String {
    guard frame.connectionEpoch == epoch, frame.sequence > 0,
      (1...8192).contains(frame.size.width), (1...8192).contains(frame.size.height),
      frame.size.width * frame.size.height <= 16_777_216,
      frame.rgbaData.count == frame.size.width * frame.size.height * 4,
      x + width <= frame.size.width, y + height <= frame.size.height
    else { throw Self.failure() }
    var hash = SHA256()
    hash.update(
      data: Data(
        "mvo-target-v1:\(frame.size.width):\(frame.size.height):\(x):\(y):\(width):\(height)\n".utf8
      ))
    for row in y..<(y + height) {
      let offset = (row * frame.size.width + x) * 4
      hash.update(data: frame.rgbaData.subdata(in: offset..<(offset + width * 4)))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  func contains(clickX: Int, clickY: Int) -> Bool {
    (x..<(x + width)).contains(clickX) && (y..<(y + height)).contains(clickY)
  }
  private static func failure() -> VMError {
    VMError(
      .staleOperation, "The visual input target is invalid or changed.",
      recovery: "Observe the target again. No input is replayed automatically.")
  }
}
