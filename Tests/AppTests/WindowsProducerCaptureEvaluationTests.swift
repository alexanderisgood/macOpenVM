// SPDX-License-Identifier: Apache-2.0
// SOURCE ONLY / UNRUN. Pure request, recipe and freshness values; no worker/VM launch.
import BackendAPI
import Foundation
import Qemu
import Testing

@testable import MacOpenVMApp

@Suite @MainActor struct WindowsProducerCaptureEvaluationTests {
  private let vm = URL(fileURLWithPath: "/private/tmp/arguments-only.macopenvm")
  private let run = URL(
    fileURLWithPath:
      "/private/tmp/arguments-only.macopenvm/.runtime/run-0123456789abcdef0123456789abcdef")
  private let endpoint = URL(fileURLWithPath: "/private/tmp/mvo-qemu-0123456789abcdef")
  private var captureArguments: [String] {
    ["app", WindowsDisplayEvaluationRequest.producerCaptureFlag, "3456", "2168"]
  }
  private var captureEnvironment: [String: String] {
    [
      "MVO_WINDOWS_GPU_EVALUATION": "1",
      WindowsDisplayEvaluationRequest.producerCaptureEnvironment: "1",
    ]
  }
  private func gpu() throws -> ReviewedQemuAcceleratedDisplay {
    try ReviewedQemuAcceleratedDisplay(
      initialPixels: PixelSize(width: 3456, height: 2168),
      separateFirmware: true, hostWindow: .fourGiB, refreshRate: .hz120)
  }

  @Test func captureRequestRequiresBothClosedOptinsAndExplicitPhysicalDimensions() throws {
    let chosen = try #require(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: captureArguments, environment: captureEnvironment))
    #expect(chosen.producerCapture == .boundedProducerV1 && chosen.accelerated && !chosen.native)
    #expect(chosen.display?.initialPixels == PixelSize(width: 3456, height: 2168))
    for environment in [
      [:], ["MVO_WINDOWS_GPU_EVALUATION": "1"],
      [WindowsDisplayEvaluationRequest.producerCaptureEnvironment: "1"],
      [
        "MVO_WINDOWS_GPU_EVALUATION": "1",
        WindowsDisplayEvaluationRequest.producerCaptureEnvironment: "bounded-producer-v1-signed",
      ],
    ] {
      #expect(throws: VMError.self) {
        try WindowsDisplayEvaluationRequest.parse(
          arguments: captureArguments, environment: environment)
      }
    }
    for arguments in [
      ["app", WindowsDisplayEvaluationRequest.producerCaptureFlag, "native", "native"],
      ["app", WindowsDisplayEvaluationRequest.producerCaptureFlag, "8192", "8192"],
      captureArguments + ["--socket", "/arbitrary/qmp.sock"],
    ] {
      #expect(throws: VMError.self) {
        try WindowsDisplayEvaluationRequest.parse(
          arguments: arguments, environment: captureEnvironment)
      }
    }
  }

  @Test func ordinaryAppAndGPUFlagsNeverAcquireCaptureFromAnInheritedEnvironment() throws {
    #expect(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: ["app"],
        environment: captureEnvironment) == nil)
    for flag in [WindowsDisplayEvaluationRequest.gpuFlag, WindowsDisplayEvaluationRequest.flag] {
      let environment =
        flag == WindowsDisplayEvaluationRequest.gpuFlag
        ? ["MVO_WINDOWS_GPU_EVALUATION": "1"] : ["MVO_WINDOWS_2D_DISPLAY_EVALUATION": "1"]
      let ordinary = try #require(
        try WindowsDisplayEvaluationRequest.parse(
          arguments: ["app", flag, "3456", "2168"], environment: environment))
      #expect(ordinary.producerCapture == nil)
      var inherited = environment
      inherited[WindowsDisplayEvaluationRequest.producerCaptureEnvironment] = "1"
      #expect(throws: VMError.self) {
        try WindowsDisplayEvaluationRequest.parse(
          arguments: ["app", flag, "3456", "2168"], environment: inherited)
      }
    }
  }

  @Test func explicitCaptureRetainsTheClosedRefreshAndVMSelectionRules() throws {
    let path = "/private/tmp/arguments-only.macopenvm/configuration.json"
    var environment = captureEnvironment
    environment[WindowsDisplayEvaluationRequest.highRefreshEnvironment] = "120000"
    let selected = try #require(
      try WindowsDisplayEvaluationRequest.parse(
        arguments: captureArguments + ["--open-evaluation-vm", path], environment: environment))
    #expect(selected.configurationURL?.path == path && selected.refreshRate == .hz120)
    #expect(selected.producerCapture == .boundedProducerV1)
    environment[WindowsDisplayEvaluationRequest.highRefreshEnvironment] = "120001"
    #expect(throws: VMError.self) {
      try WindowsDisplayEvaluationRequest.parse(
        arguments: captureArguments, environment: environment)
    }
    #expect(throws: VMError.self) {
      try WindowsDisplayEvaluationRequest.parse(
        arguments: captureArguments + ["--open-evaluation-vm", "/tmp/../configuration.json"],
        environment: captureEnvironment)
    }
  }

  @Test func captureRecipeSelectsOnlyTheExistingClosedSignedWorkerCommand() throws {
    let arguments = try DesktopWindowsRuntime.workerArguments(
      directory: vm, runDirectory: run,
      endpointDirectory: endpoint, acceleratedDisplay: gpu(), producerCapture: .boundedProducerV1)
    #expect(
      arguments == [
        "windows-producer-capture-worker-lab", "--directory", vm.path, "--run-directory", run.path,
        "--endpoint-directory", endpoint.path, "--display-profile", "neptune-metal-evaluation",
        "--display-width", "3456", "--display-height", "2168", "--gpu-host-window", "4G",
        "--gpu-refresh-millihertz", "120000", "--capture-profile", "bounded-producer-v1-signed",
      ])
    #expect(!arguments.contains("--socket") && !arguments.contains("--qmp-socket"))
    let basic = try DesktopWindowsRuntime.workerArguments(
      directory: vm, runDirectory: run,
      endpointDirectory: endpoint)
    #expect(
      basic == [
        "windows-worker", "--directory", vm.path, "--run-directory", run.path,
        "--endpoint-directory", endpoint.path,
      ])
    let ordinaryGPU = try DesktopWindowsRuntime.workerArguments(
      directory: vm, runDirectory: run,
      endpointDirectory: endpoint, acceleratedDisplay: gpu())
    #expect(ordinaryGPU == ["windows-gpu-worker-lab"] + Array(arguments.dropFirst().dropLast(2)))
    let display = try ReviewedQemu2DDisplay(initialPixels: PixelSize(width: 1800, height: 1200))
    let ordinary2D = try DesktopWindowsRuntime.workerArguments(
      directory: vm, runDirectory: run,
      endpointDirectory: endpoint, displayEvaluation: display)
    #expect(
      ordinary2D == [
        "windows-display-worker-lab", "--directory", vm.path,
        "--run-directory", run.path, "--endpoint-directory", endpoint.path,
        "--display-profile", "virtio-gpu-2d-evaluation", "--display-width", "1800",
        "--display-height", "1200",
      ])
  }

  @Test func aCaptureRecipeCannotBeMadeForDefaultTwoDimensionalOrMixedDisplayInputs() throws {
    let display = try ReviewedQemu2DDisplay(initialPixels: PixelSize(width: 1800, height: 1200))
    let accelerated = try gpu()
    let pairs: [(ReviewedQemu2DDisplay?, ReviewedQemuAcceleratedDisplay?)] = [
      (nil, nil), (display, nil), (display, accelerated),
    ]
    for pair in pairs {
      #expect(throws: VMError.self) {
        try DesktopWindowsRuntime.workerArguments(
          directory: vm, runDirectory: run,
          endpointDirectory: endpoint, displayEvaluation: pair.0, acceleratedDisplay: pair.1,
          producerCapture: .boundedProducerV1)
      }
    }
  }

  @Test func captureReadinessCannotReuseAnOrdinaryGPUObservationOrAnOwnedRuntime() {
    let url = vm.appendingPathComponent("configuration.json")
    let configuration = VMConfiguration(
      name: "Pure capture request", guest: .windows11,
      backend: .qemuHVF, diskBytes: 64 << 30)
    let request = WindowsLaunchReadinessRequest(
      configurationURL: url,
      configuration: configuration, profile: .producerCapture)
    #expect(
      request.canApply(
        generation: request.generation, selectedURL: url,
        configuration: configuration, profile: .producerCapture, hasOwnedWindowsRuntime: false))
    #expect(
      !request.canApply(
        generation: request.generation, selectedURL: url,
        configuration: configuration, profile: .accelerated, hasOwnedWindowsRuntime: false))
    #expect(
      !request.canApply(
        generation: request.generation, selectedURL: url,
        configuration: configuration, profile: .producerCapture, hasOwnedWindowsRuntime: true))
  }
}
