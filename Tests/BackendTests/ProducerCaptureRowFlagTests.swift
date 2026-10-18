// SPDX-License-Identifier: Apache-2.0
// Source-only directed cases; no native API, QEMU, worker, device or VM fixture.
import BackendAPI
import Testing

private func rowFlagWords(event: UInt64, flags: UInt64) -> [UInt64] {
  var words = [UInt64](repeating: 0, count: 18)
  words[0] = 1
  words[1] = event
  words[2] = flags
  words[3] = 1
  words[4] = 2
  words[6] = .max
  words[7] = .max
  words[10] = 100
  words[11] = 101
  return words
}

@Suite("ProducerCaptureRowFlagTests")
struct ProducerCaptureRowFlagTests {
  @Test func eachFixedGpuDiagnosticKindRetainsEveryCommonFlagCombination() throws {
    for kind in UInt64(1)...3 {
      for common in UInt64(0)...7 {
        let words = rowFlagWords(event: 10, flags: (kind << 16) | common)
        #expect(try CaptureRow(words).words == words)
      }
    }
  }

  @Test func gpuDiagnosticRejectsMissingKindAndEveryUndocumentedBit() {
    for common in UInt64(0)...7 {
      #expect(throws: CaptureFault.malformed) {
        try CaptureRow(rowFlagWords(event: 10, flags: common))
      }
    }
    for kind in UInt64(1)...3 {
      for bit in 3...63 where bit != 16 && bit != 17 {
        let flags = (kind << 16) | (UInt64(1) << bit) | 1
        #expect(throws: CaptureFault.malformed) {
          try CaptureRow(rowFlagWords(event: 10, flags: flags))
        }
      }
    }
  }

  @Test func allOtherEventsRetainOnlyTheOriginalCommonFlags() throws {
    for event in UInt64(1)...9 {
      for flags in UInt64(0)...7 {
        let words = rowFlagWords(event: event, flags: flags)
        #expect(try CaptureRow(words).words == words)
      }
      for bit in 3...63 {
        #expect(throws: CaptureFault.malformed) {
          try CaptureRow(rowFlagWords(event: event, flags: UInt64(1) << bit))
        }
      }
    }
  }

  @Test func gpuDiagnosticFlagAllowanceDoesNotRelaxRowIdentityOrShape() {
    let valid = rowFlagWords(event: 10, flags: 0x0001_0001)
    for (field, value) in [
      (0, UInt64(4096)), (1, 11), (3, 0),
      (3, UInt64.max), (4, 1), (5, 2),
    ] {
      var words = valid
      words[field] = value
      #expect(throws: CaptureFault.malformed) { try CaptureRow(words) }
    }
    #expect(throws: CaptureFault.malformed) { try CaptureRow(Array(valid.dropLast())) }
    #expect(throws: CaptureFault.malformed) { try CaptureRow(valid + [0]) }
  }
}
