// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu

/// Closed development entry point; no saved VM setting selects this device experiment.
struct WindowsDisplayEvaluationRequest: Equatable, Sendable {
  static let flag = "--windows-2d-display-evaluation"
  static let gpuFlag = "--windows-gpu-evaluation"
  static let producerCaptureFlag = "--windows-producer-capture-evaluation"
  static let producerCaptureEnvironment = "MVO_WINDOWS_PRODUCER_CAPTURE_EVALUATION"
  static let highRefreshEnvironment = "MVO_WINDOWS_GPU_HIGH_REFRESH_EVALUATION"
  let display: ReviewedQemu2DDisplay?
  let native: Bool
  var accelerated = false
  var configurationURL: URL?
  var refreshRate: ReviewedQemuAcceleratedDisplay.RefreshRate = .hz60
  var producerCapture: CaptureCapability? = nil

  static func parse(arguments: [String], environment: [String: String]) throws -> Self? {
    let capture = arguments.contains(producerCaptureFlag)
    let gpu = arguments.contains(gpuFlag) || capture
    guard arguments.contains(flag) || gpu else { return nil }
    guard
      environment[gpu ? "MVO_WINDOWS_GPU_EVALUATION" : "MVO_WINDOWS_2D_DISPLAY_EVALUATION"] == "1",
      [4, 6].contains(arguments.count),
      arguments[1] == (capture ? producerCaptureFlag : gpu ? gpuFlag : flag)
    else {
      throw VMError(
        .invalidConfiguration, "The private Windows display experiment is invalid.",
        recovery: "Use the reviewed evaluation launcher with bounded initial dimensions.")
    }
    // Both explicit GPU evaluation and the separate capture opt-in are needed.
    // Neither an inherited environment value nor an ordinary GPU flag enables it.
    guard
      capture
        ? environment[producerCaptureEnvironment] == "1"
        : environment[producerCaptureEnvironment] == nil
    else {
      throw VMError(
        .invalidConfiguration, "The private producer capture experiment is invalid.",
        recovery: "Use its separate reviewed flag and explicit physical dimensions.")
    }
    guard !capture || (arguments[2] != "native" && arguments[3] != "native") else {
      throw VMError(
        .invalidConfiguration, "Producer capture requires explicit physical dimensions.",
        recovery: "Independently check the Windows mode before selecting bounded dimensions.")
    }
    let highRefresh = environment[highRefreshEnvironment]
    guard highRefresh == nil || (gpu && highRefresh == "120000") else {
      throw VMError(
        .invalidConfiguration, "The private high-refresh experiment is invalid.",
        recovery: "Use the reviewed GPU launcher after qualifying the updated guest driver.")
    }
    let refresh: ReviewedQemuAcceleratedDisplay.RefreshRate = highRefresh == nil ? .hz60 : .hz120
    let configurationURL: URL?
    if arguments.count == 6 {
      let path = arguments[5]
      guard arguments[4] == "--open-evaluation-vm", path.hasPrefix("/"),
        path.utf8.count <= 4096, !path.contains(","),
        !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        !path.split(separator: "/").contains(".."),
        URL(fileURLWithPath: path).lastPathComponent == "configuration.json"
      else {
        throw VMError(
          .invalidConfiguration, "The evaluation VM path is invalid.",
          recovery: "Select an absolute path to the preserved VM's configuration.json.")
      }
      configurationURL = URL(fileURLWithPath: path)
    } else {
      configurationURL = nil
    }
    if arguments[2] == "native", arguments[3] == "native" {
      return Self(
        display: nil, native: true, accelerated: gpu, configurationURL: configurationURL,
        refreshRate: refresh)
    }
    guard let width = Int(arguments[2]), let height = Int(arguments[3]) else {
      throw VMError(
        .invalidConfiguration, "The display dimensions are invalid.",
        recovery: "Choose native dimensions or explicit bounded pixel dimensions.")
    }
    return try Self(
      display: ReviewedQemu2DDisplay(initialPixels: PixelSize(width: width, height: height)),
      native: false, accelerated: gpu, configurationURL: configurationURL, refreshRate: refresh,
      producerCapture: capture ? .boundedProducerV1 : nil)
  }
}
