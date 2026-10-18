// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import MacOpenVMApp

@MainActor @Suite struct GuestMenuBarVisibilityTests {
  @Test func restoresVisibilityWithoutChangingAnUnrelatedApplication() {
    var visible = false
    var writes: [Bool] = []
    var policy = GuestMenuBarVisibility(
      visible: { visible },
      setVisible: {
        visible = $0
        writes.append($0)
      })
    policy.show(activeOwner: true)
    #expect(writes.isEmpty)
    policy.prepare()
    policy.show(activeOwner: false)
    #expect(writes.isEmpty)
    policy.show(activeOwner: true)
    policy.show(activeOwner: true)
    #expect(writes == [true] && visible)
    policy.suspend(canChangeVisibility: false)
    #expect(writes == [true])
    // The other app/system establishes its own state during focus loss.
    visible = false
    policy.show(activeOwner: true)
    policy.finish(canChangeVisibility: true)
    #expect(writes == [true, true, false] && !visible)
    policy.show(activeOwner: true)
    #expect(writes == [true, true, false])
  }
  @Test func repeatedEntryKeepsTheWindowedBaseline() {
    var visible = true
    var writes: [Bool] = []
    var policy = GuestMenuBarVisibility(
      visible: { visible },
      setVisible: {
        visible = $0
        writes.append($0)
      })
    policy.prepare()
    visible = false  // AppKit's fullscreen defaults hid the menu.
    policy.prepare()
    policy.show(activeOwner: true)
    policy.finish(canChangeVisibility: true)
    #expect(visible && writes == [true])
    policy.prepare()
    visible = false
    policy.show(activeOwner: true)
    policy.finish(canChangeVisibility: false)
    #expect(visible && writes == [true, true])
  }
}
