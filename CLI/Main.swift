// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import AppKit
import AppleVz
import BackendAPI
import Darwin
import Foundation
import Qemu
import VMCore
import VMStorage

@main struct MacOpenVMCLI {
  @MainActor static func main() async {
    do { try await run(Array(CommandLine.arguments.dropFirst())) } catch {
      let message =
        (error as? VMError)?.errorDescription
        ?? (error as? NativeAgentTLSError)?.errorDescription
        ?? "Operation failed. Inspect prerequisites and preserved local VM files."
      FileHandle.standardError.write(Data(("macOpenVM: \(message)\n").utf8))
      exit(1)
    }
  }

  @MainActor private static func run(_ arguments: [String]) async throws {
    guard let command = arguments.first else {
      print(usage)
      return
    }
    if command == "help" || command == "--help" {
      print(usage)
      return
    }
    let options = try parse(Array(arguments.dropFirst()))
    try validateOptions(options, command: command)
    switch command {
    case "inspect-interrupted-windows", "recover-interrupted-windows":
      try await InterruptedWindowsCLI.run(command: command, options: options)
    case "probe": try output(HostProbe.capture())
    case "storage-capacity":
      let destination = try directory(options)
      let available = try await Task.detached(priority: .utility) {
        try await VMFiles().availableStorageCapacity(at: destination)
      }.value
      try output(StorageCapacityCLIObservation(availableBytes: available))
    case "windows-readiness": try QemuPlan.windowsReadiness()
    case "verify-agent-package-lab":
      guard let issuer = options["issuer"] else {
        throw bad("Provide the independently approved issuer fingerprint.")
      }
      try output(
        await AgentPackageLab.verify(directory: directory(options), approvedIssuer: issuer))
    case "agent-tls-lab":
      guard let path = options["socket"], let credentials = options["credentials"],
        let rawID = options["vm-id"], let vmID = UUID(uuidString: rawID)
      else {
        throw bad("Provide a private socket, transient credentials folder and test VM identity.")
      }
      try output(
        await AgentTLSLab.run(socketPath: path, credentialDirectory: credentials, vmID: vmID))
    case "agent-keychain-public-roundtrip-lab":
      guard let action = options["action"], let marker = options["public-fixture"],
        let service = options["service-id"].flatMap(UUID.init(uuidString:)),
        let vm = options["vm-id"].flatMap(UUID.init(uuidString:)),
        let enrollment = options["enrollment-id"].flatMap(UUID.init(uuidString:))
      else { throw bad("Provide the public-fixture marker, action and three isolated test UUIDs.") }
      let result = try await AgentKeychainRoundtripLab.run(
        action: action, serviceID: service, vmID: vm, enrollmentID: enrollment,
        publicFixture: marker)
      try output(result)
      if !result.exactPublicFixtureVerified { Foundation.exit(2) }
    case "agent-keychain-read-probe-lab":
      guard let rawService = options["service-id"], let serviceID = UUID(uuidString: rawService),
        let rawVM = options["vm-id"], let vmID = UUID(uuidString: rawVM)
      else { throw bad("Provide two fresh isolated service and VM UUIDs for the read-only probe.") }
      try output(await AgentKeychainProbeLab.run(serviceID: serviceID, vmID: vmID))
    case "move-to-trash", "check-trash-admission":
      guard let vmID = options["vm-id"].flatMap(UUID.init(uuidString:)) else {
        throw bad("Provide the exact VM UUID for Trash admission.")
      }
      if command == "move-to-trash", options["confirm-move-to-trash"] != "yes" {
        throw bad(
          "Confirm the recoverable move with --confirm-move-to-trash yes and the exact VM UUID.")
      }
      let folder = try directory(options)
      let configuration = try StrictConfigurationDocument(
        await VMFiles().readMetadata(
          at: folder.appendingPathComponent("configuration.json"),
          limit: ConfigurationCodec.maximumBytes)
      ).configuration
      guard configuration.id == vmID else {
        throw bad("A different VM occupies the selected folder.")
      }
      let ticket = try await VMTrash().prepare(in: folder, expected: configuration)
      if command == "check-trash-admission" {
        await ticket.cancel()
        try output(
          TrashCLIObservation(
            vmID: vmID, status: "eligibleAtCheck", trashLocation: nil,
            cancellationObserved: false, readOnly: true))
        return
      }
      let moved = try await ticket.commit()
      let status: String
      switch moved.status {
      case .moved: status = "moved"
      case .notMoved: status = "notMoved"
      case .relocationUnverified: status = "relocationUnverified"
      }
      try output(
        TrashCLIObservation(
          vmID: vmID, status: status, trashLocation: moved.trashURL?.path,
          cancellationObserved: moved.cancellationObserved, readOnly: false))
      if moved.status != .moved { Foundation.exit(2) }
    case "export-diagnostics":
      guard let target = options["output"], target.hasPrefix("/"), !target.contains("\0") else {
        throw bad("Choose a new absolute file for the support report.")
      }
      let source = try options["directory"].map { _ in try directory(options) }
      let probe = HostProbe.capture()
      let host = DiagnosticHostFacts(
        virtualizationSupported: probe.virtualizationSupported,
        virtualizationEntitled: probe.virtualizationEntitled)
      let report = await SupportDiagnostics.make(directory: source, host: host)
      try await SupportDiagnostics.export(report, to: URL(fileURLWithPath: target))
      print("Support report saved. Review it before sharing.")
    case "qemu-lab": try await QemuLabRuntime.run(directory: directory(options))
    case "qemu-worker-lab": try await QemuWorkerLab.run(directory: directory(options))
    case "qemu-display-worker-lab":
      try await QemuWorkerLab.run(directory: directory(options), profile: .display)
    case "qemu-windows-installer-worker-lab":
      try await QemuWorkerLab.run(directory: directory(options), profile: .windowsInstaller)
    case "qemu-windows-installation-worker-lab":
      try await QemuWorkerLab.run(
        directory: directory(options), profile: .windowsInstaller, installationAuthorized: true)
    case "qemu-windows-network-continuation-worker-lab":
      let required = ["plan", "approval", "terminal", "shutdown-record", "run-directory"]
      guard required.allSatisfy({ options[$0]?.hasPrefix("/") == true }) else {
        throw bad(
          "Provide the reviewed continuation plan, prior terminal evidence and a new private run folder."
        )
      }
      try await QemuWorkerLab.runWindowsNetworkContinuation(
        directory: directory(options), planURL: URL(fileURLWithPath: options["plan", default: ""]),
        approvalURL: URL(fileURLWithPath: options["approval", default: ""]),
        terminalURL: URL(fileURLWithPath: options["terminal", default: ""]),
        shutdownURL: URL(fileURLWithPath: options["shutdown-record", default: ""]),
        runDirectory: URL(fileURLWithPath: options["run-directory", default: ""]))
    case "qemu-windows-external-continuation-worker-lab":
      guard let record = options["record"], record.hasPrefix("/"),
        let digest = options["record-sha256"],
        digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        let run = options["run-directory"], run.hasPrefix("/")
      else {
        throw bad("Provide the reviewed external-storage record, its digest and a new run folder.")
      }
      try await QemuWorkerLab.runWindowsExternalContinuation(
        directory: directory(options), recordURL: URL(fileURLWithPath: record),
        recordSHA256: digest, runDirectory: URL(fileURLWithPath: run))
    case "qemu-windows-external-input-lab":
      guard let action = options["action"] else {
        throw bad("Choose a reviewed guest setup action.")
      }
      for field in ["x", "y"] {
        if let value = options[field], Int(value) == nil {
          throw bad("Guest pointer coordinates require integer values.")
        }
      }
      try await WindowsExternalInputLab.run(
        action: action, expectedFrame: options["expected-frame"],
        x: options["x"].flatMap(Int.init), y: options["y"].flatMap(Int.init), key: options["key"])
    case "registered-windows-agent-probe-lab":
      guard options["agent-channel"] == "fixed-transfer-evaluation",
        let run = options["run-directory"], run.hasPrefix("/"),
        let raw = options["expected-session"], let session = UUID(uuidString: raw)
      else { throw bad("Explicitly select the fixed transport fixture and exact current session.") }
      let request = try RegisteredWindowsControl.Request(
        action: .status, directory: directory(options),
        runDirectory: URL(fileURLWithPath: run), expectedSession: session)
      let result = try await RegisteredWindowsAgentProbeLab.run(request: request)
      try output(result)
      if !result.completed { Foundation.exit(2) }
    case "windows-agent-worker-lab":
      guard options["agent-channel"] == "fixed-transfer-evaluation",
        let run = options["run-directory"], run.hasPrefix("/"),
        let endpoint = options["endpoint-directory"], endpoint.hasPrefix("/")
      else {
        throw bad("Explicitly select the fixed agent transport evaluation and new private folders.")
      }
      try await RegisteredWindowsWorker.run(
        directory: directory(options), runDirectory: URL(fileURLWithPath: run),
        endpointDirectory: URL(fileURLWithPath: endpoint), agentChannel: .virtioSerialV1)
    case "windows-gpu-worker-lab", "windows-producer-capture-worker-lab":
      if command == "windows-producer-capture-worker-lab" {
        try RegisteredWindowsCaptureLab.requireProfile(options["capture-profile"])
      }
      guard options["display-profile"] == "neptune-metal-evaluation",
        let hostWindow = ReviewedQemuAcceleratedDisplay.HostWindow(
          rawValue: options["gpu-host-window"] ?? "1G"),
        let refresh = ReviewedQemuAcceleratedDisplay.RefreshRate(
          rawValue: options["gpu-refresh-millihertz"] ?? "60000"),
        let width = options["display-width"].flatMap(Int.init),
        let height = options["display-height"].flatMap(Int.init),
        let run = options["run-directory"], run.hasPrefix("/"),
        let endpoint = options["endpoint-directory"], endpoint.hasPrefix("/")
      else { throw bad("Select the reviewed GPU evaluation and bounded native pixels.") }
      let display = try ReviewedQemuAcceleratedDisplay(
        initialPixels: PixelSize(width: width, height: height), separateFirmware: true,
        hostWindow: hostWindow, refreshRate: refresh)
      try await RegisteredWindowsWorker.run(
        directory: directory(options), runDirectory: URL(fileURLWithPath: run),
        endpointDirectory: URL(fileURLWithPath: endpoint), acceleratedDisplay: display,
        producerCapture: command == "windows-producer-capture-worker-lab" ? .boundedProducerV1 : nil
      )
    case "registered-windows-producer-capture-lab":
      try RegisteredWindowsCaptureLab.requireProfile(options["capture-profile"])
      guard let run = options["run-directory"], run.hasPrefix("/"),
        let rawSession = options["expected-session"], let session = UUID(uuidString: rawSession),
        let rawEpoch = options["expected-monitor-epoch"], let epoch = UUID(uuidString: rawEpoch),
        let rawCapture = options["capture-id"], let capture = UInt64(rawCapture),
        String(capture) == rawCapture
      else {
        throw bad(
          "Select the explicit capture profile, current session/monitor and numeric capture ID.")
      }
      let request = try RegisteredWindowsControl.Request(
        action: .status,
        directory: directory(options), runDirectory: URL(fileURLWithPath: run),
        expectedSession: session)
      let result = try await RegisteredWindowsCaptureLab.run(
        request: request,
        monitorEpoch: epoch, capture: capture,
        milliseconds: integer(options, "milliseconds", fallback: 250))
      try output(result)
      if !result.completed { exit(2) }
    case "windows-display-worker-lab":
      guard options["display-profile"] == "virtio-gpu-2d-evaluation",
        let width = options["display-width"].flatMap(Int.init),
        let height = options["display-height"].flatMap(Int.init),
        let run = options["run-directory"], run.hasPrefix("/"),
        let endpoint = options["endpoint-directory"], endpoint.hasPrefix("/")
      else {
        throw bad("Select the explicit 2D evaluation, bounded pixels and new private folders.")
      }
      let display = try ReviewedQemu2DDisplay(
        initialPixels: PixelSize(width: width, height: height))
      try await RegisteredWindowsWorker.run(
        directory: directory(options), runDirectory: URL(fileURLWithPath: run),
        endpointDirectory: URL(fileURLWithPath: endpoint), displayEvaluation: display)
    case "windows-worker":
      guard let run = options["run-directory"], run.hasPrefix("/"),
        let endpoint = options["endpoint-directory"], endpoint.hasPrefix("/")
      else { throw bad("Provide a new private runtime record folder and endpoint folder.") }
      try await RegisteredWindowsWorker.run(
        directory: directory(options), runDirectory: URL(fileURLWithPath: run),
        endpointDirectory: URL(fileURLWithPath: endpoint))
    case "status", "pause", "resume", "stop", "force-stop":
      guard let action = RegisteredWindowsControl.Action(rawValue: command),
        let run = options["run-directory"], run.hasPrefix("/"),
        let rawSession = options["expected-session"], let session = UUID(uuidString: rawSession)
      else {
        throw bad("Provide the existing runtime folder and expected current session.")
      }
      if command == "force-stop", options["confirm-data-loss"] != "yes" {
        throw bad("Force Stop may lose unsaved guest data. Confirm with --confirm-data-loss yes.")
      }
      let request = try RegisteredWindowsControl.Request(
        action: action, directory: directory(options),
        runDirectory: URL(fileURLWithPath: run, isDirectory: true), expectedSession: session,
        confirmDataLoss: options["confirm-data-loss"])
      let result = try await RegisteredWindowsControl.run(request)
      try output(result)
      if action != .status, !result.requestAcknowledged { exit(2) }
    case "registered-windows-observe-lab":
      guard let run = options["run-directory"], run.hasPrefix("/"),
        let raw = options["expected-session"], let session = UUID(uuidString: raw),
        let count = options["frames"].flatMap(Int.init), (1...120).contains(count)
      else { throw bad("Provide the exact current runtime, session and 1 to 120 frames.") }
      let request = try RegisteredWindowsControl.Request(
        action: .status, directory: directory(options),
        runDirectory: URL(fileURLWithPath: run, isDirectory: true), expectedSession: session)
      let observation = try await RegisteredWindowsInputLab.observe(request: request, frames: count)
      try output(observation)
      if !observation.completed { Foundation.exit(2) }
    case "registered-windows-recovery-input-lab":
      guard let raw = options["action"],
        let action = RegisteredWindowsInputLab.RecoveryAction(rawValue: raw),
        let run = options["run-directory"], run.hasPrefix("/"),
        let rawSession = options["expected-session"], let session = UUID(uuidString: rawSession)
      else { throw bad("Select the exact active recovery session and closed navigation action.") }
      let request = try RegisteredWindowsControl.Request(
        action: .status, directory: directory(options),
        runDirectory: URL(fileURLWithPath: run), expectedSession: session)
      let targetFields = ["target-x", "target-y", "target-width", "target-height"]
      let region: RegisteredInputRegion?
      if targetFields.contains(where: { options[$0] != nil }) {
        guard action == .startCS2PerformanceSample || action == .readCS2PerformanceSample,
          let x = options["target-x"].flatMap(Int.init),
          let y = options["target-y"].flatMap(Int.init),
          let width = options["target-width"].flatMap(Int.init),
          let height = options["target-height"].flatMap(Int.init)
        else { throw bad("Only the fixed performance Run-dialog target accepts a region.") }
        region = try RegisteredInputRegion(x: x, y: y, width: width, height: height)
      } else {
        region = nil
      }
      let destination: PrivateSnapshotOutput?
      if action == .snapshot {
        guard let path = options["output"], path.hasPrefix("/"), path.hasSuffix(".ppm") else {
          throw bad("Use a new private output for recovery observation.")
        }
        destination = try await Task.detached {
          try PrivateSnapshotOutput(at: URL(fileURLWithPath: path))
        }.value
      } else {
        guard options["output"] == nil else { throw bad("Only observation accepts output.") }
        destination = nil
      }
      let result = try await RegisteredWindowsInputLab.run(
        request: request, action: raw,
        expectedFrame: options["expected-frame"], x: nil, y: nil, key: nil, recovery: action,
        region: region)
      if action == .liveView || action == .liveGPUView || action == .liveSeparateGPUView {
        guard let bytes = result.frameData else { throw bad("The live view returned no frame.") }
        try FileHandle.standardOutput.write(contentsOf: bytes)
        return
      }
      if let destination, let bytes = result.frameData {
        try await Task.detached { try destination.save(bytes) }.value
      }
      try output(result)
    case "registered-windows-input-lab":
      guard options["display-console"] == nil || options["display-console"] == "gpu" else {
        throw bad("The combined GPU evaluation uses one display console.")
      }
      guard let action = options["action"], let run = options["run-directory"], run.hasPrefix("/"),
        let rawSession = options["expected-session"], let session = UUID(uuidString: rawSession)
      else {
        throw bad("Provide the current registered VM, runtime, session and explicit input action.")
      }
      for field in ["x", "y"] {
        if let value = options[field], Int(value) == nil {
          throw bad("Guest coordinates require integers.")
        }
      }
      let destination: PrivateSnapshotOutput?
      if action == "snapshot" {
        guard let raw = options["output"], raw.hasPrefix("/"), raw.hasSuffix(".ppm") else {
          throw bad("Snapshot requires a new private .ppm output file.")
        }
        let url = URL(fileURLWithPath: raw)
        destination = try await Task.detached(priority: .utility) {
          try PrivateSnapshotOutput(at: url)
        }.value
      } else {
        guard options["output"] == nil else { throw bad("Only snapshot accepts an output file.") }
        destination = nil
      }
      let request = try RegisteredWindowsControl.Request(
        action: .status, directory: directory(options),
        runDirectory: URL(fileURLWithPath: run, isDirectory: true), expectedSession: session)
      let targetFields = ["target-x", "target-y", "target-width", "target-height"]
      let region: RegisteredInputRegion?
      if targetFields.contains(where: { options[$0] != nil }) {
        guard ["click", "key", "scrollDown"].contains(action),
          let tx = options["target-x"].flatMap(Int.init),
          let ty = options["target-y"].flatMap(Int.init),
          let tw = options["target-width"].flatMap(Int.init),
          let th = options["target-height"].flatMap(Int.init)
        else { throw bad("Select one complete bounded click target.") }
        region = try RegisteredInputRegion(x: tx, y: ty, width: tw, height: th)
      } else {
        region = nil
      }
      let result = try await RegisteredWindowsInputLab.run(
        request: request, action: action, expectedFrame: options["expected-frame"],
        x: options["x"].flatMap(Int.init), y: options["y"].flatMap(Int.init), key: options["key"],
        region: region, selectGPU: options["display-console"] == "gpu")
      if let destination {
        guard let data = result.frameData else { throw bad("The snapshot returned no frame.") }
        try await Task.detached(priority: .utility) { try destination.save(data) }.value
      }
      try output(result)
    case "qemu-windows-installer-observer-lab":
      try await RfbObserverLab.bootWindowsInstaller(directory: directory(options))
    case "qemu-windows-installation-control-lab":
      guard let action = options["action"] else { throw bad("Choose a guest installation action.") }
      for field in ["x", "y"] {
        if let value = options[field], Int(value) == nil {
          throw bad("Guest pointer coordinates require integer values.")
        }
      }
      try await RfbObserverLab.windowsInstallationControl(
        directory: directory(options), action: action,
        x: options["x"].flatMap(Int.init), y: options["y"].flatMap(Int.init), key: options["key"])
    case "qemu-windows-network-shutdown-input-lab":
      guard let action = options["action"], let approval = options["approval"],
        let frame = options["expected-frame"], approval.hasPrefix("/")
      else { throw bad("Choose an explicitly approved fixed shutdown input and reviewed frame.") }
      try await RfbObserverLab.windowsNetworkShutdownControl(
        directory: directory(options), approvalURL: URL(fileURLWithPath: approval),
        action: action, expectedFrame: frame)
    case "qemu-windows-network-continuation-control-lab":
      guard let action = options["action"], let run = options["run-directory"], run.hasPrefix("/")
      else {
        throw bad(
          "Choose a private continuation run and reviewed snapshot, click or navigation key.")
      }
      for field in ["x", "y"] {
        if let value = options[field], Int(value) == nil {
          throw bad("Guest coordinates require integers.")
        }
      }
      try await RfbObserverLab.windowsNetworkContinuationControl(
        directory: directory(options), runDirectory: URL(fileURLWithPath: run), action: action,
        expectedFrame: options["expected-frame"], x: options["x"].flatMap(Int.init),
        y: options["y"].flatMap(Int.init), key: options["key"])
    case "qemu-windows-installer-input-lab":
      guard let action = options["action"], let expected = options["expected-frame"] else {
        throw bad("Select a fixed installer input action and its reviewed frame hash.")
      }
      try await RfbObserverLab.windowsInstallerInput(
        directory: directory(options), action: action, expectedFrame: expected)
    case "qemu-nvme-lab":
      try await QemuNvmeLab.run(directory: directory(options))
    case "qemu-rfb-observer-lab":
      try await RfbObserverLab.run(directory: directory(options))
    case "qemu-survivor-worker-lab":
      guard let first = options["first-exit"], first == "qemu" || first == "tpm" else {
        throw bad("The diskless survivor worker requires --first-exit qemu or tpm.")
      }
      try await QemuSurvivorWorkerLab.run(directory: directory(options), firstExit: first)
    case "qemu-lease-lab":
      guard let first = options["first-exit"], first == "qemu" || first == "tpm" else {
        throw bad("The diskless lease test requires --first-exit qemu or tpm.")
      }
      try await QemuLabRuntime.runLease(directory: directory(options), firstExit: first)
    case "qemu-shutdown-lab":
      try await QemuShutdownLab.run(directory: directory(options))
    case "doctor":
      let report = await VMInspection().inspect(at: try directory(options))
      try output(report)
      if report.status != .filesMatchConfiguration { exit(2) }
    case "attach-media", "detach-media":
      let selected: URL?
      if command == "attach-media" {
        guard let path = options["media"], path.hasPrefix("/"), !path.contains("\0") else {
          throw bad("Attach requires an absolute --media installation-file path.")
        }
        selected = URL(fileURLWithPath: path)
      } else {
        selected = nil
      }
      let result = try await InstallationMedia().update(in: directory(options), to: selected)
      try output(result)
    case "attach-support-media", "detach-support-media":
      let selected: URL?
      if command == "attach-support-media" {
        guard let path = options["support-media"], path.hasPrefix("/"), path.utf8.count <= 4096,
          !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw bad("Attach requires a bounded absolute --support-media image path.") }
        selected = URL(fileURLWithPath: path)
      } else {
        selected = nil
      }
      try output(await InstallationMedia().updateSupport(in: directory(options), to: selected))
    case "grow-disk":
      guard options["disk-gib"] != nil else {
        throw bad("Grow requires an explicit larger --disk-gib size.")
      }
      try output(
        await DiskGrowth().grow(
          in: directory(options),
          toBytes: bytes(options, "disk-gib", multiplier: 1_073_741_824, fallback: 0)))
    case "set-linux-boot-arguments":
      guard let arguments = options["kernel-arguments"] else {
        throw bad("Provide explicit --kernel-arguments for a stopped direct-kernel Linux VM.")
      }
      try output(await LinuxBootArguments().update(in: directory(options), to: arguments))
    case "set-linux-kernel-boot":
      guard let arguments = options["kernel-arguments"],
        let kernel = options["kernel"], kernel.hasPrefix("/"), !kernel.contains("\0"),
        let initialRamdisk = options["initrd"], initialRamdisk.hasPrefix("/"),
        !initialRamdisk.contains("\0")
      else {
        throw bad(
          "Provide --kernel, --initrd and --kernel-arguments for a stopped direct-kernel Linux VM.")
      }
      try output(
        await LinuxBootArguments().update(
          in: directory(options), to: arguments, kernel: URL(fileURLWithPath: kernel),
          initialRamdisk: URL(fileURLWithPath: initialRamdisk)))
    case "finish-disk-growth":
      try output(await DiskGrowth().finish(in: directory(options)))
    case "check-disk-growth-identity-upgrade":
      let result = await DiskGrowthIdentityUpgrade().inspect(in: try directory(options))
      try output(result)
      if ![.eligibleAtCheck, .alreadyStable, .notNeeded].contains(result.status) {
        Foundation.exit(2)
      }
    case "upgrade-disk-growth-identity":
      let confirmation = try diskGrowthIdentityUpgradeConfirmation(options)
      try output(
        await DiskGrowthIdentityUpgrade().upgrade(
          in: directory(options), expectedVMID: confirmation.vmID,
          expectedTransactionID: confirmation.transactionID,
          acknowledgement: confirmation.acknowledgement))
    case "set-network":
      guard let rawMode = options["network"], let mode = NetworkMode(rawValue: rawMode) else {
        throw bad("Choose an explicit --network disconnected or shared mode for the stopped VM.")
      }
      let selectedDirectory = try directory(options)
      let baseline = try StrictConfigurationDocument(
        await VMFiles().readMetadata(
          at: selectedDirectory.appendingPathComponent("configuration.json"),
          limit: ConfigurationCodec.maximumBytes)
      ).configuration
      let permission: SharedNetworkConfigurationPermission?
      if mode == .shared, baseline.guest == .windows11 {
        permission = try await Task.detached(priority: .utility) {
          let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
          return try QemuRegisteredCatalog.sharedNetworkConfigurationPermission(
            for: baseline, projectRoot: project)
        }.value
      } else {
        permission = nil
      }
      try output(
        await NetworkSettings().update(
          in: selectedDirectory, mode: mode, expected: baseline, sharedPermission: permission))
    case "set-hardware":
      guard options["cpus"] != nil, options["memory-mib"] != nil else {
        throw bad("Provide both --cpus and --memory-mib for the stopped VM.")
      }
      try output(
        await HardwareSettings().update(
          in: directory(options), cpuCount: integer(options, "cpus", fallback: 2),
          memoryBytes: bytes(options, "memory-mib", multiplier: 1_048_576, fallback: 4096)))
    case "clone":
      guard let target = options["destination"], target.hasPrefix("/"), !target.contains("\0"),
        let name = options["name"]
      else { throw bad("Provide a new absolute destination and a name for the VM copy.") }
      try output(
        await VMClone().copy(
          from: directory(options), to: URL(fileURLWithPath: target, isDirectory: true), name: name,
          platform: AppleCreationPlatform()))
    case "create":
      let directory = try directory(options)
      let guest = options["guest"] ?? "linux"
      guard guest == "linux" || guest == "windows11-arm64" else {
        throw bad("Choose --guest linux or windows11-arm64.")
      }
      let windows = guest == "windows11-arm64"
      if windows {
        guard !directory.path.contains(","), options["kernel"] == nil, options["initrd"] == nil,
          options["kernel-arguments"] == nil, options["support-media"] == nil,
          options["network"] == nil || options["network"] == "disconnected"
        else {
          throw bad("The experimental Windows creation profile starts offline from an ARM64 ISO.")
        }
      }
      var c = VMConfiguration(
        name: options["name"] ?? (windows ? "Windows 11 VM" : "Linux VM"),
        guest: windows ? .windows11 : .linux, backend: windows ? .qemuHVF : .appleVz,
        cpuCount: try integer(options, "cpus", fallback: 2),
        memoryBytes: try bytes(options, "memory-mib", multiplier: 1_048_576, fallback: 4096),
        diskBytes: try bytes(
          options, "disk-gib", multiplier: 1_073_741_824, fallback: windows ? 64 : 32))
      c.installationMedia = options["media"]
      c.supportMedia = options["support-media"]
      if let kernel = options["kernel"] {
        c.boot = .linuxKernel
        c.kernel = kernel
        c.initialRamdisk = options["initrd"]
        c.kernelArguments = options["kernel-arguments"] ?? "console=hvc0"
      }
      guard c.installationMedia != nil || c.kernel != nil else {
        throw bad(
          windows
            ? "Select a lawfully obtained Windows 11 ARM64 ISO."
            : "Select an ARM64 Linux installation image or kernel.")
      }
      if let network = options["network"] {
        guard let mode = NetworkMode(rawValue: network) else {
          throw bad("Network must be disconnected or shared.")
        }
        c.network = mode
      }
      if windows {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
          .deletingLastPathComponent()
        let resources = try QemuRegisteredCatalog.offlineEvaluation(projectRoot: project)
        try resources.verify()
        try await VMCreation().create(
          c, at: directory, platform: QemuCreationPlatform(resources: resources.creation))
      } else {
        try await VMCreation().create(c, at: directory, platform: AppleCreationPlatform())
      }
      try output(c)
    case "inspect", "validate":
      let directory = try directory(options)
      let files = VMFiles()
      let observed = try await readConfiguration(in: directory, files: files)
      let lock: VMLock?
      let c: VMConfiguration
      if command == "validate" {
        let admitted = try VMLock(directory: directory, expectedVMID: observed.id)
        lock = admitted
        c = try await readAdmittedConfiguration(
          in: directory, files: files, lock: admitted, expectedID: observed.id)
      } else {
        lock = nil
        c = observed
      }
      try ConfigurationValidator.validate(c, host: .current)
      let usage = try await files.inspectDisk(at: directory.appendingPathComponent(c.diskFile))
      guard usage.virtualBytes == c.diskBytes else {
        throw bad("Disk length differs from saved configuration; inspect without modifying it.")
      }
      if let lock {
        if c.backend == .qemuHVF {
          let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
          let resources = try QemuRegisteredCatalog.registeredEvaluation(
            for: c, projectRoot: project)
          let identity = try await files.readMetadata(
            at: directory.appendingPathComponent(QemuPlatformIdentityCodec.filename), limit: 8192)
          try await QemuRegisteredAdmission.validateStoredState(
            configuration: c, in: directory, platformIdentity: identity,
            resources: resources, lock: lock)
        } else {
          try await validateWritableFiles(c, in: directory, files: files)
          let identity = try await files.readMetadata(
            at: directory.appendingPathComponent("machine-identity.bin"), limit: 4096)
          let backend = try AppleVirtualMachine(
            configuration: c, directory: directory, identityData: identity)
          withExtendedLifetime((lock, backend)) {}
        }
      }
      try output(usage)
    case "run", "run-agent-transport-lab":
      let directory = try directory(options)
      let files = VMFiles()
      let duration = try integer(options, "seconds", fallback: 300)
      guard duration >= 1, duration <= 86_400 else {
        throw bad("Run duration must be 1–86400 seconds.")
      }
      let observed = try await readConfiguration(in: directory, files: files)
      let lock = try VMLock(directory: directory, expectedVMID: observed.id)
      let c = try await readAdmittedConfiguration(
        in: directory, files: files, lock: lock, expectedID: observed.id)
      let agentSocket = command == "run-agent-transport-lab" ? options["socket"] : nil
      let agentAttempts = try AgentGuestTransportLab.attempts(options["agent-attempts"])
      if command == "run-agent-transport-lab" {
        guard let agentSocket else { throw bad("Choose the private agent ciphertext socket.") }
        try AgentGuestTransportLab.validate(
          directory: directory, configuration: c, socketPath: agentSocket)
        guard
          agentAttempts.allSatisfy({
            !FileManager.default.fileExists(
              atPath: directory.appendingPathComponent("agent-connect-\($0).request").path)
          })
        else { throw bad("The selected lab request already exists. Choose fresh request numbers.") }
      }
      try ConfigurationValidator.validate(c, host: .current)
      try await validateWritableFiles(c, in: directory, files: files)
      let terminal = try SerialTerminal()
      defer {
        if !terminal.restore() {
          FileHandle.standardError.write(
            Data("Serial terminal restore failed. Run stty sane in this terminal.\n".utf8))
        }
      }
      let identity = try await files.readMetadata(
        at: directory.appendingPathComponent("machine-identity.bin"), limit: 4096)
      let backend = try AppleVirtualMachine(
        configuration: c, directory: directory, identityData: identity,
        serialInput: .standardInput, serialOutput: .standardOutput)
      let relay: (@MainActor () -> Task<Void, any Error>)?
      if let agentSocket {
        relay = {
          Task { @MainActor in
            try await AgentGuestTransportLab.run(
              backend: backend, directory: directory, socketPath: agentSocket,
              attempts: agentAttempts)
          }
        }
      } else {
        relay = nil
      }
      try await AppleRecordedCLI.run(
        directory: directory, vmID: c.id, lock: lock, backend: backend,
        files: files, duration: duration, startRelay: relay)

    default: throw bad("Unknown command. Use macopenvm help.")
    }
  }

  private static func readConfiguration(in directory: URL, files: VMFiles) async throws
    -> VMConfiguration
  {
    try ConfigurationCodec.decode(
      await files.readMetadata(
        at: directory.appendingPathComponent("configuration.json"),
        limit: ConfigurationCodec.maximumBytes))
  }

  private static func readAdmittedConfiguration(
    in directory: URL, files: VMFiles, lock: VMLock, expectedID: UUID
  ) async throws -> VMConfiguration {
    let current = try await readConfiguration(in: directory, files: files)
    guard current.id == expectedID, lock.owns(directory) else {
      throw VMError(
        .busy, "The saved VM identity changed before writer admission.",
        recovery: "Preserve the current configuration and inspect it before retrying.")
    }
    return current
  }

  private static func validateWritableFiles(
    _ c: VMConfiguration, in directory: URL, files: VMFiles
  ) async throws {
    let disk = try await files.inspectWritableFile(at: directory.appendingPathComponent(c.diskFile))
    guard disk.virtualBytes == c.diskBytes else {
      throw bad("Disk length differs from saved configuration; inspect without modifying it.")
    }
    if c.boot == .efi {
      _ = try await files.inspectWritableFile(
        at: directory.appendingPathComponent("efi-variables.bin"))
    }
    if let support = c.supportMedia {
      _ = try await files.inspectReadOnlyImage(at: URL(fileURLWithPath: support))
    }
  }

  static func parse(_ values: [String]) throws -> [String: String] {
    let allowed: Set<String> = [
      "directory", "destination", "output", "socket", "credentials", "vm-id", "issuer",
      "service-id", "enrollment-id", "public-fixture", "confirm-move-to-trash",
      "growth-transaction", "acknowledge-schema2-incompatibility",
      "expected-vm", "run-name", "expected-metadata-sha256", "reboot-evidence",
      "process-evidence", "acknowledge-host-reboot",
      "plan", "approval", "terminal", "shutdown-record", "run-directory", "record", "record-sha256",
      "endpoint-directory",
      "expected-session", "confirm-data-loss", "frames", "agent-channel",
      "display-profile", "display-width", "display-height", "gpu-host-window",
      "gpu-refresh-millihertz",
      "capture-profile", "capture-id", "expected-monitor-epoch", "milliseconds",
      "agent-attempts", "name", "media", "guest",
      "support-media", "kernel", "initrd",
      "kernel-arguments", "cpus",
      "memory-mib",
      "target-x", "target-y", "target-width", "target-height",
      "disk-gib", "network", "seconds", "first-exit", "action", "expected-frame", "x", "y", "key",
    ]
    guard values.count % 2 == 0 else { throw bad("Options require explicit values.") }
    var result: [String: String] = [:]
    for index in stride(from: 0, to: values.count, by: 2) {
      guard values[index].hasPrefix("--") else { throw bad("Invalid option.") }
      let key = String(values[index].dropFirst(2))
      guard allowed.contains(key), result[key] == nil else {
        throw bad("Unknown or repeated option.")
      }
      result[key] = values[index + 1]
    }
    return result
  }
  static func validateOptions(_ options: [String: String], command: String) throws {
    let accepted: [String: Set<String>] = [
      "probe": [], "windows-readiness": [], "storage-capacity": ["directory"],
      "inspect-interrupted-windows": ["directory", "expected-vm", "expected-session", "run-name"],
      "recover-interrupted-windows": [
        "directory", "expected-vm", "expected-session", "run-name", "expected-metadata-sha256",
        "reboot-evidence", "process-evidence", "acknowledge-host-reboot",
      ],
      "agent-tls-lab": ["socket", "credentials", "vm-id"],
      "agent-keychain-public-roundtrip-lab": [
        "action", "service-id", "vm-id", "enrollment-id", "public-fixture",
      ],
      "agent-keychain-read-probe-lab": ["service-id", "vm-id"],
      "registered-windows-agent-probe-lab": [
        "directory", "run-directory", "expected-session", "agent-channel",
      ],
      "windows-gpu-worker-lab": [
        "directory", "run-directory", "endpoint-directory", "display-profile",
        "display-width", "display-height", "gpu-host-window", "gpu-refresh-millihertz",
      ],
      "windows-producer-capture-worker-lab": [
        "directory", "run-directory", "endpoint-directory", "display-profile",
        "display-width", "display-height", "gpu-host-window", "gpu-refresh-millihertz",
        "capture-profile",
      ],
      "registered-windows-producer-capture-lab": [
        "directory", "run-directory", "expected-session", "expected-monitor-epoch",
        "capture-id", "capture-profile", "milliseconds",
      ],
      "windows-display-worker-lab": [
        "directory", "run-directory", "endpoint-directory", "display-profile",
        "display-width", "display-height",
      ],
      "windows-agent-worker-lab": [
        "directory", "run-directory", "endpoint-directory", "agent-channel",
      ],
      "registered-windows-observe-lab": [
        "directory", "run-directory", "expected-session", "frames",
      ],
      "registered-windows-recovery-input-lab": [
        "directory", "run-directory", "expected-session", "action", "expected-frame", "output",
        "target-x", "target-y", "target-width", "target-height",
      ],
      "registered-windows-input-lab": [
        "directory", "run-directory", "expected-session", "action", "expected-frame", "x", "y",
        "key", "output", "target-x", "target-y", "target-width", "target-height", "display-console",
      ],
      "verify-agent-package-lab": ["directory", "issuer"],
      "move-to-trash": ["directory", "vm-id", "confirm-move-to-trash"],
      "check-trash-admission": ["directory", "vm-id"],
      "export-diagnostics": ["directory", "output"],
      "clone": ["directory", "destination", "name"],
      "create": [
        "directory", "name", "guest", "media", "support-media", "kernel", "initrd",
        "kernel-arguments",
        "cpus", "memory-mib",
        "disk-gib", "network",
      ],
      "inspect": ["directory"], "validate": ["directory"], "doctor": ["directory"],
      "grow-disk": ["directory", "disk-gib"], "finish-disk-growth": ["directory"],
      "check-disk-growth-identity-upgrade": ["directory"],
      "upgrade-disk-growth-identity": [
        "directory", "vm-id", "growth-transaction", "acknowledge-schema2-incompatibility",
      ],
      "set-linux-boot-arguments": ["directory", "kernel-arguments"],
      "set-linux-kernel-boot": ["directory", "kernel", "initrd", "kernel-arguments"],
      "set-hardware": ["directory", "cpus", "memory-mib"],
      "set-network": ["directory", "network"],
      "run": ["directory", "seconds"],
      "run-agent-transport-lab": ["directory", "seconds", "socket", "agent-attempts"],
      "qemu-lab": ["directory"],
      "qemu-worker-lab": ["directory"],
      "qemu-display-worker-lab": ["directory"],
      "qemu-windows-installer-worker-lab": ["directory"],
      "qemu-windows-installation-worker-lab": ["directory"],
      "qemu-windows-network-continuation-worker-lab": [
        "directory", "plan", "approval", "terminal", "shutdown-record", "run-directory",
      ],
      "qemu-windows-external-continuation-worker-lab": [
        "directory", "record", "record-sha256", "run-directory",
      ],
      "qemu-windows-external-input-lab": ["action", "expected-frame", "x", "y", "key"],
      "windows-worker": ["directory", "run-directory", "endpoint-directory"],
      "status": ["directory", "run-directory", "expected-session"],
      "pause": ["directory", "run-directory", "expected-session"],
      "resume": ["directory", "run-directory", "expected-session"],
      "stop": ["directory", "run-directory", "expected-session"],
      "force-stop": ["directory", "run-directory", "expected-session", "confirm-data-loss"],
      "qemu-windows-installer-observer-lab": ["directory"],
      "qemu-windows-installation-control-lab": ["directory", "action", "x", "y", "key"],
      "qemu-windows-network-shutdown-input-lab": [
        "directory", "approval", "action", "expected-frame",
      ],
      "qemu-windows-network-continuation-control-lab": [
        "directory", "run-directory", "action", "expected-frame", "x", "y", "key",
      ],
      "qemu-windows-installer-input-lab": ["directory", "action", "expected-frame"],
      "qemu-rfb-observer-lab": ["directory"],
      "qemu-nvme-lab": ["directory"],
      "qemu-survivor-worker-lab": ["directory", "first-exit"],
      "qemu-lease-lab": ["directory", "first-exit"],
      "qemu-shutdown-lab": ["directory"],
      "attach-media": ["directory", "media"], "detach-media": ["directory"],
      "attach-support-media": ["directory", "support-media"], "detach-support-media": ["directory"],
    ]
    guard let allowed = accepted[command] else { throw bad("Unknown command. Use macopenvm help.") }
    guard Set(options.keys).isSubset(of: allowed) else {
      throw bad("An option is not supported by this command. Use macopenvm help.")
    }
  }
  private static func directory(_ options: [String: String]) throws -> URL {
    guard let value = options["directory"], value.hasPrefix("/"), !value.contains("\0") else {
      throw bad("Provide an absolute --directory path.")
    }
    return URL(fileURLWithPath: value, isDirectory: true)
  }
  static func diskGrowthIdentityUpgradeConfirmation(_ options: [String: String]) throws
    -> (vmID: UUID, transactionID: UUID, acknowledgement: DiskGrowthIdentityUpgradeAcknowledgement)
  {
    guard let rawVMID = options["vm-id"], let vmID = UUID(uuidString: rawVMID),
      rawVMID == vmID.uuidString,
      let rawTransaction = options["growth-transaction"],
      let transactionID = UUID(uuidString: rawTransaction),
      rawTransaction == transactionID.uuidString,
      rawVMID != "00000000-0000-0000-0000-000000000000",
      rawTransaction != "00000000-0000-0000-0000-000000000000",
      options["acknowledge-schema2-incompatibility"] == "yes"
    else {
      throw bad(
        "Provide canonical --vm-id and --growth-transaction UUIDs and explicit --acknowledge-schema2-incompatibility yes. "
          + DiskGrowthIdentityUpgrade.compatibilityNotice)
    }
    return (vmID, transactionID, .schema1OnlyAppsCannotOpenSchema2)
  }
  private static func integer(_ options: [String: String], _ key: String, fallback: Int) throws
    -> Int
  {
    guard let raw = options[key] else { return fallback }
    guard let value = Int(raw), value >= 0 else { throw bad("Invalid numeric option.") }
    return value
  }
  private static func bytes(
    _ options: [String: String], _ key: String, multiplier: UInt64, fallback: Int
  ) throws -> UInt64 {
    let count = try integer(options, key, fallback: fallback)
    let (value, overflow) = UInt64(count).multipliedReportingOverflow(by: multiplier)
    guard !overflow else { throw bad("Resource size overflow.") }
    return value
  }
  private static func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    print()
  }
  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
  private static func bad(_ message: String) -> VMError {
    VMError(
      .invalidConfiguration, message,
      recovery: "Use macopenvm help for the supported experimental workflow.")
  }
  private static let usage = """
    macOpenVM experimental CLI
      inspect-interrupted-windows --directory /VM-directory --expected-vm UUID --expected-session UUID --run-name run-HEX32 (read-only exact interruption inspection; never recovers)
      recover-interrupted-windows --directory /VM-directory --expected-vm UUID --expected-session UUID --run-name run-HEX32 --expected-metadata-sha256 HEX64 --reboot-evidence /private/reboot.json --process-evidence /private/processes.txt --acknowledge-host-reboot observed-reboot-and-reviewed-processes (explicit operator recovery; old facts archived, new failed transaction; ambiguous failure retains custody and this process refuses exit)
      set-linux-boot-arguments --directory /VM-directory --kernel-arguments 'arguments' (stopped direct-kernel Linux only)
      set-hardware --directory /VM-directory --cpus 4 --memory-mib 8192 (stopped VM; applies at next start)
      set-network --directory /VM-directory --network disconnected|shared (stopped VM; shared native Linux or reviewed experimental Windows ARM64; applies at next start)
      set-linux-kernel-boot --directory /VM-directory --kernel /image --initrd /initramfs --kernel-arguments 'arguments' (stopped paired image selection only)
      grow-disk --directory /VM-directory --disk-gib larger-size (offline raw capacity only)
      finish-disk-growth --directory /VM-directory (explicitly finish one pending growth)
      check-disk-growth-identity-upgrade --directory /VM-directory (read-only point-in-time legacy eligibility)
      upgrade-disk-growth-identity --directory /VM-directory --vm-id UPPERCASE-UUID --growth-transaction UPPERCASE-UUID --acknowledge-schema2-incompatibility yes (explicit stopped-VM metadata upgrade; App79/schema1-only apps cannot open schema2; preserve a compatible app, VM and exact legacy archive; no automatic rollback)
      probe
      agent-tls-lab --socket /private/local.sock --credentials /private/tmp/mvo-agent-tls-UUID --vm-id UUID (temporary authenticated protocol evaluation; no guest boot or setup claim)
      agent-keychain-public-roundtrip-lab --action create|verify --service-id UUID --vm-id UUID --enrollment-id UUID --public-fixture public-synthetic-not-for-authentication-v1 (explicit isolated public test item; never real credentials; no deletion/reset/UI/fallback)
      agent-keychain-read-probe-lab --service-id FRESH-UUID --vm-id FRESH-UUID (isolated read-only development Keychain lookup; no stored data disclosure or persistence qualification)
      registered-windows-agent-probe-lab --directory /private/VM.macopenvm --run-directory /private/current-run --expected-session UUID --agent-channel fixed-transfer-evaluation (fixed public-byte test only; never authentication or guest health)
      windows-display-worker-lab --directory /private/copy.macopenvm --run-directory /private/new-run --endpoint-directory /private/new-endpoints --display-profile virtio-gpu-2d-evaluation --display-width PIXELS --display-height PIXELS (isolated 2D device experiment; firmware fallback retained; no driver/Retina/FPS claim)
      windows-agent-worker-lab --directory /private/VM.macopenvm --run-directory /private/new-run --endpoint-directory /private/new-endpoints --agent-channel fixed-transfer-evaluation (explicit future agent transport evaluator; experimental, no driver/TLS/health claim)
      registered-windows-observe-lab --directory /private/VM.macopenvm --run-directory /private/VM.macopenvm/.runtime/run-HEX32 --expected-session UUID --frames 1...120 (read-only incremental display check; no pixels, text or input retained)
      registered-windows-input-lab --directory /private/VM.macopenvm --run-directory /private/VM.macopenvm/.runtime/run-HEX32 --expected-session UUID --action snapshot|click|key [--output /private/new.ppm|--expected-frame SHA256 --x N --y N|--key tab|return|space|escape|up|down|home|end|pageup|pagedown] (explicit current test-display navigation; no text, credentials or lifecycle action)
      verify-agent-package-lab --directory /generic/package --issuer HEX64 (explicitly approved Ed25519 issuer; exact signed generic payload)
      check-trash-admission --directory /private/VM.macopenvm --vm-id UUID (read-only preparation/cancellation; point-in-time admission, no move)
      move-to-trash --directory /private/VM.macopenvm --vm-id UUID --confirm-move-to-trash yes (experimental, stopped dedicated folder on the same volume; recoverable system Trash, never permanent removal)
      export-diagnostics --output /new/support.json [--directory /VM.macopenvm] (local structured report; no raw logs or automatic upload)
      create --directory /new/VM.macopenvm --media /ARM64.iso [--name NAME]
      storage-capacity --directory /existing/destination (read-only available host bytes; no reservation or installation-fit guarantee)
      create --guest windows11-arm64 --directory /new/Windows.macopenvm --media /Windows11_ARM64.iso [--name NAME] (experimental reviewed macOS 27 offline profile; creates files only)
        [--cpus 2 --memory-mib 4096 --disk-gib 32 --network disconnected]
        [--support-media /support-data.iso] (one additional guest-read-only image; no setup/readiness claim)
        Or --kernel /kernel --initrd /initrd --kernel-arguments 'console=hvc0 ...'
      clone --directory /stopped/VM.macopenvm --destination /new/Copy.macopenvm --name NAME (experimental same-volume native Linux copy; networking starts disconnected)
      inspect --directory /VM.macopenvm  (read-only metadata and disk size)
      doctor --directory /VM.macopenvm (read-only structural/ownership report; no repairs)
      validate --directory /VM.macopenvm (exclusive lock and framework validation)
      attach-media --directory /VM.macopenvm --media /ARM64.iso (stopped-only; exact configuration backup)
      detach-media --directory /VM.macopenvm (stopped-only; disk and identity preserved)
      attach-support-media --directory /VM.macopenvm --support-media /support-data.iso (stopped-only; read-only guest image)
      detach-support-media --directory /VM.macopenvm (stopped-only; installation media, disk and identity preserved)
      run --directory /VM.macopenvm [--seconds 300] (headless serial; clean shutdown only)
      run-agent-transport-lab --directory /new/agent-guest-UUID/Agent.macopenvm --socket /private/tmp/mvo-agent-tls-UUID/relay.sock [--seconds 300] (fresh offline native fixture, one bounded ciphertext connection; no agent authentication inferred)
        Interactive control keys, including Ctrl-C, go to the guest. Terminal mode is restored on exit.
      windows-readiness (reports unresolved compliant-platform prerequisites)
      qemu-lab --directory /new/private/EFI-fixture (explicit pinned diskless lifecycle test only)
      qemu-worker-lab --directory /new/private/EFI-fixture (separate diskless worker; private regular stdio required)
      qemu-display-worker-lab --directory /new/private/EFI-fixture (new original RAMFB/USB/VNC worker; private stdio)
      qemu-windows-installer-observer-lab --directory /new/private/installer-fixture (exact boot prompt only)
      qemu-windows-installer-input-lab --directory /private/installer-fixture --action open-format-list|scroll-format-list|close-format-list --expected-frame SHA256 (reviewed 800x600 frame only)
      qemu-windows-installer-worker-lab --directory /new/private/installer-fixture (approved offline installer experiment; no licence acceptance)
      qemu-windows-installation-worker-lab --directory /new/private/installer-fixture (explicitly approved fresh offline installation; credentials remain excluded)
      qemu-windows-installation-control-lab --directory /private/installer-fixture --action snapshot|click|key [--x PIXEL --y PIXEL|--key tab|return|space|escape|up|down|home|end|pageup|pagedown] (approved guest-only installation controls)
      qemu-windows-network-shutdown-input-lab --directory /private/installer-fixture --approval /private/plan/approval.json --action open-console|normal-shutdown --expected-frame SHA256 (explicit approval and visual review; no arbitrary commands or stop inference)
      qemu-windows-network-continuation-worker-lab --directory /private/existing-fixture --plan /private/plan/plan.json --approval /private/plan/approval.json --terminal /private/actual-terminal.json --shutdown-record /private/fixed-input.json --run-directory /private/plan/run-UUID (explicitly approved same-VM lab only; new writer permit required)
      qemu-windows-external-continuation-worker-lab --directory /private/external-VM --record /private/external-VM/continuation-runs/run-UUID/external-prepared.json --record-sha256 SHA256 --run-directory /private/external-VM/continuation-runs/run-UUID (reviewed stopped relocation only; new actual writer and session required)
      qemu-windows-external-input-lab --action snapshot|click|key [--expected-frame SHA256 --x INTEGER --y INTEGER|--key NAME] (one exact approved live Windows evaluation session; no text, credentials or runtime control)
      windows-worker --directory /RegisteredVM.macopenvm --run-directory /RegisteredVM.macopenvm/.runtime/run-UUID --endpoint-directory /private/tmp/mvo-qemu-UUID (experimental registered offline Windows worker; real writer and current resource verification required)
      status|pause|resume|stop --directory /RegisteredVM.macopenvm --run-directory /RegisteredVM.macopenvm/.runtime/run-UUID --expected-session UUID (experimental existing registered Windows worker only; no new owner)
      force-stop --directory /RegisteredVM.macopenvm --run-directory /RegisteredVM.macopenvm/.runtime/run-UUID --expected-session UUID --confirm-data-loss yes (explicit loss-of-unsaved-data confirmation)
        Control replies acknowledge requests or report observed status. A stop acknowledgement does not prove shutdown, disk consistency or process reaping.
      qemu-windows-network-continuation-control-lab --directory /private/existing-fixture --run-directory /private/plan/run-UUID --action snapshot|click|key [--expected-frame SHA256 --x N --y N|--key tab|return|space|escape|up|down|home|end|pageup|pagedown] (approved new route only; no arbitrary typing or lifecycle actions)
      qemu-rfb-observer-lab --directory /new/private/EFI-fixture (headless original no-OS display/input observer)
      qemu-nvme-lab --directory /new/private/NVMe-fixture (new original two-boot disposable32MiB storage test)
      qemu-survivor-worker-lab --directory /new/private/EFI-fixture --first-exit qemu|tpm
        (private-stdio single-survivor fault trial; owns explicit cleanup after its fixed 60-second hold)
      qemu-lease-lab --directory /new/private/EFI-fixture --first-exit qemu|tpm (diskless; qemu simulates an abrupt child exit)
      qemu-shutdown-lab --directory /new/private/shutdown-fixture (pinned diskless guest-originated shutdown; status-only, no automatic cleanup)
    No OS media is bundled. Start completion is not guest readiness. No parity claim.
    """
}

/// Explicit CLI relocation result; never included in a support bundle.
private struct TrashCLIObservation: Encodable {
  let scope = "macopenvm-experimental-vm-trash"
  let vmID: UUID
  let status: String
  let trashLocation: String?
  let cancellationObserved: Bool
  let readOnly: Bool
}

/// Current filesystem availability, without paths or an allocation promise.
private struct StorageCapacityCLIObservation: Encodable {
  let schemaVersion = 1
  let scope = "macopenvm-destination-storage-capacity"
  let availableBytes: UInt64
  let creationReserveBytes: UInt64 = 1_073_741_824
  let readOnly = true
  let spaceReserved = false
  let installationFitVerified = false
}
