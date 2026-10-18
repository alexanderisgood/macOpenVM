// SPDX-License-Identifier: Apache-2.0
import Qemu
import Testing

@Suite("RFB keyboard translation and host state")
struct RfbKeyboardTests {
  @Test func consumedMenuKeyUpCannotLeaveShortcutKeyHeld() throws {
    var keyboard = RFBKeyboardState()
    let expected = [
      RFBKeyStroke(0xffeb, down: true), RFBKeyStroke(0x69, down: true),
      RFBKeyStroke(0x69, down: false), RFBKeyStroke(0xffeb, down: false),
    ]
    for _ in 0..<4 {
      #expect(try keyboard.shortcut(keyCode: 34, symbol: 0x69, modifiers: .command) == expected)
      #expect(keyboard.release(keyCode: 34).isEmpty)
    }
    #expect(try keyboard.press(keyCode: 34, symbol: 0x69) == [RFBKeyStroke(0x69, down: true)])
    #expect(keyboard.release(keyCode: 34) == [RFBKeyStroke(0x69, down: false)])
  }
  @Test func shortcutRestoresExistingPhysicalModifiersWithoutReleasingOtherKeys() throws {
    var keyboard = RFBKeyboardState()
    _ = keyboard.changeModifiers(.shift)
    _ = try keyboard.press(keyCode: 0, symbol: 0x61)
    #expect(
      try keyboard.shortcut(keyCode: 34, symbol: 0x69, modifiers: [.shift, .command]) == [
        RFBKeyStroke(0xffeb, down: true), RFBKeyStroke(0x69, down: true),
        RFBKeyStroke(0x69, down: false), RFBKeyStroke(0xffeb, down: false),
      ])
    #expect(keyboard.release(keyCode: 0) == [RFBKeyStroke(0x61, down: false)])
    #expect(keyboard.changeModifiers([]) == [RFBKeyStroke(0xffe1, down: false)])
  }
  @Test func printableLayoutCharactersAndUnicode() {
    for (text, expected): (String, UInt32) in [
      ("a", 0x61), ("A", 0x41), ("1", 0x31), ("!", 0x21),
      ("#", 0x23), ("£", 0xa3), ("@", 0x40), ("é", 0xe9),
      ("€", 0x0100_20ac), ("界", 0x0100_754c), ("😀", 0x0101_f600),
    ] {
      #expect(RFBKeySymbol.appKitCharacters(text) == expected)
      #expect(RFBKeySymbol.isSupported(expected))
    }
  }

  @Test func installerNavigationAndFunctionCharacters() {
    for (text, expected): (String, UInt32) in [
      ("\t", 0xff09), ("\u{19}", 0xff09), ("\r", 0xff0d), ("\u{3}", 0xff0d),
      ("\u{7f}", 0xff08), ("\u{1b}", 0xff1b), ("\u{f700}", 0xff52),
      ("\u{f703}", 0xff53), ("\u{f728}", 0xffff), ("\u{f729}", 0xff50),
      ("\u{f72b}", 0xff57), ("\u{f72c}", 0xff55), ("\u{f72d}", 0xff56),
      ("\u{f704}", 0xffbe), ("\u{f70f}", 0xffc9), ("\u{f71b}", 0xffd5),
    ] {
      #expect(RFBKeySymbol.appKitCharacters(text) == expected)
      #expect(RFBKeySymbol.isSupported(expected))
    }
  }

  @Test func rejectsControlCompositionAndUnmappedFunctionCharacters() {
    for text: String? in [nil, "", "ab", "e\u{301}", "\u{0}", "\u{1}", "\u{f735}"] {
      #expect(RFBKeySymbol.appKitCharacters(text) == nil)
    }
    for value: UInt32 in [
      0, 1, 0x7f, 0x9f, 0x100, 0xffe5, 0x0100_0000,
      0x0100_d800, 0x0100_dfff, 0x0111_0000, .max,
    ] { #expect(!RFBKeySymbol.isSupported(value)) }
  }

  @Test func releasesOriginalSymbolAfterShiftOrLayoutChanges() throws {
    var keyboard = RFBKeyboardState()
    #expect(try keyboard.press(keyCode: 0, symbol: 0x41) == [RFBKeyStroke(0x41, down: true)])
    #expect(try keyboard.press(keyCode: 0, symbol: 0x61).isEmpty)
    #expect(keyboard.release(keyCode: 0) == [RFBKeyStroke(0x41, down: false)])
    #expect(keyboard.release(keyCode: 0).isEmpty)
    #expect(try keyboard.press(keyCode: 0, symbol: 0x61) == [RFBKeyStroke(0x61, down: true)])
  }

  @Test func aliasesAndRepeatedDigitsKeepOneBalancedPress() throws {
    var keyboard = RFBKeyboardState()
    #expect(try keyboard.press(keyCode: 18, symbol: 49) == [RFBKeyStroke(49, down: true)])
    #expect(try keyboard.press(keyCode: 83, symbol: 49).isEmpty)
    #expect(keyboard.release(keyCode: 18).isEmpty)
    #expect(keyboard.release(keyCode: 83) == [RFBKeyStroke(49, down: false)])
    for _ in 0..<8 {
      #expect(try keyboard.press(keyCode: 18, symbol: 49) == [RFBKeyStroke(49, down: true)])
      #expect(keyboard.release(keyCode: 18) == [RFBKeyStroke(49, down: false)])
    }
  }

  @Test func aggregateModifiersHaveOrderedBalancedTransitions() {
    var keyboard = RFBKeyboardState()
    #expect(
      keyboard.changeModifiers([.control, .alt]) == [
        RFBKeyStroke(0xffe3, down: true), RFBKeyStroke(0xffe9, down: true),
      ])
    #expect(keyboard.changeModifiers([.control, .alt]).isEmpty)
    #expect(
      keyboard.changeModifiers([.shift, .command]) == [
        RFBKeyStroke(0xffe3, down: false), RFBKeyStroke(0xffe9, down: false),
        RFBKeyStroke(0xffe1, down: true), RFBKeyStroke(0xffeb, down: true),
      ])
    #expect(
      keyboard.changeModifiers([]) == [
        RFBKeyStroke(0xffe1, down: false), RFBKeyStroke(0xffeb, down: false),
      ])
  }

  @Test func boundedStateAndFocusReset() throws {
    var keyboard = RFBKeyboardState()
    for key: UInt16 in 0..<32 { _ = try keyboard.press(keyCode: key, symbol: UInt32(0x20 + key)) }
    #expect(throws: RFBClientError.limitExceeded) { try keyboard.press(keyCode: 32, symbol: 0x61) }
    _ = keyboard.changeModifiers(.command)
    keyboard.reset()
    #expect(keyboard.release(keyCode: 0).isEmpty)
    #expect(keyboard.changeModifiers([]).isEmpty)
    #expect(try keyboard.press(keyCode: 0, symbol: 0x61) == [RFBKeyStroke(0x61, down: true)])
    #expect(throws: RFBClientError.unsupportedKey) { try keyboard.press(keyCode: 1, symbol: 0) }
  }
}
