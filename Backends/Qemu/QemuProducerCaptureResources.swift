// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// Closed root-adopted tools carrier. No public initializer, decoded metadata,
/// picked path/hash, arbitrary guest command, installer or media mutation.
public struct ReviewedQemuCaptureTools: Equatable, Sendable {
  public let image: ReviewedQemuSupportImage

  private init(image: ReviewedQemuSupportImage) { self.image = image }

  package static func nativePresenterR4(projectRoot: URL) throws -> Self {
    Self(
      image: try ReviewedQemuSupportImage(
        url: projectRoot.appendingPathComponent(
          ".lab/manager-iteration-20261016/root-native-d3d11-presenter-r4-carrier1/macopenvm-native-d3d11-presenter.iso"
        ),
        byteCount: 921_600,
        sha256: "5ebea3828ff3797375547f05bec5e25bb7897289b37997c1ccd169c67ebf22aa"))
  }

  func requireCaptureRuntime(_ runtime: ReviewedQemuResource) throws {
    guard runtime.role == .qemu, runtime.byteCount == 26_997_280,
      runtime.sha256 == "3975e5d2199bafb5ee82b40e5d79507a0a4b7adbdee7b570f2b06be0e492ed0e"
    else { throw registeredQemuFailure() }
  }
}

extension QemuRegisteredCatalog {
  /// Explicit package-only signed producer-capture evaluation, never a default.
  /// This selects pinned descriptors only; verify() must still admit the actual
  /// files/imports/providers and Security predicate. No capture or VM is started.
  package static func producerCaptureEvaluation(
    for configuration: VMConfiguration, projectRoot: URL
  ) throws -> ReviewedQemuLaunchResources {
    let original = try acceleratedDisplayEvaluation(for: configuration, projectRoot: projectRoot)
    return try ReviewedQemuLaunchResources(
      creation: original.creation, libraries: original.libraries,
      qemuImports: original.qemuImports, swtpmImports: original.swtpmImports,
      systemImports: original.systemImports,
      runtimeQemu: ReviewedQemuResource(
        role: .qemu,
        url: projectRoot.appendingPathComponent(
          ".lab/unified-graphics-20261018/runtimes/capture/qemu-system-aarch64"
        ),
        byteCount: 26_997_280,
        sha256: "3975e5d2199bafb5ee82b40e5d79507a0a4b7adbdee7b570f2b06be0e492ed0e"),
      supportsShared: original.supportsShared,
      supportImage: original.supportImage,
      agentChannel: original.agentChannel,
      displayEvaluation: original.displayEvaluation,
      acceleratedDisplay: original.acceleratedDisplay,
      renderServer: original.renderServer,
      keyboardMap: original.keyboardMap,
      sharedFrameTransport: original.sharedFrameTransport,
      audioOutput: original.audioOutput,
      extraReadOnlyTools: .nativePresenterR4(projectRoot: projectRoot))
  }
}
