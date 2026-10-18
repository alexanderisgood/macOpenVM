// SPDX-License-Identifier: Apache-2.0
import AppKit
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Qemu
import VMCore
import VMStorage

struct RegisteredWindowsAppQualificationRequest: Sendable {
  enum Mode: Equatable, Sendable { case fresh, installed }
  static let flag = "--registered-windows-app-qualification"
  static let installedFlag = "--registered-windows-installed-app-qualification"
  static let vmID = UUID(
    uuid: (
      0xa9, 0x27, 0x3d, 0x69, 0xe6, 0xc4, 0x4c, 0xd7, 0x81, 0x8c, 0x2a, 0x38, 0xc4, 0x5b, 0x13, 0x05
    ))
  static let vmPath =
    "/private/tmp/mvo-registered-create-83450c6d81f44e60b3d1a48e5c7c8796/Windows ARM Evaluation.macopenvm"
  static let installedVMID = UUID(
    uuid: (
      0x7d, 0x5c, 0x2c, 0xd4, 0xe2, 0xe4, 0x40, 0xdf, 0x85, 0x35, 0x7c, 0x75, 0xe6, 0x91, 0xd7, 0x28
    ))
  static let installedVMPath =
    "/private/tmp/mvo-network-preparation-4ba67433cd724be2813e72de72da44dd/Windows Network Evaluation.macopenvm"
  static let installedConfigurationSHA256 =
    "437d3671a90c33e02d8403b129b445ce54b62e612e4aa6698c766a48fdaefeb4"
  static let priorInstalledSession = UUID(
    uuid: (
      0x01, 0xf4, 0x05, 0xd3, 0x85, 0x3f, 0x4b, 0xe0, 0x9f, 0x01, 0xae, 0xfa, 0xb8, 0xc1, 0xa1, 0x67
    ))
  let mode: Mode
  let controlSocket: URL
  var expectedVMID: UUID { mode == .installed ? Self.installedVMID : Self.vmID }
  var expectedVMPath: String { mode == .installed ? Self.installedVMPath : Self.vmPath }
  var outputDirectory: URL { controlSocket.deletingLastPathComponent() }
  private init(mode: Mode, controlSocket: URL) {
    self.mode = mode
    self.controlSocket = controlSocket
  }
  static func parse(arguments: [String], environment: [String: String]) throws -> Self? {
    guard arguments.contains(flag) || arguments.contains(installedFlag) else { return nil }
    let installed = arguments.contains(installedFlag)
    let offset = installed ? 1 : 0
    guard environment["MVO_REGISTERED_APP_QUALIFICATION"] == "1", arguments.count == 7 + offset,
      arguments[1] == (installed ? installedFlag : flag), arguments[2] == "--run",
      !installed || arguments[3] == "--shared-network-authorized",
      arguments[3 + offset] == "--directory",
      arguments[4 + offset] == (installed ? installedVMPath : vmPath),
      arguments[5 + offset] == "--control-socket",
      arguments[6 + offset].range(
        of: "^/private/tmp/mvo-appqual-[0-9a-f]{16}/control\\.sock$", options: .regularExpression)
        != nil,
      !arguments[6 + offset].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw appQualificationFailure() }
    return Self(
      mode: installed ? .installed : .fresh,
      controlSocket: URL(fileURLWithPath: arguments[6 + offset]))
  }
}

enum RegisteredAppQualificationFreshness {
  static func validate(
    configuration: VMConfiguration, names: Set<String>, diskBytes: Int64,
    diskBlocks: Int64, variablesBytes: Int64, tpmMembers: [String]
  ) throws {
    guard configuration.id == RegisteredWindowsAppQualificationRequest.vmID,
      configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi,
      configuration.network == .disconnected, configuration.installationMedia != nil,
      configuration.supportMedia == nil,
      configuration.kernel == nil, configuration.initialRamdisk == nil,
      names == [
        "configuration.json", "writer.lock", configuration.diskFile, "qemu-platform.json",
        "uefi-vars.json", "tpm-state",
      ],
      diskBytes >= 0, UInt64(diskBytes) == configuration.diskBytes, diskBlocks == 0,
      variablesBytes == 0, tpmMembers.isEmpty
    else { throw appQualificationFailure() }
  }
  static func inspect() async throws {
    let directory = URL(
      fileURLWithPath: RegisteredWindowsAppQualificationRequest.vmPath, isDirectory: true)
    try AppQualificationIO.privateDirectory(directory)
    let files = VMFiles()
    let url = directory.appendingPathComponent("configuration.json")
    let before = try ConfigurationCodec.decode(
      await files.readMetadata(at: url, limit: ConfigurationCodec.maximumBytes))
    let lock = try VMLock(
      directory: directory, expectedVMID: RegisteredWindowsAppQualificationRequest.vmID)
    defer { withExtendedLifetime(lock) {} }
    let current = try ConfigurationCodec.decode(
      await files.readMetadata(at: url, limit: ConfigurationCodec.maximumBytes))
    guard current == before, lock.owns(directory) else { throw appQualificationFailure() }
    try ConfigurationValidator.validate(current, host: .current)
    let disk = try AppQualificationIO.regular(directory.appendingPathComponent(current.diskFile))
    let variables = try AppQualificationIO.regular(
      directory.appendingPathComponent("uefi-vars.json"))
    let tpm = directory.appendingPathComponent("tpm-state", isDirectory: true)
    try AppQualificationIO.privateDirectory(tpm)
    try validate(
      configuration: current,
      names: Set(FileManager.default.contentsOfDirectory(atPath: directory.path)),
      diskBytes: disk.st_size, diskBlocks: disk.st_blocks, variablesBytes: variables.st_size,
      tpmMembers: FileManager.default.contentsOfDirectory(atPath: tpm.path))
    guard lock.owns(directory) else { throw appQualificationFailure() }
  }
}

enum RegisteredInstalledAppQualificationAdmission {
  static func validate(
    configuration: VMConfiguration, configurationSHA256: String,
    history: RuntimeRecord, intentVMID: UUID, intentSessionID: UUID,
    intentState: RuntimeIntent.State,
    diskBytes: Int64, variablesBytes: Int64, tpmMembers: Set<String>
  ) throws {
    guard configuration.id == RegisteredWindowsAppQualificationRequest.installedVMID,
      configurationSHA256 == RegisteredWindowsAppQualificationRequest.installedConfigurationSHA256,
      configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi,
      configuration.network == .shared, configuration.installationMedia == nil,
      configuration.supportMedia == nil, configuration.kernel == nil,
      configuration.initialRamdisk == nil,
      history.sessionID == RegisteredWindowsAppQualificationRequest.priorInstalledSession,
      history.snapshot
        == RuntimeSnapshot(
          state: .stopped, operation: nil, backendActive: false, outcome: .guestStopped),
      intentVMID == configuration.id, intentSessionID == history.sessionID, intentState == .settled,
      diskBytes >= 0, UInt64(diskBytes) == configuration.diskBytes,
      variablesBytes > 0, variablesBytes <= 1_048_576,
      tpmMembers == [".lock", "tpm2-00.permall"]
    else { throw appQualificationFailure() }
  }
  static func inspect() async throws -> VMConfiguration {
    let directory = URL(
      fileURLWithPath: RegisteredWindowsAppQualificationRequest.installedVMPath, isDirectory: true)
    try AppQualificationIO.privateDirectory(directory)
    let files = VMFiles()
    let url = directory.appendingPathComponent("configuration.json")
    let before = try await files.readMetadata(at: url, limit: ConfigurationCodec.maximumBytes)
    let lock = try VMLock(
      directory: directory, expectedVMID: RegisteredWindowsAppQualificationRequest.installedVMID)
    defer { withExtendedLifetime(lock) {} }
    let bytes = try await files.readMetadata(at: url, limit: ConfigurationCodec.maximumBytes)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard digest == RegisteredWindowsAppQualificationRequest.installedConfigurationSHA256 else {
      throw appQualificationFailure()
    }
    let current = try ConfigurationCodec.decode(bytes)
    guard bytes == before, lock.owns(directory),
      let intent = try await files.readRuntimeIntent(in: directory)
    else { throw appQualificationFailure() }
    try ConfigurationValidator.validate(current, host: .current)
    let history = try RuntimeHistoryCodec.decode(
      await files.readMetadata(at: directory.appendingPathComponent("runtime.json"), limit: 4096))
    let disk = try AppQualificationIO.regular(directory.appendingPathComponent(current.diskFile))
    let variables = try AppQualificationIO.regular(
      directory.appendingPathComponent("uefi-vars.json"))
    let tpm = directory.appendingPathComponent("tpm-state", isDirectory: true)
    try AppQualificationIO.privateDirectory(tpm)
    let names = try Set(FileManager.default.contentsOfDirectory(atPath: tpm.path))
    guard names == [".lock", "tpm2-00.permall"] else { throw appQualificationFailure() }
    for name in names {
      let member = try AppQualificationIO.regular(tpm.appendingPathComponent(name))
      guard member.st_size >= 0,
        name == ".lock" ? member.st_size == 0 : member.st_size <= 16_777_216
      else { throw appQualificationFailure() }
    }
    try validate(
      configuration: current,
      configurationSHA256: digest,
      history: history, intentVMID: intent.vmID, intentSessionID: intent.sessionID,
      intentState: intent.state, diskBytes: disk.st_size, variablesBytes: variables.st_size,
      tpmMembers: names)
    guard lock.owns(directory) else { throw appQualificationFailure() }
    return current
  }
}

enum RegisteredAppQualificationAuthorization {
  static func sharedNetworkNoop(
    original: VMConfiguration, selected: VMConfiguration,
    permission: SharedNetworkConfigurationPermission?
  ) throws {
    guard original.id == RegisteredWindowsAppQualificationRequest.installedVMID,
      original.network == .shared, original == selected,
      permission?.allowsSharedConfiguration(original) == true
    else { throw appQualificationFailure() }
  }
  static func allowsRuntimeAction(
    _ action: RegisteredAppQualificationControl.Action,
    mode: RegisteredWindowsAppQualificationRequest.Mode
  ) -> Bool {
    mode == .installed ? action == .stop : action == .forceStop
  }
  static func driverDiscSelection(
    original: VMConfiguration, selected: VMConfiguration,
    image: ReviewedQemuSupportImage
  ) throws {
    guard original.id == RegisteredWindowsAppQualificationRequest.vmID,
      original.supportMedia == nil
    else { throw appQualificationFailure() }
    var allowed = original
    allowed.supportMedia = image.url.path
    guard selected == allowed else { throw appQualificationFailure() }
  }
  static func displayReady(attached: Bool, drawn: Bool, failed: Bool) -> Bool {
    attached && drawn && !failed
  }
  static func mutationMatches(
    _ input: RegisteredAppQualificationControl.Request, nonce: UUID,
    lastRequest: UInt64, sessionID: UUID, generation: UUID,
    vmID: UUID = RegisteredWindowsAppQualificationRequest.vmID
  ) -> Bool {
    input.vmID == vmID && input.nonce == nonce
      && input.requestID > lastRequest && input.sessionID == sessionID
      && input.launchGeneration == generation
  }
  static func preOwnerQuit(
    _ input: RegisteredAppQualificationControl.Request, nonce: UUID,
    lastRequest: UInt64, hasRuntime: Bool, busy: Bool,
    vmID: UUID = RegisteredWindowsAppQualificationRequest.vmID
  ) -> Bool {
    input.action == .quit && input.vmID == vmID
      && input.nonce == nonce && input.requestID > lastRequest && input.sessionID == nil
      && input.launchGeneration == nil && !hasRuntime && !busy
  }
}

@MainActor final class RegisteredWindowsAppQualification {
  private let request: RegisteredWindowsAppQualificationRequest
  private let session: DesktopSession
  private var control: RegisteredAppQualificationControl?
  private var runtime: DesktopWindowsRuntime?
  private var display: RfbLabSession?
  private var lifetime: RegisteredWindowsAppQualification?
  private var log: Int32 = -1
  private var logBytes = 0
  private var stages: Set<String> = []
  private var lastMutation: UInt64 = 0
  private var attached = false
  private var drawn = false
  private var quitAuthorized = false
  private var failed = false
  private var installedBaseline: VMConfiguration?
  private var lastPresentation: RfbQualificationPresentation?
  init(request: RegisteredWindowsAppQualificationRequest, session: DesktopSession) {
    self.request = request
    self.session = session
  }
  func run() async {
    guard lifetime == nil else { return }
    lifetime = self
    do {
      try AppQualificationIO.privateDirectory(request.outputDirectory)
      let names = try Set(
        FileManager.default.contentsOfDirectory(atPath: request.outputDirectory.path))
      guard names == ["app-stdout.log", "app-stderr.log"] else { throw appQualificationFailure() }
      for name in names {
        _ = try AppQualificationIO.regular(request.outputDirectory.appendingPathComponent(name))
      }
      log = open(
        request.outputDirectory.appendingPathComponent("sdk-events.jsonl").path,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard log >= 0, fchmod(log, 0o600) == 0 else { throw appQualificationFailure() }
      let server = RegisteredAppQualificationControl(
        socketURL: request.controlSocket,
        handler: { [weak self] input in
          guard let self else { return Self.unavailable(input) }
          return self.handle(input)
        },
        onResponseSent: { [weak self] input, output in
          guard let self, input.action == .quit, output.replyCode == .ok, self.quitAuthorized else {
            return
          }
          Task { @MainActor [self] in
            await self.control?.close()
            if self.log >= 0 {
              _ = fsync(self.log)
              close(self.log)
              self.log = -1
            }
            NSApp.terminate(nil)
          }
        })
      control = server
      try await server.start()
      try record("control-bound-before-fallible-admission")
      if request.mode == .installed {
        installedBaseline = try await RegisteredInstalledAppQualificationAdmission.inspect()
        try record("installed-baseline-under-exclusive-writer")
      } else {
        try await RegisteredAppQualificationFreshness.inspect()
        try record("fresh-under-exclusive-writer")
      }
      try await boundedSelection()
      guard session.canStartSelected,
        session.configuration?.id == request.expectedVMID,
        !session.isBusy
      else { throw appQualificationFailure() }
      try record("ordinary-selection-and-actual-bundle-ready")
      if request.mode == .installed {
        try await selectOrdinarySharedNetwork()
      } else {
        try await selectOrdinaryDriverDisc()
        try record("ordinary-driver-disc-selected")
      }
      session.start()
      runtime = session.qualificationWindowsRuntime
      let deadline = ContinuousClock.now + .seconds(90)
      while ContinuousClock.now < deadline {
        if let actual = session.qualificationWindowsRuntime, actual.phase == .running,
          let presentation = session.qualificationWindowsDisplay
        {
          runtime = actual
          display = presentation
          presentation.qualificationPresentation = { [weak self] value in self?.presentation(value)
          }
          try record("ordinary-worker-running")
          break
        }
        if session.needsOwnershipRecovery { throw appQualificationFailure() }
        try await Task.sleep(for: .milliseconds(25))
      }
      guard runtime != nil else { throw appQualificationFailure() }
      while true {
        if let actual = runtime, actual.phase == .settled {
          try record("actual-parent-and-producer-settled")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    } catch {
      failed = true
      recordOrFail("failure-retained-no-automatic-action")
      // Keep the actual session/control/log and parent lifetime. A deadline, EOF
      // or failed SDK observation never sends input, quit, force or a signal.
    }
  }
  private func boundedSelection() async throws {
    let target = URL(
      fileURLWithPath: request.expectedVMPath, isDirectory: true
    ).appendingPathComponent("configuration.json")
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await self.session.qualificationSelectVM(
          at: target, expectedID: self.request.expectedVMID)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(90))
        throw appQualificationFailure()
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }
  private func selectOrdinarySharedNetwork() async throws {
    guard let original = installedBaseline, session.configuration == original,
      session.canEditNetworkSettings, !session.isBusy
    else { throw appQualificationFailure() }
    session.showNetworkSettings()
    let openDeadline = ContinuousClock.now + .seconds(30)
    while session.preparing {
      guard ContinuousClock.now < openDeadline else { throw appQualificationFailure() }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard session.editingNetwork, session.networkConfiguration == original,
      session.configuration == original, session.networkError == nil
    else { throw appQualificationFailure() }
    let permission = session.networkSharedPermission
    try RegisteredAppQualificationAuthorization.sharedNetworkNoop(
      original: original, selected: original, permission: permission)
    try record("ordinary-network-settings-permission-ready")
    session.saveNetwork(mode: .shared)
    let saveDeadline = ContinuousClock.now + .seconds(30)
    while session.preparing {
      guard ContinuousClock.now < saveDeadline else { throw appQualificationFailure() }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard !session.editingNetwork, session.networkError == nil,
      let selected = session.configuration, session.canStartSelected, !session.isBusy
    else { throw appQualificationFailure() }
    try RegisteredAppQualificationAuthorization.sharedNetworkNoop(
      original: original, selected: selected, permission: permission)
    try record("ordinary-shared-network-noop-saved")
  }
  private func selectOrdinaryDriverDisc() async throws {
    guard let original = session.configuration,
      original.id == RegisteredWindowsAppQualificationRequest.vmID
    else { throw appQualificationFailure() }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let image = try QemuRegisteredCatalog.networkDriverSupportImage(projectRoot: project)
    session.chooseSupportMedia()
    let deadline = ContinuousClock.now + .seconds(30)
    while session.preparing {
      guard ContinuousClock.now < deadline else { throw appQualificationFailure() }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard let selected = session.configuration, session.canStartSelected, !session.isBusy else {
      throw appQualificationFailure()
    }
    try RegisteredAppQualificationAuthorization.driverDiscSelection(
      original: original,
      selected: selected, image: image)
  }
  private func presentation(_ value: RfbQualificationPresentation) {
    guard let actual = runtime, actual === session.qualificationWindowsRuntime,
      actual.phase == .running,
      let display, value.epoch == display.frame?.connectionEpoch, value.sequence > 0
    else { return }
    if value.attached {
      attached = true
      recordOrFail("native-view-attached")
    }
    lastPresentation = value
    if value.drawn, value.attached, value.visible {
      drawn = true
      recordOrFail("native-view-drawn")
    }
  }
  private func handle(_ input: RegisteredAppQualificationControl.Request)
    -> RegisteredAppQualificationControl.Response
  {
    var code = RegisteredAppQualificationControl.ReplyCode.refused
    let nonce = control?.nonce ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    if input.vmID == request.expectedVMID {
      if input.action == .status, input.nonce == zero || input.nonce == nonce {
        code = .ok
      } else if input.nonce == nonce, input.requestID > lastMutation {
        if runtime == nil { runtime = session.qualificationWindowsRuntime }
        if RegisteredAppQualificationAuthorization.preOwnerQuit(
          input, nonce: nonce,
          lastRequest: lastMutation,
          hasRuntime: runtime != nil || session.qualificationWindowsRuntime != nil,
          busy: session.isBusy, vmID: request.expectedVMID)
        {
          lastMutation = input.requestID
          quitAuthorized = true
          code = .ok
          recordOrFail("explicit-root-pre-owner-quit-request")
        } else if let actual = runtime, let sessionID = actual.sessionID,
          RegisteredAppQualificationAuthorization.mutationMatches(
            input, nonce: nonce,
            lastRequest: lastMutation, sessionID: sessionID, generation: actual.launchGeneration,
            vmID: request.expectedVMID)
        {
          if RegisteredAppQualificationAuthorization.allowsRuntimeAction(
            input.action, mode: request.mode),
            actual === session.qualificationWindowsRuntime,
            actual.phase == .running || request.mode == .fresh && actual.phase == .recoveryRequired
          {
            lastMutation = input.requestID
            session.perform(request.mode == .installed ? .stop : .forceStop)
            code = .ok
            recordOrFail(
              request.mode == .installed
                ? "explicit-root-normal-stop-request" : "explicit-root-force-request")
          } else if input.action == .quit, runtime?.phase == .settled, !session.isBusy,
            runtime?.termination?.producerQualified == true,
            runtime?.termination?.parentReaped == true,
            runtime?.termination?.regularDescriptorsClosed == true
          {
            lastMutation = input.requestID
            quitAuthorized = true
            code = .ok
            recordOrFail("explicit-root-quit-request")
          }
        }
      }
    }
    return .init(
      requestID: input.requestID, nonce: nonce, vmID: request.expectedVMID,
      sessionID: runtime?.sessionID, launchGeneration: runtime?.launchGeneration, replyCode: code,
      state: session.state, busy: session.isBusy, backendActive: session.isActive,
      displayReady: RegisteredAppQualificationAuthorization.displayReady(
        attached: attached, drawn: drawn, failed: failed),
      frameEpochPresent: display?.frame?.connectionEpoch != nil,
      settled: runtime?.phase == .settled, outcome: runtime?.termination?.outcome,
      qualificationFailed: failed)
  }
  private static func unavailable(_ input: RegisteredAppQualificationControl.Request)
    -> RegisteredAppQualificationControl.Response
  {
    .init(
      requestID: input.requestID, nonce: input.nonce, vmID: input.vmID, sessionID: nil,
      launchGeneration: nil,
      replyCode: .failed, state: .failed, busy: true, backendActive: false, displayReady: false,
      frameEpochPresent: false, settled: false, outcome: nil, qualificationFailed: true)
  }
  private func recordOrFail(_ stage: String) {
    do { try record(stage) } catch { failed = true }
  }
  private func record(_ stage: String) throws {
    guard !stages.contains(stage) else { return }
    guard log >= 0, stages.count < 16 else { throw appQualificationFailure() }
    let data =
      try JSONEncoder().encode(
        Event(
          stage: stage, vmID: request.expectedVMID,
          sessionID: runtime?.sessionID, launchGeneration: runtime?.launchGeneration,
          attached: attached, drawn: drawn, failed: failed, frameEpoch: lastPresentation?.epoch,
          sequence: lastPresentation?.sequence, width: lastPresentation?.width,
          height: lastPresentation?.height)) + Data([10])
    guard logBytes + data.count <= 16_384 else { throw appQualificationFailure() }
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { throw appQualificationFailure() }
      var written = 0
      while written < data.count {
        let count = write(log, base.advanced(by: written), data.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw appQualificationFailure() }
        written += count
      }
    }
    guard fsync(log) == 0 else { throw appQualificationFailure() }
    logBytes += data.count
    stages.insert(stage)
  }
  private struct Event: Encodable {
    let stage: String, vmID: UUID, sessionID: UUID?, launchGeneration: UUID?
    let attached: Bool, drawn: Bool, failed: Bool
    let frameEpoch: UUID?
    let sequence: UInt64?
    let width: Int?, height: Int?
  }
}

private enum AppQualificationIO {
  static func privateDirectory(_ url: URL) throws {
    var path = ""
    for part in url.path.split(separator: "/") {
      path += "/" + part
      var s = stat()
      guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR,
        s.st_uid == 0 || s.st_uid == geteuid(),
        s.st_mode & 0o022 == 0
          || (path == "/private/tmp" && s.st_uid == 0 && s.st_mode & S_ISVTX != 0)
      else { throw appQualificationFailure() }
    }
    var s = stat()
    guard lstat(url.path, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o7777 == 0o700 else {
      throw appQualificationFailure()
    }
  }
  static func regular(_ url: URL) throws -> stat {
    var s = stat()
    guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
      s.st_uid == geteuid(), s.st_nlink == 1, s.st_mode & 0o7777 == 0o600
    else { throw appQualificationFailure() }
    return s
  }
}

private func appQualificationFailure() -> VMError {
  VMError(
    .invalidConfiguration, "The opt-in App qualification could not be confirmed.",
    recovery: "Preserve the actual App and worker; no automatic cleanup is performed.")
}
