// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu
import Testing
import VMCore
import VMStorage

@testable import MacOpenVMApp

@Suite struct RegisteredWindowsAppQualificationTests {
  @Test func installedOptInRequiresSeparateFlagAndExplicitSharedNetworkAuthorization() throws {
    let arguments = [
      "app", RegisteredWindowsAppQualificationRequest.installedFlag, "--run",
      "--shared-network-authorized", "--directory",
      RegisteredWindowsAppQualificationRequest.installedVMPath, "--control-socket",
      "/private/tmp/mvo-appqual-0011223344556677/control.sock",
    ]
    let environment = ["MVO_REGISTERED_APP_QUALIFICATION": "1"]
    let value = try #require(
      try RegisteredWindowsAppQualificationRequest.parse(
        arguments: arguments, environment: environment)
    )
    #expect(value.mode == .installed)
    #expect(value.expectedVMID == RegisteredWindowsAppQualificationRequest.installedVMID)
    #expect(value.expectedVMPath == RegisteredWindowsAppQualificationRequest.installedVMPath)
    for invalid in [
      arguments.filter { $0 != "--shared-network-authorized" },
      arguments + [RegisteredWindowsAppQualificationRequest.flag],
      arguments.map { $0 == "--shared-network-authorized" ? "--network-observed" : $0 },
      arguments.map {
        $0 == RegisteredWindowsAppQualificationRequest.installedVMPath
          ? RegisteredWindowsAppQualificationRequest.vmPath : $0
      },
    ] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsAppQualificationRequest.parse(
          arguments: invalid, environment: environment)
      }
    }
    #expect(throws: VMError.self) {
      try RegisteredWindowsAppQualificationRequest.parse(arguments: arguments, environment: [:])
    }
  }

  @Test func installedAdmissionRejectsWrongBaselineReceiptOrPlatformShape() throws {
    var original = VMConfiguration(
      name: "Synthetic installed baseline", guest: .windows11, backend: .qemuHVF,
      diskBytes: 64 * 1_073_741_824,
      id: RegisteredWindowsAppQualificationRequest.installedVMID)
    original.network = .shared
    let prior = RegisteredWindowsAppQualificationRequest.priorInstalledSession
    let stopped = RuntimeSnapshot(
      state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped)
    func validate(_ fault: String? = nil) throws {
      var configuration = original
      switch fault {
      case "vm": configuration.id = RegisteredWindowsAppQualificationRequest.vmID
      case "network": configuration.network = .disconnected
      case "backend": configuration.backend = .appleVz
      case "architecture": configuration.architecture = .x8664
      case "boot": configuration.boot = .linuxKernel
      case "installation": configuration.installationMedia = "/private/tmp/public.iso"
      case "support": configuration.supportMedia = "/private/tmp/public.iso"
      default: break
      }
      let snapshot: RuntimeSnapshot
      switch fault {
      case "force":
        snapshot = .init(
          state: .stopped, operation: nil, backendActive: false, outcome: .forcedStopped)
      case "active":
        snapshot = .init(
          state: .stopped, operation: nil, backendActive: true, outcome: .guestStopped)
      case "operation":
        snapshot = .init(
          state: .stopped, operation: .stop, backendActive: false, outcome: .guestStopped)
      default: snapshot = stopped
      }
      let history = RuntimeRecord(
        sessionID: fault == "prior-session" ? UUID() : prior, sequence: 1, recordedAt: 0,
        snapshot: snapshot)
      try RegisteredInstalledAppQualificationAdmission.validate(
        configuration: configuration,
        configurationSHA256: fault == "digest"
          ? String(repeating: "0", count: 64)
          : RegisteredWindowsAppQualificationRequest.installedConfigurationSHA256,
        history: history,
        intentVMID: fault == "intent-vm" ? UUID() : original.id,
        intentSessionID: fault == "intent-session" ? UUID() : prior,
        intentState: fault == "unsettled" ? .unsettled : .settled,
        diskBytes: fault == "disk" ? 0 : Int64(original.diskBytes),
        variablesBytes: fault == "empty-vars" ? 0 : fault == "oversized-vars" ? 1_048_577 : 9975,
        tpmMembers: fault == "empty-tpm"
          ? []
          : fault == "unknown-tpm"
            ? [".lock", "other"]
            : [".lock", "tpm2-00.permall"])
    }
    // The supplied digest is a pure guard fixture; actual inspect hashes the
    // bounded configuration bytes under the actual writer before inspecting assets.
    try validate()
    for fault in [
      "vm", "digest", "network", "backend", "architecture", "boot", "installation", "support",
      "prior-session", "force", "active", "operation", "intent-vm", "intent-session", "unsettled",
      "disk", "empty-vars", "oversized-vars", "empty-tpm", "unknown-tpm",
    ] {
      #expect(throws: VMError.self) { try validate(fault) }
    }
  }

  @Test func ordinarySharedSaveMustBeNoopWithExactBaselinePermission() throws {
    var original = VMConfiguration(
      name: "Synthetic shared baseline", guest: .windows11, backend: .qemuHVF,
      id: RegisteredWindowsAppQualificationRequest.installedVMID)
    original.network = .shared
    // This package-only value tests stale admission, not native verification.
    let permission = SharedNetworkConfigurationPermission(configuration: original)
    try RegisteredAppQualificationAuthorization.sharedNetworkNoop(
      original: original, selected: original, permission: permission)
    for fault in [
      "missing-permission", "foreign-permission", "identity", "cpu", "network", "support",
    ] {
      var selected = original
      if fault == "identity" { selected.id = UUID() }
      if fault == "cpu" { selected.cpuCount += 1 }
      if fault == "network" { selected.network = .disconnected }
      if fault == "support" { selected.supportMedia = "/private/tmp/unreviewed.iso" }
      let foreign = SharedNetworkConfigurationPermission(
        configuration: VMConfiguration(name: "Other", guest: .windows11, backend: .qemuHVF))
      #expect(throws: VMError.self) {
        try RegisteredAppQualificationAuthorization.sharedNetworkNoop(
          original: original, selected: selected,
          permission: fault == "missing-permission"
            ? nil : fault == "foreign-permission" ? foreign : permission)
      }
    }
  }

  @Test func installedRuntimeControlsAllowOnlyNormalStopAndCurrentInstalledIdentity() {
    #expect(RegisteredAppQualificationAuthorization.allowsRuntimeAction(.stop, mode: .installed))
    for action in [RegisteredAppQualificationControl.Action.status, .forceStop, .quit] {
      #expect(
        !RegisteredAppQualificationAuthorization.allowsRuntimeAction(action, mode: .installed))
    }
    #expect(RegisteredAppQualificationAuthorization.allowsRuntimeAction(.forceStop, mode: .fresh))
    #expect(!RegisteredAppQualificationAuthorization.allowsRuntimeAction(.stop, mode: .fresh))
    let nonce = UUID()
    let session = UUID()
    let generation = UUID()
    func request(vm: UUID, id: UInt64 = 2, sid: UUID? = nil)
      -> RegisteredAppQualificationControl.Request
    {
      .init(
        requestID: id, nonce: nonce, vmID: vm, sessionID: sid ?? session,
        launchGeneration: generation, action: .stop)
    }
    let vm = RegisteredWindowsAppQualificationRequest.installedVMID
    #expect(
      RegisteredAppQualificationAuthorization.mutationMatches(
        request(vm: vm), nonce: nonce, lastRequest: 1, sessionID: session, generation: generation,
        vmID: vm))
    for invalid in [
      request(vm: RegisteredWindowsAppQualificationRequest.vmID), request(vm: vm, id: 1),
      request(vm: vm, sid: UUID()),
    ] {
      #expect(
        !RegisteredAppQualificationAuthorization.mutationMatches(
          invalid, nonce: nonce, lastRequest: 1, sessionID: session, generation: generation,
          vmID: vm))
    }
  }

  @Test func driverDiscQualificationAllowsOnlyIndependentlyReviewedSupportField() throws {
    var original = VMConfiguration(
      name: "Fresh Windows", guest: .windows11, backend: .qemuHVF,
      cpuCount: 2, memoryBytes: 4 * 1_073_741_824, diskBytes: 64 * 1_073_741_824)
    original.id = RegisteredWindowsAppQualificationRequest.vmID
    original.installationMedia = "/private/tmp/windows.iso"
    let image = try QemuRegisteredCatalog.networkDriverSupportImage(
      projectRoot: URL(fileURLWithPath: "/private/fixture-source"))
    var selected = original
    selected.supportMedia = image.url.path
    try RegisteredAppQualificationAuthorization.driverDiscSelection(
      original: original, selected: selected, image: image)
    for field in ["identity", "name", "cpu", "network", "installation", "support", "nil-support"] {
      var changed = selected
      if field == "identity" { changed.id = UUID() }
      if field == "name" { changed.name = "Unexpected rename" }
      if field == "cpu" { changed.cpuCount += 1 }
      if field == "network" { changed.network = .shared }
      if field == "installation" { changed.installationMedia = nil }
      if field == "support" { changed.supportMedia = "/private/tmp/unreviewed.iso" }
      if field == "nil-support" { changed.supportMedia = nil }
      #expect(throws: VMError.self) {
        try RegisteredAppQualificationAuthorization.driverDiscSelection(
          original: original, selected: changed, image: image)
      }
    }
  }
  @Test func failedQualificationCannotBecomeReadyAfterLateRenderCallback() {
    #expect(
      RegisteredAppQualificationAuthorization.displayReady(
        attached: true, drawn: true, failed: false))
    #expect(
      !RegisteredAppQualificationAuthorization.displayReady(
        attached: true, drawn: true, failed: true))
    #expect(
      !RegisteredAppQualificationAuthorization.displayReady(
        attached: false, drawn: true, failed: false))
    #expect(
      !RegisteredAppQualificationAuthorization.displayReady(
        attached: true, drawn: false, failed: false))
  }
  private var arguments: [String] {
    [
      "app", RegisteredWindowsAppQualificationRequest.flag, "--run",
      "--directory", RegisteredWindowsAppQualificationRequest.vmPath, "--control-socket",
      "/private/tmp/mvo-appqual-0011223344556677/control.sock",
    ]
  }
  @Test func optInRequiresExactRunEnvironmentAndFreshFixedSelectionBeforeIO() throws {
    #expect(
      try RegisteredWindowsAppQualificationRequest.parse(arguments: ["app"], environment: [:])
        == nil)
    #expect(
      try RegisteredWindowsAppQualificationRequest.parse(
        arguments: arguments,
        environment: ["MVO_REGISTERED_APP_QUALIFICATION": "1"])?.outputDirectory.path
        == "/private/tmp/mvo-appqual-0011223344556677")
    for variant in [
      Array(arguments.dropLast()), arguments + ["--windows-installer-display-lab"],
      arguments.map { $0 == "--run" ? "--observe" : $0 },
      arguments.map {
        $0 == RegisteredWindowsAppQualificationRequest.vmPath ? "/private/tmp/other.macopenvm" : $0
      },
      arguments.map { $0.hasSuffix("control.sock") ? "/private/tmp/../control.sock" : $0 },
    ] {
      #expect(throws: VMError.self) {
        try RegisteredWindowsAppQualificationRequest.parse(
          arguments: variant,
          environment: ["MVO_REGISTERED_APP_QUALIFICATION": "1"])
      }
    }
    #expect(throws: VMError.self) {
      try RegisteredWindowsAppQualificationRequest.parse(arguments: arguments, environment: [:])
    }
  }
  @Test func freshnessRejectsHistoryAllocatedDiskVarsTPMOrForeignIdentity() throws {
    var c = VMConfiguration(
      name: "Qualification", guest: .windows11, backend: .qemuHVF, cpuCount: 2,
      memoryBytes: 4 * 1_073_741_824, diskBytes: 64 * 1_073_741_824)
    c.id = RegisteredWindowsAppQualificationRequest.vmID
    c.installationMedia = "/private/tmp/image.iso"
    let names: Set<String> = [
      "configuration.json", "writer.lock", c.diskFile, "qemu-platform.json", "uefi-vars.json",
      "tpm-state",
    ]
    try RegisteredAppQualificationFreshness.validate(
      configuration: c, names: names, diskBytes: Int64(c.diskBytes), diskBlocks: 0,
      variablesBytes: 0, tpmMembers: [])
    for kind in [
      "identity", "network", "history", "intent", "allocated", "disk-size", "vars", "tpm",
    ] {
      var altered = c
      var present = names
      if kind == "identity" { altered.id = UUID() }
      if kind == "network" { altered.network = .shared }
      if kind == "history" { present.insert("runtime.json") }
      if kind == "intent" { present.insert("runtime-intent.json") }
      #expect(throws: VMError.self) {
        try RegisteredAppQualificationFreshness.validate(
          configuration: altered, names: present,
          diskBytes: kind == "disk-size" ? 0 : Int64(c.diskBytes),
          diskBlocks: kind == "allocated" ? 1 : 0,
          variablesBytes: kind == "vars" ? 1 : 0,
          tpmMembers: kind == "tpm" ? ["tpm2-00.permall"] : [])
      }
    }
  }
  @Test func explicitMutationBindsMemoryNonceCurrentSessionGenerationAndFreshRequest() {
    let nonce = UUID()
    let sid = UUID()
    let generation = UUID()
    func request(
      id: UInt64 = 2, nonceValue: UUID? = nil, vm: UUID? = nil, session: UUID? = nil,
      gen: UUID? = nil
    ) -> RegisteredAppQualificationControl.Request {
      .init(
        requestID: id, nonce: nonceValue ?? nonce,
        vmID: vm ?? RegisteredWindowsAppQualificationRequest.vmID,
        sessionID: session ?? sid, launchGeneration: gen ?? generation, action: .forceStop)
    }
    #expect(
      RegisteredAppQualificationAuthorization.mutationMatches(
        request(), nonce: nonce, lastRequest: 1, sessionID: sid, generation: generation))
    for invalid in [
      request(id: 1), request(nonceValue: UUID()), request(vm: UUID()), request(session: UUID()),
      request(gen: UUID()),
    ] {
      #expect(
        !RegisteredAppQualificationAuthorization.mutationMatches(
          invalid, nonce: nonce, lastRequest: 1, sessionID: sid, generation: generation))
    }
  }
  @Test func preOwnerQuitRequiresExplicitCurrentChallengeAndAbsenceOfCustody() {
    let nonce = UUID()
    let quit = RegisteredAppQualificationControl.Request(
      requestID: 1, nonce: nonce,
      vmID: RegisteredWindowsAppQualificationRequest.vmID, sessionID: nil, launchGeneration: nil,
      action: .quit)
    #expect(
      RegisteredAppQualificationAuthorization.preOwnerQuit(
        quit, nonce: nonce, lastRequest: 0, hasRuntime: false, busy: false))
    #expect(
      !RegisteredAppQualificationAuthorization.preOwnerQuit(
        quit, nonce: UUID(), lastRequest: 0, hasRuntime: false, busy: false))
    #expect(
      !RegisteredAppQualificationAuthorization.preOwnerQuit(
        quit, nonce: nonce, lastRequest: 1, hasRuntime: false, busy: false))
    #expect(
      !RegisteredAppQualificationAuthorization.preOwnerQuit(
        quit, nonce: nonce, lastRequest: 0, hasRuntime: true, busy: false))
    #expect(
      !RegisteredAppQualificationAuthorization.preOwnerQuit(
        quit, nonce: nonce, lastRequest: 0, hasRuntime: false, busy: true))
  }
}
