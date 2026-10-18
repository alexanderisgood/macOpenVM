// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

struct WindowsExternalInputRequest: Sendable {
  enum Operation: Sendable {
    case snapshot
    case click(UInt16, UInt16)
    case key(UInt32)
  }
  let operation: Operation
  let expectedFrame: String?
  init(action: String, expectedFrame: String?, x: Int?, y: Int?, key: String?) throws {
    let navigation: [String: UInt32] = [
      "tab": 0xff09, "return": 0xff0d, "space": 0x20, "escape": 0xff1b,
      "up": 0xff52, "down": 0xff54, "home": 0xff50, "end": 0xff57, "pageup": 0xff55,
      "pagedown": 0xff56,
    ]
    self.expectedFrame = expectedFrame
    if action == "snapshot", expectedFrame == nil, x == nil, y == nil, key == nil {
      operation = .snapshot
      return
    }
    guard expectedFrame.map(WindowsExternalAdmission.validHash) == true else {
      throw windowsExternalFailure()
    }
    if action == "click", key == nil, let x, let y, (0...8191).contains(x), (0...8191).contains(y),
      let px = UInt16(exactly: x), let py = UInt16(exactly: y)
    {
      operation = .click(px, py)
      return
    }
    if action == "key", x == nil, y == nil, let key, let symbol = navigation[key] {
      operation = .key(symbol)
      return
    }
    throw windowsExternalFailure()
  }
  func admitsFrame(hash: String, size: PixelSize) -> Bool {
    guard (1...8192).contains(size.width), (1...8192).contains(size.height),
      size.width * size.height <= 16_777_216
    else { return false }
    switch operation {
    case .snapshot: return WindowsExternalAdmission.validHash(hash)
    case .key: return hash == expectedFrame
    case .click(let x, let y):
      return hash == expectedFrame && Int(x) < size.width && Int(y) < size.height
    }
  }
}
