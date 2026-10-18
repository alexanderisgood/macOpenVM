// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Testing

@testable import MacOpenVMApp

@Suite struct WindowsDisplayEvaluationRequestTests {
  @Test func optionalSavedVMOpeningStillRequiresExplicitEvaluationAndBoundedPath() throws {
    let base = ["app", WindowsDisplayEvaluationRequest.gpuFlag, "native", "native"]
    let env = ["MVO_WINDOWS_GPU_EVALUATION": "1"]
    let path = "/private/tmp/preserved-test.macopenvm/configuration.json"
    let selected = try #require(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: base + ["--open-evaluation-vm", path], environment: env))
    #expect(selected.configurationURL?.path == path)
    for invalid in [
      "relative/configuration.json", "/tmp/../configuration.json",
      "/tmp/wrong.json", "/tmp/a\n/configuration.json",
    ] {
      #expect(throws: VMError.self) {
        try WindowsDisplayEvaluationRequest.parse(
          arguments: base + ["--open-evaluation-vm", invalid], environment: env)
      }
    }
    #expect(throws: VMError.self) {
      try WindowsDisplayEvaluationRequest.parse(
        arguments: base + ["--open-evaluation-vm", path], environment: [:])
    }
    #expect(throws: VMError.self) {
      try WindowsDisplayEvaluationRequest.parse(
        arguments: base + ["--start-without-inspection", path], environment: env)
    }
  }
  @Test func acceleratedProfileRequiresItsOwnExplicitOptIn() throws {
    let flag = WindowsDisplayEvaluationRequest.gpuFlag
    let native = try #require(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: ["app", flag, "native", "native"],
        environment: ["MVO_WINDOWS_GPU_EVALUATION": "1"]))
    #expect(native.native && native.accelerated && native.display == nil)
    #expect(throws: VMError.self) {
      try WindowsDisplayEvaluationRequest.parse(
        arguments: ["app", flag, "native", "native"],
        environment: ["MVO_WINDOWS_2D_DISPLAY_EVALUATION": "1"])
    }
  }
  @Test func ordinaryStartsRemainUnselected() throws {
    #expect(try WindowsDisplayEvaluationRequest.parse(arguments: ["app"], environment: [:]) == nil)
  }
  @Test func highRefreshRequiresASeparateClosedGPUOptIn() throws {
    let arguments = ["app", WindowsDisplayEvaluationRequest.gpuFlag, "3456", "2168"]
    let ordinary = ["MVO_WINDOWS_GPU_EVALUATION": "1"]
    #expect(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: arguments, environment: ordinary)?.refreshRate == .hz60)
    var selected = ordinary
    selected[WindowsDisplayEvaluationRequest.highRefreshEnvironment] = "120000"
    #expect(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: arguments, environment: selected)?.refreshRate == .hz120)
    for invalid in ["", "1", "60000", "119999", "120000,blob=off"] {
      var environment = ordinary
      environment[WindowsDisplayEvaluationRequest.highRefreshEnvironment] = invalid
      #expect(throws: VMError.self) {
        try WindowsDisplayEvaluationRequest.parse(arguments: arguments, environment: environment)
      }
    }
    #expect(throws: VMError.self) {
      try WindowsDisplayEvaluationRequest.parse(
        arguments: ["app", WindowsDisplayEvaluationRequest.flag, "3456", "2168"],
        environment: [
          "MVO_WINDOWS_2D_DISPLAY_EVALUATION": "1",
          WindowsDisplayEvaluationRequest.highRefreshEnvironment: "120000",
        ])
    }
  }
  @Test func exactOptInAndBoundedDimensionsAreRequired() throws {
    let flag = WindowsDisplayEvaluationRequest.flag
    let env = ["MVO_WINDOWS_2D_DISPLAY_EVALUATION": "1"]
    let selected = try #require(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: ["app", flag, "1800", "1200"], environment: env))
    #expect(selected.display?.initialPixels == PixelSize(width: 1800, height: 1200))
    let native = try #require(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: ["app", flag, "native", "native"], environment: env))
    #expect(native.native && native.display == nil)
    for arguments in [
      ["app", flag, "native", "1200"],
      ["app", flag], ["app", flag, "-1", "600"],
      ["app", flag, "8192", "8192"], ["app", flag, "1800", "1200", "--foreign"],
      ["app", flag, "nan", "600"],
    ] {
      #expect(throws: VMError.self) {
        try WindowsDisplayEvaluationRequest.parse(arguments: arguments, environment: env)
      }
    }
    #expect(throws: VMError.self) {
      try WindowsDisplayEvaluationRequest.parse(
        arguments: ["app", flag, "1800", "1200"], environment: [:])
    }
  }
}
