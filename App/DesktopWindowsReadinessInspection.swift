// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu

/// Only the ordinary verified factory can construct a result containing a worker.
/// A controlled inspector can report unavailability, never .ready/.checking or authority.
struct DesktopWindowsReadinessInspection: Sendable {
  let worker: ReviewedBundledWindowsWorker?
  let readiness: WindowsLaunchReadiness

  private init(worker: ReviewedBundledWindowsWorker?, readiness: WindowsLaunchReadiness) {
    self.worker = worker
    self.readiness = readiness
  }

  static func unavailable(_ reason: WindowsLaunchReadiness.Reason)
    -> DesktopWindowsReadinessInspection
  {
    DesktopWindowsReadinessInspection(worker: nil, readiness: .unavailable(reason))
  }

  fileprivate static func inspectOrdinary(_ request: WindowsLaunchReadinessRequest)
    -> DesktopWindowsReadinessInspection
  {
    func unavailable(_ reason: WindowsLaunchReadiness.Reason)
      -> DesktopWindowsReadinessInspection
    { .unavailable(reason) }
    guard
      WindowsLaunchReadiness.supportsHost(
        architecture: HostResources.current.architecture,
        majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    else { return unavailable(.unsupportedHost) }
    let worker: ReviewedBundledWindowsWorker
    do { worker = try BundledWindowsWorkerAdmission.current() } catch {
      return unavailable(.bundledWorkerUnavailable)
    }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    func catalog(_ configuration: VMConfiguration) throws -> ReviewedQemuLaunchResources {
      switch request.profile {
      case .basic:
        try QemuRegisteredCatalog.registeredEvaluation(for: configuration, projectRoot: project)
      case .twoDimensional:
        try QemuRegisteredCatalog.twoDimensionalDisplayEvaluation(
          for: configuration, projectRoot: project)
      case .accelerated:
        try QemuRegisteredCatalog.acceleratedDisplayEvaluation(
          for: configuration, projectRoot: project)
      case .producerCapture:
        try QemuRegisteredCatalog.producerCaptureEvaluation(
          for: configuration, projectRoot: project)
      }
    }
    var base = request.configuration
    base.supportMedia = nil
    var resources: ReviewedQemuLaunchResources
    do { resources = try catalog(base) } catch { return unavailable(.reviewedRuntimeUnavailable) }
    if request.configuration.supportMedia != nil {
      do {
        resources = try catalog(request.configuration)
        try resources.supportImage?.verify()
      } catch { return unavailable(.incompatibleSupportDisc) }
    }
    guard request.configuration.network != .shared || resources.supportsShared else {
      return unavailable(.sharedRuntimeUnavailable)
    }
    do { try resources.verify() } catch { return unavailable(.reviewedRuntimeUnavailable) }
    return DesktopWindowsReadinessInspection(worker: worker, readiness: .ready)
  }

}

@MainActor protocol DesktopWindowsReadinessInspecting {
  func inspect(_ request: WindowsLaunchReadinessRequest) async -> DesktopWindowsReadinessInspection
}

struct NativeDesktopWindowsReadinessInspection: DesktopWindowsReadinessInspecting {
  func inspect(_ request: WindowsLaunchReadinessRequest) async -> DesktopWindowsReadinessInspection
  {
    await Task.detached(priority: .utility) {
      DesktopWindowsReadinessInspection.inspectOrdinary(request)
    }.value
  }
}
