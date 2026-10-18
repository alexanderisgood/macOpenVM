// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// Strict bounded registration bytes. Disk growth changes one numeric token,
/// preserving every other byte, including formatting and escaped string values.
package struct StrictConfigurationDocument: Sendable {
  let bytes: Data
  package let configuration: VMConfiguration

  package init(_ data: Data) throws {
    _ = try Self.knownObject(data)
    configuration = try ConfigurationCodec.decode(data)
    bytes = data
  }

  func replacingDiskBytes(with target: UInt64) throws -> StrictConfigurationDocument {
    var parser = ConfigurationFieldParser(bytes: Array(bytes))
    let fields = try parser.parse()
    guard let span = fields["diskBytes"], !span.isEmpty else { throw Self.invalid() }
    var replacement = bytes
    let range = (bytes.startIndex + span.lowerBound)..<(bytes.startIndex + span.upperBound)
    replacement.replaceSubrange(range, with: String(target).utf8)
    let document = try StrictConfigurationDocument(replacement)
    var expected = configuration
    expected.diskBytes = target
    guard document.configuration == expected else { throw Self.invalid() }
    return document
  }

  /// Replace one existing string token without reserializing surrounding fields.
  func replacingKernelArguments(with arguments: String) throws -> StrictConfigurationDocument {
    var expected = configuration
    expected.kernelArguments = arguments
    return try replacingStrings(["kernelArguments": arguments], expected: expected)
  }

  /// Select both existing image strings and arguments in one registration replacement.
  func replacingBootSelection(kernel: String, initialRamdisk: String, arguments: String) throws
    -> StrictConfigurationDocument
  {
    var expected = configuration
    expected.kernel = kernel
    expected.initialRamdisk = initialRamdisk
    expected.kernelArguments = arguments
    return try replacingStrings(
      ["kernel": kernel, "initialRamdisk": initialRamdisk, "kernelArguments": arguments],
      expected: expected)
  }

  private func replacingStrings(_ values: [String: String], expected: VMConfiguration) throws
    -> StrictConfigurationDocument
  {
    var parser = ConfigurationFieldParser(bytes: Array(bytes))
    let fields = try parser.parse()
    let replacements = try values.map { key, value -> (Range<Int>, Data) in
      guard let span = fields[key], !span.isEmpty, bytes[bytes.startIndex + span.lowerBound] == 0x22
      else { throw Self.invalid() }
      return (span, try JSONEncoder().encode(value))
    }.sorted { $0.0.lowerBound > $1.0.lowerBound }
    var replacement = bytes
    for (span, token) in replacements {
      let range = (bytes.startIndex + span.lowerBound)..<(bytes.startIndex + span.upperBound)
      replacement.replaceSubrange(range, with: token)
    }
    let document = try StrictConfigurationDocument(replacement)
    guard document.configuration == expected else { throw Self.invalid() }
    return document
  }

  /// Installation-media editing retains its existing object serialization behavior.
  static func knownObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= ConfigurationCodec.maximumBytes else { throw invalid() }
    let object: [String: Any]
    do {
      guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw invalid()
      }
      object = decoded
    } catch { throw invalid() }
    guard Set(object.keys).isSubset(of: knownFields) else { throw invalid() }
    var parser = ConfigurationFieldParser(bytes: Array(data))
    guard Set(try parser.parse().keys) == Set(object.keys) else { throw invalid() }
    return object
  }

  private static let knownFields: Set<String> = [
    "schemaVersion", "id", "name", "guest", "architecture", "backend", "cpuCount", "memoryBytes",
    "diskBytes", "diskFile", "boot", "installationMedia", "supportMedia", "kernel",
    "initialRamdisk",
    "kernelArguments", "network", "macAddress",
  ]

  fileprivate static func invalid() -> VMError {
    VMError(
      .corruptMetadata, "Configuration is malformed, oversized or contains unsupported fields.",
      recovery:
        "Preserve the original configuration and use read-only inspection before changing it.")
  }
}

/// Foundation has checked complete JSON syntax. This bounded top-level lexical
/// pass decodes key strings so escaped duplicates cannot collapse into one field.
/// It captures scalar value ranges; every supported configuration field is scalar.
private struct ConfigurationFieldParser {
  let bytes: [UInt8]
  private var index = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
    if bytes.starts(with: [0xef, 0xbb, 0xbf]) { index = 3 }
  }

  mutating func parse() throws -> [String: Range<Int>] {
    try consume(0x7b)
    var fields: [String: Range<Int>] = [:]
    whitespace()
    if current == 0x7d {
      index += 1
    } else {
      while true {
        let keySpan = try stringSpan()
        let key: String
        do { key = try JSONDecoder().decode(String.self, from: Data(bytes[keySpan])) } catch {
          throw StrictConfigurationDocument.invalid()
        }
        guard fields[key] == nil, fields.count < 18 else {
          throw StrictConfigurationDocument.invalid()
        }
        try consume(0x3a)
        whitespace()
        let start = index
        if current == 0x22 {
          _ = try stringSpan()
        } else {
          guard current != 0x7b, current != 0x5b else {
            throw StrictConfigurationDocument.invalid()
          }
          while let byte = current, ![0x2c, 0x7d, 9, 10, 13, 32].contains(byte) { index += 1 }
        }
        guard index > start else { throw StrictConfigurationDocument.invalid() }
        fields[key] = start..<index
        whitespace()
        if current == 0x7d {
          index += 1
          break
        }
        try consume(0x2c)
      }
    }
    whitespace()
    guard index == bytes.count else { throw StrictConfigurationDocument.invalid() }
    return fields
  }

  private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

  private mutating func stringSpan() throws -> Range<Int> {
    whitespace()
    let start = index
    try consume(0x22)
    var escaped = false
    while let byte = current {
      index += 1
      if escaped {
        escaped = false
      } else if byte == 0x5c {
        escaped = true
      } else if byte == 0x22 {
        return start..<index
      }
    }
    throw StrictConfigurationDocument.invalid()
  }

  private mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard current == byte else { throw StrictConfigurationDocument.invalid() }
    index += 1
  }

  private mutating func whitespace() {
    while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 }
  }
}
