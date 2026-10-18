// SPDX-License-Identifier: Apache-2.0
import Foundation
import Qemu

/// Fixed evaluator strings only; no user text or credential entry point.
/// These symbols share their physical positions on English US and UK layouts.
enum FixedGuestASCII {
  static func strokes(_ text: String) throws -> [RFBKeyStroke] {
    let symbols = text.unicodeScalars.map(\.value)
    guard !symbols.isEmpty, symbols.count <= 12_000,
      symbols.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || [32, 43, 44, 45, 46, 47, 58, 59, 61].contains($0)
      })
    else { throw RFBClientError.unsupportedKey }
    var shifted = false
    var result: [RFBKeyStroke] = []
    for symbol in symbols {
      let needed = (65...90).contains(symbol) || symbol == 43 || symbol == 58
      if shifted != needed {
        result.append(RFBKeyStroke(0xffe1, down: needed))
        shifted = needed
      }
      result += [RFBKeyStroke(symbol, down: true), RFBKeyStroke(symbol, down: false)]
    }
    if shifted { result.append(RFBKeyStroke(0xffe1, down: false)) }
    return result
  }
}
