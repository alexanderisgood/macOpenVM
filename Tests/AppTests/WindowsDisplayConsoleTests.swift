// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import MacOpenVMApp

struct WindowsDisplayConsoleTests {
  @Test func selectionUsesOnlyTheTwoExistingQemuConsoles() {
    #expect(WindowsDisplayConsole.allCases.count == 2)
    #expect(WindowsDisplayConsole.firmware.chord == [0xffe3, 0xffe9, 0x31])
    #expect(WindowsDisplayConsole.gpu.chord == [0xffe3, 0xffe9, 0x32])
  }
}
