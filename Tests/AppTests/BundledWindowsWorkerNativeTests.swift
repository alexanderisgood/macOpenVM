// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMApp

/// Read-only native signature qualification of the explicitly pinned private
/// build. A snapshot cannot authorize launch or mint the runtime's reviewed value.
@Suite struct BundledWindowsWorkerNativeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_BUNDLE_CHECK"] == "1",
      "Requires explicit MACOPENVM_NATIVE_BUNDLE_CHECK=1 and the pinned private build; no app or VM launch."
    )
  )
  func actualSealedDevelopmentBundleMatchesNativeRequirements() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let app = root.appendingPathComponent(
      ".lab/linux-desktop-artifacts-7376314220144fa8b3785b176dcc800a/macOpenVM.app",
      isDirectory: true)
    let identifier = "local.macOpenVM.linuxTrial.7376314220144fa8b3785b176dcc800a"
    let executable = app.appendingPathComponent("Contents/MacOS/macOpenVMNative")
    let first = try BundledWindowsWorkerAdmission.inspect(
      bundleURL: app, mainExecutableURL: executable, bundleIdentifier: identifier,
      signature: BundledWindowsWorkerAdmission.nativeSignature)
    let second = try BundledWindowsWorkerAdmission.inspect(
      bundleURL: app, mainExecutableURL: executable, bundleIdentifier: identifier,
      signature: BundledWindowsWorkerAdmission.nativeSignature)
    #expect(first == second)
    #expect(first.identifier == identifier + ".worker")
    #expect(first.executableURL == app.appendingPathComponent("Contents/MacOS/macopenvm-worker"))
    #expect(first.byteCount == 10_513_728)
    #expect(first.sha256 == "02c2f4cd511557c7d97455537574351364aa75f1dafa6d2441748afa6c553f49")
    #expect(throws: VMError.self) {
      try BundledWindowsWorkerAdmission.nativeSignature(
        first.executableURL, identifier: "local.macOpenVM.wrong-worker", worker: true)
    }
  }
}
