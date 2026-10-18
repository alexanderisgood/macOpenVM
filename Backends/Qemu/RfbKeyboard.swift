// SPDX-License-Identifier: Apache-2.0
import Foundation

/// RFC 6143 section 7.5.4 keysyms. This is a bounded keyboard vocabulary,
/// not a claim that a guest keyboard layout or input method accepts every symbol.
public enum RFBKeySymbol {
  public static func isSupported(_ value: UInt32) -> Bool {
    if (0x20...0x7e).contains(value) || (0xa0...0xff).contains(value) { return true }
    if (0xffbe...0xffd5).contains(value) { return true }  // F1...F24
    if (0xffe1...0xffe4).contains(value) || (0xffe9...0xffec).contains(value) { return true }
    if [
      0xff08, 0xff09, 0xff0d, 0xff1b, 0xff50, 0xff51, 0xff52,
      0xff53, 0xff54, 0xff55, 0xff56, 0xff57, 0xff63, 0xffff,
    ].contains(value) {
      return true
    }
    guard (0x0100_0100...0x0110_ffff).contains(value) else { return false }
    return Unicode.Scalar(value & 0x00ff_ffff) != nil
  }

  /// AppKit's public function-character values are mapped explicitly. Ordinary
  /// text must be exactly one scalar; marked text/dead-key composition needs a
  /// separate input-method contract and must never be partially transmitted.
  public static func appKitCharacters(_ text: String?) -> UInt32? {
    guard let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else {
      return nil
    }
    let value = scalar.value
    switch value {
    case 0x08, 0x7f: return 0xff08
    case 0x09, 0x19: return 0xff09
    case 0x03, 0x0a, 0x0d: return 0xff0d
    case 0x1b: return 0xff1b
    case 0xf700: return 0xff52
    case 0xf701: return 0xff54
    case 0xf702: return 0xff51
    case 0xf703: return 0xff53
    case 0xf704...0xf71b: return 0xffbe + value - 0xf704
    case 0xf727: return 0xff63
    case 0xf728: return 0xffff
    case 0xf729: return 0xff50
    case 0xf72b: return 0xff57
    case 0xf72c: return 0xff55
    case 0xf72d: return 0xff56
    case 0x20...0x7e, 0xa0...0xff: return value
    // AppKit's remaining function characters must not become Unicode text.
    case 0x00...0x9f, 0xf700...0xf8ff: return nil
    default: return 0x0100_0000 | value
    }
  }
}

public struct RFBKeyStroke: Equatable, Sendable {
  public let symbol: UInt32
  public let down: Bool
  public init(_ symbol: UInt32, down: Bool) {
    self.symbol = symbol
    self.down = down
  }
}

/// Host modifier families are deliberately collapsed to left-hand guest keys.
/// This avoids guessing device-dependent flags when both physical sides are held.
public struct RFBKeyboardModifiers: OptionSet, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = Self(rawValue: 1)
  public static let control = Self(rawValue: 2)
  public static let alt = Self(rawValue: 4)
  public static let command = Self(rawValue: 8)
}

/// Host-event state only: the RFB client independently tracks what it admitted.
/// Key-up uses the original symbol even after a layout/modifier change. Multiple
/// physical keys producing one symbol keep it held until the final key is up.
public struct RFBKeyboardState: Sendable {
  private var keys: [UInt16: UInt32] = [:]
  private var modifiers: RFBKeyboardModifiers = []
  public init() {}

  public mutating func press(keyCode: UInt16, symbol: UInt32) throws -> [RFBKeyStroke] {
    guard RFBKeySymbol.isSupported(symbol) else { throw RFBClientError.unsupportedKey }
    guard keys[keyCode] == nil else { return [] }  // guest owns held-key repeat
    guard keys.count < 32 else { throw RFBClientError.limitExceeded }
    let duplicate = keys.values.contains(symbol)
    keys[keyCode] = symbol
    return duplicate ? [] : [RFBKeyStroke(symbol, down: true)]
  }

  public mutating func release(keyCode: UInt16) -> [RFBKeyStroke] {
    guard let symbol = keys.removeValue(forKey: keyCode), !keys.values.contains(symbol) else {
      return []
    }
    return [RFBKeyStroke(symbol, down: false)]
  }

  public mutating func changeModifiers(_ next: RFBKeyboardModifiers) -> [RFBKeyStroke] {
    let mapping: [(RFBKeyboardModifiers, UInt32)] = [
      (.shift, 0xffe1), (.control, 0xffe3), (.alt, 0xffe9), (.command, 0xffeb),
    ]
    var changes: [RFBKeyStroke] = []
    // Release old modifiers before applying new ones; no lock-key toggles.
    for (flag, symbol) in mapping where modifiers.contains(flag) && !next.contains(flag) {
      changes.append(RFBKeyStroke(symbol, down: false))
    }
    for (flag, symbol) in mapping where !modifiers.contains(flag) && next.contains(flag) {
      changes.append(RFBKeyStroke(symbol, down: true))
    }
    modifiers = next
    return changes
  }

  /// AppKit menu key equivalents may consume the host key-up. Send a complete
  /// shortcut transaction and restore the previously tracked physical modifiers.
  public mutating func shortcut(
    keyCode: UInt16, symbol: UInt32, modifiers next: RFBKeyboardModifiers
  ) throws -> [RFBKeyStroke] {
    guard keys[keyCode] == nil, !keys.values.contains(symbol) else { return [] }
    guard RFBKeySymbol.isSupported(symbol) else { throw RFBClientError.unsupportedKey }
    let previous = modifiers
    var result = changeModifiers(next)
    result.append(contentsOf: try press(keyCode: keyCode, symbol: symbol))
    result.append(contentsOf: release(keyCode: keyCode))
    result.append(contentsOf: changeModifiers(previous))
    return result
  }

  public mutating func reset() {
    keys.removeAll()
    modifiers = []
  }
}
