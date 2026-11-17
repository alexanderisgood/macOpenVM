// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct GuestMenuBarVisibilityTests {
  @Test func revealsTheMenuOnlyForTheActiveFullscreenOwner() {
    var visible = false
    var writes: [Bool] = []
    let policy = GuestMenuBarVisibility(
      visible: { visible },
      setVisible: {
        visible = $0
        writes.append($0)
      })
    policy.show(activeOwner: false)
    #expect(writes.isEmpty)
    policy.show(activeOwner: true)
    policy.show(activeOwner: true)
    #expect(writes == [true] && visible)
    // AppKit can hide the menu as the app loses focus, including when it
    // switches Spaces. The VM must leave that state to AppKit until it is key.
    visible = false
    policy.show(activeOwner: false)
    #expect(writes == [true] && !visible)
    policy.show(activeOwner: true)
    #expect(writes == [true, true] && visible)
  }
  @Test func leavingFullscreenCannotRestoreATransientHiddenMenu() {
    var visible = false
    var writes: [Bool] = []
    let policy = GuestMenuBarVisibility(
      visible: { visible },
      setVisible: {
        visible = $0
        writes.append($0)
      })
    policy.show(activeOwner: true)
    policy.show(activeOwner: false)
    #expect(visible && writes == [true])
  }
}
