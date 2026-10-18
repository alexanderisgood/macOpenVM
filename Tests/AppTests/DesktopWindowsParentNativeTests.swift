// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import MacOpenVMApp

/// Actual owned spawn/regular-descriptor qualification. The worker probe
/// has no configuration and must fail before writer admission or any VM launch.
@Suite(
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_PARENT_CHECK"] == "1",
    "Requires explicit MACOPENVM_NATIVE_PARENT_CHECK=1; benign process and pre-admission worker only."
  )
)
struct DesktopWindowsParentNativeTests {
  private func fixture() throws -> (URL, URL) {
    let root = URL(
      fileURLWithPath: "/private/tmp/windows-parent-check-\(UUID().uuidString)", isDirectory: true)
    let run = root.appendingPathComponent("run", isDirectory: true)
    for path in [root, run] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    return (root, run)
  }

  @Test func benignProcessActuallyReapsAndClosesRegularDescriptors() async throws {
    let (root, run) = try fixture()
    let parent = DesktopWindowsParent(
      executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
      directory: root, runDirectory: run)
    try await parent.launch()
    let result = await parent.waitForTermination()
    #expect(result.submitted && result.started && result.reaped && result.descriptorsClosed)
    #expect(
      result.exitStatus == 0 && !result.signalled && result.failure == nil && !result.isActive)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: run.path).sorted()
        == ["parent-stderr.log", "parent-stdout.log"])
    if result.reaped && result.descriptorsClosed { try FileManager.default.removeItem(at: root) }
  }

  @Test func realBundledWorkerSeparatesItsSessionBeforeConfigurationRefusal() async throws {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let app = project.appendingPathComponent(
      ".lab/linux-desktop-artifacts-7376314220144fa8b3785b176dcc800a/macOpenVM.app")
    let admitted = try BundledWindowsWorkerAdmission.inspect(
      bundleURL: app,
      mainExecutableURL: app.appendingPathComponent("Contents/MacOS/macOpenVMNative"),
      bundleIdentifier: "local.macOpenVM.linuxTrial.7376314220144fa8b3785b176dcc800a",
      signature: BundledWindowsWorkerAdmission.nativeSignature)
    let (root, run) = try fixture()
    let missingVM = root.appendingPathComponent("NoConfiguration.macopenvm")
    let parent = DesktopWindowsParent(
      executable: admitted.executableURL,
      arguments: [
        "windows-worker", "--directory", missingVM.path, "--run-directory", run.path,
        "--endpoint-directory", root.appendingPathComponent("NoEndpoints").path,
      ], directory: root, runDirectory: run)
    try await parent.launch()
    let result = await parent.waitForTermination()
    #expect(
      result.reaped && result.descriptorsClosed && result.exitStatus == 1 && !result.signalled)
    let errors = try String(
      contentsOf: run.appendingPathComponent("parent-stderr.log"), encoding: .utf8)
    // The pinned worker reaches readConfiguration only after session separation;
    // its shared private-directory reader currently uses this failure message.
    #expect(errors.contains("reviewed external Windows continuation could not be confirmed"))
    #expect(!errors.contains("could not separate its terminal session"))
    #expect(!FileManager.default.fileExists(atPath: missingVM.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: run.path).sorted()
        == ["parent-stderr.log", "parent-stdout.log"])
    if result.reaped && result.descriptorsClosed { try FileManager.default.removeItem(at: root) }
  }
}
