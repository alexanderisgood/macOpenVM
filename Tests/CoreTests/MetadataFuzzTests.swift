// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing
import VMCore

private let fuzzSentinel = "synthetic-private-sentinel-7bd448"
private let fuzzID = UUID(uuid: (0x7b, 0xd4, 0x48, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))
private let fuzzHost = HostResources(cpuCount: 12, memoryBytes: 32 * 1_073_741_824)
private let fuzzConfiguration = VMConfiguration(
  name: fuzzSentinel, guest: .linux, backend: .appleVz, id: fuzzID)
private let fuzzRecord = RuntimeRecord(
  sessionID: fuzzID, sequence: 1, recordedAt: 100,
  snapshot: RuntimeSnapshot(
    state: .starting, operation: .start, backendActive: false, outcome: .pending))

/// SplitMix64: fixed wrapping arithmetic makes the corpus independent of system randomness.
private struct MetadataGenerator {
  static let seed: UInt64 = 0x6d61_634f_7065_6e56
  var state = Self.seed
  mutating func next(_ bound: Int) -> Int {
    state &+= 0x9e37_79b9_7f4a_7c15
    var value = state
    value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
    value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
    return Int((value ^ (value >> 31)) % UInt64(bound))
  }
  mutating func input(index: Int, seed: Data) -> Data {
    var bytes = Array(
      "{\"fuzzCase\":\(index),\"privateSentinel\":\"\(fuzzSentinel)\",".utf8)
    bytes.append(contentsOf: seed.dropFirst())
    // Eight deterministic modes include valid unknown fields as acceptance controls.
    switch index % 8 {
    case 0: break
    case 1: bytes.append(contentsOf: (0..<8).map { _ in UInt8(next(256)) })
    case 2: bytes.removeLast(next(bytes.count - 48) + 1)
    case 3:
      for _ in 0..<(next(8) + 1) { bytes[next(bytes.count)] = UInt8(next(256)) }
    case 4:
      let insertion = (0..<16).map { _ in UInt8(next(256)) }
      bytes.insert(contentsOf: insertion, at: 48 + next(bytes.count - 48))
    case 5:
      let count = next(16) + 1
      let offset = 48 + next(bytes.count - 48 - count)
      bytes.removeSubrange(offset..<(offset + count))
    case 6:
      bytes = (0..<(next(240) + 16)).map { _ in UInt8(next(256)) }
    default:
      bytes.insert(UInt8(ascii: "["), at: 0)
      bytes.append(UInt8(ascii: "]"))
    }
    return Data(bytes)
  }
}

private func controlled(_ error: any Error, code: VMError.Code) {
  guard let vmError = error as? VMError else {
    Issue.record("Metadata escaped the controlled VMError contract.")
    return
  }
  #expect(vmError.code == code)
  let text = vmError.message + vmError.recovery + (vmError.errorDescription ?? "")
  #expect(!text.contains(fuzzSentinel))
  #expect(!text.contains(fuzzID.uuidString))
}

@discardableResult private func checkConfiguration(_ data: Data) throws -> Bool {
  let value: VMConfiguration
  do { value = try ConfigurationCodec.decode(data) } catch {
    controlled(error, code: .corruptMetadata)
    return false
  }
  #expect(try ConfigurationCodec.decode(ConfigurationCodec.encode(value)) == value)
  do { try ConfigurationValidator.validate(value, host: fuzzHost) } catch {
    controlled(error, code: .invalidConfiguration)
  }
  return true
}

@discardableResult private func checkRuntime(_ data: Data) throws -> Bool {
  let value: RuntimeRecord
  do { value = try RuntimeHistoryCodec.decode(data) } catch {
    controlled(error, code: .corruptMetadata)
    return false
  }
  #expect(try RuntimeHistoryCodec.decode(RuntimeHistoryCodec.encode(value)) == value)
  return true
}

private func rejectConfiguration(_ data: Data) {
  do {
    _ = try ConfigurationCodec.decode(data)
    Issue.record("Malformed configuration was accepted.")
  } catch { controlled(error, code: .corruptMetadata) }
}
private func rejectRuntime(_ data: Data) {
  do {
    _ = try RuntimeHistoryCodec.decode(data)
    Issue.record("Malformed runtime record was accepted.")
  } catch { controlled(error, code: .corruptMetadata) }
}

@Test(.timeLimit(.minutes(1))) func seededMetadataMutationCorpus() throws {
  let configuration = try ConfigurationCodec.encode(fuzzConfiguration)
  let runtime = try RuntimeHistoryCodec.encode(fuzzRecord)
  var generator = MetadataGenerator()
  var unique: Set<Data> = []
  var accepted = 0
  for index in 0..<12_000 {
    // Separate parity from mutation mode so each codec sees all eight modes.
    let configurationCase = (index / 8) % 2 == 0
    let input = generator.input(index: index, seed: configurationCase ? configuration : runtime)
    #expect(input.count <= 2048)
    unique.insert(input)
    let decoded = try configurationCase ? checkConfiguration(input) : checkRuntime(input)
    if index % 8 == 0 { #expect(decoded) }
    if decoded { accepted += 1 }
  }
  #expect(unique.count >= 10_000)
  #expect(accepted >= 1500)
  #expect(12_000 - accepted >= 6000)
  print(
    "Metadata corpus seed=0x6d61634f70656e56 inputs=12000 unique=\(unique.count) accepted=\(accepted) rejected=\(12_000 - accepted)"
  )
}

/// JSONSerialization is used only to construct fixtures, never to decide codec acceptance.
private func replacing(_ key: String, raw: String, in data: Data) throws -> Data {
  let decoded = try JSONSerialization.jsonObject(with: data)
  var object = try #require(decoded as? [String: Any])
  object[key] = "numeric-fixture-placeholder"
  object["privateSentinel"] = fuzzSentinel
  let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  return Data(
    String(decoding: bytes, as: UTF8.self).replacingOccurrences(
      of: "\"numeric-fixture-placeholder\"", with: raw
    ).utf8)
}

@Test(.timeLimit(.minutes(1))) func metadataNumericUTF8NestingAndByteBoundaries() throws {
  let configuration = try ConfigurationCodec.encode(fuzzConfiguration)
  let runtime = try RuntimeHistoryCodec.encode(fuzzRecord)
  for field in ["memoryBytes", "diskBytes"] {
    for number in ["-1", "18446744073709551616", "1.5", "1e400", "NaN", "null", "true"] {
      rejectConfiguration(try replacing(field, raw: number, in: configuration))
    }
  }
  for number in ["9223372036854775808", "-9223372036854775809", "1.5", "1e400"] {
    rejectConfiguration(try replacing("cpuCount", raw: number, in: configuration))
  }
  for number in ["-1", "0", "18446744073709551616", "1.5", "1e400", "null", "true"] {
    rejectRuntime(try replacing("sequence", raw: number, in: runtime))
  }
  for number in ["-1", "1e400", "NaN", "null", "true"] {
    rejectRuntime(try replacing("recordedAt", raw: number, in: runtime))
  }
  for version in ["0", "-1", "2", "9223372036854775807", "1.5"] {
    rejectConfiguration(try replacing("schemaVersion", raw: version, in: configuration))
    rejectRuntime(try replacing("schemaVersion", raw: version, in: runtime))
  }
  // Representable extremes decode, then obey the distinct hardware-policy layer.
  for field in ["cpuCount", "memoryBytes", "diskBytes"] {
    let extremes =
      field == "cpuCount"
      ? ["-9223372036854775808", "9223372036854775807"] : ["0", "18446744073709551615"]
    for number in extremes {
      let value = try ConfigurationCodec.decode(replacing(field, raw: number, in: configuration))
      do {
        try ConfigurationValidator.validate(value, host: fuzzHost)
        Issue.record("Unsafe hardware extreme was accepted.")
      } catch { controlled(error, code: .invalidConfiguration) }
      #expect(try ConfigurationCodec.decode(ConfigurationCodec.encode(value)) == value)
    }
  }
  #expect(try checkRuntime(replacing("sequence", raw: "18446744073709551615", in: runtime)))
  #expect(try checkRuntime(replacing("recordedAt", raw: "1.7976931348623157e308", in: runtime)))
  let invalidUTF8: [[UInt8]] = [
    [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xff],
  ]
  for invalid in invalidUTF8 {
    // All required fields remain intact; removing only these bytes gives a valid record.
    for (field, original, source, configurationCase) in [
      ("name", fuzzSentinel, configuration, true),
      ("sessionID", fuzzID.uuidString, runtime, false),
    ] {
      var bytes = try replacing(field, raw: "\"utf8-fixture\"", in: source)
      let range = try #require(bytes.range(of: Data("\"utf8-fixture\"".utf8)))
      bytes.replaceSubrange(
        range, with: Data("\"\(original)".utf8) + Data(invalid) + Data([0x22]))
      if configurationCase { rejectConfiguration(bytes) } else { rejectRuntime(bytes) }
    }
  }
  for depth in [1, 32, 128, 512, 1024] {
    let nested =
      String(repeating: "[", count: depth) + "null" + String(repeating: "]", count: depth)
    let root = Data(nested.utf8)
    rejectConfiguration(root)
    rejectRuntime(root)
    // Unknown nested fields are permitted only if Foundation accepts the bounded JSON.
    _ = try checkConfiguration(replacing("unknown", raw: nested, in: configuration))
    _ = try checkRuntime(replacing("unknown", raw: nested, in: runtime))
  }
  let atConfigurationLimit =
    configuration
    + Data(
      repeating: 0x20, count: ConfigurationCodec.maximumBytes - configuration.count)
  let atRuntimeLimit =
    runtime
    + Data(
      repeating: 0x20, count: RuntimeHistoryCodec.maximumBytes - runtime.count)
  #expect(try ConfigurationCodec.decode(atConfigurationLimit) == fuzzConfiguration)
  #expect(try RuntimeHistoryCodec.decode(atRuntimeLimit) == fuzzRecord)
  rejectConfiguration(atConfigurationLimit + Data([0x20]))
  rejectRuntime(atRuntimeLimit + Data([0x20]))
  var oversized = fuzzConfiguration
  oversized.kernelArguments = String(repeating: fuzzSentinel, count: 3000)
  do {
    _ = try ConfigurationCodec.encode(oversized)
    Issue.record("Oversized encoded configuration was accepted.")
  } catch { controlled(error, code: .corruptMetadata) }
  for timestamp in [Double.nan, .infinity, -.infinity, -1] {
    do {
      _ = try RuntimeHistoryCodec.encode(
        RuntimeRecord(
          sessionID: fuzzID, sequence: 1, recordedAt: timestamp, snapshot: fuzzRecord.snapshot))
      Issue.record("Invalid timestamp was encoded.")
    } catch { controlled(error, code: .corruptMetadata) }
  }
}

@Test func runtimeStopRecordsRejectEveryInconsistentStateOperationAndOwnershipCombination() throws {
  let operations: [LifecycleOperation?] = [nil] + LifecycleOperation.allCases.map { Optional($0) }
  var rejected = 0
  for outcome in [RuntimeOutcome.guestStopped, .forcedStopped] {
    for state in VMState.allCases {
      for operation in operations {
        for active in [false, true] {
          let record = RuntimeRecord(
            sessionID: fuzzID, sequence: 1, recordedAt: 100,
            snapshot: RuntimeSnapshot(
              state: state, operation: operation, backendActive: active, outcome: outcome))
          let bytes = try JSONEncoder().encode(record)
          if state == .stopped && operation == nil && !active {
            #expect(try RuntimeHistoryCodec.decode(bytes) == record)
            #expect(try RuntimeHistoryCodec.decode(RuntimeHistoryCodec.encode(record)) == record)
          } else {
            rejectRuntime(bytes)
            do {
              _ = try RuntimeHistoryCodec.encode(record)
              Issue.record("Inconsistent stopped outcome was encoded.")
            } catch { controlled(error, code: .corruptMetadata) }
            rejected += 1
          }
        }
      }
    }
  }
  #expect(rejected == 350)
}
