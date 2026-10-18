// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Testing

@testable import MacOpenVMCLI

struct GPUWorkerOptionTests {
  @Test func refreshTraversesBothWorkerOptionGates() throws {
    let options = try MacOpenVMCLI.parse([
      "--directory", "/private/tmp/vm", "--run-directory", "/private/tmp/run",
      "--endpoint-directory", "/private/tmp/endpoints",
      "--display-profile", "neptune-metal-evaluation",
      "--display-width", "3456", "--display-height", "2168",
      "--gpu-host-window", "4G", "--gpu-refresh-millihertz", "120000",
    ])
    try MacOpenVMCLI.validateOptions(options, command: "windows-gpu-worker-lab")
    #expect(options["gpu-refresh-millihertz"] == "120000")
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.validateOptions(options, command: "windows-display-worker-lab")
    }
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.validateOptions(options, command: "windows-worker")
    }
  }

  @Test func duplicateRefreshAndUnknownOptionsRemainRejected() {
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.parse([
        "--gpu-refresh-millihertz", "60000", "--gpu-refresh-millihertz", "120000",
      ])
    }
    #expect(throws: VMError.self) {
      try MacOpenVMCLI.parse(["--gpu-refresh-override", "120000"])
    }
  }
}
