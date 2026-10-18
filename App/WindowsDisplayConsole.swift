// SPDX-License-Identifier: Apache-2.0
import Foundation

/// QEMU consumes these documented console chords on the existing display route.
/// They do not create a new connection, device, VM owner, or guest command.
enum WindowsDisplayConsole: String, CaseIterable, Identifiable, Sendable {
  case firmware, gpu
  var id: Self { self }
  var title: String {
    switch self {
    case .firmware: "Firmware Display"
    case .gpu: "Windows GPU Display"
    }
  }
  var chord: [UInt32] {
    [0xffe3, 0xffe9, self == .firmware ? 0x31 : 0x32]
  }
}
